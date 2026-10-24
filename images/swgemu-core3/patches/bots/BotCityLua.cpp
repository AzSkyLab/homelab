/*
 * BotCityLua (Phase 6 bot players' city). See BotCityLua.h.
 *
 * Console tools, for the local server (console runLuaFunction BotCityDev:<fn>:<arg>:...; each runs in a task and logs
 * its outcome as BotCity). The ones that change the world need botSetDevHuman on (BotJobs:devHuman:on):
 *   probe:<planet>:<x>:<y>[:<radius>:<areaRadius>]          a site probe (default radius 30, area 150)
 *   probeRing:<planet>:<cx>:<cy>:<r1>:<r2>:<rStep>:<degStep>  probes on rings around a point (bearing 0 = north), then
 *                                                            logs the best five
 *   map:<planet>:<x0>:<y0>:<x1>:<y1>[:<step>]                an ASCII height map, north at the top
 *   profile:<planet>:<x0>:<y0>:<x1>:<y1>[:<step>]            heights along a line
 *   info:<city>                     the city's state           owned:<first>                  a bot's structures
 *   grant:<first>:<skill>           award a skill box and what it requires (politician boxes cost no skill points)
 *   surrender:<first>:<prefix>      surrender every box starting with prefix ("social_politician")
 *   bring:<first>:<x>:<y>           teleport a bot outdoors on its planet
 *   found:<first>:<x>:<y>:<angle>:<name>                     botFoundCity
 *   house:<first>:<deed template>:<x>:<y>:<angle>            make the deed, then botPlaceStructure (the real command)
 *   declare:<first>[:<structure oid>]                        botDeclareResidence (default: its first house)
 *   expand:<city>[:update]          rank up, or a full weekly update
 *   deposit:<city>:<credits>        decorate:<first>:<template>
 *   zoning:<city>:<on|off>          tax:<city>:<index>:<value>     spec:<city>:<spec>     register:<city>[:off]
 *   candidate:<first>:<city>        vote:<first>:<city>:<candidate's first name, or 0 to abstain>
 *   destroy:<city>                  CityManager::destroyCity (the city, its civic buildings and decorations)
 *   raze:<first>                    destroy every structure the bot owns (houses, cantinas...)
 *
 * Cleaning a test city out of the dev world (the city's bots are job-driven: while the mayor is online and a human is
 * "online", its job founds the city again at once, so destroy last, with the bots offline):
 *   1. BotJobs:devHuman:on, BotJobs:login:<first> for each city bot, and wait until BotJobs:list shows them online
 *      (a login queue of ten takes a minute; raze and the other dev tools need an online bot);
 *   2. BotCityDev:raze:<first> for each: its houses and commercial buildings (the cantina, hospital, theater);
 *   3. BotJobs:logout:<first> for each, then BotCityDev:destroy:<city> (the hall, civic buildings and decorations),
 *      then BotJobs:devHuman:off (destroy is a dev tool and refuses once it is off);
 *   4. BotCityDev:surrender:<first>:social_politician for any bot that was granted politician boxes.
 * Starting over from nothing is also simple: stop the stack, delete CORE3_DEV_DATA/databases (and mysql for the bots'
 * accounts, which then are made again); the navmesh files can stay.
 */

#include "BotCityLua.h"
#include "BotCity.h"
#include "BotManager.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/managers/planet/PlanetManager.h"
#include "terrain/manager/TerrainManager.h"
#include "terrain/ProceduralTerrainAppearance.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/region/CityRegion.h"
#include "server/zone/objects/region/CitizenList.h"
#include "server/zone/objects/structure/StructureObject.h"
#include "server/zone/objects/building/BuildingObject.h"
#include "server/zone/objects/tangible/deed/structure/StructureDeed.h"
#include "server/zone/managers/city/CityManager.h"
#include "server/zone/managers/skill/SkillManager.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "server/zone/objects/creature/variables/SkillList.h"

