/*
 * BotLootLua (Phase 7 bot players). See BotLootLua.h.
 */

#include "BotLootLua.h"
#include "BotLoot.h"
#include "BotManager.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"

using namespace server::zone::managers::bot;

namespace {

Logger& devLog() {
	static Logger logger("BotLootDev");

	return logger;
}

CreatureObject* toCreature(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_islightuserdata(L, index))
		return nullptr;

	SceneObject* object = static_cast<SceneObject*>(lua_touserdata(L, index));

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

String toString(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isstring(L, index))
		return "";

	return lua_tostring(L, index);
}

// A number, or a number in a string (console arguments are strings)
uint64 toOid(lua_State* L, int index) {
	if (lua_gettop(L) < index)
		return 0;

	if (lua_type(L, index) == LUA_TNUMBER)
		return lua_tointeger(L, index);

	if (lua_type(L, index) == LUA_TSTRING) {
		String text = lua_tostring(L, index);

		if (text.isEmpty())
			return 0;

		try {
			return UnsignedLong::valueOf(text);
		} catch (const Exception& e) {
			return 0;
		}
	}

	return 0;
}

void setString(lua_State* L, const char* field, const String& value) {
	lua_pushstring(L, value.toCharArray());
	lua_setfield(L, -2, field);
}

void setInteger(lua_State* L, const char* field, int64 value) {
	lua_pushinteger(L, value);
	lua_setfield(L, -2, field);
}

void setBoolean(lua_State* L, const char* field, bool value) {
	lua_pushboolean(L, value);
	lua_setfield(L, -2, field);
}

// --- Development table, BotLootDev ---

Reference<CreatureObject*> devBot(lua_State* L, int index) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(toString(L, index));

	if (bot == nullptr)
		devLog().info(true) << "no online bot called " << toString(L, index);

	return bot;
}

int devLoot(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	BotLootResult result;

	if (bot != nullptr) {
		BotLoot::lootCorpse(bot, toOid(L, 3), result);
		devLog().info(true) << bot->getFirstName() << " loot: ok " << (result.ok ? "yes" : "no") << ", moved " << result.moved << ", left "
			<< result.left << ", credits " << result.credits << ", full " << (result.full ? "yes" : "no") << ", error '" << result.error << "'";
	}

	return 0;
}

int devHarvest(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	BotHarvestResult result;

	if (bot != nullptr) {
		BotLoot::harvest(bot, toOid(L, 3), toString(L, 4), result);
		devLog().info(true) << bot->getFirstName() << " harvest: ok " << (result.ok ? "yes" : "no") << ", " << result.amount << " units of "
			<< result.kind << " (" << result.resource << "), error '" << result.error << "'";
	}

	return 0;
}

int devGoods(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	Vector<Reference<BotGoodsItem*>> goods;
	BotLoot::goods(bot, goods);

	StringBuffer text;
	text << bot->getFirstName() << " holds " << goods.size() << " goods:";

	for (int i = 0; i < goods.size(); ++i) {
		BotGoodsItem* item = goods.get(i);
		text << " " << item->oid << " " << item->name;

		if (item->resource)
			text << " x" << item->quantity;

		if (!item->tradable)
			text << " (no trade)";

		text << ";";
	}

	devLog().info(true) << text.toString();

	return 0;
}

int devOffer(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	Reference<CreatureObject*> player = BotManager::instance()->getOnlineBot(toString(L, 3));
	String error;
	int offered = 0, remaining = 0;

	if (player == nullptr) {
		ZoneServer* zoneServer = bot != nullptr ? bot->getZoneServer() : nullptr;
		ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(toOid(L, 3)) : nullptr;

		if (object != nullptr && object->isCreatureObject())
			player = object->asCreatureObject();
	}

	if (bot != nullptr) {
		bool ok = BotLoot::offerGoods(bot, player, offered, remaining, error);
		devLog().info(true) << bot->getFirstName() << " offer: " << (ok ? String("opened") : error) << ", offered " << offered << ", remaining " << remaining;
	}

	return 0;
}

