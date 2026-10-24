/*
 * BotMoverLua: the Lua bindings for walking and following (Phase 5, see BotMover.h). Registered from
 * BotLua::registerFunctions, so every Lua state has them. Safe with nil, a non-bot or an offline bot.
 *
 *   botFollow(pBot, pLeader[, near, far]) -> bool    near/far default to roster settings followNear/followFar (3, 5)
 *   botStop(pBot) -> bool
 *   botMoveTo(pBot, x, z, y, cellOid[, pace]) -> bool    pace "walk", "run" (or true), default: run over 30 m
 *   botMoveState(pBot) -> {state, leader, distance, stuck} or nil
 *   Events (BotJobs:onEvent): "arrived", "stuck" (detail "noEntry", "blocked", "moved" or "zone"),
 *   "leaderGone" (detail the leader's oid)
 *
 * Development, from the console (only while BotJobs:devHuman is on; the local server has no game client):
 *   runLuaFunction BotMoverDev:follow:<bot>:<leader bot>          runLuaFunction BotMoverDev:stop:<bot>
 *   runLuaFunction BotMoverDev:moveTo:<bot>:<x>:<z>:<y>:<cell>[:walk|run]
 *   runLuaFunction BotMoverDev:patrol:<bot>:<x,z,y,cell;x,z,y,cell;...>[:walk|run]   a loop of moveTo legs
 *   runLuaFunction BotMoverDev:zone:<bot>:<planet>:<x>:<y>      switchZone, e.g. a leader taking a shuttle
 *   runLuaFunction BotMoverDev:quiet:<bot>                       stop its job (BotJobs:restart starts it again)
 *   runLuaFunction BotMoverDev:state:<bot>                       runLuaFunction BotMoverDev:list
 */

#ifndef BOTMOVERLUA_H_
#define BOTMOVERLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotMoverLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botFollow(lua_State* L);
	static int botStop(lua_State* L);
	static int botMoveTo(lua_State* L);
	static int botMoveState(lua_State* L);

	static int devFollow(lua_State* L);
	static int devStop(lua_State* L);
	static int devMoveTo(lua_State* L);
	static int devPatrol(lua_State* L);
	static int devZone(lua_State* L);
	static int devQuiet(lua_State* L);
	static int devState(lua_State* L);
	static int devList(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTMOVERLUA_H_ */
