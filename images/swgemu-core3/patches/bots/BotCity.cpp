/*
 * BotCity (Phase 6 bot players' city). See BotCity.h.
 */

#include "BotCity.h"
#include "BotManager.h"
#include "BotChat.h"
#include "BotLua.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/ZoneProcessServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/player/FactionStatus.h"
#include "server/zone/objects/scene/SessionFacadeType.h"
#include "server/zone/objects/area/ActiveArea.h"
#include "server/zone/objects/region/Region.h"
#include "server/zone/objects/region/CityRegion.h"
#include "server/zone/objects/region/CitizenList.h"
#include "server/zone/objects/structure/StructureObject.h"
#include "server/zone/objects/building/BuildingObject.h"
#include "server/zone/objects/tangible/TangibleObject.h"
#include "server/zone/objects/tangible/deed/structure/StructureDeed.h"
#include "server/zone/objects/transaction/TransactionLog.h"
#include "server/zone/managers/city/CityManager.h"
#include "server/zone/managers/city/CitySpecialization.h"
#include "server/zone/managers/city/CityTax.h"
#include "server/zone/managers/structure/StructureManager.h"
#include "server/zone/managers/planet/PlanetManager.h"
#include "server/zone/managers/name/NameManager.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "server/zone/objects/pathfinding/NavArea.h"
#include "templates/tangible/SharedStructureObjectTemplate.h"
#include "templates/tangible/StructureDeedTemplate.h"
#include "templates/manager/TemplateManager.h"
#include "templates/faction/Factions.h"
#include "terrain/manager/TerrainManager.h"
#include "terrain/layer/boundaries/BoundaryRectangle.h"
#include "conf/ConfigManager.h"

