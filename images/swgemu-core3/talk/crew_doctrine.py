"""The crew's doctrine and orders (Phase 9b), for the talk bridge. Standard library only.

Each crew bot has a tactics table (crew.lua's BotCrew.tactics: the same entries, limits and defaults; the Lua checks every
value again on its way in, so this file and that table agree by hand). The language model fills it from three things:

  * the bot's doctrine (a plain-text file, in the creator's words, plus the lines it was taught in game) -> the base table,
    made once whenever the doctrine changes and written to /run/talk/tactics/base.txt ("first entry value" lines);
  * the fight (a "plan" request from the Lua: the crew, the creatures, the standing orders) -> changes for this fight;
  * the players' words in chat -> orders ("Quillan, just heal") and lessons ("from now on revive before anything").

Everything the model says is checked here: entries must exist for the bot's role, numbers are clamped, words must be on the
list, a creature must be one in the request, and an order or a lesson must be backed by what the player actually said.

Where the doctrine lives (all overridable, so the bridge runs with no /data/doctrine, e.g. in local development):
  TALK_DOCTRINE_SEED  the image's seed doctrines (default: doctrine/ next to this file)
  TALK_DOCTRINE_DIR   base/ (the script's copy of the files, wins over the seed), taught/<first>.txt (lessons, and crew.txt for
                      everyone), tables/<first>.json (the model's base tables); default /data/doctrine when /data is writable,
                      else <TALK_DIR>/doctrine
"""
import hashlib
import json
import os
import re
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

ALL_ROLES = ("tank", "rifleman", "medic", "ranger", "squadleader", "entertainer", "commando")
RANGED = ("rifleman", "ranger", "squadleader", "entertainer", "commando", "medic")

# Who the seed doctrines are for. A doctrine file may start with "role: <role>" for a bot not listed here.
CREW_ROLE = {"kragoth": "tank", "senna": "rifleman", "quillan": "medic", "weeta": "ranger", "tavik": "squadleader",
             "ilsi": "entertainer", "brask": "commando"}

MAX_TAUGHT = 10
MAX_TAUGHT_CHARS = 160

# The tactics table: (roles, kind, values or (min, max), default, description). kinds: enum, number, int, focus, protect, set.
# Defaults are today's numbers (crew.lua: holdFor 3, healBelow.fight 0.75, dotMindFloor 0.4, retreatLow 0.3).
TACTICS = {
    "focus": (("tank", "rifleman", "ranger", "squadleader", "entertainer", "commando"), "focus",
              ("tank", "leader", "weakest", "strongest", "medic"), "tank",
              "what to attack: the tank's target (the default), the leader's target, the creature with the least or most "
              "health, the creature that is on the medic, or one named creature as creature:<oid>"),
    "hold": (RANGED, "int", (0, 6), 3,
             "seconds to wait for the tank to take a creature before opening on it (0: don't wait)"),
    "range": (("rifleman", "ranger", "squadleader", "entertainer", "medic"), "enum", ("close", "band", "far"), "band",
              "where to stand: 5 m closer than usual, the usual band, or 5 m further"),
    "specials": (ALL_ROLES, "enum", ("full", "normal", "save"), "normal",
                 "how freely to use specials: full (while over 30% of each pool), normal (50%), save (75%)"),
    "protect": (("tank", "ranger"), "protect", ("medic",), "medic",
                "whom to look after first when taunting and rescuing: the medic, or a member by first name"),
    "healAt": (("medic",), "number", (0.5, 0.9), 0.75, "heal in a fight anyone below this share of health or action: higher heals sooner (0.9 tops everyone up early), "
               "lower heals later and saves mind; \"keep everyone above half\" is about who comes first, not a reason to go "
               "below the default"),
    "reviveFirst": (("medic",), "enum", ("yes", "no"), "yes",
                    "revive the dead before healing the living (anyone close to death is always healed first)"),
    "packs": (("medic",), "enum", ("area", "single", "none"), "area",
              "the poison and disease packs: area ones when creatures are clumped, single ones only, or none"),
    "mindFloor": (("medic",), "number", (0.3, 0.8), 0.4, "throw packs only above this share of its mind"),
    "shoot": (("medic", "entertainer"), "enum", ("yes", "no"), "yes",
              "shoot between heals (yes), or stay out of the fight unless something is on it (no)"),
    "area": (("commando",), "enum", ("both", "cones", "none"), "both",
             "cones and grenades, cones only (\"save the grenades\"), or neither; with both, grenades already go only on a "
             "pack of three or more on the tank, and nothing is ever thrown near creatures that haven't been pulled"),
    "retreatAt": (("squadleader",), "number", (0.2, 0.5), 0.3,
                  "call the retreat when the tank is down and two members are under this share of health"),
    "calls": (("squadleader",), "set", ("rally", "volley", "formup", "steadyaim"), "all",
              "which calls to make: all, none, or some of rally, volley, formup, steadyaim"),
}


def applies(entry, role):
    return entry in TACTICS and role in TACTICS[entry][0]


def default_text(entry):
    value = TACTICS[entry][3]
    return str(value)


