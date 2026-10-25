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
 *   botCreaturesNear(pBot, range) -> {{oid, x, y, radius, target}, ...}   the live creatures (never players or pets) within
 *                                               range metres that the bot may attack, nearest first, at most 40; target is
 *                                               who each fights (0 for nobody). For area attacks (Phase 8): scan when weighing
 *                                               one, not every step
 *   botResists(pCreature) -> {kinetic, energy, blast, heat, cold, electricity, acid, stun, lightsaber} or nil
 *                                               a creature's resistances in percent (-1: vulnerable); nil for anything
 *                                               but an AiAgent (Phase 8: the commando's weapon choice)
 *   botRecentIncaps(pCreature) -> count         incaps in the last ten minutes; at 2 the next one kills, so no fight
 *                                               (botStartFight refuses) and no duel worth accepting
 *   botDropDeadDefenders(pCreature) -> count   takes the dead from a creature's defender list (a player left in combat on
 *                                               a corpse something else killed); live defenders stay. Call it in an event on
 *                                               the creature
 *   botWeaponRange(pBot) -> table|nil          the held weapon's ranges (unarmed: the default fists): {template, ranged,
 *                                               pointBlankRange, pointBlankAccuracy, idealRange, idealAccuracy, maxRange,
 *                                               maxAccuracy}. nil for a non-bot
 *   botLairsNear(pBot, range) -> array of {oid, x, y}   the lairs within range metres (a scan: now and then, not every step)
 *   botThreatOn(pBot, pCreature) -> table|nil   what a creature is on and how it can be taunted: {target (oid, 0 for
 *                                               nobody), tauntable, taunted, tauntedBy, lockoutMs (until a taunt takes
 *                                               effect again), poisoned, diseased, poisonImmune,
 *                                               diseaseImmune, entries = {{oid, name, damage, aggro, heal, taunted}...}}.
 *                                               nil when pCreature isn't an AiAgent. Call it in an event on the bot
 *
 * Dev table BotCombatDev (console: runLuaFunction BotCombatDev:<fn>:<args>, output in the pod log):
 *   threat:<oid>   a creature's threat map (entries, damage, aggro, heal, state), its target, taunt lockout
 *   range:<first>  a bot's held weapon and its ranges
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
	static int botResists(lua_State* L);
	static int botCreaturesNear(lua_State* L);
	static int botRecentIncaps(lua_State* L);
	static int botDropDeadDefenders(lua_State* L);
	static int botWeaponRange(lua_State* L);
	static int botThreatOn(lua_State* L);
	static int botLairsNear(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTCOMBATLUA_H_ */
