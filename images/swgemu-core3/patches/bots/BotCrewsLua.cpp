/*
 * BotCrewsLua (Phase 9, Part 1). See BotCrewsLua.h.
 */

#include "BotCrewsLua.h"
#include "BotManager.h"
#include "BotFactory.h"
#include "BotCrews.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/managers/name/NameManager.h"
#include "server/ServerCore.h"
#include "templates/manager/TemplateManager.h"
#include "templates/creature/PlayerCreatureTemplate.h"

namespace {

int64 toInteger(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isnumber(L, index))
		return 0;

	return lua_tointeger(L, index);
}

String toString(lua_State* L, int index) {
	if (lua_gettop(L) < index || !lua_isstring(L, index))
		return "";

	return lua_tostring(L, index);
}

void setString(lua_State* L, const char* name, const String& value) {
	lua_pushstring(L, value.toCharArray());
	lua_setfield(L, -2, name);
}

void setInteger(lua_State* L, const char* name, int64 value) {
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

void setStrings(lua_State* L, const char* name, const Vector<String>& items) {
	lua_newtable(L);

	for (int i = 0; i < items.size(); ++i) {
		lua_pushstring(L, items.get(i).toCharArray());
		lua_rawseti(L, -2, i + 1);
	}

	lua_setfield(L, -2, name);
}

}

void BotCrewsLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botCrewOf", botCrewOf);
	lua->registerFunction("botHire", botHire);
	lua->registerFunction("botLetGo", botLetGo);
	lua->registerFunction("botOwner", botOwner);
	lua->registerFunction("botNameFree", botNameFree);
	lua->registerFunction("botNameCheck", botNameCheck);
	lua->registerFunction("botBoxCount", botBoxCount);
	lua->registerFunction("botEntry", botEntry);
	lua->registerFunction("botSkillPoints", botSkillPoints);
	lua->registerFunction("botSetGear", botSetGear);
	lua->registerFunction("botSquadAura", botSquadAura);
}

