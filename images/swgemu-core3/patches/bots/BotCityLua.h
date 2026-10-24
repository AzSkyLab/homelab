/*
 * BotCityLua: the Lua bindings for the player city (Phase 6), registered from BotLua::registerFunctions. The work is in
 * BotCity; see ~/github/swgemu/specs/2026-10-23-bot-players/interfaces.md, "Phases 4-6: additions", for the contract.
 *
 * Every function is safe with nil, a non-bot or an offline bot: it returns false, nil or 0.
 *
 *   botCheckSite(planet, x, y, radius[, areaRadius])  -> {ok, reasons, warnings, heightDiff, heightDiffArea, z, blocked,
 *                                                         water, nearestCity, nearestDistance, nearestLimit}
 *   botFoundCity(pMayor, x, y, angle, name)            -> city id or 0 (idempotent by name; angle 0-3)
 *   botCityInfo(name | pCreature)                      -> table (see BotCityLua.cpp) or nil; a creature: its residence's city
 *   botDeclareResidence(pBot, structureOid)            -> bool
 *   botOwnedStructures(pBot)                           -> array of {oid, template, name, kind, x, y, city, residence}
 *   botCheckPlacement(pBot, deedOid, x, y, angle)      -> ok, reason (what Core3 would say, without placing)
 *   botPlaceStructure(pBot, deedOid, x, y, angle)      -> bool: checked and logged, then the real /placestructure, and a
 *                                                         watcher: event "placed" (pOther the structure, detail its
 *                                                         template) or "placeFailed" (detail the reason)
 *   botCityDeposit(name, credits[, pFrom])             -> bool (queued; pFrom a bot pays from its cash, then bank)
 *   botCitySetTax(name, index, value)                  -> bool (0 income, 1 property, 2 sales, 3 travel, 4 garage)
 *   botCitySetSpec(name, spec)                         -> bool ("entertainer", "city_spec_entertainer", "" clears)
 *   botCityZoning(name, on)                            -> bool
 *   botCityRegister(name[, on])                        -> bool (on defaults to true)
 *   botCityCandidate(pBot, name)                       -> bool
 *   botCityVote(pBot, name, candidateOid)              -> bool (0 abstains)
 *   botCityExpand(name[, fullUpdate])                  -> bool (dev only: rank up, or a full weekly update)
 *   botPlaceDecoration(pMayor, template)               -> oid or 0 (at the mayor's feet)
 *
 * The console tools (global table BotCityDev, so `console runLuaFunction BotCityDev:<fn>:<arg>:...` works; the
 * changing ones need botSetDevHuman on): probe, probeRing, info, owned, grant, surrender, bring, found, house,
 * declare, expand, deposit, decorate, zoning, tax, spec, register, candidate, vote, destroy, raze. Usage is in
 * BotCityLua.cpp.
 */

#ifndef BOTCITYLUA_H_
#define BOTCITYLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotCityLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botCheckSite(lua_State* L);
	static int botFoundCity(lua_State* L);
	static int botCityInfo(lua_State* L);
	static int botDeclareResidence(lua_State* L);
	static int botOwnedStructures(lua_State* L);
	static int botCheckPlacement(lua_State* L);
	static int botPlaceStructure(lua_State* L);
	static int botCityDeposit(lua_State* L);
	static int botCitySetTax(lua_State* L);
	static int botCitySetSpec(lua_State* L);
	static int botCityZoning(lua_State* L);
	static int botCityRegister(lua_State* L);
	static int botCityCandidate(lua_State* L);
	static int botCityVote(lua_State* L);
	static int botCityExpand(lua_State* L);
	static int botPlaceDecoration(lua_State* L);

	// BotCityDev:<fn> (console; the arguments are strings, after self)
	static int devProbe(lua_State* L);
	static int devProbeRing(lua_State* L);
	static int devInfo(lua_State* L);
	static int devOwned(lua_State* L);
	static int devGrant(lua_State* L);
	static int devSurrender(lua_State* L);
	static int devBring(lua_State* L);
	static int devFound(lua_State* L);
	static int devHouse(lua_State* L);
	static int devDeclare(lua_State* L);
	static int devExpand(lua_State* L);
	static int devDeposit(lua_State* L);
	static int devDecorate(lua_State* L);
	static int devZoning(lua_State* L);
	static int devTax(lua_State* L);
	static int devSpec(lua_State* L);
	static int devRegister(lua_State* L);
	static int devCandidate(lua_State* L);
	static int devVote(lua_State* L);
	static int devDestroy(lua_State* L);
	static int devRaze(lua_State* L);

	enum { MAYOR_ZONING, MAYOR_TAX, MAYOR_SPEC, MAYOR_REGISTER };

	static int devMayor(lua_State* L, int control);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTCITYLUA_H_ */
