/*
 * BotMission (Phase 7 bot players). See BotMission.h.
 */

#include "BotMission.h"
#include "BotManager.h"
#include "server/ServerCore.h"
#include "server/zone/Zone.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/group/GroupObject.h"
#include "server/zone/objects/building/BuildingObject.h"
#include "server/zone/objects/cell/CellObject.h"
#include "server/zone/objects/mission/MissionObject.h"
#include "server/zone/objects/mission/MissionTypes.h"
#include "server/zone/objects/mission/MissionObjective.h"
#include "server/zone/objects/tangible/terminal/mission/MissionTerminal.h"
#include "server/zone/objects/waypoint/WaypointObject.h"
#include "server/zone/managers/mission/MissionManager.h"
#include "server/zone/managers/creature/CreatureTemplateManager.h"
#include "server/zone/managers/creature/SpawnGroup.h"
#include "server/zone/managers/creature/LairSpawn.h"
#include "server/zone/objects/creature/ai/CreatureTemplate.h"
#include "templates/mobile/LairTemplate.h"
#include "server/zone/managers/stringid/StringIdManager.h"

using namespace server::zone::managers::bot;

namespace {

Logger& missionLog() {
	static Logger logger("BotMission");

	return logger;
}

const char* WAYPOINT_MARK = "Crew mission #";
const uint32 WAYPOINT_TEMPLATE = 0xc456e788;		// object/waypoint/world_waypoint_blue.iff, as PlayerObject::addWaypoint makes

// A waypoint we made for a bot's mission, remembered until the mission ends
class TrackedWaypoint : public Object {
public:
	uint64 bot = 0;
	uint64 mission = 0;
	uint64 leader = 0;
	uint64 waypoint = 0;
};

Mutex trackMutex;
Vector<Reference<TrackedWaypoint*>> tracked;
SortedVector<String> scanned;		// "<bot oid>:<leader oid>" once the leader's old waypoints were looked through

const char* compassName(float degrees) {
	static const char* names[] = {"north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"};

	int sector = ((int) floor((degrees + 22.5f) / 45.f)) % 8;

	return names[sector < 0 ? sector + 8 : sector];
}

// Compass bearing (0 north, 90 east) of (dx, dy)
int bearingOf(float dx, float dy) {
	float degrees = atan2(dx, dy) * 180.f / M_PI;

	if (degrees < 0)
		degrees += 360.f;

	return ((int) (degrees + 0.5f)) % 360;
}

// A bot's refresh counter (the client sends an increasing one; Core3 stores it on each mission)
Mutex counterMutex;
VectorMap<uint64, int> counters;

int nextCounter(uint64 oid) {
	Locker locker(&counterMutex);

	int next = counters.contains(oid) ? counters.get(oid) + 1 : 1;

	counters.put(oid, next);

	return next;
}

// What the client shows for a lair: "@lair_n:womp_rat" -> "womp rat lair" (the string table's text, else the key)
String targetText(const String& targetName) {
	String text;

	if (targetName.beginsWith("@")) {
		StringId id(targetName);
		UnicodeString resolved = StringIdManager::instance()->getStringId(id);

		text = resolved.toString();

		if (text.isEmpty()) {
			int colon = targetName.indexOf(':');

			text = colon >= 0 ? targetName.subString(colon + 1) : targetName.subString(1);
			text = text.replaceAll("_", " ");
		}
	} else {
		text = targetName;
	}

	text = text.toLowerCase();

	// "a womp rat lair" -> "womp rat lair" (the lines add their own articles)
	if (text.beginsWith("a "))
		text = text.subString(2);
	else if (text.beginsWith("an "))
		text = text.subString(3);
	else if (text.beginsWith("the "))
		text = text.subString(4);

	return text;
}

// A creature as the client names it ("womp rat"): the template's object name from the string table, else its custom name,
// else the template's own name
String creatureText(const String& mobile) {
	CreatureTemplate* creatureTemplate = CreatureTemplateManager::instance()->getTemplate(mobile);
	String text;

	if (creatureTemplate != nullptr) {
		String objectName = creatureTemplate->getObjectName();

		if (!objectName.isEmpty())
			text = targetText(objectName);

		if (text.isEmpty())
			text = creatureTemplate->getCustomName().toLowerCase();
	}

	if (text.isEmpty())
		text = mobile.replaceAll("_", " ");

	return text;
}

void addName(Vector<String>& out, const String& name) {
	String text = name.trim().toLowerCase();

	if (!text.isEmpty() && !out.contains(text))
		out.add(text);
}

Mutex lairNamesMutex;
VectorMap<String, Vector<String>> lairNames;	// lair template -> creatureNames of it (the templates don't change)

void lairCreaturesRead(const String& lairName, Vector<String>& out);

// The names of what lives in a lair: its mobiles and boss mobiles, by display name (the template names carry planet and
// title words: "tatooine_mynock")
void lairCreatures(const String& lairName, Vector<String>& out) {
	{
		Locker locker(&lairNamesMutex);

		int pos = lairNames.find(lairName);

		if (pos != -1) {
			const Vector<String>& known = lairNames.elementAt(pos).getValue();

			for (int i = 0; i < known.size(); ++i) {
				if (!out.contains(known.get(i)))
					out.add(known.get(i));
			}

			return;
		}
	}

	Vector<String> found;

	lairCreaturesRead(lairName, found);

	{
		Locker locker(&lairNamesMutex);

		lairNames.put(lairName, found);
	}

	for (int i = 0; i < found.size(); ++i) {
		if (!out.contains(found.get(i)))
			out.add(found.get(i));
	}
}

void lairCreaturesRead(const String& lairName, Vector<String>& out) {
	LairTemplate* lair = CreatureTemplateManager::instance()->getLairTemplate(lairName.hashCode());

	if (lair == nullptr)
		return;

	const VectorMap<String, int>* lists[2] = {lair->getMobiles(), lair->getBossMobiles()};

	for (int l = 0; l < 2; ++l) {
		const VectorMap<String, int>* list = lists[l];

		if (list == nullptr)
			continue;

		for (int i = 0; i < list->size(); ++i) {
			String mobile = list->elementAt(i).getKey();

			addName(out, creatureText(mobile));
		}
	}
}

Mutex creaturesMutex;
VectorMap<String, Vector<String>> creaturesByZone;	// zone -> creatureNames (computed once: the spawn groups are fixed at boot)

MissionManager* missionManager(CreatureObject* bot) {
	ZoneServer* zoneServer = bot->getZoneServer();

	return zoneServer != nullptr ? zoneServer->getMissionManager() : nullptr;
}

Reference<MissionTerminal*> terminalOf(CreatureObject* bot, uint64 oid) {
	ZoneServer* zoneServer = bot->getZoneServer();

	if (zoneServer == nullptr)
		return nullptr;

	ManagedReference<SceneObject*> object = zoneServer->getObject(oid);

	if (object == nullptr || !object->isMissionTerminal())
		return nullptr;

	MissionTerminal* terminal = cast<MissionTerminal*>(object.get());

	return terminal != nullptr && terminal->isGeneralTerminal() ? terminal : nullptr;
}

void fillInfo(BotMissionInfo* info, MissionObject* mission, float fromX, float fromY) {
	info->oid = mission->getObjectID();
	info->reward = mission->getRewardCredits();
	info->x = mission->getStartPositionX();
	info->y = mission->getStartPositionY();
	info->planet = mission->getStartPlanet();
	info->target = targetText(mission->getTargetName());
	info->level = mission->getDifficultyDisplay();
	info->lair = mission->getTargetOptionalTemplate();

	if (!info->lair.isEmpty())
		lairCreatures(info->lair, info->creatures);

	// Core3 fails a destroy mission it can't find a lair spot for, and removes it as it does a done one: the lair having
	// spawned (the objective has an observer on it) tells the two apart
	ManagedReference<MissionObjective*> objective = mission->getMissionObjective();

	info->lairUp = objective != nullptr && objective->hasObservers();

	float dx = info->x - fromX;
	float dy = info->y - fromY;

	info->distance = sqrt(dx * dx + dy * dy);
	info->degrees = bearingOf(dx, dy);
	info->direction = compassName(info->degrees);
}

bool isDestroy(SceneObject* object) {
	if (object == nullptr || !object->isMissionObject())
		return false;

	MissionObject* mission = cast<MissionObject*>(object);

	return mission != nullptr && mission->getTypeCRC() == MissionTypes::DESTROY;
}

// The destroy missions in the bot's datapad
void datapadMissions(CreatureObject* bot, Vector<Reference<MissionObject*>>& out) {
	SceneObject* datapad = bot->getSlottedObject("datapad");

	if (datapad == nullptr)
		return;

	for (int i = 0; i < datapad->getContainerObjectsSize(); ++i) {
		SceneObject* object = datapad->getContainerObject(i);

		if (isDestroy(object))
			out.add(cast<MissionObject*>(object));
	}
}

// The mission's oid in a waypoint we made ("Crew mission #123 bot 456"), and its bot's
bool parseMark(const String& text, uint64& mission, uint64& botOid) {
	int at = text.indexOf(WAYPOINT_MARK);

	if (at != 0)
		return false;

	int botAt = text.indexOf(" bot ");

	if (botAt < 0)
		return false;

	String missionText = text.subString(strlen(WAYPOINT_MARK), botAt);
	String botText = text.subString(botAt + 5);

	mission = UnsignedLong::valueOf(missionText);
	botOid = UnsignedLong::valueOf(botText);

	return mission != 0 && botOid != 0;
}

String markOf(uint64 mission, uint64 botOid) {
	StringBuffer text;

	text << WAYPOINT_MARK << mission << " bot " << botOid;

	return text.toString();
}

// The leader's waypoints we made for a bot: waypoint oid and its mission
void markedWaypoints(CreatureObject* leader, uint64 botOid, Vector<uint64>& waypoints, Vector<uint64>& missions) {
	PlayerObject* ghost = leader->getPlayerObject();

	if (ghost == nullptr)
		return;

	for (int i = 0; i < ghost->getWaypointListSize(); ++i) {
		WaypointObject* waypoint = ghost->getWaypoint(i);

		if (waypoint == nullptr)
			continue;

		uint64 mission = 0, owner = 0;

		if (parseMark(waypoint->getDetailedDescription(), mission, owner) && owner == botOid) {
			waypoints.add(waypoint->getObjectID());
			missions.add(mission);
		}
	}
}

// Takes a waypoint out of its owner's datapad. The leader is locked by the caller
void dropWaypoint(CreatureObject* leader, uint64 waypointOid) {
	PlayerObject* ghost = leader->getPlayerObject();

	if (ghost != nullptr && ghost->hasWaypoint(waypointOid)) {
		ghost->removeWaypoint(waypointOid, true, true);

		missionLog().info(true) << "waypoint " << waypointOid << " left " << leader->getFirstName() << "'s datapad";
	}
}

}

