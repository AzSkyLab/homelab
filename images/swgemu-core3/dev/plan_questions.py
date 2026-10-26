#!/usr/bin/env python3
"""Ask the model for the crew's fight plans (Phase 9b): ten fight situations, the same request the crew's Lua writes.

  LITELLM_URL=https://llm.home.lab/v1 LITELLM_KEY=... python3 dev/plan_questions.py            # the ten situations
  LITELLM_URL=... LITELLM_KEY=... python3 dev/plan_questions.py --with-chat 2                # ...with crowd chat in flight
  python3 dev/plan_questions.py --check                                                      # the parser alone, no model

Uses the real bridge code (../talk/): the plan prompt, the model call and the checks on what it says. For each situation it
prints the plan the bridge would send back (the "first entry value" lines and the line to say), whether the reply was a valid
plan, how many of the model's changes the bridge kept (a change to an entry the role hasn't, a creature that isn't in the list,
a member who is down or a standing order's entry is dropped), and the latency. The summary has the median and the worst
latency, with and without --with-chat (crowd chat asked of the same model in the background, as in the pod, where plans share
the 3090 with the crowd). A plan older than 15 s is dropped by the bridge and Lua, so the worst latency matters.

Exits 1 if any reply wasn't a valid plan, or if --check finds the parser wrong.
"""
import argparse
import json
import os
import statistics
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "talk"))
import crew_doctrine as cd  # noqa: E402
import talk_bridge  # noqa: E402

CREW = [("kragoth", "tank"), ("senna", "rifleman"), ("quillan", "medic"), ("weeta", "ranger"), ("tavik", "squadleader"),
        ("ilsi", "entertainer"), ("brask", "commando")]


def member(first, role, hp=100, action=100, mind=100, up=True, dist=15):
    return "%s %s hp %d action %d mind %d %s %dm" % (first, role, hp, action, mind, "up" if up else "down", dist)


def crew_lines(hurt=None, down=(), mind=None):
    """The group as the Lua writes it: the leader, then the seven. hurt: {first: hp}; down: firsts; mind: {first: mind}."""
    hurt, mind = hurt or {}, mind or {}
    lines = [member("cameren", "player", hurt.get("cameren", 100), dist=0)]
    for first, role in CREW:
        lines.append(member(first, role, hurt.get(first, 100), 100, mind.get(first, 100), first not in down,
                            {"tank": 4, "rifleman": 26, "medic": 28, "ranger": 5, "squadleader": 16, "entertainer": 16,
                             "commando": 12}[role]))
    return "\n".join(lines)


def creature(oid, name, level, hp, on, dist):
    return "%d %s level %d hp %d on %s %dm" % (oid, name, level, hp, on, dist)