def clean_value(entry, raw, creatures=(), names=()):
    """The canonical text of a value for an entry, or None. creatures: the oids a focus may name; names: the first names a
    protect may name (lowercase)."""
    if entry not in TACTICS or raw is None:
        return None
    _roles, kind, limits, _default, _desc = TACTICS[entry]
    text = str(raw).strip().lower()
    if not text:
        return None
    if kind in ("number", "int"):
        try:
            n = float(text.rstrip("%"))
        except ValueError:
            return None
        if limits[1] <= 1 and n > 1:
            n /= 100
        n = max(limits[0], min(limits[1], n))
        return "%d" % round(n) if kind == "int" else "%.2f" % n
    if kind == "enum":
        return text if text in limits else None
    if kind == "focus":
        if text in limits:
            return text
        m = re.fullmatch(r"creature:(\d+)", text)
        return text if m and int(m.group(1)) in set(creatures) else None
    if kind == "protect":
        if text == "medic":
            return text
        return text if text in set(names) else None
    if kind == "set":
        if text in ("all", "none"):
            return text
        picked = set()
        for word in re.findall(r"[a-z]+", text):
            if word == "all":
                return "all"
            if word not in limits:
                return None
            picked.add(word)
        if not picked:
            return None
        if len(picked) == len(limits):
            return "all"
        return ",".join(w for w in limits if w in picked)
    return None


def is_default(entry, value):
    d = TACTICS[entry][3]
    if TACTICS[entry][1] in ("number", "int"):
        return abs(float(value) - float(d)) < 0.005
    return str(value) == str(d)


def clean_table(role, obj, creatures=(), names=()):
    """A model's {entry: value} -> {entry: canonical value} for entries this role has; unknown or bad ones dropped."""
    out = {}
    if not isinstance(obj, dict):
        return out
    for entry, raw in obj.items():
        if applies(entry, role):
            value = clean_value(entry, raw, creatures, names)
            if value is not None:
                out[entry] = value
    return out


def table_lines(first, table):
    """base.txt lines for a bot: only entries that differ from the default (no line means the default)."""
    return ["%s %s %s" % (first, entry, table[entry]) for entry in sorted(table) if not is_default(entry, table[entry])]


def describe_entries(roles):
    """The entries these roles have, for a prompt: one line each with values and the default."""
    lines = []
    for entry, (eroles, kind, limits, default, desc) in TACTICS.items():
        if not any(r in eroles for r in roles):
            continue
        if kind in ("number", "int"):
            values = "a number from %s to %s" % (("%d" % limits[0], "%d" % limits[1]) if kind == "int" else
                                                  ("%.2f" % limits[0], "%.2f" % limits[1]))
        elif kind == "focus":
            values = "one of " + ", ".join(limits) + ", or creature:<oid>"
        elif kind == "protect":
            values = "medic, or a member's first name"
        elif kind == "set":
            values = "all, none, or a comma list of " + ", ".join(limits)
        else:
            values = "one of " + ", ".join(limits)
        who = "all" if len(eroles) == len(ALL_ROLES) else "/".join(r for r in eroles if r in roles)
        lines.append("- %s (%s): %s. %s. Default %s." % (entry, who, values, desc, default))
    return "\n".join(lines)


# The doctrines -------------------------------------------------------------------------------------------------------------

def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