// botCrewOf(ownerOid)
int BotCrewsLua::botCrewOf(lua_State* L) {
	Vector<Reference<BotListEntry*>> crew;
	BotManager::instance()->getCrewOf(toInteger(L, 1), crew);

	lua_newtable(L);

	for (int i = 0; i < crew.size(); ++i) {
		BotListEntry* item = crew.get(i);

		lua_newtable(L);

		setInteger(L, "oid", item->oid);
		setString(L, "name", item->name);
		setString(L, "firstName", item->firstName);
		setString(L, "job", item->job);
		setString(L, "species", item->species);
		setString(L, "sex", item->sex);
		setString(L, "city", item->city);
		setInteger(L, "hiredAt", item->hiredAt);
		setBoolean(L, "online", item->online);
		setBoolean(L, "ready", item->oid != 0);
		setString(L, "state", item->state);

		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botHire(ownerOid, entry)
int BotCrewsLua::botHire(lua_State* L) {
	uint64 owner = toInteger(L, 1);

	if (owner == 0 || lua_gettop(L) < 2 || !lua_istable(L, 2)) {
		lua_pushboolean(L, false);
		lua_pushstring(L, "no owner or entry");

		return 2;
	}

	Reference<BotEntry*> entry = new BotEntry();

	lua_pushvalue(L, 2);

	{
		LuaObject table(L);

		BotFactory::parseEntry(table, *entry);
		table.pop();
	}

	entry->owner = owner;

	if (entry->hiredAt == 0)
		entry->hiredAt = Time().getTime();

	String reason;
	bool ok = BotManager::instance()->hire(entry, reason);

	lua_pushboolean(L, ok);
	lua_pushstring(L, (ok ? entry->firstName : reason).toCharArray());

	return 2;
}

// botLetGo(botOid)
int BotCrewsLua::botLetGo(lua_State* L) {
	String reason;
	bool ok = BotManager::instance()->letGo(toInteger(L, 1), reason);

	lua_pushboolean(L, ok);
	lua_pushstring(L, reason.toCharArray());

	return 2;
}

// botOwner(botOid)
int BotCrewsLua::botOwner(lua_State* L) {
	lua_pushinteger(L, BotManager::instance()->getOwner(toInteger(L, 1)));

	return 1;
}

// botNameFree(first)
int BotCrewsLua::botNameFree(lua_State* L) {
	String reason;
	bool ok = BotManager::instance()->nameFree(toString(L, 1).trim(), reason);

	lua_pushboolean(L, ok);
	lua_pushstring(L, reason.toCharArray());

	return 2;
}

// botNameCheck(name, species)
int BotCrewsLua::botNameCheck(lua_State* L) {
	String name = toString(L, 1).trim();
	String species = toString(L, 2).trim().toLowerCase();

	ZoneServer* zoneServer = ServerCore::getZoneServer();
	NameManager* nameManager = zoneServer != nullptr ? zoneServer->getNameManager() : nullptr;

	String raceFile = "object/creature/player/" + species + "_male.iff";
	PlayerCreatureTemplate* playerTemplate = dynamic_cast<PlayerCreatureTemplate*>(TemplateManager::instance()->getTemplate(raceFile.hashCode()));

	if (name.isEmpty() || nameManager == nullptr || playerTemplate == nullptr) {
		lua_pushboolean(L, false);
		lua_pushstring(L, "no name or species");

		return 2;
	}

	int result = nameManager->validateName(name, playerTemplate->getSpecies());
	const char* reason = "";

	switch (result) {
	case NameManagerResult::ACCEPTED:
		break;
	case NameManagerResult::DECLINED_EMPTY:
		reason = "A name can't be empty.";
		break;
	case NameManagerResult::DECLINED_RACE_INAPP:
		reason = "That name doesn't suit the species.";
		break;
	case NameManagerResult::DECLINED_PROFANE:
		reason = "That name is not allowed.";
		break;
	case NameManagerResult::DECLINED_DEVELOPER:
	case NameManagerResult::DECLINED_FICT_RESERVED:
	case NameManagerResult::DECLINED_RESERVED:
		reason = "That name is reserved.";
		break;
	case NameManagerResult::DECLINED_SYNTAX:
		reason = "That name has letters the game doesn't allow.";
		break;
	default:
		reason = "The game won't take that name.";
		break;
	}

	lua_pushboolean(L, result == NameManagerResult::ACCEPTED);
	lua_pushstring(L, reason);

	return 2;
}

// botBoxCount(oid)
int BotCrewsLua::botBoxCount(lua_State* L) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();

	if (zoneServer == nullptr) {
		lua_pushinteger(L, 0);

		return 1;
	}

	ManagedReference<SceneObject*> object = zoneServer->getObject(toInteger(L, 1));
	CreatureObject* creature = object != nullptr && object->isCreatureObject() ? object->asCreatureObject() : nullptr;

	// (the skill list is read without the creature's lock: a delta vector copy, as Lua's hasSkill does)
	lua_pushinteger(L, BotCrews::boxCount(creature));

	return 1;
}

// botEntry(first)
int BotCrewsLua::botEntry(lua_State* L) {
	Reference<BotEntry*> entry = BotManager::instance()->getEntry(toString(L, 1));

	if (entry == nullptr) {
		lua_pushnil(L);

		return 1;
	}

	lua_newtable(L);

	setString(L, "name", entry->name);
	setString(L, "account", entry->account);
	setString(L, "species", entry->species);
	setString(L, "sex", entry->sex);
	setString(L, "hair", entry->hair);
	setString(L, "job", entry->job);
	setString(L, "city", entry->city);
	setString(L, "online", entry->online);
	setString(L, "weapon", entry->weapon);
	setString(L, "campKit", entry->campKit);
	setString(L, "doctrine", entry->doctrine);
	setInteger(L, "owner", entry->owner);
	setInteger(L, "hiredAt", entry->hiredAt);
	setInteger(L, "hairColor", entry->hairColor);
	setInteger(L, "skinTone", entry->skinTone);
	setStrings(L, "skills", entry->skills);
	setStrings(L, "outfit", entry->outfit);
	setStrings(L, "carry", entry->carry);

	lua_newtable(L);

	setString(L, "planet", entry->planet);
	setNumber(L, "x", entry->x);
	setNumber(L, "z", entry->z);
	setNumber(L, "y", entry->y);
	setInteger(L, "cell", entry->cell);
	setNumber(L, "heading", entry->heading);

	lua_setfield(L, -2, "station");

	return 1;
}

// botSkillPoints(pBot)
int BotCrewsLua::botSkillPoints(lua_State* L) {
	CreatureObject* creature = nullptr;

	if (lua_gettop(L) >= 1 && lua_islightuserdata(L, 1)) {
		SceneObject* object = static_cast<SceneObject*>(lua_touserdata(L, 1));

		creature = object != nullptr && object->isCreatureObject() ? object->asCreatureObject() : nullptr;
	}

	PlayerObject* ghost = creature != nullptr ? creature->getPlayerObject() : nullptr;

	lua_pushinteger(L, ghost != nullptr ? ghost->getSkillPoints() : 0);

	return 1;
}

// botSetGear(botOid, entry)
int BotCrewsLua::botSetGear(lua_State* L) {
	if (lua_gettop(L) < 2 || !lua_istable(L, 2)) {
		lua_pushboolean(L, false);

		return 1;
	}

	BotEntry fresh;

	lua_pushvalue(L, 2);

	{
		LuaObject table(L);

		BotFactory::parseEntry(table, fresh);
		table.pop();
	}

	lua_pushboolean(L, BotManager::instance()->updateGear(toInteger(L, 1), fresh));

	return 1;
}

// botSquadAura(botOid)
int BotCrewsLua::botSquadAura(lua_State* L) {
	lua_pushboolean(L, BotManager::instance()->refreshSquadAura(toInteger(L, 1)));

	return 1;
}
