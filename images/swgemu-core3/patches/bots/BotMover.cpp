/*
 * BotMover (bot players, Phase 5). See BotMover.h.
 */

#include "BotMover.h"
#include "BotManager.h"
#include "BotLua.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/cell/CellObject.h"
#include "server/zone/objects/building/BuildingObject.h"
#include "server/zone/objects/scene/WorldCoordinates.h"
#include "server/zone/objects/scene/variables/ContainerPermissions.h"
#include "server/zone/managers/planet/PlanetManager.h"
#include "terrain/manager/TerrainManager.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "server/zone/managers/collision/IntersectionResults.h"
#include "server/zone/managers/collision/PathFinderManager.h"
#include "server/zone/packets/scene/UpdateTransformMessage.h"
#include "server/zone/packets/scene/UpdateTransformWithParentMessage.h"
#include "templates/params/creature/CreaturePosture.h"

namespace {

// Metres
const float CRUMB_SPACING = 1.0f;		// a new breadcrumb once the leader has moved this far, or changed cell
const int MAX_CRUMBS = 96;
const float JUMP_DIST = 6.0f;			// a hop this long into or out of a cell between two looks is a teleport (an elevator)
const float RUN_BEHIND = 8.0f;
const float CATCH_UP_DIST = 80.0f;
const float CATCH_UP_BEHIND = 10.0f;
const float OFF_TRAIL_DIST = 8.0f;		// the next breadcrumb is in another cell and this far: the bot isn't on the trail
const float NO_WAY_SNAP_DIST = 12.0f;	// no path to a leader in another room or building: appear beside it from this far
const float TOGETHER_DIST = 64.0f;		// within this the bot is with the leader, and follows it across a leap
const float MOVED_AWAY_DIST = 5.0f;		// further than this from where the mover put it: someone else moved it
const float ARRIVE_DIST = 0.3f;
const float AUTO_RUN_PATH = 30.0f;
const float CATCH_UP_SPEED = 1.1f;		// closing the gap: a little faster than the leader
const float PROGRESS_DIST = 0.05f;

Logger& moverLog() {
	static Logger logger("BotMover");
	static bool init = [] {
		logger.setGlobalLogging(true);
		logger.setLogging(true);
		return true;
	}();

	(void)init;

	return logger;
}

// A place: a cell and the coordinates in its frame (the building's), or world coordinates outdoors
class BotMovePoint : public Object {
public:
	ManagedReference<CellObject*> cell;	// nullptr outdoors
	Vector3 local;
	Vector3 world;
	bool jump = false;	// in a trail: teleport here (the leader was teleported, e.g. by an elevator)

	BotMovePoint() {
	}

	BotMovePoint(const BotMovePoint& p) : Object(), cell(p.cell), local(p.local), world(p.world), jump(p.jump) {
	}

	void set(const BotMovePoint& p) {
		cell = p.cell;
		local = p.local;
		world = p.world;
		jump = p.jump;
	}
};

typedef Vector<Reference<BotMovePoint*>> BotMovePath;

bool sameCell(const ManagedReference<CellObject*>& a, const ManagedReference<CellObject*>& b) {
	return a.get() == b.get();
}

class BotMoveEvent : public Object {
public:
	String name;
	ManagedReference<SceneObject*> other;
	String detail;
};

typedef Vector<Reference<BotMoveEvent*>> BotMoveEvents;

void addEvent(BotMoveEvents& events, const String& name, SceneObject* other, const String& detail) {
	Reference<BotMoveEvent*> event = new BotMoveEvent();
	event->name = name;
	event->other = other;
	event->detail = detail;
	events.add(event);
}

class BotMoveJob : public Object {
public:
	enum { IDLE, FOLLOW, GOTO };

	uint64 botOid = 0;
	ManagedWeakReference<CreatureObject*> bot;

	// Orders from the bindings, applied by the task at its next step; and what botMoveState shows. Under mutex
	Mutex mutex;
	uint64 orderGen = 0;
	int orderMode = IDLE;
	ManagedWeakReference<CreatureObject*> orderLeader;
	uint64 orderLeaderOid = 0;
	float orderFollowDist = 4;
	float orderSide = 0;
	BotMovePath orderPath;
	Reference<BotMovePoint*> orderGoal;
	Zone* orderZone = nullptr;
	bool orderRun = false;
	BotMovePath orderPatrol;
	int orderPace = BotMover::PACE_AUTO;
	bool scheduled = false;
	BotMoveStatus status;

	// The task's own state, with the bot locked
	uint64 appliedGen = 0;
	int mode = IDLE;
	bool moving = false;
	uint64 lastStep = 0;
	uint64 ownTeleportAt = 0;
	bool placedValid = false;
	Vector3 placedWorld;
	Zone* placedZone = nullptr;

	// Following
	ManagedWeakReference<CreatureObject*> leader;
	uint64 leaderOid = 0;
	float followDist = 4;
	float side = 0;
	BotMovePath trail;
	BotMovePoint lastSeen;
	bool lastSeenValid = false;
	Zone* lastSeenZone = nullptr;
	uint64 lastSeenAt = 0;
	bool fresh = false;
	bool together = true;
	float lastDistance = -1;
	uint64 leaderAwaySince = 0;
	bool leapPending = false;
	bool leapCopy = false;
	uint64 leapAt = 0;
	bool pathTried = false;
	uint64 stuckSince = 0;
	bool blockedLogged = false;

	// Going to a point
	BotMovePath path;
	Reference<BotMovePoint*> goal;
	Zone* goalZone = nullptr;
	bool run = false;
	uint64 gotoStuckSince = 0;
	float gotoBest = 0;		// the least way left so far, and when it last got shorter by half a metre
	uint64 gotoBestAt = 0;
	BotMovePath patrol;		// dev: a loop of goals
	int patrolIndex = 0;
	int patrolPace = BotMover::PACE_AUTO;
};

class BotMoveJobs {
public:
	Mutex mutex;
	VectorMap<uint64, Reference<BotMoveJob*>> jobs;

