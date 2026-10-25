/*
 * BotCombatLua (Phase 5 bot group mates). See BotCombatLua.h.
 */

#include "BotCombatLua.h"
#include "BotCombat.h"
#include "BotItems.h"
#include "BotManager.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/tangible/TangibleObject.h"
#include "server/ServerCore.h"

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

namespace {

void setIntField(lua_State* L, const char* name, lua_Integer value) {
	lua_pushinteger(L, value);
	lua_setfield(L, -2, name);
}

void setBoolField(lua_State* L, const char* name, bool value) {
	lua_pushboolean(L, value);
	lua_setfield(L, -2, name);
}

void setStringField(lua_State* L, const char* name, const String& value) {
	lua_pushstring(L, value.toCharArray());
	lua_setfield(L, -2, name);
}

Logger& devLog() {
	static Logger logger("BotCombatDev");

	return logger;
}

// threat:<oid>: a creature's threat map, its target, and when a taunt works again
int devThreat(lua_State* L) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	uint64 oid = (uint64) UnsignedLong::valueOf(toString(L, 2));
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(oid) : nullptr;

	if (object == nullptr || !object->isCreatureObject()) {
		devLog().info(true) << "threat: no creature " << oid;
		return 0;
	}

	CreatureObject* creature = object->asCreatureObject();
	BotThreat threat;
	StringBuffer text;

	// The reading is cross-locked from a bot's lock: any online bot will do
	Vector<Reference<CreatureObject*>> bots;
	BotManager::instance()->getOnlineBots(bots);

	if (bots.size() == 0) {
		devLog().info(true) << "threat: no bot is online";
		return 0;
	}

	if (!BotCombat::threatOn(bots.get(0), creature, threat)) {
		devLog().info(true) << "threat: " << creature->getDisplayedName() << " is not an AiAgent";
		return 0;
	}

	text << "threat: " << creature->getDisplayedName() << " " << oid << ", HAM " << creature->getHAM(0) << "/" << creature->getMaxHAM(0) << ", on " << threat.target
		<< ", tauntable " << (threat.tauntable ? "yes" : "NO") << ", " << (threat.taunted ? "TAUNTED by " + String::valueOf(threat.tauntedBy) : String("not taunted"))
		<< ", taunt lockout " << threat.lockoutMs << " ms" << (threat.poisoned ? ", POISONED" : "") << (threat.diseased ? ", DISEASED" : "");

	for (int i = 0; i < threat.entries.size(); ++i) {
		const BotThreatEntry& entry = *threat.entries.get(i);

		text << "; " << entry.name << " " << entry.oid << " damage " << entry.damage << " aggro " << entry.aggro << " heal " << entry.heal << (entry.taunted ? " TAUNTED" : "");
	}

	devLog().info(true) << text.toString();

	return 0;
}

// range:<first>: a bot's held weapon and its ranges
int devRange(lua_State* L) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(toString(L, 2));
	BotWeaponRange range;

	if (bot == nullptr || !BotCombat::weaponRange(bot, range)) {
		devLog().info(true) << "range: no online bot called " << toString(L, 2);
		return 0;
	}

	devLog().info(true) << "range: " << bot->getFirstName() << " holds " << (range.templateName.isEmpty() ? String("nothing (fists)") : range.templateName) << ": point blank "
		<< range.pointBlankAccuracy << " @ " << range.pointBlankRange << " m, ideal " << range.idealAccuracy << " @ " << range.idealRange << " m, max " << range.maxAccuracy
		<< " @ " << range.maxRange << " m, " << (range.ranged ? "ranged" : "not ranged");

	return 0;
}

String templatePath(SceneObject* object) {
	SharedObjectTemplate* objectTemplate = object != nullptr ? object->getObjectTemplate() : nullptr;

	return objectTemplate != nullptr ? objectTemplate->getFullTemplateString() : String("?");
}

