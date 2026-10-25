/*
 * BotGroupLua (bot players). See BotGroupLua.h.
 */

#include "BotGroupLua.h"
#include "BotGroup.h"
#include "BotManager.h"
#include "BotChat.h"
#include "BotCombat.h"
#include "server/zone/managers/group/GroupManager.h"
#include "server/zone/objects/creature/ai/AiAgent.h"
#include "server/ServerCore.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/group/GroupObject.h"
#include "server/zone/objects/tangible/threat/ThreatMap.h"
#include "server/zone/managers/creature/CreatureManager.h"
#include "server/zone/ZoneServer.h"
#include "server/chat/ChatManager.h"
#include "server/chat/room/ChatRoom.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "server/zone/objects/tangible/pharmaceutical/EnhancePack.h"
#include "server/zone/objects/tangible/pharmaceutical/PharmaceuticalObject.h"
#include "server/zone/managers/skill/SkillModManager.h"
#include "templates/params/creature/CreatureAttribute.h"

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

	String args = toString(L, 5);

	if (!args.isEmpty())
		args = args.replaceAll("_", " ");

	return command.isEmpty() ? 0 : devCommand(L, command.toCharArray(), targetOid, args);
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
	String text = toString(L, 3);

	if (!text.isEmpty())
		text = text.replaceAll("_", " ");

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

// fight:<first>:<oid>: the bot targets it and attacks (BotCombat::setTarget)
int devFight(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot != nullptr)
		devLog().info(true) << bot->getFirstName() << " fights " << (uint64) toNumber(L, 3) << ": "
			<< (BotCombat::setTarget(bot, (uint64) UnsignedLong::valueOf(toString(L, 3)), true) ? "ok" : "refused");

	return 0;
}

// mob:<oid>: a creature's state and who damaged it
int devMob(lua_State* L) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(UnsignedLong::valueOf(toString(L, 2))) : nullptr;

	if (object == nullptr || !object->isTangibleObject()) {
		devLog().info(true) << "no such creature";
		return 0;
	}

	TangibleObject* tano = object->asTangibleObject();
	StringBuffer text;
	text << tano->getDisplayedName() << ": " << (tano->isCreatureObject() && tano->asCreatureObject()->isDead() ? "DEAD" : "alive")
		<< ", in combat " << (tano->hasDefenders() ? "yes" : "no");

	if (tano->isCreatureObject())
		text << ", health " << tano->asCreatureObject()->getHAM(0) << "/" << tano->asCreatureObject()->getMaxHAM(0);

	ThreatMap* threatMap = tano->getThreatMap();

	if (threatMap != nullptr) {
		for (int i = 0; i < threatMap->size(); ++i)
			text << "; threat " << threatMap->elementAt(i).getKey()->getDisplayedName() << " damage " << threatMap->elementAt(i).getValue().getTotalDamage();
	}

	devLog().info(true) << text.toString();

	return 0;
}

// weaken:<oid>: a creature's health, action and mind to 30, so a bot's hit kills it (for the fairness tests)
int devWeaken(lua_State* L) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(UnsignedLong::valueOf(toString(L, 2))) : nullptr;

	if (object == nullptr || !object->isCreatureObject())
		return 0;

	CreatureObject* creature = object->asCreatureObject();

	Locker locker(creature);

	creature->setHAM(CreatureAttribute::HEALTH, 30);
	creature->setHAM(CreatureAttribute::ACTION, 30);
	creature->setHAM(CreatureAttribute::MIND, 30);

	devLog().info(true) << creature->getDisplayedName() << " weakened";

	return 0;
}

// grouploot:<first>:<corpse oid>:<2 lottery, 3 random>: runs the group's loot step on a corpse, as /loot does for those rules
int devGroupLoot(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(UnsignedLong::valueOf(toString(L, 3))) : nullptr;

	if (bot == nullptr || object == nullptr || !object->isAiAgent())
		return 0;

	ManagedReference<GroupObject*> group = bot->getGroup();

	if (group == nullptr)
		return 0;

	AiAgent* corpse = cast<AiAgent*>(object.get());

	Locker locker(corpse);

	if ((int) toNumber(L, 4) == 2)
		GroupManager::instance()->createLottery(group, corpse);
	else
		GroupManager::instance()->doRandomLoot(group, corpse);

	devLog().info(true) << "group loot step " << (int) toNumber(L, 4) << " on " << corpse->getDisplayedName() << " done, the group has " << group->getNumberOfPlayerMembers()
		<< " player member(s) for a mission reward";

	return 0;
}