	BotMoveJobs() {
		jobs.setNoDuplicateInsertPlan();
	}
};

BotMoveJobs& moveJobs() {
	static BotMoveJobs jobs;

	return jobs;
}

Reference<BotMoveJob*> getJob(CreatureObject* bot, bool create) {
	BotMoveJobs& registry = moveJobs();
	Locker locker(&registry.mutex);

	uint64 oid = bot->getObjectID();
	int pos = registry.jobs.find(oid);

	if (pos != -1)
		return registry.jobs.elementAt(pos).getValue();

	if (!create)
		return nullptr;

	Reference<BotMoveJob*> job = new BotMoveJob();
	job->botOid = oid;
	job->bot = bot;
	registry.jobs.put(oid, job);

	return job;
}

const char* modeName(int mode) {
	switch (mode) {
	case BotMoveJob::FOLLOW:
		return "follow";
	case BotMoveJob::GOTO:
		return "goto";
	default:
		return "idle";
	}
}

void publish(BotMoveJob* job, const String& state, uint64 leader, float distance, bool stuck) {
	Locker locker(&job->mutex);

	job->status.state = state;
	job->status.leader = leader;
	job->status.distance = distance;
	job->status.stuck = stuck;
}

// --- Geometry ---

float normalizeRadians(float angle) {
	while (angle < 0)
		angle += 2 * M_PI;

	while (angle >= 2 * M_PI)
		angle -= 2 * M_PI;

	return angle;
}

// The heading for a step of dx, dy, as AiAgent::findNextPosition works it out
float headingOf(float dx, float dy) {
	return normalizeRadians(M_PI / 2 - atan2(dy, dx));
}

float buildingRadians(CellObject* cell) {
	SceneObject* root = cell != nullptr ? cell->getRootParent() : nullptr;

	return root != nullptr ? root->getDirection()->getRadians() : 0;
}

// A world heading in a cell's frame
float frameHeading(float worldHeading, CellObject* cell) {
	return cell == nullptr ? worldHeading : normalizeRadians(worldHeading - buildingRadians(cell));
}

Vector3 toWorld(const Vector3& local, CellObject* cell) {
	if (cell == nullptr)
		return local;

	WorldCoordinates coordinates(local, cell);

	return coordinates.getWorldPosition();
}

// The inverse of WorldCoordinates::getWorldPosition
Vector3 toLocal(const Vector3& world, CellObject* cell) {
	SceneObject* root = cell != nullptr ? cell->getRootParent() : nullptr;

	if (root == nullptr)
		return world;

	float rad = root->getDirection()->getRadians();
	float c = cos(rad);
	float s = sin(rad);
	float dx = world.getX() - root->getPositionX();
	float dy = world.getY() - root->getPositionY();

	return Vector3(dx * c - dy * s, dx * s + dy * c, world.getZ() - root->getPositionZ());
}

// Where a creature is: its cell, or outdoors (on a mount or vehicle, the vehicle's place). Reads without locking, as
// AiAgent reads what it follows. False when it isn't in the world or is inside something else
bool samplePosition(CreatureObject* creature, BotMovePoint& out) {
	ManagedReference<SceneObject*> parent = creature->getParent().get();

	out.jump = false;

	if (parent == nullptr) {
		out.cell = nullptr;
		out.local = creature->getPosition();
		out.world = out.local;
		return true;
	}

	if (parent->isCellObject()) {
		CellObject* cell = parent.castTo<CellObject*>();

		if (cell == nullptr || cell->getParent().get() == nullptr)
			return false;

		out.cell = cell;
		out.local = creature->getPosition();
		out.world = toWorld(out.local, cell);
		return true;
	}

	if ((parent->isVehicleObject() || parent->isMount()) && parent->getParent().get() == nullptr) {
		out.cell = nullptr;
		out.local = parent->getPosition();
		out.world = out.local;
		return true;
	}

	return false;
}

// The floor under x, y nearest to z, as DataTransform finds it for a player outdoors
float worldFloor(CreatureObject* bot, Zone* zone, float x, float y, float z, IntersectionResults* intersections) {
	PlanetManager* planetManager = zone->getPlanetManager();

	if (planetManager == nullptr)
		return z;

	CloseObjectsVector* closeObjects = bot->getCloseObjects();

	CollisionManager::getWorldFloorCollisions(x, y, zone, intersections, closeObjects);

	float floor = planetManager->findClosestWorldFloor(x, y, z, bot->getSwimHeight(), intersections, closeObjects);

	// It picks the floor nearest the hint, and a hint that is metres off (a crumb on a slope, a height carried over)
	// can land on a mesh under the ground. Nothing outdoors walks below the terrain: shooting from there has no line of sight
	float terrain = zone->getHeight(x, y);

	if (floor < terrain - 0.5f)
		floor = terrain;

	return floor;
}

// The cell's floor mesh under x, y nearest to z. False if the point is off the floor
bool cellFloor(CellObject* cell, float x, float y, float z, float& out) {
	UniqueReference<Vector<float>*> floors(CollisionManager::getCellFloorCollision(x, y, cell));

	if (floors == nullptr || floors->size() == 0)
		return false;

	float best = floors->get(0);

	for (int i = 1; i < floors->size(); ++i) {
		if (fabs(floors->get(i) - z) < fabs(best - z))
			best = floors->get(i);
	}

	out = best;

	return true;
}

float pathLength(const Vector3& from, const BotMovePath& path) {
	float length = 0;
	Vector3 previous = from;

	for (int i = 0; i < path.size(); ++i) {
		const BotMovePoint* point = path.get(i);

		if (!point->jump)
			length += previous.distanceTo2d(point->world);

		previous = point->world;
	}

	return length;
}

// --- Rules ---

// Walking waits while it sits, lies, performs, is incapacitated or dead, or can't move
bool isPaused(CreatureObject* bot) {
	return bot->getPosture() != CreaturePosture::UPRIGHT || bot->isIncapacitated() || bot->isDead() || bot->isDancing()
		|| bot->isPlayingMusic() || !bot->isMovementAllowed() || bot->isFrozen() || bot->isRidingMount();
}

// DataTransformWithParent's checks for stepping into a cell: the building's entry rules and the cell's WALKIN permission
bool canEnter(CreatureObject* bot, CellObject* cell) {
	ManagedReference<SceneObject*> root = cell->getParent().get();

	if (root == nullptr || root->getZone() == nullptr)
		return false;

	Reference<PlayerObject*> ghost = bot->getPlayerObject();
	bool privileged = ghost != nullptr && ghost->isPrivileged();

	if (root->isBuildingObject()) {
		BuildingObject* building = root->asBuildingObject();

		if (building == nullptr || (!privileged && !building->isAllowedEntry(bot)))
			return false;
	}

	const ContainerPermissions* permissions = cell->getContainerPermissions();

	if (permissions == nullptr)
		return false;

	return permissions->hasInheritPermissionsFromParent() || cell->checkContainerPermission(bot, ContainerPermissions::WALKIN);
}

float runSpeedOf(CreatureObject* creature) {
	float mod = creature->getSpeedMultiplierMod();

	return creature->getRunSpeed() * (mod > 0 ? mod : 1.f);
}

float walkSpeedOf(CreatureObject* creature) {
	float mod = creature->getSpeedMultiplierMod();

	return creature->getWalkSpeed() * (mod > 0 ? mod : 1.f);
}

// --- Moving the body ---

// One movement update, as the server applies a client's transform: position, direction, speed, locomotion, the
// movement counter, the zone (with the packets), the validated position
void place(BotMoveJob* job, CreatureObject* bot, Zone* zone, BotMovePoint& to, const Vector3& fromWorld, float speed) {
	float x = to.local.getX();
	float y = to.local.getY();
	float z = to.local.getZ();

	IntersectionResults intersections;

	if (to.cell == nullptr) {
		z = worldFloor(bot, zone, x, y, z, &intersections);
	} else {
		float floor;

		if (cellFloor(to.cell, x, y, z, floor))
			z = floor;
	}

	to.local.setZ(z);
	to.world = to.cell == nullptr ? to.local : toWorld(to.local, to.cell);

	float dx = to.world.getX() - fromWorld.getX();
	float dy = to.world.getY() - fromWorld.getY();

	if (dx * dx + dy * dy > 0.0001f)
		bot->setDirection(frameHeading(headingOf(dx, dy), to.cell));

	bot->setPosition(x, z, y);
	bot->setCurrentSpeed(speed);
	bot->updateLocomotion();
	bot->incrementMovementCounter();

	if (to.cell != nullptr) {
		bot->updateZoneWithParent(to.cell.get(), true, true);
	} else {
		bot->updateZone(true, true);

		ZoneServer* zoneServer = bot->getZoneServer();
		PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

		if (playerManager != nullptr)
			playerManager->updateSwimmingState(bot, z, &intersections, bot->getCloseObjects());
	}

	Reference<PlayerObject*> ghost = bot->getPlayerObject();

	if (ghost != nullptr)
		ghost->updateLastValidatedPosition();

	job->moving = true;
	job->placedWorld = to.world;
	job->placedZone = zone;
	job->placedValid = true;
}

// Speed 0 and a full transform, as a client's last update when it stops; facing faceWorld if given
void stopMoving(BotMoveJob* job, CreatureObject* bot, const Vector3* faceWorld) {
	bot->setCurrentSpeed(0);
	bot->updateLocomotion();

	BotMovePoint here;

	if (faceWorld != nullptr && samplePosition(bot, here)) {
		float dx = faceWorld->getX() - here.world.getX();
		float dy = faceWorld->getY() - here.world.getY();

		if (dx * dx + dy * dy > 0.01f)
			bot->setDirection(frameHeading(headingOf(dx, dy), here.cell));
	}

	bot->incrementMovementCounter();

	ManagedReference<SceneObject*> parent = bot->getParent().get();

	if (parent != nullptr && parent->isCellObject())
		bot->broadcastMessage(new UpdateTransformWithParentMessage(bot), false);
	else
		bot->broadcastMessage(new UpdateTransformMessage(bot), false);

	job->moving = false;
}

void teleportTo(BotMoveJob* job, CreatureObject* bot, const BotMovePoint& point) {
	if (job->moving) {
		bot->setCurrentSpeed(0);
		bot->updateLocomotion();
		job->moving = false;
	}

	float z = point.local.getZ();
	Zone* zone = bot->getZone();

	if (point.cell == nullptr && zone != nullptr) {
		IntersectionResults intersections;

		z = worldFloor(bot, zone, point.local.getX(), point.local.getY(), z, &intersections);
	}

	bot->teleport(point.local.getX(), z, point.local.getY(), point.cell != nullptr ? point.cell->getObjectID() : 0);

	job->ownTeleportAt = System::getMiliTime();
	job->placedValid = false;
}

class BotMoveResult {
public:
	float moved = 0;
	bool blocked = false;	// a cell it may not enter is next
	bool teleported = false;
	bool reachedFinal = false;
};

// Walks up to `budget` metres along `points` (consumed as it passes them), then toward `finalPoint` if given and the list
// is done. A point in another frame is reached in this frame, then the bot changes frame on it: that's the doorway
BotMoveResult advance(BotMoveJob* job, CreatureObject* bot, Zone* zone, const BotMovePoint& here, BotMovePath& points,
		const BotMovePoint* finalPoint, float budget, float speed) {
	BotMoveResult result;
	BotMovePoint current(here);
	float left = budget;
	bool walked = false;

	while (left > 0.001f) {
		bool isFinal = points.isEmpty();
		const BotMovePoint* next = isFinal ? finalPoint : points.get(0).get();

		if (next == nullptr)
			break;

		if (next->cell != nullptr && !sameCell(next->cell, current.cell) && !canEnter(bot, next->cell)) {
			result.blocked = true;
			break;
		}

		if (next->jump) {
			if (walked)
				break;	// this step walks, the next one jumps

			BotMovePoint target(*next);

			if (!isFinal)
				points.remove(0);

			teleportTo(job, bot, target);
			result.teleported = true;

			return result;
		}

		float distance = current.world.distanceTo2d(next->world);

		if (distance <= left) {
			current.set(*next);
			current.jump = false;
			left -= distance;
			result.moved += distance;
			walked = true;

			if (isFinal) {
				result.reachedFinal = true;
				break;
			}

			points.remove(0);
		} else {
			float t = left / distance;
			Vector3 world = current.world + (next->world - current.world) * t;

			if (current.cell == nullptr) {
				current.local = world;
			} else if (sameCell(current.cell, next->cell)) {
				current.local = current.local + (next->local - current.local) * t;
			} else {
				current.local = toLocal(world, current.cell);	// still on this side of the doorway
			}

			current.world = world;
			result.moved += left;
			left = 0;
			walked = true;
		}
	}

	if (walked)
		place(job, bot, zone, current, here.world, speed);

	return result;
}

// A way from `from` to `to` with PathFinderManager, without the starting point. In and out of one building (or
// outdoors) it's one findPath; the outdoor leg into a building is pathed on the navmesh; across two buildings the bot
// goes out by the first one's exit to the second one's entrance
bool findWay(Zone* zone, const BotMovePoint& from, const BotMovePoint& to, BotMovePath& out) {
	PathFinderManager* finder = PathFinderManager::instance();

	ManagedReference<SceneObject*> fromRoot = from.cell != nullptr ? from.cell->getParent().get() : nullptr;
	ManagedReference<SceneObject*> toRoot = to.cell != nullptr ? to.cell->getParent().get() : nullptr;

	WorldCoordinates start(from.local, from.cell);
	WorldCoordinates end(to.local, to.cell);

	Vector<WorldCoordinates> way;

	if (toRoot != nullptr && fromRoot != toRoot) {
		// Into a building: its own path graph from the nearest entrance, which is the first outdoor point after the start
		WorldCoordinates outside(from.world, nullptr);
		Vector<WorldCoordinates>* inPath = finder->findPath(outside, end, zone);

		if (inPath == nullptr || inPath->size() < 2) {
			delete inPath;
			return false;
		}

		int entrance = -1;

		for (int i = 1; i < inPath->size(); ++i) {
			if (inPath->get(i).getCell() != nullptr)
				break;

			entrance = i;
		}

		Vector<WorldCoordinates>* outPath = nullptr;

		if (entrance != -1) {
			// To the entrance: out of the first building by its exit (cell to world), or on the navmesh outdoors
			WorldCoordinates door(inPath->get(entrance).getPoint(), nullptr);
			outPath = finder->findPath(start, door, zone);
		}

		if (outPath != nullptr) {
			for (int i = 0; i < outPath->size(); ++i)
				way.add(outPath->get(i));

			for (int i = entrance + 1; i < inPath->size(); ++i)
				way.add(inPath->get(i));

			delete outPath;
		} else if (fromRoot == nullptr) {
			for (int i = 0; i < inPath->size(); ++i)
				way.add(inPath->get(i));
		} else {
			delete inPath;
			return false;
		}

		delete inPath;
	} else {
		// Outdoors, within one building, or out of one
		Vector<WorldCoordinates>* path = finder->findPath(start, end, zone);

		if (path == nullptr) {
			if (from.cell != nullptr || to.cell != nullptr)
				return false;

			way.add(start);
			way.add(end);
		} else {
			for (int i = 0; i < path->size(); ++i)
				way.add(path->get(i));

			delete path;
		}
	}

	Vector3 previous = from.world;

	for (int i = 0; i < way.size(); ++i) {
		const WorldCoordinates& coordinates = way.get(i);

		Reference<BotMovePoint*> point = new BotMovePoint();
		point->cell = coordinates.getCell();
		point->local = coordinates.getPoint();
		point->world = coordinates.getWorldPosition();

		if (point->world.distanceTo(previous) < 0.05f && sameCell(point->cell, out.isEmpty() ? from.cell : out.get(out.size() - 1)->cell))
			continue;

		previous = point->world;
		out.add(point);
	}

	// End exactly on the goal
	if (out.isEmpty() || out.get(out.size() - 1)->world.distanceTo2d(to.world) > 0.05f || !sameCell(out.get(out.size() - 1)->cell, to.cell)) {
		Reference<BotMovePoint*> point = new BotMovePoint(to);
		point->jump = false;
		out.add(point);
	}

	return true;
}

// A place a couple of metres behind the leader and a little to the side: outdoors on the floor, in a cell only where
// there's floor (else the leader's own spot)
void spotNear(CreatureObject* leader, const BotMovePoint& seen, float side, Zone* zone, BotMovePoint& out) {
	out.set(seen);
	out.jump = false;

	float heading = leader->getDirection()->getRadians();	// in the cell's frame when it's in one, like the position
	float back = 2.5f;

	// Forward for a heading h is (sin h, cos h); the right side is (cos h, -sin h). In a cell this is all in its frame
	float dx = -sin(heading) * back + cos(heading) * side;
	float dy = -cos(heading) * back - sin(heading) * side;

	if (seen.cell == nullptr) {
		float x = seen.local.getX() + dx;
		float y = seen.local.getY() + dy;
		float z = zone != nullptr ? CollisionManager::getWorldFloorCollision(x, y, seen.local.getZ() + 0.5f, zone, false) : seen.local.getZ();

		out.local = Vector3(x, y, z);
		out.world = out.local;
		return;
	}

	float x = seen.local.getX() + dx * 0.5f;
	float y = seen.local.getY() + dy * 0.5f;
	float floor;

	if (cellFloor(seen.cell, x, y, seen.local.getZ(), floor) && fabs(floor - seen.local.getZ()) < 1.0f) {
		out.local = Vector3(x, y, floor);
		out.world = toWorld(out.local, seen.cell);
	}
}

// --- Following ---

void rememberSeen(BotMoveJob* job, const BotMovePoint& seen, Zone* zone, uint64 now) {
	job->lastSeen.set(seen);
	job->lastSeenValid = true;
	job->lastSeenZone = zone;
	job->lastSeenAt = now;
}

void trimTrail(BotMoveJob* job) {
	while (job->trail.size() > MAX_CRUMBS)
		job->trail.remove(0);
}

// A breadcrumb when the leader moved a metre or changed cell; a jump into or out of a cell (an elevator, a teleport)
// is marked so the bot copies it
void recordCrumb(BotMoveJob* job, CreatureObject* leader, const BotMovePoint& seen, Zone* zone, uint64 now) {
	const BotMovePoint* last = job->trail.isEmpty() ? nullptr : job->trail.get(job->trail.size() - 1).get();
	bool previous = job->lastSeenValid && job->lastSeenZone == zone;

	if (previous) {
		float hop = seen.world.distanceTo(job->lastSeen.world);
		float rise = fabs(seen.world.getZ() - job->lastSeen.world.getZ());
		float elapsed = (float)(now - job->lastSeenAt) / 1000.f;
		float allowed = Math::max(JUMP_DIST, runSpeedOf(leader) * 2.f * elapsed);
		bool indoors = seen.cell != nullptr || job->lastSeen.cell != nullptr;

		// Too far for running, or straight up or down (an elevator lift is a teleport in its cell)
		if (indoors && (hop > allowed || (rise > 2.5f && rise > hop * 0.8f))) {
			// Walk to where it was, then jump where it went
			if (last == nullptr || last->world.distanceTo(job->lastSeen.world) > 0.1f || !sameCell(last->cell, job->lastSeen.cell)) {
				Reference<BotMovePoint*> before = new BotMovePoint(job->lastSeen);
				before->jump = false;
				job->trail.add(before);
			}

			Reference<BotMovePoint*> after = new BotMovePoint(seen);
			after->jump = true;
			job->trail.add(after);

			trimTrail(job);
			return;
		}
	}

	if (last != nullptr && sameCell(seen.cell, last->cell) && seen.world.distanceTo2d(last->world) < CRUMB_SPACING)
		return;

	Reference<BotMovePoint*> crumb = new BotMovePoint(seen);
	crumb->jump = false;

	// Outdoors each bot keeps to its own side of the leader's track, so a crew doesn't walk in single file
	if (seen.cell == nullptr && previous && job->lastSeen.cell == nullptr && job->side != 0) {
		float dx = seen.world.getX() - job->lastSeen.world.getX();
		float dy = seen.world.getY() - job->lastSeen.world.getY();
		float length = sqrt(dx * dx + dy * dy);

		if (length > 0.01f) {
			Vector3 offset(dy / length * job->side, -dx / length * job->side, 0);

			crumb->local = seen.local + offset;
			crumb->world = crumb->local;
		}
	}

	job->trail.add(crumb);
	trimTrail(job);
}

bool trailHasJump(const BotMovePath& trail) {
	for (int i = 0; i < trail.size(); ++i) {
		if (trail.get(i)->jump)
			return true;
	}

	return false;
}

// The leader's trail came back past the bot (a loop): skip to there
void skipLoops(BotMoveJob* job, const BotMovePoint& here) {
	int best = -1;

	for (int i = 0; i < job->trail.size(); ++i) {
		const BotMovePoint* crumb = job->trail.get(i);

		if (crumb->jump)
			break;

		if (sameCell(crumb->cell, here.cell) && fabs(crumb->world.getZ() - here.world.getZ()) < 2.f) {
			float dx = crumb->world.getX() - here.world.getX();
			float dy = crumb->world.getY() - here.world.getY();

			if (dx * dx + dy * dy < 1.f)
				best = i;
		}
	}

	if (best > 0)
		job->trail.removeRange(0, best);
}

// Appear about 10 m behind the leader on its trail (or near it, with no trail), as a player who ran to catch up
bool catchUp(BotMoveJob* job, CreatureObject* bot, CreatureObject* leader, const BotMovePoint& seen, Zone* zone, const char* why) {
	// Back along the trail from the leader, but not back past a jump's landing point
	int index = -1;
	float behind = 0;
	Vector3 previous = seen.world;

	for (int i = job->trail.size() - 1; i >= 0; --i) {
		const BotMovePoint* crumb = job->trail.get(i);

		behind += previous.distanceTo2d(crumb->world);
		previous = crumb->world;
		index = i;

		if (behind >= CATCH_UP_BEHIND || crumb->jump)
			break;
	}

	BotMovePoint target;

	if (index != -1 && behind >= 2.f)
		target.set(*job->trail.get(index));
	else
		spotNear(leader, seen, job->side, zone, target);

	target.jump = false;

	if (target.cell != nullptr && !canEnter(bot, target.cell)) {
		if (!job->blockedLogged) {
			moverLog().info(true) << "BotMover: " << bot->getFirstName() << " can't catch up with " << leader->getFirstName()
				<< ": no entry to cell " << target.cell->getObjectID();
			job->blockedLogged = true;
		}

		return false;
	}

	if (index != -1)
		job->trail.removeRange(0, index + 1);
	else
		job->trail.removeAll();

	teleportTo(job, bot, target);

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " caught up with " << leader->getFirstName() << " (" << why
		<< ", " << (int)job->lastDistance << " m away)";

	return true;
}

// Follow the leader across a leap: another planet (switchZone), or far on this one (a teleport)
void followLeap(BotMoveJob* job, CreatureObject* bot, CreatureObject* leader, const BotMovePoint& seen, Zone* zone, Zone* leaderZone, uint64 now) {
	BotMovePoint spot;
	spotNear(leader, seen, job->side, leaderZone, spot);

	if (spot.cell != nullptr && !canEnter(bot, spot.cell))
		spot.set(seen);

	job->trail.removeAll();

	if (leaderZone == zone) {
		teleportTo(job, bot, spot);
	} else {
		if (job->moving) {
			bot->setCurrentSpeed(0);
			bot->updateLocomotion();
			job->moving = false;
		}

		bot->switchZone(leaderZone->getZoneName(), spot.local.getX(), spot.local.getZ(), spot.local.getY(),
				spot.cell != nullptr ? spot.cell->getObjectID() : 0);

		job->placedValid = false;
	}

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " followed " << leader->getFirstName() << " to "
		<< leaderZone->getZoneName() << " " << (int)spot.world.getX() << " " << (int)spot.world.getY()
		<< (spot.cell != nullptr ? " in cell " + String::valueOf(spot.cell->getObjectID()) : String(""));
}

void tickFollow(BotMoveJob* job, CreatureObject* bot, Zone* zone, const BotMovePoint& here, float dt, uint64 now, BotMoveEvents& events) {
	ManagedReference<CreatureObject*> leader = job->leader.get();
	Reference<PlayerObject*> leaderGhost = leader != nullptr ? leader->getPlayerObject() : nullptr;
	Zone* leaderZone = leader != nullptr ? leader->getZone() : nullptr;
	bool present = leaderZone != nullptr && (leaderGhost == nullptr || leaderGhost->isOnline());

	// Logged out, link-dead or gone: wait for it as long as Core3 keeps a link-dead player
	if (!present) {
		if (job->leaderAwaySince == 0) {
			job->leaderAwaySince = now;
			moverLog().info(true) << "BotMover: " << bot->getFirstName() << "'s leader " << job->leaderOid << " is away, waiting";
		}

		if (job->moving)
			stopMoving(job, bot, nullptr);

		if (now - job->leaderAwaySince >= (uint64)BotMover::LEADER_GONE_MS) {
			moverLog().info(true) << "BotMover: " << bot->getFirstName() << "'s leader " << job->leaderOid << " is gone, stopping";

			job->mode = BotMoveJob::IDLE;
			job->trail.removeAll();
			addEvent(events, "leaderGone", leader, String::valueOf(job->leaderOid));
			publish(job, "idle", 0, 0, false);
			return;
		}

		publish(job, "follow", job->leaderOid, -1, false);
		return;
	}

	job->leaderAwaySince = 0;

	BotMovePoint seen;

	if (!samplePosition(leader, seen)) {
		if (job->moving)
			stopMoving(job, bot, nullptr);

		publish(job, "follow", job->leaderOid, -1, false);
		return;
	}

	bool loading = leaderGhost != nullptr && leaderGhost->isOnLoadScreen();
	bool sameZone = leaderZone == zone;

	if (job->fresh) {
		// Ordered to follow a leader on another planet: it waits until the leader comes to it
		job->fresh = false;
		job->together = sameZone;

		if (!sameZone) {
			job->leapPending = true;
			job->leapCopy = false;
			job->leapAt = 0;
		}
	}

	// A leap: another planet, a load screen (a shuttle), or far on this planet in one look (a teleport)
	bool farHop = job->lastSeenValid && job->lastSeenZone == leaderZone && seen.world.distanceTo2d(job->lastSeen.world) > TOGETHER_DIST;

	if ((!sameZone || loading || farHop) && !job->leapPending) {
		job->leapPending = true;
		job->leapCopy = job->together && job->lastDistance >= 0 && job->lastDistance <= TOGETHER_DIST;
		job->leapAt = 0;
		job->trail.removeAll();

		if (job->moving)
			stopMoving(job, bot, nullptr);

		moverLog().info(true) << "BotMover: " << bot->getFirstName() << "'s leader " << leader->getFirstName() << " left ("
			<< (!sameZone ? "for " + leaderZone->getZoneName() : String(loading ? "load screen" : "teleport")) << "), "
			<< (job->leapCopy ? "following" : "too far to follow") << ", last " << (int)job->lastDistance << " m";
	}

	if (job->leapPending) {
		float distance = sameZone ? here.world.distanceTo2d(seen.world) : -1;

		if (loading) {
			job->leapAt = 0;
			publish(job, job->leapCopy ? "zoning" : "follow", job->leaderOid, distance, !job->leapCopy);
			return;
		}

		if (!job->leapCopy) {
			if (!sameZone || distance > TOGETHER_DIST) {
				rememberSeen(job, seen, leaderZone, now);
				publish(job, "follow", job->leaderOid, distance, true);
				return;
			}

			// It came back to the bot
			job->leapPending = false;
			job->together = true;
		} else {
			if (job->leapAt == 0)
				job->leapAt = now + BotMover::LEAP_DELAY_MIN_MS + System::random(BotMover::LEAP_DELAY_MAX_MS - BotMover::LEAP_DELAY_MIN_MS);

			if (now < job->leapAt) {
				rememberSeen(job, seen, leaderZone, now);
				publish(job, "zoning", job->leaderOid, distance, false);
				return;
			}

			job->leapPending = false;
			followLeap(job, bot, leader, seen, zone, leaderZone, now);
			rememberSeen(job, seen, leaderZone, now);
			publish(job, "zoning", job->leaderOid, distance, false);
			return;
		}
	}

	float distance = here.world.distanceTo2d(seen.world);

	job->lastDistance = distance;

	if (distance <= TOGETHER_DIST)
		job->together = true;

	recordCrumb(job, leader, seen, zone, now);
	rememberSeen(job, seen, zone, now);

	bool paused = isPaused(bot);

	if (!job->together) {
		// Moved away from the leader by someone else: wait until it's back within 64 m
		if (job->moving)
			stopMoving(job, bot, nullptr);

		publish(job, "follow", job->leaderOid, distance, true);
		return;
	}

	// Fallen far behind (a speeder, or it was busy): appear about 10 m behind the leader
	if (!paused && distance > CATCH_UP_DIST) {
		catchUp(job, bot, leader, seen, zone, "far behind");
		publish(job, "follow", job->leaderOid, distance, false);
		return;
	}

	bool sameFrame = sameCell(here.cell, seen.cell);

	if (sameFrame)
		job->pathTried = false;

	// The leader in plain sight: the trail behind the bot doesn't matter any more
	// (keeping its last look, so the trail still starts where the bot is if the leader now goes through a door)
	if (sameFrame && distance <= job->followDist + 1.5f && !trailHasJump(job->trail) && job->trail.size() > 1)
		job->trail.removeRange(0, job->trail.size() - 1);

	skipLoops(job, here);

	const BotMovePoint* last = job->trail.isEmpty() ? nullptr : job->trail.get(job->trail.size() - 1).get();
	float remaining = last == nullptr ? distance : pathLength(here.world, job->trail) + last->world.distanceTo2d(seen.world);
	bool wantMove = remaining > job->followDist + (job->moving ? 0.25f : 1.5f);

	if (paused || !wantMove) {
		if (job->moving)
			stopMoving(job, bot, &seen.world);

		job->stuckSince = 0;
		publish(job, "follow", job->leaderOid, distance, false);
		return;
	}

	// No trail to walk, or a trail that doesn't start where the bot is (the leader went through a door the bot didn't
	// see) and a wall between: find a way once, to where the leader is now
	bool offTrail = !job->trail.isEmpty() && !job->trail.get(0)->jump && !sameCell(job->trail.get(0)->cell, here.cell)
			&& job->trail.get(0)->world.distanceTo2d(here.world) > OFF_TRAIL_DIST;

	if (((job->trail.isEmpty() && !sameFrame) || offTrail) && !job->pathTried) {
		job->pathTried = true;

		BotMovePath way;

		if (findWay(zone, here, seen, way)) {
			moverLog().info(true) << "BotMover: " << bot->getFirstName() << " found a way to " << leader->getFirstName() << ": "
				<< way.size() << " points, " << (int)pathLength(here.world, way) << " m (" << (offTrail ? "off the trail" : "no trail")
				<< ", cell " << (here.cell != nullptr ? here.cell->getObjectID() : 0) << " to " << (seen.cell != nullptr ? seen.cell->getObjectID() : 0)
				<< ", first crumb cell " << (offTrail && job->trail.get(0)->cell != nullptr ? job->trail.get(0)->cell->getObjectID() : 0) << ")";

			// The last point is the leader's spot; the bot stops short of it anyway
			job->trail.removeAll();

			for (int i = 0; i < way.size(); ++i)
				job->trail.add(way.get(i));

			trimTrail(job);
			remaining = pathLength(here.world, job->trail);
		} else if (distance > NO_WAY_SNAP_DIST) {
			// Two buildings, or a room the paths don't know: don't walk through the walls
			job->trail.removeAll();
			catchUp(job, bot, leader, seen, zone, "no way");
			publish(job, "follow", job->leaderOid, distance, false);
			return;
		}
	}

	bool leaderRunning = leader->getCurrentSpeed() > (walkSpeedOf(leader) + runSpeedOf(leader)) * 0.5f;
	bool running = remaining > RUN_BEHIND || leaderRunning;
	float speed = running ? runSpeedOf(bot) : walkSpeedOf(bot);

	if (running && remaining > job->followDist + 3.f)
		speed *= CATCH_UP_SPEED;

	float budget = Math::min(speed * dt, remaining - job->followDist);

	// After the trail, straight on to the leader when the bot is in its frame
	const BotMovePoint* finalPoint = nullptr;

	if (job->trail.isEmpty() ? sameFrame : sameCell(job->trail.get(job->trail.size() - 1)->cell, seen.cell))
		finalPoint = &seen;

	BotMoveResult result = advance(job, bot, zone, here, job->trail, finalPoint, budget, speed);

	if (result.blocked) {
		if (job->moving)
			stopMoving(job, bot, &seen.world);

		// Forget the way inside: when the leader comes back out, the bot picks up its trail from the door
		while (!job->trail.isEmpty()) {
			const BotMovePoint* next = job->trail.get(0);

			if (next->cell == nullptr || sameCell(next->cell, here.cell) || canEnter(bot, next->cell))
				break;

			job->trail.remove(0);
		}

		if (!job->blockedLogged) {
			moverLog().info(true) << "BotMover: " << bot->getFirstName() << " may not enter where " << leader->getFirstName() << " went, waiting";
			job->blockedLogged = true;
		}

		job->stuckSince = 0;
		publish(job, "follow", job->leaderOid, distance, true);
		return;
	}

	job->blockedLogged = false;

	if (result.teleported || result.moved >= PROGRESS_DIST) {
		job->stuckSince = 0;
	} else if (job->stuckSince == 0) {
		job->stuckSince = now;
	} else if (now - job->stuckSince >= (uint64)BotMover::STUCK_MS) {
		job->stuckSince = 0;
		catchUp(job, bot, leader, seen, zone, "stuck");
	}

	publish(job, "follow", job->leaderOid, distance, job->stuckSince != 0 && now - job->stuckSince >= 2000);
}

// --- Going to a point ---

void finishGoto(BotMoveJob* job, CreatureObject* bot, Zone* zone, const BotMovePoint& here, BotMoveEvents& events) {
	if (job->moving)
		stopMoving(job, bot, nullptr);

	// Dev patrol: on to the next point
	if (!job->patrol.isEmpty()) {
		job->patrolIndex = (job->patrolIndex + 1) % job->patrol.size();

		BotMovePath way;
		BotMovePoint* next = job->patrol.get(job->patrolIndex);

		if (findWay(zone, here, *next, way)) {
			job->path = way;
			job->goal = new BotMovePoint(*next);
			job->run = job->patrolPace == BotMover::PACE_RUN || (job->patrolPace == BotMover::PACE_AUTO && pathLength(here.world, way) > AUTO_RUN_PATH);
			job->gotoStuckSince = 0;
			job->gotoBestAt = 0;

			moverLog().info(true) << "BotMover: " << bot->getFirstName() << " patrol leg " << job->patrolIndex << ", " << way.size() << " points";

			publish(job, "goto", 0, pathLength(here.world, job->path), false);
			return;
		}

		moverLog().info(true) << "BotMover: " << bot->getFirstName() << " patrol has no way to point " << job->patrolIndex << ", stopping";
		job->patrol.removeAll();
	}

	job->mode = BotMoveJob::IDLE;
	job->path.removeAll();

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " arrived";

	addEvent(events, "arrived", nullptr, "");
	publish(job, "idle", 0, 0, false);
}

void giveUp(BotMoveJob* job, CreatureObject* bot, const String& why, BotMoveEvents& events) {
	if (job->moving)
		stopMoving(job, bot, nullptr);

	job->mode = BotMoveJob::IDLE;
	job->path.removeAll();
	job->patrol.removeAll();

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " gave up going to a point (" << why << ")";

	addEvent(events, "stuck", nullptr, why);
	publish(job, "idle", 0, 0, true);
}

void tickGoto(BotMoveJob* job, CreatureObject* bot, Zone* zone, const BotMovePoint& here, float dt, uint64 now, BotMoveEvents& events) {
	if (job->goalZone != zone) {
		giveUp(job, bot, "zone", events);
		return;
	}

	float remaining = pathLength(here.world, job->path);

	if (job->path.isEmpty() || remaining < ARRIVE_DIST) {
		finishGoto(job, bot, zone, here, events);
		return;
	}

	if (isPaused(bot)) {
		if (job->moving)
			stopMoving(job, bot, nullptr);

		job->gotoStuckSince = 0;
		job->gotoBestAt = 0;
		publish(job, "goto", 0, remaining, false);
		return;
	}

	float speed = job->run ? runSpeedOf(bot) : walkSpeedOf(bot);
	BotMoveResult result = advance(job, bot, zone, here, job->path, nullptr, speed * dt, speed);

	if (result.blocked) {
		giveUp(job, bot, "noEntry", events);
		return;
	}

	if (result.teleported || result.moved >= PROGRESS_DIST) {
		job->gotoStuckSince = 0;
	} else if (job->gotoStuckSince == 0) {
		job->gotoStuckSince = now;
	} else if (now - job->gotoStuckSince >= (uint64)BotMover::GOTO_STUCK_MS) {
		giveUp(job, bot, "blocked", events);
		return;
	}

	// Walking but not getting there (jittering at a point): the way left must shrink
	if (job->gotoBestAt == 0 || result.teleported || remaining < job->gotoBest - 0.5f) {
		job->gotoBest = remaining;
		job->gotoBestAt = now;
	} else if (now - job->gotoBestAt >= (uint64)BotMover::GOTO_STUCK_MS) {
		giveUp(job, bot, "blocked", events);
		return;
	}

	if (job->path.isEmpty()) {
		BotMovePoint there;

		if (samplePosition(bot, there))
			finishGoto(job, bot, zone, there, events);

		return;
	}

	publish(job, "goto", 0, Math::max(0.f, remaining - result.moved), false);
}

// --- The step ---

void applyOrder(BotMoveJob* job) {
	Locker locker(&job->mutex);

	if (job->orderGen == job->appliedGen)
		return;

	job->appliedGen = job->orderGen;
	job->mode = job->orderMode;

	job->trail.removeAll();
	job->path.removeAll();
	job->patrol.removeAll();
	job->lastSeenValid = false;
	job->leapPending = false;
	job->leaderAwaySince = 0;
	job->stuckSince = 0;
	job->gotoStuckSince = 0;
	job->gotoBestAt = 0;
	job->pathTried = false;
	job->blockedLogged = false;
	job->lastDistance = -1;
	job->placedValid = false;

	if (job->mode == BotMoveJob::FOLLOW) {
		job->leader = job->orderLeader;
		job->leaderOid = job->orderLeaderOid;
		job->followDist = job->orderFollowDist;
		job->side = job->orderSide;
		job->fresh = true;
		job->together = true;
	} else if (job->mode == BotMoveJob::GOTO) {
		job->path = job->orderPath;
		job->goal = job->orderGoal;
		job->goalZone = job->orderZone;
		job->run = job->orderRun;
		job->patrol = job->orderPatrol;
		job->patrolIndex = 0;
		job->patrolPace = job->orderPace;
	}

	job->orderPath.removeAll();
	job->orderPatrol.removeAll();
}

// One step with the bot locked: the milliseconds to the next, or 0 when there's nothing left to do
int step(BotMoveJob* job, CreatureObject* bot, BotMoveEvents& events) {
	uint64 now = System::getMiliTime();

	applyOrder(job);

	Reference<PlayerObject*> ghost = bot->getPlayerObject();

	if (ghost == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		// Logging out or gone: no more walking. The jobs give new orders after the next login
		if (job->mode != BotMoveJob::IDLE)
			moverLog().info(true) << "BotMover: " << bot->getFirstName() << " is offline, dropping its " << modeName(job->mode);

		job->mode = BotMoveJob::IDLE;
		job->moving = false;
		job->trail.removeAll();
		job->path.removeAll();
		job->patrol.removeAll();
		publish(job, "idle", 0, 0, false);
		return 0;
	}

	if (job->mode == BotMoveJob::IDLE) {
		if (job->moving)
			stopMoving(job, bot, nullptr);

		publish(job, "idle", 0, 0, false);
		return 0;
	}

	float dt = job->lastStep == 0 ? (BotMover::STEP_MIN_MS + BotMover::STEP_RANDOM_MS / 2) / 1000.f : (float)(now - job->lastStep) / 1000.f;

	dt = Math::max(0.05f, Math::min(dt, 1.0f));
	job->lastStep = now;

	// A teleport of ours (catching up, copying an elevator): acknowledged as a client would, a moment later
	if (ghost->isTeleporting() && !ghost->isOnLoadScreen() && job->ownTeleportAt != 0 && now - job->ownTeleportAt >= 300) {
		ghost->setTeleporting(false);
		job->ownTeleportAt = 0;
	}

	Zone* zone = bot->getZone();

	if (zone == nullptr || ghost->isOnLoadScreen() || ghost->isTeleporting()) {
		job->moving = false;
		publish(job, "zoning", job->mode == BotMoveJob::FOLLOW ? job->leaderOid : 0, -1, false);
		return BotMover::WAIT_MS;
	}

	BotMovePoint here;

	if (!samplePosition(bot, here)) {
		publish(job, modeName(job->mode), job->mode == BotMoveJob::FOLLOW ? job->leaderOid : 0, -1, true);
		return BotMover::WAIT_MS;
	}

	// Below the terrain outdoors (a bad height from a teleport, a spawn): stand on the ground, or nothing it does has line of sight
	if (here.cell == nullptr && bot->getParent().get() == nullptr && here.world.getZ() < zone->getHeight(here.world.getX(), here.world.getY()) - 1.0f) {
		moverLog().info(true) << "BotMover: " << bot->getFirstName() << " was under the ground (" << here.world.getZ() << " at "
			<< (int)here.world.getX() << " " << (int)here.world.getY() << "), standing it on the terrain";

		BotMovePoint fixed(here);

		place(job, bot, zone, fixed, here.world, 0);
		stopMoving(job, bot, nullptr);

		here.set(fixed);
		job->placedValid = false;
	}

	// Moved by someone else (a teleport, cloning, a zone switch it didn't make): its trail or path no longer fits
	if (job->placedValid && (job->placedZone != zone || here.world.distanceTo2d(job->placedWorld) > MOVED_AWAY_DIST)) {
		moverLog().info(true) << "BotMover: " << bot->getFirstName() << " was moved (" << (int)here.world.distanceTo2d(job->placedWorld)
			<< " m), dropping its " << (job->mode == BotMoveJob::FOLLOW ? "trail" : "path");

		job->placedValid = false;
		job->moving = false;
		job->trail.removeAll();
		job->pathTried = false;

		if (job->mode == BotMoveJob::FOLLOW) {
			ManagedReference<CreatureObject*> leader = job->leader.get();
			Zone* leaderZone = leader != nullptr ? leader->getZone() : nullptr;

			BotMovePoint there;

			job->together = leaderZone == zone && samplePosition(leader, there) && there.world.distanceTo2d(here.world) <= TOGETHER_DIST;
		} else if (job->goal != nullptr) {
			job->path.removeAll();

			if (job->goalZone != zone || !findWay(zone, here, *job->goal, job->path)) {
				giveUp(job, bot, "moved", events);
				return 0;
			}
		}
	}

	if (job->mode == BotMoveJob::FOLLOW)
		tickFollow(job, bot, zone, here, dt, now, events);
	else
		tickGoto(job, bot, zone, here, dt, now, events);

	if (job->mode == BotMoveJob::IDLE)
		return 0;

	// Waiting for a leader who is away or on another planet needs no quick steps
	if (!job->moving && job->mode == BotMoveJob::FOLLOW && (job->leaderAwaySince != 0 || job->leapPending))
		return BotMover::WAIT_MS;

	return BotMover::STEP_MIN_MS + System::random(BotMover::STEP_RANDOM_MS);
}

int runJob(BotMoveJob* job) {
	ManagedReference<CreatureObject*> bot = job->bot.get();
	int next = 0;

	if (bot != nullptr) {
		Locker locker(bot);

		BotMoveEvents events;

		try {
			next = step(job, bot, events);
		} catch (Exception& e) {
			moverLog().error() << "BotMover: exception moving " << bot->getFirstName() << ": " << e.getMessage();
			next = BotMover::WAIT_MS;
		}

		// The jobs hear it with the bot still locked; they may give a new order here
		for (int i = 0; i < events.size(); ++i) {
			BotMoveEvent* event = events.get(i);

			BotLua::callEvent(bot, event->name, event->other, event->detail);
		}
	}

	Locker locker(&job->mutex);

	if (next == 0 && bot != nullptr && job->orderGen != job->appliedGen)
		next = 50;	// a new order came in meanwhile (from an event)

	if (next == 0)
		job->scheduled = false;

	return next;
}

class BotMoveTask : public Task {
	Reference<BotMoveJob*> job;

public:
	BotMoveTask(BotMoveJob* moveJob) : job(moveJob) {
		setTaskName("BotMoveStep");
	}