// --- Terminals ---

bool BotMission::findTerminals(CreatureObject* bot, float range, Vector<Reference<BotMissionTerminal*>>& out) {
	if (bot == nullptr)
		return false;

	Locker locker(bot);

	Zone* zone = bot->getZone();

	if (zone == nullptr)
		return false;

	SortedVector<ManagedReference<TreeEntry*>> objects(512, 512);
	zone->getInRangeObjects(bot->getWorldPositionX(), bot->getWorldPositionZ(), bot->getWorldPositionY(), range, &objects, true, false);

	Vector<Reference<SceneObject*>> candidates;

	for (int i = 0; i < objects.size(); ++i) {
		SceneObject* object = static_cast<SceneObject*>(objects.get(i).get());

		if (object != nullptr && object->isMissionTerminal())
			candidates.add(object);
	}

	// Inside a building the terminals are in its cells, not always in the zone's tree
	ManagedReference<SceneObject*> root = bot->getRootParent();

	if (root != nullptr && root->isBuildingObject()) {
		for (int c = 0; c < root->getContainerObjectsSize(); ++c) {
			SceneObject* cell = root->getContainerObject(c);

			if (cell == nullptr)
				continue;

			for (int j = 0; j < cell->getContainerObjectsSize(); ++j) {
				SceneObject* object = cell->getContainerObject(j);

				if (object != nullptr && object->isMissionTerminal())
					candidates.add(object);
			}
		}
	}

	VectorMap<int, Reference<BotMissionTerminal*>> sorted;	// by distance in centimetres
	sorted.setAllowDuplicateInsertPlan();
	SortedVector<uint64> seen;

	for (int i = 0; i < candidates.size(); ++i) {
		SceneObject* object = candidates.get(i);

		if (seen.contains(object->getObjectID()))
			continue;

		seen.put(object->getObjectID());

		MissionTerminal* terminal = cast<MissionTerminal*>(object);

		if (terminal == nullptr || !terminal->isGeneralTerminal())
			continue;

		Vector3 at = terminal->getWorldPosition();
		Vector3 from = bot->getWorldPosition();
		float dx = at.getX() - from.getX();
		float dy = at.getY() - from.getY();
		float distance = sqrt(dx * dx + dy * dy);

		if (distance > range)
			continue;

		Reference<BotMissionTerminal*> entry = new BotMissionTerminal();

		entry->oid = terminal->getObjectID();
		entry->distance = distance;
		entry->x = terminal->getPositionX();
		entry->z = terminal->getPositionZ();
		entry->y = terminal->getPositionY();
		entry->cell = terminal->getParentID();
		entry->planet = zone->getZoneName();

		sorted.put((int) (distance * 100), entry);
	}

	for (int i = 0; i < sorted.size(); ++i)
		out.add(sorted.elementAt(i).getValue());

	return true;
}

