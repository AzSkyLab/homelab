#!/usr/bin/env python3
"""Makes the generated parts of custom_scripts/bots/crews.lua (Phase 9, own crews) from the game's own tables.

  python3 -I dev/crew_data.py            # prints what it would write, and checks it
  python3 -I dev/crew_data.py --write    # rewrites the regions between the BEGIN/END generated markers in crews.lua

It reads, from the client's TREs (tools/tre.py in the swgemu repo, ~/Games/swgemu), datatables/skill/skills.iff (the table Core3
loads), and, from a Core3 checkout (CORE3_SCRIPTS, default the dev build's pristine tree), the weapon and armor object
scripts. It makes:
  * the training order of each role: the boxes of the roadmap's build, a master's four lines taken level by level, every
    prerequisite before what needs it (novice boxes are in the list; they don't count towards a bot's level);
  * for each weapon, from which count of boxes the bot is certified for it, and for each camp kit, from which count its
    camp skill is enough;
  * the armor sets with the species, and the species/role pairs, that can't wear a piece (Core3 refuses it at equip: the species isn't
    in its list, or the secondary stats of a new bot of that species and starting profession are below its encumbrance);
  * the looks: hairstyles the character creator offers with hair colours, or skin tones for the species with no hair.
Counts are "boxes", the number of non-novice boxes a bot owns, which is the level the recruiter gives it (BotManager counts
the owner the same way: all skills but novice, species and language ones).
"""
import os
import re
import sys

SWGEMU = os.path.expanduser("~/github/swgemu")
SCRIPTS = os.environ.get("CORE3_SCRIPTS", os.path.expanduser("~/.cache/swgemu-scratch/core3-dev/pristine/MMOCoreORB/bin/scripts"))
CREWS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "custom_scripts", "bots", "crews.lua")

sys.path.insert(0, os.path.join(SWGEMU, "tools"))
from tre import datatable, find_file  # noqa: E402

CLIENT = os.path.expanduser("~/Games/swgemu")

# The builds (roadmap, "The crew"): targets in training priority. A master target brings in its lines level by level. The
# gunners learn their gun line first (the bot fights with it from its first boxes), the others their trade.
BUILDS = {
    "tank": ["combat_unarmed_master", "combat_brawler_master", "science_medic_master", "combat_1hsword_accuracy_04",
             "combat_1hsword_speed_02"],
    "rifleman": ["combat_rifleman_master", "combat_marksman_master", "combat_carbine_master", "science_medic_injury_04",
                 "science_medic_injury_speed_04"],
    "medic": ["combat_marksman_novice", "science_combatmedic_master", "combat_marksman_rifle_04", "science_doctor_master"],
    "ranger": ["combat_marksman_carbine_04", "outdoors_ranger_master", "combat_marksman_master", "combat_carbine_ability_04",
               "combat_carbine_accuracy_02"],
    "squadleader": ["combat_marksman_carbine_04", "outdoors_squadleader_master", "combat_carbine_master", "combat_marksman_master"],
    "entertainer": ["combat_marksman_pistol_02", "social_dancer_master", "social_musician_master", "combat_marksman_pistol_04",
                    "combat_pistol_accuracy_04", "combat_pistol_speed_02", "combat_pistol_ability_01"],
    "commando": ["combat_commando_master", "combat_carbine_master", "science_medic_novice"],
}
START = {"tank": "combat_brawler", "rifleman": "combat_marksman", "medic": "science_medic", "ranger": "outdoors_scout",
         "squadleader": "outdoors_scout", "entertainer": "social_entertainer", "commando": "combat_marksman"}

# Weapons, worst to best: the bot holds the last one it is certified for.
WEAPONS = {
    "tank": [],
    "rifleman": ["rifle/rifle_dlt20", "rifle/rifle_t21"],
    "medic": ["rifle/rifle_dlt20", "rifle/rifle_e11"],
    "ranger": ["carbine/carbine_dh17", "carbine/carbine_e11", "carbine/carbine_ee3"],
    "squadleader": ["carbine/carbine_dh17", "carbine/carbine_e11", "carbine/carbine_dxr6"],
    "entertainer": ["pistol/pistol_d18", "pistol/pistol_dh17"],
    "commando": ["carbine/carbine_dh17", "rifle/rifle_flame_thrower"],
}
# Carried from a count of boxes on: the commando's acid rifle (its grenades the crew job stocks)
CARRY = {"commando": ["rifle/rifle_acid_beam"]}
CAMPS = [("camp_basic", 5), ("camp_multi", 10), ("camp_improved", 30), ("camp_quality", 50), ("camp_elite", 65), ("camp_luxury", 85)]