	void run() {
		int next = runJob(job);

		if (next > 0)
			reschedule(next);
	}
};

// pre: job->mutex locked. The order is applied at the bot's next step
void giveOrder(BotMoveJob* job) {
	++job->orderGen;

	if (job->scheduled)
		return;

	job->scheduled = true;

	Reference<Task*> task = new BotMoveTask(job);
	task->schedule(10);
}

bool readyBot(CreatureObject* bot) {
	return bot != nullptr && BotManager::instance()->isOnlineBot(bot) && bot->getZone() != nullptr;
}

// The goal for moveTo: a cell (in the bot's zone) and coordinates in it, or world coordinates
bool makeGoal(CreatureObject* bot, Zone* zone, float x, float z, float y, uint64 cellOid, BotMovePoint& goal) {
	goal.jump = false;

	if (cellOid == 0) {
		if (z == 0) {
			// The ground, not the highest roof over it (the 4-argument getWorldFloorCollision): the path gives the height
			PlanetManager* planetManager = zone->getPlanetManager();
			TerrainManager* terrainManager = planetManager != nullptr ? planetManager->getTerrainManager() : nullptr;

			z = terrainManager != nullptr ? terrainManager->getHeight(x, y) : 0;
		}

		goal.cell = nullptr;
		goal.local = Vector3(x, y, z);
		goal.world = goal.local;
		return true;
	}

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(cellOid) : nullptr;

	if (object == nullptr || !object->isCellObject())
		return false;

	CellObject* cell = object.castTo<CellObject*>();
	ManagedReference<SceneObject*> building = cell != nullptr ? cell->getParent().get() : nullptr;

	if (building == nullptr || building->getZone() != zone)
		return false;

	if (z == 0) {
		float floor;

		if (cellFloor(cell, x, y, 0, floor))
			z = floor;
	}

	goal.cell = cell;
	goal.local = Vector3(x, y, z);
	goal.world = toWorld(goal.local, cell);

	return true;
}

}