// --- The list ---

bool BotMission::list(CreatureObject* bot, uint64 terminalOid, bool refresh, Vector<Reference<BotMissionInfo*>>& out, String& error) {
	if (bot == nullptr) {
		error = "terminal";
		return false;
	}

	Locker locker(bot);

	Reference<MissionTerminal*> terminal = terminalOf(bot, terminalOid);
	MissionManager* manager = missionManager(bot);

	if (terminal == nullptr || manager == nullptr) {
		error = "terminal";
		return false;
	}

	if (!bot->isInRange(terminal, LIST_RANGE)) {
		error = "far";
		return false;
	}

	int counter = 0;

	if (refresh) {
		if (!bot->checkCooldownRecovery("mission_list_request")) {
			error = "wait";
			return false;
		}

		counter = nextCounter(bot->getObjectID());

		manager->handleMissionListRequest(terminal, bot, counter);
	}

	SceneObject* missionBag = bot->getSlottedObject("mission_bag");

	if (missionBag == nullptr) {
		error = "refused";
		return false;
	}

	Vector3 from = terminal->getWorldPosition();
	bool fresh = !refresh;

	for (int i = 0; i < missionBag->getContainerObjectsSize(); ++i) {
		SceneObject* object = missionBag->getContainerObject(i);

		if (!isDestroy(object))
			continue;

		MissionObject* mission = cast<MissionObject*>(object);

		if (refresh && (int) mission->getRefreshCounter() == counter)
			fresh = true;

		Reference<BotMissionInfo*> info = new BotMissionInfo();

		fillInfo(info, mission, from.getX(), from.getY());
		out.add(info);
	}

	if (!fresh) {
		out.removeAll();
		error = "refused";
		return false;
	}

	return true;
}