namespace {

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

// Numbers, or strings of numbers (the console passes strings)
double toNumber(lua_State* L, int index, double fallback = 0) {
	if (lua_gettop(L) < index || !lua_isnumber(L, index))
		return fallback;

	return lua_tonumber(L, index);
}

uint64 toOid(lua_State* L, int index) {
	if (lua_gettop(L) < index)
		return 0;

	if (lua_type(L, index) == LUA_TSTRING)
		return UnsignedLong::valueOf(lua_tostring(L, index));

	if (!lua_isnumber(L, index))
		return 0;

	return (uint64)lua_tointeger(L, index);
}

bool toBoolean(lua_State* L, int index, bool fallback) {
	if (lua_gettop(L) < index || lua_isnil(L, index))
		return fallback;

	if (lua_type(L, index) == LUA_TSTRING) {
		String value = String(lua_tostring(L, index)).toLowerCase();

		return value == "true" || value == "on" || value == "1" || value == "yes" || value == "update";
	}

	return lua_toboolean(L, index);
}

// A city by name, or a creature's residence city
Reference<CityRegion*> toCity(lua_State* L, int index) {
	if (lua_gettop(L) < index)
		return nullptr;

	if (lua_type(L, index) == LUA_TSTRING)
		return BotCity::findCity(lua_tostring(L, index));

	return BotCity::getResidenceCity(toCreature(L, index));
}

void setField(lua_State* L, const char* key, const String& value) {
	lua_pushstring(L, value.toCharArray());
	lua_setfield(L, -2, key);
}

void setField(lua_State* L, const char* key, double value) {
	lua_pushnumber(L, value);
	lua_setfield(L, -2, key);
}

void setIntField(lua_State* L, const char* key, int64 value) {
	lua_pushinteger(L, value);
	lua_setfield(L, -2, key);
}

void setBoolField(lua_State* L, const char* key, bool value) {
	lua_pushboolean(L, value);
	lua_setfield(L, -2, key);
}

void pushStringArray(lua_State* L, const Vector<String>& values) {
	lua_newtable(L);

	for (int i = 0; i < values.size(); ++i) {
		lua_pushstring(L, values.get(i).toCharArray());
		lua_rawseti(L, -2, i + 1);
	}
}

void pushStructure(lua_State* L, const BotStructureInfo& info) {
	lua_newtable(L);

	setIntField(L, "oid", info.oid);
	setField(L, "template", info.templatePath);
	setField(L, "name", info.name);
	setField(L, "kind", info.kind);
	setField(L, "x", info.x);
	setField(L, "y", info.y);
	setField(L, "city", info.city);
	setBoolField(L, "residence", info.residence);
}

String getFirstName(ZoneServer* zoneServer, uint64 oid) {
	Reference<CreatureObject*> creature = zoneServer->getObject(oid).castTo<CreatureObject*>();

	return creature != nullptr ? creature->getFirstName() : String::valueOf(oid);
}

// Everything botCityInfo returns, read as Core3's own city reports read it (without the city's lock)
void pushCityInfo(lua_State* L, CityRegion* city) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	CityManager* cityManager = zoneServer->getCityManager();
	Zone* zone = city->getZone();
	int rank = city->getCityRank();

	lua_newtable(L);

	setField(L, "name", city->getCityRegionName());
	setIntField(L, "id", city->getObjectID());
	setField(L, "planet", zone != nullptr ? zone->getZoneName() : String(""));
	setField(L, "x", city->getPositionX());
	setField(L, "y", city->getPositionY());
	setIntField(L, "rank", rank);
	setField(L, "radius", city->getRadius());
	setIntField(L, "citizens", city->getCitizenCount());

	Vector<uint8>& citizensPerRank = CityManagerImplementation::citizensPerRank;

	setIntField(L, "citizensToKeep", rank >= 1 && rank <= citizensPerRank.size() ? citizensPerRank.get(rank - 1) : 0);
	setIntField(L, "citizensForNextRank", rank >= 1 && rank < citizensPerRank.size() ? citizensPerRank.get(rank) : 0);

	uint64 mayorOid = city->getMayorID();
	Reference<CreatureObject*> mayor = zoneServer->getObject(mayorOid).castTo<CreatureObject*>();

	setIntField(L, "mayor", mayorOid);
	setField(L, "mayorName", mayor != nullptr ? mayor->getDisplayedName() : String(""));
	setBoolField(L, "mayorIsBot", BotManager::instance()->isBotOid(mayorOid));
	setBoolField(L, "mayorOnline", mayor != nullptr && mayor->getPlayerObject() != nullptr && mayor->getPlayerObject()->isOnline());

	setField(L, "treasury", city->getCityTreasury());
	setIntField(L, "upkeep", BotCity::getWeeklyUpkeep(city));
	setIntField(L, "nextUpdate", city->getTimeToUpdate());
	setField(L, "nextUpdateText", cityManager->getNextUpdateTimeString(city));
	setBoolField(L, "assessmentPending", city->hasAssessmentPending());

	String spec = city->getCitySpecialization();

	setField(L, "specialization", spec);
	setField(L, "spec", spec.contains("city_spec_") ? spec.subString(spec.indexOf("city_spec_") + 10) : String(""));
	setBoolField(L, "registered", city->isRegistered());
	setBoolField(L, "zoning", city->isZoningEnabled());

	lua_newtable(L);
	setIntField(L, "income", city->getIncomeTax());
	setIntField(L, "property", city->getPropertyTax());
	setIntField(L, "sales", city->getSalesTax());
	setIntField(L, "travel", city->getTravelTax());
	setIntField(L, "garage", city->getGarageTax());
	lua_setfield(L, -2, "taxes");

	setIntField(L, "decorations", city->getDecorationCount());
	setIntField(L, "maxDecorations", CityManagerImplementation::decorationsPerRank * rank);

	ManagedReference<StructureObject*> hall = city->getCityHall();

	setIntField(L, "cityHall", hall != nullptr ? hall->getObjectID() : 0);

	// The citizens
	CitizenList* citizens = city->getCitizenList();

	lua_newtable(L);

	for (int i = 0; i < citizens->size(); ++i) {
		uint64 oid = citizens->get(i);

		lua_newtable(L);
		setIntField(L, "oid", oid);
		setField(L, "name", getFirstName(zoneServer, oid));
		setBoolField(L, "bot", BotManager::instance()->isBotOid(oid));
		lua_rawseti(L, -2, i + 1);
	}

	lua_setfield(L, -2, "citizenList");

	// The election
	lua_newtable(L);
	setBoolField(L, "locked", city->isVotingLocked());
	setIntField(L, "seconds", BotCity::getSecondsToElection(city));

	VectorMap<uint64, int>* candidates = city->getCandidates();

	lua_newtable(L);