namespace {

// Player cities by lower-case name -> object id: filled from the cityregions database and by founding (a new city is
// only written to the database at the next save)
Mutex cityMutex;
VectorMap<String, uint64> cityOids;
Time lastScan;
bool scanned = false;

const int RESCAN_MS = 30 * 1000;	// a lookup that misses rescans the database at most this often

// The next election per city id (ms since the epoch), read from the city's own record in a task of its own
Mutex electionMutex;
VectorMap<uint64, uint64> electionTimes;
VectorMap<uint64, uint64> electionRead;		// when each was read (ms)

const int ELECTION_REFRESH_MS = 60 * 1000;

// pre: cityMutex locked
void scanCityDatabase() {
	cityOids.setAllowOverwriteInsertPlan();

	ObjectDatabase* database = ObjectDatabaseManager::instance()->loadObjectDatabase("cityregions", true);

	if (database == nullptr)
		return;

	try {
		ObjectDatabaseIterator iterator(database);
		uint64 oid = 0;

		while (iterator.getNextKey(oid)) {
			Reference<CityRegion*> city = Core::getObjectBroker()->lookUp(oid).castTo<CityRegion*>();

			if (city == nullptr || city->isClientRegion() || city->getZone() == nullptr)
				continue;

			cityOids.put(city->getCityRegionName().toLowerCase(), oid);
		}
	} catch (const Exception& e) {
		BotCity::log().error() << "reading the cityregions database: " << e.getMessage();
	}

	lastScan.updateToCurrentTime();
	scanned = true;
}

Reference<CityRegion*> lookUpCity(uint64 oid) {
	Reference<CityRegion*> city = Core::getObjectBroker()->lookUp(oid).castTo<CityRegion*>();

	if (city == nullptr || city->isClientRegion() || city->getZone() == nullptr)
		return nullptr;

	return city;
}

String formatPosition(float x, float y) {
	StringBuffer buffer;
	buffer << "(" << (int)x << ", " << (int)y << ")";

	return buffer.toString();
}

// The city hall deed whose building is allowed on this planet
String getCityHallDeed(const String& planet) {
	static const char* deeds[] = {
		"object/tangible/deed/city_deed/cityhall_naboo_deed.iff",
		"object/tangible/deed/city_deed/cityhall_corellia_deed.iff",
		"object/tangible/deed/city_deed/cityhall_tatooine_deed.iff",
	};

	TemplateManager* templateManager = TemplateManager::instance();

	for (const char* deed : deeds) {
		StructureDeedTemplate* deedTemplate = dynamic_cast<StructureDeedTemplate*>(templateManager->getTemplate(String(deed).hashCode()));

		if (deedTemplate == nullptr)
			continue;

		SharedStructureObjectTemplate* building = dynamic_cast<SharedStructureObjectTemplate*>(templateManager->getTemplate(deedTemplate->getGeneratedObjectTemplate().hashCode()));

		if (building != nullptr && building->isAllowedZone(planet))
			return deed;
	}

	return "";
}

String getPlacementComponent(StructureDeed* deed) {
	StructureDeedTemplate* deedTemplate = dynamic_cast<StructureDeedTemplate*>(deed->getObjectTemplate());

	return deedTemplate != nullptr ? deedTemplate->getStructurePlacementComponent() : "";
}

// The player city or NPC city whose region covers this point, or nullptr
Reference<CityRegion*> getCityAt(Zone* zone, float x, float y) {
	SortedVector<ManagedReference<ActiveArea*>> areas;
	zone->getInRangeActiveAreas(x, 0, y, &areas, true);

	for (int i = 0; i < areas.size(); ++i) {
		ActiveArea* area = areas.get(i).get();

		if (area == nullptr || !area->isRegion())
			continue;

		Reference<CityRegion*> city = cast<Region*>(area)->getCityRegion().get();

		if (city != nullptr)
			return city;
	}

	return nullptr;
}

// StructureManager::placeStructureFromDeed's footprint test: the structure that would overlap, or nullptr
Reference<SceneObject*> findFootprintOverlap(Zone* zone, SharedStructureObjectTemplate* serverTemplate, float x, float y, int angleDegrees) {
	StructureManager* structureManager = StructureManager::instance();

	float length0 = 0, width0 = 0, length1 = 0, width1 = 0;

	if (structureManager->getStructureFootprint(serverTemplate, angleDegrees, length0, width0, length1, width1))
		return nullptr;

	float x0 = x + width0;
	float y0 = y + length0;
	float x1 = x + width1;
	float y1 = y + length1;

	BoundaryRectangle placingFootprint(x0, y0, x1, y1);

	SortedVector<ManagedReference<TreeEntry*>> inRangeObjects;
	zone->getInRangeObjects(x, 0, y, 128, &inRangeObjects, true, false);

	for (int i = 0; i < inRangeObjects.size(); ++i) {
		SceneObject* scene = inRangeObjects.get(i).castTo<SceneObject*>();

		if (scene == nullptr)
			continue;

		float l0 = -5, w0 = -5, l1 = 5, w1 = 5;

		if (structureManager->getStructureFootprint(dynamic_cast<SharedStructureObjectTemplate*>(scene->getObjectTemplate()), scene->getDirectionAngle(), l0, w0, l1, w1))
			continue;

		float xx0 = scene->getPositionX() + (w0 + 0.1);
		float yy0 = scene->getPositionY() + (l0 + 0.1);
		float xx1 = scene->getPositionX() + (w1 - 0.1);
		float yy1 = scene->getPositionY() + (l1 - 0.1);

		BoundaryRectangle rect(xx0, yy0, xx1, yy1);

		if (rect.containsPoint(x0, y0) || rect.containsPoint(x0, y1) || rect.containsPoint(x1, y0) || rect.containsPoint(x1, y1))
			return scene;

		if (placingFootprint.containsPoint(xx0, yy0) || placingFootprint.containsPoint(xx0, yy1) || placingFootprint.containsPoint(xx1, yy0)
				|| placingFootprint.containsPoint(xx1, yy1) || (xx0 == x0 && yy0 == y0 && xx1 == x1 && yy1 == y1))
			return scene;
	}

	return nullptr;
}

String describeObject(SceneObject* object) {
	StringBuffer buffer;
	buffer << object->getDisplayedName() << " (" << object->getObjectID() << ") at " << formatPosition(object->getWorldPositionX(), object->getWorldPositionY());

	return buffer.toString();
}

// PlaceStructureCommand, the deed's component and StructureManager::placeStructureFromDeed, in their order.
// cityHall: the city hall deed placed by foundCity, which skips the component's name window. Bot locked
String checkPlacementInternal(CreatureObject* bot, StructureDeed* deed, float x, float y, int angle, bool cityHall) {
	if (bot == nullptr || deed == nullptr)
		return "no bot or no deed";

	Zone* zone = bot->getZone();
	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerObject* ghost = bot->getPlayerObject();

	if (zone == nullptr || zoneServer == nullptr || ghost == nullptr)
		return "the bot isn't in the world";

	PlanetManager* planetManager = zone->getPlanetManager();
	CityManager* cityManager = zoneServer->getCityManager();
	StringBuffer reason;

	// PlaceStructureCommand::doQueueCommand
	if (bot->isRidingMount())
		return "mounted";

	if (bot->getParent().get() != nullptr)
		return "inside a building (the command needs the bot outdoors)";

	ManagedReference<CityRegion*> standingCity = bot->getCityRegion().get();

	if (standingCity != nullptr && standingCity->isClientRegion())
		return "standing in " + standingCity->getRegionDisplayedName() + ", an NPC city";

	if (angle < 0 || angle > 3)
		return "the angle must be 0-3";

	float placeZ = CollisionManager::getWorldFloorCollision(x, y, zone, false);
	Vector3 placement(x, y, placeZ);
	Vector3 position = bot->getPosition();
	float distance = placement.distanceTo(position);
	float heightDiff = position.getZ() - placeZ;

	if (distance > 100.f || heightDiff > 10.f) {
		reason << "out of range: the bot is " << (int)distance << " m from the spot and " << (int)heightDiff
			<< " m above it (the command allows 100 m and 10 m)";
		return reason.toString();
	}

	SortedVector<ManagedReference<ActiveArea*>> areas;
	zone->getInRangeActiveAreas(x, placeZ, y, &areas, true);

	for (int i = 0; i < areas.size(); ++i) {
		ActiveArea* area = areas.get(i).get();

		if (area != nullptr && area->isNoBuildZone())
			return "in the no-build area " + area->getAreaName();
	}

	Reference<SceneObject*> conflict = planetManager->findObjectInNoBuildZone(x, y, 0.f);

	if (conflict != nullptr)
		return "too close to " + describeObject(conflict);

	// The deed's placement component
	String component = getPlacementComponent(deed);

	if (component == "PlaceCityHallComponent" && !cityHall)
		return "a city hall deed: found the city with botFoundCity";

	if (component == "PlaceGCWBaseComponent")
		return "a faction base deed (not supported)";

	if (component == "PlaceDecorationComponent") {
		if (standingCity == nullptr)
			return "a city decoration: the bot must stand inside the city";

		if (!cityManager->canSupportMoreDecorations(standingCity))
			return "the city can't support more decorations at its rank";
	}

	// StructureManager::placeStructureFromDeed
	if (bot->containsActiveSession(SessionFacadeType::PLACESTRUCTURE))
		return "already placing a structure";

	if (deed->getFaction() != Factions::FACTIONNEUTRAL && (bot->getFaction() != deed->getFaction() || bot->getFactionStatus() == FactionStatus::ONLEAVE))
		return "a faction deed of another faction";

	String serverTemplatePath = deed->getGeneratedObjectTemplate();
	SharedStructureObjectTemplate* serverTemplate = dynamic_cast<SharedStructureObjectTemplate*>(TemplateManager::instance()->getTemplate(serverTemplatePath.hashCode()));

	if (serverTemplate == nullptr)
		return "the deed's structure template " + serverTemplatePath + " doesn't exist";

	if (!serverTemplate->isAllowedZone(zone->getZoneName()))
		return serverTemplatePath + " isn't allowed on " + zone->getZoneName();

	if (!planetManager->isBuildingPermittedAt(x, y, bot)) {
		if (!zone->isWithinBoundaries(Vector3(x, y, 0)))
			return "outside the planet's boundaries";

		if (planetManager->isInWater(x, y))
			return "in water";

		if (planetManager->isInRangeWithPoi(x, y, 150))
			return "within 150 m of a point of interest";

		Reference<SceneObject*> object = planetManager->findObjectInNoBuildZone(x, y, 0.f, true);

		if (object != nullptr)
			return "in the no-build zone or footprint of " + describeObject(object);

		return "building is not permitted here";
	}

	Reference<CityRegion*> city = getCityAt(zone, x, y);

	if (city != nullptr && city->isClientRegion())
		return "inside " + city->getRegionDisplayedName() + ", an NPC city";

	Reference<SceneObject*> overlap = findFootprintOverlap(zone, serverTemplate, x, y, angle * 90);

	if (overlap != nullptr)
		return "no room: the footprint overlaps " + describeObject(overlap);

	int rankRequired = serverTemplate->getCityRankRequired();

	if (city == nullptr && rankRequired > 0)
		return "needs to stand inside a player city";

	if (city != nullptr) {
		if (city->isZoningEnabled() && !city->hasZoningRights(bot->getObjectID()))
			return city->getCityRegionName() + " has zoning on and the bot has no zoning rights";

		if (rankRequired != 0 && city->getCityRank() < rankRequired) {
			reason << city->getCityRegionName() << " is rank " << city->getCityRank() << "; this needs rank " << rankRequired;
			return reason.toString();
		}

		if (serverTemplate->isCivicStructure() && !city->isMayor(bot->getObjectID()))
			return "a civic structure, and the bot isn't the mayor of " + city->getCityRegionName();

		if (serverTemplate->isUniqueStructure() && city->hasUniqueStructure(serverTemplate->getServerObjectCRC()))
			return city->getCityRegionName() + " already has one (a unique structure)";
	}

	if (!deed->isASubChildOf(bot))
		return "the deed isn't in the bot's inventory";

	const String& abilityRequired = serverTemplate->getAbilityRequired();

	if (!abilityRequired.isEmpty() && !ghost->hasAbility(abilityRequired))
		return "lacks the ability " + abilityRequired;

	int lots = serverTemplate->getLotSize();

	if (!ghost->hasLotsRemaining(lots)) {
		reason << "not enough lots: needs " << lots << ", has " << ghost->getLotsRemaining();
		return reason.toString();
	}

	return "";
}

// A structure the bot owns, of this template, standing at (x, y), that wasn't in `before`
Reference<StructureObject*> findPlacedStructure(CreatureObject* bot, const String& templatePath, float x, float y, const Vector<uint64>& before) {
	PlayerObject* ghost = bot->getPlayerObject();
	ZoneServer* zoneServer = bot->getZoneServer();

	if (ghost == nullptr || zoneServer == nullptr)
		return nullptr;

	for (int i = 0; i < ghost->getTotalOwnedStructureCount(); ++i) {
		uint64 oid = ghost->getOwnedStructure(i);

		if (before.contains(oid))
			continue;

		Reference<StructureObject*> structure = zoneServer->getObject(oid).castTo<StructureObject*>();

		if (structure == nullptr || structure->getObjectTemplate() == nullptr)
			continue;

		if (structure->getObjectTemplate()->getFullTemplateString() != templatePath)
			continue;

		float dx = structure->getPositionX() - x;
		float dy = structure->getPositionY() - y;

		if (dx * dx + dy * dy < 4.f)
			return structure;
	}

	return nullptr;
}

void tellJobs(CreatureObject* bot, const String& name, SceneObject* other, const String& detail) {
	// pre: bot locked, in a task
	if (BotManager::instance()->isOnlineBot(bot))
		BotLua::callEvent(bot, name, other, detail);
}

// A city's navmesh name, as CityRegionImplementation::createNavMesh makes it
String getNavMeshName(CityRegion* city) {
	String name = city->getCityRegionName();

	if (name.contains(":"))
		name = name.subString(name.lastIndexOf(':') + 1);

	Zone* zone = city->getZone();

	return (zone != nullptr ? zone->getZoneName() : String("")) + "_city_" + name + "_player";
}

// After founding: the city hall should stand within a second or two; then time the navmesh build
void watchFounding(uint64 cityOid, uint64 mayorOid, uint64 deedOid, uint64 startedMs, int checks) {
	Core::getTaskManager()->scheduleTask([cityOid, mayorOid, deedOid, startedMs, checks]() {
		Reference<CityRegion*> city = lookUpCity(cityOid);

		if (city == nullptr)
			return;

		Time now;
		uint64 elapsed = now.getMiliTime() - startedMs;
		ManagedReference<StructureObject*> hall = city->getCityHall();

		if (hall == nullptr) {
			if (elapsed < 15000) {
				watchFounding(cityOid, mayorOid, deedOid, startedMs, checks + 1);
				return;
			}

			BotCity::log().error() << "foundCity: " << city->getCityRegionName() << " has no city hall " << elapsed
				<< " ms after founding; destroying it so the mayor can try again";

			ZoneServer* zoneServer = ServerCore::getZoneServer();
			CityManager* cityManager = zoneServer != nullptr ? zoneServer->getCityManager() : nullptr;

			if (cityManager != nullptr)
				cityManager->destroyCity(city);

			ManagedReference<SceneObject*> deed = zoneServer != nullptr ? zoneServer->getObject(deedOid) : nullptr;

			if (deed != nullptr) {
				Locker locker(deed);

				deed->destroyObjectFromWorld(true);
				deed->destroyObjectFromDatabase(true);
			}

			return;
		}

		if (checks >= 0) {
			BotCity::log().info(true) << "foundCity: " << city->getCityRegionName() << "'s city hall stands: " << hall->getObjectID()
				<< " at " << formatPosition(hall->getPositionX(), hall->getPositionY()) << ", " << elapsed << " ms after founding; mayor "
				<< city->getMayorID() << ", citizens " << city->getCitizenCount();
		}

		// The navmesh: CityRegion::createNavMesh queued it when the hall was placed
		Zone* zone = city->getZone();
		Reference<NavArea*> mesh = zone != nullptr ? zone->getPlanetManager()->getNavArea(getNavMeshName(city)) : nullptr;

		if (mesh != nullptr && mesh->isNavMeshLoaded()) {
			BotCity::log().info(true) << "foundCity: " << city->getCityRegionName() << "'s navmesh " << mesh->getMeshName()
				<< " is built, " << elapsed << " ms after founding";
			return;
		}

		if (elapsed > 30 * 60 * 1000) {
			BotCity::log().warning() << "foundCity: " << city->getCityRegionName() << "'s navmesh isn't built after 30 minutes";
			return;
		}

		watchFounding(cityOid, mayorOid, deedOid, startedMs, -1);
	}, "BotCityWatchFounding", checks >= 0 ? 1000 : 2000);
}

// Reads the next election from the city's record (it has no getter), in a task that holds nothing else
void refreshElectionTime(uint64 cityOid) {
	Core::getTaskManager()->executeTask([cityOid]() {
		Reference<CityRegion*> city = lookUpCity(cityOid);

		if (city == nullptr)
			return;

		uint64 next = 0;

		try {
			JSONSerializationType json;

			{
				Locker locker(city);

				city->writeJSON(json);
			}

			auto region = json.find("CityRegion");

			if (region != json.end() && region->is_object()) {
				auto inauguration = region->find("nextInauguration");

				if (inauguration != region->end() && inauguration->is_number())
					next = inauguration->get<uint64>();
			}
		} catch (const std::exception& e) {
			BotCity::log().error() << "reading " << cityOid << "'s election time: " << e.what();
		}

		Time now;
		Locker locker(&electionMutex);

		electionTimes.put(cityOid, next);
		electionRead.put(cityOid, now.getMiliTime());
	}, "BotCityElectionTime");
}

// Runs `step` every `interval` ms until it returns true
class RepeatUntilTask : public Task {
	std::function<bool()> step;
	int interval;

public:
	RepeatUntilTask(const std::function<bool()>& step, const char* name, int interval) : step(step), interval(interval) {
		setTaskName(name);
	}

