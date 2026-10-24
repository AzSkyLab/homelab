/*
 * BotVehicleLua (bot players, Phase 7). See BotVehicleLua.h.
 */

#include "BotVehicleLua.h"
#include "BotVehicle.h"
#include "BotManager.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"

namespace {

// Lua passes Core3 objects as light userdata; anything else (nil, a number) is no object
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

}

void BotVehicleLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botMount", botMount);
	lua->registerFunction("botDismount", botDismount);
	lua->registerFunction("botMounted", botMounted);
	lua->registerFunction("botVehicleOut", botVehicleOut);
	lua->registerFunction("botMountAttacker", botMountAttacker);
	lua->registerFunction("botHasSwoop", botHasSwoop);
}

int BotVehicleLua::botMount(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotVehicle::mount(bot));

	return 1;
}

int BotVehicleLua::botDismount(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	bool force = lua_gettop(L) >= 2 && lua_toboolean(L, 2);

	lua_pushboolean(L, bot != nullptr && BotVehicle::dismount(bot, force));

	return 1;
}

// Any creature (a human leader too): the mirror rule reads the leader with this
int BotVehicleLua::botMounted(lua_State* L) {
	lua_pushboolean(L, BotVehicle::isMounted(toCreature(L, 1)));

	return 1;
}

int BotVehicleLua::botVehicleOut(lua_State* L) {
	lua_pushboolean(L, BotVehicle::isOut(toOnlineBot(L, 1)));

	return 1;
}

int BotVehicleLua::botMountAttacker(lua_State* L) {
	lua_pushinteger(L, (lua_Integer)BotVehicle::mountAttacker(toCreature(L, 1)));

	return 1;
}

int BotVehicleLua::botHasSwoop(lua_State* L) {
	lua_pushboolean(L, BotVehicle::hasSwoop(toOnlineBot(L, 1)));

	return 1;
}