	for (int i = 0; i < candidates->size(); ++i) {
		const VectorMapEntry<uint64, int>& entry = candidates->elementAt(i);

		lua_newtable(L);
		setIntField(L, "oid", entry.getKey());
		setField(L, "name", getFirstName(zoneServer, entry.getKey()));
		setIntField(L, "votes", entry.getValue());
		setBoolField(L, "incumbent", entry.getKey() == mayorOid);
		setBoolField(L, "bot", BotManager::instance()->isBotOid(entry.getKey()));
		lua_rawseti(L, -2, i + 1);
	}

	lua_setfield(L, -2, "candidates");
	lua_setfield(L, -2, "election");

	// The civic and commercial buildings and the decorations
	lua_newtable(L);

	int n = 0;

	for (int i = 0; i < city->getStructuresCount(); ++i) {
		ManagedReference<StructureObject*> structure = city->getCivicStructure(i);

		if (structure == nullptr)
			continue;

		BotStructureInfo info;
		BotCity::getStructureInfo(structure, info);
		pushStructure(L, info);
		lua_rawseti(L, -2, ++n);
	}

	for (int i = 0; i < city->getCommercialStructuresCount(); ++i) {
		ManagedReference<StructureObject*> structure = city->getCommercialStructure(i);

		if (structure == nullptr)
			continue;

		BotStructureInfo info;
		BotCity::getStructureInfo(structure, info);
		pushStructure(L, info);
		lua_rawseti(L, -2, ++n);
	}

	for (int i = 0; i < city->getDecorationCount(); ++i) {
		ManagedReference<SceneObject*> decoration = city->getCityDecoration(i);

		if (decoration == nullptr)
			continue;

		BotStructureInfo info;
		info.oid = decoration->getObjectID();
		info.templatePath = decoration->getObjectTemplate() != nullptr ? decoration->getObjectTemplate()->getFullTemplateString() : "";
		info.name = decoration->getDisplayedName();
		info.kind = "decoration";
		info.x = decoration->getPositionX();
		info.y = decoration->getPositionY();
		info.city = city->getCityRegionName();
		pushStructure(L, info);
		lua_rawseti(L, -2, ++n);
	}

	lua_setfield(L, -2, "structures");
}

// The same, one line for the log
String describeCity(CityRegion* city) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	StringBuffer buffer;

	buffer << city->getCityRegionName() << " (id " << city->getObjectID() << ") on " << (city->getZone() != nullptr ? city->getZone()->getZoneName() : String("?"))
		<< " at (" << (int)city->getPositionX() << ", " << (int)city->getPositionY() << "): rank " << city->getCityRank() << ", radius "
		<< (int)city->getRadius() << ", " << city->getCitizenCount() << " citizens, mayor " << getFirstName(zoneServer, city->getMayorID())
		<< ", treasury " << (int64)city->getCityTreasury() << ", upkeep " << BotCity::getWeeklyUpkeep(city) << "/week, next update in "
		<< zoneServer->getCityManager()->getNextUpdateTimeString(city) << (city->hasAssessmentPending() ? " (assessment pending)" : "")
		<< ", spec " << (city->getCitySpecialization().isEmpty() ? String("none") : city->getCitySpecialization())
		<< (city->isRegistered() ? ", registered" : "") << ", zoning " << (city->isZoningEnabled() ? "on" : "off")
		<< ", election in " << BotCity::getSecondsToElection(city) << " s" << (city->isVotingLocked() ? " (ballot locked)" : "")
		<< ", " << city->getCandidates()->size() << " candidates, " << city->getDecorationCount() << " decorations";

	CitizenList* citizens = city->getCitizenList();

	buffer << " | citizens:";

	for (int i = 0; i < citizens->size(); ++i)
		buffer << " " << getFirstName(zoneServer, citizens->get(i));

	buffer << " | buildings:";

	ManagedReference<StructureObject*> hall = city->getCityHall();

	if (hall != nullptr)
		buffer << " cityhall " << hall->getObjectID();

	for (int i = 0; i < city->getStructuresCount(); ++i) {
		ManagedReference<StructureObject*> structure = city->getCivicStructure(i);

		if (structure != nullptr && structure != hall)
			buffer << " " << structure->getObjectTemplate()->getTemplateFileName() << " " << structure->getObjectID();
	}

	for (int i = 0; i < city->getCommercialStructuresCount(); ++i) {
		ManagedReference<StructureObject*> structure = city->getCommercialStructure(i);

		if (structure != nullptr)
			buffer << " " << structure->getObjectTemplate()->getTemplateFileName() << " " << structure->getObjectID();
	}

	return buffer.toString();
}

// A dev tool's bot, by first name, online; logged if not
Reference<CreatureObject*> getDevBot(const String& firstName) {
	Reference<CreatureObject*> bot = BotManager::instance()->getOnlineBot(firstName);

	if (bot == nullptr)
		BotCity::log().warning() << "BotCityDev: no online bot called " << firstName;

	return bot;
}

}

