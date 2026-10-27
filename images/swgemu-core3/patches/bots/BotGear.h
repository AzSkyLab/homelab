/*
 * BotGear: the gear of an own-crew bot (Phase 9 Part 3, ~/github/swgemu/specs/2026-10-26-crew-grows/).
 *
 * An own-crew bot fights with what its owner gave it (a trade, BotTrade) and the starter kit it was hired with. This is the
 * C++ side of that:
 * - List: what the bot wears and holds, classified (weapon, armour, clothing, the kinds of medicine, grenade, camp kit), with
 *   the numbers a decision needs: uses left, the medicine skill a pack asks for, a weapon's damage per second, an armour's
 *   rating, the condition left.
 * - Given: the oids of what the owner gave, in the bot's character (ScreenPlayData "BotGear" / "given"). A given item comes
 *   back to the owner on "hand over your gear" and when the bot is let go; the starter kit and the bot's own loot do not.
 * - Equip: a container transfer into the slot, so Core3's own checks run (species, faction, encumbrance, skill), and a
 *   weapon's certification is looked at first. The old occupant goes to the pack and is put back if the new piece is refused.
 * - Packs: the best usable pack or thrown grenade of a kind in the bot's pack (usable: uses left and the medicine skill
 *   the pack asks for), and how many uses are left of a kind.
 * - Give back: the filter that turns BotLoot's goods into the given gear (BotLoot::goods reads it), and the let-go's straight
 *   return of everything given.
 * - Development: make an item in a bot's pack as if traded, set an item's condition.
 *
 * Kinds (BotGearItem::kind): "weapon", "armor", "clothing", "stim", "ranged" (a ranged stim), "state", "cure" (poison or
 * disease: the template name says which), "revive", "dot" (a poison or disease pack; "dotarea" for an area one), "enhance",
 * "wound", "medicine" (any other), "grenade", "camp", "other". A weapon's family: "unarmed", "onehand", "twohand",
 * "polearm", "pistol", "carbine", "rifle", "heavy" (the flame thrower and the acid rifle too), "thrown", "other".
 */

#ifndef BOTGEAR_H_
#define BOTGEAR_H_

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

class BotGoodsItem;

class BotGearItem : public Object {
public:
	uint64 oid = 0;
	String templateName;
	String name;
	String kind;
	String family;			// a weapon's
	String slot;			// the arrangement's slots joined by "|": what it occupies when worn
	bool worn = false;		// in a slot of the bot (the weapon in hand too)
	bool given = false;		// the owner gave it
	bool certified = true;	// a weapon the bot is certified for (else it hits for 5-10)
	int uses = 0;			// packs and grenades: uses left
	int required = 0;		// a pack's medicine skill (healing_ability, or combat_healing_ability for ranged stims and DoT packs)
	bool usable = true;		// a pack the bot's skill meets
	float power = 0;		// a pack's effectiveness; a weapon's damage per second; an armour's average rating
	int left = 100;			// condition left, percent
	bool broken = false;
};

class BotGear {
public:
	// What the bot wears and holds, not the goods it looted. Locks the bot
	static void list(server::zone::objects::creature::CreatureObject* bot, Vector<Reference<BotGearItem*>>& out);

	// The kind and family of any item (an offer on the table), "other" for something that is no gear. Reads only
	static void classify(server::zone::objects::scene::SceneObject* item, String& kind, String& family);

	// Puts the item on (or in hand) through a container transfer. false and why: "no item", "cert" (a weapon the bot is not
	// certified for, or a piece that asks for a skill it lacks), "species", "faction", "heavy" (its secondary stats are too
	// low), "slot" (something stays in the way), "failed". Locks the bot
	static bool equip(server::zone::objects::creature::CreatureObject* bot, uint64 itemOid, String& why);

	// Takes a worn item off into the pack. Locks the bot
	static bool unequip(server::zone::objects::creature::CreatureObject* bot, uint64 itemOid);

	// The owner's gifts. Locks the bot
	static void markGiven(server::zone::objects::creature::CreatureObject* bot, const Vector<uint64>& oids);
	static bool isGiven(server::zone::objects::creature::CreatureObject* bot, uint64 oid);

	// The best usable pack of a kind ("stim", "ranged", "revive", "state:<word>", "cure:<word>", "dot:<word>", "dotarea:<word>",
	// "grenade"; the word is in the template name: "poison", "disease", "stunned"...), else 0. uses: the uses left of all the
	// usable ones of the kind. Locks the bot
	static uint64 findPack(server::zone::objects::creature::CreatureObject* bot, const String& kind, int& uses);

	// The template of the best camp kit in the pack (the highest in the camp's own order is the caller's), "" if none
	static void campKits(server::zone::objects::creature::CreatureObject* bot, Vector<String>& out);

	// Give back. The mode is the filter BotLoot::goods reads: "" off, "all", or a kind or family ("rifle", "armor", "stim"...).
	// prepareGiveBack takes the matching worn given items off into the pack, sets the mode and returns how many are to go
	static int prepareGiveBack(server::zone::objects::creature::CreatureObject* bot, const String& filter);
	static void endGiveBack(server::zone::objects::creature::CreatureObject* bot);
	static String giveMode(server::zone::objects::creature::CreatureObject* bot);

	// The given items in the pack that match the mode, as goods (BotLoot::goods). Pre: bot locked
	static void givenGoods(server::zone::objects::creature::CreatureObject* bot, const String& mode, Vector<Reference<BotGoodsItem*>>& out);

	// The let-go: every given item, worn or in the pack, straight into the owner's pack. The bot may be offline (its character is
	// loaded). false and why ("owner offline", "inventory full"...) with nothing lost: what went stays gone, the rest stays
	static bool returnGiven(uint64 botOid, uint64 ownerOid, String& why);

	// The starter stims an own-crew bot is hired with: one basic stim pack of `uses` uses in its pack, not recorded as a gift (it is the
	// bot's own). Pre: the character is new. Returns the pack's oid, or 0
	static uint64 starterStims(server::zone::objects::creature::CreatureObject* bot, int uses);

	// Development: an item made in the bot's pack and recorded as given (uses > 0 sets a pack's uses); its oid, or 0
	static uint64 devGive(server::zone::objects::creature::CreatureObject* bot, const String& templateName, int uses);

	// Development: the item's condition left, in percent
	static bool devCondition(server::zone::objects::creature::CreatureObject* bot, uint64 oid, int percent);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTGEAR_H_ */