// why:<enhancer>:<patient>: the checks of /healenhance on the two, so a refusal that only a client would see can be read
int devWhy(lua_State* L) {
	Reference<CreatureObject*> enhancer = devBot(L, 2);
	Reference<CreatureObject*> patient = devBot(L, 3);

	if (enhancer == nullptr || patient == nullptr)
		return 0;

	Locker locker(enhancer);
	Locker clocker(patient, enhancer);

	SceneObject* inventory = enhancer->getSlottedObject("inventory");
	int packs = 0;

	for (int i = 0; inventory != nullptr && i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->isPharmaceuticalObject() && cast<PharmaceuticalObject*>(object)->isEnhancePack())
			++packs;
	}

	ManagedReference<SceneObject*> root = enhancer->getRootParent();

	devLog().info(true) << enhancer->getFirstName() << " -> " << patient->getFirstName() << ": canTreatWounds " << (enhancer->canTreatWounds() ? "yes" : "NO")
		<< ", enhance packs " << packs << ", medical rating " << enhancer->getSkillMod("private_medical_rating") << " (city "
		<< enhancer->getSkillModOfType("private_medical_rating", SkillModManager::CITY) << ", structure "
		<< enhancer->getSkillModOfType("private_medical_rating", SkillModManager::STRUCTURE) << "), root client object "
		<< (root != nullptr && root->isClientObject() ? "yes" : "no") << ", in combat " << (enhancer->isInCombat() ? "YES" : "no")
		<< "/" << (patient->isInCombat() ? "YES" : "no") << ", mind " << enhancer->getHAM(CreatureAttribute::MIND) << ", distance "
		<< enhancer->getDistanceTo(patient) << ", line of sight " << (CollisionManager::checkLineOfSight(enhancer, patient) ? "yes" : "NO");

	return 0;
}

// roomsay:<first>:<text>: the bot types into its group's chat room, the way a client does (ChatSendToRoom)
int devRoomSay(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	ManagedReference<GroupObject*> group = bot->getGroup();
	ManagedReference<ChatRoom*> room = group != nullptr ? group->getChatRoom() : nullptr;
	ChatManager* chatManager = bot->getZoneServer() != nullptr ? bot->getZoneServer()->getChatManager() : nullptr;

	if (room == nullptr || chatManager == nullptr) {
		devLog().info(true) << bot->getFirstName() << " has no group chat room";
		return 0;
	}

	Locker locker(bot);

	chatManager->handleChatRoomMessage(bot, UnicodeString(toString(L, 3).replaceAll("_", " ")), room->getRoomID(), 1);

	devLog().info(true) << bot->getFirstName() << " typed into group room " << room->getRoomID();

	return 0;
}

// lootrule:<first>:<0 free-for-all, 1 master looter, 2 lottery, 3 random>: the loot rule of the bot's group
int devLootRule(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	ManagedReference<GroupObject*> group = bot->getGroup();

	if (group == nullptr) {
		devLog().info(true) << bot->getFirstName() << " is in no group";
		return 0;
	}

	Locker glocker(group);

	group->setLootRule((int) toNumber(L, 3));

	devLog().info(true) << bot->getFirstName() << "'s group: loot rule " << group->getLootRule() << ", " << group->getGroupSize() << " member(s)";

	return 0;
}

// group:<first>: who is in the bot's group
int devGroup(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);

	if (bot == nullptr)
		return 0;

	ManagedReference<GroupObject*> group = bot->getGroup();

	if (group == nullptr) {
		devLog().info(true) << bot->getFirstName() << " is in no group";
		return 0;
	}

	Locker glocker(group);

	StringBuffer text;
	text << bot->getFirstName() << "'s group: loot rule " << group->getLootRule() << ", members";

	for (int i = 0; i < group->getGroupSize(); ++i) {
		Reference<CreatureObject*> member = group->getGroupMember(i);

		if (member != nullptr)
			text << " " << member->getFirstName() << (group->getLeader() == member ? " (leader)" : "");
	}

	devLog().info(true) << text.toString();

	return 0;
}

// spawn:<first>:<mobile template>[:<metres>]: a creature that far (default 6) in front of the bot, to fight. Logs its oid
int devSpawn(lua_State* L) {
	Reference<CreatureObject*> bot = devBot(L, 2);
	String name = toString(L, 3);

	if (bot == nullptr || name.isEmpty())
		return 0;

	Zone* zone = bot->getZone();

	if (bot->getParent().get() != nullptr) {
		devLog().info(true) << bot->getFirstName() << " is inside a building: teleport it outdoors first";
		return 0;
	}

	CreatureManager* creatureManager = zone != nullptr ? zone->getCreatureManager() : nullptr;

	if (creatureManager == nullptr)
		return 0;

	float distance = (float) toNumber(L, 4, 6);
	float x = bot->getPositionX() + distance * sin(bot->getDirection()->getRadians());
	float y = bot->getPositionY() + distance * cos(bot->getDirection()->getRadians());
	float z = CollisionManager::getWorldFloorCollision(x, y, zone, false);

	CreatureObject* creature = creatureManager->spawnCreature(name.hashCode(), 0, x, z, y, 0);

	if (creature == nullptr) {
		devLog().info(true) << "could not spawn " << name;
		return 0;
	}

	devLog().info(true) << bot->getFirstName() << " spawned " << creature->getDisplayedName() << ", oid " << creature->getObjectID() << ", at " << x << " " << y;

	return 0;
}

