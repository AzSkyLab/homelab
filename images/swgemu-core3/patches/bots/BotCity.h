/*
 * BotCity: the bot players' player city (Phase 6, see ~/github/swgemu/specs/2026-10-23-player-city/).
 *
 * What a mayor and its citizens do through the city hall deed, the structure deeds and the city terminal, without a
 * client. No upstream hooks: everything calls Core3's own CityManager, StructureManager and PlanetManager.
 * - Founding: PlaceCityHallSuiCallback::run minus the name window (bots close every window, patch 0005), with the
 *   same checks, the city hall deed made here, and idempotent by name.
 * - Spawns in the way: Core3's spawn manager puts creature lairs, camps ("poi" buildings) and theaters on the plains, and
 *   a placement is refused inside their no-build radius. A player would fight them away; placeStructure, foundCity and
 *   placeDecoration remove one that stands on the spot (as DespawnLairOnPlayerDisappear does), and logs it. Site probes
 *   leave them out of the numbers.
 * - Site probes, placement checks, and a watcher that logs each placement's outcome. Core3 sends every refusal as a
 *   system message, which a bot's missing client never shows, so the reasons are worked out here and logged.
 * - Residence, elections, the mayor's controls (treasury, taxes, specialization, zoning, registration), decorations.
 * - A dev fast-forward (rank up) and the BotCityDev console tools (BotCityLua.cpp).
 *
 * Locking: functions that take a bot lock it (a no-op when the caller's event holds it), then cross-lock the city, as
 * Core3's own city code does. The mayor's controls that take only a city run in a task of their own, so they never
 * lock the mayor while the caller holds another object: they return true when the checks pass and the change is
 * queued, and log the outcome.
 */

#ifndef BOTCITY_H_
#define BOTCITY_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace creature {
class CreatureObject;
}
namespace region {
class CityRegion;
}
namespace structure {
class StructureObject;
}
namespace tangible {
namespace deed {
namespace structure {
class StructureDeed;
}
}
}
}

namespace managers {
namespace bot {

// botCheckSite's answer
class BotSiteCheck : public Object {
public:
	bool ok = false;
	Vector<String> reasons;			// what stops a city hall at the centre (empty when ok)
	Vector<String> warnings;		// what makes the site poor without stopping it
	float z = 0;					// terrain height at the centre
	float waterLevel = -9999;		// the water surface at the centre (a water boundary or the global table), or -9999 if none
	float heightDiff = 0;			// highest height difference over the footprint square (centre +/- radius)
	float heightDiffArea = 0;		// the same over the area square (centre +/- areaRadius)
	float blocked = 0;				// share of grid points in the area circle where building isn't permitted (0..1)
	float water = 0;				// share of them in water
	String nearestCity;				// the nearest city, NPC or player, by distance less its limit
	float nearestDistance = 0;
	float nearestLimit = 0;			// the closest a new city hall may be to it
};

// One structure for botOwnedStructures and botCityInfo
class BotStructureInfo : public Object {
public:
	uint64 oid = 0;
	String templatePath;
	String name;
	String kind;					// "cityhall", "civic", "commercial", "decoration", "house", "other"
	float x = 0;
	float y = 0;
	String city;					// the player city it stands in, or ""
	bool residence = false;
};

class BotCity {
public:
	static const int MAX_TREASURY = 100000000;
	static const int WATCH_MS = 2000;			// how often a placement watcher looks
	static const int WATCH_GRACE_MS = 8000;		// a deed still in the inventory this long after the command: refused

	// --- Sites and placement ---

	// Probes a city site on a loaded planet: building permitted, not water, not in an NPC city, the city-distance
	// limits (another player city 1024 m; an NPC city 2 x max(radius, 512) m, 1904 m for Theed), the height differences
	// and the share of buildable ground. Logged. False only if the planet isn't loaded
	static bool checkSite(const String& planet, float x, float y, float radius, float areaRadius, BotSiteCheck& out);

	// Why Core3 would refuse this placement, as PlaceStructureCommand, the deed's placement component and
	// StructureManager::placeStructureFromDeed check it; "" if it would place. angle is 0-3. Bot locked
	static String checkPlacement(server::zone::objects::creature::CreatureObject* bot,
			server::zone::objects::tangible::deed::structure::StructureDeed* deed, float x, float y, int angle);

	// checkPlacement, logged; then the real /placestructure, and a watcher that logs the outcome and tells the jobs:
	// BotJobs:onEvent(pBot, "placed", pStructure, template) or (pBot, "placeFailed", nil, reason). Bot locked
	static bool placeStructure(server::zone::objects::creature::CreatureObject* bot, uint64 deedOid, float x, float y, int angle);

	// --- Founding ---