void BotCityLua::registerFunctions(Lua* lua) {
	lua->registerFunction("botCheckSite", botCheckSite);
	lua->registerFunction("botFoundCity", botFoundCity);
	lua->registerFunction("botCityInfo", botCityInfo);
	lua->registerFunction("botDeclareResidence", botDeclareResidence);
	lua->registerFunction("botOwnedStructures", botOwnedStructures);
	lua->registerFunction("botCheckPlacement", botCheckPlacement);
	lua->registerFunction("botPlaceStructure", botPlaceStructure);
	lua->registerFunction("botCityDeposit", botCityDeposit);
	lua->registerFunction("botCitySetTax", botCitySetTax);
	lua->registerFunction("botCitySetSpec", botCitySetSpec);
	lua->registerFunction("botCityZoning", botCityZoning);
	lua->registerFunction("botCityRegister", botCityRegister);
	lua->registerFunction("botCityCandidate", botCityCandidate);
	lua->registerFunction("botCityVote", botCityVote);
	lua->registerFunction("botCityExpand", botCityExpand);
	lua->registerFunction("botPlaceDecoration", botPlaceDecoration);

	// The console tools: a table, so runLuaFunction BotCityDev:<fn> finds them
	lua_State* L = lua->getLuaState();

	static const luaL_Reg devFunctions[] = {
		{"probe", devProbe},
		{"probeRing", devProbeRing},
		{"map", devMap},
		{"profile", devProfile},
		{"info", devInfo},
		{"owned", devOwned},
		{"grant", devGrant},
		{"surrender", devSurrender},
		{"bring", devBring},
		{"found", devFound},
		{"house", devHouse},
		{"declare", devDeclare},
		{"expand", devExpand},
		{"deposit", devDeposit},
		{"decorate", devDecorate},
		{"zoning", devZoning},
		{"tax", devTax},
		{"spec", devSpec},
		{"register", devRegister},
		{"candidate", devCandidate},
		{"vote", devVote},
		{"destroy", devDestroy},
		{"raze", devRaze},
		{nullptr, nullptr}
	};

	lua_newtable(L);

	for (const luaL_Reg* entry = devFunctions; entry->name != nullptr; ++entry) {
		lua_pushcfunction(L, entry->func);
		lua_setfield(L, -2, entry->name);
	}

	lua_setglobal(L, "BotCityDev");
}

// --- Sites and placement ---

// botCheckSite(planet, x, y, radius[, areaRadius])
int BotCityLua::botCheckSite(lua_State* L) {
	BotSiteCheck site;
	float radius = toNumber(L, 4, 30);

	if (!BotCity::checkSite(toString(L, 1), toNumber(L, 2), toNumber(L, 3), radius, toNumber(L, 5, radius), site)) {
		lua_pushnil(L);
		return 1;
	}

	lua_newtable(L);

	setBoolField(L, "ok", site.ok);
	pushStringArray(L, site.reasons);
	lua_setfield(L, -2, "reasons");
	pushStringArray(L, site.warnings);
	lua_setfield(L, -2, "warnings");
	setField(L, "z", site.z);

	if (site.waterLevel > -9000)
		setField(L, "waterLevel", site.waterLevel);

	setField(L, "heightDiff", site.heightDiff);
	setField(L, "heightDiffArea", site.heightDiffArea);
	setField(L, "blocked", site.blocked);
	setField(L, "water", site.water);
	setField(L, "nearestCity", site.nearestCity);
	setField(L, "nearestDistance", site.nearestDistance);
	setField(L, "nearestLimit", site.nearestLimit);

	return 1;
}

// botCheckPlacement(pBot, deedOid, x, y, angle) -> ok, reason
int BotCityLua::botCheckPlacement(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	String reason = "not an online bot";

	if (bot != nullptr) {
		Locker locker(bot);

		ManagedReference<StructureDeed*> deed = bot->getZoneServer()->getObject(toOid(L, 2)).castTo<StructureDeed*>();

		reason = deed == nullptr ? String("there's no structure deed with that id") : BotCity::checkPlacement(bot, deed, toNumber(L, 3), toNumber(L, 4), (int)toNumber(L, 5));
	}

	lua_pushboolean(L, reason.isEmpty());
	lua_pushstring(L, reason.toCharArray());

	return 2;
}

// botPlaceStructure(pBot, deedOid, x, y, angle)
int BotCityLua::botPlaceStructure(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotCity::placeStructure(bot, toOid(L, 2), toNumber(L, 3), toNumber(L, 4), (int)toNumber(L, 5)));

	return 1;
}

// --- Founding and the city ---

// botFoundCity(pMayor, x, y, angle, name) -> city id or 0
int BotCityLua::botFoundCity(lua_State* L) {
	CreatureObject* mayor = toOnlineBot(L, 1);
	uint64 oid = mayor != nullptr ? BotCity::foundCity(mayor, toNumber(L, 2), toNumber(L, 3), (int)toNumber(L, 4), toString(L, 5)) : 0;

	lua_pushinteger(L, oid);

	return 1;
}

// botCityInfo(name | pCreature)
int BotCityLua::botCityInfo(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);

	if (city == nullptr)
		lua_pushnil(L);
	else
		pushCityInfo(L, city);

	return 1;
}

// botDeclareResidence(pBot, structureOid)
int BotCityLua::botDeclareResidence(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);

	lua_pushboolean(L, bot != nullptr && BotCity::declareResidence(bot, toOid(L, 2)));

	return 1;
}

// botOwnedStructures(pBot)
int BotCityLua::botOwnedStructures(lua_State* L) {
	CreatureObject* bot = toCreature(L, 1);
	Vector<BotStructureInfo> owned;

	if (bot != nullptr && BotManager::instance()->isBot(bot))
		BotCity::getOwnedStructures(bot, owned);

	lua_newtable(L);

	for (int i = 0; i < owned.size(); ++i) {
		pushStructure(L, owned.get(i));
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

// botCityDeposit(name, credits[, pFrom])
int BotCityLua::botCityDeposit(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);
	CreatureObject* from = toCreature(L, 3);

	lua_pushboolean(L, city != nullptr && BotCity::deposit(city, (int)toNumber(L, 2), from));

	return 1;
}

// botCitySetTax(name, index, value)
int BotCityLua::botCitySetTax(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);

	lua_pushboolean(L, city != nullptr && BotCity::setTax(city, (int)toNumber(L, 2, -1), (int)toNumber(L, 3)));

	return 1;
}