void registerDevTable(lua_State* L) {
	static const luaL_Reg functions[] = {
		{"why", devWhy}, {"grouploot", devGroupLoot}, {"weaken", devWeaken}, {"fight", devFight}, {"mob", devMob}, {"lootrule", devLootRule}, {"roomsay", devRoomSay}, {"group", devGroup}, {"spawn", devSpawn},
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
	lua->registerFunction("botCampSpots", botCampSpots);
	lua->registerFunction("botRemoveCamp", botRemoveCamp);
	lua->registerFunction("botGetCamp", botGetCamp);
	lua->registerFunction("botTrack", botTrack);
	lua->registerFunction("botAttackers", botAttackers);
	lua->registerFunction("botPeopleNear", botPeopleNear);
	lua->registerFunction("botHumansOnline", botHumansOnline);
	lua->registerFunction("botGroupInfo", botGroupInfo);

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
	uint64 blocker = 0;

	if (bot != nullptr) {
		error = "";
		camp = BotGroup::placeCamp(bot, toString(L, 2), error, &blocker);
	}

	lua_pushinteger(L, camp);
	lua_pushstring(L, error.toCharArray());
	lua_pushinteger(L, blocker);

	return 3;
}

// botCampSpots(pBot, kit, {x1, y1, x2, y2, ...}) -> {reason1, reason2, ...} ("" for clear ground), or nil
int BotGroupLua::botCampSpots(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	if (bot == nullptr || lua_gettop(L) < 3 || !lua_istable(L, 3)) {
		lua_pushnil(L);
		return 1;
	}

	Vector<float> points;
	int count = (int) lua_rawlen(L, 3);

	for (int i = 1; i <= count && i <= 512; ++i) {
		lua_rawgeti(L, 3, i);
		points.add((float) lua_tonumber(L, -1));
		lua_pop(L, 1);
	}

	Vector<String> reasons;

	if (!BotGroup::campSpots(bot, toString(L, 2), points, reasons)) {
		lua_pushnil(L);
		return 1;
	}

	lua_newtable(L);

	for (int i = 0; i < reasons.size(); ++i) {
		lua_pushstring(L, reasons.get(i).toCharArray());
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botAttackers(pCreature): the oids of the live creatures attacking it, nearest first (a bot, or a player: the creature
// must be locked, i.e. called from an event on it)
int BotGroupLua::botAttackers(lua_State* L) {
	lua_newtable(L);

	if (lua_gettop(L) < 1 || !lua_islightuserdata(L, 1))
		return 1;

	SceneObject* object = static_cast<SceneObject*>(lua_touserdata(L, 1));

	if (object == nullptr || !object->isCreatureObject())
		return 1;

	Vector<uint64> found;
	BotGroup::attackers(object->asCreatureObject(), found);

	for (int i = 0; i < found.size() && i < 8; ++i) {
		lua_pushinteger(L, found.get(i));
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
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

// botPeopleNear(pObject, range): array of {name, oid, kind} for the players (bots too) and people NPCs around it
// botGroupInfo(pCreature) -> nil or {id, leader, members = {oid, ...}}
int BotGroupLua::botGroupInfo(lua_State* L) {
	CreatureObject* creature = nullptr;

	if (lua_gettop(L) >= 1 && lua_islightuserdata(L, 1)) {
		SceneObject* object = static_cast<SceneObject*>(lua_touserdata(L, 1));

		creature = object != nullptr && object->isCreatureObject() ? object->asCreatureObject() : nullptr;
	}

	BotGroupInfo info;

	if (!BotGroup::groupInfo(creature, info)) {
		lua_pushnil(L);

		return 1;
	}

	lua_newtable(L);
	lua_pushinteger(L, (lua_Integer) info.id);
	lua_setfield(L, -2, "id");
	lua_pushinteger(L, (lua_Integer) info.leader);
	lua_setfield(L, -2, "leader");
	lua_newtable(L);

	for (int i = 0; i < info.members.size(); ++i) {
		lua_pushinteger(L, (lua_Integer) info.members.get(i));
		lua_rawseti(L, -2, i + 1);
	}

	lua_setfield(L, -2, "members");

	return 1;
}

// botHumansOnline() -> {oid, ...}
int BotGroupLua::botHumansOnline(lua_State* L) {
	Vector<uint64> humans;

	BotManager::instance()->getOnlineHumans(humans);

	lua_newtable(L);

	for (int i = 0; i < humans.size(); ++i) {
		lua_pushinteger(L, (lua_Integer) humans.get(i));
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

int BotGroupLua::botPeopleNear(lua_State* L) {
	lua_newtable(L);

	if (lua_gettop(L) < 1 || !lua_islightuserdata(L, 1))
		return 1;

	SceneObject* object = static_cast<SceneObject*>(lua_touserdata(L, 1));
	Vector<Reference<BotTrackEntry*>> found;

	BotGroup::peopleNear(object, (float) toNumber(L, 2, 25), found);

	for (int i = 0; i < found.size(); ++i) {
		BotTrackEntry* entry = found.get(i);

		lua_newtable(L);
		lua_pushstring(L, entry->name.toCharArray());
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, entry->oid);
		lua_setfield(L, -2, "oid");
		lua_pushstring(L, entry->kind.toCharArray());
		lua_setfield(L, -2, "kind");
		lua_rawseti(L, -2, i + 1);
	}

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
