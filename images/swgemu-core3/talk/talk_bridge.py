#!/usr/bin/env python3
"""Living Cities talk bridge: lets Core3's player-looking NPCs answer players through LiteLLM.

Core3's Lua can't make network calls without stalling a server thread, so it talks to this process through files on a
shared directory (an emptyDir in the core3 pod):

  req/<id>.json   written by Lua (temp file, then rename): {"type": "say" | "gone" | "warm", ...}
  rep/<id>.txt    written here (temp file, then rename), read and removed by Lua:
                    line 1: "ok" or "fallback"; line 2: a mood (may be empty); line 3: what the NPC says;
                    line 4 (bot players only): the action, "buff", "wounds", "bufftarget" or empty
  alive           the time, rewritten 4 times a second; Lua sends nothing when it is over a minute old

"say" carries the NPC's persona (name, species, sex, kit, city, place), the player's name and what they said; the
reply comes from the model with the NPC's city fact sheet and the last exchanges between the two. "gone" drops an
NPC's memory (it logged out). "warm" keeps the model loaded while players are near a crowd, so the first question
doesn't wait for Ollama to load it.

Bot players (Phase 3) send "say" with "bot": 1, "job" ("doctor" or "dancer") and "channel" ("spatial" or "tell").
They get a veteran's persona for their job, and the reply carries an action. The model proposes it; the bridge only
lets through actions the job allows, and only when the player's words plausibly asked for it, and adds it when the
model forgot a plain request ("buff plz"). Crowd replies stay three lines.

Standard library only. Settings come from the environment:
  TALK_DIR (/run/talk), LITELLM_URL (http://litellm.litellm.svc:4000/v1), LITELLM_KEY, TALK_MODEL (vm/qwen3.8:27b),
  TALK_FACTS (/opt/swgemu/talk/facts.json), TALK_DEADLINE (seconds Lua waits for a reply, 12)

  python3 talk_bridge.py                       # run
  python3 talk_bridge.py --ask mos_eisley "where's the bank?"   # one question from the command line, for testing
  python3 talk_bridge.py --ask mos_eisley "buff plz" --bot --job doctor --channel tell   # the same, to a bot player
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

# Exchanges remembered per NPC and player, and for how long
MEMORY_TURNS = 8
MEMORY_SECONDS = 4 * 3600
# Keep the model loaded this long after the last "warm" or question
KEEP_ALIVE = "15m"
WARM_EVERY = 240
MAX_CHARS = 200
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

# Bot players (Phase 3): where each job stands, and the actions it may take
BOT_PLACES = {"doctor": "inside the medical centre", "dancer": "on the dance floor of the cantina"}
BOT_ACTIONS = {"doctor": ("buff", "wounds"), "dancer": ("bufftarget",)}
# What the model may call an action -> the job's action
ACTION_ALIASES = {
    "doctor": {"buff": "buff", "buffs": "buff", "enhance": "buff", "enhancements": "buff", "bufftarget": "buff",
               "wounds": "wounds", "wound": "wounds", "heal": "wounds", "healwound": "wounds", "heal wounds": "wounds"},
    "dancer": {"bufftarget": "bufftarget", "buff": "bufftarget", "buffs": "bufftarget", "buff target": "bufftarget",
               "mind buff": "bufftarget", "mindbuff": "bufftarget"},
}

# Player words for each action. A model's action stands only if the player's words (or the exchange just before)
# mention it; a plain request in these words gets the action even when the model left it out.
WORDS = {
    "buff": re.compile(r"\b(bu+f+\w*|buf|enh\w*|enchance\w*|the works|full set)\b", re.I),
    "wounds": re.compile(r"\b(wound\w*|heal(s|z|ing)?|patch(ed)? (me )?up|fix (me )?up)\b", re.I),
    "bufftarget": re.compile(r"\b(bu+f+\w*|buf|buff target)\b", re.I),
}
# ...not counting the other job's work: phrases cut out before looking ("mind buff" to the doctor, "doctor buff" to
# the dancer, "heal my battle fatigue")
OTHER = {
    "buff": re.compile(r"\b((mind|dance|dancer'?s?|entertainer'?s?|performance|music)\s+bu+f+[sz]?|bu+f+\w*\s+(my |your )?"
                       r"mind)\b", re.I),
    "wounds": re.compile(r"\b(heal\w*\s+(my |your |the |some |up )?(mind wounds?|battle fatigue|bf|shock( wounds?)?|mind)|"
                         r"mind wounds?)\b", re.I),
    "bufftarget": re.compile(r"\b(doc(tor)?'?s?|medic(al)?|health|action|strength|constitution|quickness|stamina)\s+"
                             r"bu+f+\w*\b", re.I),
}
# Battle fatigue named with no wound word: a "heal" is the dancer's work
FATIGUE = re.compile(r"\b(battle fatigue|bf|shock|mind)\b", re.I)
# The shape of a request (with a word above): "can I get", "buff plz", "u up for", "hook me up", ...
REQUEST = re.compile(
    r"\b(plz|pls|please|plez|plox|can|could|may|would|will|wud|cud|need\w*|want|wanna|gimme|give|get|hook|hit me|lf|"
    r"looking for|any chance|up for|how about|what about|me up|buff me|heal me|enhance me|i'?d like|id like|"
    r"requesting|do you|you buffing|u buffing|ready|another|mind if|set me|make me|throw|toss|slap|hit me up)\b", re.I)
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
INFO = re.compile(r"^\W*(how (long|much|many|often|strong|big|good|does|do|is|are)|what (does|do|is|are|'s)|whats|"
                  r"why|when|who|which|where)\b", re.I)


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
            f"them or meet later. {swearing(r)} Use only the places below when giving directions; if you don't know, "
            "say so.\n\n"
            f"What you know about {city.get('name', 'this town')}:\n{city.get('text', '(nothing in particular)')}\n\n"
            'Answer with JSON only: {"say": "<what you say>", "mood": "<one of: ' + ", ".join(MOODS) + '>"}'
        )

    def bot_prompt(self, r):
        """A bot player: a veteran of its job who has parked at its spot for years, and knows the work in the
        galaxy's own words."""
        city = self.facts.get(r.get("city"), {})
        job = r.get("job")
        name = r.get("name", "someone")
        species = SPECIES.get(r.get("species"), r.get("species", "human"))
        person = "woman" if r.get("sex") == "female" else "man"
        town = f"{city.get('name', 'town')} on {city.get('planet', 'Tatooine')}"
        player = r.get("playerName", "Someone")
        if job == "doctor":
            who = (
                f"You are {name}, a {species} {person} and a master doctor. For years you've kept your spot "
                f"{BOT_PLACES[job]} in {town}, near the doctor trainer, buffing anyone who asks; everyone in town knows "
                "you. Your buffs are the six medical enhancements: health, action, strength, constitution, quickness "
                "and stamina, about +1400 each for three hours, because you work in a hospital. You also heal wounds on "
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
            choices = "buff, wounds, none"
        else:
            who = (
                f"You are {name}, a {species} {person} and a master dancer. You've danced {BOT_PLACES[job]} in "
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
            choices = "bufftarget, none"
        if r.get("channel") == "tell":
            heard = (f"{player} sent you a private tell from somewhere else in town. You can only work on them once "
                     f"they come to you {BOT_PLACES[job]}, so if they want your help, tell them to come over and that "
                     "you'll do it when they get there. Answer as a tell, a little more personal.")
        else:
            heard = f"{player} is standing near you and talking to you out loud."
        if job == "dancer":
            voice = ("You talk like a cantina dancer who has done it all: sultry, filthy, direct, and you call buffs "
                     "buffs. Talk about bodies and how people feel, not numbers.")
        else:
            voice = ("You talk like a friendly veteran who has done this a thousand times: warm, easy-going, a bit of "
                     "dry humour, and you call buffs buffs. Talk about bodies and how people feel, not numbers.")
        # The model can't be trusted to ask for tips "now and then", so the bridge picks the times
        if random.random() < TIP_CHANCE:
            tips = "If you help them this time, add that tips are appreciated (you help everyone, tip or no tip)."
        else:
            tips = "Don't mention tips this time unless they ask about paying; you help everyone, tip or no tip."
        return (
            f"{who} It is {self.time_of_day(int(r.get('hour', 20)))}. This is the Star Wars galaxy during the Galactic "
            "Civil War, around the time of the Battle of Yavin: the Empire rules, the Rebel Alliance fights it, and "
            f"most folk just try to make a living. {heard}\n\n"
            "People talk to you in shorthand: \"buff plz\", \"enhances?\" (enhancements), \"heal wounds?\", \"u up "
            "for a buff\", \"bf\" (battle fatigue), \"omw\" (on my way). " + voice + " Say one or two "
            "short sentences, never more, under 150 characters in all. Don't push buffs on someone who is just "
            f"chatting. {tips} Stay in character as a person in this galaxy at all times. Never say you are an AI, a "
            "program, a droid, a character, a player or in a game; you don't know those words. "
            "If someone mentions something that doesn't exist in this galaxy, play along instead of brushing it off: take it as an odd offworld gadget, slang or rumour and riff on it with an opinion, a guess or a joke. You have a real personality: opinions, gossip, little stories from your day, likes and gripes, and now and then you ask something back. If someone insults or "
            "swears at you, snap back, annoyed and sharp; don't start a fight, and still help if they ask. With "
            f"anyone polite, you're {'flirty' if job == 'dancer' else 'polite'}. {swearing(r)} Don't promise to trade, give items, group up, travel with them "
            "or meet later. Use only the places below when giving directions; if you don't know, say so.\n\n"
            f"What you know about {city.get('name', 'this town')}:\n{city.get('text', '(nothing in particular)')}\n\n"
            f"The action is what you do for them now: {actions} It happens right after you speak, so say what "
            "you're about to do, not that it's done.\n\n"
            f'Answer with JSON only: {{"action": "<one of: {choices}>", "say": "<what you say>", "mood": "<one of: '
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
        -> (mood, text, the action the model proposed, as written)."""
        mood, text, action = "", content.strip(), ""
        match = re.search(r"\{.*\}", text, re.S)
        if match:
            try:
                obj = json.loads(match.group(0))
            except ValueError:
                return None
            if not isinstance(obj, dict) or not isinstance(obj.get("say"), str):
                return None
            text, mood, action = obj["say"], str(obj.get("mood") or ""), str(obj.get("action") or "")
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
        if bot:
            text = Bridge.two_sentences(text)
        if len(text) > MAX_CHARS:
            cut = max(text.rfind(c, 0, MAX_CHARS) for c in ".!?")
            text = text[:cut + 1] if cut > 40 else text[:MAX_CHARS - 3].rstrip() + "..."
        return (mood, text, action) if bot else (mood, text)

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
        """The action a bot player takes: the model's proposal if the job allows it and the player's words plausibly
        asked for it, else a plain request the model missed, else none. `before` is the exchange just before (a short
        "ok, I'm here" after "come closer for your buff")."""
        allowed = BOT_ACTIONS.get(job, ())
        proposed = ACTION_ALIASES.get(job, {}).get(proposed.strip().lower(), "")
        # A request word, or a short question that isn't about something ("full set of buffs?")
        asking = bool(REQUEST.search(text)) or (text.rstrip().endswith("?") and len(text.split()) <= 6 and
                                                 not INFO.search(text) and not PRAISE.search(text))
        aside = (THANKS.search(text) or INFO.search(text) or INSULT.search(text) or REFUSAL.search(text)) and not asking

        def mentioned(action, words):
            rest = OTHER[action].sub(" ", words)
            if action == "wounds" and FATIGUE.search(words) and not re.search(r"\bwound", rest, re.I):
                return False
            return bool(WORDS[action].search(rest))

        def negated(action):
            return re.search(NEGATED + WORDS[action].pattern, text, re.I)

        if proposed in allowed and not aside and not negated(proposed):
            if mentioned(proposed, text) or (mentioned(proposed, before) and len(text.split()) <= 6 and
                                             not WORDS[proposed].search(text)):
                return proposed
        for action in allowed:
            if mentioned(action, text) and not negated(action) and not aside and \
                    (asking or (BARE.search(text) and not PRAISE.search(text))):
                return action
        return ""

    def answer(self, r, timeout):
        bot = bool(r.get("bot")) and r.get("job") in BOT_ACTIONS
        turns = self.remember(r)
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
        result = self.clean(self.complete(messages, 120, timeout), text, bot=True)
        if result is None and deadline - time.time() > 5:
            result = self.clean(self.complete(messages, 120, deadline - time.time()), text, bot=True)
        if result is None:
            return None
        before = " ".join(json.loads(t["content"]).get("say", "") if t["role"] == "assistant" else t["content"]
                          for t in list(turns)[-2:])
        mood, say, proposed = result
        action = self.decide(r.get("job"), text, proposed, before)
        turns.append({"role": "user", "content": text})
        turns.append({"role": "assistant", "content": json.dumps({"action": action or "none", "say": say, "mood": mood})})
        return mood, say, action

    # Requests and replies

    def reply(self, rid, result, bot=False):
        path = os.path.join(TALK_DIR, "rep", rid + ".txt")
        if result is None:
            write_atomic(path, "fallback\n\n\n\n" if bot else "fallback\n\n\n")
        elif bot:
            # (a bot request with a job we don't know got a crowd persona, and no action)
            write_atomic(path, "ok\n%s\n%s\n%s\n" % (result[0], result[1], result[2] if len(result) > 2 else ""))
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
                # A bot player's reply has a fourth line, the action
                bot = bool(r.get("bot"))
                # Lua stops waiting at the deadline (from when it wrote the request)
                left = DEADLINE - 1 - (time.time() - float(r.get("at", queued)))
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
                log("tell" if r.get("channel") == "tell" else "say", "%.1fs" % (time.time() - started), r.get("city"),
                    r.get("name"), "<-", repr(r.get("text", "")[:60]), "->", repr(result[1]) if result else "fallback",
                    *(["[%s]" % (result[2] or "none")] if bot and result and len(result) > 2 else []))
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
    parser.add_argument("--channel", choices=["spatial", "tell"], default="spatial")
    args = parser.parse_args()
    bridge = Bridge(load_facts())
    if args.ask:
        r = {"npc": 1, "player": 2, "name": "Tarn Vosk", "species": args.species, "sex": "male", "kit": args.kit,
             "city": args.ask[0], "place": "plaza", "hour": 20, "playerName": "Cameren", "text": args.ask[1]}
        if args.bot:
            r.update(bot=1, job=args.job, channel=args.channel, place="medical" if args.job == "doctor" else "cantina")
        started = time.time()
        print(bridge.answer(r, 30), "%.1fs" % (time.time() - started))
        return
    bridge.run()


if __name__ == "__main__":
    sys.exit(main())