	void run() {
		if (!step())
			reschedule(interval);
	}
};

bool hasSpecializationAbility(PlayerObject* ghost, const String& spec) {
	// "@city/city:city_spec_entertainer" -> the ability "city_spec_entertainer"
	String ability = spec.subString(spec.indexOf(':') + 1);

	return ghost->hasAbility(ability);
}

}

Logger& BotCity::log() {
	static Logger logger("BotCity");

	return logger;
}

bool BotCity::isDevAllowed(const char* what) {
	static const bool devTools = ConfigManager::instance()->getBool("Core3.BotCity.DevTools", false);

	if (devTools || BotManager::instance()->isDevHuman())
		return true;

	log().warning() << what << " is a dev tool: turn it on with botSetDevHuman(true) (BotJobs:devHuman:on) on the local server";

	return false;
}

// --- Lookups ---

void BotCity::rememberCity(CityRegion* city) {
	Locker locker(&cityMutex);

	cityOids.setAllowOverwriteInsertPlan();
	cityOids.put(city->getCityRegionName().toLowerCase(), city->getObjectID());
}

Reference<CityRegion*> BotCity::findCity(const String& name) {
	if (name.isEmpty())
		return nullptr;

	String key = name.toLowerCase();
	Locker locker(&cityMutex);

	for (int pass = 0; pass < 2; ++pass) {
		if (cityOids.contains(key)) {
			Reference<CityRegion*> city = lookUpCity(cityOids.get(key));

			if (city != nullptr && city->getCityRegionName().toLowerCase() == key)
				return city;

			cityOids.drop(key);
		}

		if (pass == 0 && (!scanned || lastScan.miliDifference() > RESCAN_MS))
			scanCityDatabase();
		else
			break;
	}

	// Renamed since it was cached: the slow way, through every known city
	for (int i = 0; i < cityOids.size(); ++i) {
		Reference<CityRegion*> city = lookUpCity(cityOids.elementAt(i).getValue());

		if (city != nullptr && city->getCityRegionName().toLowerCase() == key)
			return city;
	}

	return nullptr;
}

void BotCity::getPlayerCities(Vector<Reference<CityRegion*>>& out) {
	Locker locker(&cityMutex);

	scanCityDatabase();

	for (int i = 0; i < cityOids.size(); ++i) {
		Reference<CityRegion*> city = lookUpCity(cityOids.elementAt(i).getValue());

		if (city != nullptr && !out.contains(city))
			out.add(city);
	}
}

Reference<CityRegion*> BotCity::getResidenceCity(CreatureObject* creature) {
	if (creature == nullptr)
		return nullptr;

	PlayerObject* ghost = creature->getPlayerObject();
	ZoneServer* zoneServer = creature->getZoneServer();

	if (ghost == nullptr || zoneServer == nullptr || ghost->getDeclaredResidence() == 0)
		return nullptr;

	Reference<BuildingObject*> residence = zoneServer->getObject(ghost->getDeclaredResidence()).castTo<BuildingObject*>();

	if (residence == nullptr)
		return nullptr;

	Reference<CityRegion*> city = residence->getCityRegion().get();

	if (city == nullptr || city->isClientRegion())
		return nullptr;

	return city;
}

int BotCity::getWeeklyUpkeep(CityRegion* city) {
	if (city == nullptr || city->getCityRank() < 1)
		return 0;

	int rankIndex = city->getCityRank() - 1;
	float discount = CityManagerImplementation::maintenanceDiscount;
	int total = 0;

	ManagedReference<StructureObject*> hall = city->getCityHall();
	SharedStructureObjectTemplate* hallTemplate = hall != nullptr ? dynamic_cast<SharedStructureObjectTemplate*>(hall->getObjectTemplate()) : nullptr;

	if (hallTemplate != nullptr)
		total += discount * hallTemplate->getCityMaintenanceAtRank(rankIndex);

	for (int i = 0; i < city->getStructuresCount(); ++i) {
		ManagedReference<StructureObject*> structure = city->getCivicStructure(i);

		if (structure == nullptr || structure == hall)
			continue;

		SharedStructureObjectTemplate* structureTemplate = dynamic_cast<SharedStructureObjectTemplate*>(structure->getObjectTemplate());

		if (structureTemplate != nullptr)
			total += discount * structureTemplate->getCityMaintenanceAtRank(rankIndex);
	}

	for (int i = 0; i < city->getDecorationCount(); ++i) {
		ManagedReference<SceneObject*> decoration = city->getCityDecoration(i);

		if (decoration == nullptr)
			continue;

		SharedStructureObjectTemplate* structureTemplate = decoration->isStructureObject() ? dynamic_cast<SharedStructureObjectTemplate*>(decoration->getObjectTemplate()) : nullptr;

		total += structureTemplate != nullptr ? discount * structureTemplate->getCityMaintenanceAtRank(rankIndex) : discount * 1500;
	}

	total += discount * 1500 * (city->getMissionTerminalCount() + city->getSkillTrainerCount());

	if (city->isRegistered())
		total += discount * 5000;

	if (!city->getCitySpecialization().isEmpty()) {
		ZoneServer* zoneServer = ServerCore::getZoneServer();
		const CitySpecialization* spec = zoneServer != nullptr ? zoneServer->getCityManager()->getCitySpecialization(city->getCitySpecialization()) : nullptr;

		if (spec != nullptr)
			total += discount * spec->getCost();
	}

	return total;
}