	// The city hall window's callback without the window: the same checks (cities capped, already a mayor, the name
	// rules, the distances, the no-build areas), plus the command's (outdoors, within 100 m and 10 m of height). Makes
	// the city hall deed, places it and creates the city. Idempotent: if a city by this name exists, returns its id.
	// angle is 0-3. Returns the city's object id, or 0 (logged). Bot locked or not
	static uint64 foundCity(server::zone::objects::creature::CreatureObject* mayor, float x, float y, int angle, const String& name);

	// --- Lookups ---

	// A player city by name, case-insensitive (never an NPC city), or nullptr
	static Reference<server::zone::objects::region::CityRegion*> findCity(const String& name);

	// The city of a player's declared residence, or nullptr
	static Reference<server::zone::objects::region::CityRegion*> getResidenceCity(server::zone::objects::creature::CreatureObject* creature);

	// Every player city in the galaxy
	static void getPlayerCities(Vector<Reference<server::zone::objects::region::CityRegion*>>& out);

	// What the next weekly update will charge, as CityManager::deductCityMaintenance counts it (city hall, civic
	// structures, decorations, terminals, trainers, registration, specialization)
	static int getWeeklyUpkeep(server::zone::objects::region::CityRegion* city);

	// Seconds until the next election (the update after the voting period ends), or -1 if unknown
	static int getSecondsToElection(server::zone::objects::region::CityRegion* city);

	static String getStructureKind(server::zone::objects::structure::StructureObject* structure, server::zone::objects::region::CityRegion* city);
	static void getStructureInfo(server::zone::objects::structure::StructureObject* structure, BotStructureInfo& out);

	// The structures a player owns (bots: online or not)
	static void getOwnedStructures(server::zone::objects::creature::CreatureObject* creature, Vector<BotStructureInfo>& out);

	// "entertainer", "city_spec_entertainer" or "@city/city:city_spec_entertainer" -> the last; "" stays ""
	static String normalizeSpecialization(const String& spec);

	// --- Citizens (bot locked) ---

	// StructureManager::declareResidence, with its refusals logged
	static bool declareResidence(server::zone::objects::creature::CreatureObject* bot, uint64 structureOid);

	// CityManager::registerForMayoralRace / castMayoralVote (candidateOid 0 abstains)
	static bool registerCandidate(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::region::CityRegion* city);
	static bool castVote(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::region::CityRegion* city, uint64 candidateOid);

	// --- The mayor (queued; the current mayor must be a bot, except for a deposit) ---

	// Adds to the treasury (CityRegion::addToCityTreasury, up to 100M). With `from`, a bot, the credits come out of its
	// cash, then its bank; without, they are made (the city's upkeep is the one place the bots create credits)
	static bool deposit(server::zone::objects::region::CityRegion* city, int credits, server::zone::objects::creature::CreatureObject* from);

	// CityManager::setTax: index 0 income, 1 property, 2 sales, 3 travel, 4 garage; within the tax's limits, rank 2+
	static bool setTax(server::zone::objects::region::CityRegion* city, int index, int value);

	// CityManager::changeCitySpecialization: rank 3+, the mayor's city_spec ability, its 7-day cooldown; "" clears it
	static bool setSpecialization(server::zone::objects::region::CityRegion* city, const String& spec);

	static bool setZoning(server::zone::objects::region::CityRegion* city, bool on);

	// CityManager::registerCity / unregisterCity: rank 3+ and the mayor's city_map ability to register
	static bool setRegistered(server::zone::objects::region::CityRegion* city, bool on);

	// Dev only (botSetDevHuman on): CityManager::expandCity, the City Hacks' Force Rank Up; with fullUpdate,
	// processCityUpdate, the City Hacks' Force Update (citizens, election, rank, taxes, upkeep, next update in a week)
	static bool expand(server::zone::objects::region::CityRegion* city, bool fullUpdate);

	// CityDecorationTask::placeDecoration for an item made here: at the mayor's feet, facing its way. Mayor locked.
	// Returns the decoration's object id, or 0 (logged)
	static uint64 placeDecoration(server::zone::objects::creature::CreatureObject* mayor, const String& templatePath);

	// --- Dev tools (botSetDevHuman on; for the local server) ---

	// CityManager::destroyCity: the city, its civic structures, decorations and city hall. Citizens' houses stay
	static bool destroyCity(server::zone::objects::region::CityRegion* city);

	// Destroys every structure a bot owns (its houses, its commercial buildings). Returns how many
	static int destroyOwnedStructures(server::zone::objects::creature::CreatureObject* bot);

	static bool isDevAllowed(const char* what);

	static Logger& log();

private:
	static void rememberCity(server::zone::objects::region::CityRegion* city);
	static Reference<server::zone::objects::creature::CreatureObject*> getBotMayor(server::zone::objects::region::CityRegion* city, const char* what);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTCITY_H_ */