class Doctrines:
    """The doctrine files, the lessons and the base tables of the crew."""

    def __init__(self, data_dir=None, seed_dir=None):
        self._data_dir = data_dir
        self.seed_dir = seed_dir or os.environ.get("TALK_DOCTRINE_SEED") or os.path.join(HERE, "doctrine")

    @property
    def data_dir(self):
        if self._data_dir is None:
            env = os.environ.get("TALK_DOCTRINE_DIR")
            if env:
                self._data_dir = env
            elif os.path.isdir("/data") and os.access("/data", os.W_OK):
                self._data_dir = "/data/doctrine"
            else:
                self._data_dir = os.path.join(os.environ.get("TALK_DIR", "/run/talk"), "doctrine")
            try:
                os.makedirs(self._data_dir, exist_ok=True)
            except OSError:
                pass
        return self._data_dir

    # Files

    def doctrine_path(self, first):
        """The script's copy (base/) if there is one, else the image's seed."""
        path = os.path.join(self.data_dir, "base", first + ".txt")
        return path if os.path.isfile(path) else os.path.join(self.seed_dir, first + ".txt")

    def taught_path(self, target):
        return os.path.join(self.data_dir, "taught", target + ".txt")

    def table_path(self, first):
        return os.path.join(self.data_dir, "tables", first + ".json")

    def firsts(self):
        found = set()
        for folder in (os.path.join(self.data_dir, "base"), self.seed_dir):
            try:
                found.update(n[:-4] for n in os.listdir(folder) if n.endswith(".txt") and re.fullmatch(r"[a-z][a-z']*", n[:-4])
                             and n != "crew.txt")
            except OSError:
                pass
        return sorted(found)

    # Reading

    def _doctrine_raw(self, first):
        return _read(self.doctrine_path(first)) or ""

    def role(self, first):
        m = re.match(r"\s*role:\s*(\w+)", self._doctrine_raw(first), re.I)
        role = m.group(1).lower() if m else CREW_ROLE.get(first)
        return role if role in ALL_ROLES else None

    def doctrine(self, first):
        """The doctrine text: the file without its role header, lines trimmed."""
        lines = [line.strip() for line in self._doctrine_raw(first).splitlines()]
        return "\n".join(line for line in lines if line and not re.match(r"role:\s*\w+$", line, re.I))

    def taught(self, target):
        lines = [line.strip() for line in (_read(self.taught_path(target)) or "").splitlines()]
        return [line for line in lines if line]

    def lessons(self, first):
        """Everything taught to this bot: the crew's lines, then its own."""
        return self.taught("crew") + self.taught(first)

    def text(self, first):
        """The doctrine and the lessons as the model reads them."""
        parts = [self.doctrine(first)]
        lessons = self.lessons(first)
        if lessons:
            parts.append("Taught since:\n" + "\n".join("- " + line for line in lessons))
        return "\n".join(p for p in parts if p)

    def digest(self, first):
        return hashlib.sha1(self.text(first).encode("utf-8")).hexdigest()[:16]

    def signature(self, first):
        """What changes when the doctrine does (modification times and sizes), cheap to compare."""
        sig = []
        for path in (self.doctrine_path(first), self.taught_path(first), self.taught_path("crew")):
            try:
                st = os.stat(path)
                sig.append((path, st.st_mtime_ns, st.st_size))
            except OSError:
                sig.append((path, 0, 0))
        return tuple(sig)

    # Lessons

    @staticmethod
    def _stem(word):
        return word.lower().strip(".,!?'\"").rstrip("s")

    def add_taught(self, target, line):
        """A lesson for one bot (target a first name) or everyone (target "crew"). At most MAX_TAUGHT: the oldest goes.
        False if the bot already has that line."""
        lines = self.taught(target)
        if line.lower() in (x.lower() for x in lines):
            return False
        lines.append(line)
        lines = lines[-MAX_TAUGHT:]
        write_atomic(self.taught_path(target), "\n".join(lines) + "\n")
        return True

    def forget(self, target, words=None):
        """Forget everything taught (words None), or the lines that mention any of the words. How many went."""
        lines = self.taught(target)
        if words is None:
            keep = []
        else:
            stems = {self._stem(w) for w in words if len(w) >= 3}
            keep = [line for line in lines if not any(s and s in line.lower() for s in stems)]
        if len(keep) == len(lines):
            return 0
        if keep:
            write_atomic(self.taught_path(target), "\n".join(keep) + "\n")
        else:
            try:
                os.remove(self.taught_path(target))
            except OSError:
                pass
        return len(lines) - len(keep)

    # Tables

    def load_table(self, first):
        try:
            with open(self.table_path(first), encoding="utf-8") as f:
                obj = json.load(f)
            return obj if isinstance(obj, dict) and isinstance(obj.get("table"), dict) else None
        except (OSError, ValueError):
            return None

    def save_table(self, first, table, digest):
        write_atomic(self.table_path(first), json.dumps({"digest": digest, "at": int(time.time()), "table": table},
                                                        sort_keys=True) + "\n")

    def base_text(self):
        """All the crew's base tables as base.txt: one "first entry value" line each."""
        lines = []
        firsts = self.firsts()
        for first in firsts:
            saved = self.load_table(first)
            role = self.role(first)
            if saved and role:
                # (the crew's names, or "protect quillan" is dropped as an unknown member)
                lines += table_lines(first, clean_table(role, saved["table"], (), firsts))
        return "\n".join(lines) + ("\n" if lines else "")


# Orders and lessons, checked against the player's words -------------------------------------------------------------------

# Chat that asks (how, what, why...) is not an order. A question is one only if it asks the bot ("can you just heal?").
_INFO = re.compile(r"^\W*(how (long|much|many|often|strong|big|good|does|do|is|are)|how'?s|what (does|do|is|are|'s)|what'?s|whats|"
                   r"why|when|who|which|where|does|do you|is it|are you|have you|did you)\b", re.I)
_ASKING = re.compile(r"^\W*(\w+,?\s+)?(can|could|would|will|please|pls|plz)\b", re.I)


def order_shaped(text):
    """An instruction rather than a question or a remark."""
    t = text.strip()
    # ("when the medic is down, heal yourself" opens with a question word and is a lesson)
    if _INFO.search(t) and not (t.lower().startswith("when ") and "," in t and not t.endswith("?")):
        return False
    if t.endswith("?") and not _ASKING.search(t):
        return False
    return True