int BotCity::getSecondsToElection(CityRegion* city) {
	if (city == nullptr)
		return -1;

	uint64 oid = city->getObjectID();
	uint64 next = 0;
	bool stale = true;
	Time now;

	{
		Locker locker(&electionMutex);

		if (electionTimes.contains(oid)) {
			next = electionTimes.get(oid);
			stale = now.getMiliTime() - electionRead.get(oid) > ELECTION_REFRESH_MS;
		}
	}

	if (stale)
		refreshElectionTime(oid);

	if (next == 0)
		return -1;

	// The election runs at the first weekly update on or after the end of the voting period
	int64 untilEnd = ((int64)next - (int64)now.getMiliTime()) / 1000;
	int64 seconds = city->getTimeToUpdate();
	int64 interval = (int64)CityManagerImplementation::cityUpdateInterval * 60;

	if (seconds < 0)
		seconds = 0;

	for (int i = 0; i < 10 && seconds < untilEnd && interval > 0; ++i)
		seconds += interval;

	return (int)seconds;
}

String BotCity::getStructureKind(StructureObject* structure, CityRegion* city) {
	if (structure == nullptr)
		return "other";

	if (city != nullptr && city->getCityHall() == structure)
		return "cityhall";

	if (structure->isCivicStructure())
		return "civic";

	if (structure->isCommercialStructure())
		return "commercial";

	if (structure->isBuildingObject())
		return "house";

	return "other";
}

void BotCity::getStructureInfo(StructureObject* structure, BotStructureInfo& out) {
	out.oid = structure->getObjectID();
	out.templatePath = structure->getObjectTemplate() != nullptr ? structure->getObjectTemplate()->getFullTemplateString() : "";
	out.name = structure->getDisplayedName();
	out.x = structure->getPositionX();
	out.y = structure->getPositionY();

	Reference<CityRegion*> city = structure->getCityRegion().get();

	out.city = city != nullptr && !city->isClientRegion() ? city->getCityRegionName() : "";
	out.kind = getStructureKind(structure, city);
	out.residence = structure->isBuildingObject() && cast<BuildingObject*>(structure)->isResidence();
}

void BotCity::getOwnedStructures(CreatureObject* creature, Vector<BotStructureInfo>& out) {
	PlayerObject* ghost = creature != nullptr ? creature->getPlayerObject() : nullptr;
	ZoneServer* zoneServer = creature != nullptr ? creature->getZoneServer() : nullptr;

	if (ghost == nullptr || zoneServer == nullptr)
		return;

	for (int i = 0; i < ghost->getTotalOwnedStructureCount(); ++i) {
		Reference<StructureObject*> structure = zoneServer->getObject(ghost->getOwnedStructure(i)).castTo<StructureObject*>();

		if (structure == nullptr)
			continue;

		BotStructureInfo info;
		getStructureInfo(structure, info);
		out.add(info);
	}
}

String BotCity::normalizeSpecialization(const String& spec) {
	String value = spec.trim().toLowerCase();

	if (value.isEmpty() || value == "none" || value == "null")
		return "";

	if (value.beginsWith("@city/city:"))
		return value;

	if (value.beginsWith("city_spec_"))
		return "@city/city:" + value;

	return "@city/city:city_spec_" + value;
}

// --- Sites and placement ---

bool BotCity::checkSite(const String& planet, float x, float y, float radius, float areaRadius, BotSiteCheck& out) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	Zone* zone = zoneServer != nullptr ? zoneServer->getZone(planet) : nullptr;

	if (zone == nullptr) {
		log().error() << "checkSite: the planet " << planet << " isn't loaded";
		return false;
	}

	PlanetManager* planetManager = zone->getPlanetManager();
	TerrainManager* terrain = planetManager->getTerrainManager();

	radius = Math::max(radius, 4.f);
	areaRadius = Math::max(areaRadius, radius);

	StringBuffer reason;

	// The centre: what PlaceCityHallSuiCallback and placeStructureFromDeed would refuse
	out.z = zone->getHeight(x, y);

	if (!zone->isWithinBoundaries(Vector3(x, y, 0))) {
		out.reasons.add("outside the planet's boundaries");
	} else if (!planetManager->isBuildingPermittedAt(x, y, nullptr)) {
		SortedVector<ManagedReference<ActiveArea*>> areas;
		zone->getInRangeActiveAreas(x, 0, y, &areas, true);

		for (int i = 0; i < areas.size(); ++i) {
			ActiveArea* area = areas.get(i).get();

			if (area != nullptr && area->isNoBuildZone())
				out.reasons.add("in the no-build area " + area->getAreaName());
		}

		if (planetManager->isInWater(x, y))
			out.reasons.add("in water");

		if (planetManager->isInRangeWithPoi(x, y, 150))
			out.reasons.add("within 150 m of a point of interest");

		Reference<SceneObject*> object = planetManager->findObjectInNoBuildZone(x, y, 0.f, true);

		if (object != nullptr)
			out.reasons.add("in the no-build zone of " + describeObject(object));

		if (out.reasons.isEmpty())
			out.reasons.add("building is not permitted here");
	}

	Reference<CityRegion*> inside = getCityAt(zone, x, y);

	if (inside != nullptr)
		out.reasons.add("inside " + inside->getRegionDisplayedName());

	// City distances. NPC cities and registered player cities: 2 x max(region radius, 512)
	// (PlanetManager::validateClientCityInRange); every player city: 1024 m (CityManager::validateCityInRange)
	float bestMargin = 1e9;

	for (int i = 0; i < planetManager->getCityRegionCount(); ++i) {
		Reference<CityRegion*> city = planetManager->getCityRegion(i);

		if (city == nullptr)
			continue;

		for (int j = 0; j < city->getRegionsCount(); ++j) {
			Reference<Region*> region = city->getRegion(j);

			if (region == nullptr)
				continue;

			Vector3 center = region->getAreaCenter();
			float limit = 2 * Math::max(region->getRadius(), 512.f);
			float distance = Math::sqrt((center.getX() - x) * (center.getX() - x) + (center.getY() - y) * (center.getY() - y));

			if (distance <= limit) {
				reason.deleteAll();
				reason << "too close to " << city->getRegionDisplayedName() << ": " << (int)distance << " m (a city hall needs " << (int)limit << " m)";
				out.reasons.add(reason.toString());
			}

			if (distance - limit < bestMargin) {
				bestMargin = distance - limit;
				out.nearestCity = city->getRegionDisplayedName();
				out.nearestDistance = distance;
				out.nearestLimit = limit;
			}
		}
	}

	Vector<Reference<CityRegion*>> playerCities;
	getPlayerCities(playerCities);

	for (int i = 0; i < playerCities.size(); ++i) {
		CityRegion* city = playerCities.get(i);

		if (city->getZone() != zone)
			continue;

		float dx = city->getPositionX() - x;
		float dy = city->getPositionY() - y;
		float distance = Math::sqrt(dx * dx + dy * dy);

		if (distance < 1024) {
			reason.deleteAll();
			reason << "too close to the player city " << city->getCityRegionName() << ": " << (int)distance << " m (needs 1024 m)";
			out.reasons.add(reason.toString());
		}

		if (distance - 1024 < bestMargin) {
			bestMargin = distance - 1024;
			out.nearestCity = city->getCityRegionName();
			out.nearestDistance = distance;
			out.nearestLimit = 1024;
		}
	}

	// Heights: the footprint square every 2 m, the area square every 10 m
	float low = 1e9, high = -1e9;

	for (float yy = y - radius; yy <= y + radius; yy += 2) {
		for (float xx = x - radius; xx <= x + radius; xx += 2) {
			float h = terrain->getHeight(xx, yy);
			low = Math::min(low, h);
			high = Math::max(high, h);
		}
	}

	out.heightDiff = high - low;

	float areaLow = low, areaHigh = high;

	for (float yy = y - areaRadius; yy <= y + areaRadius; yy += 10) {
		for (float xx = x - areaRadius; xx <= x + areaRadius; xx += 10) {
			float h = terrain->getHeight(xx, yy);
			areaLow = Math::min(areaLow, h);
			areaHigh = Math::max(areaHigh, h);
		}
	}

	out.heightDiffArea = areaHigh - areaLow;

	// Buildable ground: a grid over the area circle
	float step = Math::max(areaRadius / 6.f, 10.f);
	int points = 0, blocked = 0, water = 0;

	for (float dy = -areaRadius; dy <= areaRadius + 0.1f; dy += step) {
		for (float dx = -areaRadius; dx <= areaRadius + 0.1f; dx += step) {
			if (dx * dx + dy * dy > areaRadius * areaRadius)
				continue;

			++points;

			if (planetManager->isInWater(x + dx, y + dy))
				++water;

			if (!planetManager->isBuildingPermittedAt(x + dx, y + dy, nullptr) || getCityAt(zone, x + dx, y + dy) != nullptr)
				++blocked;
		}
	}

	out.blocked = points > 0 ? (float)blocked / points : 0;
	out.water = points > 0 ? (float)water / points : 0;

	if (out.heightDiff > 8) {
		reason.deleteAll();
		reason << "uneven footprint: " << (int)out.heightDiff << " m of height difference within " << (int)radius << " m";
		out.warnings.add(reason.toString());
	}

	if (out.blocked > 0.2f) {
		reason.deleteAll();
		reason << (int)(out.blocked * 100) << "% of the area within " << (int)areaRadius << " m can't be built on";
		out.warnings.add(reason.toString());
	}

	if (out.water > 0.05f) {
		reason.deleteAll();
		reason << (int)(out.water * 100) << "% of the area is water";
		out.warnings.add(reason.toString());
	}

	out.ok = out.reasons.isEmpty();

	StringBuffer msg;
	msg << "checkSite " << planet << " " << formatPosition(x, y) << ": " << (out.ok ? "ok" : "refused");

	for (int i = 0; i < out.reasons.size(); ++i)
		msg << (i == 0 ? " - " : "; ") << out.reasons.get(i);

	msg << " | z " << (int)out.z << ", height diff " << out.heightDiff << " m within " << (int)radius << " m, " << out.heightDiffArea << " m within "
		<< (int)areaRadius << " m, blocked " << (int)(out.blocked * 100) << "%, water " << (int)(out.water * 100) << "%";

	if (!out.nearestCity.isEmpty())
		msg << ", nearest city " << out.nearestCity << " " << (int)out.nearestDistance << " m (limit " << (int)out.nearestLimit << ")";

	for (int i = 0; i < out.warnings.size(); ++i)
		msg << " | warning: " << out.warnings.get(i);

	log().info(true) << msg.toString();

	return true;
}

