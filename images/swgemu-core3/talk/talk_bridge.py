#!/usr/bin/env python3
"""Living Cities talk bridge: lets Core3's player-looking NPCs answer players through LiteLLM.

Core3's Lua can't make network calls without stalling a server thread, so it talks to this process through files on a
shared directory (an emptyDir in the core3 pod):

  req/<id>.json   written by Lua (temp file, then rename): {"type": "say" | "gone" | "warm", ...}
  rep/<id>.txt    written here (temp file, then rename), read and removed by Lua:
                    line 1: "ok" or "fallback"; line 2: a mood (may be empty); line 3: what the NPC says

"say" carries the NPC's persona (name, species, sex, kit, city, place), the player's name and what they said; the
reply comes from the model with the NPC's city fact sheet and the last exchanges between the two. "gone" drops an
NPC's memory (it logged out). "warm" keeps the model loaded while players are near a crowd, so the first question
doesn't wait for Ollama to load it.

Standard library only. Settings come from the environment:
  TALK_DIR (/run/talk), LITELLM_URL (http://litellm.litellm.svc:4000/v1), LITELLM_KEY, TALK_MODEL (vm/qwen3.8:27b),
  TALK_FACTS (/opt/swgemu/talk/facts.json), TALK_DEADLINE (seconds Lua waits for a reply, 12)

  python3 talk_bridge.py                       # run
  python3 talk_bridge.py --ask mos_eisley "where's the bank?"   # one question from the command line, for testing
"""
import argparse
import collections
import json
import os
import queue
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
                    r"server|video ?game|npc|real world|internet)\b", re.I)


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
            "character or in a game; you don't know those words. If asked about things that don't exist in this galaxy, "
            "be puzzled and change the subject, in character. Don't promise to trade, give items, group up, travel with "
            "them or meet later. Keep it PG-13. Use only the places below when giving directions; if you don't know, say "
            "so.\n\n"
            f"What you know about {city.get('name', 'this town')}:\n{city.get('text', '(nothing in particular)')}\n\n"
            'Answer with JSON only: {"say": "<what you say>", "mood": "<one of: ' + ", ".join(MOODS) + '>"}'
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
    def clean(content, asked=""):
        """The model's JSON (or bare text) -> (mood, text), or None if it's unusable. Out-of-world words are only
        allowed when the player used them first (a puzzled "NPC? Never heard the term" is fine)."""
        mood, text = "", content.strip()
        match = re.search(r"\{.*\}", text, re.S)
        if match:
            try:
                obj = json.loads(match.group(0))
                text, mood = str(obj.get("say", "")), str(obj.get("mood", ""))
            except ValueError:
                pass
        text = text.translate(ASCII).encode("ascii", "ignore").decode("ascii")
        text = re.sub(r"\s+", " ", text.replace("*", "")).strip().strip('"').strip()
        if mood not in MOODS:
            mood = ""
        used = {m.group(0).lower() for m in BANNED.finditer(asked)}
        if not text or any(m.group(0).lower() not in used for m in BANNED.finditer(text)):
            return None
        if len(text) > MAX_CHARS:
            cut = max(text.rfind(c, 0, MAX_CHARS) for c in ".!?")
            text = text[:cut + 1] if cut > 40 else text[:MAX_CHARS - 3].rstrip() + "..."
        return mood, text

    def answer(self, r, timeout):
        turns = self.remember(r)
        messages = [{"role": "system", "content": self.system_prompt(r)}] + list(turns) + \
                   [{"role": "user", "content": r.get("text", "")}]
        result = self.clean(self.complete(messages, 90, timeout), r.get("text", ""))
        if result is not None:
            turns.append({"role": "user", "content": r.get("text", "")})
            turns.append({"role": "assistant", "content": json.dumps({"say": result[1], "mood": result[0]})})
        return result

    # Requests and replies

    def reply(self, rid, result):
        path = os.path.join(TALK_DIR, "rep", rid + ".txt")
        if result is None:
            write_atomic(path, "fallback\n\n\n")
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
                # Lua stops waiting at the deadline (from when it wrote the request)
                left = DEADLINE - 1 - (time.time() - float(r.get("at", queued)))
                if left < 1:
                    self.reply(r["id"], None)
                    log("late", r.get("name"), "-> fallback")
                    continue
                started = time.time()
                try:
                    result = self.answer(r, left)
                except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError) as e:
                    log("error", r.get("name"), type(e).__name__, str(e)[:120])
                    result = None
                self.reply(r["id"], result)
                log("say", "%.1fs" % (time.time() - started), r.get("city"), r.get("name"), "<-", repr(r.get("text", "")[:60]),
                    "->", repr(result[1]) if result else "fallback")
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
                # Answer it anyway, so the NPC doesn't wait out the deadline
                if re.fullmatch(r"[A-Za-z0-9_-]+", name[:-5]):
                    self.reply(name[:-5], None)
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
    args = parser.parse_args()
    bridge = Bridge(load_facts())
    if args.ask:
        r = {"npc": 1, "player": 2, "name": "Tarn Vosk", "species": args.species, "sex": "male", "kit": args.kit,
             "city": args.ask[0], "place": "plaza", "hour": 20, "playerName": "Cameren", "text": args.ask[1]}
        started = time.time()
        print(bridge.answer(r, 30), "%.1fs" % (time.time() - started))
        return
    bridge.run()


if __name__ == "__main__":
    sys.exit(main())