// gear:<first>: what the bot wears or holds, and what its inventory holds (templates, use counts)
int devGear(lua_State* L) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(toString(L, 2));

	if (bot == nullptr) {
		devLog().info(true) << "gear: no online bot called " << toString(L, 2);
		return 0;
	}

	StringBuffer text;

	text << "gear: " << bot->getFirstName() << " wears";

	for (int i = 0; i < bot->getSlottedObjectsSize(); ++i) {
		Reference<SceneObject*> object = bot->getSlottedObject(i);

		if (object == nullptr)
			continue;

		String path = templatePath(object);

		if (path.contains("/wearables/") || path.contains("/weapon/") || path.contains("/instrument/"))
			text << " " << path.subString(path.lastIndexOf('/') + 1);
	}

	SceneObject* inventory = bot->getSlottedObject("inventory");

	text << "; pack:";

	for (int i = 0; inventory != nullptr && i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object == nullptr)
			continue;

		String path = templatePath(object);

		text << " " << path.subString(path.lastIndexOf('/') + 1);

		if (object->isTangibleObject())
			text << "x" << object->asTangibleObject()->getUseCount();
	}

	devLog().info(true) << text.toString();

	return 0;
}

void registerDevTable(lua_State* L) {
	static const luaL_Reg functions[] = {{"threat", devThreat}, {"range", devRange}, {"gear", devGear}, {nullptr, nullptr}};

	lua_newtable(L);

	for (int i = 0; functions[i].name != nullptr; ++i) {
		lua_pushcfunction(L, functions[i].func);
		lua_setfield(L, -2, functions[i].name);
	}

	lua_setglobal(L, "BotCombatDev");
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
	lua->registerFunction("botDropDeadDefenders", botDropDeadDefenders);
	lua->registerFunction("botWeaponRange", botWeaponRange);
	lua->registerFunction("botThreatOn", botThreatOn);
	lua->registerFunction("botResists", botResists);
	lua->registerFunction("botCreaturesNear", botCreaturesNear);
	lua->registerFunction("botLairsNear", botLairsNear);

	registerDevTable(lua->getLuaState());

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

// botDropDeadDefenders(pCreature) -> how many it removed
int BotCombatLua::botDropDeadDefenders(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);

	lua_pushinteger(L, creature != nullptr ? BotCombat::dropDeadDefenders(creature) : 0);

	return 1;
}

// botRecentIncaps(pCreature) -> incaps in the last ten minutes (2: the next one kills)
int BotCombatLua::botRecentIncaps(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);

	lua_pushinteger(L, creature != nullptr ? BotCombat::recentIncaps(creature) : 0);

	return 1;
}

// botWeaponRange(pBot) -> {template, ranged, pointBlankRange, pointBlankAccuracy, idealRange, idealAccuracy, maxRange, maxAccuracy}
int BotCombatLua::botWeaponRange(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	BotWeaponRange range;

	if (bot == nullptr || !BotCombat::weaponRange(bot, range)) {
		lua_pushnil(L);

		return 1;
	}

	lua_newtable(L);
	setStringField(L, "template", range.templateName);
	setBoolField(L, "ranged", range.ranged);
	setIntField(L, "pointBlankRange", range.pointBlankRange);
	setIntField(L, "pointBlankAccuracy", range.pointBlankAccuracy);
	setIntField(L, "idealRange", range.idealRange);
	setIntField(L, "idealAccuracy", range.idealAccuracy);
	setIntField(L, "maxRange", range.maxRange);
	setIntField(L, "maxAccuracy", range.maxAccuracy);

	return 1;
}