String BotCity::checkPlacement(CreatureObject* bot, StructureDeed* deed, float x, float y, int angle) {
	return checkPlacementInternal(bot, deed, x, y, angle, false);
}

bool BotCity::placeStructure(CreatureObject* bot, uint64 deedOid, float x, float y, int angle) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot))
		return false;

	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<StructureDeed*> deed = zoneServer != nullptr ? zoneServer->getObject(deedOid).castTo<StructureDeed*>() : nullptr;
	String reason = deed == nullptr ? String("there's no structure deed with that id") : checkPlacement(bot, deed, x, y, angle);
	String templatePath = deed != nullptr ? deed->getGeneratedObjectTemplate() : String("?");

	if (!reason.isEmpty()) {
		log().warning() << bot->getFirstName() << " can't place " << templatePath << " at " << formatPosition(x, y) << ": " << reason;
		return false;
	}

	StringBuffer args;
	args << deedOid << " " << x << " " << y << " " << angle;

	if (!BotChat::enqueue(bot, "placestructure", 0, args.toString())) {
		log().error() << bot->getFirstName() << " couldn't queue /placestructure " << args.toString();
		return false;
	}

	log().info(true) << bot->getFirstName() << " places " << templatePath << " at " << formatPosition(x, y) << ", angle " << angle;

	// The structures it owned before, so the watcher only counts a new one
	Vector<uint64> before;
	PlayerObject* ghost = bot->getPlayerObject();

	for (int i = 0; ghost != nullptr && i < ghost->getTotalOwnedStructureCount(); ++i)
		before.add(ghost->getOwnedStructure(i));

	uint64 botOid = bot->getObjectID();
	Time started;
	uint64 startedMs = started.getMiliTime();

	// The watcher: one look every WATCH_MS; done at "placed", at a refusal, or after two minutes
	auto check = [botOid, deedOid, x, y, angle, templatePath, before, startedMs]() -> bool {
		ZoneServer* server = ServerCore::getZoneServer();
		ManagedReference<CreatureObject*> owner = server != nullptr ? server->getObject(botOid).castTo<CreatureObject*>() : nullptr;

		if (owner == nullptr)
			return true;

		Locker ownerLocker(owner);

		Time now;
		uint64 elapsed = now.getMiliTime() - startedMs;
		Reference<StructureObject*> placed = findPlacedStructure(owner, templatePath, x, y, before);

		if (placed != nullptr) {
			Reference<CityRegion*> city = placed->getCityRegion().get();

			log().info(true) << owner->getFirstName() << " placed " << templatePath << ": " << placed->getObjectID() << " at "
				<< formatPosition(placed->getPositionX(), placed->getPositionY()) << (city != nullptr ? " in " + city->getCityRegionName() : String(""))
				<< ", " << elapsed << " ms after the command";

			tellJobs(owner, "placed", placed, templatePath);
			return true;
		}

		ManagedReference<StructureDeed*> heldDeed = server->getObject(deedOid).castTo<StructureDeed*>();
		bool placing = owner->containsActiveSession(SessionFacadeType::PLACESTRUCTURE);
		bool held = heldDeed != nullptr && heldDeed->isASubChildOf(owner);

		if (!placing && held && elapsed >= WATCH_GRACE_MS) {
			String why = checkPlacementInternal(owner, heldDeed, x, y, angle, false);

			if (why.isEmpty())
				why = "refused, for a reason Core3 only told the bot's (missing) client";

			log().warning() << owner->getFirstName() << " didn't place " << templatePath << " at " << formatPosition(x, y) << ": " << why;

			tellJobs(owner, "placeFailed", nullptr, why);
			return true;
		}

		if (!placing && heldDeed == nullptr && elapsed >= WATCH_GRACE_MS) {
			log().warning() << owner->getFirstName() << "'s deed for " << templatePath << " is gone and nothing stands at " << formatPosition(x, y);

			tellJobs(owner, "placeFailed", nullptr, "the deed is gone");
			return true;
		}

		if (elapsed > 120000) {
			log().warning() << owner->getFirstName() << "'s placement of " << templatePath << " at " << formatPosition(x, y) << " timed out";

			tellJobs(owner, "placeFailed", nullptr, "timed out");
			return true;
		}

		return false;
	};

	Reference<Task*> watcher = new RepeatUntilTask(check, "BotCityWatchPlacement", WATCH_MS);
	watcher->schedule(WATCH_MS);

	return true;
}

// --- Founding ---

