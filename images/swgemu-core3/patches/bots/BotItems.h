/*
 * BotItems: pack stock and the creature getters Lua lacks (Phase 3 bot players; combat packs in Phase 5).
 */

#ifndef BOTITEMS_H_
#define BOTITEMS_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

class BotBuffInfo : public Object {
public:
	String name;		// e.g. "medical_enhance_health", or "0x<crc>" for a buff with no known name
	uint32 crc = 0;
	int secondsLeft = 0;
	int value = 0;		// the buff's first attribute modifier (e.g. +1400 health), else its first skill modifier
};

class BotItems {
public:
	// Makes sure the bot's inventory holds `templateName` with at least `uses` uses, at `power`, and `duration` seconds
	// for enhance packs. The values go in through the pack's crafting path (updateCraftingValues), as a crafted pack's
	// do; the pack keeps its template's medicine use (and a ranged stim its range, an area pack its area).
	// - Enhance and wound packs: one per kind and attribute, so the doctor commands always pick this one; other enhance
	//   (or wound) packs for the same attribute are destroyed.
	// - Stims (crafted_stimpack_sm_s1_*), ranged stims (medpack_grenade_damage_*), state packs (medpack_blinded_* etc.),
	//   cure packs (medpack_cure_*) and revive packs (medpack_revive): one per template (extra copies are destroyed);
	//   `power` is ignored for state packs, and 0 on a revive pack means a good crafted one (400). Pass the pack's oid (findPack) as the command's argument, e.g. to
	//   "healdamage", when the bot carries more than one kind.
	// - Poison and disease packs (medpack_poison_*, medpack_disease_*; Phase 7c, the combat medic's DoT packs): one per
	//   template; `power` is the DoT's strength, `duration` its seconds, and `potency` (its chance to land, against the
	//   creature's resistance) and `range` (metres, plus 14 at healing range 100) are set when above 0 and otherwise stay
	//   the template's. Area packs (medpack_poison_area_*, medpack_disease_area_*; Phase 8) hit every attackable creature
	//   within `area` metres of the target too, and make the thrower a defender of each: `area` (above 0) is set on them
	//   (else the template's stays), and the crew throws them only where nothing unpulled stands in that area.
	// The bot must be locked. Returns false if the pack can't be made.
	static bool stockPack(server::zone::objects::creature::CreatureObject* bot, const String& templateName, int uses, float power, int duration, float potency = 0, float range = 0, float area = 0);

	// Phase 8: a thrown weapon (object/weapon/ranged/grenade/*) in the bot's inventory with at least `uses` uses: the
	// first of that template that isn't loot, else a new one. Returns its oid (for throwgrenade's argument), or 0. The
	// bot must be locked
	static uint64 stockItem(server::zone::objects::creature::CreatureObject* bot, const String& templateName, int uses);

	// The oid of the first item of `templateName` in the bot's inventory (not loot), or 0
	static uint64 findItem(server::zone::objects::creature::CreatureObject* bot, const String& templateName);

	// The oid of the first pack of `templateName` in the bot's inventory, or 0. The bot must be locked
	static uint64 findPack(server::zone::objects::creature::CreatureObject* bot, const String& templateName);

	// Wounds on a pool (CreatureAttribute::HEALTH .. WILLPOWER, 0-8), and battle fatigue. 0 for nil or a bad pool.
	static int getWounds(server::zone::objects::creature::CreatureObject* creature, int pool);
	static int getShockWounds(server::zone::objects::creature::CreatureObject* creature);

	// The creature's active buffs
	static void listBuffs(server::zone::objects::creature::CreatureObject* creature, Vector<BotBuffInfo>& out);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTITEMS_H_ */