// --- The API ---

bool BotMover::follow(CreatureObject* bot, CreatureObject* leader, float nearDist, float farDist) {
	if (!readyBot(bot) || leader == nullptr || leader == bot)
		return false;

	nearDist = Math::max(1.f, nearDist);
	farDist = Math::max(nearDist, farDist);

	Reference<BotMoveJob*> job = getJob(bot, true);
	uint64 oid = bot->getObjectID();

	// Each bot keeps its own distance and side, so a crew spreads out
	float followDist = nearDist + (float)(oid % 3) * (farDist - nearDist) * 0.5f;
	float side = ((float)((oid / 3) % 5) - 2.f) * 0.6f;

	Locker locker(&job->mutex);

	job->orderMode = BotMoveJob::FOLLOW;
	job->orderLeader = leader;
	job->orderLeaderOid = leader->getObjectID();
	job->orderFollowDist = followDist;
	job->orderSide = side;
	job->orderPath.removeAll();
	job->orderPatrol.removeAll();

	job->status.state = "follow";
	job->status.leader = leader->getObjectID();
	BotMovePoint here, there;

	job->status.distance = leader->getZone() == bot->getZone() && samplePosition(bot, here) && samplePosition(leader, there) ? here.world.distanceTo2d(there.world) : -1;
	job->status.stuck = false;

	giveOrder(job);

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " follows " << leader->getDisplayedName() << " at "
		<< followDist << " m, side " << side;

	return true;
}