# (name, the request's fields): ten situations a hunt meets
SITUATIONS = [
    ("pull: one womp rat", dict(reason="pull", crew=crew_lines(), creatures=creature(5001, "womp rat", 6, 100, "none", 40))),
    ("pull: a bantha and its calf", dict(reason="pull", crew=crew_lines(), creatures="\n".join([
        creature(5001, "bantha", 28, 100, "kragoth", 20), creature(5002, "bantha calf", 10, 100, "none", 22)]))),
    ("an add on the medic", dict(reason="add", crew=crew_lines(), creatures="\n".join([
        creature(5001, "dune lizard", 14, 60, "kragoth", 12), creature(5002, "dune lizard", 14, 100, "quillan", 22)]))),
    ("the medic is low on mind", dict(reason="mind", crew=crew_lines(mind={"quillan": 22}), creatures="\n".join([
        creature(5001, "krayt dragon", 80, 70, "kragoth", 18)]))),
    ("a member under 30%", dict(reason="low", crew=crew_lines(hurt={"senna": 24}), creatures="\n".join([
        creature(5001, "gurrek", 30, 80, "senna", 25), creature(5002, "gurrek", 30, 90, "kragoth", 14)]))),
    ("the tank is down", dict(reason="down", crew=crew_lines(hurt={"cameren": 55, "weeta": 35}, down=("kragoth",)),
                              creatures="\n".join([creature(5001, "tusken raider", 40, 100, "weeta", 15),
                                                   creature(5002, "tusken raider", 40, 100, "cameren", 5)]))),
    ("the medic is down", dict(reason="down", crew=crew_lines(hurt={"kragoth": 45}, down=("quillan",)), creatures="\n".join([
        creature(5001, "sand panther", 22, 100, "kragoth", 8)]))),
    ("a lair's next wave", dict(reason="wave", lair=1, crew=crew_lines(hurt={"kragoth": 70}), creatures="\n".join([
        creature(5001, "kreetle", 8, 100, "kragoth", 12), creature(5002, "kreetle", 8, 100, "kragoth", 13),
        creature(5003, "kreetle", 8, 100, "none", 20), creature(5004, "kreetle", 8, 100, "none", 21)]))),
    ("standing orders: just heal, and the commando's cones only", dict(
        reason="add", crew=crew_lines(), creatures="\n".join([creature(5001, "gurrek", 30, 100, "kragoth", 14),
                                                                creature(5002, "gurrek", 30, 100, "kragoth", 15),
                                                                creature(5003, "gurrek", 30, 100, "kragoth", 16)]),
        orders="quillan shoot no\nquillan packs none\nbrask area cones")),
    ("a plan already made, a new add", dict(reason="add", crew=crew_lines(hurt={"kragoth": 80}), creatures="\n".join([
        creature(5001, "bantha", 28, 40, "kragoth", 12), creature(5002, "wolf", 20, 100, "kragoth", 25)]),
        plan="kragoth focus strongest\nquillan healAt 0.85")),
]


def request(fields, rid):
    r = {"type": "plan", "id": rid, "at": int(time.time()), "leader": "cameren", "lair": 0, "orders": "", "plan": ""}
    r.update(fields)
    return r


# The parser alone (--check): canned replies from a model, and what the bridge keeps
PARSE_CREW = crew_lines(down=("senna",))
PARSE_REQ = {"crew": PARSE_CREW, "creatures": creature(5001, "bantha", 28, 100, "kragoth", 20) + "\n" +
             creature(5002, "gurrek", 30, 100, "none", 25), "orders": "quillan packs none\nbrask area cones", "plan": ""}