int devCancel(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		BotLoot::cancelOffer(bot);

	return 0;
}

int devMark(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " mark " << toOid(L, 3) << ": " << (BotLoot::markGood(bot, toOid(L, 3)) ? "goods" : "not in the pack");

	return 0;
}

void registerDevTable(lua_State* L) {
	static const luaL_Reg functions[] = {
		{"loot", devLoot}, {"harvest", devHarvest}, {"goods", devGoods}, {"offer", devOffer}, {"cancel", devCancel}, {"mark", devMark},
		{nullptr, nullptr}
	};

	lua_newtable(L);

	for (int i = 0; functions[i].name != nullptr; ++i) {
		lua_pushcfunction(L, functions[i].func);
		lua_setfield(L, -2, functions[i].name);
	}

	lua_setglobal(L, "BotLootDev");
}

}

void BotLootLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botLootCorpse", botLootCorpse);
	lua->registerFunction("botHarvest", botHarvest);
	lua->registerFunction("botGoods", botGoods);
	lua->registerFunction("botOfferGoods", botOfferGoods);
	lua->registerFunction("botCancelOffer", botCancelOffer);

	registerDevTable(lua->getLuaState());
}

// botLootCorpse(pBot, corpseOid): {ok, moved, left, credits, full, error}
int BotLootLua::botLootCorpse(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	BotLootResult result;

	if (bot == nullptr)
		result.error = "no bot";
	else
		BotLoot::lootCorpse(bot, toOid(L, 2), result);

	lua_newtable(L);
	setBoolean(L, "ok", result.ok);
	setInteger(L, "moved", result.moved);
	setInteger(L, "left", result.left);
	setInteger(L, "credits", result.credits);
	setBoolean(L, "full", result.full);
	setString(L, "error", result.error);

	return 1;
}

// botHarvest(pBot, corpseOid[, kind]): {ok, kind, amount, resource, error}
int BotLootLua::botHarvest(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	BotHarvestResult result;

	if (bot == nullptr)
		result.error = "no bot";
	else
		BotLoot::harvest(bot, toOid(L, 2), toString(L, 3), result);

	lua_newtable(L);
	setBoolean(L, "ok", result.ok);
	setString(L, "kind", result.kind);
	setInteger(L, "amount", result.amount);
	setString(L, "resource", result.resource);
	setString(L, "error", result.error);

	return 1;
}

// botGoods(pBot): array of {oid, name, quantity, resource, tradable}
int BotLootLua::botGoods(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Vector<Reference<BotGoodsItem*>> goods;

	if (bot != nullptr)
		BotLoot::goods(bot, goods);

	lua_newtable(L);

	for (int i = 0; i < goods.size(); ++i) {
		BotGoodsItem* item = goods.get(i);

		lua_newtable(L);
		setInteger(L, "oid", item->oid);
		setString(L, "name", item->name);
		setInteger(L, "quantity", item->quantity);
		setBoolean(L, "resource", item->resource);
		setBoolean(L, "tradable", item->tradable);
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botOfferGoods(pBot, playerOid): true, offered, remaining; or false and why
int BotLootLua::botOfferGoods(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String error = "no bot";
	int offered = 0, remaining = 0;
	bool ok = false;

	if (bot != nullptr) {
		error = "no player";

		ZoneServer* zoneServer = bot->getZoneServer();
		ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(toOid(L, 2)) : nullptr;

		if (object != nullptr && object->isPlayerCreature())
			ok = BotLoot::offerGoods(bot, object->asCreatureObject(), offered, remaining, error);
	}

	lua_pushboolean(L, ok);

	if (ok) {
		lua_pushinteger(L, offered);
		lua_pushinteger(L, remaining);
	} else {
		lua_pushstring(L, error.toCharArray());
		lua_pushinteger(L, 0);
	}

	return 3;
}

// botCancelOffer(pBot)
int BotLootLua::botCancelOffer(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	if (bot != nullptr)
		BotLoot::cancelOffer(bot);

	return 0;
}