bool BotMover::stop(CreatureObject* bot) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot))
		return false;

	Reference<BotMoveJob*> job = getJob(bot, false);

	if (job == nullptr)
		return true;

	Locker locker(&job->mutex);

	if (job->orderMode != BotMoveJob::IDLE)
		moverLog().info(true) << "BotMover: " << bot->getFirstName() << " stops";

	job->orderMode = BotMoveJob::IDLE;
	job->orderPath.removeAll();
	job->orderPatrol.removeAll();

	job->status.state = "idle";
	job->status.leader = 0;
	job->status.distance = 0;
	job->status.stuck = false;

	giveOrder(job);

	return true;
}

bool BotMover::moveTo(CreatureObject* bot, float x, float z, float y, uint64 cellOid, int pace) {
	if (!readyBot(bot))
		return false;

	Zone* zone = bot->getZone();
	BotMovePoint goal;
	BotMovePoint here;

	if (!makeGoal(bot, zone, x, z, y, cellOid, goal) || !samplePosition(bot, here))
		return false;

	if (goal.cell != nullptr && !canEnter(bot, goal.cell))
		return false;

	BotMovePath way;

	if (!findWay(zone, here, goal, way))
		return false;

	float length = pathLength(here.world, way);
	bool run = pace == PACE_RUN || (pace == PACE_AUTO && length > AUTO_RUN_PATH);

	Reference<BotMoveJob*> job = getJob(bot, true);

	Locker locker(&job->mutex);

	job->orderMode = BotMoveJob::GOTO;
	job->orderPath = way;
	job->orderGoal = new BotMovePoint(goal);
	job->orderZone = zone;
	job->orderRun = run;
	job->orderPatrol.removeAll();
	job->orderPace = pace;

	job->status.state = "goto";
	job->status.leader = 0;
	job->status.distance = length;
	job->status.stuck = false;

	giveOrder(job);

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " goes to " << x << " " << z << " " << y
		<< (cellOid != 0 ? " in cell " + String::valueOf(cellOid) : String("")) << ", " << way.size() << " points, "
		<< (int)length << " m, " << (run ? "running" : "walking");

	return true;
}