// --- Accepting and aborting ---

bool BotMission::accept(CreatureObject* bot, uint64 terminalOid, uint64 missionOid, String& error) {
	if (bot == nullptr) {
		error = "terminal";
		return false;
	}

	Locker locker(bot);

	Reference<MissionTerminal*> terminal = terminalOf(bot, terminalOid);
	MissionManager* manager = missionManager(bot);

	if (terminal == nullptr || manager == nullptr) {
		error = "terminal";
		return false;
	}

	if (!bot->isInRange(terminal, LIST_RANGE)) {
		error = "far";
		return false;
	}

	SceneObject* missionBag = bot->getSlottedObject("mission_bag");
	SceneObject* datapad = bot->getSlottedObject("datapad");

	if (missionBag == nullptr || datapad == nullptr) {
		error = "gone";
		return false;
	}

	ManagedReference<MissionObject*> mission = nullptr;

	for (int i = 0; i < missionBag->getContainerObjectsSize(); ++i) {
		SceneObject* object = missionBag->getContainerObject(i);

		if (object != nullptr && object->getObjectID() == missionOid && isDestroy(object)) {
			mission = cast<MissionObject*>(object);
			break;
		}
	}

	if (mission == nullptr) {
		error = "gone";
		return false;
	}

	Vector<Reference<MissionObject*>> held;
	datapadMissions(bot, held);

	// Core3's limit: two missions of any kind in the datapad
	int missions = 0;

	for (int i = 0; i < datapad->getContainerObjectsSize(); ++i) {
		SceneObject* object = datapad->getContainerObject(i);

		if (object != nullptr && object->isMissionObject())
			++missions;
	}

	if (missions >= 2) {
		error = "full";
		return false;
	}

	Locker clocker(mission, bot);

	manager->handleMissionAccept(terminal, mission, bot);

	if (mission->getParent().get() != datapad) {
		error = "full";
		return false;
	}

	missionLog().info(true) << bot->getFirstName() << " accepted mission " << missionOid << ": " << mission->getTargetName()
		<< " for " << mission->getRewardCredits();

	return true;
}