// botCitySetSpec(name, spec)
int BotCityLua::botCitySetSpec(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);

	lua_pushboolean(L, city != nullptr && BotCity::setSpecialization(city, toString(L, 2)));

	return 1;
}

// botCityZoning(name, on)
int BotCityLua::botCityZoning(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);

	lua_pushboolean(L, city != nullptr && BotCity::setZoning(city, toBoolean(L, 2, false)));

	return 1;
}

// botCityRegister(name[, on])
int BotCityLua::botCityRegister(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);

	lua_pushboolean(L, city != nullptr && BotCity::setRegistered(city, toBoolean(L, 2, true)));

	return 1;
}

// botCityCandidate(pBot, name)
int BotCityLua::botCityCandidate(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Reference<CityRegion*> city = toCity(L, 2);

	lua_pushboolean(L, bot != nullptr && city != nullptr && BotCity::registerCandidate(bot, city));

	return 1;
}

// botCityVote(pBot, name, candidateOid)
int BotCityLua::botCityVote(lua_State* L) {
	CreatureObject* bot = toOnlineBot(L, 1);
	Reference<CityRegion*> city = toCity(L, 2);

	lua_pushboolean(L, bot != nullptr && city != nullptr && BotCity::castVote(bot, city, toOid(L, 3)));

	return 1;
}

// botCityExpand(name[, fullUpdate])
int BotCityLua::botCityExpand(lua_State* L) {
	Reference<CityRegion*> city = toCity(L, 1);

	lua_pushboolean(L, city != nullptr && BotCity::expand(city, toBoolean(L, 2, false)));

	return 1;
}

// botPlaceDecoration(pMayor, template) -> oid or 0
int BotCityLua::botPlaceDecoration(lua_State* L) {
	CreatureObject* mayor = toOnlineBot(L, 1);

	lua_pushinteger(L, mayor != nullptr ? BotCity::placeDecoration(mayor, toString(L, 2)) : 0);

	return 1;
}

// --- BotCityDev: the console tools (self is argument 1) ---

int BotCityLua::devProbe(lua_State* L) {
	String planet = toString(L, 2);
	float x = toNumber(L, 3), y = toNumber(L, 4), radius = toNumber(L, 5, 30), area = toNumber(L, 6, 150);

	Core::getTaskManager()->executeTask([planet, x, y, radius, area]() {
		BotSiteCheck site;
		BotCity::checkSite(planet, x, y, radius, area, site);
	}, "BotCityDevProbe");

	return 0;
}

int BotCityLua::devProbeRing(lua_State* L) {
	String planet = toString(L, 2);
	float cx = toNumber(L, 3), cy = toNumber(L, 4), r1 = toNumber(L, 5, 2000), r2 = toNumber(L, 6, 2500), rStep = toNumber(L, 7, 250);
	float degStep = toNumber(L, 8, 15), radius = toNumber(L, 9, 30), area = toNumber(L, 10, 150);

	Core::getTaskManager()->executeTask([planet, cx, cy, r1, r2, rStep, degStep, radius, area]() {
		class Candidate : public Object {
		public:
			float x, y, r, bearing, score;
			BotSiteCheck site;
		};

		Vector<Candidate> good;
		int probes = 0;

		for (float r = r1; r <= r2 + 0.1f && rStep > 0; r += rStep) {
			for (float bearing = 0; bearing < 360 && degStep > 0; bearing += degStep) {
				float rad = bearing * Math::DEG2RAD;
				float x = cx + r * sin(rad);
				float y = cy + r * cos(rad);

				Candidate candidate;
				candidate.x = x;
				candidate.y = y;
				candidate.r = r;
				candidate.bearing = bearing;

				if (!BotCity::checkSite(planet, x, y, radius, area, candidate.site))
					return;

				++probes;

				if (!candidate.site.ok)
					continue;

				candidate.score = candidate.site.heightDiff + candidate.site.heightDiffArea / 4 + candidate.site.blocked * 50 + candidate.site.water * 100;

				int at = 0;

				while (at < good.size() && good.get(at).score <= candidate.score)
					++at;

				good.add(at, candidate);
			}
		}

		StringBuffer msg;
		msg << "probeRing " << planet << " around (" << (int)cx << ", " << (int)cy << "): " << probes << " probes, " << good.size() << " ok; best:";

		for (int i = 0; i < good.size() && i < 5; ++i) {
			const Candidate& c = good.get(i);

			msg << " | (" << (int)c.x << ", " << (int)c.y << ") r " << (int)c.r << " bearing " << (int)c.bearing << ": score " << (int)c.score
				<< ", diff " << (int)c.site.heightDiff << "/" << (int)c.site.heightDiffArea << " m, blocked " << (int)(c.site.blocked * 100)
				<< "%, water " << (int)(c.site.water * 100) << "%, z " << (int)c.site.z;
		}

		BotCity::log().info(true) << msg.toString();
	}, "BotCityDevProbeRing", "slowQueue");

	return 0;
}

