/*
 * BotTradeLua (bot players). See BotTradeLua.h.
 */

#include "BotTradeLua.h"
#include "BotTrade.h"
#include "BotSlice.h"
#include "BotManager.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"

using namespace server::zone::managers::bot;

namespace {

Logger& devLog() {
	static Logger logger("BotTradeDev");

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
int64 toInteger(lua_State* L, int index, int64 fallback = 0) {
	if (lua_gettop(L) < index)
		return fallback;

	if (lua_type(L, index) == LUA_TNUMBER)
		return lua_tointeger(L, index);

	if (lua_type(L, index) == LUA_TSTRING) {
		String text = lua_tostring(L, index);

		if (text.isEmpty())
			return fallback;

		try {
			return Long::valueOf(text);
		} catch (const Exception& e) {
			return fallback;
		}
	}

	return fallback;
}

void pushOidArray(lua_State* L, const Vector<uint64>& oids) {
	lua_newtable(L);

	for (int i = 0; i < oids.size(); ++i) {
		lua_pushinteger(L, oids.get(i));
		lua_rawseti(L, -2, i + 1);
	}
}

void pushTradeInfo(lua_State* L, const BotTradeInfo& info) {
	lua_newtable(L);

	lua_pushinteger(L, info.partner);
	lua_setfield(L, -2, "partner");
	lua_pushstring(L, info.stage.toCharArray());
	lua_setfield(L, -2, "stage");
	pushOidArray(L, info.items);
	lua_setfield(L, -2, "items");
	lua_pushinteger(L, info.credits);
	lua_setfield(L, -2, "credits");
	lua_pushboolean(L, info.partnerAccepted);
	lua_setfield(L, -2, "partnerAccepted");
	lua_pushboolean(L, info.accepted);
	lua_setfield(L, -2, "accepted");
	lua_pushinteger(L, info.give);
	lua_setfield(L, -2, "give");
}

void pushSliceResult(lua_State* L, const BotSliceResult& result) {
	lua_newtable(L);

	lua_pushboolean(L, result.ok);
	lua_setfield(L, -2, "ok");
	lua_pushstring(L, result.kind.toCharArray());
	lua_setfield(L, -2, "kind");
	lua_pushstring(L, result.stat.toCharArray());
	lua_setfield(L, -2, "stat");
	lua_pushinteger(L, result.percent);
	lua_setfield(L, -2, "percent");
	lua_pushstring(L, result.error.toCharArray());
	lua_setfield(L, -2, "error");
	lua_pushboolean(L, result.returned);
	lua_setfield(L, -2, "returned");
}

String describe(const BotTradeInfo& info) {
	StringBuffer text;
	text << "stage " << info.stage << ", partner " << info.partner << ", items [";

	for (int i = 0; i < info.items.size(); ++i)
		text << (i > 0 ? " " : "") << info.items.get(i);

	text << "], credits " << info.credits << ", partnerAccepted " << (info.partnerAccepted ? "yes" : "no") << ", accepted "
		<< (info.accepted ? "yes" : "no") << ", give " << info.give;

	return text.toString();
}

// --- Development table, BotTradeDev (console: runLuaFunction BotTradeDev:<fn>:<args>; argument 1 is the table) ---

Reference<CreatureObject*> devBot(lua_State* L, int index) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(toString(L, index));

	if (bot == nullptr)
		devLog().info(true) << "no online bot called " << toString(L, index);

	return bot;
}

int devRequest(lua_State* L) {
	Reference<CreatureObject*> from = devBot(L, 2);
	Reference<CreatureObject*> to = devBot(L, 3);

	if (from != nullptr && to != nullptr)
		BotTrade::devRequest(from, to);

	return 0;
}

int devOffer(lua_State* L) {
	Reference<CreatureObject*> from = devBot(L, 2);

	if (from != nullptr && !BotTrade::devOffer(from, toInteger(L, 3), (int) toInteger(L, 4, -1)))
		devLog().info(true) << from->getFirstName() << " has no open trade";

	return 0;
}

int devAccept(lua_State* L) {
	Reference<CreatureObject*> from = devBot(L, 2);

	if (from != nullptr)
		BotTrade::devAccept(from);

	return 0;
}

int devVerify(lua_State* L) {
	Reference<CreatureObject*> from = devBot(L, 2);

	if (from != nullptr)
		BotTrade::devVerify(from);

	return 0;
}

int devAbort(lua_State* L) {
	Reference<CreatureObject*> from = devBot(L, 2);

	if (from != nullptr)
		BotTrade::devAbort(from);

	return 0;
}

int devItem(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	String templateName = toString(L, 3);

	if (bot == nullptr || templateName.isEmpty())
		return 0;

	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (zoneServer == nullptr || inventory == nullptr)
		return 0;

	Locker locker(bot);

	ManagedReference<SceneObject*> item = zoneServer->createObject(templateName.hashCode(), 1);

	if (item == nullptr) {
		devLog().info(true) << "could not create " << templateName;
		return 0;
	}

	Locker ilocker(item, bot);

	if (!inventory->transferObject(item, -1, true)) {
		item->destroyObjectFromDatabase(true);
		devLog().info(true) << "no room in " << bot->getFirstName() << "'s inventory";
		return 0;
	}

	devLog().info(true) << bot->getFirstName() << " has " << item->getDisplayedName() << ", oid " << item->getObjectID();

	return 0;
}

int devInventory(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	Locker locker(bot);

	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (inventory == nullptr)
		return 0;

	StringBuffer text;
	text << bot->getFirstName() << "'s inventory (" << inventory->getContainerObjectsSize() << "/" << inventory->getContainerVolumeLimit()
		<< "), cash " << bot->getCashCredits() << ":";

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object == nullptr)
			continue;