_ANY = r"(?:the |your |those |that |these |all |any )?"
# The words that go with each entry: an order for the entry stands only if the player said one of them
ORDER_WORDS = {
    "focus": re.compile(r"\b(focus|kill|attack|target|take (it |them )?(down|out)|first|burn|drop|biggest|big one|strongest|"
                        r"toughest|largest|weakest|smallest|little one|easiest|runt|leader'?s|my target|assist|on (the )?"
                        r"(medic|doc|healer)|on \w+|the one)\b", re.I),
    "hold": re.compile(r"\b(wait|waiting|hold|tank|without|open (fire|up)|right away|immediately|straight away|don'?t wait)\b", re.I),
    "range": re.compile(r"\b(back|closer|close|far|farther|further|away|range|distance|in tight|get in|step in|up front|"
                        r"closer in)\b", re.I),
    "specials": re.compile(r"\b(specials?|save|conserve|hold back|go easy|waste|all out|everything|full|unleash|spam|"
                           r"energy|action|mind)\b", re.I),
    "protect": re.compile(r"\b(protect|guard|cover|defend|look after|look out for|watch|take care of|keep \w+ safe|"
                          r"taunt|rescue|grab|first)\b", re.I),
    "healAt": re.compile(r"\b(heal|healing|stims?|top (us |them |off|up)|topped|earlier|sooner|keep \w+ (up|above|over)|"
                         r"before (they|we|it)|below|under|only when)\b", re.I),
    "reviveFirst": re.compile(r"\b(revive|reviving|rez|raise|bring back|before|first|after|last)\b", re.I),
    "packs": re.compile(r"\b(packs?|poison|disease|dots?|area|single|throwing|just heal|only heal|heal(s|ing)? only)\b", re.I),
    "mindFloor": re.compile(r"\b(mind|packs?|conserve|save|floor)\b", re.I),
    "shoot": re.compile(r"\b(shoot|shooting|fire|firing|attack|attacking|fight|fighting|just heal|only heal|heal(s|ing)? only|"
                        r"nothing but|keep (out|your head|down)|stay out|stand back|hold fire)\b", re.I),
    "area": re.compile(r"\b(grenades?|cones?|flame|area|aoe|splash|burn|fire|big stuff)\b", re.I),
    "retreatAt": re.compile(r"\b(retreat|fall back|pull out|bail|run|earlier|sooner|later|call it|give up|panic|lost)\b", re.I),
    "calls": re.compile(r"\b(calls?|calling|rally|volley|form ?up|steady aim|aim|quiet|shut up|stop (calling|talking|yelling)|"
                        r"command|orders?)\b", re.I),
}
# And for some values, the words that say that value (so "closer" can't become "far")
VALUE_WORDS = {
    ("range", "close"): re.compile(r"\b(close|closer|in tight|get in|step in|up front|in close)\b", re.I),
    ("range", "far"): re.compile(r"\b(back|far|farther|further|away|range|distance|stay back|hang back)\b", re.I),
    ("range", "band"): re.compile(r"\b(normal|usual|regular|as usual|default|band|where you were)\b", re.I),
    ("specials", "save"): re.compile(r"\b(save|conserve|hold back|go easy|careful|waste|stop|easy|ration|spare)\b", re.I),
    ("specials", "full"): re.compile(r"\b(all out|everything|full|unleash|spam|use (all|your|every)|go (all|wild|hard)|whatever you)\b", re.I),
    ("shoot", "no"): re.compile(r"\b(just|only|nothing but|stop|don'?t|no|keep (out|your head|down)|stay out|stand back|hold fire|"
                                r"put (the|your))\b", re.I),
    ("shoot", "yes"): re.compile(r"\b(shoot|fire|attack|fight|join in|help|back in|again|as you were)\b", re.I),
    ("area", "cones"): re.compile(r"\b(grenades?|cones? only|only cones?|no grenades?)\b", re.I),
    ("area", "none"): re.compile(r"\b(no (area|aoe|cones?|flame|splash)|no cones? or|stop (the )?(cones?|flame|area)|nothing)\b", re.I),
    ("area", "both"): re.compile(r"\b(both|everything|grenades? (again|too|ok)|use (the )?grenades?|all of it|cones? and grenades?|as you were)\b", re.I),
    ("packs", "none"): re.compile(r"\b(no (packs?|poison|disease|dots?)|just heal|only heal|heal(s|ing)? only|stop|don'?t|nothing but)\b", re.I),
    ("packs", "single"): re.compile(r"\b(single|one at a time|no area|not the area)\b", re.I),
    ("packs", "area"): re.compile(r"\b(area|both|clump|groups?|as you were)\b", re.I),
    ("reviveFirst", "no"): re.compile(r"\b(after|last|before (you )?revive|before reviving|living first|heal first|heal the living)\b", re.I),
    ("reviveFirst", "yes"): re.compile(r"\b(revive (first|before)|rez first|reviving first|before (anything|everything)|first)\b", re.I),
    ("focus", "strongest"): re.compile(r"\b(big|biggest|strongest|toughest|largest|boss|hardest|big one)\b", re.I),
    ("focus", "weakest"): re.compile(r"\b(weak|weakest|small|smallest|little|easiest|runt|squishy|finish)\b", re.I),
    ("focus", "leader"): re.compile(r"\b(my target|i'?m (hitting|attacking)|leader|my|me)\b", re.I),
}
CLEAR_WORDS = re.compile(r"\b(as you were|back to normal|carry on as (before|usual)|reset (your |the )?(orders|tactics)|stand down|"
                         r"forget (the |my |those )?orders|at ease|belay that|drop (the |my )?orders|normal orders)\b", re.I)

CREW_WORDS = re.compile(r"\b(everyone|everybody|all of you|you all|y'?all|you guys|the crew|crew|team|you lot|the boys|boys|"
                        r"squad|the rest|the others|all)\b", re.I)

# A lesson: an explicit "from now on", or "always", "never", "every time", "when X, do Y"... opening a clause (after an address and
# a word or two of lead-in), so banter like "you always know what to say" is not one
_LEAD = (r"(?:(?:hey|ok|okay|alright|right|so|now|yo|listen|guys|everyone|everybody|crew|team|all|please|pls|plz|and|just)\b[\s,]*)*"
         r"(?:[a-z']+,\s*)?(?:(?:please|pls|plz)\s+)?(?:you(?:'d| should| must| need to| have to| better| gotta| will)\s+)?")
TEACH_WORDS = re.compile(r"\b(from now on|from here on|henceforth|going forward|in (the )?future)\b|(?:^|[.!?;:]\s*)" + _LEAD +
                         r"(always|never(?! ?mind)|every time|each time|whenever|make sure|remember to|don'?t ever|do not ever)\b|"
                         r"(?:^|[.!?;:]\s*)" + _LEAD + r"when\b[^.!?]{2,60},\s*\w+", re.I)