bool BotMover::patrol(CreatureObject* bot, const Vector<Vector3>& points, const Vector<uint64>& cells, int pace) {
	if (!readyBot(bot) || points.size() < 2 || cells.size() != points.size())
		return false;

	Zone* zone = bot->getZone();
	BotMovePath goals;

	for (int i = 0; i < points.size(); ++i) {
		const Vector3& point = points.get(i);
		Reference<BotMovePoint*> goal = new BotMovePoint();

		if (!makeGoal(bot, zone, point.getX(), point.getZ(), point.getY(), cells.get(i), *goal))
			return false;

		goals.add(goal);
	}

	BotMovePoint here;
	BotMovePath way;

	if (!samplePosition(bot, here) || !findWay(zone, here, *goals.get(0), way))
		return false;

	Reference<BotMoveJob*> job = getJob(bot, true);

	Locker locker(&job->mutex);

	job->orderMode = BotMoveJob::GOTO;
	job->orderPath = way;
	job->orderGoal = goals.get(0);
	job->orderZone = zone;
	job->orderRun = pace == PACE_RUN;
	job->orderPatrol = goals;
	job->orderPace = pace;

	job->status.state = "goto";
	job->status.leader = 0;
	job->status.distance = pathLength(here.world, way);
	job->status.stuck = false;

	giveOrder(job);

	moverLog().info(true) << "BotMover: " << bot->getFirstName() << " patrols " << points.size() << " points";

	return true;
}

