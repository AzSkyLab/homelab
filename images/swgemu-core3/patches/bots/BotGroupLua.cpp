/*
 * BotGroupLua (bot players). See BotGroupLua.h.
 */

#include "BotGroupLua.h"
#include "BotGroup.h"
#include "BotManager.h"
#include "BotChat.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/managers/collision/CollisionManager.h"

using namespace server::zone::managers::bot;

namespace {

Logger& devLog() {
	static Logger logger("BotGroupDev");

	return logger;
}

CreatureObject* toOnlineBot(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_islightuserdata(L, index))
		return nullptr;

	SceneObject* object = static_cast<SceneObject*>(lua_touserdata(L, index));

	if (object == nullptr || !object->isCreatureObject())
		return nullptr;

	CreatureObject* creature = object->asCreatureObject();

	return BotManager::instance()->isOnlineBot(creature) ? creature : nullptr;
}

String toString(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isstring(L, index))
		return "";

	return lua_tostring(L, index);
}

// A number, or a number in a string (console arguments are strings)
double toNumber(lua_State* L, int index, double fallback = 0) {
	if (lua_gettop(L) < index)
		return fallback;

	if (lua_type(L, index) == LUA_TNUMBER)
		return lua_tonumber(L, index);

	if (lua_type(L, index) == LUA_TSTRING) {
		String text = lua_tostring(L, index);

		if (text.isEmpty())
			return fallback;

		try {
			return Double::valueOf(text);
		} catch (const Exception& e) {
			return fallback;
		}
	}

	return fallback;
}

// --- Development table, BotGroupDev (console: runLuaFunction BotGroupDev:<fn>:<args>; argument 1 is the table) ---

Reference<CreatureObject*> devBot(lua_State* L, int index) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(toString(L, index));

	if (bot == nullptr)
		devLog().info(true) << "no online bot called " << toString(L, index);

	return bot;
}

int devCommand(lua_State* L, const char* command, uint64 target, const String& args) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " " << command << ": " << (BotChat::enqueue(bot, command, target, args) ? "queued" : "failed");

	return 0;
}

// cmd:<first>:<command>[:<target bot or oid>[:<args>]]: any command, as botEnqueue
int devAnyCommand(lua_State* L) {
	String command = toString(L, 3);
	String target = toString(L, 4);
	uint64 targetOid = 0;

	if (!target.isEmpty()) {
		Reference<CreatureObject*> targetBot = BotManager::instance()->getOnlineBot(target);

		if (targetBot != nullptr) {
			targetOid = targetBot->getObjectID();
		} else {
			try {
				targetOid = UnsignedLong::valueOf(target);
			} catch (const Exception& e) {
				targetOid = 0;
			}
		}
	}

	return command.isEmpty() ? 0 : devCommand(L, command.toCharArray(), targetOid, toString(L, 5).replaceAll("_", " "));
}

int devInvite(lua_State* L) {
	Reference<CreatureObject*> to = devBot(L, 3);

	return to != nullptr ? devCommand(L, "invite", to->getObjectID(), "") : 0;
}

int devJoin(lua_State* L) {
	return devCommand(L, "join", 0, "");
}

int devDecline(lua_State* L) {
	return devCommand(L, "decline", 0, "");
}

int devLeave(lua_State* L) {
	return devCommand(L, "leavegroup", 0, "");
}

int devGroupSay(lua_State* L) {
	String text = toString(L, 3).replaceAll("_", " ");

	return devCommand(L, "groupchat", 0, text);
}

int devTeleport(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	float x = (float) toNumber(L, 3);
	float y = (float) toNumber(L, 4);

	Locker locker(bot);

	Zone* zone = bot->getZone();

	if (zone == nullptr)
		return 0;

	float z = CollisionManager::getWorldFloorCollision(x, y, zone, false);

	bot->teleport(x, z, y, 0);

	devLog().info(true) << bot->getFirstName() << " teleported to " << x << " " << z << " " << y << " on " << zone->getZoneName();

	return 0;
}

int devCamp(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	String error;

	if (bot != nullptr) {
		uint64 camp = BotGroup::placeCamp(bot, toString(L, 3), error);
		devLog().info(true) << bot->getFirstName() << " camp: " << camp << (error.isEmpty() ? "" : " (" + error + ")") << ", camp skill "
			<< bot->getSkillMod("camp");
	}

	return 0;
}

