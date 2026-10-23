/*
 * BotItems: pack stock and the creature getters Lua lacks (Phase 3 bot players).
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
	// Makes sure the bot's inventory holds `templateName` (an enhance or wound pack) with at least `uses` uses, at
	// `power`, and `duration` seconds for enhance packs. It keeps one pack per kind and attribute, so the doctor
	// commands always pick this one: other enhance (or wound) packs for the same attribute are destroyed. The values
	// go in through the pack's crafting path (updateCraftingValues), as a crafted pack's do. The bot must be locked.
	// Returns false if the pack can't be made.
	static bool stockPack(server::zone::objects::creature::CreatureObject* bot, const String& templateName, int uses, float power, int duration);

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