bool BotMover::getStatus(CreatureObject* bot, BotMoveStatus& out) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot))
		return false;

	Reference<BotMoveJob*> job = getJob(bot, false);

	if (job == nullptr) {
		out = BotMoveStatus();
		return true;
	}

	Locker locker(&job->mutex);

	out = job->status;

	return true;
}

String BotMover::describe(CreatureObject* bot) {
	StringBuffer line;

	if (bot == nullptr)
		return "no bot";

	BotMoveStatus status;
	bool online = getStatus(bot, status);

	line << bot->getFirstName() << ": " << (online ? status.state : String("offline"));

	if (status.leader != 0)
		line << " leader " << status.leader;

	line << " distance " << (int)(status.distance * 10) / 10.f << (status.stuck ? " STUCK" : "") << ", counter "
		<< bot->getMovementCounter() << ", speed " << bot->getCurrentSpeed() << ", posture " << bot->getPosture();

	Zone* zone = bot->getZone();
	BotMovePoint here;

	if (zone != nullptr && samplePosition(bot, here)) {
		line << ", " << zone->getZoneName() << " " << (int)here.world.getX() << " " << (int)here.world.getZ() << " " << (int)here.world.getY();

		if (here.cell != nullptr)
			line << " (cell " << here.cell->getObjectID() << " " << here.local.getX() << " " << here.local.getZ() << " " << here.local.getY() << ")";
	}

	return line.toString();
}