int BotMission::abortAll(CreatureObject* bot, String& error) {
	if (bot == nullptr)
		return 0;

	Locker locker(bot);

	MissionManager* manager = missionManager(bot);
	SceneObject* datapad = bot->getSlottedObject("datapad");

	if (manager == nullptr || datapad == nullptr)
		return 0;

	Vector<Reference<MissionObject*>> held;

	for (int i = 0; i < datapad->getContainerObjectsSize(); ++i) {
		SceneObject* object = datapad->getContainerObject(i);

		if (object != nullptr && object->isMissionObject())
			held.add(cast<MissionObject*>(object));
	}

	int aborted = 0;

	for (int i = 0; i < held.size(); ++i) {
		Reference<MissionObject*> mission = held.get(i);
		Locker clocker(mission, bot);

		manager->handleMissionAbort(mission, bot, false);

		if (mission->getParent().get() != datapad)
			++aborted;
	}

	if (aborted < held.size())
		error = "combat";

	if (aborted > 0)
		missionLog().info(true) << bot->getFirstName() << " aborted " << aborted << " mission(s)";

	return aborted;
}

bool BotMission::creatures(CreatureObject* bot, Vector<String>& out) {
	if (bot == nullptr || bot->getZone() == nullptr)
		return false;

	String zoneName = bot->getZone()->getZoneName();

	{
		Locker locker(&creaturesMutex);

		int pos = creaturesByZone.find(zoneName);

		if (pos != -1) {
			out = creaturesByZone.elementAt(pos).getValue();
			return true;
		}
	}

	Vector<String> names;
	SpawnGroup* group = CreatureTemplateManager::instance()->getDestroyMissionGroup(String(zoneName + "_destroy_missions").hashCode());

	if (group != nullptr) {
		const Vector<Reference<LairSpawn*>>& lairs = group->getSpawnList();

		for (int i = 0; i < lairs.size(); ++i) {
			LairSpawn* spawn = lairs.get(i);

			if (spawn == nullptr)
				continue;

			const String& lairName = spawn->getLairTemplateName();

			addName(names, targetText("@lair_n:" + lairName));
			lairCreatures(lairName, names);
		}
	}

	Locker locker(&creaturesMutex);

	creaturesByZone.put(zoneName, names);
	out = names;

	return true;
}

