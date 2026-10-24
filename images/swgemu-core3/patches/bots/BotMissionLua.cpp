/*
 * BotMissionLua (bot players, Phase 7). See BotMissionLua.h.
 */

#include "BotMissionLua.h"
#include "BotMission.h"
#include "BotManager.h"
#include "BotGroup.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"

namespace {

// Lua passes Core3 objects as light userdata; anything else (nil, a number) is no object
SceneObject* toSceneObject(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_islightuserdata(L, index))
		return nullptr;

	return static_cast<SceneObject*>(lua_touserdata(L, index));
}

CreatureObject* toCreature(lua_State* L, int index) {
	SceneObject* object = toSceneObject(L, index);

	if (object == nullptr || !object->isCreatureObject())
		return nullptr;

	return object->asCreatureObject();
}

CreatureObject* toOnlineBot(lua_State* L, int index) {
	CreatureObject* creature = toCreature(L, index);

	if (creature == nullptr || !BotManager::instance()->isOnlineBot(creature))
		return nullptr;

	return creature;
}

// A number, or a number in a string (console arguments are strings)
double toNumber(lua_State* L, int index, double fallback = 0) {
	if (lua_gettop(L) < index)
		return fallback;

	if (lua_type(L, index) == LUA_TNUMBER)
		return lua_tonumber(L, index);

	if (lua_type(L, index) == LUA_TSTRING)
		return atof(lua_tostring(L, index));

	return fallback;
}

uint64 toOid(lua_State* L, int index) {
	if (lua_gettop(L) < index)
		return 0;

	if (lua_type(L, index) == LUA_TNUMBER)
		return (uint64) lua_tointeger(L, index);

	if (lua_type(L, index) == LUA_TSTRING)
		return strtoull(lua_tostring(L, index), nullptr, 10);

	return 0;
}

void setNumber(lua_State* L, const char* field, double value) {
	lua_pushnumber(L, value);
	lua_setfield(L, -2, field);
}

void setInteger(lua_State* L, const char* field, int64 value) {
	lua_pushinteger(L, value);
	lua_setfield(L, -2, field);
}

void setString(lua_State* L, const char* field, const String& value) {
	lua_pushstring(L, value.toCharArray());
	lua_setfield(L, -2, field);
}

int pushFailure(lua_State* L, const String& error) {
	lua_pushnil(L);
	lua_pushstring(L, error.toCharArray());

	return 2;
}

void pushMissions(lua_State* L, const Vector<Reference<BotMissionInfo*>>& missions) {
	lua_newtable(L);

	for (int i = 0; i < missions.size(); ++i) {
		const BotMissionInfo* info = missions.get(i);

		lua_newtable(L);

		setInteger(L, "oid", info->oid);
		setInteger(L, "reward", info->reward);
		setNumber(L, "x", info->x);
		setNumber(L, "y", info->y);
		setString(L, "planet", info->planet);
		setNumber(L, "distance", info->distance);
		setInteger(L, "degrees", info->degrees);
		setString(L, "direction", info->direction);
		setString(L, "target", info->target);
		setInteger(L, "level", info->level);
		lua_pushboolean(L, info->lairUp);
		lua_setfield(L, -2, "lairUp");

		lua_rawseti(L, -2, i + 1);
	}
}

}

void BotMissionLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botMissionTerminals", botMissionTerminals);
	lua->registerFunction("botMissionList", botMissionList);
	lua->registerFunction("botMissionAccept", botMissionAccept);
	lua->registerFunction("botMissionAbort", botMissionAbort);
	lua->registerFunction("botMissions", botMissions);
	lua->registerFunction("botPlayerMissions", botPlayerMissions);
	lua->registerFunction("botMissionDone", botMissionDone);
	lua->registerFunction("botMissionSync", botMissionSync);
	lua->registerFunction("botWaypoints", botWaypoints);
}