# (only words about the lessons themselves: "forget that, ..." and "forget about it" are chat, not a wipe)
FORGET_ALL = re.compile(r"\b(unlearn|forget (what i('ve| have)? (told|taught|said to) you|everything i('ve| have)? (told|taught)|"
                        r"all (that |of that |of what )?i('ve| have)? (told|taught)|my lessons|what you('ve| have)? learn(ed|t))|"
                        r"forget (your|the) (doctrine|lessons|training|teaching)|clear (your |the )?(lessons|taught|doctrine)|"
                        r"wipe (your |the )?(lessons|doctrine))\b", re.I)
# A lesson the words alone carry; "always" / "never" / "when X, Y" also need the model to have heard one
EXPLICIT_TEACH = re.compile(r"\b(from now on|from here on|henceforth|going forward|in (the )?future|every time|each time|whenever|"
                            r"make sure|remember to|don'?t ever|do not ever)\b", re.I)
# "Always a pleasure", "never seen so many kreetles", "never again": banter, whatever the model says
NOT_LESSON = re.compile(r"\b(always|never)\s+(a|an|the|nice|good|great|fun|glad|happy|seen|again|been|was|were|had|thought|knew|"
                        r"liked?|loved?|ever|gonna|going to|before|enough|easy|boring|dull|disappoints?|fails?|gets? old)\b", re.I)
FORGET_BIT = re.compile(r"\bforget (?:about |the bit about |the bit on |the part about |the part on |what i said about |that bit about |"
                        r"the thing about |the lesson about |the rule about )(?P<what>[^.!?]+)", re.I)
DOCTRINE_Q = re.compile(r"\b(what'?s|whats|what is|what are|tell me|show me|sum up|summari[sz]e|remind me)\b[^.!?]{0,24}\b(doctrine|"
                        r"standing orders|rules|training|instructions|lessons|orders)\b|\bhow do you fight\b|\bhow (do|will) you "
                        r"play (it|this|a fight|a hunt)\b|\bwhat do you do in a fight\b|\bwhat'?s your (plan|style)\b", re.I)

_STOP = {"the", "bit", "about", "that", "those", "thing", "part", "what", "this", "told", "you", "your", "and", "for", "with"}


def parse_squad(text):
    """"cameren:player,kragoth:tank" -> {"cameren": "player", "kragoth": "tank"}"""
    out = {}
    for part in str(text or "").split(","):
        first, _, role = part.partition(":")
        first, role = first.strip().lower(), role.strip().lower()
        if re.fullmatch(r"[a-z][a-z']*", first) and role:
            out[first] = role
    return out


def parse_creatures(text):
    """The fight's lines "oid name level N hp N on first Nm" -> [(oid, lowercase name)]"""
    out = []
    for line in str(text or "").splitlines():
        m = re.match(r"\s*(\d+)\s+(.+?)\s+level\s+\d+", line)
        if m:
            out.append((int(m.group(1)), m.group(2).strip().lower()))
    return out


def _named(text, squad, crew_only=True):
    """The squad firsts the text names, in the order it names them."""
    found = []
    for m in re.finditer(r"[a-z][a-z']*", text.lower()):
        word = m.group(0)
        if word in squad and (not crew_only or squad[word] != "player") and word not in found:
            found.append(word)
    return found


def _role_first(squad, role, named=()):
    for first in named:
        if squad.get(first) == role:
            return first
    for first, r in squad.items():
        if r == role:
            return first
    return None


def _targets(entry, text, squad, answering, to):
    """Whom an order is for: its "to" (a first name or crew), checked against the squad and the roles that have the entry."""
    to = str(to or "").strip().lower()
    if to in ("", "self", "me", "you"):
        to = answering
    elif to in ("crew", "everyone", "all", "*", "everybody", "team"):
        to = "*"
    if to == "*":
        return "*"
    if to in squad and squad[to] != "player" and applies(entry, squad[to]):
        return to
    if not squad and to == answering:
        return to
    return None


def _value_ok(entry, value, text):
    words = VALUE_WORDS.get((entry, value))
    if words is not None and not words.search(text):
        return False
    if entry == "hold" and int(value) == 0:
        return bool(re.search(r"\b(don'?t wait|no need|without wait|right away|straight away|immediately|not wait|stop wait)", text, re.I))
    return True


