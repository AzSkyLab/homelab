/*
 * BotMoverLua (bot players, Phase 5). See BotMoverLua.h.
 */

#include "BotMoverLua.h"
#include "BotMover.h"
#include "BotManager.h"
#include "BotChat.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "templates/params/creature/CreaturePosture.h"

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

bool hasNumber(lua_State* L, int index) {
	return lua_gettop(L) >= index && lua_type(L, index) == LUA_TNUMBER;
}

String toString(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isstring(L, index))
		return "";

	return lua_tostring(L, index);
}

// BotRoster.settings[name] in this Lua state (the jobs screenplay includes the roster), or the fallback
float rosterSetting(lua_State* L, const char* name, float fallback) {
	int top = lua_gettop(L);
	float value = fallback;

	lua_getglobal(L, "BotRoster");

	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "settings");

		if (lua_istable(L, -1)) {
			lua_getfield(L, -1, name);

			if (lua_type(L, -1) == LUA_TNUMBER)
				value = (float)lua_tonumber(L, -1);
		}
	}

	lua_settop(L, top);

	return value;
}

int paceOf(const String& pace) {
	String lower = pace.toLowerCase();

	if (lower == "run" || lower == "true")
		return BotMover::PACE_RUN;

	if (lower == "walk" || lower == "false")
		return BotMover::PACE_WALK;

	return BotMover::PACE_AUTO;
}

int paceAt(lua_State* L, int index) {
	if (lua_gettop(L) < index)
		return BotMover::PACE_AUTO;

	if (lua_type(L, index) == LUA_TBOOLEAN)
		return lua_toboolean(L, index) ? BotMover::PACE_RUN : BotMover::PACE_WALK;

	if (lua_type(L, index) == LUA_TSTRING)
		return paceOf(lua_tostring(L, index));

	return BotMover::PACE_AUTO;
}

// --- Dev helpers ---

// The dev tools work only while the dev human switch is on (never in production)
bool devAllowed() {
	if (BotManager::instance()->isDevHuman())
		return true;

	BotManager::instance()->info(true) << "BotMoverDev: only while BotJobs:devHuman is on";

	return false;
}

Reference<CreatureObject*> devBot(const String& firstName) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(firstName);

	if (bot == nullptr)
		BotManager::instance()->info(true) << "BotMoverDev: no online bot called '" << firstName << "'";

	return bot;
}

void devReport(CreatureObject* bot) {
	BotManager::instance()->info(true) << "BotMoverDev: " << BotMover::describe(bot);
}

int64 luaReadData(lua_State* L, const String& key) {
	int top = lua_gettop(L);
	int64 value = 0;

	lua_getglobal(L, "readData");

	if (lua_isfunction(L, -1)) {
		lua_pushstring(L, key.toCharArray());

		if (lua_pcall(L, 1, 1, 0) == 0 && lua_type(L, -1) == LUA_TNUMBER)
			value = lua_tointeger(L, -1);
	}

	lua_settop(L, top);

	return value;
}

void luaWrite(lua_State* L, const char* function, const String& key, const String* text, int64 number) {
	int top = lua_gettop(L);

	lua_getglobal(L, function);

	if (lua_isfunction(L, -1)) {
		lua_pushstring(L, key.toCharArray());

		if (text != nullptr)
			lua_pushstring(L, text->toCharArray());
		else
			lua_pushinteger(L, number);

		lua_pcall(L, 2, 0, 0);
	}

	lua_settop(L, top);
}

}

void BotMoverLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botFollow", botFollow);
	lua->registerFunction("botStop", botStop);
	lua->registerFunction("botMoveTo", botMoveTo);
	lua->registerFunction("botMoveState", botMoveState);
	lua->registerFunction("botCallTo", botCallTo);

	// BotMoverDev: console tools for bot-on-bot tests (runLuaFunction passes the table as the first argument)
	lua_State* L = lua->getLuaState();

	lua_newtable(L);

	lua_pushcfunction(L, devFollow);
	lua_setfield(L, -2, "follow");
	lua_pushcfunction(L, devStop);
	lua_setfield(L, -2, "stop");
	lua_pushcfunction(L, devMoveTo);
	lua_setfield(L, -2, "moveTo");
	lua_pushcfunction(L, devPatrol);
	lua_setfield(L, -2, "patrol");
	lua_pushcfunction(L, devZone);
	lua_setfield(L, -2, "zone");
	lua_pushcfunction(L, devCall);
	lua_setfield(L, -2, "call");
	lua_pushcfunction(L, devQuiet);
	lua_setfield(L, -2, "quiet");
	lua_pushcfunction(L, devState);
	lua_setfield(L, -2, "state");
	lua_pushcfunction(L, devList);
	lua_setfield(L, -2, "list");

	lua_setglobal(L, "BotMoverDev");
}

// botFollow(pBot, pLeader[, near, far])
int BotMoverLua::botFollow(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* leader = toCreature(L, 2);
	bool ok = false;

	if (bot != nullptr && leader != nullptr) {
		float nearDist = hasNumber(L, 3) ? (float)lua_tonumber(L, 3) : rosterSetting(L, "followNear", 3);
		float farDist = hasNumber(L, 4) ? (float)lua_tonumber(L, 4) : rosterSetting(L, "followFar", 5);

		ok = BotMover::follow(bot, leader, nearDist, farDist);
	}

	lua_pushboolean(L, ok);

	return 1;
}

// botStop(pBot)
int BotMoverLua::botStop(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotMover::stop(bot));

	return 1;
}

// botMoveTo(pBot, x, z, y, cellOid[, pace])
int BotMoverLua::botMoveTo(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool ok = false;

	if (bot != nullptr && hasNumber(L, 2) && hasNumber(L, 3) && hasNumber(L, 4)) {
		uint64 cell = hasNumber(L, 5) ? (uint64)lua_tointeger(L, 5) : 0;

		ok = BotMover::moveTo(bot, (float)lua_tonumber(L, 2), (float)lua_tonumber(L, 3), (float)lua_tonumber(L, 4), cell, paceAt(L, 6));
	}

	lua_pushboolean(L, ok);

	return 1;
}

// botCallTo(pBot, pPlayer): the bot appears near the player
int BotMoverLua::botCallTo(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* player = toCreature(L, 2);
	bool ok = false;

	if (bot != nullptr && player != nullptr) {
		Locker locker(bot);

		ok = BotMover::callTo(bot, player);
	}

	lua_pushboolean(L, ok);

	return 1;
}

// botMoveState(pBot): {state, leader, distance, stuck}, or nil for anything but an online bot
int BotMoverLua::botMoveState(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	BotMoveStatus status;

	if (bot == nullptr || !BotMover::getStatus(bot, status)) {
		lua_pushnil(L);
		return 1;
	}

	lua_newtable(L);

	lua_pushstring(L, status.state.toCharArray());
	lua_setfield(L, -2, "state");
	lua_pushinteger(L, status.leader);
	lua_setfield(L, -2, "leader");
	lua_pushnumber(L, status.distance);
	lua_setfield(L, -2, "distance");
	lua_pushboolean(L, status.stuck);
	lua_setfield(L, -2, "stuck");

	return 1;
}

// --- BotMoverDev (arguments start at 2: runLuaFunction passes the table first) ---

int BotMoverLua::devFollow(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));
	Reference<CreatureObject*> leader = devBot(toString(L, 3));

	if (bot != nullptr && leader != nullptr) {
		bool ok = BotMover::follow(bot, leader, rosterSetting(L, "followNear", 3), rosterSetting(L, "followFar", 5));

		BotManager::instance()->info(true) << "BotMoverDev: follow " << (ok ? "ok" : "refused");
	}

	return 0;
}

// call:<bot>:<player's first name>: Phase 8's botCallTo (the player is another online bot in the dev tests, or any player)
int BotMoverLua::devCall(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));
	Reference<CreatureObject*> player = devBot(toString(L, 3));

	if (bot != nullptr && player != nullptr) {
		Locker locker(bot);

		bool ok = BotMover::callTo(bot, player);

		BotManager::instance()->info(true) << "BotMoverDev: call " << (ok ? "ok" : "refused");
	}

	return 0;
}