// botMissionTerminals(pBot, range)
int BotMissionLua::botMissionTerminals(lua_State* L) {
	// Any creature: it only reads where the terminals are (the crew looks around its leader too)
	CreatureObject* bot = toCreature(L, 1);
	Vector<Reference<BotMissionTerminal*>> found;

	if (bot == nullptr || !BotMission::findTerminals(bot, (float) toNumber(L, 2, 30), found))
		return pushFailure(L, "no bot");

	lua_newtable(L);

	for (int i = 0; i < found.size(); ++i) {
		const BotMissionTerminal* terminal = found.get(i);

		lua_newtable(L);

		setInteger(L, "oid", terminal->oid);
		setNumber(L, "distance", terminal->distance);
		setNumber(L, "x", terminal->x);
		setNumber(L, "z", terminal->z);
		setNumber(L, "y", terminal->y);
		setInteger(L, "cell", terminal->cell);
		setString(L, "planet", terminal->planet);

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botMissionList(pBot, terminalOid[, refresh])
int BotMissionLua::botMissionList(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Vector<Reference<BotMissionInfo*>> missions;
	String error = "no bot";

	if (bot != nullptr) {
		bool refresh = lua_gettop(L) < 3 || lua_isnil(L, 3) || lua_toboolean(L, 3);

		error = "";

		if (BotMission::list(bot, toOid(L, 2), refresh, missions, error)) {
			pushMissions(L, missions);
			return 1;
		}
	}

	return pushFailure(L, error);
}

// botMissionAccept(pBot, terminalOid, missionOid)
int BotMissionLua::botMissionAccept(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String error = "no bot";
	bool ok = false;

	if (bot != nullptr) {
		error = "";
		ok = BotMission::accept(bot, toOid(L, 2), toOid(L, 3), error);
	}

	lua_pushboolean(L, ok);
	lua_pushstring(L, error.toCharArray());

	return 2;
}

// botMissionAbort(pBot)
int BotMissionLua::botMissionAbort(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String error = "";
	int aborted = bot != nullptr ? BotMission::abortAll(bot, error) : 0;

	lua_pushinteger(L, aborted);
	lua_pushstring(L, error.toCharArray());

	return 2;
}

// botMissions(pBot)
int BotMissionLua::botMissions(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Vector<Reference<BotMissionInfo*>> missions;

	if (bot == nullptr || !BotMission::current(bot, missions)) {
		lua_pushnil(L);
		return 1;
	}

	pushMissions(L, missions);

	return 1;
}

// botPlayerMissions(pCreature)
int BotMissionLua::botPlayerMissions(lua_State* L) {
	// Any player creature (a human of the group): read-only, the datapad is read with the player locked, as botWaypoints does
	CreatureObject* player = toCreature(L, 1);
	Vector<Reference<BotMissionInfo*>> missions;

	if (player == nullptr || !player->isPlayerCreature() || !BotMission::current(player, missions)) {
		lua_pushnil(L);
		return 1;
	}

	pushMissions(L, missions);

	return 1;
}

// botMissionDone(missionOid)
int BotMissionLua::botMissionDone(lua_State* L) {
	lua_pushboolean(L, BotGroup::wasMissionDone(toOid(L, 1)));

	return 1;
}

// botMissionSync(pBot[, pLeader])
int BotMissionLua::botMissionSync(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* leader = toCreature(L, 2);

	lua_pushinteger(L, bot != nullptr ? BotMission::syncWaypoints(bot, leader) : 0);

	return 1;
}

// botWaypoints(pCreature)
int BotMissionLua::botWaypoints(lua_State* L) {
	CreatureObject* owner = toCreature(L, 1);
	Vector<Reference<BotWaypointInfo*>> found;

	if (owner == nullptr || !BotMission::listWaypoints(owner, found)) {
		lua_pushnil(L);
		return 1;
	}

	lua_newtable(L);

	for (int i = 0; i < found.size(); ++i) {
		const BotWaypointInfo* info = found.get(i);

		lua_newtable(L);

		setInteger(L, "oid", info->oid);
		setString(L, "name", info->name);
		setNumber(L, "x", info->x);
		setNumber(L, "y", info->y);
		setInteger(L, "planetCRC", info->planetCRC);
		setString(L, "description", info->description);
		lua_pushboolean(L, info->active);
		lua_setfield(L, -2, "active");

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}
