/*
 * BotGearLua (Phase 9 Part 3). See BotGearLua.h.
 */

#include "BotGearLua.h"
#include "BotGear.h"
#include "BotManager.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"

using namespace server::zone::managers::bot;

namespace {

SceneObject* toSceneObject(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_islightuserdata(L, index))
		return nullptr;

	return static_cast<SceneObject*>(lua_touserdata(L, index));
}

CreatureObject* toOnlineBot(lua_State* L, int index) {
	SceneObject* object = toSceneObject(L, index);

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

uint64 toOid(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isnumber(L, index))
		return 0;

	return (uint64) lua_tointeger(L, index);
}

void setString(lua_State* L, const char* name, const String& value) {
	lua_pushstring(L, value.toCharArray());
	lua_setfield(L, -2, name);
}

void setInteger(lua_State* L, const char* name, lua_Integer value) {
	lua_pushinteger(L, value);
	lua_setfield(L, -2, name);
}

void setNumber(lua_State* L, const char* name, double value) {
	lua_pushnumber(L, value);
	lua_setfield(L, -2, name);
}

void setBoolean(lua_State* L, const char* name, bool value) {
	lua_pushboolean(L, value);
	lua_setfield(L, -2, name);
}

}

void BotGearLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botGearList", botGearList);
	lua->registerFunction("botGearKind", botGearKind);
	lua->registerFunction("botGearEquip", botGearEquip);
	lua->registerFunction("botGearUnequip", botGearUnequip);
	lua->registerFunction("botGearGiven", botGearGiven);
	lua->registerFunction("botGearPack", botGearPack);
	lua->registerFunction("botGearCamps", botGearCamps);
	lua->registerFunction("botGearGiveBack", botGearGiveBack);
	lua->registerFunction("botGearGiveEnd", botGearGiveEnd);
	lua->registerFunction("botGearGiveMode", botGearGiveMode);
	lua->registerFunction("botGearDevGive", botGearDevGive);
	lua->registerFunction("botGearDevCondition", botGearDevCondition);
}

// botGearList(pBot)
int BotGearLua::botGearList(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_newtable(L);

	if (bot == nullptr)
		return 1;

	Vector<Reference<BotGearItem*>> items;
	BotGear::list(bot, items);

	for (int i = 0; i < items.size(); ++i) {
		BotGearItem* item = items.get(i);

		lua_newtable(L);

		setInteger(L, "oid", (lua_Integer) item->oid);
		setString(L, "template", item->templateName);
		setString(L, "name", item->name);
		setString(L, "kind", item->kind);
		setString(L, "family", item->family);
		setString(L, "slot", item->slot);
		setBoolean(L, "worn", item->worn);
		setBoolean(L, "given", item->given);
		setBoolean(L, "certified", item->certified);
		setInteger(L, "uses", item->uses);
		setInteger(L, "required", item->required);
		setBoolean(L, "usable", item->usable);
		setNumber(L, "power", item->power);
		setInteger(L, "left", item->left);
		setBoolean(L, "broken", item->broken);

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botGearKind(itemOid) -> kind, family, name
int BotGearLua::botGearKind(lua_State* L) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	ManagedReference<SceneObject*> item = zoneServer != nullptr ? zoneServer->getObject(toOid(L, 1)) : nullptr;

	if (item == nullptr) {
		lua_pushnil(L);

		return 1;
	}

	String kind, family;
	BotGear::classify(item, kind, family);

	lua_pushstring(L, kind.toCharArray());
	lua_pushstring(L, family.toCharArray());
	lua_pushstring(L, item->getDisplayedName().toCharArray());

	return 3;
}

// botGearEquip(pBot, itemOid) -> ok, why
int BotGearLua::botGearEquip(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String why = "failed";
	bool ok = bot != nullptr && BotGear::equip(bot, toOid(L, 2), why);

	lua_pushboolean(L, ok);
	lua_pushstring(L, ok ? "" : why.toCharArray());

	return 2;
}

// botGearUnequip(pBot, itemOid)
int BotGearLua::botGearUnequip(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotGear::unequip(bot, toOid(L, 2)));

	return 1;
}

// botGearGiven(pBot, {oids})
int BotGearLua::botGearGiven(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	if (bot == nullptr || lua_gettop(L) < 2 || !lua_istable(L, 2)) {
		lua_pushboolean(L, false);

		return 1;
	}

	Vector<uint64> oids;
	int count = (int) lua_rawlen(L, 2);

	for (int i = 1; i <= count; ++i) {
		lua_rawgeti(L, 2, i);

		if (lua_isnumber(L, -1))
			oids.add((uint64) lua_tointeger(L, -1));

		lua_pop(L, 1);
	}

	BotGear::markGiven(bot, oids);
	lua_pushboolean(L, true);

	return 1;
}

// botGearPack(pBot, kind) -> oid, uses
int BotGearLua::botGearPack(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	int uses = 0;
	uint64 oid = bot != nullptr ? BotGear::findPack(bot, toString(L, 2), uses) : 0;

	lua_pushinteger(L, (lua_Integer) oid);
	lua_pushinteger(L, uses);

	return 2;
}

// botGearCamps(pBot)
int BotGearLua::botGearCamps(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_newtable(L);

	if (bot == nullptr)
		return 1;

	Vector<String> kits;
	BotGear::campKits(bot, kits);

	for (int i = 0; i < kits.size(); ++i) {
		lua_pushstring(L, kits.get(i).toCharArray());
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botGearGiveBack(pBot, filter) -> how many are to go
int BotGearLua::botGearGiveBack(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushinteger(L, bot != nullptr ? BotGear::prepareGiveBack(bot, toString(L, 2)) : 0);

	return 1;
}

// botGearGiveEnd(pBot)
int BotGearLua::botGearGiveEnd(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	if (bot != nullptr)
		BotGear::endGiveBack(bot);

	return 0;
}

// botGearDevGive(pBot, template[, uses]) -> oid
int BotGearLua::botGearDevGive(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushinteger(L, bot != nullptr ? (lua_Integer) BotGear::devGive(bot, toString(L, 2), (int) toOid(L, 3)) : 0);

	return 1;
}

// botGearDevCondition(pBot, itemOid, percent)
int BotGearLua::botGearDevCondition(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotGear::devCondition(bot, toOid(L, 2), (int) toOid(L, 3)));

	return 1;
}

// botGearGiveMode(pBot) -> the filter, "" if none
int BotGearLua::botGearGiveMode(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushstring(L, bot != nullptr ? BotGear::giveMode(bot).toCharArray() : "");

	return 1;
}