bool BotMission::current(CreatureObject* bot, Vector<Reference<BotMissionInfo*>>& out) {
	if (bot == nullptr)
		return false;

	Locker locker(bot);

	Vector<Reference<MissionObject*>> held;
	datapadMissions(bot, held);

	Vector3 from = bot->getWorldPosition();

	for (int i = 0; i < held.size(); ++i) {
		Reference<BotMissionInfo*> info = new BotMissionInfo();

		fillInfo(info, held.get(i), from.getX(), from.getY());
		out.add(info);
	}

	return true;
}

// --- Waypoints ---

namespace {

// What a sync needs to know of a mission, read with the bot locked
class MissionSnapshot : public Object {
public:
	uint64 oid = 0;
	String waypointName;
	String planet;
	float x = 0, y = 0;
};

// One sync of a bot's waypoints. It runs in a task of its own that locks only the leader: the bot may be locked by
// the Lua event that asked, and a second lock on top of it (a cross-lock of the leader) cannot give way to other
// threads holding the leader, which is how four crew bots syncing at once would deadlock
class SyncJob : public Object {
public:
	uint64 bot = 0;
	String botName;
	uint64 leader = 0;			// 0: the bot left its group
	uint64 sequence = 0;
	Vector<Reference<MissionSnapshot*>> missions;
	Reference<ZoneServer*> zoneServer;
};

Mutex runMutex;				// the jobs run one at a time (held while a job locks the leader)
Mutex stateMutex;			// guards the three below, only ever held for a moment
VectorMap<uint64, uint64> issued;	// bot -> the last sequence number given
VectorMap<uint64, uint64> applied;	// bot -> the last one run
SortedVector<uint64> pending;		// bots with a job queued

bool heldIn(const Vector<Reference<MissionSnapshot*>>& missions, uint64 oid) {
	for (int i = 0; i < missions.size(); ++i) {
		if (missions.get(i)->oid == oid)
			return true;
	}

	return false;
}

void runSync(Reference<SyncJob*> job) {
	Locker serial(&runMutex);

	{
		Locker slocker(&stateMutex);

		pending.drop(job->bot);

		// An older job than one that has run
		if (applied.contains(job->bot) && applied.get(job->bot) > job->sequence)
			return;

		applied.put(job->bot, job->sequence);
	}

	ZoneServer* zoneServer = job->zoneServer;

	// This bot's waypoints in another leader's datapad (all of them, when it has no leader) go
	Vector<Reference<TrackedWaypoint*>> stale;

	{
		Locker tlocker(&trackMutex);

		for (int i = 0; i < tracked.size(); ++i) {
			TrackedWaypoint* entry = tracked.get(i);

			if (entry->bot == job->bot && entry->leader != job->leader)
				stale.add(entry);
		}
	}

	for (int i = 0; i < stale.size(); ++i) {
		ManagedReference<CreatureObject*> old = zoneServer->getObject(stale.get(i)->leader).castTo<CreatureObject*>();

		if (old != nullptr) {
			Locker olocker(old);
			dropWaypoint(old, stale.get(i)->waypoint);
		}

		Locker tlocker(&trackMutex);
		tracked.removeElement(stale.get(i));
	}

	if (job->leader == 0)
		return;

	ManagedReference<CreatureObject*> leader = zoneServer->getObject(job->leader).castTo<CreatureObject*>();

	if (leader == nullptr)
		return;

	Locker llocker(leader);

	PlayerObject* ghost = leader->getPlayerObject();

	if (ghost == nullptr)
		return;

	StringBuffer scanKey;

	scanKey << job->bot << ":" << job->leader;

	// What an earlier run left in the leader's datapad: kept while its mission is held, gone otherwise
	Vector<uint64> marked, markedMissions;
	markedWaypoints(leader, job->bot, marked, markedMissions);

	for (int i = 0; i < marked.size(); ++i) {
		bool alive = heldIn(job->missions, markedMissions.get(i));
		bool known = false;

		{
			Locker tlocker(&trackMutex);

			for (int j = 0; j < tracked.size(); ++j) {
				if (tracked.get(j)->waypoint == marked.get(i))
					known = true;
			}
		}

		if (!alive) {
			dropWaypoint(leader, marked.get(i));

			Locker tlocker(&trackMutex);

			for (int j = tracked.size() - 1; j >= 0; --j) {
				if (tracked.get(j)->waypoint == marked.get(i))
					tracked.remove(j);
			}
		} else if (!known) {
			Reference<TrackedWaypoint*> entry = new TrackedWaypoint();

			entry->bot = job->bot;
			entry->mission = markedMissions.get(i);
			entry->leader = job->leader;
			entry->waypoint = marked.get(i);

			Locker tlocker(&trackMutex);
			tracked.add(entry);
		}
	}

	// Other bots' marks: one no longer in the leader's group (a restart broke the group up, or it left while the server
	// was down) leaves nothing behind; one still in the group keeps its own and syncs them itself
	{
		ManagedReference<GroupObject*> group = leader->getGroup();
		Vector<uint64> strays;

		for (int i = 0; i < ghost->getWaypointListSize(); ++i) {
			WaypointObject* waypoint = ghost->getWaypoint(i);
			uint64 mission = 0, owner = 0;

			if (waypoint == nullptr || !parseMark(waypoint->getDetailedDescription(), mission, owner) || owner == job->bot)
				continue;

			if (group == nullptr || !group->hasMember(owner))
				strays.add(waypoint->getObjectID());
		}

		for (int i = 0; i < strays.size(); ++i) {
			dropWaypoint(leader, strays.get(i));

			Locker tlocker(&trackMutex);

			for (int j = tracked.size() - 1; j >= 0; --j) {
				if (tracked.get(j)->waypoint == strays.get(i))
					tracked.remove(j);
			}
		}
	}

	{
		Locker tlocker(&trackMutex);
		scanned.put(scanKey.toString());
	}

	// Tracked waypoints whose mission is over
	Vector<Reference<TrackedWaypoint*>> over;

	{
		Locker tlocker(&trackMutex);

		for (int j = 0; j < tracked.size(); ++j) {
			TrackedWaypoint* entry = tracked.get(j);

			if (entry->bot == job->bot && !heldIn(job->missions, entry->mission))
				over.add(entry);
		}
	}

	for (int i = 0; i < over.size(); ++i) {
		dropWaypoint(leader, over.get(i)->waypoint);

		Locker tlocker(&trackMutex);
		tracked.removeElement(over.get(i));
	}

	// A waypoint for each mission that has none
	for (int i = 0; i < job->missions.size(); ++i) {
		MissionSnapshot* mission = job->missions.get(i);
		bool has = false;

		{
			Locker tlocker(&trackMutex);

			for (int j = 0; j < tracked.size(); ++j) {
				if (tracked.get(j)->mission == mission->oid && tracked.get(j)->bot == job->bot)
					has = true;
			}
		}

		if (has)
			continue;

		ManagedReference<WaypointObject*> waypoint = zoneServer->createObject(WAYPOINT_TEMPLATE, 1).castTo<WaypointObject*>();

		if (waypoint == nullptr)
			continue;

		{
			Locker wlocker(waypoint);

			waypoint->setPlanetCRC(mission->planet.hashCode());
			waypoint->setPosition(mission->x, 0, mission->y);
			waypoint->setCustomObjectName(UnicodeString(mission->waypointName), false);
			waypoint->setDetailedDescription(markOf(mission->oid, job->bot));
			waypoint->setColor(WaypointObject::COLOR_ORANGE);
			waypoint->setActive(true);
		}

		ghost->addWaypoint(waypoint, false, true);

		Reference<TrackedWaypoint*> entry = new TrackedWaypoint();

		entry->bot = job->bot;
		entry->mission = mission->oid;
		entry->leader = job->leader;
		entry->waypoint = waypoint->getObjectID();

		Locker tlocker(&trackMutex);
		tracked.add(entry);

		missionLog().info(true) << job->botName << "'s mission " << mission->oid << " has a waypoint '" << mission->waypointName
			<< "' in " << leader->getFirstName() << "'s datapad";
	}
}

}

