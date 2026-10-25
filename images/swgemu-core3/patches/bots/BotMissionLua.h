/*
 * BotMissionLua: the Lua bindings for destroy missions (Phase 7, see BotMission.h). Registered from
 * BotLua::registerFunctions, so every Lua state has them. Safe with nil, a non-bot or an offline bot.
 *
 *   botMissionTerminals(pBot, range) -> {{oid, distance, x, z, y, cell, planet}, ...} nearest first (general mission
 *       terminals only; x, z, y and cell are what botMoveTo takes), or nil and why
 *   botMissionList(pBot, terminalOid[, refresh]) -> {{oid, reward, x, y, planet, distance, degrees, direction, target,
 *       level, lairUp}, ...}, or nil and why ("terminal", "far", "wait", "refused"). The bot must be within 6 m of the terminal;
 *       refresh (default true) refills the list as the terminal's refresh does, at most every 1.4 s ("wait").
 *       distance, degrees (0 north, 90 east) and direction are from the terminal
 *       Each mission also has lair (the lair template's name) and creatures (what lives in it: lowercase names as the
 *       client shows them)
 *   botMissionCreatures(pBot) -> every lowercase name (lairs' and creatures') in this planet's destroy-mission lairs
 *   botMissionAccept(pBot, terminalOid, missionOid) -> true, or false and why ("terminal", "far", "gone", "full")
 *   botMissionAbort(pBot) -> how many missions it aborted, and "combat" if some stayed
 *   botMissions(pBot) -> the destroy missions it holds, as botMissionList gives them (distance and direction from the
 *       bot; lairUp is true once the mission's lair has spawned), or nil
 *   botPlayerMissions(pCreature) -> the same for any player creature (a human's own missions; read-only), or nil
 *   botMissionDone(missionOid) -> true if that mission was completed and rewarded (patches/0008), as against dropped,
 *       failed or expired: a mission that left a datapad with its lair up is a lair destroyed only if this is true
 *   botMissionSync(pBot[, pLeader]) -> 1 if it queued the work (it runs a moment later), else 0. With a leader: each mission has a waypoint in the
 *       leader's datapad, "<Bot>: <target>", and finished ones go. Without: the bot's waypoints in its old leader's
 *       datapad go
 *   botWaypoints(pCreature) -> {{oid, name, x, y, planetCRC, description, active}, ...}: what is in its datapad
 */

#ifndef BOTMISSIONLUA_H_
#define BOTMISSIONLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotMissionLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botMissionTerminals(lua_State* L);
	static int botMissionList(lua_State* L);
	static int botMissionAccept(lua_State* L);
	static int botMissionAbort(lua_State* L);
	static int botMissions(lua_State* L);
	static int botMissionCreatures(lua_State* L);
	static int botPlayerMissions(lua_State* L);
	static int botMissionDone(lua_State* L);
	static int botMissionSync(lua_State* L);
	static int botWaypoints(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTMISSIONLUA_H_ */
