/*
 * BotSlice: a smuggler bot slices armor and weapons (Phase 4, ~/github/swgemu/specs/2026-10-23-musicians-smugglers/).
 *
 * The slice is Core3's own SlicingSession, driven in one task as a client would answer its window: open it on the
 * item (which must sit in the bot's own inventory), use a molecular clamp (which reveals the right cable), read the
 * right cable from the session's JSON, cut it, then the other. Core3 rolls the result for the bot's skill (master:
 * armor +11-35% effectiveness or -20-45% encumbrance, weapons +20-35% damage or -20-35% attack speed); the bot
 * takes what it rolls. The result is read back from the item's JSON. Then the item goes straight into its owner's
 * inventory in the same step, or through a give-back trade if that inventory is full (BotTrade::returnItem).
 */

#ifndef BOTSLICE_H_
#define BOTSLICE_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace scene {
class SceneObject;
}
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

// What botSlice returns
class BotSliceResult : public Object {
public:
	bool ok = false;		// sliced
	String kind;			// "armor" or "weapon" ("other" if neither)
	String stat;			// "effectiveness", "encumbrance", "damage" or "speed"
	int percent = 0;
	String error;			// why not, or why it didn't go straight back ("inventory full": a give-back trade)
	bool returned = false;	// in the owner's inventory now
};

// What botItemInfo returns
class BotItemInfo : public Object {
public:
	String kind = "other";	// "armor", "weapon" or "other"
	bool sliced = false;
	bool sliceable = false;	// armor or a non-Jedi weapon that isn't sliced
	bool powerup = false;	// a weapon with a powerup (slicing destroys it)
	String name;
	uint64 parent = 0;		// the container it's in
};

class BotSlice {
public:
	static const char* LASER_KNIFE;
	static const char* MOLECULAR_CLAMP;
	static const char* ARMOR_KIT;
	static const char* WEAPON_KIT;

	static const int KNIFE_CHARGES = 10;

	// Makes sure the bot's inventory holds a laser knife with charges for a slice (a fresh one has 10, each slice uses
	// two), and `count` molecular clamps, armor upgrade kits and weapon upgrade kits. Locks the bot
	static bool stockTools(server::zone::objects::creature::CreatureObject* bot, int count);

	static bool getItemInfo(uint64 itemOid, BotItemInfo& out);

	// Slices the item (in the bot's inventory) and hands it to owner (null: it stays with the bot). Locks the bot
	static void slice(server::zone::objects::creature::CreatureObject* bot, uint64 itemOid,
			server::zone::objects::creature::CreatureObject* owner, BotSliceResult& result);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTSLICE_H_ */