def plain_orders(text, squad, creatures, answering):
    """Orders the words give by themselves, for the model that forgot them or got them wrong: the examples from the spec.
    -> list of (target, entry, value)."""
    t = text.lower()
    out = []
    named = _named(t, squad)
    addressed = named[0] if named else None

    def add(target, entry, value):
        if target is not None and (target, entry, value) not in out:
            out.append((target, entry, value))

    if re.search(r"\b(just|only) (heal|healing|heals)\b|\bheal(s|ing)? only\b|\bnothing but (heal|healing)\b|\bstop shooting\b|"
                 r"\bkeep (out of it|your head down)\b|\bstay out of (it|the fight)\b", t):
        medic = addressed if squad.get(addressed) == "medic" else _role_first(squad, "medic", named)
        if re.search(r"\bstop shooting\b|\bkeep (out of it|your head down)\b|\bstay out of (it|the fight)\b", t) and \
                not re.search(r"\bheal", t):
            add(medic, "shoot", "no")
        else:
            add(medic, "shoot", "no")
            add(medic, "packs", "none")
    if re.search(r"\b(save|hold|keep|stop|no) (the |your |those )?grenades?\b|\bno grenades?\b|\bdon'?t (use|throw) (the |your )?grenades?\b|"
                 r"\bcones? only\b", t):
        add(_role_first(squad, "commando", named), "area", "cones")
    if re.search(r"\b(stay|keep|hang) (back|away)\b(?! off)|\b(further|farther) back\b|\bkeep your distance\b|\bat (long )?range\b", t) and \
            not re.search(r"\bstay back (with|by|at) me\b", t):
        add("*", "range", "far")
    if re.search(r"\b(get|move|come|step|stay|stand) (in )?(a bit |a little )?closer\b|\bin closer\b|\bget in (tight|close)\b", t):
        add("*", "range", "close")
    if re.search(r"\b(don'?t|dont|no need to|stop) wait(ing)?( for (the )?tank)?\b|\bwithout waiting\b", t):
        add("*", "hold", "0")
    m = re.search(r"\bprotect (?:the )?([a-z][a-z']*)", t)
    if m:
        who = m.group(1)
        who = "medic" if who in ("medic", "doc", "healer", "doctor") else who
        if who == "medic" or who in squad:
            before = t[:m.start()]
            holder = next((f for f in _named(before, squad) if squad[f] in ("tank", "ranger")), None)
            if holder is None:
                holder = "*"
            if holder == "*" or who != holder:
                add(holder, "protect", who)
    if re.search(r"\b(focus|kill|attack|take (it |them )?(down|out)|burn|target|drop)\b[^.!?]*\b(big|biggest|strongest|toughest|largest|"
                 r"boss)\b|\b(big|biggest) one\b", t):
        add("*", "focus", "strongest")
    elif re.search(r"\b(focus|kill|attack|take (it |them )?(down|out)|burn|target|drop|finish)\b[^.!?]*\b(weakest|smallest|runt|"
                   r"easiest|little one)\b", t):
        add("*", "focus", "weakest")
    elif re.search(r"\b(the one|the ones|whatever'?s|what'?s) (that'?s |that is |which is )?on (the )?(%s)\b" %
                   "|".join(["medic", "doc", "healer", "doctor"] + [re.escape(f) for f, r in squad.items() if r == "medic"]), t):
        add("*", "focus", "medic")
    else:
        for oid, name in creatures:
            if name and re.search(r"\b(kill|focus|attack|target|take out|burn)\b[^.!?]*\b%s\b" % re.escape(name), t):
                add("*", "focus", "creature:%d" % oid)
                break
    if re.search(r"\b(save|conserve|go easy on|don'?t waste)( your| the)? (specials|mind|energy|action)\b", t):
        add("*", "specials", "save")
    elif re.search(r"\bgo all out\b|\b(use|unleash)( all| every| your)? (your )?(specials|everything)\b", t):
        add("*", "specials", "full")
    if re.search(r"\b(heal|revive) (the living |us |them )?(first|before (you )?revive|before reviving)\b|\brevive (last|after)\b|"
                 r"\bheal the living (first|before)\b", t) and re.search(r"\bheal", t):
        add(_role_first(squad, "medic", named), "reviveFirst", "no")
    elif re.search(r"\brevive (first|before (anything|everything))\b|\brez first\b", t):
        add(_role_first(squad, "medic", named), "reviveFirst", "yes")
    if re.search(r"\bno (packs|poison|disease|dots)\b|\bstop (throwing|using) (the )?(packs|poison|disease|dots)\b", t):
        add(_role_first(squad, "medic", named), "packs", "none")
    return out


def check_orders(text, proposed, squad, creatures, answering, action=""):
    """What the bot's reply may order: (orders, clear). orders: a "target entry value;..." text for reply line 6 ("*" is the
    whole crew; "clear" ends every order). The model's proposals stand only when the player's words give an order and say
    the entry (and the value); the spec's plain orders are added when the model missed them."""
    if action in ("follow", "stay", "home", "join", "call"):
        return ""
    t = re.sub(r"\s+", " ", text).strip()
    if CLEAR_WORDS.search(t):
        named = _named(t, squad)
        target = named[0] if named and not CREW_WORDS.search(t) else "*"
        return "%s clear" % target
    if not order_shaped(t):
        return ""
    ids = [oid for oid, _name in creatures]
    names = [f for f in squad]
    items = []
    if isinstance(proposed, list):
        for item in proposed[:8]:
            if not isinstance(item, dict):
                continue
            entry = str(item.get("entry") or "").strip()
            if entry not in TACTICS:
                continue
            value = clean_value(entry, item.get("value"), ids, names)
            if value is None:
                continue
            target = _targets(entry, t, squad, answering, item.get("to"))
            if target is None or not ORDER_WORDS[entry].search(t) or not _value_ok(entry, value, t):
                continue
            if entry == "focus" and value.startswith("creature:"):
                oid = int(value.split(":")[1])
                name = next((n for o, n in creatures if o == oid), "")
                if not name or not re.search(r"\b%s\b" % re.escape(name.split()[-1]), t):
                    continue
            if entry == "protect" and value != "medic" and not re.search(r"\b%s\b" % re.escape(value), t):
                continue
            items.append((target, entry, value))
    for target, entry, value in plain_orders(t, squad, creatures, answering):
        if not any(i[1] == entry for i in items):
            items.append((target, entry, value))
    return ";".join("%s %s %s" % item for item in items)