uint64 BotCity::foundCity(CreatureObject* mayor, float x, float y, int angle, const String& name) {
	String cityName = name.trim();

	if (mayor == nullptr || !BotManager::instance()->isOnlineBot(mayor)) {
		log().warning() << "foundCity " << cityName << ": the mayor isn't an online bot";
		return 0;
	}

	Reference<CityRegion*> existing = findCity(cityName);

	if (existing != nullptr) {
		log().info(true) << "foundCity: " << existing->getCityRegionName() << " already exists, id " << existing->getObjectID() << ", rank "
			<< existing->getCityRank() << ", mayor " << existing->getMayorID();
		return existing->getObjectID();
	}

	Locker locker(mayor);

	Zone* zone = mayor->getZone();
	ZoneServer* zoneServer = mayor->getZoneServer();
	PlayerObject* ghost = mayor->getPlayerObject();

	if (zone == nullptr || zoneServer == nullptr || ghost == nullptr) {
		log().warning() << "foundCity " << cityName << ": " << mayor->getFirstName() << " isn't in the world";
		return 0;
	}

	CityManager* cityManager = zoneServer->getCityManager();
	PlanetManager* planetManager = zone->getPlanetManager();
	String planet = zone->getZoneName();
	String reason;

	if (angle > 3)
		angle = ((angle + 45) / 90) % 4;	// degrees

	if (angle < 0)
		angle = 0;

	// PlaceCityHallComponent::placeStructure
	Reference<CityRegion*> ownCity = getResidenceCity(mayor);
	String deedTemplate = getCityHallDeed(planet);

	if (cityManager->isCityRankCapped(planet, CityManager::OUTPOST))
		reason = planet + " already has its maximum number of player cities";
	else if (ownCity != nullptr && ownCity->isMayor(mayor->getObjectID()))
		reason = mayor->getFirstName() + " is already the mayor of " + ownCity->getCityRegionName();
	else if (deedTemplate.isEmpty())
		reason = "no city hall may be built on " + planet;

	// PlaceCityHallSuiCallback::run: the name
	if (reason.isEmpty()) {
		int nameResult = mayor->getZoneProcessServer()->getNameManager()->validateCityName(cityName);

		if (nameResult != NameManagerResult::ACCEPTED)
			reason = "the name filter rejected \"" + cityName + "\" (result " + String::valueOf(nameResult) + ")";
		else if (!planetManager->validateRegionName(cityName))
			reason = "\"" + cityName + "\" contains or is a region's name";
		else if (!cityManager->validateCityName(cityName))
			reason = "another city is called " + cityName;
	}

	// The distances, with the reasons
	if (reason.isEmpty()) {
		BotSiteCheck site;
		checkSite(planet, x, y, 4, 4, site);

		for (int i = 0; i < site.reasons.size(); ++i) {
			const String& siteReason = site.reasons.get(i);

			if (siteReason.beginsWith("too close to")) {
				reason = siteReason;
				break;
			}
		}
	}

	if (!reason.isEmpty()) {
		log().warning() << "foundCity " << cityName << " at " << planet << " " << formatPosition(x, y) << " refused: " << reason;
		return 0;
	}

	// The city hall deed, made here
	ManagedReference<SceneObject*> inventory = mayor->getSlottedObject("inventory");
	ManagedReference<SceneObject*> object = inventory != nullptr ? zoneServer->createObject(deedTemplate.hashCode(), 1) : nullptr;
	ManagedReference<StructureDeed*> deed = object != nullptr ? object.castTo<StructureDeed*>() : nullptr;

	if (deed == nullptr) {
		log().error() << "foundCity " << cityName << ": couldn't make " << deedTemplate;

		if (object != nullptr)
			object->destroyObjectFromDatabase(true);

		return 0;
	}

	{
		Locker dlocker(deed, mayor);

		if (!inventory->transferObject(deed, -1, true, true)) {
			log().error() << "foundCity " << cityName << ": couldn't put the city hall deed in " << mayor->getFirstName() << "'s inventory";
			deed->destroyObjectFromDatabase(true);
			return 0;
		}
	}

	// Everything placeStructureFromDeed and the command check, logged
	reason = checkPlacementInternal(mayor, deed, x, y, angle, true);

	uint64 cityOid = 0;

	if (reason.isEmpty()) {
		try {
			Locker clocker(cityManager);

			// As the callback: the same checks once more under the city manager's lock, then place and create
			if (!cityManager->validateCityInRange(mayor, zone, x, y) || !planetManager->validateClientCityInRange(mayor, x, y)) {
				reason = "too close to another city";
			} else if (!planetManager->validateRegionName(cityName) || !cityManager->validateCityName(cityName)) {
				reason = "the name isn't unique";
			} else {
				int result = StructureManager::instance()->placeStructureFromDeed(mayor, deed, x, y, angle * 90);

				if (result != 0) {
					reason = "StructureManager::placeStructureFromDeed refused it (result " + String::valueOf(result) + ")";
				} else {
					Reference<CityRegion*> city = cityManager->createCity(mayor, cityName, x, y);

					if (city == nullptr) {
						reason = "CityManager::createCity failed";
					} else {
						cityOid = city->getObjectID();
						rememberCity(city);
					}
				}
			}
		} catch (const Exception& e) {
			reason = "exception: " + e.getMessage();
		}
	}

	if (cityOid == 0) {
		log().warning() << "foundCity " << cityName << " at " << planet << " " << formatPosition(x, y) << " refused: " << reason;

		// The deed was ours: don't leave it lying in the inventory
		Locker dlocker(deed, mayor);

		if (deed->isASubChildOf(mayor) || deed->getParent().get() == nullptr) {
			deed->destroyObjectFromWorld(true);
			deed->destroyObjectFromDatabase(true);
		}

		return 0;
	}

	log().info(true) << "foundCity: " << mayor->getFirstName() << " founded " << cityName << " (id " << cityOid << ") on " << planet << " at "
		<< formatPosition(x, y) << ", angle " << angle << "; the city hall is being placed";

	Time now;
	watchFounding(cityOid, mayor->getObjectID(), deed->getObjectID(), now.getMiliTime(), 0);
	refreshElectionTime(cityOid);

	return cityOid;
}

// --- Citizens ---

bool BotCity::declareResidence(CreatureObject* bot, uint64 structureOid) {
	if (bot == nullptr || !BotManager::instance()->isBot(bot))
		return false;

	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerObject* ghost = bot->getPlayerObject();

	if (zoneServer == nullptr || ghost == nullptr)
		return false;

	ManagedReference<StructureObject*> structure = zoneServer->getObject(structureOid).castTo<StructureObject*>();
	String reason;

	if (structure == nullptr) {
		reason = "there's no structure " + String::valueOf(structureOid);
	} else if (!structure->isBuildingObject()) {
		reason = "it isn't a building";
	} else if (!structure->isOwnerOf(bot)) {
		reason = "the bot doesn't own it";
	} else if (ghost->getDeclaredResidence() == structureOid) {
		log().info(true) << bot->getFirstName() << "'s residence is already " << structureOid;
		return true;
	} else {
		Reference<CityRegion*> current = getResidenceCity(bot);
		Reference<CityRegion*> target = structure->getCityRegion().get();

		if (current != nullptr && current->isMayor(bot->getObjectID()))
			reason = "a mayor's residence is always the city hall of " + current->getCityRegionName();
		else if (target != nullptr && target->isMayor(bot->getObjectID()) && structure != target->getCityHall())
			reason = "a mayor's residence is always the city hall";
		else if (!bot->checkCooldownRecovery("declare_residence") && !ghost->isPrivileged()) {
			const Time* left = bot->getCooldownTime("declare_residence");
			reason = "it can change residence again in " + String::valueOf((int)ceil(left->miliDifference() / -3600000.f)) + " h";
		}
	}

	if (!reason.isEmpty()) {
		log().warning() << bot->getFirstName() << " can't declare residence at " << structureOid << ": " << reason;
		return false;
	}

	int result = StructureManager::instance()->declareResidence(bot, structure);

	if (result != 0 || ghost->getDeclaredResidence() != structureOid) {
		log().warning() << bot->getFirstName() << " couldn't declare residence at " << structureOid << " (result " << result << ")";
		return false;
	}

	Reference<CityRegion*> city = structure->getCityRegion().get();

	log().info(true) << bot->getFirstName() << " declared residence at " << structure->getDisplayedName() << " (" << structureOid << ")"
		<< (city != nullptr && !city->isClientRegion() ? ", a citizen of " + city->getCityRegionName() + " (" + String::valueOf(city->getCitizenCount()) + " citizens)" : String(", outside any player city"));

	return true;
}

bool BotCity::registerCandidate(CreatureObject* bot, CityRegion* city) {
	if (bot == nullptr || city == nullptr || !BotManager::instance()->isBot(bot))
		return false;

	Locker locker(bot);

	uint64 oid = bot->getObjectID();
	String reason;

	if (!city->isCitizen(oid))
		reason = "not a citizen";
	else if (city->isCandidate(oid)) {
		log().info(true) << bot->getFirstName() << " is already running for mayor of " << city->getCityRegionName();
		return true;
	} else if (city->isVotingLocked())
		reason = "the ballot is locked in the last week before the election";
	else if (!bot->hasSkill("social_politician_novice"))
		reason = "not a politician";
	else if (!bot->checkCooldownRecovery("register_mayor"))
		reason = "registered once already in the last 24 h";

	if (!reason.isEmpty()) {
		log().warning() << bot->getFirstName() << " can't run for mayor of " << city->getCityRegionName() << ": " << reason;
		return false;
	}

	Locker clocker(city, bot);

	bot->getZoneServer()->getCityManager()->registerForMayoralRace(city, bot);

	bool ok = city->isCandidate(oid);

	if (ok)
		log().info(true) << bot->getFirstName() << " is running for mayor of " << city->getCityRegionName();
	else
		log().warning() << bot->getFirstName() << " couldn't register for the race in " << city->getCityRegionName();

	return ok;
}

