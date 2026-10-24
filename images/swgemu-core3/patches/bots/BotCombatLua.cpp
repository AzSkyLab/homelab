/*
 * BotCombatLua (Phase 5 bot group mates). See BotCombatLua.h.
 */

#include "BotCombatLua.h"
#include "BotCombat.h"
#include "BotItems.h"
#include "BotManager.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"

using namespace server::zone::managers::bot;

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

}

void BotCombatLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botSetTarget", botSetTarget);
	lua->registerFunction("botDuelState", botDuelState);
	lua->registerFunction("botStartFight", botStartFight);
	lua->registerFunction("botEndFight", botEndFight);
	lua->registerFunction("botClone", botClone);
	lua->registerFunction("botEquip", botEquip);
	lua->registerFunction("botRepairGear", botRepairGear);
	lua->registerFunction("botFindPack", botFindPack);
	lua->registerFunction("botRecentIncaps", botRecentIncaps);

	BotCombat::start();
}

// botSetTarget(pBot, oid[, engage])
int BotCombatLua::botSetTarget(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	bool engage = lua_gettop(L) < 3 || lua_isnil(L, 3) || lua_toboolean(L, 3);

	lua_pushboolean(L, bot != nullptr && BotCombat::setTarget(bot, toOid(L, 2), engage));

	return 1;
}

// botDuelState(pBot, pOther)
int BotCombatLua::botDuelState(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* other = toCreature(L, 2);
	String state = bot != nullptr ? BotCombat::duelState(bot, other) : "none";

	lua_pushstring(L, state.toCharArray());

	return 1;
}

// botStartFight(pBot, pHuman)
int BotCombatLua::botStartFight(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* human = toCreature(L, 2);

	lua_pushboolean(L, bot != nullptr && human != nullptr && BotCombat::startFight(bot, human));

	return 1;
}

// botEndFight(pBot, pHuman)
int BotCombatLua::botEndFight(lua_State* L) {
	CreatureObject* bot = toCreature(L, 1);
	CreatureObject* human = toCreature(L, 2);

	lua_pushboolean(L, bot != nullptr && human != nullptr && BotManager::instance()->isBot(bot) && BotCombat::endFight(bot, human));

	return 1;
}

// botClone(pBot)
int BotCombatLua::botClone(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotCombat::clone(bot));

	return 1;
}

// botEquip(pBot, template) -> oid or 0
int BotCombatLua::botEquip(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushinteger(L, bot != nullptr ? (lua_Integer) BotCombat::equip(bot, toString(L, 2)) : 0);

	return 1;
}

// botRepairGear(pBot) -> count
int BotCombatLua::botRepairGear(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushinteger(L, bot != nullptr ? BotCombat::repairGear(bot) : 0);

	return 1;
}

// botFindPack(pBot, template) -> oid or 0
int BotCombatLua::botFindPack(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	uint64 oid = 0;

	if (bot != nullptr) {
		Locker locker(bot);

		oid = BotItems::findPack(bot, toString(L, 2));
	}

	lua_pushinteger(L, (lua_Integer) oid);

	return 1;
}

// botRecentIncaps(pCreature) -> incaps in the last ten minutes (2: the next one kills)
int BotCombatLua::botRecentIncaps(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);

	lua_pushinteger(L, creature != nullptr ? BotCombat::recentIncaps(creature) : 0);

	return 1;
}