// botCreaturesNear(pBot, range) -> {{oid, x, y, radius, target}, ...}
int BotCombatLua::botCreaturesNear(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Vector<Reference<BotCreatureInfo*>> found;

	if (bot != nullptr)
		BotCombat::creaturesNear(bot, (float) lua_tonumber(L, 2), found);

	lua_newtable(L);

	for (int i = 0; i < found.size(); ++i) {
		const BotCreatureInfo& info = *found.get(i);

		lua_newtable(L);
		setIntField(L, "oid", (lua_Integer) info.oid);
		lua_pushnumber(L, info.x);
		lua_setfield(L, -2, "x");
		lua_pushnumber(L, info.y);
		lua_setfield(L, -2, "y");
		lua_pushnumber(L, info.radius);
		lua_setfield(L, -2, "radius");
		setIntField(L, "target", (lua_Integer) info.target);
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botResists(pCreature) -> {kinetic, energy, blast, heat, cold, electricity, acid, stun, lightsaber} or nil
int BotCombatLua::botResists(lua_State* L) {
	CreatureObject* creature = toCreature(L, 1);
	BotResists resists;

	if (creature == nullptr || !BotCombat::resists(creature, resists)) {
		lua_pushnil(L);

		return 1;
	}

	lua_newtable(L);

	const struct {
		const char* name;
		float value;
	} fields[] = {{"kinetic", resists.kinetic}, {"energy", resists.energy}, {"blast", resists.blast}, {"heat", resists.heat},
		{"cold", resists.cold}, {"electricity", resists.electricity}, {"acid", resists.acid}, {"stun", resists.stun},
		{"lightsaber", resists.lightsaber}};

	for (const auto& field : fields) {
		lua_pushnumber(L, field.value);
		lua_setfield(L, -2, field.name);
	}

	return 1;
}

// botThreatOn(pBot, pCreature) -> {target, tauntable, taunted, tauntedBy, lockoutMs, entries}
int BotCombatLua::botThreatOn(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	CreatureObject* creature = toCreature(L, 2);
	BotThreat threat;

	if (bot == nullptr || creature == nullptr || !BotCombat::threatOn(bot, creature, threat)) {
		lua_pushnil(L);

		return 1;
	}

	lua_newtable(L);
	setIntField(L, "target", (lua_Integer) threat.target);
	setBoolField(L, "tauntable", threat.tauntable);
	setBoolField(L, "taunted", threat.taunted);
	setIntField(L, "tauntedBy", (lua_Integer) threat.tauntedBy);
	setIntField(L, "lockoutMs", threat.lockoutMs);
	setBoolField(L, "poisoned", threat.poisoned);
	setBoolField(L, "diseased", threat.diseased);
	setBoolField(L, "poisonImmune", threat.poisonImmune);
	setBoolField(L, "diseaseImmune", threat.diseaseImmune);

	lua_newtable(L);

	for (int i = 0; i < threat.entries.size(); ++i) {
		const BotThreatEntry& entry = *threat.entries.get(i);

		lua_newtable(L);
		setIntField(L, "oid", (lua_Integer) entry.oid);
		setStringField(L, "name", entry.name);
		setIntField(L, "damage", entry.damage);
		setIntField(L, "aggro", entry.aggro);
		setIntField(L, "heal", entry.heal);
		setBoolField(L, "taunted", entry.taunted);
		lua_rawseti(L, -2, i + 1);
	}

	lua_setfield(L, -2, "entries");

	return 1;
}

// botLairsNear(pBot, range) -> {{oid, x, y}, ...}
int BotCombatLua::botLairsNear(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Vector<Reference<BotLairInfo*>> found;

	if (bot != nullptr)
		BotCombat::lairsNear(bot, (float) lua_tonumber(L, 2), found);

	lua_newtable(L);

	for (int i = 0; i < found.size(); ++i) {
		const BotLairInfo& lair = *found.get(i);

		lua_newtable(L);
		setIntField(L, "oid", (lua_Integer) lair.oid);
		lua_pushnumber(L, lair.x);
		lua_setfield(L, -2, "x");
		lua_pushnumber(L, lair.y);
		lua_setfield(L, -2, "y");
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}