int BotMoverLua::devStop(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));

	if (bot != nullptr)
		BotMover::stop(bot);

	return 0;
}

int BotMoverLua::devMoveTo(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));

	if (bot == nullptr)
		return 0;

	bool ok = BotMover::moveTo(bot, Float::valueOf(toString(L, 3)), Float::valueOf(toString(L, 4)), Float::valueOf(toString(L, 5)),
			UnsignedLong::valueOf(toString(L, 6)), paceOf(toString(L, 7)));

	BotManager::instance()->info(true) << "BotMoverDev: moveTo " << (ok ? "ok" : "refused (no way there)");

	return 0;
}

// patrol:<bot>:<x,z,y,cell;x,z,y,cell;...>[:walk|run]
int BotMoverLua::devPatrol(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));

	if (bot == nullptr)
		return 0;

	Vector<Vector3> points;
	Vector<uint64> cells;
	StringTokenizer legs(toString(L, 3));
	legs.setDelimiter(";");

	while (legs.hasMoreTokens()) {
		String leg;
		legs.getStringToken(leg);

		StringTokenizer parts(leg);
		parts.setDelimiter(",");

		float x = parts.hasMoreTokens() ? parts.getFloatToken() : 0;
		float z = parts.hasMoreTokens() ? parts.getFloatToken() : 0;
		float y = parts.hasMoreTokens() ? parts.getFloatToken() : 0;
		uint64 cell = parts.hasMoreTokens() ? parts.getLongToken() : 0;

		points.add(Vector3(x, y, z));
		cells.add(cell);
	}

	bool ok = BotMover::patrol(bot, points, cells, paceOf(toString(L, 4)));

	BotManager::instance()->info(true) << "BotMoverDev: patrol of " << points.size() << " points " << (ok ? "ok" : "refused");

	return 0;
}

// zone:<bot>:<planet>:<x>:<y>: switchZone, as a shuttle does (BotManager makes it scene-ready)
int BotMoverLua::devZone(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));

	if (bot == nullptr)
		return 0;

	String planet = toString(L, 3);
	float x = Float::valueOf(toString(L, 4));
	float y = Float::valueOf(toString(L, 5));

	Core::getTaskManager()->executeTask([bot, planet, x, y]() {
		Locker locker(bot);

		bot->switchZone(planet, x, 0, y, 0);

		BotManager::instance()->info(true) << "BotMoverDev: " << bot->getFirstName() << " switching to " << planet << " " << x << " " << y;
	}, "BotMoverDevZone");

	return 0;
}

// quiet:<bot>: its job stops ticking (a new generation, no job); it stops performing and stands
int BotMoverLua::devQuiet(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));

	if (bot == nullptr)
		return 0;

	String prefix = "bot:" + String::valueOf(bot->getObjectID()) + ":";
	String none = "";

	luaWrite(L, "writeStringData", prefix + "job", &none, 0);
	luaWrite(L, "writeData", prefix + "gen", nullptr, luaReadData(L, prefix + "gen") + 1);

	if (bot->isDancing())
		BotChat::enqueue(bot, "stopdance", 0, "");
	else if (bot->isPlayingMusic())
		BotChat::enqueue(bot, "stopmusic", 0, "");

	if (bot->getPosture() != CreaturePosture::UPRIGHT)
		BotChat::enqueue(bot, "stand", 0, "");

	BotManager::instance()->info(true) << "BotMoverDev: " << bot->getFirstName() << "'s job is stopped (BotJobs:restart to start it)";

	return 0;
}

int BotMoverLua::devState(lua_State* L) {
	if (!devAllowed())
		return 0;

	Reference<CreatureObject*> bot = devBot(toString(L, 2));

	if (bot != nullptr)
		devReport(bot);

	return 0;
}

int BotMoverLua::devList(lua_State* L) {
	if (!devAllowed())
		return 0;

	Vector<Reference<CreatureObject*>> bots;
	BotManager::instance()->getOnlineBots(bots);

	for (int i = 0; i < bots.size(); ++i)
		devReport(bots.get(i));

	return 0;
}