int devUncamp(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " uncamp: " << (BotGroup::removeCamp(bot) ? "disbanded" : "no camp");

	return 0;
}

int devTrack(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	Vector<Reference<BotTrackEntry*>> found;
	String error;

	if (!BotGroup::track(bot, (int) toNumber(L, 3), found, error)) {
		devLog().info(true) << bot->getFirstName() << " track: " << error;
		return 0;
	}

	StringBuffer text;
	text << bot->getFirstName() << " track: " << found.size() << " found";

	for (int i = 0; i < found.size() && i < 15; ++i) {
		BotTrackEntry* entry = found.get(i);
		text << "; " << entry->name << " (" << entry->kind << " level " << entry->level << ") " << entry->distance << " m " << entry->bearing
			<< " (" << entry->degrees << ")";
	}

	devLog().info(true) << text.toString();

	return 0;
}

int devSkillMod(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	String mod = toString(L, 3);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " " << mod << " = " << bot->getSkillMod(mod);

	return 0;
}

void registerDevTable(lua_State* L) {
	static const luaL_Reg functions[] = {
		{"invite", devInvite}, {"join", devJoin}, {"decline", devDecline}, {"leave", devLeave}, {"gsay", devGroupSay},
		{"teleport", devTeleport}, {"camp", devCamp}, {"uncamp", devUncamp}, {"track", devTrack}, {"skillmod", devSkillMod},
		{"cmd", devAnyCommand},
		{nullptr, nullptr}
	};

	lua_newtable(L);

	for (int i = 0; functions[i].name != nullptr; ++i) {
		lua_pushcfunction(L, functions[i].func);
		lua_setfield(L, -2, functions[i].name);
	}

	lua_setglobal(L, "BotGroupDev");
}

}

void BotGroupLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botGetGroupInviter", botGetGroupInviter);
	lua->registerFunction("botPlaceCamp", botPlaceCamp);
	lua->registerFunction("botRemoveCamp", botRemoveCamp);
	lua->registerFunction("botGetCamp", botGetCamp);
	lua->registerFunction("botTrack", botTrack);

	registerDevTable(lua->getLuaState());
}

// botGetGroupInviter(pBot): oid or 0
int BotGroupLua::botGetGroupInviter(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushinteger(L, bot != nullptr ? BotGroup::getInviter(bot) : 0);

	return 1;
}

// botPlaceCamp(pBot[, kitTemplate]): oid, or 0 and why
int BotGroupLua::botPlaceCamp(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String error = "no bot";
	uint64 camp = 0;

	if (bot != nullptr) {
		error = "";
		camp = BotGroup::placeCamp(bot, toString(L, 2), error);
	}

	lua_pushinteger(L, camp);
	lua_pushstring(L, error.toCharArray());

	return 2;
}

// botRemoveCamp(pBot)
int BotGroupLua::botRemoveCamp(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotGroup::removeCamp(bot));

	return 1;
}

// botGetCamp(pBot): oid or 0
int BotGroupLua::botGetCamp(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushinteger(L, bot != nullptr ? BotGroup::getCamp(bot) : 0);

	return 1;
}

// botTrack(pBot[, type]): array of {name, distance, bearing, degrees, oid, kind, level}, or nil and why
int BotGroupLua::botTrack(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Vector<Reference<BotTrackEntry*>> found;
	String error = "no bot";

	if (bot == nullptr || !BotGroup::track(bot, (int) toNumber(L, 2), found, error)) {
		lua_pushnil(L);
		lua_pushstring(L, error.toCharArray());
		return 2;
	}

	lua_newtable(L);

	for (int i = 0; i < found.size(); ++i) {
		BotTrackEntry* entry = found.get(i);

		lua_newtable(L);

		lua_pushstring(L, entry->name.toCharArray());
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, entry->distance);
		lua_setfield(L, -2, "distance");
		lua_pushstring(L, entry->bearing.toCharArray());
		lua_setfield(L, -2, "bearing");
		lua_pushinteger(L, entry->degrees);
		lua_setfield(L, -2, "degrees");
		lua_pushinteger(L, entry->oid);
		lua_setfield(L, -2, "oid");
		lua_pushstring(L, entry->kind.toCharArray());
		lua_setfield(L, -2, "kind");
		lua_pushinteger(L, entry->level);
		lua_setfield(L, -2, "level");

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}