// map:<planet>:<x0>:<y0>:<x1>:<y1>[:<step>]: an ASCII height map, north at the top, one log line per row
//   ~ water, # can't be built on, . ground below -150 (the sunken plains), : -150..0, 0-9 every 10 m up from 0 (9 is 90+)
int BotCityLua::devMap(lua_State* L) {
	String planet = toString(L, 2);
	float x0 = toNumber(L, 3), y0 = toNumber(L, 4), x1 = toNumber(L, 5), y1 = toNumber(L, 6), step = toNumber(L, 7, 100);

	Core::getTaskManager()->executeTask([planet, x0, y0, x1, y1, step]() {
		ZoneServer* zoneServer = ServerCore::getZoneServer();
		Zone* zone = zoneServer != nullptr ? zoneServer->getZone(planet) : nullptr;

		if (zone == nullptr || step < 5) {
			BotCity::log().warning() << "BotCityDev map: the planet " << planet << " isn't loaded, or the step is under 5 m";
			return;
		}

		PlanetManager* planetManager = zone->getPlanetManager();
		ProceduralTerrainAppearance* appearance = planetManager->getTerrainManager()->getProceduralTerrainAppearance();

		if (appearance != nullptr)
			BotCity::log().info(true) << "map " << planet << ": global water table " << (appearance->getUseGlobalWaterTable() ? "on" : "off") << " at "
				<< appearance->getGlobalWaterTableHeight() << " m";

		BotCity::log().info(true) << "map " << planet << " x " << (int)x0 << ".." << (int)x1 << " (columns, west to east), step " << (int)step << " m";

		for (float y = y1; y >= y0; y -= step) {
			StringBuffer row;

			for (float x = x0; x <= x1; x += step) {
				float z = zone->getHeight(x, y);

				if (planetManager->isInWater(x, y))
					row << '~';
				else if (!planetManager->isBuildingPermittedAt(x, y, nullptr))
					row << '#';
				else if (z < -150)
					row << '.';
				else if (z < 0)
					row << ':';
				else
					row << (char)('0' + Math::min(9, (int)(z / 10)));
			}

			BotCity::log().info(true) << "map " << (int)y << "\t" << row.toString();
		}
	}, "BotCityDevMap", "slowQueue");

	return 0;
}

// profile:<planet>:<x0>:<y0>:<x1>:<y1>[:<step>]: terrain height and water along a line, in one log line
int BotCityLua::devProfile(lua_State* L) {
	String planet = toString(L, 2);
	float x0 = toNumber(L, 3), y0 = toNumber(L, 4), x1 = toNumber(L, 5), y1 = toNumber(L, 6), step = toNumber(L, 7, 25);

	Core::getTaskManager()->executeTask([planet, x0, y0, x1, y1, step]() {
		ZoneServer* zoneServer = ServerCore::getZoneServer();
		Zone* zone = zoneServer != nullptr ? zoneServer->getZone(planet) : nullptr;

		if (zone == nullptr || step < 1)
			return;

		PlanetManager* planetManager = zone->getPlanetManager();
		float length = Math::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
		StringBuffer msg;

		msg << "profile " << planet << " (" << (int)x0 << ", " << (int)y0 << ") to (" << (int)x1 << ", " << (int)y1 << "), every " << (int)step << " m:";

		for (float d = 0; d <= length + 0.1f; d += step) {
			float x = x0 + (x1 - x0) * d / length, y = y0 + (y1 - y0) * d / length;

			msg << " " << (int)zone->getHeight(x, y) << (planetManager->isInWater(x, y) ? "w" : "");
		}

		BotCity::log().info(true) << msg.toString();
	}, "BotCityDevProfile", "slowQueue");

	return 0;
}

int BotCityLua::devInfo(lua_State* L) {
	String name = toString(L, 2);

	Core::getTaskManager()->executeTask([name]() {
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (city == nullptr)
			BotCity::log().info(true) << "BotCityDev info: no player city called " << name;
		else
			BotCity::log().info(true) << "BotCityDev info: " << describeCity(city);
	}, "BotCityDevInfo");

	return 0;
}

int BotCityLua::devOwned(lua_State* L) {
	String first = toString(L, 2);

	Core::getTaskManager()->executeTask([first]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr)
			return;

		Vector<BotStructureInfo> owned;
		BotCity::getOwnedStructures(bot, owned);

		StringBuffer msg;
		PlayerObject* ghost = bot->getPlayerObject();

		msg << "BotCityDev owned: " << bot->getFirstName() << " owns " << owned.size() << " structures, " << (ghost != nullptr ? ghost->getLotsRemaining() : 0)
			<< " lots left, residence " << (ghost != nullptr ? ghost->getDeclaredResidence() : 0);

		for (int i = 0; i < owned.size(); ++i) {
			const BotStructureInfo& info = owned.get(i);

			msg << " | " << info.kind << " " << info.templatePath << " " << info.oid << " at (" << (int)info.x << ", " << (int)info.y << ")"
				<< (info.city.isEmpty() ? String("") : " in " + info.city) << (info.residence ? " (residence)" : "");
		}

		BotCity::log().info(true) << msg.toString();
	}, "BotCityDevOwned");

	return 0;
}