PARSE_CASES = [
    # (what the model said, the lines the bridge keeps (None: not a plan))
    ('{"changes": [{"bot": "kragoth", "entry": "focus", "value": "creature:5001"}, {"bot": "quillan", "entry": "healAt", "value": "0.85"}]}',
     ["kragoth focus creature:5001", "quillan healAt 0.85"]),
    ('```json\n{"changes": [{"bot": "weeta", "entry": "range", "value": "far"}], "say": {"bot": "tavik", "text": "Rally on the tank!"}}\n```',
     ["weeta range far", "say tavik Rally on the tank!"]),
    # Limits: numbers clamped, unknown words and entries dropped
    ('{"changes": [{"bot": "quillan", "entry": "healAt", "value": "0.99"}, {"bot": "quillan", "entry": "mindFloor", "value": 95},'
     ' {"bot": "weeta", "entry": "hold", "value": 12}, {"bot": "weeta", "entry": "range", "value": "sideways"},'
     ' {"bot": "weeta", "entry": "bogus", "value": "x"}]}', ["quillan healAt 0.90", "quillan mindFloor 0.80", "weeta hold 6"]),
    # A role without the entry, a creature that isn't there, a member who is down, an entry a standing order holds
    ('{"changes": [{"bot": "senna", "entry": "shoot", "value": "no"}, {"bot": "kragoth", "entry": "healAt", "value": 0.8},'
     ' {"bot": "kragoth", "entry": "focus", "value": "creature:9999"}, {"bot": "quillan", "entry": "packs", "value": "single"},'
     ' {"bot": "brask", "entry": "area", "value": "both"}, {"bot": "nobody", "entry": "focus", "value": "weakest"}]}', []),
    ('{"changes": [{"bot": "kragoth", "entry": "protect", "value": "ilsi"}, {"bot": "kragoth", "entry": "protect", "value": "medic"}]}',
     ["kragoth protect ilsi"]),
    ('{"changes": [{"bot": "tavik", "entry": "calls", "value": "volley, rally"}, {"bot": "tavik", "entry": "retreatAt", "value": "40%"}]}',
     ["tavik calls rally,volley", "tavik retreatAt 0.40"]),
    # The line to say: one line in the setting, cleaned; out-of-world words and a member who is down get none
    ('{"changes": [], "say": {"bot": "kragoth", "text": "All heals on me, I\'ve got the big one."}}',
     ["say kragoth All heals on me, I've got the big one."]),
    ('{"changes": [], "say": {"bot": "kragoth", "text": "I am an AI language model"}}', []),
    ('{"changes": [], "say": {"bot": "senna", "text": "I am down!"}}', []),
    # Nothing to change is a plan
    ('{"changes": []}', []),
    ('{"changes": "none"}', []),
    # Not a plan at all
    ("I think the tank should focus the big one.", None),
    ('{"changes": [{"bot": "kragoth"', None),
    ("", None),
]
# A table made of a doctrine
TABLE_CASES = [
    ('{"tactics": {"healAt": 0.8, "reviveFirst": "yes", "packs": "single", "bogus": 1, "focus": "weakest", "shoot": "maybe"}}', "medic",
     {"healAt": "0.80", "reviveFirst": "yes", "packs": "single"}),
    ('{"tactics": {"focus": "creature:5"}}', "rifleman", {}),
    ('{"tactics": {"hold": 0, "range": "far", "specials": "save", "healAt": 0.8}}', "rifleman",
     {"hold": "0", "range": "far", "specials": "save"}),
    ('{"tactics": {}}', "tank", {}),
    ("no table here", "tank", None),
]