		text << " " << object->getObjectID() << " " << object->getObjectTemplate()->getTemplateFileName();

		if (object->isTangibleObject()) {
			TangibleObject* tano = object->asTangibleObject();
			text << " (uses " << tano->getUseCount() << (tano->isSliced() ? ", sliced" : "") << ")";
		}

		text << ";";
	}

	devLog().info(true) << text.toString();

	return 0;
}

int devState(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	BotTradeInfo info;

	if (bot != nullptr && BotTrade::getState(bot, info))
		devLog().info(true) << bot->getFirstName() << "'s trade: " << describe(info);

	return 0;
}

int devBotAccept(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	String error;

	if (bot != nullptr) {
		bool ok = BotTrade::accept(bot, error);
		devLog().info(true) << bot->getFirstName() << " accept: " << (ok ? String("opened") : error);
	}

	return 0;
}

int devBotVerify(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	String why;

	if (bot != nullptr) {
		BotTrade::verify(bot, (int) toInteger(L, 3, -1), toInteger(L, 4), why);
		devLog().info(true) << bot->getFirstName() << " verify: " << why;
	}

	return 0;
}

int devBotAbort(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " abort: " << (BotTrade::abort(bot) ? "cancelled" : "nothing to cancel");

	return 0;
}

int devSlice(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	Reference<CreatureObject*> owner;
	BotSliceResult result;

	if (lua_gettop(L) >= 4)
		owner = devBot(L, 4);

	if (bot != nullptr) {
		BotSlice::slice(bot, toInteger(L, 3), owner, result);
		devLog().info(true) << "slice: ok " << (result.ok ? "yes" : "no") << ", kind " << result.kind << ", stat " << result.stat
			<< ", percent " << result.percent << ", error '" << result.error << "', returned " << (result.returned ? "yes" : "no");
	}

	return 0;
}

int devStock(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " stock: " << (BotSlice::stockTools(bot, (int) toInteger(L, 3, 3)) ? "ok" : "failed");

	return 0;
}

int devInfo(lua_State* L) {
	BotItemInfo info;
	uint64 oid = toInteger(L, 2);

	if (BotSlice::getItemInfo(oid, info)) {
		devLog().info(true) << "item " << oid << ": " << info.name << ", kind " << info.kind << ", sliced " << (info.sliced ? "yes" : "no")
			<< ", sliceable " << (info.sliceable ? "yes" : "no") << ", powerup " << (info.powerup ? "yes" : "no") << ", in " << info.parent;
	} else {
		devLog().info(true) << "no item " << oid;
	}

	return 0;
}

void registerDevTable(lua_State* L) {
	static const luaL_Reg functions[] = {
		{"request", devRequest}, {"offer", devOffer}, {"accept", devAccept}, {"verify", devVerify}, {"abort", devAbort},
		{"item", devItem}, {"inventory", devInventory}, {"state", devState}, {"botAccept", devBotAccept},
		{"botVerify", devBotVerify}, {"botAbort", devBotAbort}, {"slice", devSlice}, {"stock", devStock}, {"info", devInfo},
		{nullptr, nullptr}
	};

	lua_newtable(L);

	for (int i = 0; functions[i].name != nullptr; ++i) {
		lua_pushcfunction(L, functions[i].func);
		lua_setfield(L, -2, functions[i].name);
	}

	lua_setglobal(L, "BotTradeDev");
}

}

void BotTradeLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botTradeState", botTradeState);
	lua->registerFunction("botTradeAccept", botTradeAccept);
	lua->registerFunction("botTradeVerify", botTradeVerify);
	lua->registerFunction("botTradeAbort", botTradeAbort);
	lua->registerFunction("botTradeGive", botTradeGive);
	lua->registerFunction("botItemInfo", botItemInfo);
	lua->registerFunction("botSlice", botSlice);
	lua->registerFunction("botStockSlicingTools", botStockSlicingTools);

	registerDevTable(lua->getLuaState());

	// Trades and group invites are noticed by polling (no upstream hook)
	BotTrade::startWatch();
}

// botTradeState(pBot): {partner, stage, items, credits, partnerAccepted, accepted, give}
int BotTradeLua::botTradeState(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	BotTradeInfo info;

	if (bot != nullptr)
		BotTrade::getState(bot, info);

	pushTradeInfo(L, info);

	return 1;
}

// botTradeAccept(pBot): true, or false and why
int BotTradeLua::botTradeAccept(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String error = "no bot";
	bool ok = bot != nullptr && BotTrade::accept(bot, error);

	lua_pushboolean(L, ok);
	lua_pushstring(L, ok ? "" : error.toCharArray());

	return 2;
}

// botTradeVerify(pBot[, minCredits[, itemOid]]): true when done, else false and why
int BotTradeLua::botTradeVerify(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String why = "none";
	int result = BotTrade::REFUSED;

	if (bot != nullptr) {
		int minCredits = lua_gettop(L) >= 2 && lua_isnumber(L, 2) ? (int) lua_tointeger(L, 2) : -1;
		uint64 itemOid = lua_gettop(L) >= 3 && lua_isnumber(L, 3) ? lua_tointeger(L, 3) : 0;

		result = BotTrade::verify(bot, minCredits, itemOid, why);
	}

	lua_pushboolean(L, result == BotTrade::DONE);
	lua_pushstring(L, why.toCharArray());

	return 2;
}

// botTradeAbort(pBot)
int BotTradeLua::botTradeAbort(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotTrade::abort(bot));

	return 1;
}

// botTradeGive(pBot, pOwner, itemOid): a give-back trade
int BotTradeLua::botTradeGive(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* owner = toCreature(L, 2);
	uint64 itemOid = toInteger(L, 3);
	bool ok = false;

	if (bot != nullptr && owner != nullptr && owner != bot && itemOid != 0) {
		Locker locker(bot);

		SceneObject* inventory = bot->getSlottedObject("inventory");

		ok = inventory != nullptr && inventory->hasObjectInContainer(itemOid) && BotTrade::give(bot, owner, itemOid);
	}

	lua_pushboolean(L, ok);

	return 1;
}

// botItemInfo(itemOid): {kind, sliced, sliceable, powerup, name, parent} or nil
int BotTradeLua::botItemInfo(lua_State* L) {
	BotItemInfo info;

	if (!BotSlice::getItemInfo(toInteger(L, 1), info)) {
		lua_pushnil(L);
		return 1;
	}

	lua_newtable(L);

	lua_pushstring(L, info.kind.toCharArray());
	lua_setfield(L, -2, "kind");
	lua_pushboolean(L, info.sliced);
	lua_setfield(L, -2, "sliced");
	lua_pushboolean(L, info.sliceable);
	lua_setfield(L, -2, "sliceable");
	lua_pushboolean(L, info.powerup);
	lua_setfield(L, -2, "powerup");
	lua_pushstring(L, info.name.toCharArray());
	lua_setfield(L, -2, "name");
	lua_pushinteger(L, info.parent);
	lua_setfield(L, -2, "parent");

	return 1;
}

// botSlice(pBot, itemOid, pOwner[, want]): {ok, kind, stat, percent, error, returned}; want: the type the customer
// named ("effectiveness", "encumbrance", "damage", "speed")
int BotTradeLua::botSlice(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* owner = toCreature(L, 3);
	BotSliceResult result;

	if (bot == nullptr)
		result.error = "no bot";
	else
		BotSlice::slice(bot, toInteger(L, 2), owner != bot ? owner : nullptr, result,
			lua_gettop(L) >= 4 && lua_isstring(L, 4) ? String(lua_tostring(L, 4)) : String(""));

	pushSliceResult(L, result);

	return 1;
}

// botStockSlicingTools(pBot, count)
int BotTradeLua::botStockSlicingTools(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotSlice::stockTools(bot, (int) toInteger(L, 2, 5)));

	return 1;
}