int BotCityLua::devGrant(lua_State* L) {
	String first = toString(L, 2), skill = toString(L, 3);

	if (!BotCity::isDevAllowed("BotCityDev:grant"))
		return 0;

	Core::getTaskManager()->executeTask([first, skill]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr)
			return;

		Locker locker(bot);

		bool ok = SkillManager::instance()->awardSkill(skill, bot, true, true, true);

		BotCity::log().info(true) << "BotCityDev grant: " << bot->getFirstName() << " " << skill << ": " << (ok && bot->hasSkill(skill) ? "awarded" : "refused")
			<< ", skill points left " << (bot->getPlayerObject() != nullptr ? bot->getPlayerObject()->getSkillPoints() : 0);
	}, "BotCityDevGrant");

	return 0;
}

int BotCityLua::devSurrender(lua_State* L) {
	String first = toString(L, 2), prefix = toString(L, 3);

	if (prefix.isEmpty() || !BotCity::isDevAllowed("BotCityDev:surrender"))
		return 0;

	Core::getTaskManager()->executeTask([first, prefix]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr)
			return;

		Locker locker(bot);

		int removed = 0;

		// Boxes that others need refuse to go: repeat until nothing more goes
		for (int pass = 0; pass < 20; ++pass) {
			Vector<String> names;
			const SkillList* skills = bot->getSkillList();

			for (int i = 0; i < skills->size(); ++i) {
				const Skill* skill = skills->get(i);

				if (skill != nullptr && skill->getSkillName().beginsWith(prefix))
					names.add(skill->getSkillName());
			}

			int before = removed;

			for (int i = names.size() - 1; i >= 0; --i) {
				if (SkillManager::instance()->surrenderSkill(names.get(i), bot, true, false))
					++removed;
			}

			if (removed == before)
				break;
		}

		BotCity::log().info(true) << "BotCityDev surrender: " << bot->getFirstName() << " surrendered " << removed << " boxes starting " << prefix;
	}, "BotCityDevSurrender");

	return 0;
}

int BotCityLua::devBring(lua_State* L) {
	String first = toString(L, 2);
	float x = toNumber(L, 3), y = toNumber(L, 4);

	if (!BotCity::isDevAllowed("BotCityDev:bring"))
		return 0;

	Core::getTaskManager()->executeTask([first, x, y]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr || bot->getZone() == nullptr)
			return;

		Locker locker(bot);

		float z = CollisionManager::getWorldFloorCollision(x, y, bot->getZone(), false);

		bot->teleport(x, z, y, 0);

		BotCity::log().info(true) << "BotCityDev bring: " << bot->getFirstName() << " to (" << (int)x << ", " << (int)y << ") z " << (int)z << " on " << bot->getZone()->getZoneName();
	}, "BotCityDevBring");

	return 0;
}

int BotCityLua::devFound(lua_State* L) {
	String first = toString(L, 2), name = toString(L, 6);
	float x = toNumber(L, 3), y = toNumber(L, 4);
	int angle = (int)toNumber(L, 5);

	if (!BotCity::isDevAllowed("BotCityDev:found"))
		return 0;

	Core::getTaskManager()->executeTask([first, x, y, angle, name]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr)
			return;

		uint64 oid = BotCity::foundCity(bot, x, y, angle, name);

		BotCity::log().info(true) << "BotCityDev found: " << name << " -> " << oid;
	}, "BotCityDevFound");

	return 0;
}

int BotCityLua::devHouse(lua_State* L) {
	String first = toString(L, 2), deedTemplate = toString(L, 3);
	float x = toNumber(L, 4), y = toNumber(L, 5);
	int angle = (int)toNumber(L, 6);

	if (!BotCity::isDevAllowed("BotCityDev:house"))
		return 0;

	Core::getTaskManager()->executeTask([first, deedTemplate, x, y, angle]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr)
			return;

		Locker locker(bot);

		// As Lua's giveItem(pInventory, template, -1) does
		ZoneServer* zoneServer = bot->getZoneServer();
		ManagedReference<SceneObject*> inventory = bot->getSlottedObject("inventory");
		ManagedReference<SceneObject*> deed = inventory != nullptr ? zoneServer->createObject(deedTemplate.hashCode(), 1) : nullptr;

		if (deed == nullptr || !deed->isTangibleObject() || deed.castTo<StructureDeed*>() == nullptr) {
			BotCity::log().warning() << "BotCityDev house: " << deedTemplate << " isn't a structure deed";

			if (deed != nullptr)
				deed->destroyObjectFromDatabase(true);

			return;
		}

		Locker dlocker(deed, bot);

		if (!inventory->transferObject(deed, -1, true, true)) {
			deed->destroyObjectFromDatabase(true);
			return;
		}

		dlocker.release();

		BotCity::log().info(true) << "BotCityDev house: gave " << bot->getFirstName() << " " << deedTemplate << " (" << deed->getObjectID() << ")";

		BotCity::placeStructure(bot, deed->getObjectID(), x, y, angle);
	}, "BotCityDevHouse");

	return 0;
}

int BotCityLua::devDeclare(lua_State* L) {
	String first = toString(L, 2);
	uint64 oid = toOid(L, 3);

	if (!BotCity::isDevAllowed("BotCityDev:declare"))
		return 0;

	Core::getTaskManager()->executeTask([first, oid]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot == nullptr)
			return;

		uint64 target = oid;

		if (target == 0) {
			Vector<BotStructureInfo> owned;
			BotCity::getOwnedStructures(bot, owned);

			for (int i = 0; i < owned.size() && target == 0; ++i) {
				if (owned.get(i).kind == "house")
					target = owned.get(i).oid;
			}
		}

		BotCity::declareResidence(bot, target);
	}, "BotCityDevDeclare");

	return 0;
}