ARMOR = {
    "padded": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "chitin": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "bone": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "bounty_hunter": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "ris": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "ubese": ["jacket", "pants", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "kashyyykian_hunting": ["chest_plate", "leggings", "bracer_l", "bracer_r"],
    "kashyyykian_ceremonial": ["chest_plate", "leggings", "bracer_l", "bracer_r"],
    "ithorian_defender": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "ithorian_guardian": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
    "ithorian_sentinel": ["chest_plate", "leggings", "bicep_l", "bicep_r", "bracer_l", "bracer_r", "boots", "gloves", "helmet"],
}
STEM = {
    "padded": "armor_padded_s01_", "chitin": "armor_chitin_s01_", "bone": "armor_bone_s01_",
    "bounty_hunter": "armor_bounty_hunter_", "ris": "armor_ris_", "ubese": "armor_ubese_",
    "kashyyykian_hunting": "armor_kashyyykian_hunting_", "kashyyykian_ceremonial": "armor_kashyyykian_ceremonial_",
    "ithorian_defender": "ith_armor_s01_",
    "ithorian_guardian": "ith_armor_s02_", "ithorian_sentinel": "ith_armor_s03_",
}
SPECIES = ["human", "bothan", "moncal", "rodian", "sullustan", "trandoshan", "twilek", "wookiee", "zabrak", "ithorian"]

BEGIN = "-- BEGIN generated: %s (dev/crew_data.py)"
END = "-- END generated: %s"


def counted(name):
    """Does this box count towards a level?"""
    return not (name.endswith("_novice") or name.startswith("species_") or name.startswith("social_language_"))


class Skills:
    def __init__(self):
        data = find_file(CLIENT, os.path.join(CLIENT, "swgemu_live.cfg"), "datatables/skill/skills.iff")
        _, _, rows = datatable(data)
        self.rows = {r["NAME"]: r for r in rows}
        self.rank = {r["NAME"]: i for i, r in enumerate(rows)}
        self._depth = {}

    def needs(self, name):
        return [n for n in self.rows[name]["SKILLS_REQUIRED"].split(",") if n]

    def depth(self, name):
        if name not in self._depth:
            self._depth[name] = 1 + max([self.depth(n) for n in self.needs(name)] or [-1])
        return self._depth[name]

    def closure(self, name, seen=None):
        seen = set() if seen is None else seen
        if name in seen:
            return seen
        seen.add(name)
        for n in self.needs(name):
            self.closure(n, seen)
        return seen

    def order(self, targets, start):
        """The boxes of a build in training order, novice boxes included. The starting profession's novice box is not listed
        (the factory gives it)."""
        out, have = [], {start + "_novice"}
        for target in targets:
            todo = [n for n in self.closure(target) if n not in have]
            todo.sort(key=lambda n: (self.depth(n), self.rank[n]))
            for n in todo:
                out.append(n)
                have.add(n)
        return out

    def prefixes(self, role):
        """[(count, boxes owned)] for each count of boxes: everything up to the next counted box (the novice boxes that
        come before it are owned too), as BotCrewKit takes them."""
        order = self.order(BUILDS[role], START[role])
        have = [START[role] + "_novice"]
        count = 0
        out = []
        for n in order:
            if counted(n):
                out.append((count, list(have)))
                count += 1
            have.append(n)
        out.append((count, list(have)))
        return out

    def first_count(self, role, owns):
        """The smallest count of boxes at which owns(boxes) holds, or None."""
        for count, have in self.prefixes(role):
            if owns(have):
                return count
        return None

    def certified(self, role, certs):
        def owns(have):
            got = set()
            for h in have:
                got.update(self.rows[h]["COMMANDS"].split(","))
            return all(c in got for c in certs)
        return self.first_count(role, owns)

    def camp(self, role, need):
        def owns(have):
            total = 0
            for h in have:
                for mod in self.rows[h]["SKILL_MODS"].split(","):
                    m = re.fullmatch(r"camp=(\d+)", mod.strip())
                    if m:
                        total += int(m.group(1))
            return total >= need
        return self.first_count(role, owns)


def weapon_certs(path):
    text = open(os.path.join(SCRIPTS, "object/weapon/ranged", path + ".lua")).read()
    m = re.search(r"certificationsRequired\s*=\s*\{(.*?)\}", text, re.S)
    return re.findall(r'"(\w+)"', m.group(1)) if m else []


def armor_species(dirname, piece):
    """The species (of the ten) that Core3 lets wear this piece."""
    path = os.path.join(SCRIPTS, "object/tangible/wearables/armor", dirname, STEM[dirname] + piece + ".lua")
    text = open(path).read()
    m = re.search(r"playerRaces\s*=\s*\{(.*?)\}", text, re.S)
    races = set(re.findall(r"player/(\w+)_(male|female)\.iff", m.group(1)))
    return {s for s in SPECIES if (s, "male") in races and (s, "female") in races}


def load_stats():
    """{species_sex: [h, s, c, a, q, st, m, f, w]} racial mods and {profession: [...]} profession mods, as BotFactory::setStartingHam adds
    them: a new bot's secondary stats (strength, constitution, quickness, stamina, focus, willpower)."""
    def table(name):
        data = find_file(CLIENT, os.path.join(CLIENT, "swgemu_live.cfg"), name)
        cols, _, rows = datatable(data)
        return cols, rows
    cols, rows = table("datatables/creation/profession_mods.iff")
    prof = {r[cols[0]]: [r[k] for k in cols[1:]] for r in rows}
    cols, rows = table("datatables/creation/racial_mods.iff")
    race = {}
    for r in rows:
        mods = [r[k] for k in cols[2:]]
        race[r[cols[0]]] = mods
        race[r[cols[1]]] = mods
    return prof, race


def armor_encumbrance(dirname, piece):
    """(health, action, mind) encumbrance of a piece, from its object script."""
    path = os.path.join(SCRIPTS, "object/tangible/wearables/armor", dirname, STEM[dirname] + piece + ".lua")
    text = open(path).read()
    out = []
    for key in ("healthEncumbrance", "actionEncumbrance", "mindEncumbrance"):
        m = re.search(key + r"\s*=\s*(\d+)", text)
        out.append(int(m.group(1)) if m else 0)
    return out


def can_carry(enc, stats, worn):
    """Core3's PlayerManager::checkEncumbrancies: a piece is refused if its health encumbrance reaches strength or constitution, its
    action encumbrance quickness or stamina, its mind encumbrance focus or willpower. Each piece worn takes its encumbrance off those
    stats (current and maximum), so the next sees less: worn is the (health, action, mind) already taken."""
    h, a, m = enc
    if h <= 0 and a <= 0 and m <= 0:
        return True
    s, c, q, st, f, w = stats[1], stats[2], stats[4], stats[5], stats[7], stats[8]
    wh, wa, wm = worn
    return not (h >= s - wh or h >= c - wh or a >= q - wa or a >= st - wa or m >= f - wm or m >= w - wm)


def lua_list(items):
    return "{\n" + "\n".join("\t\t\"%s\"," % i for i in items) + "\n\t}"


def gen_order(sk):
    out = []
    for role in BUILDS:
        order = sk.order(BUILDS[role], START[role])
        n = sum(1 for b in order if counted(b))
        out.append("\t-- %s: %d boxes (%d counted), starts with %s_novice" % (role, len(order), n, START[role]))
        out.append("\t%s = %s," % (role, lua_list(order)))
    return "\n".join(out)


def gen_weapons(sk):
    out = []
    for role in BUILDS:
        out.append("\t%s = {" % role)
        for tpl in WEAPONS[role]:
            need = sk.certified(role, weapon_certs(tpl))
            if need is None:
                sys.exit("%s is never certified for %s" % (role, tpl))
            out.append("\t\t{from = %d, held = \"object/weapon/ranged/%s.iff\"}," % (need, tpl))
        for tpl in CARRY.get(role, []):
            need = sk.certified(role, weapon_certs(tpl))
            if need is None:
                sys.exit("%s is never certified for %s" % (role, tpl))
            out.append("\t\t{from = %d, carry = \"object/weapon/ranged/%s.iff\"}," % (need, tpl))
        out.append("\t},")
    return "\n".join(out)


def gen_camps(sk):
    out = []
    for kit, need in CAMPS:
        count = sk.camp("ranger", need)
        if count is None:
            print("  (the ranger never reaches camp %d for %s)" % (need, kit), file=sys.stderr)
            continue
        out.append("\t{from = %d, kit = \"object/tangible/scout/camp/%s.iff\"}," % (count, kit))
    return "\n".join(out)


def gen_armor():
    """Each piece: its template, and what can't wear it, as a space-separated list: a species whose object script doesn't list it, or a
    species/role pair whose new bot (the starting profession's stats plus the species') is too weak for it after the pieces before it in
    the set (encumbrance adds up, see can_carry). Lua puts a set on only if a bot can wear all of it."""
    prof, race = load_stats()
    out = []
    for dirname, pieces in ARMOR.items():
        out.append("\t%s = {" % dirname)
        info = []
        for piece in pieces:
            can = armor_species(dirname, piece)
            if dirname.startswith("kashyyykian") or dirname.startswith("ithorian"):
                cant = []	# made for one species
            else:
                assert "wookiee" not in can and "ithorian" not in can, (dirname, piece)
                cant = [sp for sp in SPECIES if sp not in can and sp not in ("wookiee", "ithorian")]
            info.append((piece, can, armor_encumbrance(dirname, piece), cant))
        for species in SPECIES:
            for role in BUILDS:
                for sex in ("male", "female"):
                    base = prof[START[role]]
                    stats = [x + y for x, y in zip(base, race[species + "_" + sex])]
                    worn = [0, 0, 0]
                    for piece, can, enc, cant in info:
                        if species not in can or species in cant:
                            continue
                        token = species + "/" + role
                        if can_carry(enc, stats, worn):
                            worn = [x + y for x, y in zip(worn, enc)]
                        elif token not in cant:
                            cant.append(token)
        for piece, can, enc, cant in info:
            out.append("\t\t{\"object/tangible/wearables/armor/%s/%s.iff\", \"%s\"}," % (dirname, STEM[dirname] + piece, " ".join(cant)))
        out.append("\t},")
    return "\n".join(out)


def gen_looks():
    """Three or four looks per playable species and sex: hairstyles the character creator offers (spread over its list), each
    with a hair colour, and for the species without hair a skin tone. Palette indexes are kept inside the palette by the
    server."""
    data = find_file(CLIENT, os.path.join(CLIENT, "swgemu_live.cfg"), "datatables/customization/hair_assets_skill_mods.iff")
    _, _, rows = datatable(data)
    hairs = {}
    for r in rows:
        if r["AVAILABLE_AT_CREATION"]:
            m = re.fullmatch(r"object/creature/player/(\w+)_(male|female)\.iff", r["SERVER_PLAYER_TEMPLATE"])
            hairs.setdefault((m.group(1), m.group(2)), []).append(r["SERVER_TEMPLATE"])
    colours = [0, 4, 8, 12]
    tones = [0, 5, 10, 15]
    out = []
    for species in SPECIES:
        out.append("\t%s = {" % species)
        for sex in ("male", "female"):
            styles = sorted(hairs.get((species, sex), []))
            out.append("\t\t%s = {" % sex)
            if styles:
                picks = sorted({styles[round(i * (len(styles) - 1) / 3)] for i in range(4)}) if len(styles) > 3 else styles
                for i, hair in enumerate(picks):
                    code = re.search(r"_(s\d+)\.iff", hair).group(1)
                    colour = colours[(i * 3 + (1 if sex == "female" else 0)) % len(colours)]
                    out.append("\t\t\t{label = \"Hairstyle %s, colour %d\", hair = \"%s\", hairColor = %d}," % (code[1:].lstrip("0") or "0", colour + 1, hair, colour))
            else:
                for i, tone in enumerate(tones):
                    out.append("\t\t\t{label = \"Skin tone %d\", hair = \"\", skinTone = %d}," % (i + 1, tone))
            out.append("\t\t},")
        out.append("\t},")
    return "\n".join(out)


def splice(text, name, body):
    begin, end = BEGIN % name, END % name
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
    if not pattern.search(text):
        sys.exit("crews.lua has no %s region" % name)
    return pattern.sub(lambda m: begin + "\n" + body + "\n\t" + end, text)


def main():
    sk = Skills()
    regions = {"order": gen_order(sk), "weapons": gen_weapons(sk), "camps": gen_camps(sk), "armor": gen_armor(), "looks": gen_looks()}
    if "--write" not in sys.argv:
        for name, body in regions.items():
            print(BEGIN % name)
            print(body)
            print("\t" + END % name)
        return
    text = open(CREWS).read()
    for name, body in regions.items():
        text = splice(text, name, body)
    open(CREWS, "w").write(text)
    print("wrote", os.path.normpath(CREWS))


if __name__ == "__main__":
    main()
