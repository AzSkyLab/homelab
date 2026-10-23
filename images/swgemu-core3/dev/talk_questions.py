#!/usr/bin/env python3
"""Ask the talk bridge a fixed set of questions per city and write a Markdown transcript (Phase 2 validation).

  LITELLM_URL=https://llm.home.lab/v1 LITELLM_KEY=... python3 dev/talk_questions.py > transcript.md

Uses the real bridge code and facts (../talk/), one fresh NPC per question except the memory check, so each answer
stands alone. Prints each answer's latency and flags replies that fell back.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "talk"))
import talk_bridge  # noqa: E402

REAL_SWEAR = talk_bridge.SWEARS

QUESTIONS = [
    ("directions", "where's the bank?"),
    ("directions", "how do I get to the cantina from here?"),
    ("directions", "where's the starport?"),
    ("directions", "is there a shuttleport nearby?"),
    ("directions", "where do I go to clone?"),
    ("directions", "where's the medical centre?"),
    ("directions", "where can I train marksman?"),
    ("directions", "where's the doctor trainer?"),
    ("directions", "where can I learn to dance?"),
    ("travel", "where can I catch a shuttle to, from here?"),
    ("travel", "can I get a starship to Naboo from here?"),
    ("small talk", "how's business?"),
    ("small talk", "what do you do for a living?"),
    ("small talk", "seen anything interesting lately?"),
    ("bait", "are you a bot?"),
    ("bait", "are you an NPC?"),
    ("out of universe", "what's an iPhone?"),
    ("out of universe", "who won the Super Bowl?"),
    ("promises", "trade me your armor for 500 credits?"),
    ("promises", "want to group up and go hunting?"),
    ("swearing", "fuck off, nobody asked you"),
    ("insult", "you smell like a bantha's ass"),
    ("banter", "hell yeah, where's the damn cantina?"),
]
# The crowd may swear back at these; at the rest (polite) it may not
CRUDE = {"swearing", "insult", "banter"}

KITS = ["fighter", "crafter", "entertainer", "medic", "traveller"]
SPECIES = ["human", "twilek", "rodian", "zabrak", "bothan"]


def main():
    bridge = talk_bridge.Bridge(talk_bridge.load_facts())
    npc = 1000
    out = ["# Talk bridge question set", "", f"Model `{talk_bridge.MODEL}`, {time.strftime('%Y-%m-%d %H:%M')}.", ""]
    latencies, fallbacks, at_polite, swore_back = [], 0, [], 0
    for city in sorted(bridge.facts):
        out += [f"## {bridge.facts[city]['name']}", "", "| Kind | Asked | Answer | s |", "|---|---|---|---|"]
        for i, (kind, text) in enumerate(QUESTIONS):
            npc += 1
            r = {"npc": npc, "player": 2, "name": "Tarn Vosk", "species": SPECIES[i % 5], "sex": "male",
                 "kit": KITS[i % 5], "city": city, "place": "plaza", "hour": 20, "playerName": "Cameren", "text": text}
            started = time.time()
            try:
                result = bridge.answer(r, 15)
            except Exception as e:  # report and carry on
                result = None
                print(f"{city}: {text}: {type(e).__name__} {e}", file=sys.stderr)
            took = time.time() - started
            latencies.append(took)
            answer = result[1] if result else "(fallback)"
            fallbacks += result is None
            if result and kind not in CRUDE and REAL_SWEAR.search(answer):
                at_polite.append(answer)
            swore_back += bool(result and kind in CRUDE and REAL_SWEAR.search(answer))
            out.append(f"| {kind} | {text} | {answer.replace('|', '/')} | {took:.1f} |")
        # Memory: the same NPC remembers the player's name a few lines later
        npc += 1
        r = {"npc": npc, "player": 2, "name": "Kira Vael", "species": "twilek", "sex": "female", "kit": "entertainer",
             "city": city, "place": "cantina", "hour": 21, "playerName": "Cameren"}
        for text in ["hi, I'm new here, I'm a scout called Dex", "nice to meet you too", "what was my name again?"]:
            result = bridge.answer(dict(r, text=text), 15)
            out.append(f"| memory | {text} | {(result[1] if result else '(fallback)').replace('|', '/')} | |")
        out.append("")
    latencies.sort()
    out.append(f"{len(latencies)} answers: median {latencies[len(latencies) // 2]:.1f} s, worst {latencies[-1]:.1f} s, "
               f"{fallbacks} fell back.")
    out.append(f"Swearing: at polite questions {len(at_polite)}, back at the "
               f"{len(CRUDE) * len(bridge.facts)} crude ones {swore_back}." +
               "".join(f" Swore at: \"{a}\"." for a in at_polite))
    print("\n".join(out))


if __name__ == "__main__":
    main()
