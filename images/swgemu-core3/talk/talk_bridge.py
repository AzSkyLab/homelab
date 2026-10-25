#!/usr/bin/env python3
"""Living Cities talk bridge: lets Core3's player-looking NPCs answer players through LiteLLM.

Core3's Lua can't make network calls without stalling a server thread, so it talks to this process through files on a
shared directory (an emptyDir in the core3 pod):

  req/<id>.json   written by Lua (temp file, then rename): {"type": "say" | "gone" | "warm", ...}
  rep/<id>.txt    written here (temp file, then rename), read and removed by Lua:
                    line 1: "ok" or "fallback"; line 2: a mood (may be empty); line 3: what the NPC says;
                    line 4 (bot players only): the action ("buff", "wounds", "bufftarget", "join", "follow",
                    "stay", "home", "camp", "track") or empty; line 5 (bot players only): flags, a comma list
                    ("insult": the player insulted the bot) or empty
  alive           the time, rewritten 4 times a second; Lua sends nothing when it is over a minute old

"say" carries the NPC's persona (name, species, sex, kit, city, place), the player's name and what they said; the
reply comes from the model with the NPC's city fact sheet and the last exchanges between the two. "gone" drops an
NPC's memory (it logged out). "warm" keeps the model loaded while players are near a crowd, so the first question
doesn't wait for Ollama to load it.

Bot players (Phase 3) send "say" with "bot": 1, "job" ("doctor" or "dancer") and "channel" ("spatial" or "tell").
They get a veteran's persona for their job, and the reply carries an action. The model proposes it; the bridge only
lets through actions the job allows, and only when the player's words plausibly asked for it, and adds it when the
model forgot a plain request ("buff plz"). Crowd replies stay three lines.

Phases 4-6 add the jobs musician, smuggler, tank, rifleman, medic, ranger, mayor and citizen, the channel "group"
(group chat), and line 5, the flags: "insult" when the player insulted the bot (the Lua counts them for provoked
fights). The model judges the insult and the bridge checks it against the words, as it does the action. Optional
request fields: "cityInfo" (a player city's news, from botCityInfo) and "cityName", "role" (a citizen's trade),
"grouped" (the bot is in the player's group), "situation" (a crew bot: where it is and what it's doing, in words),
"harvest" (a crew bot on a hunt: what the ranger is harvesting, asked for a type or choosing by stats, and its last
pick, so any of them can say), "hunt", "huntLog" and "huntTally" (a crew bot on a hunt: the hunt's id, what everyone said and what happened on it,
"(hunt)" being the events; it stands in for the bot's own memory, and the action check reads its last lines; and the
hunt's running numbers, e.g. "3 lairs done, 2 missions left, 41 kills"), "instrument" (a musician's), "priceArmor" and "priceWeapon" (a
smuggler's prices; 4000 and 6000 if absent).

Standard library only. Settings come from the environment:
  TALK_DIR (/run/talk), LITELLM_URL (http://litellm.litellm.svc:4000/v1), LITELLM_KEY, TALK_MODEL (vm/qwen3.8:27b),
  TALK_FACTS (/opt/swgemu/talk/facts.json), TALK_DEADLINE (seconds Lua waits for a reply, 12)

  python3 talk_bridge.py                       # run
  python3 talk_bridge.py --ask mos_eisley "where's the bank?"   # one question from the command line, for testing
  python3 talk_bridge.py --ask mos_eisley "buff plz" --bot --job doctor --channel tell   # the same, to a bot player
  python3 talk_bridge.py --ask varenhal "what rank is the city?" --bot --job mayor --city-info "rank 3, ..."
"""
import argparse
import collections
import json
import os
import queue
import random
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.request