int BotMission::syncWaypoints(CreatureObject* bot, CreatureObject* leader) {
	if (bot == nullptr)
		return 0;

	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();

	if (zoneServer == nullptr)
		return 0;

	uint64 botOid = bot->getObjectID();
	uint64 leaderOid = leader != nullptr ? leader->getObjectID() : 0;

	Vector<Reference<MissionObject*>> held;
	datapadMissions(bot, held);

	// What's to do: a mission with no waypoint yet, a waypoint whose mission is over or that is in another leader's
	// datapad, a leader not yet looked through
	bool needed = false;
	StringBuffer scanKey;

	scanKey << botOid << ":" << leaderOid;

	{
		Locker tlocker(&trackMutex);

		needed = leaderOid != 0 && !scanned.contains(scanKey.toString());

		for (int i = 0; i < held.size() && !needed && leaderOid != 0; ++i) {
			bool found = false;

			for (int j = 0; j < tracked.size(); ++j) {
				if (tracked.get(j)->mission == held.get(i)->getObjectID() && tracked.get(j)->bot == botOid)
					found = true;
			}

			needed = !found;
		}

		for (int j = 0; j < tracked.size() && !needed; ++j) {
			TrackedWaypoint* entry = tracked.get(j);

			if (entry->bot != botOid)
				continue;

			bool alive = false;

			for (int i = 0; i < held.size(); ++i) {
				if (held.get(i)->getObjectID() == entry->mission)
					alive = true;
			}

			needed = !alive || entry->leader != leaderOid;
		}
	}

	if (!needed)
		return 0;

	Reference<SyncJob*> job = new SyncJob();

	job->bot = botOid;
	job->botName = bot->getFirstName();
	job->leader = leaderOid;
	job->zoneServer = zoneServer;

	for (int i = 0; i < held.size(); ++i) {
		MissionObject* mission = held.get(i);
		Reference<MissionSnapshot*> snapshot = new MissionSnapshot();

		snapshot->oid = mission->getObjectID();
		snapshot->waypointName = job->botName + ": " + targetText(mission->getTargetName());
		snapshot->planet = mission->getStartPlanet();
		snapshot->x = mission->getStartPositionX();
		snapshot->y = mission->getStartPositionY();

		job->missions.add(snapshot);
	}

	{
		Locker slocker(&stateMutex);

		// One job at a time for a bot: the next sync, a few seconds on, sees what this one did
		if (pending.contains(botOid))
			return 0;

		pending.put(botOid);
		job->sequence = (issued.contains(botOid) ? issued.get(botOid) : 0) + 1;
		issued.put(botOid, job->sequence);
	}

	Core::getTaskManager()->executeTask([job]() {
		runSync(job);
	}, "BotMissionSync");

	return 1;
}

// --- Reading a datapad's waypoints (for tests and the console) ---

bool BotMission::listWaypoints(CreatureObject* owner, Vector<Reference<BotWaypointInfo*>>& out) {
	if (owner == nullptr)
		return false;

	Locker locker(owner);

	PlayerObject* ghost = owner->getPlayerObject();

	if (ghost == nullptr)
		return false;

	for (int i = 0; i < ghost->getWaypointListSize(); ++i) {
		WaypointObject* waypoint = ghost->getWaypoint(i);

		if (waypoint == nullptr)
			continue;

		Reference<BotWaypointInfo*> info = new BotWaypointInfo();

		info->oid = waypoint->getObjectID();
		info->name = waypoint->getCustomObjectName().toString();
		info->x = waypoint->getPositionX();
		info->y = waypoint->getPositionY();
		info->planetCRC = waypoint->getPlanetCRC();
		info->description = waypoint->getDetailedDescription();
		info->active = waypoint->isActive();

		out.add(info);
	}

	return true;
}