def _sentence(line):
    line = re.sub(r"\s+", " ", line.translate({0x2019: "'", 0x2018: "'", 0x201c: '"', 0x201d: '"', 0x2014: "-", 0x2013: "-"}))
    line = line.encode("ascii", "ignore").decode("ascii").replace("*", "").strip().strip('"').strip()
    if len(line) > MAX_TAUGHT_CHARS:
        cut = max(line.rfind(c, 0, MAX_TAUGHT_CHARS) for c in ".!?")
        line = line[:cut + 1] if cut > 30 else line[:MAX_TAUGHT_CHARS].rstrip()
    if line and line[-1] not in ".!?":
        line += "."
    return line[:1].upper() + line[1:]


def plain_lesson(text):
    """The lesson in a plain "from now on ..." / "always ..." / "never ..." clause, for the model that forgot it, or ''."""
    m = re.search(r"(?:^|[.!?,;:]\s*)(?:[a-z][a-z']*,?\s+){0,2}?(from now on|from here on|going forward|in (?:the )?future)[,:]?\s+(?P<rest>[^.!?]+)",
                  text, re.I)
    if m:
        return _sentence(m.group("rest"))
    m = re.search(r"(?:^|[.!?,;:]\s*)(?:[a-z][a-z']*,?\s+){0,2}?(?P<word>always|never)\s+(?P<rest>[^.!?]+)", text, re.I)
    if m:
        return _sentence(m.group("word") + " " + m.group("rest"))
    return ""


def check_teach(text, proposed, proposed_to, squad, answering):
    """A lesson or a forget the player's words back: None, or a dict {op: add|forget, to: first or crew, line, words}."""
    t = re.sub(r"\s+", " ", text).strip()
    # (a lesson is for the bot spoken to, "Quillan, from now on ...", else the one who answers; names inside the lesson don't count)
    vocative = re.match(r"\W*(?:(?:hey|ok|okay|yo|oi|alright|right|so|now)\W+)*([a-z][a-z']*)\s*[,:]", t, re.I)
    named = vocative.group(1).lower() if vocative and vocative.group(1).lower() in squad and \
        squad[vocative.group(1).lower()] != "player" else None
    others = [named] if named is not None and named != answering else []
    # (a bot named at the start wins: "Quillan, from now on top everyone up" is Quillan's, whatever "everyone" says;
    # the model's own "teach_to" counts only when the words also speak to the whole crew)
    if named is not None:
        target = named
    elif CREW_WORDS.search(t) and (str(proposed_to or "").strip().lower() == "crew" or
                                 re.search(r"\b(everyone|everybody|all of you|you all|y'?all|you guys|the crew|crew|team|you lot|the boys|boys|squad)\b", t, re.I)):
        target = "crew"
    elif len(others) == 1:
        target = others[0]
    else:
        target = answering
    # ("as you were" clears orders, never lessons)
    clearing = CLEAR_WORDS.search(t)
    if FORGET_ALL.search(t) and not clearing:
        return {"op": "forget", "to": target, "words": None}
    m = None if clearing else FORGET_BIT.search(t)
    if m:
        words = [w for w in re.findall(r"[a-z']+", m.group("what").lower()) if w not in _STOP and len(w) >= 3]
        if words:
            return {"op": "forget", "to": target, "words": words}
    if not order_shaped(t) or not TEACH_WORDS.search(t):
        return None
    explicit = EXPLICIT_TEACH.search(t)
    if not explicit and NOT_LESSON.search(t):
        return None
    line = _sentence(proposed) if isinstance(proposed, str) and proposed.strip() and proposed.strip().lower() not in ("none", "forget") \
        and not proposed.strip().lower().startswith("forget") else ""
    if len(line.split()) < 2 and not explicit:
        return None
    if len(line.split()) < 2:
        line = plain_lesson(t)
    if len(line.split()) < 2:
        return None
    return {"op": "add", "to": target, "line": line}


# The model's JSON ---------------------------------------------------------------------------------------------------------

def extract_json(content):
    """The first {...} object in a model's reply, or None."""
    match = re.search(r"\{.*\}", content or "", re.S)
    if not match:
        return None
    try:
        obj = json.loads(match.group(0))
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


# Base tables: a doctrine turned into a table, once whenever it changes

def table_messages(first, role, text):
    system = (
        f"You set up the fight logic of {first.title()}, a {role} in a hunting crew in the Star Wars galaxy. The logic reads a "
        "tactics table. Every entry has a default (today's behaviour) and fixed limits. Read the doctrine below, which is how "
        f"{first.title()} is meant to fight, and set an entry only where the doctrine asks for something other than the default; "
        "leave out everything the doctrine doesn't speak to. Do not invent changes the doctrine doesn't ask for. Many doctrine "
        "lines describe what the default already does (the descriptions say so): those change nothing.\n\n"
        "The entries this role has:\n" + describe_entries([role]) + "\n\n"
        "Name a member (protect) by first name in lowercase. focus can't name a creature here (that is for one fight). "
        'Answer with JSON only, for example {"tactics": {"healAt": 0.8, "shoot": "no"}}, or {"tactics": {}} when the doctrine '
        "changes nothing.")
    return [{"role": "system", "content": system}, {"role": "user", "content": "Doctrine:\n" + text}]


