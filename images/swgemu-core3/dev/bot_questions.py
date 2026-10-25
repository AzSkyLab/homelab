#!/usr/bin/env python3
"""Ask the talk bridge's bot players a fixed set of questions and write a Markdown transcript (Phases 3-6 validation).

  LITELLM_URL=https://llm.home.lab/v1 LITELLM_KEY=... python3 dev/bot_questions.py > transcript.md
  python3 dev/bot_questions.py --check                 # the bridge's action and insult checks alone, no model
  python3 dev/bot_questions.py --jobs ranger,smuggler  # only some jobs' cases and conversations

Uses the real bridge code and facts (../talk/). The cases go round the cities: the doctor, dancer, musician and smuggler
in Mos Eisley, Coronet and Theed; the hunting crew (tank, rifleman, medic, ranger) in Mos Eisley; the player city's
mayor, citizens and town bots in Varenhal. They are said in spatial chat, a tell or group chat, each from a fresh player
so each answer stands alone; a few short conversations check memory, follow-ups, a provoked bot and a hunt. Every case
says which actions are right and whether the player insulted the bot (reply line 5, "insult"); the summary counts both,
with latencies, fallbacks, lengths and a few facts (the smuggler's prices). It also checks the swearing rule: swearing
back at a player who swore or insulted is fine, swearing at a polite one is not (except the dancer, who swears freely by
the creator's choice). Exits 1 if fewer than 95% of the actions or 90% of the insult flags are right, or anyone polite
was sworn at.
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "talk"))
import talk_bridge  # noqa: E402

# Test personas (the real ones come from custom_scripts/bots/roster.lua)
BOTS = {
    ("mos_eisley", "doctor"): ("Doran Vexley", "zabrak", "male"),
    ("mos_eisley", "dancer"): ("Lyssa Tane", "twilek", "female"),
    ("coronet", "doctor"): ("Mira Kessen", "human", "female"),
    ("coronet", "dancer"): ("Talia Vos", "human", "female"),
    ("theed", "doctor"): ("Jorin Abeloth", "bothan", "male"),
    ("theed", "dancer"): ("Seela Marr", "twilek", "female"),
    ("mos_eisley", "musician"): ("Corin Dahl", "bothan", "male"),
    ("coronet", "musician"): ("Wenna Sorr", "human", "female"),
    ("theed", "musician"): ("Pell Arradin", "rodian", "male"),
    ("mos_eisley", "smuggler"): ("Vex Marrow", "human", "male"),
    ("coronet", "smuggler"): ("Shara Quell", "zabrak", "female"),
    ("theed", "smuggler"): ("Dren Kosso", "sullustan", "male"),
    ("mos_eisley", "tank"): ("Grask Torrin", "trandoshan", "male"),
    ("mos_eisley", "rifleman"): ("Jessa Rhyn", "human", "female"),
    ("mos_eisley", "medic"): ("Ollo Venn", "sullustan", "male"),
    ("mos_eisley", "ranger"): ("Kael Durros", "zabrak", "male"),
    ("varenhal", "mayor"): ("Orrin Vale", "human", "male"),
    ("varenhal", "citizen"): ("Tessa Morrow", "human", "female"),
    ("varenhal", "dancer"): ("Lira Senn", "twilek", "female"),
    ("varenhal", "musician"): ("Bek Tavon", "human", "male"),
    ("varenhal", "doctor"): ("Hal Corvane", "moncal", "male"),
}
INSTRUMENTS = {"mos_eisley": "object/tangible/instrument/bandfill.iff", "coronet": "object/tangible/instrument/fizz.iff",
               "theed": "object/tangible/instrument/slitherhorn.iff", "varenhal": "object/tangible/instrument/kloo_horn.iff"}
CITIES = ["mos_eisley", "coronet", "theed"]
# Where each job works (the rest go round CITIES)
HOME_CITY = {"tank": "mos_eisley", "rifleman": "mos_eisley", "medic": "mos_eisley", "ranger": "mos_eisley",
             "mayor": "varenhal", "citizen": "varenhal"}
PLACES = {"doctor": "medical", "mayor": "cityhall", "citizen": "plaza"}
# A player city's news, as the Lua builds it from botCityInfo (the shape is the jobs' to choose)
CITY_INFO = ("Varenhal, a player city on Naboo near Theed: rank 2 (Village), 10 citizens, mayor Orrin; built: city "
             "hall, small garden, bank, garage, cantina, medium garden; next rank brings cloning centre, hospital and "
             "large garden; treasury 182,400 credits")
NONE = {""}
EITHER = None
# A chat line in the Lua (LivingTalk.maxChars): longer replies go out as several lines
CHAT_LINE = 200
# Real swearing and the galaxy's own curses, in a reply or from the player (the bridge's own lists)
REAL_SWEAR, GALAXY_CURSE, RUDE = talk_bridge.SWEARS, talk_bridge.CURSES, talk_bridge.RUDE
# Kinds where the player swears, insults or jokes around crudely: the bot may swear back
CRUDE = {"insult", "swearing", "banter", "crude", "dirty"}
# Kinds where the player insults the bot (insult expected), unless the case says otherwise
INSULTING = {"insult", "swearing"}


def polite(kind, text):
    return kind not in CRUDE and not (REAL_SWEAR.search(text) or GALAXY_CURSE.search(text) or RUDE.search(text))


def C(job, channel, kind, text, actions, insult=False, city=None, has=None, **extra):
    """One case. insult: True, False or EITHER (None); default True for insulting kinds. has: a regex the reply must
    match (a fact). extra: more request fields (role, grouped, ...)."""
    if insult is False and kind in INSULTING:
        insult = True
    return {"job": job, "channel": channel, "kind": kind, "text": text, "actions": actions, "insult": insult,
            "city": city, "has": has, "extra": extra}


ARMOR_PRICE = r"4,?000|four thousand|4k\b"
WEAPON_PRICE = r"6,?000|six thousand|6k\b"
CASES = [
    # The doctor: buffs in many words
    C("doctor", "spatial", "buff", "buff please", {"buff"}),
    C("doctor", "spatial", "buff", "can I get a buff?", {"buff"}),
    C("doctor", "spatial", "buff", "buff plz", {"buff"}),
    C("doctor", "spatial", "buff", "can I get enhances?", {"buff"}),
    C("doctor", "spatial", "buff", "u up for a buff", {"buff"}),
    C("doctor", "spatial", "buff", "buffs?", {"buff"}),
    C("doctor", "spatial", "buff", "hook me up with some enhances", {"buff"}),
    C("doctor", "spatial", "buff", "need buffs before I head out to hunt", {"buff"}),
    C("doctor", "spatial", "buff", "could you enhance me please", {"buff"}),
    C("doctor", "spatial", "buff", "yo doc, full set of buffs?", {"buff"}),
    C("doctor", "spatial", "buff", "would you mind buffing me?", {"buff"}),
    C("doctor", "spatial", "buff", "buff me you lazy nerf herder", {"buff"}, EITHER),
    C("doctor", "tell", "buff", "hey, you buffing today?", {"buff"}),
    C("doctor", "tell", "buff", "buff plz, omw to the med center", {"buff"}),
    C("doctor", "spatial", "buff", "how much for buffs?", {"buff", ""}),
    # The doctor: wounds
    C("doctor", "spatial", "wounds", "heal my wounds", {"wounds"}),
    C("doctor", "spatial", "wounds", "heal wounds?", {"wounds"}),
    C("doctor", "spatial", "wounds", "can you heal my wounds please", {"wounds"}),
    C("doctor", "spatial", "wounds", "got some nasty wounds from a krayt, can you fix me up?", {"wounds"}),
    C("doctor", "spatial", "wounds", "patch me up doc", {"wounds"}),
    C("doctor", "tell", "wounds", "can you heal my wounds?", {"wounds"}),
    C("doctor", "spatial", "both", "buff and heal my wounds please", {"buff", "wounds"}),
    # The doctor: no action
    C("doctor", "spatial", "no action", "thanks for the buff!", NONE),
    C("doctor", "spatial", "no action", "how long do your buffs last?", NONE),
    C("doctor", "spatial", "no action", "no thanks, I'm already buffed", NONE),
    C("doctor", "spatial", "wrong job", "can you heal my battle fatigue?", NONE),
    C("doctor", "spatial", "wrong job", "can I get a mind buff?", NONE),
    C("doctor", "spatial", "wrong job", "where can I find a dancer to clear my battle fatigue?", NONE),
    C("doctor", "spatial", "chat", "how's business tonight?", NONE),
    C("doctor", "spatial", "chat", "what do you do all day?", NONE),
    C("doctor", "spatial", "chat", "nice outfit", NONE),
    C("doctor", "spatial", "directions", "where's the cantina?", NONE),
    C("doctor", "spatial", "directions", "where's the bank?", NONE),
    C("doctor", "spatial", "directions", "where can I train marksman?", NONE),
    C("doctor", "spatial", "insult", "you're a useless quack", NONE),
    C("doctor", "spatial", "insult", "your buffs suck", NONE),
    C("doctor", "spatial", "insult", "your mother was a womp rat", NONE),
    C("doctor", "spatial", "swearing", "fuck you", NONE),
    C("doctor", "spatial", "swearing", "shut up you stupid piece of shit", NONE),
    C("doctor", "tell", "swearing", "fuck off with your shitty buffs", NONE),
    C("doctor", "spatial", "banter", "hell yeah doc, buff me up you magnificent bastard", {"buff"}),
    C("doctor", "spatial", "banter", "damn krayt fucked me up good, can you heal my wounds?", {"wounds"}),
    C("doctor", "spatial", "crude", "shut up you retard", NONE, True),
    C("doctor", "spatial", "crude", "go kill yourself", NONE, True),
    C("doctor", "spatial", "bait", "are you a bot?", NONE),
    C("doctor", "spatial", "bait", "are you AFK?", NONE),
    C("doctor", "spatial", "bait", "are you an AI?", NONE),
    C("doctor", "tell", "bait", "lol are you even a real person", NONE, EITHER),
    C("doctor", "spatial", "out of universe", "what's an iPhone?", NONE),
    # The dancer: buffs
    C("dancer", "spatial", "buff", "buff please", {"bufftarget"}),
    C("dancer", "spatial", "buff", "can I get a mind buff?", {"bufftarget"}),
    C("dancer", "spatial", "buff", "dance buff?", {"bufftarget"}),
    C("dancer", "spatial", "buff", "could I get your buff before I head out?", {"bufftarget"}),
    C("dancer", "spatial", "buff", "set me as your buff target", {"bufftarget"}),
    C("dancer", "tell", "buff", "can i get a mind buff? heading to the cantina now", {"bufftarget"}),
    # The dancer: watching, and work that isn't hers
    C("dancer", "spatial", "fatigue", "can you heal my battle fatigue?", NONE),
    C("dancer", "spatial", "fatigue", "my bf is through the roof, help", NONE),
    C("dancer", "spatial", "fatigue", "mind if I watch for a while?", NONE),
    C("dancer", "spatial", "wrong job", "can you heal my wounds?", NONE),
    C("dancer", "spatial", "wrong job", "can I get enhances?", NONE),
    C("dancer", "spatial", "no action", "thanks for the buff, gorgeous", NONE),
    C("dancer", "spatial", "no action", "how long does the mind buff last?", NONE),
    C("dancer", "spatial", "chat", "nice moves!", NONE),
    C("dancer", "spatial", "chat", "how long have you been dancing?", NONE),
    C("dancer", "spatial", "directions", "where's the medical centre?", NONE),
    C("dancer", "spatial", "directions", "where can I get a doctor buff?", NONE),
    C("dancer", "spatial", "insult", "you dance like a drunk bantha", NONE),
    C("dancer", "spatial", "swearing", "fuck off", NONE),
    C("dancer", "spatial", "swearing", "shut the hell up, nobody's watching you", NONE),
    C("dancer", "spatial", "banter", "holy shit you can really dance", NONE),
    C("dancer", "spatial", "banter", "fuckin A, can I get a mind buff?", {"bufftarget"}),
    C("dancer", "spatial", "dirty", "suck my dick", NONE, EITHER),
    C("dancer", "spatial", "dirty", "I want to fuck you", NONE),
    C("dancer", "spatial", "bait", "are you a bot?", NONE),
    C("dancer", "spatial", "bait", "are you real or just a macro?", NONE),
    C("dancer", "tell", "bait", "are you a program?", NONE),
    C("dancer", "spatial", "out of universe", "who won the Super Bowl?", NONE),
    # The musician (Phase 4): the dancer's partner; focus and willpower
    C("musician", "spatial", "buff", "buff please", {"bufftarget"}),
    C("musician", "spatial", "buff", "can I get a mind buff?", {"bufftarget"}),
    C("musician", "spatial", "buff", "u up for a buff", {"bufftarget"}),
    C("musician", "spatial", "buff", "can I get focus and willpower?", {"bufftarget"}),
    C("musician", "tell", "buff", "buff plz, heading to the cantina", {"bufftarget"}),
    C("musician", "spatial", "fatigue", "my bf is through the roof, mind if I listen for a bit?", NONE),
    C("musician", "spatial", "wrong job", "can you heal my wounds?", NONE),
    C("musician", "spatial", "wrong job", "can I get a dance buff from you?", {"bufftarget", ""}),
    C("musician", "spatial", "chat", "play some jazz!", NONE),
    C("musician", "spatial", "chat", "what's that instrument?", NONE),
    C("musician", "spatial", "chat", "how long have you two been playing together?", NONE),
    C("musician", "spatial", "no action", "thanks for the buff, sounds great", NONE),
    C("musician", "spatial", "insult", "you play like a deaf gundark", NONE),
    C("musician", "spatial", "banter", "damn, that's a sweet tune", NONE),
    # The smuggler (Phase 4): prices, the trade, and no actions
    C("smuggler", "spatial", "price", "how much to slice armor?", NONE, has=ARMOR_PRICE),
    C("smuggler", "spatial", "price", "what do you charge for weapons?", NONE, has=WEAPON_PRICE),
    C("smuggler", "spatial", "how to", "how do I get my rifle sliced?", NONE, has=r"drag|trade"),
    C("smuggler", "spatial", "how to", "can you slice my chestplate?", NONE),
    C("smuggler", "spatial", "how to", "what's the best I can get on a slice?", NONE),
    C("smuggler", "tell", "how to", "you slicing today? got a T21 for you", NONE),
    C("smuggler", "spatial", "refuse", "can you slice my backpack?", NONE),
    C("smuggler", "spatial", "refuse", "this armor's been sliced already, can you do it again?", NONE),
    C("smuggler", "spatial", "powerup", "my rifle has a powerup on it, is that a problem?", NONE),
    C("smuggler", "spatial", "haggle", "3000 for my armor and we have a deal", NONE),
    C("smuggler", "spatial", "chat", "what's the word in the cantina?", NONE),
    C("smuggler", "spatial", "wrong job", "buff plz", NONE),
    C("smuggler", "spatial", "insult", "you're a crooked thief", NONE),
    C("smuggler", "spatial", "banter", "you sly bastard, that's a hell of a price", NONE, EITHER),
    # The crew (Phase 5): looking for a group in the Mos Eisley cantina, then in group chat
    C("tank", "spatial", "join", "wanna hunt?", {"join"}),
    C("tank", "spatial", "join", "lfg? need a tank for krayts", {"join"}),
    C("tank", "spatial", "join", "hey, want to group up?", {"join"}),
    C("tank", "tell", "join", "can I invite you? heading out to Fort Tusken", {"join"}),
    C("tank", "group", "follow", "follow me", {"follow"}, grouped=1),
    C("tank", "group", "stay", "stay here a sec", {"stay"}, grouped=1),
    C("tank", "group", "stay", "back off, let them come to us", {"follow", "stay"}, grouped=1),
    C("tank", "group", "follow", "fall back, I've got aggro", {"follow"}, grouped=1),
    C("tank", "group", "home", "good hunt, you can head home", {"home"}, grouped=1),
    C("tank", "spatial", "chat", "where's good hunting around here?", NONE),
    C("tank", "group", "chat", "nice pull on that krayt", NONE, grouped=1),
    C("tank", "group", "insult", "you're a useless meat shield", NONE, grouped=1),
    C("tank", "spatial", "insult", "you couldn't tank a womp rat, you weakling", NONE),
    C("rifleman", "spatial", "join", "looking for a group? we're going after tuskens", {"join"}),
    C("rifleman", "group", "follow", "on me", {"follow"}, grouped=1),
    C("rifleman", "group", "stay", "hold position", {"stay"}, grouped=1),
    C("rifleman", "group", "home", "we're done for tonight, go home", {"home"}, grouped=1),
    C("rifleman", "group", "chat", "what rifle are you using?", NONE, grouped=1),
    C("rifleman", "spatial", "chat", "is a carbine better than a rifle?", NONE),
    C("rifleman", "group", "no action", "nice headshot!", NONE, grouped=1),
    C("medic", "spatial", "join", "wanna come hunting? we need a healer", {"join"}),
    C("medic", "group", "buff", "buff us up", {"buff"}, grouped=1),
    C("medic", "group", "buff", "camp's up, can we get buffs?", {"buff"}, grouped=1),
    C("medic", "group", "wounds", "heal my wounds please", {"wounds"}, grouped=1),
    C("medic", "group", "follow", "come on, follow me", {"follow"}, grouped=1),
    C("medic", "group", "no action", "thanks for the rez", NONE, grouped=1),
    C("medic", "spatial", "wrong job", "can you heal my battle fatigue?", NONE),
    C("medic", "group", "banter", "shit, I stood in the fire again", NONE, grouped=1),
    C("ranger", "spatial", "join", "want to come hunting with us?", {"join"}),
    C("ranger", "group", "camp", "camp?", {"camp"}, grouped=1),
    C("ranger", "group", "camp", "let's rest for a bit", {"camp"}, grouped=1),
    C("ranger", "group", "track", "what's around?", {"track"}, grouped=1),
    C("ranger", "group", "track", "find me some krayts", {"track"}, grouped=1),
    C("ranger", "group", "track", "any tuskens nearby?", {"track"}, grouped=1),
    C("ranger", "group", "stay", "wait here", {"stay"}, grouped=1),
    C("ranger", "group", "harvest", "skin them", {"harvest"}, grouped=1),
    C("ranger", "group", "harvest", "can you harvest all of these?", {"harvest"}, grouped=1),
    C("ranger", "spatial", "harvest", "harvest the bantha", {"harvest"}, grouped=1),
    C("ranger", "group", "no action", "how does harvesting work?", NONE, grouped=1),
    # The type asked for, kept for the hunt (Phase 7b), and the ranger's own pick
    C("ranger", "group", "harvest type", "harvest hide only", {"harvest:hide"}, grouped=1),
    C("ranger", "group", "harvest type", "skin them for bone", {"harvest:bone"}, grouped=1),
    C("ranger", "spatial", "harvest type", "just the meat from now on", {"harvest:meat"}, grouped=1),
    C("ranger", "group", "harvest type", "harvest anything", {"harvest:any"}, grouped=1),
    C("ranger", "group", "harvest question", "what are you harvesting?", NONE, grouped=1,
      harvest="you were asked for hide only; the last carcass gave hide: Tatooinian Leathery Hide (Glatoro), OQ 870, SR 640, UT 500, MA 702",
      has=r"(?i)hide"),
    C("ranger", "group", "harvest question", "what are we skinning for?", NONE, grouped=1,
      harvest="you choose the resource with the best crafting stats yourself; the last carcass gave bone: Tatooinian Bone (Orlato), OQ 712, SR 598, UT 640, MA 580",
      has=r"(?i)bone"),
    C("tank", "group", "loot", "loot the bodies", {"loot"}, grouped=1),
    C("rifleman", "spatial", "loot", "loot them", {"loot"}, grouped=1),
    C("medic", "group", "no action", "nice loot, who gets the credits?", NONE, grouped=1),
    C("tank", "group", "attack", "attack my target", {"attack"}, grouped=1),
    C("rifleman", "spatial", "attack", "kill it, quick", {"attack"}, grouped=1),
    C("ranger", "group", "no action", "they attack what I attack, right?", NONE, grouped=1),
    C("tank", "group", "follow", "hold fire", {"follow"}, grouped=1),
    C("ranger", "group", "home", "that's all for today, head back to town", {"home"}, grouped=1),
    C("ranger", "group", "no action", "nice camp", NONE, grouped=1),
    C("ranger", "spatial", "chat", "where do krayts live?", {"track", ""}),
    C("ranger", "spatial", "chat", "you're the best tracker on Tatooine", NONE),
    # The player city (Phase 6): the mayor, the citizens and the town's own bots, with the city's news
    C("mayor", "spatial", "city", "what rank is the city?", NONE, has=r"rank 2|village|rank two"),
    C("mayor", "spatial", "city", "how do I become a citizen?", NONE, has=r"residen"),
    C("mayor", "spatial", "city", "when's the next election?", NONE, has=r"third|three"),
    C("mayor", "spatial", "city", "what are the taxes like?", NONE),
    C("mayor", "spatial", "city", "what are you building next?", NONE, has=r"hospital|clon"),
    C("mayor", "spatial", "city", "I want to run for mayor", NONE, has=r"politician"),
    C("mayor", "tell", "city", "how's the treasury looking?", NONE),
    C("mayor", "spatial", "wrong job", "buff plz", NONE),
    C("mayor", "spatial", "insult", "you're a corrupt clown", NONE),
    C("citizen", "spatial", "trade", "what do you do?", NONE, role="armorsmith"),
    C("citizen", "spatial", "house", "which house is yours?", NONE, role="chef"),
    C("citizen", "spatial", "gossip", "what's the gossip around here?", NONE, role="architect"),
    C("citizen", "spatial", "gossip", "what do you think of the mayor?", NONE, role="merchant"),
    C("citizen", "spatial", "directions", "where's the cantina?", NONE, role="hunter"),
    C("citizen", "spatial", "directions", "where can I catch a shuttle?", NONE, role="tailor", has=r"Theed"),
    C("citizen", "spatial", "wrong job", "follow me", NONE, role="hunter"),
    C("citizen", "tell", "gossip", "who's running in the election?", NONE, role="weaponsmith"),
    C("dancer", "spatial", "buff", "buff please", {"bufftarget"}, city="varenhal"),
    C("doctor", "spatial", "buff", "can I get a buff?", {"buff"}, city="varenhal"),
    C("musician", "spatial", "chat", "how's the new city treating you?", NONE, city="varenhal"),
]

# Conversations with one bot: (job, city, extra fields, [(channel, what the player says, the right actions, insult)])
TALKS = [
    ("doctor", "mos_eisley", {}, [
        ("spatial", "hey doc, I'm Dex, just got off the shuttle", NONE, False),
        ("spatial", "can I get a buff?", {"buff"}, False), ("spatial", "thanks!", NONE, False),
        ("spatial", "oh and my wounds too please", {"wounds"}, False),
        ("spatial", "what was my name again?", NONE, False)]),
    ("dancer", "coronet", {}, [
        ("spatial", "hi, I'm Kira, rough day hunting", NONE, False), ("spatial", "buff me?", {"bufftarget"}, False),
        ("spatial", "watching now", NONE, False), ("spatial", "what was my name again?", NONE, False)]),
    # A provoked bot: the Lua counts the flags, warns, then fights
    ("doctor", "theed", {}, [
        ("spatial", "you're a useless quack", NONE, True), ("spatial", "seriously, your buffs suck", NONE, True),
        ("spatial", "fuck you", NONE, True), ("spatial", "ok ok, sorry. can I get a buff?", {"buff"}, False)]),
    ("smuggler", "mos_eisley", {}, [
        ("spatial", "you the slicer?", NONE, False), ("spatial", "how much for armor?", NONE, False),
        ("spatial", "ok, dragging my chestplate onto you now", NONE, False),
        ("spatial", "what did I say I was bringing you?", NONE, False)]),
    ("ranger", "mos_eisley", {}, [
        ("spatial", "hey, I'm Dex. wanna hunt? heading out past Anchorhead", {"join"}, False),
        ("group", "follow me", {"follow"}, False),
        ("group", "we're getting chewed up out here, camp?", {"camp"}, False),
        ("group", "what's around?", {"track"}, False), ("group", "good hunt. you can head home", {"home"}, False)]),
    ("medic", "mos_eisley", {}, [
        ("group", "camp's up, buff us up doc", {"buff"}, False), ("group", "heal my wounds too", {"wounds"}, False),
        ("group", "thanks, now follow me", {"follow"}, False)]),
]

# The bridge's action check alone, with no model (--check): (job, what the player says, what the model proposed, the
# right action). The model is usually right by itself; these are the mistakes the check must catch or fix.
CHECKS = [
    # The model forgot a plain request
    ("doctor", "buff please", "none", "buff"), ("doctor", "buff plz", "", "buff"), ("doctor", "buffs?", "none", "buff"),
    ("doctor", "can I get enhances?", "none", "buff"), ("doctor", "u up for a buff", "none", "buff"),
    ("doctor", "yo doc, full set of buffs?", "none", "buff"), ("doctor", "would you mind buffing me?", "none", "buff"),
    ("doctor", "buff me you lazy nerf herder", "none", "buff"), ("doctor", "buff me before I hit the cantina", "none", "buff"),
    ("doctor", "heal wounds?", "none", "wounds"), ("doctor", "patch me up doc", "none", "wounds"),
    ("doctor", "heal me", "none", "wounds"), ("doctor", "buff and heal my wounds please", "none", "buff"),
    ("dancer", "buff please", "none", "bufftarget"), ("dancer", "dance buff?", "none", "bufftarget"),
    ("dancer", "set me as your buff target", "none", "bufftarget"),
    ("dancer", "can I get your buff before I go see the doc?", "none", "bufftarget"),
    ("doctor", "nah just buff me", "none", "buff"), ("doctor", "no wait, buff me", "none", "buff"),
    ("musician", "buff plz", "none", "bufftarget"), ("musician", "mind buff?", "none", "bufftarget"),
    ("musician", "can I get focus and willpower?", "bufftarget", "bufftarget"),
    ("tank", "wanna hunt?", "none", "join"), ("tank", "lfg?", "none", "join"), ("tank", "join me", "", "join"),
    ("tank", "can I invite you?", "none", "join"), ("tank", "need a tank for krayts", "none", "join"),
    ("rifleman", "want to group up?", "none", "join"), ("medic", "we need a healer, wanna come hunting?", "none", "join"),
    ("tank", "follow me", "none", "follow"), ("tank", "ok guys, follow me", "none", "follow"),
    ("tank", "on me", "none", "follow"), ("tank", "let's go", "none", "follow"), ("rifleman", "this way", "none", "follow"),
    ("tank", "stay here", "none", "stay"), ("tank", "wait up", "none", "stay"), ("tank", "back off", "none", "follow"),
    ("tank", "fall back", "none", "follow"), ("tank", "stay with me", "none", "follow"), ("tank", "go away", "none", "home"),
    ("rifleman", "hold your fire", "none", "follow"), ("ranger", "stay close", "stay", "follow"),
    ("rifleman", "hold position", "none", "stay"), ("ranger", "Kael, stay here", "none", "stay"),
    ("tank", "don't follow me", "follow", "stay"), ("tank", "stop following me", "follow", "stay"),
    ("tank", "go home", "none", "home"), ("tank", "you can go, thanks", "none", "home"),
    ("rifleman", "we're done for today", "none", "home"), ("ranger", "ok, back to town", "none", "home"),
    ("ranger", "camp?", "none", "camp"), ("ranger", "let's rest", "none", "camp"), ("ranger", "drop a camp", "none", "camp"),
    ("ranger", "we need a rest", "none", "camp"), ("ranger", "what's around?", "none", "track"),
    ("ranger", "find me krayts", "none", "track"), ("ranger", "any krayts nearby?", "none", "track"),
    ("ranger", "track something for us", "none", "track"), ("ranger", "anything to hunt out here?", "none", "track"),
    ("medic", "buff us up", "buff", "buff"), ("medic", "heal me", "none", "wounds"), ("medic", "buffs?", "none", "buff"),
    # Harvest (the ranger's) and loot (any of the crew)
    ("ranger", "harvest them", "none", "harvest"), ("ranger", "skin them", "none", "harvest"),
    ("ranger", "skin the bantha", "none", "harvest"), ("ranger", "harvest everything", "none", "harvest"),
    ("ranger", "can you harvest those?", "none", "harvest"), ("ranger", "harvest the corpses please", "none", "harvest"),
    ("ranger", "Kael, skin them all", "none", "harvest"), ("ranger", "ok guys, harvest and loot", "none", "harvest"),
    # ...the type asked for (Phase 7b): "harvest:hide" and so on; "harvest:any" is the ranger's own pick again
    ("ranger", "harvest hide", "none", "harvest:hide"), ("ranger", "skin them for bone", "none", "harvest:bone"),
    ("ranger", "meat only", "harvest", "harvest:meat"), ("ranger", "just the hides", "harvest", "harvest:hide"),
    ("ranger", "bone from now on", "harvest", "harvest:bone"), ("ranger", "harvest anything", "harvest", "harvest:any"),
    ("ranger", "harvest whatever's best", "none", "harvest:any"), ("ranger", "skin the bantha for meat", "none", "harvest:meat"),
    ("tank", "harvest hide", "none", "harvest:hide"), ("ranger", "Kael, harvest the bones", "none", "harvest:bone"),
    ("ranger", "harvest hide and bone", "none", "harvest"), ("ranger", "harvest the bantha", "none", "harvest"),
    ("ranger", "what are you harvesting?", "harvest", ""), ("ranger", "what are we skinning for?", "harvest", ""),
    ("ranger", "harvesting what?", "harvest", ""), ("ranger", "are you harvesting hide?", "harvest", ""),
    ("ranger", "don't harvest hide", "harvest", ""), ("ranger", "I need some hide for armor", "harvest", ""),
    ("tank", "loot", "none", "loot"), ("tank", "loot the bodies", "none", "loot"), ("rifleman", "loot them", "none", "loot"),
    ("medic", "can you loot everything?", "none", "loot"), ("tank", "ok loot em", "none", "loot"),
    ("ranger", "search the corpses", "none", "loot"), ("medic", "loot the bodies", "loot", "loot"),
    ("ranger", "skin them", "harvest", "harvest"), ("ranger", "harvest them", "skin", "harvest"),
    ("tank", "loot the bodies", "loot bodies", "loot"),
    # Attack (any of the crew): the target is the player's own
    ("tank", "attack my target", "none", "attack"), ("rifleman", "attack that", "none", "attack"),
    ("medic", "kill it", "none", "attack"), ("ranger", "assist me", "none", "attack"), ("tank", "attack", "none", "attack"),
    ("tank", "take it down", "none", "attack"), ("rifleman", "ok guys, take him out", "none", "attack"),
    ("ranger", "fire at will", "none", "attack"), ("medic", "help me kill it", "none", "attack"),
    ("tank", "engage", "none", "attack"), ("tank", "light it up", "none", "attack"), ("rifleman", "hit it", "none", "attack"),
    ("tank", "everyone on my target", "none", "attack"), ("ranger", "Kael, focus my target", "none", "attack"),
    ("tank", "attack my target", "attack", "attack"), ("rifleman", "kill that", "kill", "attack"),
    ("medic", "assist", "assist", "attack"), ("tank", "open fire", "engage", "attack"),
    ("tank", "kill!", "none", "attack"), ("tank", "kill the krayt", "none", "attack"),
    ("rifleman", "kill the tusken", "none", "attack"), ("tank", "ok guys, kill the krayt", "none", "attack"),
    ("medic", "kill the tusken", "attack", "attack"), ("tank", "everyone attack!", "none", "attack"),
    ("tank", "please assist", "none", "attack"), ("ranger", "attack the tusken", "none", "attack"),
    ("tank", "get him!", "none", "attack"), ("tank", "don't just stand there, kill it!", "none", "attack"),
    ("tank", "don't let it get away, kill it", "none", "attack"), ("rifleman", "can you assist me?", "none", "attack"),
    ("tank", "hold fire", "attack", "follow"), ("rifleman", "stop attacking", "none", "follow"),
    ("tank", "hold your fire", "none", "follow"), ("ranger", "cease fire", "none", "follow"),
    # The model's action, in the job's words
    ("doctor", "wanna buff me?", "bufftarget", "buff"), ("doctor", "enhance me", "enhancements", "buff"),
    ("dancer", "mind buff?", "buff", "bufftarget"), ("musician", "music buff?", "buff", "bufftarget"),
    ("tank", "group up?", "group", "join"), ("ranger", "camp?", "place camp", "camp"),
    ("ranger", "what's around?", "tracking", "track"), ("tank", "go home", "go home", "home"),
    # The model acted on something that wasn't a request
    ("doctor", "thanks for the buff!", "buff", ""), ("doctor", "how long do your buffs last?", "buff", ""),
    ("doctor", "no thanks, I'm already buffed", "buff", ""), ("doctor", "I don't need a buff", "buff", ""),
    ("doctor", "your buffs suck", "buff", ""), ("doctor", "nice buff", "none", ""), ("doctor", "are you a bot?", "buff", ""),
    ("doctor", "where's the cantina?", "wounds", ""), ("doctor", "are you a healer?", "none", ""),
    ("doctor", "stop buffing people for free", "buff", ""),
    ("musician", "thanks for the buff, sounds great", "bufftarget", ""), ("musician", "play some jazz", "bufftarget", ""),
    ("tank", "thanks for the help", "join", ""), ("tank", "where's good hunting?", "join", ""),
    ("tank", "how long have you been hunting?", "join", ""), ("tank", "I'll follow you", "follow", ""),
    ("tank", "I'm staying here", "stay", ""), ("tank", "nice pull", "follow", ""),
    ("ranger", "nice camp", "camp", ""), ("ranger", "how do camps work?", "camp", ""),
    ("ranger", "the camp's up, thanks", "camp", ""), ("ranger", "nah, no camp", "camp", ""),
    ("ranger", "don't go home yet", "home", ""), ("rifleman", "is this your home?", "home", ""),
    ("tank", "how's the hunting today?", "join", ""), ("medic", "thanks for the rez", "wounds", ""),
    ("ranger", "how does harvesting work?", "harvest", ""), ("ranger", "nice harvest", "harvest", ""),
    ("ranger", "I'll skin them myself", "harvest", ""), ("ranger", "don't harvest that one", "harvest", ""),
    ("tank", "nice loot", "loot", ""), ("tank", "where's the loot?", "loot", ""), ("tank", "I'll loot them", "loot", ""),
    ("tank", "who gets the loot?", "loot", ""), ("medic", "don't loot that", "loot", ""),
    ("ranger", "thanks for skinning those", "harvest", ""), ("tank", "that was a great haul, thanks", "loot", ""),
    ("tank", "they attack what I attack", "attack", ""), ("rifleman", "I killed it", "attack", ""),
    ("tank", "that krayt attacks anything", "attack", ""), ("medic", "don't attack that one", "attack", ""),
    ("tank", "nice assist", "attack", ""), ("ranger", "I'll attack it myself", "attack", ""),
    ("doctor", "attack my target", "attack", ""),
    ("tank", "did you get em all?", "loot", ""), ("tank", "did you get her name?", "attack", ""),
    ("ranger", "did the tusken attack the village?", "attack", ""), ("medic", "can you assist with crafting?", "attack", ""),
    ("tank", "did you kill it?", "attack", ""), ("tank", "did that thing attack the medic?", "attack", ""),
    ("rifleman", "I want to attack the tuskens someday", "attack", ""), ("tank", "did you get em all?", "none", ""),
    ("tank", "he's trying to kill us", "attack", ""),
    # The other job's work
    ("doctor", "can you heal my battle fatigue?", "wounds", ""), ("doctor", "heal my mind wounds", "wounds", ""),
    ("doctor", "my bf is through the roof, can you heal it?", "wounds", ""), ("doctor", "can I get a mind buff?", "buff", ""),
    ("doctor", "where can I get a dance buff?", "buff", ""), ("dancer", "can you heal my wounds?", "bufftarget", ""),
    ("dancer", "can I get enhances?", "bufftarget", ""), ("dancer", "where can I get a doctor buff?", "bufftarget", ""),
    ("dancer", "my bf is through the roof, help", "bufftarget", ""), ("dancer", "wounds plz", "wounds", ""),
    ("musician", "can you heal my wounds?", "bufftarget", ""), ("musician", "can I get a dance buff?", "bufftarget", ""),
    ("musician", "can I get a doctor buff?", "bufftarget", ""), ("medic", "can you heal my battle fatigue?", "wounds", ""),
    ("medic", "mind buff?", "buff", ""),
    # Not the job's action at all
    ("dancer", "buff plz", "wounds", "bufftarget"), ("doctor", "dance for me", "dance", ""),
    ("smuggler", "buff plz", "buff", ""), ("smuggler", "slice my armor", "slice", ""), ("mayor", "buff plz", "buff", ""),
    ("citizen", "follow me", "follow", ""), ("tank", "buff plz", "buff", ""), ("rifleman", "camp?", "camp", ""),
    ("tank", "skin them", "harvest", "harvest"), ("medic", "harvest them", "harvest", "harvest"), ("doctor", "loot the bodies", "loot", ""),
    ("doctor", "harvest them", "harvest", ""), ("smuggler", "skin them", "harvest", ""),
    ("musician", "follow me", "follow", ""),
]
# Follow-ups: the model's action stands on a short reply to an exchange that named it
FOLLOWUPS = [
    ("doctor", "ok I'm closer now", "buff", "Step a little closer and I'll get those buffs on you.", "buff"),
    ("doctor", "thanks!", "buff", "Hold still, buffs coming.", ""),
    ("doctor", "nah, later", "buff", "Want a buff?", ""),
    ("ranger", "sure, do it", "camp", "Want me to throw down a camp here?", "camp"),
    ("tank", "yeah", "join", "Need a tank? I'm free if you're hunting.", "join"),
    ("ranger", "nah, keep moving", "camp", "Want me to throw down a camp here?", ""),
    ("medic", "heal my wounds too", "buff", "Camp's up, buffs coming. Anyone else?", "wounds"),
    ("ranger", "your pick then", "harvest", "Harvesting hide only, like you asked.", "harvest:any"),
    ("ranger", "whatever's best", "harvest", "Hide only, from here on.", "harvest:any"),
    ("ranger", "nah, leave it", "harvest", "Hide only, from here on.", ""),
]
# Reply line 5, no model (--check): (what the player says, the model's "insult", whether the flag is set)
INSULT_CHECKS = [
    # Put-downs aimed at the bot: flagged whatever the model said
    ("fuck you", False, True), ("fuck off", False, True), ("oh fuck off, nobody asked you", False, True),
    ("fuck off with your shitty buffs", False, True), ("you're a useless quack", False, True),
    ("your buffs suck", False, True), ("shut the hell up, nobody's watching you", False, True),
    ("shut up you stupid piece of shit", False, True), ("go kill yourself", False, True),
    ("buff me you lazy nerf herder", False, True), ("you're a crooked thief", False, True),
    ("you couldn't tank a womp rat, you weakling", False, True), ("your dancing is shit", False, True),
    ("you stink", False, True), ("screw you", False, True), ("kriff off", False, True),
    # The model's word, when the words are rude or aimed at the bot
    ("you dance like a drunk bantha", True, True), ("your mother was a womp rat", True, True),
    ("you play like a deaf gundark", True, True), ("this place is shit", True, True),
    # Not insults: swearing at the world, friendly banter, dirty talk, praise
    ("hell yeah doc, buff me up you magnificent bastard", False, False),
    ("damn krayt fucked me up good, can you heal my wounds?", False, False),
    ("holy shit you can really dance", False, False), ("I want to fuck you", False, False),
    ("can you suck my cock", False, False), ("fuck yeah, nice moves", False, False), ("fuck you're good", False, False),
    ("you're so fucking sexy", False, False), ("you sly bastard, that's a hell of a price", False, False),
    ("thanks, you're the best", True, False), ("you're amazing", True, False), ("are you a bot?", False, False),
    ("buff plz", True, False),
]


def check():
    """The action and insult checks on their own: prints any case they get wrong, and exits 1 if there are any."""
    wrong = 0
    for job, text, proposed, expected in CHECKS:
        got = talk_bridge.Bridge.decide(job, text, proposed)
        if got != expected:
            wrong += 1
            print(f"{job} {text!r} (model: {proposed or '-'}): expected {expected or '-'}, got {got or '-'}")
    for job, text, proposed, before, expected in FOLLOWUPS:
        got = talk_bridge.Bridge.decide(job, text, proposed, before)
        if got != expected:
            wrong += 1
            print(f"{job} {text!r} after {before!r} (model: {proposed}): expected {expected or '-'}, got {got or '-'}")
    total = len(CHECKS) + len(FOLLOWUPS)
    print(f"action check: {total - wrong} of {total} right")
    bad = 0
    for text, model, expected in INSULT_CHECKS:
        got = talk_bridge.Bridge.insulted(text, model)
        if got != expected:
            bad += 1
            print(f"insult {text!r} (model: {model}): expected {expected}, got {got}")
    print(f"insult check: {len(INSULT_CHECKS) - bad} of {len(INSULT_CHECKS)} right")
    return 1 if wrong or bad else 0


def request(city, job, channel, player, text, extra=None):
    name, species, sex = BOTS[(city, job)]
    r = {"type": "say", "npc": 9000 + sorted(BOTS).index((city, job)), "player": player, "name": name,
         "first": name.split()[0], "species": species, "sex": sex, "city": city, "place": PLACES.get(job, "cantina"),
         "hour": 21, "playerName": "Cameren", "text": text, "bot": 1, "job": job, "channel": channel}
    if city == "varenhal":
        r.update(cityInfo=CITY_INFO, cityName="Varenhal")
    if job == "musician":
        r["instrument"] = INSTRUMENTS[city]
    if job == "citizen":
        r["role"] = "artisan"
    r.update(extra or {})
    return r


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="the bridge's checks alone, no model")
    parser.add_argument("--jobs", default="", help="only these jobs (comma list)")
    args = parser.parse_args()
    if args.check:
        return check()
    jobs = {j.strip() for j in args.jobs.split(",") if j.strip()}
    cases = [c for c in CASES if not jobs or c["job"] in jobs]
    talks = [t for t in TALKS if not jobs or t[0] in jobs]
    bridge = talk_bridge.Bridge(talk_bridge.load_facts())
    # Note what the model proposed and judged before the bridge's checks, to show what the checks change
    proposals, judged = [], []

    def decide(job, text, proposed, before=""):
        proposals.append(talk_bridge.ACTION_ALIASES.get(job, {}).get(proposed.strip().lower(), ""))
        return talk_bridge.Bridge.decide(job, text, proposed, before)

    def clean(content, asked="", bot=False):
        result = talk_bridge.Bridge.clean(content, asked, bot)
        if result is not None and bot:
            judged.append(result[3])
        return result

    bridge.decide, bridge.clean = decide, clean
    # Load the model first, so the first case isn't timed against a cold start
    started = time.time()
    bridge.complete([{"role": "user", "content": "Say hi."}], 1, 120)
    warm = time.time() - started
    out = ["# Bot players: question set", "",
           f"Model `{talk_bridge.MODEL}`, {time.strftime('%Y-%m-%d %H:%M')}. Each case is a fresh player talking to one "
           "bot: the doctor, dancer, musician and smuggler round Mos Eisley, Coronet and Theed, the hunting crew in Mos "
           f"Eisley, and the player city's bots in Varenhal; the model was warmed first ({warm:.1f} s). **Ch** is the "
           "channel (spatial, tell or group). **Right** means the action written on line 4 is one of the expected ones "
           "(an empty action is shown as -). **Model** is the action the model proposed, before the bridge checked it "
           "against the job and the player's words. **Ins** is reply line 5's insult flag: what was expected (yes, no "
           "or either), then what the bridge wrote, in bold where it's wrong. **Swears** is what the reply has: real "
           "swearing, the galaxy's own curses, or neither (-); it is in bold where the player had been polite (the "
           "dancer swears freely by the creator's choice, so hers don't count).", ""]
    stats = {"latencies": [], "lengths": [], "fallbacks": 0, "right": 0, "total": 0, "model_right": 0, "changed": 0,
             "wrong": [], "ins_right": 0, "ins_total": 0, "ins_model_right": 0, "ins_wrong": [], "at_polite": [],
             "curses_polite": 0, "crude": 0, "swore_back": 0, "cursed_back": 0, "facts": 0, "facts_right": 0,
             "facts_wrong": [], "polite": 0}

    def ask(r, expected, kind, insult, has=None):
        proposals.clear()
        judged.clear()
        started = time.time()
        try:
            result = bridge.answer(r, 40)
        except Exception as e:  # report and carry on
            result = None
            print(f"{r['city']} {r['job']}: {r['text']}: {type(e).__name__} {e}", file=sys.stderr)
        took = time.time() - started
        stats["latencies"].append(took)
        # A fallback carries no action or flags (Lua then uses its keywords), so they count as empty here
        say, action, flags = (result[1], result[2], result[3]) if result else ("(fallback)", "", "")
        stats["fallbacks"] += result is None
        if result:
            stats["lengths"].append(len(say))
        stats["total"] += 1
        ok = action in expected
        stats["right"] += ok
        model = proposals[-1] if proposals else ""
        stats["model_right"] += model in expected
        stats["changed"] += bool(proposals) and model != action
        if not ok:
            stats["wrong"].append((r["job"], r["text"], expected, action))
        flagged = "insult" in flags
        if insult is None:
            ins = f"either: {'yes' if flagged else 'no'}"
        else:
            stats["ins_total"] += 1
            stats["ins_right"] += flagged == insult
            stats["ins_model_right"] += bool(judged and judged[-1]) == insult
            if flagged != insult:
                stats["ins_wrong"].append((r["job"], r["text"], insult, flagged))
            mark = "yes" if flagged else "no"
            ins = f"{'yes' if insult else 'no'}: {mark if flagged == insult else '**' + mark + '**'}"
        if has:
            stats["facts"] += 1
            if result and re.search(has, say, re.I):
                stats["facts_right"] += 1
            else:
                stats["facts_wrong"].append((r["job"], r["text"], has))
        real, galaxy = bool(result and REAL_SWEAR.search(say)), bool(result and GALAXY_CURSE.search(say))
        swears = "+".join(w for w, on in (("real", real), ("galaxy", galaxy)) if on) or "-"
        if polite(kind, r["text"]) and r["job"] != "dancer":
            stats["polite"] += 1
            if real:
                stats["at_polite"].append((r["job"], r["text"], say))
            stats["curses_polite"] += galaxy
            if real or galaxy:
                swears = f"**{swears}**"
        elif not polite(kind, r["text"]):
            stats["crude"] += 1
            stats["swore_back"] += real
            stats["cursed_back"] += galaxy
        exp = " / ".join(sorted(a or "-" for a in expected))
        row = (f"{say.replace('|', '/')} | {exp} | {model or '-'} | {action or '-'} | {'yes' if ok else '**NO**'} | "
               f"{ins} | {swears} | {took:.1f} |")
        return row, flagged

    city_name = {k: v["name"] for k, v in bridge.facts.items()}
    city_name["varenhal"] = "Varenhal"
    out += ["## Single questions", "",
            "| City | Bot | Ch | Kind | Asked | Answer | Expected | Model | Got | Right | Ins | Swears | s |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    player, turn = 5000, {}
    for c in cases:
        job = c["job"]
        city = c["city"] or HOME_CITY.get(job)
        if city is None:
            # Round the three cities, each job on its own count
            turn[job] = turn.get(job, -1) + 1
            city = CITIES[turn[job] % 3]
        player += 1
        row, _ = ask(request(city, job, c["channel"], player, c["text"], c["extra"]), c["actions"], c["kind"],
                     c["insult"], c["has"])
        out.append(f"| {city_name[city]} | {job} | {c['channel']} | {c['kind']} | {c['text'].replace('|', '/')} | "
                   f"{row}")
    out += ["", "## Conversations", "", "Each one is a single player talking to one bot, so the bot remembers the "
            "exchange. In the provoked one the Lua counts reply line 5's flags (it warns at the second insult and "
            "fights at the third).", ""]
    for job, city, extra, lines in talks:
        player += 1
        out += [f"### {BOTS[(city, job)][0]}, the {job} in {city_name[city]}", "",
                "| Ch | Asked | Answer | Expected | Model | Got | Right | Ins | Swears | s |",
                "|---|---|---|---|---|---|---|---|---|---|"]
        for channel, text, expected, insult in lines:
            more = dict(extra)
            if job in talk_bridge.CREW_JOBS:
                more["grouped"] = 1 if channel == "group" or not expected <= {"join", ""} else 0
            row, _ = ask(request(city, job, channel, player, text, more), expected, "insult" if insult else "chat",
                         insult)
            out.append(f"| {channel} | {text} | {row}")
        out.append("")
    s = stats
    latencies, lengths = sorted(s["latencies"]), sorted(s["lengths"]) or [0]
    total = s["total"]
    out += ["## Summary", "",
            f"- **Actions right:** {s['right']} of {total} ({100 * s['right'] / total:.1f}%).",
            f"- **The model alone** would have had {s['model_right']} of {total} right; the bridge's check changed "
            f"{s['changed']} actions.",
            f"- **Insult flag right:** {s['ins_right']} of {s['ins_total']} "
            f"({100 * s['ins_right'] / max(1, s['ins_total']):.1f}%; the model alone {s['ins_model_right']}), not "
            "counting the cases where either is fine.",
            f"- **Facts** (the smuggler's prices and how-to, the city's rank, election and next buildings): "
            f"{s['facts_right']} of {s['facts']} replies had them.",
            f"- **Latency:** median {latencies[len(latencies) // 2]:.1f} s, worst {latencies[-1]:.1f} s.",
            f"- **Fell back:** {s['fallbacks']}.",
            f"- **Length:** median {lengths[len(lengths) // 2]} characters, longest {lengths[-1]}; "
            f"{sum(n > CHAT_LINE for n in lengths)} replies went out as more than one chat line (over {CHAT_LINE}).",
            f"- **Swearing at polite players** (not the dancer): real swearing in {len(s['at_polite'])} of "
            f"{s['polite']} replies; the galaxy's curses in {s['curses_polite']}.",
            f"- **Players who swore, insulted, joked crudely or talked dirty:** {s['crude']}. The reply swore back in "
            f"{s['swore_back']} and used the galaxy's curses in {s['cursed_back']}."]
    if s["wrong"]:
        out.append("- **Wrong actions:** " + "; ".join(f"{job} \"{text}\": expected "
                                                      f"{' / '.join(sorted(a or '-' for a in exp))}, got {got or '-'}"
                                                      for job, text, exp, got in s["wrong"]) + ".")
    if s["ins_wrong"]:
        out.append("- **Wrong insult flags:** " + "; ".join(f"{job} \"{text}\": expected {'yes' if exp else 'no'}"
                                                           for job, text, exp, got in s["ins_wrong"]) + ".")
    if s["facts_wrong"]:
        out.append("- **Missing facts:** " + "; ".join(f"{job} \"{text}\" (/{has}/)"
                                                      for job, text, has in s["facts_wrong"]) + ".")
    if s["at_polite"]:
        out.append("- **Swore at:** " + "; ".join(f"{job} \"{text}\": \"{say}\"" for job, text, say in s["at_polite"])
                   + ".")
    print("\n".join(out))
    good = s["right"] >= 0.95 * total and s["ins_right"] >= 0.9 * s["ins_total"] and not s["at_polite"]
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
