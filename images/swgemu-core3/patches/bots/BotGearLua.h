/*
 * BotGearLua: the Lua bindings for an own-crew bot's gear (Phase 9 Part 3). Registered from BotLua::registerFunctions. See BotGear.h.
 *
 *   botGearList(pBot)               every item worn or held (not looted goods): {oid, template, name, kind, family, slot, worn, given,
 *                                   certified, uses, required, usable, power, left, broken}
 *   botGearKind(itemOid)            kind, family, name of any item ("other" for no gear), or nil
 *   botGearEquip(pBot, itemOid)     true, or false and why ("no item", "cert", "species", "faction", "heavy", "slot", "failed")
 *   botGearUnequip(pBot, itemOid)   true if it is in the pack now
 *   botGearGiven(pBot, {oids})      records the items as the owner's gift
 *   botGearPack(pBot, kind)         oid, uses: the best usable pack (or grenade) of a kind, 0 and 0 if none. Kinds: "stim", "ranged",
 *                                   "revive", "state:<word>", "cure:<word>", "dot:<word>", "dotarea:<word>", "grenade"
 *   botGearCamps(pBot)              the camp kit templates in the pack
 *   botGearGiveBack(pBot, filter)   takes the matching worn gifts off and turns BotLoot's goods into the gifts that match ("all", a
 *                                   kind or a weapon family); how many are to go
 *   botGearGiveEnd(pBot)            the goods are the loot again
 *   botGearGiveMode(pBot)           the hand-back filter while one is under way, else ""
 *   botGearDevGive(pBot, template[, uses])   development: an item in the pack, recorded as a gift; its oid
 *   botGearDevCondition(pBot, itemOid, percent)   development: the condition left
 */

#ifndef BOTGEARLUA_H_
#define BOTGEARLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotGearLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botGearList(lua_State* L);
	static int botGearKind(lua_State* L);
	static int botGearEquip(lua_State* L);
	static int botGearUnequip(lua_State* L);
	static int botGearGiven(lua_State* L);
	static int botGearPack(lua_State* L);
	static int botGearCamps(lua_State* L);
	static int botGearGiveBack(lua_State* L);
	static int botGearGiveEnd(lua_State* L);
	static int botGearGiveMode(lua_State* L);
	static int botGearDevGive(lua_State* L);
	static int botGearDevCondition(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTGEARLUA_H_ */