int BotCityLua::devExpand(lua_State* L) {
	String name = toString(L, 2);
	bool update = toBoolean(L, 3, false);

	Core::getTaskManager()->executeTask([name, update]() {
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (city == nullptr)
			BotCity::log().warning() << "BotCityDev expand: no player city called " << name;
		else
			BotCity::expand(city, update);
	}, "BotCityDevExpand");

	return 0;
}

int BotCityLua::devDeposit(lua_State* L) {
	String name = toString(L, 2);
	int credits = (int)toNumber(L, 3);

	if (!BotCity::isDevAllowed("BotCityDev:deposit"))
		return 0;

	Core::getTaskManager()->executeTask([name, credits]() {
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (city == nullptr)
			BotCity::log().warning() << "BotCityDev deposit: no player city called " << name;
		else
			BotCity::deposit(city, credits, nullptr);
	}, "BotCityDevDeposit");

	return 0;
}

int BotCityLua::devDecorate(lua_State* L) {
	String first = toString(L, 2), templatePath = toString(L, 3);

	if (!BotCity::isDevAllowed("BotCityDev:decorate"))
		return 0;

	Core::getTaskManager()->executeTask([first, templatePath]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot != nullptr)
			BotCity::placeDecoration(bot, templatePath);
	}, "BotCityDevDecorate");

	return 0;
}

// zoning:<city>:<on|off>, tax:<city>:<index>:<value>, spec:<city>:<spec>, register:<city>[:off]
int BotCityLua::devMayor(lua_State* L, int control) {
	String name = toString(L, 2), a = toString(L, 3), b = toString(L, 4);

	if (!BotCity::isDevAllowed("BotCityDev mayor controls"))
		return 0;

	Core::getTaskManager()->executeTask([name, a, b, control]() {
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (city == nullptr) {
			BotCity::log().warning() << "BotCityDev: no player city called " << name;
			return;
		}

		String value = a.toLowerCase();
		bool ok = false;

		switch (control) {
		case MAYOR_ZONING:
			ok = BotCity::setZoning(city, value == "on" || value == "true");
			break;
		case MAYOR_TAX:
			ok = BotCity::setTax(city, Integer::valueOf(a), Integer::valueOf(b));
			break;
		case MAYOR_SPEC:
			ok = BotCity::setSpecialization(city, a);
			break;
		case MAYOR_REGISTER:
			ok = BotCity::setRegistered(city, value != "off" && value != "false");
			break;
		}

		BotCity::log().info(true) << "BotCityDev mayor control " << control << " on " << name << " (" << a << " " << b << "): " << (ok ? "queued" : "refused");
	}, "BotCityDevMayor");

	return 0;
}

int BotCityLua::devZoning(lua_State* L) {
	return devMayor(L, MAYOR_ZONING);
}

int BotCityLua::devTax(lua_State* L) {
	return devMayor(L, MAYOR_TAX);
}

int BotCityLua::devSpec(lua_State* L) {
	return devMayor(L, MAYOR_SPEC);
}

int BotCityLua::devRegister(lua_State* L) {
	return devMayor(L, MAYOR_REGISTER);
}

int BotCityLua::devCandidate(lua_State* L) {
	String first = toString(L, 2), name = toString(L, 3);

	if (!BotCity::isDevAllowed("BotCityDev:candidate"))
		return 0;

	Core::getTaskManager()->executeTask([first, name]() {
		Reference<CreatureObject*> bot = getDevBot(first);
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (bot != nullptr && city != nullptr)
			BotCity::registerCandidate(bot, city);
	}, "BotCityDevCandidate");

	return 0;
}

int BotCityLua::devVote(lua_State* L) {
	String first = toString(L, 2), name = toString(L, 3), candidate = toString(L, 4);

	if (!BotCity::isDevAllowed("BotCityDev:vote"))
		return 0;

	Core::getTaskManager()->executeTask([first, name, candidate]() {
		Reference<CreatureObject*> bot = getDevBot(first);
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (bot == nullptr || city == nullptr)
			return;

		uint64 oid = 0;

		if (candidate != "0") {
			Reference<CreatureObject*> who = BotManager::instance()->getOnlineBot(candidate);
			oid = who != nullptr ? who->getObjectID() : UnsignedLong::valueOf(candidate);
		}

		BotCity::castVote(bot, city, oid);
	}, "BotCityDevVote");

	return 0;
}

int BotCityLua::devDestroy(lua_State* L) {
	String name = toString(L, 2);

	Core::getTaskManager()->executeTask([name]() {
		Reference<CityRegion*> city = BotCity::findCity(name);

		if (city == nullptr)
			BotCity::log().warning() << "BotCityDev destroy: no player city called " << name;
		else
			BotCity::destroyCity(city);
	}, "BotCityDevDestroy");

	return 0;
}

int BotCityLua::devRaze(lua_State* L) {
	String first = toString(L, 2);

	Core::getTaskManager()->executeTask([first]() {
		Reference<CreatureObject*> bot = getDevBot(first);

		if (bot != nullptr)
			BotCity::log().info(true) << "BotCityDev raze: " << BotCity::destroyOwnedStructures(bot) << " of " << bot->getFirstName() << "'s structures";
	}, "BotCityDevRaze");

	return 0;
}