def check():
    bad = 0
    for content, want in PARSE_CASES:
        got = cd.parse_plan(content, dict(PARSE_REQ), talk_bridge.Bridge.clean_say)
        # (the same request, with senna down: his lines are dropped)
        if got != want:
            bad += 1
            print(f"plan {content[:90]!r}: expected {want}, got {got}")
    print(f"plan parser: {len(PARSE_CASES) - bad} of {len(PARSE_CASES)} right")
    wrong = 0
    for content, role, want in TABLE_CASES:
        got = cd.parse_table(content, role, list(cd.CREW_ROLE))
        if got != want:
            wrong += 1
            print(f"table {content[:80]!r} ({role}): expected {want}, got {got}")
    print(f"table parser: {len(TABLE_CASES) - wrong} of {len(TABLE_CASES)} right")
    # base.txt: only what differs from the default
    lines = cd.table_lines("quillan", {"healAt": "0.75", "packs": "single", "mindFloor": "0.40", "shoot": "no"})
    if lines != ["quillan packs single", "quillan shoot no"]:
        wrong += 1
        print(f"base lines: {lines}")
    # the tactics and their defaults are today's numbers
    for entry, default in (("hold", 3), ("healAt", 0.75), ("mindFloor", 0.4), ("retreatAt", 0.3)):
        if float(cd.TACTICS[entry][3]) != default:
            wrong += 1
            print(f"default of {entry}: {cd.TACTICS[entry][3]}")
    return 1 if bad or wrong else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="the parser alone, no model")
    parser.add_argument("--with-chat", type=int, default=0, metavar="N", help="N crowd chat questions in flight meanwhile")
    parser.add_argument("--repeat", type=int, default=1, help="each situation this many times")
    args = parser.parse_args()
    if args.check:
        return check()
    if not talk_bridge.LITELLM_KEY:
        print("no LITELLM_KEY: set LITELLM_URL and LITELLM_KEY, or use --check for the parser alone", file=sys.stderr)
        return 2
    bridge = talk_bridge.Bridge({}, cd.Doctrines(data_dir=tempfile.mkdtemp()))
    raw = []
    complete = bridge.complete

    def recording(messages, max_tokens, timeout, temperature=0.8):
        content = complete(messages, max_tokens, timeout, temperature)
        raw.append(content)
        return content

    stop = threading.Event()
    chat_latencies = []

    def chatter(n):
        crowd = {"npc": 900 + n, "player": 800 + n, "name": "Tarn Vosk", "species": "human", "sex": "male", "kit": "traveller",
                 "city": "mos_eisley", "place": "plaza", "hour": 20, "playerName": "Cameren", "text": "where's the bank?"}
        while not stop.is_set():
            started = time.time()
            try:
                complete([{"role": "system", "content": bridge.system_prompt(crowd)}, {"role": "user", "content": crowd["text"]}], 90, 60)
                chat_latencies.append(time.time() - started)
            except Exception as e:  # noqa: BLE001
                print("crowd chat:", type(e).__name__, str(e)[:80], file=sys.stderr)
                time.sleep(2)

    bridge.complete = recording
    # Load the model first, so the first plan isn't timed against a cold start
    started = time.time()
    complete([{"role": "user", "content": "Say hi."}], 1, 120)
    print(f"# Crew plans: {len(SITUATIONS)} situations\n\nModel `{talk_bridge.MODEL}`, {time.strftime('%Y-%m-%d %H:%M')}; warmed in "
          f"{time.time() - started:.1f} s; {args.with_chat} crowd chat stream(s) in flight.\n")
    threads = [threading.Thread(target=chatter, args=(i,), daemon=True) for i in range(args.with_chat)]
    for thread in threads:
        thread.start()
    latencies, invalid, proposed_total, kept_total = [], 0, 0, 0
    print("| Situation | Latency | Valid | Kept | Plan |\n|---|---|---|---|---|")
    for name, fields in SITUATIONS:
        for n in range(args.repeat):
            r = request(fields, "plan-%d" % len(latencies))
            raw.clear()
            started = time.time()
            try:
                lines = bridge.plan(r, 40)
            except Exception as e:  # noqa: BLE001
                lines = None
                print(f"{name}: {type(e).__name__} {e}", file=sys.stderr)
            took = time.time() - started
            latencies.append(took)
            obj = cd.extract_json(raw[-1]) if raw else None
            proposed = len(obj.get("changes") or []) if obj and isinstance(obj.get("changes"), list) else 0
            kept = len([line for line in (lines or []) if not line.startswith("say ")])
            proposed_total += proposed
            kept_total += kept
            invalid += lines is None
            late = took > talk_bridge.PLAN_DEADLINE
            print(f"| {name} | {took:.1f} s{' (late)' if late else ''} | {'yes' if lines is not None else '**NO**'} | {kept} of "
                  f"{proposed} | {'; '.join(lines) if lines else '-'} |")
    stop.set()
    ordered = sorted(latencies)
    print(f"\n- **Valid plans:** {len(latencies) - invalid} of {len(latencies)}.")
    print(f"- **Latency:** median {statistics.median(ordered):.1f} s, worst {ordered[-1]:.1f} s "
          f"({sum(t > talk_bridge.PLAN_DEADLINE for t in ordered)} over the {talk_bridge.PLAN_DEADLINE:.0f} s the bridge allows).")
    print(f"- **Changes kept:** {kept_total} of {proposed_total} the model proposed (the rest were clamped away: a role without "
          "the entry, a creature that isn't there, a member who is down, or a standing order's entry).")
    if chat_latencies:
        print(f"- **Crowd chat meanwhile:** {len(chat_latencies)} answers, median {statistics.median(chat_latencies):.1f} s.")
    return 1 if invalid else 0


if __name__ == "__main__":
    sys.exit(main())
