/*
 * BotGroupLua: the Lua bindings for groups, group chat, the ranger's camp and tracking (Phase 5). Registered from
 * BotLua::registerFunctions.
 *
 *   botGetGroupInviter(pBot)           the oid of whoever invited the bot, or 0 (also event "groupInvite", pOther the
 *                                      inviter); the jobs answer with botEnqueue(pBot, "join" / "decline", 0, "")
 *   botPlaceCamp(pBot[, kitTemplate])  the camp's oid, or 0 and why ("skill", "in combat", "inside", "in a city",
 *                                      "no camping here", "in water", "in another camp", "building too close", "camp
 *                                      too close", "lair too close", "not placed ..."); an existing camp's oid and
 *                                      "already camping". The default kit is the master camp (camp_luxury). The third
 *                                      result is the oid of the camp, building or lair that is too close (else 0)
 *   botCampSpots(pBot, kit, points)    would a camp take at each point? points is {x1, y1, x2, y2, ...} (world coordinates on the bot's
 *                                      planet); gives {reason1, reason2, ...}, "" for clear ground, else "camp too close", "building
 *                                      too close", "lair too close", "in water", "no camping here" or "in a city": the kit's own scan
 *                                      without placing, once for all the points (at most 512 numbers, 256 points). nil when the bot isn't in a zone (positioning fix, camp search)
 *   botAttackers(pCreature)            array of the oids of the live creatures attacking a bot or a player, nearest
 *                                      first (their threat map; a creature that is attacked has no defender of its
 *                                      own until it hits back). Call it from an event on that creature
 *   botRemoveCamp(pBot)                disbands the bot's camp
 *   botGetCamp(pBot)                   the bot's camp's oid, or 0
 *   botTrack(pBot[, type])             array of {name, distance, bearing, degrees, oid, kind, level}, nearest first;
 *                                      type 0 (default) animals, 1 NPCs, 2 players. nil and why if it can't
 *   botPeopleNear(pObject, range)      array of {name, oid, kind ("player" or "npc")}: the players (bots too) and people NPCs
 *                                      (the crowd, vendors; no animals) around it, for who a spoken line might be for
 *   botHumansOnline()                  array of the oids of the players online with a client (never a bot): the crew's
 *                                      group cap leaves a slot for the other human (Phase 8)
 *   botGroupInfo(pCreature)            nil when it has no group, else {id, leader, members = {oid, ...}} (group order, the leader
 *                                      first). Lock-free: use it for another creature's group (a human, another bot), never
 *                                      getGroupSize / getGroupMember, which lock that creature and then its group (Phase 8)
 * Group chat from humans reaches BotJobs:onHeard(pBot, pSpeaker, text, "group") (BotGroup, patches/0003).
 *
 * Development (console):
 *   runLuaFunction BotGroupDev:invite:<from>:<to>      (join:<first>, decline:<first>, leave:<first>)
 *   runLuaFunction BotGroupDev:gsay:<first>:<text>     group chat as a bot ("_" is a space)
 *   runLuaFunction BotGroupDev:teleport:<first>:<x>:<y>   outdoors on its planet (z from the terrain)
 *   runLuaFunction BotGroupDev:camp:<first>[:<kit>]    (uncamp:<first>)
 *   runLuaFunction BotGroupDev:track:<first>[:<type>]
 *   runLuaFunction BotGroupDev:skillmod:<first>:<mod>  a bot's skill mod (e.g. private_medical_rating, camp)
 *   runLuaFunction BotGroupDev:group:<first>            who is in its group, the loot rule (lootrule:<first>:<0-3>, roomsay:<first>:<text>: typed into the group room)
 *   runLuaFunction BotGroupDev:why:<enhancer>:<patient>  the checks of /healenhance, as a line (refusals go only to a client)
 *   runLuaFunction BotGroupDev:fight:<first>:<oid>      the bot targets and attacks it (mob:<oid>: its state and threat map)
 *   runLuaFunction BotGroupDev:grouploot:<first>:<corpse>:<2|3>  the lottery or random loot step on a corpse; weaken:<oid>
 *   runLuaFunction BotGroupDev:spawn:<first>:<mobile>[:<m>]  a creature in front of the bot (logs its oid)
 *   runLuaFunction BotGroupDev:cmd:<first>:<command>[:<target bot or oid>[:<args>]]   any command, as botEnqueue
 */

#ifndef BOTGROUPLUA_H_
#define BOTGROUPLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotGroupLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botGetGroupInviter(lua_State* L);
	static int botPlaceCamp(lua_State* L);
	static int botCampSpots(lua_State* L);
	static int botRemoveCamp(lua_State* L);
	static int botGetCamp(lua_State* L);
	static int botTrack(lua_State* L);
	static int botAttackers(lua_State* L);
	static int botPeopleNear(lua_State* L);
	static int botHumansOnline(lua_State* L);
	static int botGroupInfo(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTGROUPLUA_H_ */
