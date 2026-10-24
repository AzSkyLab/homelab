/*
 * BotLoot: looting, harvesting and handing over what a crew bot picked up (Phase 7,
 * ~/github/swgemu/specs/2026-10-24-crew-swoops-missions/).
 *
 * - Looting: everything on a corpse the bot's group may loot goes into the bot's inventory, under any loot rule (the
 *   human stays master looter; the rule decides who may open the corpse, and the bot isn't opening it). The credits on
 *   it go through Core3's own group split (GroupLootTask::splitCredits), where patches/0007 leaves bots out, so they
 *   reach the humans. Never a player's corpse, never a corpse owned by someone else's group or player.
 * - Harvesting: Core3's own CreatureManager::harvest, as /harvestCorpse runs it.
 * - Goods: what the bot holds that isn't its own gear. Its gear is never marked: the oid of everything it looted is
 *   recorded in its ScreenPlayData ("BotLoot" / "goods", saved with the character, so a restart keeps it), and every
 *   resource container in its inventory counts as goods (harvested resources stack into one container, so there is no
 *   single oid to record). Outfit, weapons, medicine, camp kits and the swoop are never in either.
 * - Handing over: a give-back trade of all the goods that fit (BotTrade::giveBundle; the rest in a later trade).
 */

#ifndef BOTLOOT_H_
#define BOTLOOT_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace creature {
class CreatureObject;
}
namespace scene {
class SceneObject;
}
}

namespace managers {
namespace bot {

// botLootCorpse's result
class BotLootResult : public Object {
public:
	bool ok = false;
	int moved = 0;			// items now in the bot's inventory
	int left = 0;			// items still on the corpse (a full inventory, or a refusal)
	int credits = 0;		// the credits the corpse held, split among the humans in the group
	Vector<String> names;	// what moved (display names, at most NAMES_KEPT)
	bool full = false;		// the bot's inventory ran out of room
	String error;			// when !ok: "no bot", "no corpse", "player corpse", "alive", "not grouped", "not the group's", "too far"
};

// botHarvest's result
class BotHarvestResult : public Object {
public:
	bool ok = false;
	String kind;			// "meat", "hide" or "bone"
	int amount = 0;			// units now in the bot's inventory
	String resource;		// the resource's class, e.g. "Tatooinian Bone"
	String error;			// when !ok: "no bot", "no corpse", "not a creature", "alive", "too far", "nothing to harvest", "cannot harvest", "no <kind>", "failed"
};

// One corpse botCorpsesNear found
class BotCorpseInfo : public Object {
public:
	uint64 oid = 0;
	float distance = 0;		// metres from the scan's centre
	int items = 0;			// items still on it
	int credits = 0;		// credits still on it
	bool harvest = false;	// a creature with something to harvest (the bot may not have the skill, or may have harvested it)
	String name;
};

// One thing in botGoods
class BotGoodsItem : public Object {
public:
	uint64 oid = 0;
	String name;
	int quantity = 1;		// a resource container's units, else 1
	bool resource = false;
	bool tradable = true;	// false for a no-trade item: it stays in the bot's pack
};

class BotLoot {
public:
	static const int MAX_BUNDLE = 20;		// items in one handover trade
	static const int OFFER_RANGE = 13;		// Core3 refuses a trade at 15 m
	static const int NAMES_KEPT = 12;		// item names a loot result carries
	static const int CORPSES_MAX = 40;		// corpses one scan returns

	// Moves everything the bot's group may loot off the corpse into the bot's inventory. Locks the bot and the corpse
	static bool lootCorpse(server::zone::objects::creature::CreatureObject* bot, uint64 corpseOid, BotLootResult& out);

	// The corpses within range of the centre (the bot itself, or a group mate) that the bot's group may loot or harvest
	// (Core3's own permission: the loot container's owner is the group; never a player's corpse, never another group's
	// or player's), with something still on them or to harvest, nearest first. Reads only, locks nothing
	static void corpsesNear(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::scene::SceneObject* center,
		float range, Vector<Reference<BotCorpseInfo*>>& out);

	// Harvests the corpse with the bot's own skills. kind: "meat", "hide", "bone", or "" for the one the creature has
	// most of. Locks the bot and the corpse
	static bool harvest(server::zone::objects::creature::CreatureObject* bot, uint64 corpseOid, const String& kind, BotHarvestResult& out);

	// What the bot holds that isn't its own gear. Drops what has left the inventory from the record. Locks the bot
	static void goods(server::zone::objects::creature::CreatureObject* bot, Vector<Reference<BotGoodsItem*>>& out);

	// Opens a give-back trade to the player with all the goods that fit in its inventory (at most MAX_BUNDLE items).
	// offered: the items in this trade; remaining: the goods left for another one. Returns false and why ("no bot",
	// "no player", "too far", "busy", "no goods", "inventory full"). Locks the bot
	static bool offerGoods(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* player,
			int& offered, int& remaining, String& error);

	// Drops an offer that hasn't been taken (and closes its trade window). Locks the bot
	static void cancelOffer(server::zone::objects::creature::CreatureObject* bot);

	// Is this item goods (looted or harvested, never the bot's gear)? The gear code (stockPack, findPack, equip) leaves
	// goods alone, so a looted pack or weapon is never destroyed, used up or equipped. Pre: bot locked (or read-only)
	static bool isGood(server::zone::objects::creature::CreatureObject* bot, uint64 itemOid);

	// Development: records an item already in the bot's inventory as goods. Locks the bot
	static bool markGood(server::zone::objects::creature::CreatureObject* bot, uint64 itemOid);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTLOOT_H_ */
