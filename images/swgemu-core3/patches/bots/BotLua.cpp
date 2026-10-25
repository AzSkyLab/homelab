/*
 * BotLua (Phase 3 bot players). See BotLua.h.
 */

#include "BotLua.h"
#include "BotMoverLua.h"
#include "BotCombatLua.h"
#include "BotTradeLua.h"
#include "BotCityLua.h"
#include "BotGroupLua.h"
#include "BotMissionLua.h"
#include "BotVehicleLua.h"
#include "BotLootLua.h"
#include "BotManager.h"
#include "BotChat.h"
#include "BotItems.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/managers/director/DirectorManager.h"

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

// An online bot, or nullptr
CreatureObject* toOnlineBot(lua_State* L, int index) {
	CreatureObject* creature = toCreature(L, index);

	if (creature == nullptr || !BotManager::instance()->isOnlineBot(creature))
		return nullptr;

	return creature;
}

String toString(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isstring(L, index))
		return "";

	return lua_tostring(L, index);
}

int64 toInteger(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isnumber(L, index))
		return 0;

	return lua_tointeger(L, index);
}

double toNumber(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isnumber(L, index))
		return 0;

	return lua_tonumber(L, index);
}

bool hasJobsFunction(lua_State* L, const char* fn) {
	lua_getglobal(L, "BotJobs");

	bool found = false;

	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, fn);
		found = lua_isfunction(L, -1);
		lua_pop(L, 1);
	}

	lua_pop(L, 1);

	return found;
}

}

void BotLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botList", botList);
	lua->registerFunction("botGetCreature", botGetCreature);
	lua->registerFunction("isBot", isBot);
	lua->registerFunction("botLogin", botLogin);
	lua->registerFunction("botLogout", botLogout);
	lua->registerFunction("botSetDevHuman", botSetDevHuman);
	lua->registerFunction("botEnqueue", botEnqueue);
	lua->registerFunction("botSay", botSay);
	lua->registerFunction("botTell", botTell);
	lua->registerFunction("botEmote", botEmote);
	lua->registerFunction("botFace", botFace);
	lua->registerFunction("botStockPack", botStockPack);
	lua->registerFunction("botStockItem", botStockItem);
	lua->registerFunction("botFindItem", botFindItem);
	lua->registerFunction("botGetWounds", botGetWounds);
	lua->registerFunction("botGetShockWounds", botGetShockWounds);
	lua->registerFunction("botGetBuffs", botGetBuffs);

	// Phases 4-6: each part registers its own
	BotMoverLua::registerFunctions(lua);
	BotCombatLua::registerFunctions(lua);
	BotTradeLua::registerFunctions(lua);
	BotCityLua::registerFunctions(lua);
	BotGroupLua::registerFunctions(lua);
	BotMissionLua::registerFunctions(lua);
	BotVehicleLua::registerFunctions(lua);
	BotLootLua::registerFunctions(lua);
}

// --- Events ---

void BotLua::callEvent(CreatureObject* bot, const String& name, SceneObject* other, const String& detail) {
	Lua* lua = DirectorManager::instance()->getLuaInstance();
	lua_State* L = lua->getLuaState();
	int top = lua_gettop(L);

	if (hasJobsFunction(L, "onEvent")) {
		try {
			LuaFunction call(L, "BotJobs", "onEvent", 0);
			call << bot;
			call << name.toCharArray();

			call << (void*)other;	// nil in Lua when null

			call << detail.toCharArray();
			call.callFunction();
		} catch (const Exception& e) {
			BotManager::instance()->error() << "BotManager: exception in BotJobs:onEvent(" << name << "): " << e.getMessage();
		}
	}

	lua_settop(L, top);
}

void BotLua::callJobsEvent(const char* fn, CreatureObject* bot) {
	Lua* lua = DirectorManager::instance()->getLuaInstance();
	lua_State* L = lua->getLuaState();
	int top = lua_gettop(L);

	if (hasJobsFunction(L, fn)) {
		try {
			LuaFunction call(L, "BotJobs", fn, 0);
			call << bot;
			call.callFunction();
		} catch (const Exception& e) {
			BotManager::instance()->error() << "BotManager: exception in BotJobs:" << fn << ": " << e.getMessage();
		}
	}

	lua_settop(L, top);
}

void BotLua::callJobsHeard(CreatureObject* bot, CreatureObject* speaker, const String& text, const String& channel) {
	Lua* lua = DirectorManager::instance()->getLuaInstance();
	lua_State* L = lua->getLuaState();
	int top = lua_gettop(L);

	if (hasJobsFunction(L, "onHeard")) {
		try {
			LuaFunction call(L, "BotJobs", "onHeard", 0);
			call << bot;
			call << speaker;
			call << text;
			call << channel;
			call.callFunction();
		} catch (const Exception& e) {
			BotManager::instance()->error() << "BotManager: exception in BotJobs:onHeard: " << e.getMessage();
		}
	}

	lua_settop(L, top);
}

// --- The bots ---