def parse_table(content, role, names=()):
    """The model's reply -> {entry: value} (checked), or None when it isn't a table at all."""
    obj = extract_json(content)
    if obj is None:
        return None
    table = obj.get("tactics", obj.get("table"))
    if not isinstance(table, dict):
        return None
    return clean_table(role, {k: v for k, v in table.items() if k != "focus" or not str(v).lower().startswith("creature")},
                       (), names)


# Plans: the fight's situation -> changes for this fight

_MEMBER = re.compile(r"^(\S+) (\S+) hp (\d+) action (\d+) mind (\d+) (up|down) (\d+)m\s*$")


def parse_members(text):
    """The plan request's crew lines -> {first: {role, hp, action, mind, up, dist}}"""
    out = {}
    for line in str(text or "").splitlines():
        m = _MEMBER.match(line.strip())
        if m:
            out[m.group(1).lower()] = {"role": m.group(2), "hp": int(m.group(3)), "action": int(m.group(4)),
                                       "mind": int(m.group(5)), "up": m.group(6) == "up", "dist": int(m.group(7))}
    return out


def parse_orders(text):
    """Standing orders "first entry value" lines -> {(first, entry): value}"""
    out = {}
    for line in str(text or "").splitlines():
        parts = line.split()
        if len(parts) == 3:
            out[(parts[0].lower(), parts[1])] = parts[2]
    return out


def plan_messages(r, doctrines, bases):
    """The plan prompt for a request. doctrines: {first: text}; bases: {first: [table lines]}."""
    members = parse_members(r.get("crew"))
    roles = sorted({m["role"] for m in members.values() if m["role"] in ALL_ROLES})
    system = (
        "You are the tactician of a small hunting crew in the Star Wars galaxy during the Galactic Civil War. The crew fights "
        "alongside a player. You never move anyone: the crew's fight logic runs every second and a half and reads a tactics table "
        "for each member. You set entries of those tables for THIS fight, only where the situation calls for something other than "
        "what each member's doctrine and base table already give. Most plans change little or nothing.\n\n"
        "The entries, by role:\n" + describe_entries(roles) + "\n\n"
        "Rules: members are named by first name in lowercase. focus may name a creature only from the creatures listed, as "
        "creature:<oid>. An entry that has a standing order from a player isn't yours to change. Members that are down, and "
        "players, get no changes. The fight logic keeps its own hard rules (the medic heals anyone close to death first, area "
        "attacks never hit creatures that aren't fighting the group, the crew retreats when three are down), so don't try to "
        "set those. What you return replaces the plan so far, so repeat the changes you still want.\n\n"
        'Answer with JSON only: {"changes": [{"bot": "<first>", "entry": "<entry>", "value": "<value>"}], "say": {"bot": '
        '"<first>", "text": "<one short line for group chat, in character>"}}. Leave "say" out unless a member would '
        "really call something out (where the heals should go, who takes the add); at most one line, no out-of-world words.")
    lines = [f"Why now: {r.get('reason', 'the fight changed')}.", f"The leader (a player) is {r.get('leader', 'the player')}.",
             "The group:", str(r.get("crew") or "(nobody)"), "Creatures attacking the group (oid name level hp on whom distance):",
             str(r.get("creatures") or "(none)"), "A lair is being fought: " + ("yes" if r.get("lair") else "no"),
             "Standing orders from the players:", str(r.get("orders") or "(none)"), "The plan so far:",
             str(r.get("plan") or "(none)"), "", "Doctrines:"]
    for first in members:
        if first in doctrines and members[first]["role"] in ALL_ROLES:
            lines.append(f"== {first} ({members[first]['role']}) ==")
            lines.append(doctrines[first] or "(none)")
            lines.append("Base table: " + (", ".join(bases.get(first, [])) or "all defaults"))
    return [{"role": "system", "content": system}, {"role": "user", "content": "\n".join(lines)}]


def parse_plan(content, r, clean_say=None):
    """The model's plan -> reply lines ("first entry value", then "say first text"), checked against the request: only members
    who are up and have the entry, creatures from the list, no entry a standing order holds."""
    obj = extract_json(content)
    if obj is None:
        return None
    members = parse_members(r.get("crew"))
    creatures = [oid for oid, _name in parse_creatures(r.get("creatures"))]
    names = list(members)
    held = set(parse_orders(r.get("orders")))
    lines, seen = [], set()
    changes = obj.get("changes")
    for item in (changes if isinstance(changes, list) else [])[:20]:
        if not isinstance(item, dict):
            continue
        first, entry = str(item.get("bot") or "").strip().lower(), str(item.get("entry") or "").strip()
        member = members.get(first)
        if member is None or not member["up"] or member["role"] not in ALL_ROLES or not applies(entry, member["role"]):
            continue
        if (first, entry) in held or (first, entry) in seen:
            continue
        value = clean_value(entry, item.get("value"), creatures, names)
        if value is None:
            continue
        seen.add((first, entry))
        lines.append("%s %s %s" % (first, entry, value))
    say = obj.get("say")
    if isinstance(say, dict):
        first, text = str(say.get("bot") or "").strip().lower(), say.get("text")
        member = members.get(first)
        if member is not None and member["up"] and member["role"] in ALL_ROLES and isinstance(text, str):
            text = clean_say(text) if clean_say else text.strip()
            if text:
                lines.append("say %s %s" % (first, text))
    return lines