bool BotCity::castVote(CreatureObject* bot, CityRegion* city, uint64 candidateOid) {
	if (bot == nullptr || city == nullptr || !BotManager::instance()->isBot(bot))
		return false;

	Locker locker(bot);

	String reason;

	if (!city->isCitizen(bot->getObjectID()))
		reason = "not a citizen";
	else if (candidateOid != 0 && !city->isCandidate(candidateOid))
		reason = String::valueOf(candidateOid) + " isn't running";

	if (!reason.isEmpty()) {
		log().warning() << bot->getFirstName() << " can't vote in " << city->getCityRegionName() << ": " << reason;
		return false;
	}

	Locker clocker(city, bot);

	bot->getZoneServer()->getCityManager()->castMayoralVote(city, bot, candidateOid);

	log().info(true) << bot->getFirstName() << " voted for " << candidateOid << " in " << city->getCityRegionName()
		<< (candidateOid != 0 ? " (" + String::valueOf(city->getCandidateVotes(candidateOid)) + " votes)" : String(" (abstained)"));

	return true;
}

// --- The mayor ---

Reference<CreatureObject*> BotCity::getBotMayor(CityRegion* city, const char* what) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	Reference<CreatureObject*> mayor = zoneServer != nullptr ? zoneServer->getObject(city->getMayorID()).castTo<CreatureObject*>() : nullptr;

	if (mayor == nullptr || !mayor->isPlayerCreature()) {
		log().warning() << what << " " << city->getCityRegionName() << ": the mayor " << city->getMayorID() << " isn't loaded";
		return nullptr;
	}

	if (!BotManager::instance()->isBot(mayor)) {
		log().warning() << what << " " << city->getCityRegionName() << ": the mayor, " << mayor->getFirstName() << ", isn't a bot";
		return nullptr;
	}

	return mayor;
}

bool BotCity::deposit(CityRegion* city, int credits, CreatureObject* from) {
	if (city == nullptr || credits <= 0)
		return false;

	if (from != nullptr && !BotManager::instance()->isBot(from)) {
		log().warning() << "deposit into " << city->getCityRegionName() << ": the payer isn't a bot";
		return false;
	}

	int room = MAX_TREASURY - (int)city->getCityTreasury();

	if (room <= 0) {
		log().warning() << "deposit into " << city->getCityRegionName() << ": the treasury is full (100M)";
		return false;
	}

	int amount = Math::min(credits, room);

	if (from != nullptr && from->getCashCredits() + from->getBankCredits() < amount) {
		log().warning() << "deposit into " << city->getCityRegionName() << ": " << from->getFirstName() << " has only "
			<< (from->getCashCredits() + from->getBankCredits()) << " of " << amount << " credits";
		return false;
	}

	Reference<CityRegion*> cityRef = city;
	Reference<CreatureObject*> fromRef = from;

	Core::getTaskManager()->executeTask([cityRef, fromRef, amount]() {
		if (fromRef != nullptr) {
			Locker locker(fromRef);

			int cash = Math::min(amount, fromRef->getCashCredits());
			int bank = amount - cash;

			if (bank > fromRef->getBankCredits()) {
				log().warning() << "deposit into " << cityRef->getCityRegionName() << ": " << fromRef->getFirstName() << " no longer has " << amount << " credits";
				return;
			}

			if (cash > 0) {
				TransactionLog trx(fromRef.get(), TrxCode::CITYTREASURY, (uint)cash, true);
				fromRef->subtractCashCredits(cash);
			}

			if (bank > 0) {
				TransactionLog trx(fromRef.get(), TrxCode::CITYTREASURY, (uint)bank, false);
				fromRef->subtractBankCredits(bank);
			}

			Locker clocker(cityRef, fromRef);

			cityRef->addToCityTreasury(amount);

			log().info(true) << fromRef->getFirstName() << " deposited " << amount << " credits into " << cityRef->getCityRegionName()
				<< "'s treasury, now " << (int64)cityRef->getCityTreasury();
		} else {
			Locker locker(cityRef);

			cityRef->addToCityTreasury(amount);

			log().info(true) << "deposited " << amount << " new credits into " << cityRef->getCityRegionName() << "'s treasury, now "
				<< (int64)cityRef->getCityTreasury();
		}
	}, "BotCityDeposit");

	return true;
}

bool BotCity::setTax(CityRegion* city, int index, int value) {
	if (city == nullptr)
		return false;

	ZoneServer* zoneServer = ServerCore::getZoneServer();
	CityManager* cityManager = zoneServer != nullptr ? zoneServer->getCityManager() : nullptr;
	const CityTax* tax = cityManager != nullptr ? cityManager->getCityTax(index) : nullptr;
	Reference<CreatureObject*> mayor = getBotMayor(city, "setTax");
	PlayerObject* ghost = mayor != nullptr ? mayor->getPlayerObject() : nullptr;
	String reason;

	if (ghost == nullptr)
		return false;

	if (tax == nullptr)
		reason = "no tax " + String::valueOf(index) + " (0 income, 1 property, 2 sales, 3 travel, 4 garage)";
	else if (value < tax->getMinValue() || value > tax->getMaxValue())
		reason = "the value must be " + String::valueOf(tax->getMinValue()) + "-" + String::valueOf(tax->getMaxValue());
	else if (city->getCityRank() < CityRegion::RANK_VILLAGE)
		reason = "the city must be rank 2 to tax";
	else if (!ghost->hasAbility("manage_taxes"))
		reason = mayor->getFirstName() + " lacks manage_taxes";
	else if (index == CityRegion::TAX_TRAVEL && !city->hasShuttleInstallation())
		reason = "a travel fee needs a shuttleport";

	if (!reason.isEmpty()) {
		log().warning() << "setTax " << index << " = " << value << " in " << city->getCityRegionName() << ": " << reason;
		return false;
	}

	if (city->getTax(index) == value)
		return true;

	Reference<CityRegion*> cityRef = city;

	Core::getTaskManager()->executeTask([cityRef, mayor, index, value]() {
		Locker locker(mayor);

		mayor->getZoneServer()->getCityManager()->setTax(cityRef, mayor, index, value);

		log().info(true) << mayor->getFirstName() << " set " << cityRef->getCityRegionName() << "'s tax " << index << " to " << cityRef->getTax(index);
	}, "BotCitySetTax");

	return true;
}

bool BotCity::setSpecialization(CityRegion* city, const String& spec) {
	if (city == nullptr)
		return false;

	String value = normalizeSpecialization(spec);
	ZoneServer* zoneServer = ServerCore::getZoneServer();
	CityManager* cityManager = zoneServer != nullptr ? zoneServer->getCityManager() : nullptr;
	Reference<CreatureObject*> mayor = getBotMayor(city, "setSpecialization");
	PlayerObject* ghost = mayor != nullptr ? mayor->getPlayerObject() : nullptr;
	String reason;

	if (ghost == nullptr || cityManager == nullptr)
		return false;

	if (city->getCitySpecialization() == value)
		return true;

	if (!value.isEmpty()) {
		if (cityManager->getCitySpecialization(value) == nullptr)
			reason = "no specialization " + value;
		else if (city->getCityRank() < CityRegion::RANK_TOWNSHIP)
			reason = "the city must be rank 3";
		else if (!hasSpecializationAbility(ghost, value))
			reason = mayor->getFirstName() + " lacks the ability for " + value;
		else if (!mayor->checkCooldownRecovery("city_specialization") && !ghost->isPrivileged())
			reason = "the specialization changed less than a week ago";
	}

	if (!reason.isEmpty()) {
		log().warning() << "setSpecialization " << value << " in " << city->getCityRegionName() << ": " << reason;
		return false;
	}

	Reference<CityRegion*> cityRef = city;

	Core::getTaskManager()->executeTask([cityRef, mayor, value]() {
		Locker locker(mayor);

		mayor->getZoneServer()->getCityManager()->changeCitySpecialization(cityRef, mayor, value);

		log().info(true) << mayor->getFirstName() << " set " << cityRef->getCityRegionName() << "'s specialization to "
			<< (value.isEmpty() ? String("none") : value);
	}, "BotCitySetSpec");

	return true;
}

bool BotCity::setZoning(CityRegion* city, bool on) {
	if (city == nullptr)
		return false;

	if (city->isZoningEnabled() == on)
		return true;

	Reference<CreatureObject*> mayor = getBotMayor(city, "setZoning");

	if (mayor == nullptr)
		return false;

	if (!mayor->hasSkill("social_politician_novice")) {
		log().warning() << "setZoning in " << city->getCityRegionName() << ": " << mayor->getFirstName() << " isn't a politician";
		return false;
	}

	Reference<CityRegion*> cityRef = city;

	Core::getTaskManager()->executeTask([cityRef, mayor, on]() {
		Locker locker(mayor);
		Locker clocker(cityRef, mayor);

		cityRef->setZoningEnabled(on);

		log().info(true) << mayor->getFirstName() << " turned zoning " << (on ? "on" : "off") << " in " << cityRef->getCityRegionName();
	}, "BotCityZoning");

	return true;
}