// botList(): array of {name, firstName, job, city, oid, online, state, forced}
int BotLua::botList(lua_State* L) {
	Vector<Reference<BotListEntry*>> list;
	BotManager::instance()->getBotList(list);

	lua_newtable(L);

	for (int i = 0; i < list.size(); ++i) {
		BotListEntry* item = list.get(i);

		lua_newtable(L);

		lua_pushstring(L, item->name.toCharArray());
		lua_setfield(L, -2, "name");
		lua_pushstring(L, item->firstName.toCharArray());
		lua_setfield(L, -2, "firstName");
		lua_pushstring(L, item->job.toCharArray());
		lua_setfield(L, -2, "job");
		lua_pushstring(L, item->city.toCharArray());
		lua_setfield(L, -2, "city");
		lua_pushinteger(L, item->oid);
		lua_setfield(L, -2, "oid");
		lua_pushboolean(L, item->online);
		lua_setfield(L, -2, "online");
		lua_pushstring(L, item->state.toCharArray());
		lua_setfield(L, -2, "state");
		lua_pushboolean(L, item->forced);
		lua_setfield(L, -2, "forced");

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botGetCreature(firstName): an online bot, or nil
int BotLua::botGetCreature(lua_State* L) {
	Reference<CreatureObject*> creature = BotManager::instance()->getOnlineBot(toString(L, 1));

	if (creature == nullptr) {
		lua_pushnil(L);
	} else {
		creature->_setUpdated(true);	// as DirectorManager does, so it isn't collected while Lua holds it
		lua_pushlightuserdata(L, creature.get());
	}

	return 1;
}

// isBot(pCreature)
int BotLua::isBot(lua_State* L) {
	lua_pushboolean(L, BotManager::instance()->isBot(toCreature(L, 1)));

	return 1;
}

// botLogin(firstName) / botLogout(firstName): force a state until the online rule next changes
int BotLua::botLogin(lua_State* L) {
	lua_pushboolean(L, BotManager::instance()->forceState(toString(L, 1), true));

	return 1;
}

int BotLua::botLogout(lua_State* L) {
	lua_pushboolean(L, BotManager::instance()->forceState(toString(L, 1), false));

	return 1;
}

// botSetDevHuman(on): pretend a human is online
int BotLua::botSetDevHuman(lua_State* L) {
	bool on = lua_gettop(L) >= 1 && lua_toboolean(L, 1);

	BotManager::instance()->setDevHuman(on);

	return 0;
}

// --- Actions ---

// botEnqueue(pBot, command, targetOid, args)
int BotLua::botEnqueue(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool ok = bot != nullptr && BotChat::enqueue(bot, toString(L, 2), toInteger(L, 3), toString(L, 4));

	lua_pushboolean(L, ok);

	return 1;
}

// botSay(pBot, text, mood): true if queued (the interface needs no result; it's there for checks)
int BotLua::botSay(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool ok = bot != nullptr && BotChat::say(bot, toString(L, 2), toString(L, 3));

	lua_pushboolean(L, ok);

	return 1;
}

// botTell(pBot, toFirstName, text)
int BotLua::botTell(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool ok = bot != nullptr && BotChat::tell(bot, toString(L, 2), toString(L, 3));

	lua_pushboolean(L, ok);

	return 1;
}

// botEmote(pBot, emote, targetOid): true if the emote exists and was queued
int BotLua::botEmote(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool ok = bot != nullptr && BotChat::emote(bot, toString(L, 2), toInteger(L, 3));

	lua_pushboolean(L, ok);

	return 1;
}

// botFace(pBot, pTarget): true if queued
int BotLua::botFace(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	SceneObject* target = toSceneObject(L, 2);
	bool ok = bot != nullptr && target != nullptr && BotChat::face(bot, target);

	lua_pushboolean(L, ok);

	return 1;
}

// --- The doctor's checks and stock (BotItems, the factory's code) ---

// botStockPack(pBot, template, uses, power, duration[, potency, range, area]) (potency, range and area: poison and disease packs)
int BotLua::botStockPack(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool ok = false;

	if (bot != nullptr) {
		Locker locker(bot);	// BotItems wants it locked; no-op if the caller's event already holds it

		ok = BotItems::stockPack(bot, toString(L, 2), (int)toInteger(L, 3), (float)toNumber(L, 4), (int)toInteger(L, 5), (float)toNumber(L, 6), (float)toNumber(L, 7), (float)toNumber(L, 8));
	}

	lua_pushboolean(L, ok);

	return 1;
}

// botStockItem(pBot, template, uses) -> oid or 0: a grenade (object/weapon/ranged/grenade/*) with at least `uses` uses
int BotLua::botStockItem(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	uint64 oid = 0;

	if (bot != nullptr) {
		Locker locker(bot);

		oid = BotItems::stockItem(bot, toString(L, 2), (int)toInteger(L, 3));
	}

	lua_pushinteger(L, (lua_Integer) oid);

	return 1;
}

// botFindItem(pBot, template) -> oid or 0
int BotLua::botFindItem(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	uint64 oid = 0;

	if (bot != nullptr) {
		Locker locker(bot);

		oid = BotItems::findItem(bot, toString(L, 2));
	}

	lua_pushinteger(L, (lua_Integer) oid);

	return 1;
}

// botGetWounds(pCreature, pool)
int BotLua::botGetWounds(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);
	int pool = (int)toInteger(L, 2);

	lua_pushinteger(L, creature != nullptr && pool >= 0 && pool <= 8 ? BotItems::getWounds(creature, pool) : 0);

	return 1;
}

// botGetShockWounds(pCreature)
int BotLua::botGetShockWounds(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);

	lua_pushinteger(L, creature != nullptr ? BotItems::getShockWounds(creature) : 0);

	return 1;
}

// botGetBuffs(pCreature): array of {name, crc, secondsLeft, value}
int BotLua::botGetBuffs(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);
	Vector<BotBuffInfo> buffs;

	if (creature != nullptr)
		BotItems::listBuffs(creature, buffs);

	lua_newtable(L);

	for (int i = 0; i < buffs.size(); ++i) {
		const BotBuffInfo& buff = buffs.get(i);

		lua_newtable(L);

		lua_pushstring(L, buff.name.toCharArray());
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, buff.crc);
		lua_setfield(L, -2, "crc");
		lua_pushinteger(L, buff.secondsLeft);
		lua_setfield(L, -2, "secondsLeft");
		lua_pushinteger(L, buff.value);
		lua_setfield(L, -2, "value");

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}
