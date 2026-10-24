/*
 * BotCombatLua: the Lua bindings for fighting (Phase 5 bot group mates; BotCombat.h and BotItems.h do the work).
 * Registered from BotLua::registerFunctions. Every function is safe with nil, a non-bot or an offline bot.
 *
 *   botSetTarget(pBot, oid[, engage]) -> bool   set the target (0 clears it); unless engage is false, a target the bot
 *                                               may attack gets a real attack queued, so auto-attack runs
 *   botDuelState(pBot, pOther) -> string        "none", "challenged", "challenging" or "dueling"
 *   botStartFight(pBot, pHuman) -> bool         a real fight: mutual personal enemy flags and combat, ending itself at
 *                                               the first incap of either side (event "fightEnded")
 *   botEndFight(pBot, pHuman) -> bool           end it now (event "fightEnded", detail "ended")
 *   botClone(pBot) -> bool                      a dead bot clones at the closest facility (event "cloned")
 *   botEquip(pBot, template) -> oid             create if missing, equip (a weapon to hold_r), repair; 0 on failure
 *   botRepairGear(pBot) -> count
 *   botFindPack(pBot, template) -> oid          a pack of that template in the inventory, or 0
 *   botRecentIncaps(pCreature) -> count         incaps in the last ten minutes; at 2 the next one kills, so no fight
 *                                               (botStartFight refuses) and no duel worth accepting
 *
 * Also starts BotCombat's tick (its events: "incapacitated", "died", "revived", "cloned", "duel", "fightEnded").
 */

#ifndef BOTCOMBATLUA_H_
#define BOTCOMBATLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotCombatLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botSetTarget(lua_State* L);
	static int botDuelState(lua_State* L);
	static int botStartFight(lua_State* L);
	static int botEndFight(lua_State* L);
	static int botClone(lua_State* L);
	static int botEquip(lua_State* L);
	static int botRepairGear(lua_State* L);
	static int botFindPack(lua_State* L);
	static int botRecentIncaps(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTCOMBATLUA_H_ */