bool BotCity::setRegistered(CityRegion* city, bool on) {
	if (city == nullptr)
		return false;

	if (city->isRegistered() == on)
		return true;

	Reference<CreatureObject*> mayor = getBotMayor(city, "setRegistered");
	PlayerObject* ghost = mayor != nullptr ? mayor->getPlayerObject() : nullptr;

	if (ghost == nullptr)
		return false;

	if (on && city->getCityRank() < CityRegion::RANK_TOWNSHIP) {
		log().warning() << "register " << city->getCityRegionName() << ": the city must be rank 3";
		return false;
	}

	if (on && !ghost->hasAbility("city_map")) {
		log().warning() << "register " << city->getCityRegionName() << ": " << mayor->getFirstName() << " lacks city_map";
		return false;
	}

	Reference<CityRegion*> cityRef = city;

	Core::getTaskManager()->executeTask([cityRef, mayor, on]() {
		Locker locker(mayor);
		Locker clocker(cityRef, mayor);

		CityManager* cityManager = mayor->getZoneServer()->getCityManager();

		if (on)
			cityManager->registerCity(cityRef, mayor);
		else
			cityManager->unregisterCity(cityRef, mayor);

		log().info(true) << mayor->getFirstName() << (on ? " registered " : " unregistered ") << cityRef->getCityRegionName() << " on the planetary map";
	}, "BotCityRegister");

	return true;
}

bool BotCity::expand(CityRegion* city, bool fullUpdate) {
	if (city == nullptr || !isDevAllowed(fullUpdate ? "botCityExpand (update)" : "botCityExpand"))
		return false;

	Reference<CityRegion*> cityRef = city;

	Core::getTaskManager()->executeTask([cityRef, fullUpdate]() {
		CityManager* cityManager = ServerCore::getZoneServer()->getCityManager();
		int before = cityRef->getCityRank();

		Locker locker(cityRef);

		if (fullUpdate)
			cityManager->processCityUpdate(cityRef);
		else
			cityManager->expandCity(cityRef);

		log().info(true) << (fullUpdate ? "dev city update: " : "dev rank up: ") << cityRef->getCityRegionName() << " rank " << before << " -> "
			<< cityRef->getCityRank() << ", radius " << (int)cityRef->getRadius() << ", citizens " << cityRef->getCitizenCount()
			<< ", treasury " << (int64)cityRef->getCityTreasury();
	}, "BotCityExpand");

	return true;
}

uint64 BotCity::placeDecoration(CreatureObject* mayor, const String& templatePath) {
	if (mayor == nullptr || !BotManager::instance()->isOnlineBot(mayor))
		return 0;

	Locker locker(mayor);

	Zone* zone = mayor->getZone();
	ZoneServer* zoneServer = mayor->getZoneServer();
	PlayerObject* ghost = mayor->getPlayerObject();

	if (zone == nullptr || zoneServer == nullptr || ghost == nullptr)
		return 0;

	ManagedReference<CityRegion*> city = mayor->getCityRegion().get();
	SharedObjectTemplate* objectTemplate = TemplateManager::instance()->getTemplate(templatePath.hashCode());
	CityManager* cityManager = zoneServer->getCityManager();
	PlanetManager* planetManager = zone->getPlanetManager();
	float x = mayor->getWorldPositionX();
	float y = mayor->getWorldPositionY();
	bool lamp = templatePath.contains("object/tangible/furniture/city/streetlamp");
	bool statue = templatePath.contains("object/tangible/furniture/city/statue");
	bool fountain = templatePath.contains("object/tangible/furniture/city/fountain");
	String reason;

	// CityDecorationTask::placeDecoration, in its order
	if (objectTemplate == nullptr)
		reason = "no template " + templatePath;
	else if (mayor->getParent().get() != nullptr)
		reason = "the mayor must be outdoors";
	else if (city == nullptr || city->isClientRegion())
		reason = "the mayor must stand inside its city";
	else if (!city->isMayor(mayor->getObjectID()))
		reason = mayor->getFirstName() + " isn't the mayor of " + city->getCityRegionName();
	else if ((lamp && !ghost->hasAbility("place_streetlamp")) || (statue && !ghost->hasAbility("place_statue")) || (fountain && !ghost->hasAbility("place_fountain")))
		reason = "the mayor lacks the skill to place this decoration";
	else if (!cityManager->canSupportMoreDecorations(city))
		reason = "the city can't support more decorations at its rank";
	else if (!planetManager->isBuildingPermittedAt(x, y, mayor, 0, false))
		reason = "building is not permitted here";
	else if (!lamp) {
		Reference<SceneObject*> tooClose = planetManager->findObjectTooCloseToDecoration(x, y, objectTemplate->getNoBuildRadius());

		if (tooClose != nullptr)
			reason = "too close to " + describeObject(tooClose);
	}

	if (reason.isEmpty() && city->getCityTreasury() < 1000)
		reason = "the treasury needs 1000 credits";

	if (!reason.isEmpty()) {
		log().warning() << mayor->getFirstName() << " can't place the decoration " << templatePath << " at " << formatPosition(x, y) << ": " << reason;
		return 0;
	}

	ManagedReference<SceneObject*> object = zoneServer->createObject(templatePath.hashCode(), 1);
	ManagedReference<TangibleObject*> decoration = object != nullptr && object->isTangibleObject() ? object.castTo<TangibleObject*>() : nullptr;

	if (decoration == nullptr) {
		log().error() << "placeDecoration: couldn't make " << templatePath;

		if (object != nullptr)
			object->destroyObjectFromDatabase(true);

		return 0;
	}

	Locker olocker(decoration, mayor);

	decoration->initializePosition(x, mayor->getWorldPositionZ(), y);
	decoration->rotate(mayor->getDirectionAngle() - decoration->getDirectionAngle());

	if (!zone->transferObject(decoration, -1, true)) {
		log().error() << "placeDecoration: couldn't put " << templatePath << " in the world";
		decoration->destroyObjectFromDatabase(true);
		return 0;
	}

	olocker.release();

	Locker clocker(city, mayor);

	city->addDecoration(decoration);
	city->subtractFromCityTreasury(1000);

	log().info(true) << mayor->getFirstName() << " placed the decoration " << templatePath << " (" << decoration->getObjectID() << ") in "
		<< city->getCityRegionName() << " at " << formatPosition(x, y) << "; " << city->getDecorationCount() << " decorations";

	return decoration->getObjectID();
}

// --- Dev tools ---

bool BotCity::destroyCity(CityRegion* city) {
	if (city == nullptr || !isDevAllowed("destroyCity"))
		return false;

	Reference<CityRegion*> cityRef = city;
	String name = city->getCityRegionName();

	{
		Locker locker(&cityMutex);

		cityOids.drop(name.toLowerCase());
	}

	Core::getTaskManager()->executeTask([cityRef, name]() {
		ServerCore::getZoneServer()->getCityManager()->destroyCity(cityRef);

		log().info(true) << "dev: destroyed the city " << name;
	}, "BotCityDestroy");

	return true;
}

int BotCity::destroyOwnedStructures(CreatureObject* bot) {
	if (bot == nullptr || !BotManager::instance()->isBot(bot) || !isDevAllowed("destroyOwnedStructures"))
		return 0;

	Vector<BotStructureInfo> owned;
	getOwnedStructures(bot, owned);

	ZoneServer* zoneServer = bot->getZoneServer();
	int count = 0;

	for (int i = 0; i < owned.size(); ++i) {
		const BotStructureInfo& info = owned.get(i);

		if (info.kind == "cityhall")
			continue;	// destroyCity does it

		Reference<StructureObject*> structure = zoneServer->getObject(info.oid).castTo<StructureObject*>();

		if (structure == nullptr)
			continue;

		Core::getTaskManager()->executeTask([structure]() {
			Locker locker(structure);

			StructureManager::instance()->destroyStructure(structure);
		}, "BotCityDestroyStructure");

		log().info(true) << "dev: destroying " << bot->getFirstName() << "'s " << info.templatePath << " (" << info.oid << ")";
		++count;
	}

	return count;
}