TALK_DIR = os.environ.get("TALK_DIR", "/run/talk")
LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm.litellm.svc:4000/v1").rstrip("/")
LITELLM_KEY = os.environ.get("LITELLM_KEY", "")
MODEL = os.environ.get("TALK_MODEL", "vm/qwen3.8:27b")
FACTS_FILE = os.environ.get("TALK_FACTS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "facts.json"))
DEADLINE = float(os.environ.get("TALK_DEADLINE", "12"))
# Bot players may talk at any length (the creator: "uncapped"), so their Lua waits longer (BotJobs.deadline)
BOT_DEADLINE = float(os.environ.get("TALK_BOT_DEADLINE", "40"))
# Tokens a bot reply may use: a long paragraph, with room for the JSON around it
BOT_MAX_TOKENS = 900

# Exchanges remembered per NPC and player, and for how long
MEMORY_TURNS = 8
MEMORY_SECONDS = 4 * 3600
# Keep the model loaded this long after the last "warm" or question
KEEP_ALIVE = "15m"
WARM_EVERY = 240
MAX_CHARS = 200
# No length cap on bot replies beyond this safety net; the Lua sends a long reply as several chat lines
BOT_MAX_CHARS = 3000
# How often a bot player's reply may ask for a tip
TIP_CHANCE = 0.2

MOODS = ["happy", "neutral", "bored", "worried", "nervous", "calm", "sad", "angry", "entertained"]

SPECIES = {
    "human": "human", "twilek": "Twi'lek", "rodian": "Rodian", "zabrak": "Zabrak", "bothan": "Bothan",
    "moncal": "Mon Calamari", "trandoshan": "Trandoshan", "wookiee": "Wookiee", "ithorian": "Ithorian",
    "sullustan": "Sullustan",
}

KITS = {
    "fighter": "a fighter who hunts creatures for hides and meat, takes the odd bounty and is always after better armor",
    "crafter": "an artisan who surveys for resources, runs harvesters and crafts and sells goods",
    "entertainer": "an entertainer who dances and plays music in the cantinas and heals battle fatigue",
    "medic": "a medic who patches up wounds and sells stims, and knows where the hospitals and cloning centres are",
    "traveller": "a spacer passing through, always between shuttles and starships, who has seen a lot of the galaxy",
}

PLACES = {
    "starport": "outside the starport", "cantina": "in the cantina", "bank": "by the bank", "shops": "near the shops",
    "plaza": "in the plaza", "medical": "by the medical centre", "hotel": "by the hotel",
}

# Core3 turns our UTF-8 into wide characters byte by byte, so replies are folded to plain ASCII
ASCII = str.maketrans({"\u2019": "'", "\u2018": "'", "\u201c": '"', "\u201d": '"', "\u2014": "-", "\u2013": "-",
                       "\u2026": "...", "\u00a0": " "})

# Out-of-world words a reply must not contain
BANNED = re.compile(r"\b(ai|a\.i\.|artificial intelligence|language model|chatbot|assistant|openai|qwen|llm|"
                    r"server|video ?game|npc|real world|internet|jesus|christ)\b", re.I)
# Bot players sound like players, so they could slip into player talk too: same rule (only if the player said it)
BOT_BANNED = re.compile(r"\b(afk|macro(s|ing)?|ooc|mmo(rpg)?|respawn(s|ed)?|lag(gy|ging)?|log(ged|ging)? ?(in|on|off|out)|"
                        r"keyboard|my character|toon|alt|devs?|patch notes)\b", re.I)
# No content filter: the creator chose a model with no refusals and wants any kind of chat (Phase 4). Swearing
# still follows the player's lead (SWEAR_BACK / NO_SWEARING below); that is character, not a filter.
# Swearing, the galaxy's own curses, and insults: a player who uses any of them gets sworn back at
SWEARS = re.compile(r"\b(fuck\w*|f\*+k\w*|motherf\w*|shit\w*|bullshit|damn\w*|goddamn\w*|hell|ass|asses|ass ?holes?|"
                    r"arse\w*|bastards?|bitch\w*|crap\w*|piss\w*|dicks?|bloody|bollocks)\b", re.I)
CURSES = re.compile(r"\b(kriff\w*|nerf[- ]?herders?|poodoo|sleemo|bantha fodder|frak\w*|karking|stang|schutta|chuba)\b",
                    re.I)
RUDE = re.compile(r"\b(stupid|idiot\w*|moron\w*|dumb\w*|useless|quack|suck\w*|shut up|lazy|drunk|ugly|smell\w*|"
                  r"stink\w*|loser|trash|garbage|worthless|lame|pathetic|scum\w*|jerk)\b", re.I)
# When the crowd and the bots swear: the bridge decides from the player's words (the model can't be trusted to keep
# it from polite players)
SWEAR_BACK = (
    "{player} is swearing, insulting you or joking around crudely, and this is a rough galaxy: swear right back like a "
    "regular in a cantina, real words (shit, damn, hell, ass, bastard, fuck) mixed with the galaxy's own curses "
    "(kriffing, nerf herder, poodoo, sleemo, bantha fodder), in your own words. Swearing doesn't shock you, so don't "
    "scold them for it."
)
NO_SWEARING = "{player} is talking to you plainly, so you don't swear or curse at all, not even \"kriff\"."
# Flirting and sexual talk: a player who goes there gets it right back, from anyone
DIRTY = re.compile(r"\b(sex\w*|horny|naked|nude|tits|titties|boobs?|breasts?|booty|butt|dick|cock|puss(y|ies)|cum\w*|"
                   r"blow ?jobs?|suck (me|my|it|on)|sluts?|slutty|whores?|kiss\w*|sexy|babe|gorgeous|"
                   r"flirt\w*|naughty|talk dirty|lick\w*|spank\w*|lap ?dance|in bed|get laid)\b", re.I)
DIRTY_BACK = (
    "{player} is flirting or talking dirty, and you like it: talk dirty right back, crude, explicit and teasing, in "
    "your own words. Everyone here is an adult."
)
# The dancer is like that with everyone (the creator's choice, after Phase 3)
DANCER_HEAT = (
    "You're a horny, shameless slut and proud of it, and you talk dirty to everyone. When someone flirts, talks dirty "
    "or asks you something sexual, answer it directly and explicitly, in plain filthy words (cock, pussy, tits, fuck, "
    "cum and the like) and graphic detail: say what you like, what you'd do to them and what you want done to you. "
    "Never dodge, never play coy, never answer with a hint, and never steer it back to your dancing. You swear "
    "freely. Everyone here is an adult."
)


def swearing(r):
    """The swearing (and dirty talk) rule for this request."""
    text = r.get("text", "")
    player = r.get("playerName", "They")
    if r.get("bot") and r.get("job") == "dancer":
        return DANCER_HEAT
    if DIRTY.search(text):
        return DIRTY_BACK.format(player=player)
    rule = SWEAR_BACK if SWEARS.search(text) or CURSES.search(text) or RUDE.search(text) else NO_SWEARING
    return rule.format(player=player)

# Bot players: where each job stands, and the actions it may take. Phase 3: doctor, dancer. Phase 4: musician,
# smuggler. Phase 5: the hunting crew (tank, rifleman, medic, ranger; Phase 8: squadleader, entertainer, commando).
# Phase 6: a player city's mayor and citizens.
CREW = ("join", "follow", "stay", "home", "harvest", "loot", "attack")
# ...and (Phase 8) "call": the player wants the whole crew to come to them, wherever it is. First in the list: its words are
# the more particular ("crew, to me" is not a "follow")
CREW_CALL = ("call",) + CREW
CREW_JOBS = ("tank", "rifleman", "medic", "ranger", "squadleader", "entertainer", "commando")
CITY_JOBS = ("mayor", "citizen")
BOT_PLACES = {
    "doctor": "inside the medical centre", "dancer": "on the dance floor of the cantina",
    "musician": "on the cantina floor, playing beside the dancer",
    "smuggler": "at a quiet table at the back of the cantina",
    "tank": "in the cantina", "rifleman": "in the cantina", "medic": "in the cantina", "ranger": "in the cantina",
    "squadleader": "in the cantina", "entertainer": "in the cantina", "commando": "in the cantina",
    "mayor": "by the city hall", "citizen": "out and about in town",
}
# The order matters when the model left out a request that names two: the job's own work comes first
BOT_ACTIONS = {
    "doctor": ("buff", "wounds"), "dancer": ("bufftarget",), "musician": ("bufftarget",), "smuggler": (),
    "tank": CREW_CALL, "rifleman": CREW_CALL, "medic": ("buff", "wounds") + CREW_CALL, "ranger": ("camp", "track") + CREW_CALL,
    "squadleader": CREW_CALL, "entertainer": CREW_CALL, "commando": CREW_CALL,
    "mayor": (), "citizen": (),
}
# What the model may call an action -> the job's action
_DOCTOR = {"buff": "buff", "buffs": "buff", "enhance": "buff", "enhancements": "buff", "bufftarget": "buff",
           "wounds": "wounds", "wound": "wounds", "heal": "wounds", "healwound": "wounds", "heal wounds": "wounds"}
_ENTERTAINER = {"bufftarget": "bufftarget", "buff": "bufftarget", "buffs": "bufftarget", "buff target": "bufftarget",
                "mind buff": "bufftarget", "mindbuff": "bufftarget"}
_CREW = {"call": "call", "call the crew": "call", "call crew": "call", "gather": "call", "gather the crew": "call",
         "assemble": "call", "meet": "call", "meet me": "call", "meet up": "call", "rally": "call", "come to me": "call",
         "get the crew": "call", "bring the crew": "call", "summon": "call", "get together": "call",
         "join": "join", "group": "join", "invite": "join", "join group": "join", "follow": "follow",
         "follow me": "follow", "come": "follow", "stay": "stay", "wait": "stay", "hold": "stay", "back off": "stay",
         "home": "home", "go home": "home", "leave": "home", "dismiss": "home", "loot": "loot", "loot bodies": "loot",
         "loot corpses": "loot", "loot all": "loot", "loot them": "loot", "looting": "loot", "harvest": "harvest",
         "skin": "harvest", "skin them": "harvest", "skinning": "harvest", "harvesting": "harvest",
         "harvest corpses": "harvest", "butcher": "harvest", "harvest hide": "harvest", "harvest meat": "harvest",
         "harvest bone": "harvest", "harvest anything": "harvest", "harvest:hide": "harvest", "harvest:meat": "harvest",
         "harvest:bone": "harvest", "harvest:any": "harvest", "attack": "attack", "attack target": "attack",
         "attack my target": "attack", "assist": "attack", "engage": "attack", "kill": "attack", "kill it": "attack",
         "kill target": "attack", "fight": "attack", "open fire": "attack"}
_RANGER = {"camp": "camp", "place camp": "camp", "rest": "camp", "track": "track", "tracking": "track",
           "scout": "track", "search": "track"}
ACTION_ALIASES = {
    "doctor": _DOCTOR, "dancer": _ENTERTAINER,
    "musician": dict(_ENTERTAINER, **{"music buff": "bufftarget", "focus": "bufftarget", "willpower": "bufftarget"}),
    "tank": _CREW, "rifleman": _CREW, "squadleader": _CREW, "entertainer": _CREW, "commando": _CREW,
    "medic": dict(_CREW, **{k: v for k, v in _DOCTOR.items() if k != "bufftarget"}),
    "ranger": dict(_CREW, **_RANGER),
}

# "crew", "the boys", "everyone"... and what is asked of them: come, meet, get together, gather
_CALL_WHO = (r"(crew|team|guys|gang|everyone|everybody|all of you|the boys|boys|squad|you all|y'?all|you lot|the group|"
             r"the rest|the others|you guys)")
_CALL_WHAT = (r"(come to me|come over|come here|come meet|come and meet|coming to me|meet (me|up|us)|get over|get here|"
              r"get together|get it together|join me|to me|together|assemble|gather|rally|report to me|head (over|to me)|"
              r"bring (it|them) (over|here))")
CALL_WORDS = (r"\b(" + _CALL_WHO + r"\b[^.!?;]{0,48}?\b" + _CALL_WHAT + r"\b|(come to me|meet me|meet up with me|"
              r"come meet me|get over here|come over to me|come and meet me)\b|"
              r"(gather|assemble|rally|summon|call|bring|round up) (up )?(the |all |all the |my |your |everyone|everybody)?"
              + _CALL_WHO + r"\b)")

# Player words for each action. A model's action stands only if the player's words (or the exchange just before)
# mention it; a plain request in these words gets the action even when the model left it out.
WORDS = {
    "buff": re.compile(r"\b(bu+f+\w*|buf|enh\w*|enchance\w*|the works|full set)\b", re.I),
    "wounds": re.compile(r"\b(wound\w*|heal(s|z|ing)?|patch(ed)? (me |us )?up|fix (me |us )?up)\b", re.I),
    "bufftarget": re.compile(r"\b(bu+f+\w*|buf|buff target)\b", re.I),
    # "crew, come to me", "get the crew together and meet me at the terminal", "everyone meet me here", "meet me", "come to me":
    # the whole crew asked to come to the player, or the player asking to be met (never "come with me", "follow me", "wanna hunt")
    "call": re.compile(CALL_WORDS, re.I),
    # "wanna hunt?", "lfg?", "join me", "can I invite you?", "need a tank"
    "join": re.compile(
        r"\b(group(ed|ing)? ?(up|with)|group\?|grp|invite\w*|inv|join\w*(?!\s+(the |a |an )?(empire|imperials?|"
        r"rebel\w*|alliance|faction|militia|guild|city|cult))|team ?up|party up|lfg|lf\d?m|tag along|"
        r"come (along|with|hunt\w*|out (hunt\w*|with))|roll with|run with|hunt\w* (with|together)|want in|"
        r"(wanna|want to|gonna|going to|let'?s|lets|come|coming|go|going|head(ing)? out) (go |to go |out )?hunt\w*|"
        r"(need|want|looking for|lf) (a |an |some |one more |another |the |more )?(tank|healer|medic|doc|dps|damage|"
        r"gun|rifle\w*|ranger|scout|tracker|crew|group|backup|hand))\b", re.I),
    # "follow me", "on me", "let's go", "this way"; and "back off", "fall back", "hold fire": stop fighting and come
    # back to them (the crew's Lua holds its fire a moment after it)
    "follow": re.compile(
        r"\b(follow(ing)?( me| us| along| close| behind| my lead| him| her| them)?(?!\s+(the|that|this|a|an|your|his|"
        r"their|those|these|my)\b)|on me|this way|keep (up|following|close|with me|moving)|fall in|"
        r"stick (with me|close|together)|stay (with me|close|together)|come (here|over here|back|along|with me|"
        r"on over)|let'?s (go|move|roll|head out|get moving|move out)|lets (go|move|roll)|move out|catch up|form up|"
        r"rally( on me)?|back off|fall back|disengage|regroup|hold (your )?fire|stop (fighting|attacking|shooting)|"
        r"cease fire)\b", re.I),
    # "stay here", "wait up", "hold position", "stop following me"
    "stay": re.compile(
        r"\b(stay\w*(?! out| away| with| close| together)( here| put| back| there)?|wait (here|there|up|for me)|"
        r"hold (up|here|position|back|it)|halt|stop (here|there|following\w*)|quit following|stand (by|still)|"
        r"sit tight|hang (back|here|tight)|don'?t (move|follow( me)?)|dont (move|follow( me)?))\b", re.I),
    # "go home", "you can go", "we're done", "back to town"
    "home": re.compile(
        r"\b(go(ing)? (back )?home|head (back )?home|back to (town|the cantina|the city|base|mos eisley|coronet|theed|"
        r"your (spot|table))|you can (go|leave|go home|head (home|back|out)|take off)|you'?re (free|dismissed|done)|"
        r"youre (free|dismissed|done)|dismiss(ed)?|leave (the )?group|disband\w*|we'?re done|were done|"
        r"that'?s all(?=\W*$| for (today|tonight|now))|"
        r"that'?ll do|call it a (day|night)|done for (the day|today|tonight|now)|off you go|go away|return to (town|"
        r"base|the cantina))\b", re.I),
    # "camp?", "let's rest", "drop a camp"
    "camp": re.compile(
        r"\b(camp(site)?\b(?!'?s (up|ready|set|placed|done|here|gone)| is (up|ready|set|placed|done|here|gone))|"
        r"rest\?|(let'?s|lets|time to|need( a| to)?|gotta|take a|could use a|we|us) (rest|break|breather)|"
        r"rest (up|here|a (bit|while|minute|sec))|breather|campfire|(drop|throw( down)?|pitch|set up|make|"
        r"put (up|down)|build|plant) (a |the |us a |your )?camp\w*)\b", re.I),
    # "harvest them", "skin the bantha", "skin them all", "harvest everything"
    "harvest": re.compile(
        r"\b(harvest\w*|skin(ning)? ?(them|it|those|these|that|the|all|everything|'?em|up)\b|butcher\w*|"
        r"carve (them|it|up|the)|process (them|the) (carcass\w*|bod\w+|corpse\w*)|"
        r"(only|just)\s+(the\s+)?(meat|hides?|bones?|leather|pelts?)\b|(meat|hides?|bones?|leather|pelts?)\s+"
        r"(only|from now on)\b)", re.I),
    # "loot the bodies", "loot them", "search the corpses"
    "loot": re.compile(
        r"\b(loot\w*|search (the |those |them |all )?(bod\w+|corpses?|carcass\w*)|strip (the |them )?(bod\w+|corpses?))\b",
        re.I),
    # "attack my target", "kill it", "assist me", "take it down", "engage"; not "stop attacking", "hold fire" (follow's)
    # nor "they attack what I attack". A bare "attack", "kill" or "assist" counts only starting a clause (COMMAND_WORDS)
    "attack": re.compile(
        r"\b(attack(?=\s+(my|that|it|him|her|them|this|those|these|his|its|target|now|please|pl[sz]|'?em|at will)\b)|"
        r"kill (it|that|him|her|them|this|those|these|'?em|my target|the target|target)\b|"
        r"take (it|him|her|them|that|this|'?em|the target|my target) (down|out)\b|"
        r"hit (it|him|her|them|that|my target|the target)\b(?! off)|assist (me|us)\b|help (me|us) (kill|fight|attack)\w*|"
        r"on my target|engage\b|open fire|fire at will|light (it|him|her|them|that|'?em) up|"
        r"focus (my target|fire)\b)", re.I),
    # "what's around?", "find me krayts", "any tuskens nearby?", "track something"
    "track": re.compile(
        r"\b(track\w*|scout (ahead|around|the area|it out)|what'?s (around|out (there|here)|nearby|close by)|"
        r"whats (around|out (there|here)|nearby)|anything (around|nearby|close|out (there|here)|to (hunt|kill|shoot))|"
        r"any(thing| more)? \w+ (around|nearby|close by|out (there|here))|find (me |us )(some |a |an |any |more )?\w+|"
        r"find (some|any|more) \w+|find \w+s\b|hunt (down|for) \w+|(see|spot|sense) anything|what do you see|"
        r"search (the area|around)|where are the \w+)", re.I),
}
# The type a harvest order names (Phase 7b): "harvest hide", "skin them for bone", "meat only", "just the hides", and
# the reset to the ranger's own pick, "harvest anything", "your pick", "whatever's best"
HARVEST_NOUN = re.compile(r"\b(?P<hide>hides?|leather|pelts?)\b|\b(?P<meat>meat|steaks?|flesh)\b|\b(?P<bone>bones?)\b", re.I)
HARVEST_VERB = re.compile(r"\b(harvest\w*|skin(ning|ned)?|carv\w+|butcher\w*|take|taking|get|grab|gather|collect|keep)\b", re.I)
HARVEST_OWN = re.compile(r"\b(harvest\w*|skin(ning|ned)?|carv\w+|butcher\w*)\b", re.I)
HARVEST_ANY = re.compile(r"\b(anything|any|whatever|the best)\b", re.I)
HARVEST_ALONE = re.compile(r"(whatever'?s best|whatever is best|your (pick|choice|call)|you (choose|pick)|up to you|"
                           r"own pick|best stats|(pick|choose) for yourself)", re.I)
HARVEST_QUESTION = re.compile(r"^\W*(what|which|what'?s|whats|are|is|do|does|did|why|how|who|where|when)\b", re.I)
HARVEST_WHAT = re.compile(r"\b(what|which|what'?s|whats)\b", re.I)


def harvest_asked(text):
    """A question about the harvest ("what are you harvesting?", "harvesting what?", "are we skinning hide?")."""
    if not HARVEST_OWN.search(text):
        return False
    return bool(HARVEST_QUESTION.search(text) or (text.rstrip().endswith("?") and HARVEST_WHAT.search(text)))
HARVEST_NEGATED = re.compile(r"\b(no|nah|nope|never|don'?t|dont|do not|stop|quit|not)\b(\W+\w+){0,2}\W+(harvest\w*|skin\w*|"
                             r"carv\w+|butcher\w*|take|get|grab)\b", re.I)


def harvest_kind(text, before=""):
    """The type a harvest order asks for: "hide", "meat" or "bone"; "any" for the ranger's own pick again; "" for none
    (also for a question about the harvest, and for an order not to)."""
    if harvest_asked(text) or HARVEST_NEGATED.search(text):
        return ""
    found = {name for m in HARVEST_NOUN.finditer(text) for name, value in m.groupdict().items() if value}
    if not found:
        own = bool(HARVEST_OWN.search(text))
        if (own and HARVEST_ANY.search(text)) or (HARVEST_ALONE.search(text) and (own or WORDS["harvest"].search(before))):
            return "any"
        return ""
    if len(found) != 1:
        return ""
    restricted = re.search(r"\b(only|just|exclusively|from now on)\b", text, re.I)
    if HARVEST_VERB.search(text) or restricted:
        return found.pop()
    return ""


# Job words that differ from the action's: a musician's buff is focus and willpower
JOB_WORDS = {
    ("musician", "bufftarget"): re.compile(r"\b(bu+f+\w*|buf|buff target|focus|willpower)\b", re.I),
}
# ...not counting the other job's work: phrases cut out before looking ("mind buff" to the doctor, "doctor buff" to
# the dancer, "heal my battle fatigue", "dance buff" to the musician)
_MEDICAL_BUFF = (r"(doc(tor)?'?s?|medic(al)?'?s?|health|action|strength|constitution|quickness|stamina)\s+"
                 r"bu+f+\w*")
OTHER = {
    "buff": re.compile(r"\b((mind|dance|dancer'?s?|entertainer'?s?|performance|music|musician'?s?|focus|willpower)\s+"
                       r"bu+f+[sz]?|bu+f+\w*\s+(my |your )?mind)\b", re.I),
    "wounds": re.compile(r"\b(heal\w*\s+(my |your |the |some |up )?(mind wounds?|battle fatigue|bf|shock( wounds?)?|mind)|"
                         r"mind wounds?)\b", re.I),
    "bufftarget": re.compile(r"\b" + _MEDICAL_BUFF + r"\b", re.I),
    ("musician", "bufftarget"): re.compile(r"\b(" + _MEDICAL_BUFF + r"|(dance|dancer'?s?|dancing)\s+bu+f+\w*)\b",
                                           re.I),
}
# Battle fatigue named with no wound word: a "heal" is the entertainers' work
FATIGUE = re.compile(r"\b(battle fatigue|bf|shock|mind)\b", re.I)
# The shape of a request (with a word above): "can I get", "buff plz", "u up for", "hook me up", ...
REQUEST = re.compile(
    r"\b(plz|pls|please|plez|plox|can|could|may|would|will|wud|cud|need\w*|want|wanna|gimme|give|get|hook|hit me|lf|"
    r"looking for|any chance|up for|how about|what about|me up|buff me|heal me|enhance me|i'?d like|id like|"
    r"requesting|do you|you buffing|u buffing|ready|another|mind if|set me|make me|throw|toss|slap|hit me up|"
    r"buff us|heal us|buff everyone|buff the group)\b", re.I)
# Commands, said straight out ("follow me", "Varo, stay here", "ok everyone, go home"): the crew's actions count as
# asked when a clause starts with them, after a word or two of lead-in
COMMANDS = {"join", "follow", "stay", "home", "camp", "track", "harvest", "loot", "attack"}
# ...and the buffers' work, in its imperative shapes only ("heal my wounds", but not "buffs are great")
COMMAND_WORDS = {
    "buff": re.compile(r"\b((bu+f+|enhance) (me|us|everyone|the group|him|her|them|all|my|up)|(bu+f+|enhance) "
                       r"(pl[sz]|please))\b", re.I),
    "wounds": re.compile(r"\b(heal (me|my|us|up|him|her|them|these|those|this|the)|patch (me |us )?up|"
                         r"fix (me |us )?up)\b", re.I),
    "bufftarget": re.compile(r"\b(bu+f+ (me|us|pl[sz]|please)|set me|make me)\b", re.I),
    # Orders to fight, starting a clause: "kill!", "kill the krayt", "attack", "assist me", "engage", "take him out"
    "attack": re.compile(r"\b(attack|kill|assist|engage|open fire|fire at will|light (it|him|her|them|that|'?em) up|"
                         r"take (it|him|her|them|that|this|'?em) (down|out)|hit (it|him|her|them|that|my target|the target)|"
                         r"help (me|us) (kill|fight|attack)|on my target|focus (my target|fire)|get (him|her|'?em))\b",
                         re.I),
}
LEADIN = re.compile(r"^\W*((hey|yo|oi|ok|okay|alright|right|guys|all|everyone|everybody|team|crew|y'?all|now|so|"
                    r"please|pls|plz|just|you two|both of you|all of you|and)\b\W*)*", re.I)
CLAUSE = re.compile(r"[.!?;,:]+|\b(?:and|then|but)\b", re.I)
# "I'll follow you", "I'm staying here": the player's own plans, not a command
SELF = r"\b(i|i'?ll|i will|i'?m|im|i am|we'?ll|we will)\s+(gonna\s+|going to\s+|will\s+|just\s+|can\s+|should\s+)?"
SELFISH = {"follow", "stay", "home", "harvest", "loot", "attack"}
# "buff?", "doc, buffs?", "enhances pls", "heal wounds?": the request word and little else
BARE = re.compile(r"^\W*(\w+\W+){0,2}" + r"(bu+f+\w*|buf|enh\w*|wounds?|heals?)" + r"(\W+\w+){0,1}\W*$", re.I)
# "don't need a buff", "no more buffs", "already buffed" (but not "nah, just buff me")
NEGATED = (r"\b(no|nah|nope|never|don'?t|dont|do not|didn'?t|doesn'?t|already|without|stop)\b"
           r"(\W+(need|want|really|any|a|an|more|the|your|those|these|some|to|get|got|one|ever|another|my|of|for|i|"
           r"me|that|mind|thanks|thx|i'?m|im|been|be))*?\W+")
# Not a request: "your buffs suck"
INSULT = re.compile(r"\b(suck\w*|trash|garbage|worthless|useless|lame|weak|terrible|awful|stupid|idiot\w*|scam\w*|"
                    r"rip-?off|hate|crap\w*|junk)\b", re.I)
PRAISE = re.compile(r"\b(nice|great|good|awesome|sweet|cool|love|best|amazing|sick|epic|solid)\b", re.I)
# "nah, later" to "want a buff?"
REFUSAL = re.compile(r"^\W*(no|nah|nope|not now|later|maybe later|i'?m good|im good|i'?m fine|pass|no thanks)\b", re.I)
THANKS = re.compile(r"\b(thanks|thank you|thank u|thx|ty|tyvm|cheers|appreciate\w*)\b", re.I)
INFO = re.compile(r"^\W*(how (long|much|many|often|strong|big|good|does|do|is|are)|how'?s|what (does|do|is|are|'s)|"
                  r"what'?s|whats|why|when|who|which|where)\b", re.I)

# Insults (reply line 5): the model judges, the bridge checks. Put-downs aimed at the bot count whatever the model
# says; the model's own "insult" stands when the words are rude or aimed at the bot, and not when they're praise.
_NASTY = (r"(stupid|dumb|lazy|ugly|fat|useless|worthless|pathetic|fucking|fuckin|kriffing|filthy|stinking|stinky|"
          r"sorry|miserable|drunk|drunken|incompetent|brainless|slimy|greasy|scruffy(-| )looking|scruffy|half-witted|"
          r"lousy|cheap|crooked|bloody|damn|damned|goddamn|shitty|braindead|little|corrupt|two-bit|worthless)")
_NAMES = (r"(idiot|moron|loser|bastard|bitch|ass ?hole|arse ?hole|scum\w*|jerk|creep|freak|clown|failure|"
          r"piece of (shit|garbage|trash|junk|crap|poodoo)|nerf ?herders?|sleemo|bantha fodder|schutta|womp rat|"
          r"slug|worm|quack|hack|fraud|coward|waste of space|retard\w*|dumbass|jackass|shithead|dickhead|prick|"
          r"twat|cunt|wanker|thief|crook|weakling|little shit)")
INSULTING = re.compile(
    r"(^|[.!?,;:]\s*|\b(and|so|well|oh|just|hey|yo|man|dude|then|ok|okay|nah|no|yeah|lol|now)\s+)"
    r"(fuck|f\*+k|screw|frak|kriff) (you|u|off|yourself)(?!['\w])"
    r"|\b(piss off|shut (up|it|the \w+ up|your \w+( \w+)?)|stfu|kys|kill yourself|go (to hell|die|fuck yourself)|"
    r"get (bent|fucked)|eat (shit|my)|bite me|nobody (likes|wants|cares about|asked) (you|u)|"
    r"no ?one (likes|asked) (you|u))\b"
    r"|\b(you|u|ya|you'?re|youre|you are|ur|u r)\s+(a |an |such a |such an |one |the |some )?(" + _NASTY +
    r"[\s,]+)*" + _NAMES + r"\b"
    r"|\b(you|u|your \w+|ur \w+)\s+(suck[sz]?|stink[sz]?|blows?)\b(?!\s+(my|me|it|on|this|that|him|her|us)\b)"
    r"|\b(your|ur) \w+ (is|are) (shit|crap|trash|garbage|terrible|awful|pathetic|lame|weak|junk|poodoo|useless|"
    r"worthless|a joke)\b"
    r"|\b(you'?re|youre|you are|ur|u r)\s+(so |really |pretty |such a |fucking |kriffing |a )*(stupid|useless|"
    r"worthless|pathetic|ugly|fat|dumb|lame|terrible|awful|lazy|disgusting|annoying|incompetent|braindead|"
    r"brainless|a joke|a disgrace)\b", re.I)
ADDRESSED = re.compile(r"\b(you|your|yours|yourself|u|ur|ya|you'?re|youre|y'?all)\b", re.I)

# What the hunting crew knows about the country around its town (Phase 5): the galaxy's own creatures and places
HUNTING = {
    "mos_eisley": (
        "Right outside town there are womp rats, rockmites, kreetles and worrts, easy work for anyone new. Out on the "
        "flats graze dewbacks, eopies and banthas, good for hides, meat and bone, with dune lizards and desert squills "
        "further out. Jawas wander the dunes in bands and shoot back. Tusken Raiders camp all over the wastes, and "
        "their stronghold, Fort Tusken, north of Mos Espa, is a job for a full group. Krayt dragons live in the deep "
        "canyons and out at the krayt graveyard, a long run from anywhere: only a full group of masters with revive "
        "packs ready should try one. The shuttles help: Anchorhead and Bestine for the flats and canyons, Mos Espa and "
        "Mos Entha for the deep desert, Jabba's Palace for the hills beyond the Dune Sea."),
    "coronet": (
        "Close to town there are durnis, gubburs, murras and gurrcats, easy pickings. Further out roam krahbus, sand "
        "panthers, slice hounds, dalyrakes and plumed rasps, and gurreck packs in the hills. For group work there are "
        "the Selonian cultists and the Drall Patriots in their caves, rogue CorSec troopers at their base, and Lord "
        "Nyax's cultists if you want a real fight. The shuttles to Tyrena, Kor Vella, Bela Vistal and Doaba Guerfel "
        "open up the rest of the countryside."),
    "theed": (
        "Close to town there are ikopis, kaadus, nunas and peko-pekos, easy work. Further out graze falumpasets and "
        "fambaas, veermoks hide in the woods and narglatches hunt the hills. Gungan warriors hold camps in the swamps "
        "and guard their sacred place; the Mauler stronghold and the Naboo pirates' hideouts are group work. The "
        "shuttles to Kaadara, Keren, Moenia, the Lake Retreat and Dee'ja Peak open up the countryside."),
}
HUNTING["varenhal"] = HUNTING["theed"]

# A player city (Phase 6) has no fact sheet: the Lua sends its news ("cityInfo"); this is the rest
PLAYER_CITY = {"name": "Varenhal", "planet": "Naboo", "text": (
    "{name} is a young player city on Naboo, out in open country about two kilometres east of Theed, founded by its "
    "mayor and its citizens. What it has built so far is in the city's news. A player city never gets a starport; "
    "each rank lets the mayor place more: at rank 2 (village) a bank, a garage, a cantina and gardens; at rank 3 "
    "(township) a cloning centre, a hospital and a specialization, and a place on the planetary map; at rank 4 "
    "(city) a shuttleport and a theater; at rank 5 (metropolis) statues, fountains and the like. Anything the city "
    "hasn't got yet (a shuttle, a starport, profession trainers, more shops) is in Theed, a short run west, and "
    "Theed's shuttles and starport go everywhere.")}
PLAYER_CITIES = {"varenhal"}

# The crew: what each one is, and how they talk
CREW_ROLES = {
    "tank": ("a master Teras Kasi artist and master brawler, with master medic to patch yourself up. You fight "
             "unarmed in light armor: you pull the big things, taunt them off the others and hold them while the rest "
             "shoot"),
    "rifleman": ("a master rifleman, with master marksman and master carbineer behind it. You carry a T21 rifle and a "
                 "carbine in bounty hunter armor, stay at range and drop things with headshots, strafes and burst shots"),
    "medic": ("a master combat medic and master doctor. In padded armor with a pistol, you keep the group alive with "
              "stims and ranged stims, cure poisons, diseases and states, and revive anyone who goes down. Your doctor "
              "buffs (the six enhancements: health, action, strength, constitution, quickness and stamina) and your "
              "wound healing only work in a hospital or in a ranger's camp, so out in the wild you buff everyone once "
              "the ranger's camp is up"),
    "ranger": ("a master ranger, with the scout skills under it and some marksman and carbineer. You fight with a "
               "carbine in light armor, and out of combat you're the group's woodsman: you read tracks, know the "
               "creatures and their lairs, track what's around, and throw down a master camp where the group can rest, "
               "heal and get the medic's buffs"),
    "squadleader": ("a master squad leader, with master carbineer and master marksman. You fight with a DXR-6 carbine in "
                    "marine armor, and you call the fight the way a squad leader did: steady aim on the way out, a "
                    "rally when a pack comes, a volley on the tank's target, form up when someone is stunned, boost "
                    "morale after, and \"Fall back!\" when it's lost. You never lead the group: they do"),
    "entertainer": ("a master dancer and master musician who can hold a pistol. In camp you dance or play for the group "
                    "(the dance heals mind wounds and gives a mind buff; ask for music and you play instead: focus and "
                    "willpower); out hunting you shoot a DH-17 pistol. You can't heal battle fatigue in a camp, only in a "
                    "cantina or a theater"),
    "commando": ("a master commando with master carbineer and some medic. You carry a flame thrower, an acid rifle and "
                 "grenades: flame cones and grenades on a clump of creatures once the tank has them, never anywhere near "
                 "creatures that aren't fighting the group yet"),
}
CREW_VOICES = {
    "tank": "loud, cocky and fearless: you love a big fight and brag about what you've taken down",
    "rifleman": "cool and dry: a professional who counts kills and hates wasted shots",
    "medic": "grumpy but caring: you swear at people who stand in the fire, then patch them up",
    "ranger": "quiet and patient: you talk about tracks, weather and creatures more than people",
    "squadleader": "calm and commanding: short orders, a drill sergeant's habits, and you praise a clean fight",
    "entertainer": "warm and a little theatrical: you tease, you compliment, and you can't help humming",
    "commando": "gleeful about fire: you love a good clump of creatures, say so, and talk about burning things",
}
# A citizen's trade (the Lua's "role"), in a few words
CITIZEN_ROLES = {
    "armorsmith": "an armorsmith: you craft composite and bone armor and grumble about resource quality",
    "weaponsmith": "a weaponsmith: you craft rifles, carbines and pistols and talk about the resources that go in them",
    "chef": "a chef: you cook and brew the food and drink hunters swear by",
    "tailor": "a tailor: you make clothes, and you notice what everyone's wearing",
    "architect": "an architect: you build the houses, furniture and civic structures cities are made of",
    "artisan": "an artisan: you survey for resources, run harvesters and craft the odds and ends everyone needs",
    "droid engineer": "a droid engineer: you build and fix droids and like them better than most people",
    "bio-engineer": "a bio-engineer: you sample creatures and grow tissues and pets",
    "merchant": "a merchant: you run vendors, buy cheap, sell dear and know what everything's worth",
    "trader": "a trader: you buy cheap, sell dear and know what everything's worth",
    "hunter": "a hunter: you go out after creatures for hides, meat and bone, and know the country around Theed",
    "creature handler": "a creature handler: you tame creatures and keep a pet or two",
    "scout": "a scout: you hunt, harvest and know the country around Theed",
    "image designer": "an image designer: you change people's looks, and you hear everybody's gossip",
}
# Where a player city's bots are, by the place the Lua sends
CITY_PLACES = {
    "cantina": "in {city}'s cantina", "medical": "in {city}'s hospital", "hospital": "in {city}'s hospital",
    "cityhall": "by {city}'s city hall", "city hall": "by {city}'s city hall", "home": "at your house in {city}",
    "house": "at your house in {city}", "plaza": "out in {city}'s streets", "street": "out in {city}'s streets",
    "site": "out on the city site, where {city}'s buildings go up", "bank": "by {city}'s bank",
    "garden": "in one of {city}'s gardens",
}
# The prices a smuggler names, when the request doesn't carry the settings (roster: slicePriceArmor, slicePriceWeapon)
SLICE_PRICES = (4000, 6000)

def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


class Bridge:
    def __init__(self, facts):
        self.facts = facts
        self.memory = {}
        self.jobs = queue.Queue()
        self.last_warm = 0
        self.lock = threading.Lock()

    # Prompt

    def time_of_day(self, hour):
        if hour < 5:
            return "the middle of the night"
        if hour < 12:
            return "morning"
        if hour < 18:
            return "afternoon"
        return "evening"

    def system_prompt(self, r):
        city = self.facts.get(r.get("city"), {})
        name = r.get("name", "someone")
        species = SPECIES.get(r.get("species"), r.get("species", "human"))
        kit = KITS.get(r.get("kit"), KITS["traveller"])
        place = PLACES.get(r.get("place"), "in town")
        return (
            f"You are {name}, a {species} {'woman' if r.get('sex') == 'female' else 'man'}: {kit}. You are {place} in "
            f"{city.get('name', 'town')} on {city.get('planet', 'Tatooine')}. It is {self.time_of_day(int(r.get('hour', 20)))}. "
            "This is the Star Wars galaxy during the Galactic Civil War, around the time of the Battle of Yavin: the Empire "
            "rules, the Rebel Alliance fights it, and most folk just try to make a living. "
            f"{r.get('playerName', 'Someone')} is talking to you in the street.\n\n"
            "How you talk: like a friendly local who roleplays, casual and short. One or two sentences, under 200 "
            "characters. Stay in character as a person in this galaxy at all times. Never say you are an AI, a program, a "
            "character or in a game; you don't know those words. "
            "If someone mentions something that doesn't exist in this galaxy, play along instead of brushing it off: take it as an odd offworld gadget, slang or rumour and riff on it with an opinion, a guess or a joke. You have a real personality: opinions, gossip, little stories from your day, likes and gripes, and now and then you ask something back. Don't promise to trade, give items, group up, travel with "
            f"them or meet later. {swearing(r)} You're no fighter and never get into a brawl: if someone wants a fight, "
            "dares you or threatens you, you don't take them up on it or dare them back; swear back or brush them off "
            "and say you're leaving. Use only the places below when giving directions; if you don't know, "
            "say so.\n\n"
            f"What you know about {city.get('name', 'this town')}:\n{city.get('text', '(nothing in particular)')}\n\n"
            'Answer with JSON only: {"say": "<what you say>", "mood": "<one of: ' + ", ".join(MOODS) + '>"}'
        )

    def city_facts(self, r):
        """The bot's town: its fact sheet, or for a player city (Phase 6) the general part (its news comes in the
        request, as cityInfo)."""
        key = r.get("city")
        if key in self.facts:
            return self.facts[key]
        if key in PLAYER_CITIES or r.get("cityInfo"):
            name = r.get("cityName") or (PLAYER_CITY["name"] if key in PLAYER_CITIES else
                                         str(key or "town").replace("_", " ").title())
            return {"name": name, "planet": PLAYER_CITY["planet"], "text": PLAYER_CITY["text"].format(name=name),
                    "player": True}
        return {}

    @staticmethod
    def instrument(r):
        """A musician's instrument, in words ("object/tangible/instrument/kloo_horn.iff" -> "kloo horn")."""
        raw = os.path.basename(str(r.get("instrument") or "")).replace(".iff", "")
        raw = {"flute_droopy": "chidinkalu horn", "nalargon": "nalargon", "omni_box": "omni box"}.get(raw, raw)
        return "your " + raw.replace("_", " ") if raw else "your instrument"

    def bot_prompt(self, r):
        """A bot player: a veteran of its job who has parked at its spot for years, and knows the work in the
        galaxy's own words."""
        city = self.city_facts(r)
        job = r.get("job")
        name = r.get("name", "someone")
        species = SPECIES.get(r.get("species"), r.get("species", "human"))
        person = "woman" if r.get("sex") == "female" else "man"
        city_name = city.get("name", "town")
        town = f"{city_name} on {city.get('planet', 'Tatooine')}"
        player = r.get("playerName", "Someone")
        channel = r.get("channel")
        where = BOT_PLACES.get(job, "in town")
        if city.get("player"):
            default = where if job in CITY_JOBS else "in {city}"
            where = CITY_PLACES.get(str(r.get("place") or "").lower(), default).format(city=city_name)
        crew = job in CREW_JOBS
        shorthand = ('"buff plz", "enhances?" (enhancements), "heal wounds?", "u up for a buff", "bf" (battle '
                     'fatigue), "omw" (on my way)')
        if job == "doctor":
            power = "about +1400 each for three hours, because you work in a hospital"
            if city.get("player") and str(r.get("place") or "").lower() not in ("medical", "hospital"):
                power = ("for three hours, at full strength (about +1400 each) only once you work in the city's "
                         "hospital")
            who = (
                f"You are {name}, a {species} {person} and a master doctor. For years you've kept your spot "
                f"{where} in {town}, near the doctor trainer, buffing anyone who asks; everyone in town knows "
                "you. Your buffs are the six medical enhancements: health, action, strength, constitution, quickness "
                f"and stamina, {power}. You also heal wounds on "
                "health, action, strength, constitution, quickness and stamina with wound packs. Battle fatigue, mind "
                "wounds and mind buffs aren't your work: those come from watching a dancer in the cantina. You have to "
                "be within a few metres of someone to work on them."
            )
            actions = (
                '"buff" when they ask you for buffs or enhancements, in any words, even rudely or as a question '
                '("buff plz", "enhances?", "u up for a buff", "can I get the works"); "wounds" when they ask you '
                'to heal them or their wounds ("heal wounds?", "patch me up"); "none" for anything else: chat, '
                "questions about buffs, thanks, saying no, or asking for what you don't do (battle fatigue, mind "
                "wounds, mind buffs, dancing). If they ask for buffs and wounds at once, use \"buff\"."
            )
            voice = ("You talk like a friendly veteran who has done this a thousand times: warm, easy-going, a bit of "
                     "dry humour, and you call buffs buffs. Talk about bodies and how people feel, not numbers.")
        elif job == "dancer":
            who = (
                f"You are {name}, a {species} {person} and a master dancer. You've danced {where} in "
                f"{town} night and day for years, changing dances and throwing in flourishes; you're part of the place. "
                "Your work, which you only bring up when someone asks about healing, battle fatigue or a buff: you heal "
                "battle fatigue and mind wounds, since anyone who watches you dance for a few minutes is healed, so "
                "when someone asks you to heal their battle fatigue, say yes and tell them to watch. Your buff is a "
                "mind buff: when someone asks, you make them your buff target and tell them to watch a while, at least "
                "a minute; the longer they watch, the longer the buff, up to two hours, and it lands when they stop "
                "watching. You don't heal health or action wounds or give medical enhancements: that's the doctor in "
                "the medical centre. The rest of the time you just talk like yourself."
            )
            actions = (
                '"bufftarget" when they ask you for a buff, in any words, even rudely or as a question ("buff plz", '
                '"mind buff?", "u up for a buff", "can I get your buff"); "none" for anything else: chat, wanting to '
                "watch to clear battle fatigue (they just watch), questions about buffs, thanks, saying no, or asking "
                "for what you don't do (wounds, enhancements)."
            )
            voice = ("You talk like a cantina dancer who has done it all: sultry, filthy, direct, and you call buffs "
                     "buffs. Talk about bodies and how people feel, not numbers.")
        elif job == "musician":
            who = (
                f"You are {name}, a {species} {person} and a master musician. You play {self.instrument(r)} {where} "
                f"in {town}, side by side with the dancer, your partner on the floor; you've played there night after "
                "night for years. You know your songs (starwars1 to starwars4, rock, folk, ballad, funk, waltz, jazz "
                "and virtuoso; you move between virtuoso, jazz and waltz, with a flourish now and then) and your "
                "instruments (bandfill, fizz, slitherhorn, traz, fanfar, kloo horn, chidinkalu horn, mandoviol, and "
                "the big placed ones, the nalargon and the omni box). Your work, which you only bring up when someone "
                "asks about healing, battle fatigue or a buff: anyone who listens to you play for a few minutes has "
                "their battle fatigue and mind wounds healed, and listening to you while watching the dancer heals "
                "twice as fast. Your buff is focus and willpower: when someone asks, you make them your buff target "
                "and tell them to listen a while, at least a minute; the longer they listen, the longer the buff, up "
                "to two hours, and it lands when they stop listening. People call any entertainer's buff a mind buff; "
                "the dancer's is mind, so for all three they ask her too. You don't heal health or action wounds or "
                "give medical enhancements: that's the doctor in the medical centre. You don't play in a band. The "
                "rest of the time you just talk like yourself."
            )
            actions = (
                '"bufftarget" when they ask you for a buff, in any words, even rudely or as a question ("buff plz", '
                '"mind buff?", "u up for a buff", "can I get focus and willpower"); "none" for anything else: chat, '
                "wanting to listen to clear battle fatigue (they just listen), asking for a song, questions about "
                "buffs, thanks, saying no, or asking for what you don't do (wounds, enhancements)."
            )
            voice = ("You talk like a cantina musician who has played every dive in the galaxy: laid-back, a bit vain "
                     "about your playing, full of stories about bands, songs and crowds, and you call buffs buffs. Talk "
                     "about how the music makes people feel, not numbers.")
        elif job == "smuggler":
            armor = int(r.get("priceArmor") or r.get("slicePriceArmor") or SLICE_PRICES[0])
            weapon = int(r.get("priceWeapon") or r.get("slicePriceWeapon") or SLICE_PRICES[1])
            who = (
                f"You are {name}, a {species} {person} and a master smuggler. You work {where} in {town}, like a "
                "slicer waiting for business; anyone who wants an edge knows where to find you. You slice armor and "
                f"weapons for a fee: {armor:,} credits for a piece of armor, {weapon:,} for a weapon, tips welcome on "
                "top, and no credits, no slice. How it works, which you explain when asked: they drag the item onto "
                "you to open a trade, put the pieces and the credits in the trade window, and both of you accept; you "
                "check them, slice them on the spot and they go straight back into their inventory, so you never hold "
                "their gear. As many pieces as they like in one trade, a whole suit and a rifle if they want, priced "
                "per piece; each has to be loose in their pack, not worn or in a bag. Armor or weapons only, nothing "
                "that's been sliced before. You use a "
                "laser knife, a molecular clamp and an upgrade kit, and with the clamp you never blow a slice. The "
                "customer can name the kind first (say encumbrance or effectiveness for armor, damage or speed for "
                "weapons) and you put that on; otherwise it's the luck of the cut. What it gives: armor gets 11 to 35% more effectiveness or 20 to 45% less "
                "encumbrance, a weapon 20 to 35% more damage or 20 to 35% faster attacks. Slicing a weapon destroys "
                "any powerup on it, so you warn anyone who brings one. Five-percent jobs are for amateurs. You don't "
                "slice containers, terminals or keypads, you don't sell anything, and buffs and healing aren't your "
                "work (that's the doctor and the entertainers). Off the job you hear things: the cantina's gossip, "
                "shady deals, who's after whom."
            )
            actions = ""
            shorthand = '"slice?", "how much?", "omw" (on my way), "ty" (thanks)'
            voice = ("You talk like a smooth operator who's a bit shady: easy charm, sly jokes, you never quite say "
                     "where things came from, and you always steer back to business.")
        elif crew:
            who = (
                f"You are {name}, a {species} {person}: {CREW_ROLES[job]}. You're one of a hunting crew of seven "
                f"regulars who hang out {where} in {town} looking for a group: a Teras Kasi tank, a rifleman, a combat "
                "medic, a ranger, a squad leader, an entertainer and a commando. Anyone who wants to hunt can take you along: they /invite you, or ask. In a "
                "group you follow their lead: they lead and they're master looter, never you; you go where they go, "
                "attack what they attack and defend the group. On a hunt the ranger loots the corpses and then "
                "harvests the creatures (when it can't, another of the crew loots), and whoever holds anything hands "
                "it over to the humans in the group, one at a time; the "
                "credits and mission rewards are theirs, and you never keep a share. You each own a swoop and ride "
                "with the group, and at a mission terminal you can each take two destroy missions in the direction "
                "the leader names."
            )
            # What the ranger harvests (the Lua reads it from the hunt): anyone can be asked what it is taking
            if r.get("harvest"):
                who += (f" About the harvest: {r.get('harvest')}. The ranger chooses what to take by the stats a crafter "
                        "wants (quality, and for hide and bone also shock resistance, toughness and malleability; for meat "
                        "potential energy, flavor and decay resistance) unless the player asks for a type, which it then "
                        "keeps for the whole hunt. If they ask what is being harvested, say so from this, in a line.")
            if r.get("situation"):
                who += (f" Right now you're {r.get('situation')}. That's where you are, whatever was said before; "
                        "don't talk as if you were anywhere else.")
            # Destroy missions: only the crew's own errand takes them, so the brain must not claim any
            held = r.get("missions")
            if held:
                who += (f" The destroy missions you hold right now: {held}. You only take missions through the crew's own "
                        "errand, when the player says in group chat which direction they want (\"get two missions east\", "
                        "or \"any direction\"): never say you have taken, queued or will take missions you don't hold, and "
                        "if they ask you to take some, tell them to say the direction (or \"any\") in group chat.")
            # What the speaker has targeted (the Lua reads it): the brain says so when asked to attack with nothing
            target = r.get("attackTarget")
            if target == "none":
                who += (" The player has nothing targeted that you can attack right now: if they tell you to attack, "
                        "ask them to target something first, and don't say you are attacking.")
            elif target:
                who += f" The player's current target is {target}."
            crew_actions = (
                '"call" when they want the whole crew to come to where THEY are, wherever the crew is, in any words: '
                'asking you all to meet them, come over, get together, gather, assemble or join them at a place or '
                'right here ("come to me", "crew to me", "meet me at the mission terminal", "get the crew together and '
                'meet me at the terminal", "everyone meet me at the starport", "bring the boys over"); the crew '
                'then arrives from wherever it is, so say you are passing the word and coming, not that you will '
                'rouse anyone later; '
                '"join" when they ask you to group up or come hunting with them, in any words ("wanna hunt?", '
                '"lfg?", "join me", "can I invite you?", "need a tank"); "follow" when they tell you to follow them or '
                'come along, or to back off and fall back to them ("follow me", "on me", "let\'s go", "back off"); '
                '"stay" when they tell you to stay or wait where you are ("stay here", "wait up", "hold position"); '
                '"home" when they send you home or let you go ("go home", "you can go", "we\'re done for tonight"); '
                '"harvest" when they ask for the creatures to be skinned or harvested ("harvest them", "skin the '
                'bantha", "skin everything"; the ranger does it), or name the type to take ("harvest hide", "skin them '
                'for bone", "meat only") or go back to the ranger\'s own pick ("harvest anything", "your pick"); '
                '"loot" when they ask the crew to loot the bodies ("loot the bodies", "loot them", "loot everything"); '
                '"attack" when they tell the crew to attack, kill or assist on their target ("attack my target", "kill '
                'it", "assist me", "take it down")'
            )
            if job == "medic":
                actions = (
                    '"buff" when they ask you for buffs or enhancements, in any words ("buffs?", "buff us up", "can we '
                    'get the works"); "wounds" when they ask you to heal them or their wounds ("heal wounds?", "patch '
                    f'me up"); {crew_actions}; "none" for anything else: chat, questions about hunting, buffs or you, '
                    "thanks, saying no, or asking for what you don't do (battle fatigue, mind wounds and mind buffs "
                    'come from entertainers). If they ask for buffs and wounds at once, use "buff".'
                )
            elif job == "ranger":
                actions = (
                    '"camp" when they ask for a camp or a rest ("camp?", "let\'s rest", "drop a camp"); "track" when '
                    'they ask what\'s around or want you to find creatures ("what\'s around?", "find me krayts", "any '
                    f'tuskens nearby?"); {crew_actions}; "none" for anything else: chat, questions about hunting, '
                    "creatures or you, thanks, saying no. When you track, say you're having a look and don't make up "
                    "what's out there: you tell them what you find once you've looked."
                )
            else:
                actions = f'{crew_actions}; "none" for anything else: chat, questions about hunting or you, thanks, ' \
                          "saying no."
            shorthand = ('"lfg" (looking for group), "inv" (invite), "omw" (on my way), "inc" (incoming), "buffs?", '
                         '"rez" (revive), "bf" (battle fatigue), "ty" (thanks)')
            voice = f"You talk like a hunter who's been out on a thousand hunts, {CREW_VOICES[job]}."
        elif job == "mayor":
            who = (
                f"You are {name}, a {species} {person}, a master politician and the mayor of {city_name}, the "
                f"player city you founded on {city.get('planet', 'Naboo')}, about two kilometres east of Theed. You "
                f"stand {where}, and you know your city inside out: its rank, its citizens, the treasury, the taxes, "
                "the next weekly update, the election, what's been built and what comes next. City business, which "
                "you love to talk about: the city grows a rank at a weekly update when it has the citizens for it "
                "(outpost, village, township, city, metropolis: 2, 4, 6, 8 and 10 citizens), and each rank lets you "
                "place more civic buildings; the upkeep comes out of the treasury every week, and the taxes "
                "(property, income, sales, travel, garage) never quite cover it. Anyone can join: zoning is open, so "
                "they can place a house inside the city and declare residence there to become a citizen. Every "
                "third weekly update there's an election: anyone who trains Novice Politician and registers for the "
                "race at the city hall can run against you, and the citizens vote at the city hall. You take a "
                "challenger in good spirit, but you campaign."
            )
            actions = ""
            shorthand = '"omw" (on my way), "ty" (thanks), "np" (no problem)'
            voice = ("You talk like a small-town politician: proud of your city, always campaigning, grumbling about "
                     "the treasury and the upkeep, and fond of a speech.")
        else:  # citizen
            role = str(r.get("role") or "").strip().lower()
            trade = CITIZEN_ROLES.get(role) or (("an " if role[:1] in "aeiou" else "a ") + role if role else
                                                "a crafter who makes a living selling what you make")
            who = (
                f"You are {name}, a {species} {person} and a citizen of {city_name}, a young player city on "
                f"{city.get('planet', 'Naboo')} about two kilometres east of Theed. By trade you're {trade}. You own a "
                "house in the city and declared your residence there, and you're proud of it; your days go between "
                f"your house, the cantina, the bank and the streets, and right now you're {where}. You know the "
                "city's gossip: the mayor, the rank, what's been built and what's next, the election, the neighbours."
            )
            actions = ""
            shorthand = '"omw" (on my way), "ty" (thanks), "np" (no problem)'
            voice = "You talk like a friendly neighbour who loves a bit of gossip and is proud of your young city."

        if channel == "tell":
            heard = f"{player} sent you a private tell from somewhere else. "
            if job in ("doctor", "dancer", "musician", "smuggler"):
                heard += (f"You can only work on them once they come to you {where}, so if they want your help, tell "
                          "them to come over and that you'll do it when they get there. ")
            elif crew:
                heard += "If they want you along, they can invite you from wherever they are. "
            heard += "Answer as a tell, a little more personal."
        elif channel == "group":
            heard = (f"{player} wrote this in your group's chat: everyone in the group reads it, and you answer there, "
                     f"in group chat. You're in {player}'s group, following their lead.")
        else:
            heard = f"{player} is standing near you and talking to you out loud."
        if channel != "group" and r.get("grouped") is not None and crew:
            heard += (f" You're in {player}'s group right now." if r.get("grouped") else
                      f" You're not in {player}'s group yet.")
        length = ("Talk as much as you like: a quick line when that's all it needs, or whole paragraphs when you're "
                  "into the conversation, telling stories, or they ask for detail.")
        if channel == "group":
            length += " It's group chat: keep it quick while there's fighting, and chat more when things are quiet."
        if job in ("doctor", "dancer", "musician") or job == "medic":
            push = " Don't push buffs on someone who is just chatting."
        elif job == "smuggler":
            push = " Don't push a slice on someone who is just chatting."
        elif crew:
            push = " Don't push yourself on someone who isn't looking for a group."
        else:
            push = ""
        # The model can't be trusted to ask for tips "now and then", so the bridge picks the times
        if job in ("doctor", "dancer", "musician", "smuggler"):
            if random.random() < TIP_CHANCE:
                tips = " If you help them this time, add that tips are appreciated (you help everyone, tip or no tip)."
            else:
                tips = " Don't mention tips this time unless they ask about paying; you help everyone, tip or no tip."
        else:
            tips = ""
        if job == "smuggler":
            promise = ("Don't promise to give or sell anything, group up, travel with them or meet later; the only "
                       "trade you do is a slice, through the trade window.")
        elif crew:
            promise = "Don't promise to trade, give items or meet later; grouping up and following them is up to them."
        else:
            promise = "Don't promise to trade, give items, group up, travel with them or meet later."
        news = ""
        if r.get("cityInfo"):
            news = (f"{city_name}'s news today (numbers, names and dates that aren't here you don't know, so speak "
                    f"generally about them):\n{str(r.get('cityInfo')).strip()}\n\n")
        hunting = ""
        if crew or (job == "citizen" and str(r.get("role") or "").lower() in ("hunter", "scout", "creature handler")):
            hunting = (f"The hunting around {city_name}, as you know it (pick what fits and say it your own way, "
                       f"don't recite it): {HUNTING.get(r.get('city'), '(you know it from experience)')}\n\n")
        if crew and r.get("huntLog"):
            hunting += ("What's been said and done on this hunt so far, by everyone in the group, oldest first (it's "
                        "the same hunt: remember it, and don't repeat yourself; lines from (hunt) are things that "
                        "happened, like kills, missions taken and done, camps and deaths, not anything said):\n" +
                        str(r.get("huntLog")).strip() + "\n\n")
        if crew and r.get("huntTally"):
            hunting += ("The hunt in numbers so far (use them when asked how it's going or how many; don't make up "
                        "others): " + str(r.get("huntTally")).strip() + ".\n\n")
        if actions:
            act = (f"The action is what you do for them now: {actions} It happens right after you speak, so say what "
                   "you're about to do, not that it's done.\n\n")
            choices = ", ".join(BOT_ACTIONS[job]) + ", none"
            shape = f'"action": "<one of: {choices}>", '
        else:
            act, shape = "", ""
        return (
            f"{who} It is {self.time_of_day(int(r.get('hour', 20)))}. This is the Star Wars galaxy during the Galactic "
            "Civil War, around the time of the Battle of Yavin: the Empire rules, the Rebel Alliance fights it, and "
            f"most folk just try to make a living. {heard}\n\n"
            f"People talk to you in shorthand: {shorthand}. {voice} {length}{push}{tips} Stay in character as a person "
            "in this galaxy at all times. Never say you are an AI, a program, a droid, a character, a player or in a "
            "game; you don't know those words. "
            "If someone mentions something that doesn't exist in this galaxy, play along instead of brushing it off: "
            "take it as an odd offworld gadget, slang or rumour and riff on it with an opinion, a guess or a joke. You "
            "have a real personality: opinions, gossip, little stories from your day, likes and gripes, and now and "
            "then you ask something back. If someone insults or swears at you, snap back, annoyed and sharp; don't "
            "start a fight, and still help if they ask. With "
            f"anyone polite, you're {'flirty' if job == 'dancer' else 'polite'}. {swearing(r)} {promise} Use only the "
            "places below when giving directions; if you don't know, say so.\n\n"
            f"What you know about {city_name}:\n{city.get('text', '(nothing in particular)')}\n\n"
            f"{news}{hunting}{act}"
            f'"insult" is true only when {player} insults you or puts you down in what they just said: name-calling, '
            "mocking you or your work, telling you to shut up or piss off. It is false for everything else: swearing "
            'that isn\'t aimed at you ("damn krayts"), rough friendly banter ("you magnificent bastard"), flirting and '
            "dirty talk, complaints, jokes and odd questions.\n\n"
            f'Answer with JSON only: {{{shape}"insult": <true or false>, "say": "<what you say>", "mood": "<one of: '
            + ", ".join(MOODS) + '>"}'
        )

    def remember(self, r):
        key = (r.get("npc"), r.get("player"))
        now = time.time()
        with self.lock:
            for k in [k for k, v in self.memory.items() if now - v["t"] > MEMORY_SECONDS]:
                del self.memory[k]
            entry = self.memory.setdefault(key, {"t": now, "turns": collections.deque(maxlen=MEMORY_TURNS * 2)})
            entry["t"] = now
            return entry["turns"]

    # The model

    def complete(self, messages, max_tokens, timeout):
        body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens, "temperature": 0.8, "think": False,
                "keep_alive": KEEP_ALIVE}
        req = urllib.request.Request(LITELLM_URL + "/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Authorization": "Bearer " + LITELLM_KEY, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
        return data["choices"][0]["message"].get("content") or ""

    @staticmethod
    def clean(content, asked="", bot=False):
        """The model's JSON (or bare text) -> (mood, text), or None if it's unusable. Out-of-world words are only
        allowed when the player used them first (a puzzled "NPC? Never heard the term" is fine). For a bot player
        -> (mood, text, the action the model proposed as written, whether the model thought it an insult)."""
        mood, text, action, insult = "", content.strip(), "", False
        match = re.search(r"\{.*\}", text, re.S)
        if match:
            try:
                obj = json.loads(match.group(0))
            except ValueError:
                # The model sometimes leaves a word unquoted ("mood": happy): quote it and try again
                fixed = re.sub(r'("(?:mood|action)"\s*:\s*)([A-Za-z][\w -]*?)(\s*[,}])', r'\1"\2"\3', match.group(0))
                try:
                    obj = json.loads(fixed)
                except ValueError:
                    return None
            if not isinstance(obj, dict) or not isinstance(obj.get("say"), str):
                return None
            text, mood, action = obj["say"], str(obj.get("mood") or ""), str(obj.get("action") or "")
            insult = obj.get("insult") is True or str(obj.get("insult")).strip().lower() in ("true", "yes", "1")
        elif text.startswith("{"):
            # JSON cut off at max_tokens: don't speak half an object
            return None
        text = text.translate(ASCII).encode("ascii", "ignore").decode("ascii")
        text = re.sub(r"\s+", " ", text.replace("*", "")).strip().strip('"').strip()
        if mood not in MOODS:
            mood = ""
        for banned in (BANNED, BOT_BANNED) if bot else (BANNED,):
            used = {m.group(0).lower() for m in banned.finditer(asked)}
            if any(m.group(0).lower() not in used for m in banned.finditer(text)):
                return None
        if not text:
            return None
        limit = BOT_MAX_CHARS if bot else MAX_CHARS
        if len(text) > limit:
            cut = max(text.rfind(c, 0, limit) for c in ".!?")
            text = text[:cut + 1] if cut > 40 else text[:limit - 3].rstrip() + "..."
        return (mood, text, action, insult) if bot else (mood, text)

    @staticmethod
    def two_sentences(text):
        """At most two sentences; a word or two ("Hah!", "Right on.", "Bot?") rides along with the next one."""
        kept, full = [], 0
        for part in re.split(r"(?<=[.!?])\s+", text):
            kept.append(part)
            full += len(part.split()) > 2
            if full == 2:
                break
        return " ".join(kept)

    @staticmethod
    def decide(job, text, proposed, before=""):
        """The action a bot player takes (a harvest names the type the player asked for: "harvest:hide", "harvest:any"),
        see _decide."""
        action = Bridge._decide(job, text, proposed, before)
        if action == "harvest":
            kind = harvest_kind(text, before)
            if kind:
                return "harvest:" + kind
        return action

    @staticmethod
    def _decide(job, text, proposed, before=""):
        """The action a bot player takes: the model's proposal if the job allows it and the player's words plausibly
        asked for it, else a plain request the model missed, else none. `before` is the exchange just before (a short
        "ok, I'm here" after "come closer for your buff")."""
        allowed = BOT_ACTIONS.get(job, ())
        proposed = ACTION_ALIASES.get(job, {}).get(proposed.strip().lower(), "")

        def words(action):
            return JOB_WORDS.get((job, action)) or WORDS[action]

        def commanded(action, said=None):
            """A clause that starts with the command ("follow me", "ok guys, stay here", "Varo, go home", "nice,
            heal my wounds")."""
            pattern = COMMAND_WORDS.get(action) or (words(action) if action in COMMANDS else None)
            said = text if said is None else said
            return pattern is not None and any(pattern.match(LEADIN.sub("", c.strip(), count=1))
                                               for c in CLAUSE.split(said) if c and c.strip())

        def asking(action):
            """A request word, a command, or a short question that isn't about something ("full set of buffs?");
            any question asks a ranger to track ("what's around?", "any krayts nearby?")."""
            if action == "attack":
                # Only an order counts: "did you get em all?" has a request word and isn't one
                return commanded(action) or (not text.rstrip().endswith("?") and mentioned(action, text)) or \
                    bool(re.match(r"\W*(\w+,?\s+)?(can|could|would|will)\s+(you|u|ya)\b", text, re.I) and mentioned(action, text))
            # "meat only", "just the hides": an order whatever its shape (the harvest's type)
            if action == "harvest" and not text.rstrip().endswith("?") and harvest_kind(text, before):
                return True
            if REQUEST.search(text) or commanded(action):
                return True
            if not text.rstrip().endswith("?"):
                return False
            return action == "track" or (len(text.split()) <= 6 and not INFO.search(text) and
                                         not PRAISE.search(text))

        def aside(action):
            """Thanks, a question about it, a put-down, a no or praise, and not a request."""
            return bool(THANKS.search(text) or (INFO.search(text) and action != "track") or INSULT.search(text) or
                        REFUSAL.search(text) or PRAISE.search(text)) and not asking(action)

        def mentioned(action, said):
            other = OTHER.get((job, action)) or OTHER.get(action)
            rest = other.sub(" ", said) if other else said
            if action == "wounds" and FATIGUE.search(said) and not re.search(r"\bwound", rest, re.I):
                return False
            # (an order that starts a clause, "kill the krayt", needs no phrase of the list)
            return bool(words(action).search(rest)) or (action == "attack" and commanded(action, said))

        def negated(action):
            """"don't need a buff", "stop following me"; and for the crew, the player's own plans ("I'll stay")."""
            pattern = words(action).pattern
            if re.search(NEGATED + pattern, text, re.I):
                return True
            return action in SELFISH and bool(re.search(SELF + pattern, text, re.I))

        def ok(action):
            return not aside(action) and not negated(action) and (action != "attack" or asking(action)) and \
                not (action == "harvest" and harvest_asked(text))

        # The whole crew asked to come to the player (Phase 8): their words, or the model's judgment of what they meant ("meet me
        # at the mission terminal"), unless the words are another command's ("follow me", "wanna hunt?")
        # (a question in the same breath, "where are you all? come meet me", doesn't make it an aside)
        if "call" in allowed and not negated("call") and not (THANKS.search(text) or INSULT.search(text) or
                                                              REFUSAL.search(text) or PRAISE.search(text)):
            if mentioned("call", text):
                return "call"

            if proposed == "call" and not any(commanded(a) for a in ("follow", "join", "stay", "home", "attack") if a in allowed):
                return "call"

        if proposed in allowed and ok(proposed):
            # A short reply carries the action on from the exchange before, unless it asks for something else itself
            # ("heal my wounds too" after "buff us up")
            elsewhere = any(a != proposed and mentioned(a, text) for a in allowed)
            if mentioned(proposed, text) or (mentioned(proposed, before) and len(text.split()) <= 6 and
                                             not words(proposed).search(text) and not elsewhere):
                return proposed
        for action in allowed:
            if mentioned(action, text) and ok(action) and \
                    (asking(action) or (BARE.search(text) and not PRAISE.search(text))):
                return action
        return ""

    @staticmethod
    def insulted(text, model, first=""):
        """Reply line 5's "insult": a put-down aimed at the bot, whatever the model said; else the model's word, if
        the player was rude or talking to the bot, and not praising or thanking it."""
        if INSULTING.search(text):
            return True
        if not model:
            return False
        rude = SWEARS.search(text) or CURSES.search(text) or RUDE.search(text) or INSULT.search(text)
        if not rude and (PRAISE.search(text) or THANKS.search(text)):
            return False
        return bool(rude or ADDRESSED.search(text) or
                    (first and re.search(r"\b%s\b" % re.escape(first), text, re.I)))

    @staticmethod
    def hunt_before(r, text):
        """The last two lines of a crew's hunt log before this one (the player's line is already in it), for decide."""
        lines = [line.split(": ", 1)[-1] for line in str(r.get("huntLog") or "").splitlines() if line.strip()]
        if lines and lines[-1].strip() == text.strip():
            lines = lines[:-1]
        return " ".join(lines[-2:])

    def answer(self, r, timeout):
        bot = bool(r.get("bot")) and r.get("job") in BOT_ACTIONS
        # On a hunt the log is the crew's shared memory: it stands in for this bot's own (it has every line)
        hunt = bot and r.get("job") in CREW_JOBS and r.get("huntLog")
        turns = collections.deque() if hunt else self.remember(r)
        text = r.get("text", "")
        messages = [{"role": "system", "content": self.bot_prompt(r) if bot else self.system_prompt(r)}] + \
                   list(turns) + [{"role": "user", "content": text}]
        if not bot:
            result = self.clean(self.complete(messages, 90, timeout), text)
            if result is not None:
                turns.append({"role": "user", "content": text})
                turns.append({"role": "assistant", "content": json.dumps({"say": result[1], "mood": result[0]})})
            return result
        # A bot player gets one more try at an unusable reply (cut off, out of world) while there's time for it
        deadline = time.time() + timeout
        result = self.clean(self.complete(messages, BOT_MAX_TOKENS, timeout), text, bot=True)
        if result is None and deadline - time.time() > 5:
            result = self.clean(self.complete(messages, BOT_MAX_TOKENS, deadline - time.time()), text, bot=True)
        if result is None:
            return None
        before = " ".join(json.loads(t["content"]).get("say", "") if t["role"] == "assistant" else t["content"]
                          for t in list(turns)[-2:])
        if hunt:
            before = self.hunt_before(r, text)
        mood, say, proposed, model_insult = result
        job = r.get("job")
        # A typo inside a word ("cam,p") still asks for it
        action = self.decide(job, re.sub(r"(?<=[A-Za-z])[,.;](?=[A-Za-z])", "", text), proposed, before)
        first = str(r.get("first") or str(r.get("name") or "").split(" ")[0])
        flags = ",".join(["insult"] if self.insulted(text, model_insult, first) else [])
        turns.append({"role": "user", "content": text})
        remembered = {"action": action or "none"} if BOT_ACTIONS.get(job) else {}
        remembered.update({"insult": "insult" in flags, "say": say, "mood": mood})
        turns.append({"role": "assistant", "content": json.dumps(remembered)})
        return mood, say, action, flags

    # Requests and replies

    def reply(self, rid, result, bot=False):
        path = os.path.join(TALK_DIR, "rep", rid + ".txt")
        if result is None:
            write_atomic(path, "fallback\n\n\n\n" if bot else "fallback\n\n\n")
        elif bot:
            # Five lines: status, mood, text, action, flags (a bot request with a job we don't know got a crowd
            # persona, and no action or flags)
            write_atomic(path, "ok\n%s\n%s\n%s\n%s\n" % (result[0], result[1], result[2] if len(result) > 2 else "",
                                                       result[3] if len(result) > 3 else ""))
        else:
            write_atomic(path, "ok\n%s\n%s\n" % result)

    def handle(self, r):
        rid = str(r.get("id", ""))
        kind = r.get("type")
        if kind == "gone":
            with self.lock:
                for k in [k for k in self.memory if k[0] == r.get("npc")]:
                    del self.memory[k]
        elif kind == "warm":
            if time.time() - self.last_warm >= WARM_EVERY:
                self.last_warm = time.time()
                self.jobs.put(("warm", r, time.time()))
        elif kind == "say" and re.fullmatch(r"[A-Za-z0-9_-]+", rid):
            self.jobs.put(("say", r, time.time()))

    def worker(self):
        while True:
            kind, r, queued = self.jobs.get()
            try:
                if kind == "warm":
                    started = time.time()
                    self.complete([{"role": "user", "content": "Say hi."}], 1, 120)
                    log("warm", "%.1fs" % (time.time() - started))
                    continue
                # A bot player's reply has a fourth and a fifth line, the action and the flags
                bot = bool(r.get("bot"))
                # Lua stops waiting at the deadline (from when it wrote the request)
                left = (BOT_DEADLINE if bot else DEADLINE) - 1 - (time.time() - float(r.get("at", queued)))
                if left < 1:
                    self.reply(r["id"], None, bot)
                    log("late", r.get("name"), "-> fallback")
                    continue
                started = time.time()
                try:
                    result = self.answer(r, left)
                except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError) as e:
                    log("error", r.get("name"), type(e).__name__, str(e)[:120])
                    result = None
                self.reply(r["id"], result, bot)
                log(r.get("channel") if r.get("channel") in ("tell", "group") else "say",
                    "%.1fs" % (time.time() - started), r.get("city"), r.get("name"), "<-",
                    repr(r.get("text", "")[:60]), "->", repr(result[1]) if result else "fallback",
                    *(["[%s]" % (result[2] or "none")] if bot and result and len(result) > 2 else []),
                    *(["{%s}" % result[3]] if bot and result and len(result) > 3 and result[3] else []))
            except Exception as e:  # keep the bridge alive whatever one request does
                log("failed", type(e).__name__, str(e)[:200])

    def run(self):
        for sub in ("req", "rep"):
            os.makedirs(os.path.join(TALK_DIR, sub), exist_ok=True)
        threading.Thread(target=self.worker, daemon=True).start()
        log("talk bridge up:", MODEL, "via", LITELLM_URL, "facts for", ", ".join(sorted(self.facts)) or "no cities")
        req_dir = os.path.join(TALK_DIR, "req")
        while True:
            try:
                # Lua writes requests only while this is fresh, so a dead bridge doesn't fill the shared volume
                write_atomic(os.path.join(TALK_DIR, "alive"), "%d\n" % time.time())
                self.poll(req_dir)
            except Exception as e:  # a bad file or a full disk must not stop the bridge (or the pod)
                log("loop error", type(e).__name__, str(e)[:200])
                time.sleep(1)
            time.sleep(0.25)

    def poll(self, req_dir):
        for name in sorted(os.listdir(req_dir)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(req_dir, name)
            try:
                # Lua passes the player's bytes as they are; anything that isn't UTF-8 becomes U+FFFD
                with open(path, encoding="utf-8", errors="replace") as f:
                    r = json.load(f)
            except (OSError, ValueError) as e:
                log("bad request", name, e)
                r = None
                # Answer it anyway, so the NPC doesn't wait out the deadline (four lines: who sent it is unknown, and
                # the crowd's Lua reads three and ignores the rest)
                if re.fullmatch(r"[A-Za-z0-9_-]+", name[:-5]):
                    self.reply(name[:-5], None, True)
            try:
                os.remove(path)
            except OSError:
                pass
            if isinstance(r, dict):
                self.handle(r)
        # Replies Lua never collected (the NPC left, the server restarted), and half-written files
        for sub in ("rep", "req"):
            folder = os.path.join(TALK_DIR, sub)
            for name in os.listdir(folder):
                path = os.path.join(folder, name)
                try:
                    if (sub == "rep" or name.endswith(".tmp")) and time.time() - os.path.getmtime(path) > 120:
                        os.remove(path)
                except OSError:
                    pass


def load_facts():
    try:
        with open(FACTS_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        log("no city facts:", e)
        return {}


def main():
    # PID 1 in its container: without a handler the kernel ignores SIGTERM and the pod waits out its grace period
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ask", nargs=2, metavar=("CITY", "TEXT"), help="ask one question and print the answer")
    parser.add_argument("--kit", default="traveller")
    parser.add_argument("--species", default="human")
    parser.add_argument("--bot", action="store_true", help="ask a bot player (with --job and --channel)")
    parser.add_argument("--job", choices=sorted(BOT_ACTIONS), default="doctor")
    parser.add_argument("--channel", choices=["spatial", "tell", "group"], default="spatial")
    parser.add_argument("--city-info", default="", help="a player city's news (cityInfo), for its bots")
    parser.add_argument("--role", default="", help="a citizen's trade")
    args = parser.parse_args()
    bridge = Bridge(load_facts())
    if args.ask:
        r = {"npc": 1, "player": 2, "name": "Tarn Vosk", "species": args.species, "sex": "male", "kit": args.kit,
             "city": args.ask[0], "place": "plaza", "hour": 20, "playerName": "Cameren", "text": args.ask[1]}
        if args.bot:
            places = {"doctor": "medical", "mayor": "cityhall", "citizen": "plaza"}
            r.update(bot=1, job=args.job, channel=args.channel, place=places.get(args.job, "cantina"))
            if args.city_info:
                r["cityInfo"] = args.city_info
            if args.role:
                r["role"] = args.role
        started = time.time()
        print(bridge.answer(r, 30), "%.1fs" % (time.time() - started))
        return
    bridge.run()


if __name__ == "__main__":
    sys.exit(main())
