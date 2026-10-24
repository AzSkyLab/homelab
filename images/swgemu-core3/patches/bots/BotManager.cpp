/*
 * BotManager: bot players (Phase 3). See BotManager.h and patches/README.md.
 */

#include "BotManager.h"
#include "BotFactory.h"
#include "BotLua.h"
#include "BotTrade.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/cell/CellObject.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/managers/skill/SkillModManager.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "server/zone/packets/creature/CreatureObjectDeltaMessage6.h"
#include "server/chat/ChatManager.h"
#include "templates/params/creature/CreaturePosture.h"
#include "server/zone/objects/player/sui/SuiWindowType.h"

namespace {

class BotTickTask : public Task {
public:
	BotTickTask() {
		setTaskName("BotManagerTick");
	}

	void run() {
		BotManager* manager = BotManager::instance();

		manager->tick();

		if (manager->keepTicking())
			reschedule(BotManager::TICK_MS);
	}
};

}

const char* BotRuntime::stateName(int state) {
	switch (state) {
	case OFFLINE:
		return "offline";
	case LOGGINGIN:
		return "logging in";
	case ONLINE:
		return "online";
	case LOGGINGOUT:
		return "logging out";
	default:
		return "unknown";
	}
}

BotManager::BotManager() {
	setLoggingName("BotManager");
	setGlobalLogging(true);
	setLogging(true);
}

void BotManager::start(ZoneServer* server) {
	zoneServer = server;

	if (!BotFactory::loadRoster("scripts/custom_scripts/bots/roster.lua", roster, settings)) {
		info(true) << "BotManager: started with no roster";
		return;
	}

	{
		Locker locker(&stateMutex);

		for (int i = 0; i < roster.size(); ++i) {
			Reference<BotRuntime*> bot = new BotRuntime();
			bot->entry = roster.get(i);
			bot->firstNameLower = bot->entry->firstName.toLowerCase();
			bots.add(bot);
		}
	}

	info(true) << "BotManager: started, " << roster.size() << " bots in the roster, login delay " << settings.loginDelay
		<< " s, logout delay " << settings.logoutDelay << " s";

	// Make any bot that doesn't exist yet, once the zones have loaded; then the online rule starts
	Core::getTaskManager()->scheduleTask([this]() {
		for (int i = 0; i < roster.size(); ++i) {
			BotEntry* entry = roster.get(i);
			uint64 oid = BotFactory::ensureCharacter(zoneServer, *entry);

			if (oid == 0) {
				error() << "BotManager: " << entry->name << " not created";
				continue;
			}

			info(true) << "BotManager: " << entry->name << " ready, oid " << oid;

			{
				Locker locker(&stateMutex);

				bots.get(i)->oid = oid;
				botIndexByOid.put(oid, i);
			}

			// After a crash Core3 loads a character saved in a building back into its cell, link-dead, and unloads it
			// three minutes later. A bot that isn't logging in leaves at once
			ManagedReference<SceneObject*> object = zoneServer->getObject(oid);
			ManagedReference<CreatureObject*> creature = object != nullptr && object->isPlayerCreature() ? object->asCreatureObject() : nullptr;

			if (creature != nullptr) {
				Locker clocker(creature);

				if (creature->getZone() != nullptr) {
					info(true) << "BotManager: " << entry->name << " was left in the world by a crash, unloading it";
					logoutBot(creature, false);
				}
			}
		}

		Locker locker(&stateMutex);

		ready = true;
		humansChanged.updateToCurrentTime();

		tickTask = new BotTickTask();
		tickTask->schedule(TICK_MS);
	}, "BotManagerEnsureCharacters", 30000);
}

// --- Lookups ---

BotRuntime* BotManager::findByOid(uint64 oid) const {
	// pre: stateMutex locked
	int pos = botIndexByOid.find(oid);

	if (pos == -1)
		return nullptr;

	return bots.get(botIndexByOid.elementAt(pos).getValue());
}

BotRuntime* BotManager::findByFirstName(const String& firstName) const {
	// pre: stateMutex locked
	String lower = firstName.toLowerCase();

	for (int i = 0; i < bots.size(); ++i) {
		BotRuntime* bot = bots.get(i);

		if (bot->firstNameLower == lower)
			return bot;
	}

	return nullptr;
}

bool BotManager::isBotOid(uint64 oid) const {
	if (oid == 0)
		return false;

	Locker locker(&stateMutex);

	return botIndexByOid.contains(oid);
}

bool BotManager::isBot(CreatureObject* creature) const {
	if (creature == nullptr || !creature->isPlayerCreature())
		return false;

	return isBotOid(creature->getObjectID());
}

bool BotManager::isOnlineBot(CreatureObject* creature) const {
	if (creature == nullptr || !creature->isPlayerCreature())
		return false;

	Locker locker(&stateMutex);

	BotRuntime* bot = findByOid(creature->getObjectID());

	return bot != nullptr && bot->state == BotRuntime::ONLINE;
}

Reference<CreatureObject*> BotManager::getOnlineBot(const String& firstName) const {
	Locker locker(&stateMutex);

	BotRuntime* bot = findByFirstName(firstName);

	if (bot == nullptr || bot->state != BotRuntime::ONLINE)
		return nullptr;

	ManagedReference<CreatureObject*> creature = bot->creature.get();

	return creature.get();
}

void BotManager::getOnlineBots(Vector<Reference<CreatureObject*>>& out) const {
	Locker locker(&stateMutex);

	for (int i = 0; i < bots.size(); ++i) {
		BotRuntime* bot = bots.get(i);

		if (bot->state != BotRuntime::ONLINE)
			continue;

		ManagedReference<CreatureObject*> creature = bot->creature.get();

		if (creature != nullptr)
			out.add(creature.get());
	}
}

void BotManager::getBotList(Vector<Reference<BotListEntry*>>& out) const {
	Locker locker(&stateMutex);

	for (int i = 0; i < bots.size(); ++i) {
		BotRuntime* bot = bots.get(i);
		BotEntry* entry = bot->entry;

		Reference<BotListEntry*> item = new BotListEntry();
		item->name = entry->name;
		item->firstName = entry->firstName;
		item->job = entry->job;
		item->city = entry->city;
		item->oid = bot->oid;
		item->online = bot->state == BotRuntime::ONLINE;
		item->state = BotRuntime::stateName(bot->state);
		item->forced = bot->forced;

		out.add(item);
	}
}

// --- Controls ---

bool BotManager::forceState(const String& firstName, bool online) {
	Reference<BotRuntime*> bot;

	{
		Locker locker(&stateMutex);

		bot = findByFirstName(firstName);

		if (bot == nullptr || bot->oid == 0)
			return false;

		bot->forced = true;
		bot->forcedOnline = online;
		bot->nextAttempt.updateToCurrentTime();	// a forced login doesn't wait for a retry
	}

	info(true) << "BotManager: " << bot->entry->name << " forced " << (online ? "online" : "offline")
		<< " until the online rule changes";

	if (tickTask != nullptr && ready)
		Core::getTaskManager()->executeTask([this]() { tick(); }, "BotManagerForcedTick");

	return true;
}

void BotManager::setDevHuman(bool on) {
	{
		Locker locker(&stateMutex);

		if (devHuman == on)
			return;

		devHuman = on;
	}

	info(true) << "BotManager: dev human " << (on ? "on" : "off");
}

bool BotManager::isDevHuman() const {
	Locker locker(&stateMutex);

	return devHuman;
}

// --- The online rule ---

bool BotManager::countHumans() const {
	if (isDevHuman())
		return true;

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager == nullptr)
		return false;

	// Players with a client session; bots never have one, but check anyway
	Vector<uint64> online = playerManager->getOnlinePlayerList();

	for (int i = 0; i < online.size(); ++i) {
		if (!isBotOid(online.get(i)))
			return true;
	}

	return false;
}

void BotManager::notePlanets() {
	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager == nullptr)
		return;

	Vector<uint64> online = playerManager->getOnlinePlayerList();
	uint64 now = System::getMiliTime();

	for (int i = 0; i < online.size(); ++i) {
		uint64 oid = online.get(i);

		if (isBotOid(oid))
			continue;

		ManagedReference<SceneObject*> object = zoneServer->getObject(oid);
		Zone* zone = object != nullptr ? object->getZone() : nullptr;

		if (zone != nullptr)
			planetSeen.put(zone->getZoneName(), now);
	}

	if (isDevHuman()) {
		// The dev switch stands in for a human everywhere
		for (int i = 0; i < bots.size(); ++i)
			planetSeen.put(bots.get(i)->entry->planet, now);
	}
}

bool BotManager::planetOccupied(const String& planet) const {
	if (!planetSeen.contains(planet))
		return false;

	// Like the global rule's logout delay: a planet counts until the last human has been gone that long
	return System::getMiliTime() - planetSeen.get(planet) < (uint64)settings.logoutDelay * 1000;
}

void BotManager::updateRule() {
	// pre: stateMutex locked
	bool want = ruleOnline;
	int64 since = humansChanged.miliDifference();

	if (humansOnline && !ruleOnline && since >= (int64)settings.loginDelay * 1000)
		want = true;
	else if (!humansOnline && ruleOnline && since >= (int64)settings.logoutDelay * 1000)
		want = false;

	if (want == ruleOnline)
		return;

	ruleOnline = want;

	// A forced state lasts until the rule next changes
	for (int i = 0; i < bots.size(); ++i)
		bots.get(i)->forced = false;

	info(true) << "BotManager: the online rule says " << (want ? "online" : "offline");
}

void BotManager::tick() {
	if (zoneServer == nullptr || zoneServer->isServerShuttingDown())
		return;

	Vector<Reference<BotRuntime*>> toLogin, toLogout, toCheck;

	if (!zoneServer->isServerLoading()) {
		bool humans = countHumans();

		Locker locker(&stateMutex);

		if (shuttingDown)
			return;

		if (humans != humansOnline) {
			humansOnline = humans;
			humansChanged.updateToCurrentTime();

			info(true) << "BotManager: " << (humans ? "a human is online" : "no human is online");
		}

		updateRule();
		notePlanets();

		for (int i = 0; i < bots.size(); ++i) {
			BotRuntime* bot = bots.get(i);

			if (bot->oid == 0)
				continue;

			bool desired = bot->forced ? bot->forcedOnline
				: ruleOnline && (bot->entry->online != "planet" || planetOccupied(bot->entry->planet));

			if (desired && bot->state == BotRuntime::OFFLINE) {
				if (!bot->nextAttempt.isPast())
					continue;

				bot->state = BotRuntime::LOGGINGIN;
				bot->stateSince.updateToCurrentTime();
				toLogin.add(bot);
			} else if (!desired && bot->state == BotRuntime::ONLINE) {
				bot->state = BotRuntime::LOGGINGOUT;
				bot->stateSince.updateToCurrentTime();
				toLogout.add(bot);
			} else if (bot->state == BotRuntime::ONLINE) {
				toCheck.add(bot);
			} else if (bot->state != BotRuntime::OFFLINE && bot->stateSince.miliDifference() > 60000) {
				// A login or logout task that never finished; it logged why
				error() << "BotManager: " << bot->entry->name << " stuck " << BotRuntime::stateName(bot->state)
					<< ", resetting to offline";

				bot->state = BotRuntime::OFFLINE;
				bot->stateSince.updateToCurrentTime();
				bot->nextAttempt.updateToCurrentTime();
				bot->nextAttempt.addMiliTime(RETRY_MS);
			}
		}
	}

	for (int i = 0; i < toLogin.size(); ++i)
		scheduleLogin(toLogin.get(i));

	for (int i = 0; i < toLogout.size(); ++i)
		scheduleLogout(toLogout.get(i), false);

	for (int i = 0; i < toCheck.size(); ++i)
		checkOnlineBot(toCheck.get(i));
}

bool BotManager::keepTicking() const {
	Locker locker(&stateMutex);

	return !shuttingDown && zoneServer != nullptr && !zoneServer->isServerShuttingDown();
}

void BotManager::setState(uint64 oid, int state) {
	Locker locker(&stateMutex);

	BotRuntime* bot = findByOid(oid);

	if (bot == nullptr)
		return;

	bot->state = state;
	bot->stateSince.updateToCurrentTime();

	if (state == BotRuntime::OFFLINE)
		bot->creature = nullptr;
}

// --- Login ---

void BotManager::scheduleLogin(BotRuntime* bot) {
	uint64 oid = bot->oid;
	Reference<BotEntry*> entry = bot->entry;

	Core::getTaskManager()->executeTask([this, oid, entry]() {
		// A shutdown that started after this login was queued: stay out, or the bot would be saved online
		if (!keepTicking()) {
			setState(oid, BotRuntime::OFFLINE);
			return;
		}

		ManagedReference<SceneObject*> object = zoneServer->getObject(oid, true);	// loads it from the database
		ManagedReference<CreatureObject*> creature = object != nullptr && object->isPlayerCreature() ? object->asCreatureObject() : nullptr;

		bool ok = false;

		if (creature == nullptr) {
			error() << "BotManager: " << entry->name << " (oid " << oid << ") is not a player character in the database";
		} else {
			Locker locker(creature);

			try {
				ok = loginBot(creature, entry);
			} catch (Exception& e) {
				error() << "BotManager: exception logging in " << entry->name << ": " << e.getMessage();
			}
		}

		if (!ok) {
			Locker locker(&stateMutex);

			BotRuntime* bot = findByOid(oid);

			if (bot != nullptr) {
				bot->state = BotRuntime::OFFLINE;
				bot->stateSince.updateToCurrentTime();
				bot->creature = nullptr;
				bot->nextAttempt.updateToCurrentTime();
				bot->nextAttempt.addMiliTime(RETRY_MS);
			}

			return;
		}

		{
			Locker locker(&stateMutex);

			BotRuntime* bot = findByOid(oid);

			if (bot != nullptr)
				bot->creature = creature.get();
		}

		// The client's load screen: scene-ready a moment later, then the jobs take over
		Reference<CreatureObject*> ref = creature.get();

		Core::getTaskManager()->scheduleTask([this, ref]() {
			Locker locker(ref);

			sceneReady(ref);
		}, "BotSceneReady", SCENE_READY_MS);
	}, "BotLogin", "slowQueue");
}

bool BotManager::loginBot(CreatureObject* creature, BotEntry* entry) {
	// pre: creature locked. SelectCharacterCallback::connectApprovedPlayer minus the client steps.
	PlayerObject* ghost = creature->getPlayerObject();

	if (ghost == nullptr) {
		error() << "BotManager: " << entry->name << " has no PlayerObject";
		return false;
	}

	if (creature->getClient() != nullptr) {
		error() << "BotManager: " << entry->name << " has a game client attached, not logging it in";
		return false;
	}

	// Log in at the station; with no station, where it was saved
	bool hasStation = !entry->planet.isEmpty();
	String zoneName = hasStation ? entry->planet : ghost->getSavedTerrainName();
	Zone* zone = zoneServer->getZone(zoneName);

	if (zone == nullptr) {
		error() << "BotManager: " << entry->name << "'s planet " << zoneName << " is not enabled";
		return false;
	}

	Reference<CellObject*> stationCell;

	if (hasStation && entry->cell != 0) {
		stationCell = zoneServer->getObject(entry->cell, true).castTo<CellObject*>();

		ManagedReference<SceneObject*> building;

		if (stationCell != nullptr)
			building = stationCell->getParent().get();

		if (building == nullptr || building->getZone() != zone) {
			error() << "BotManager: " << entry->name << "'s station cell " << entry->cell << " is not a cell of a building on "
				<< zoneName;
			return false;
		}
	}

	ghost->setTeleporting(true);
	creature->setMovementCounter(0);
	ghost->setClientLastMovementStamp(0);
	ghost->setOnLoadScreen(true);

	// A crash can leave a bot in the world; take it out, so it enters again below (and its building gives it the
	// building's skill mods)
	ManagedReference<SceneObject*> oldParent = creature->getParent().get();

	if (creature->getZone() != nullptr || oldParent != nullptr) {
		info(true) << "BotManager: " << entry->name << " was still in the world (zone " << (creature->getZone() != nullptr ? creature->getZone()->getZoneName() : String("none"))
			<< ", parent " << (oldParent != nullptr ? oldParent->getObjectID() : 0) << ", status " << (ghost->isLinkDead() ? "link dead" : ghost->isLoggingOut() ? "logging out" : ghost->isOffline() ? "offline" : "online")
			<< "), taking it out first";
	}

	if (creature->getZone() != nullptr)
		creature->destroyObjectFromWorld(true);

	creature->removeAllSkillModsOfType(SkillModManager::STRUCTURE);
	creature->clearSpaceStates();

	ManagedReference<SceneObject*> parent;

	if (hasStation) {
		float z = entry->z;

		if (stationCell == nullptr && z == 0)
			z = CollisionManager::getWorldFloorCollision(entry->x, entry->y, zone, false);

		creature->initializePosition(entry->x, z, entry->y);
		creature->setDirection(Math::deg2rad(entry->heading));

		if (stationCell != nullptr) {
			stationCell->transferObject(creature, -1, true);
			parent = stationCell.get();
		} else {
			zone->transferObject(creature, -1, true);
		}
	} else {
		uint64 savedParentID = ghost->getSavedParentID();
		ManagedReference<SceneObject*> savedParent;

		if (savedParentID != 0)
			savedParent = zoneServer->getObject(savedParentID, true);

		if (savedParent != nullptr && savedParent->isCellObject()) {
			ManagedReference<SceneObject*> root = savedParent->getRootParent();

			if (root != nullptr && root->getZone() != nullptr) {
				savedParent->transferObject(creature, -1, true);
				parent = savedParent;
			}
		}

		if (parent == nullptr) {
			if (savedParentID != 0) {
				Vector3 last = ghost->getLastLogoutWorldPosition();
				float z = CollisionManager::getWorldFloorCollision(last.getX(), last.getY(), zone, false);

				creature->initializePosition(last.getX(), z, last.getY());
			}

			zone->transferObject(creature, -1, true);
		}
	}

	if (creature->getZone() == nullptr) {
		error() << "BotManager: " << entry->name << " did not make it into " << zoneName;
		ghost->setTeleporting(false);
		ghost->setOnLoadScreen(false);
		return false;
	}

	if (parent == nullptr)
		ghost->setSavedParentID(0);

	SkillModManager::instance()->verifyStructureSkillMods(creature);

	ghost->setOnline();
	ghost->notifyOnline();

	ChatManager* chatManager = zoneServer->getChatManager();

	if (chatManager != nullptr)
		chatManager->addPlayer(creature);

	// As at a client login: no leftover performance (the jobs start a dance themselves)
	if (!creature->isPlayingMusic() && !creature->isDancing()) {
		creature->setPerformanceStartTime(0, false);
		creature->setPerformanceType(0, false);

		CreatureObjectDeltaMessage6* dcreo6 = new CreatureObjectDeltaMessage6(creature);
		dcreo6->updatePerformanceAnimation(creature->getPerformanceAnimation());
		dcreo6->updatePerformanceStartTime(0);
		dcreo6->updatePerformanceType(0);
		dcreo6->close();
		creature->broadcastMessage(dcreo6, true);

		creature->setListenToID(0);

		if (creature->getPosture() == CreaturePosture::SKILLANIMATING)
			creature->setPosture(CreaturePosture::UPRIGHT);
	}

	SkillModManager::instance()->verifyWearableSkillMods(creature);

	ghost->unloadSpawnedChildren(true);

	Vector3 pos = creature->getWorldPosition();
	StringBuffer where;
	where << zone->getZoneName() << " at " << (int)pos.getX() << " " << (int)pos.getY();

	if (parent != nullptr)
		where << " in cell " << parent->getObjectID();

	info(true) << "BotManager: " << entry->name << " logging in on " << where.toString();

	return true;
}

void BotManager::sceneReady(CreatureObject* creature) {
	// pre: creature locked
	uint64 oid = creature->getObjectID();
	PlayerObject* ghost = creature->getPlayerObject();

	if (ghost == nullptr || !ghost->isOnline() || creature->getZone() == nullptr) {
		error() << "BotManager: " << creature->getFirstName() << " left the world before it was scene-ready";
		setState(oid, BotRuntime::OFFLINE);
		return;
	}

	ghost->notifySceneReady();

	// Standing still: a bot saved mid-walk (a restart while it moved) keeps its speed, and Core3 won't start a
	// dance or a song while it's "running"
	if (creature->getCurrentSpeed() != 0) {
		creature->setCurrentSpeed(0);
		creature->updateLocomotion();
	}

	setState(oid, BotRuntime::ONLINE);

	info(true) << "BotManager: " << creature->getDisplayedName() << " logged in, skill mod private_medical_rating "
		<< creature->getSkillMod("private_medical_rating") << ", private_buff_mind " << creature->getSkillMod("private_buff_mind");

	// notifySceneReady spawns a helper droid for a character under a day old; a bot puts it away
	if (ghost->getCharacterAgeInDays() < 1) {
		Reference<CreatureObject*> ref = creature;

		Core::getTaskManager()->scheduleTask([ref]() {
			Locker locker(ref);

			PlayerObject* ghost = ref->getPlayerObject();

			if (ghost != nullptr && ghost->isOnline())
				ghost->unloadSpawnedChildren(true);
		}, "BotStoreHelperDroid", 8000);
	}

	BotTrade::restoreOwed(creature);

	BotLua::callJobsEvent("onLogin", creature);
}

// --- Logout ---

void BotManager::scheduleLogout(BotRuntime* bot, bool fromShutdown) {
	uint64 oid = bot->oid;
	ManagedReference<CreatureObject*> creature;

	{
		Locker locker(&stateMutex);

		creature = bot->creature.get();
	}

	if (creature == nullptr) {
		ManagedReference<SceneObject*> object = zoneServer->getObject(oid);
		creature = object != nullptr && object->isPlayerCreature() ? object->asCreatureObject() : nullptr;
	}

	if (creature == nullptr) {
		setState(oid, BotRuntime::OFFLINE);
		return;
	}

	Reference<CreatureObject*> ref = creature.get();

	Core::getTaskManager()->executeTask([this, ref, oid, fromShutdown]() {
		{
			Locker locker(ref);

			try {
				logoutBot(ref, true);
			} catch (Exception& e) {
				error() << "BotManager: exception logging out " << ref->getFirstName() << ": " << e.getMessage();
			}
		}

		setState(oid, BotRuntime::OFFLINE);
	}, fromShutdown ? "BotShutdownLogout" : "BotLogout");
}

void BotManager::logoutBot(CreatureObject* creature, bool callLua) {
	// pre: creature locked. The link-dead unload path (PlayerObject::doRecovery), at once.
	PlayerObject* ghost = creature->getPlayerObject();

	if (ghost == nullptr)
		return;

	if (callLua)
		BotLua::callJobsEvent("onLogout", creature);

	// No trade left open, and no customer's item kept (BotTrade, Phase 4)
	BotTrade::abortAtLogout(creature);

	if (ghost->isOnline() || ghost->isLinkDead() || creature->getZone() != nullptr) {
		ghost->setLastLogoutWorldPosition();

		// Notifies observers and screenplays that it's offline, sets the LD bit and clears the command queue
		if (!ghost->isLinkDead())
			ghost->setLinkDead(true);

		ghost->unload();
	}

	ghost->setOffline();
	ghost->setTeleporting(false);
	ghost->setOnLoadScreen(false);

	info(true) << "BotManager: " << creature->getDisplayedName() << " logged out";
}

void BotManager::shutdown() {
	Vector<Reference<BotRuntime*>> toLogout;

	{
		Locker locker(&stateMutex);

		shuttingDown = true;

		if (tickTask != nullptr)
			tickTask->cancel();

		for (int i = 0; i < bots.size(); ++i) {
			BotRuntime* bot = bots.get(i);

			if (bot->state == BotRuntime::OFFLINE)
				continue;

			bot->state = BotRuntime::LOGGINGOUT;
			bot->stateSince.updateToCurrentTime();
			toLogout.add(bot);
		}
	}

	if (toLogout.isEmpty()) {
		info(true) << "BotManager: shutdown, no bots online";
		return;
	}

	info(true) << "BotManager: shutdown, logging out " << toLogout.size() << " bots";

	for (int i = 0; i < toLogout.size(); ++i)
		scheduleLogout(toLogout.get(i), true);

	// Wait for the logout tasks (they run on the task threads, which have the screenplay Lua state)
	for (int wait = 0; wait < 150; ++wait) {
		int left = 0;

		{
			Locker locker(&stateMutex);

			for (int i = 0; i < bots.size(); ++i) {
				if (bots.get(i)->state != BotRuntime::OFFLINE)
					++left;
			}
		}

		if (left == 0) {
			info(true) << "BotManager: all bots logged out";
			return;
		}

		Thread::sleep(100);
	}

	error() << "BotManager: shutdown, some bots did not log out in 15 s";
}

// --- Client chores ---

void BotManager::checkOnlineBot(BotRuntime* bot) {
	// The tick's look at an online bot, without its lock; anything to fix runs in a task that holds it
	ManagedReference<CreatureObject*> creature;

	{
		Locker locker(&stateMutex);

		creature = bot->creature.get();
	}

	if (creature == nullptr) {
		error() << "BotManager: " << bot->entry->name << " is gone from memory while online";
		setState(bot->oid, BotRuntime::OFFLINE);
		return;
	}

	PlayerObject* ghost = creature->getPlayerObject();

	if (ghost == nullptr)
		return;

	bool external = ghost->isLoggingOut() || ghost->isLinkDead() || ghost->isOffline() || creature->getZone() == nullptr;
	bool loadScreen = ghost->isOnLoadScreen();
	bool teleporting = ghost->isTeleporting();

	if (!external && !loadScreen && !teleporting)
		return;

	uint64 oid = bot->oid;
	Reference<CreatureObject*> ref = creature.get();

	creature->executeOrderedTask([this, ref, oid]() {
		Locker locker(ref);

		PlayerObject* ghost = ref->getPlayerObject();

		if (ghost == nullptr || !isOnlineBot(ref))
			return;

		if (ghost->isLoggingOut() || ghost->isLinkDead() || ghost->isOffline() || ref->getZone() == nullptr) {
			// Kicked, /logout or unloaded by someone else: finish the logout, and stay out until the rule changes
			info(true) << "BotManager: " << ref->getDisplayedName() << " was logged out from outside (status "
				<< (ghost->isLoggingOut() ? "logging out" : ghost->isLinkDead() ? "link dead" : ghost->isOffline() ? "offline" : "not in a zone")
				<< "), finishing the logout";

			{
				Locker slocker(&stateMutex);

				BotRuntime* bot = findByOid(oid);

				if (bot != nullptr) {
					bot->state = BotRuntime::LOGGINGOUT;
					bot->forced = true;
					bot->forcedOnline = false;
				}
			}

			logoutBot(ref, true);
			setState(oid, BotRuntime::OFFLINE);
			return;
		}

		if (ghost->isOnLoadScreen()) {
			// A zone switch: the client would send CmdSceneReady when the new planet is loaded
			ghost->notifySceneReady();
			info(true) << "BotManager: " << ref->getDisplayedName() << " scene-ready after a zone switch";
		} else if (ghost->isTeleporting()) {
			// A teleport within the zone: the client would send TeleportAck
			ghost->setTeleporting(false);
			info(true) << "BotManager: " << ref->getDisplayedName() << " teleport acknowledged";
		}
	}, "BotCheckOnline");
}

void BotManager::onSuiBoxCreated(uint64 playerOid, uint32 boxID) {
	if (!isBotOid(playerOid))
		return;

	// Windows a bot answers itself, so they stay open: cloning after death (BotCombat) and the slicing menu (BotSlice)
	uint32 windowType = boxID & 0xFFFF;

	if (windowType == SuiWindowType::CLONE_REQUEST || windowType == SuiWindowType::CLONE_REQUEST_FACTIONAL
		|| windowType == SuiWindowType::SLICING_MENU)
		return;

	ZoneServer* server = zoneServer;

	if (server == nullptr)
		return;

	Core::getTaskManager()->scheduleTask([this, server, playerOid, boxID]() {
		ManagedReference<SceneObject*> object = server->getObject(playerOid);
		ManagedReference<CreatureObject*> creature = object != nullptr && object->isPlayerCreature() ? object->asCreatureObject() : nullptr;

		if (creature == nullptr)
			return;

		Locker locker(creature);

		PlayerObject* ghost = creature->getPlayerObject();

		if (ghost == nullptr || !ghost->hasSuiBox(boxID))
			return;

		// Closed without an answer, as when a player closes the window: no callback runs
		ghost->removeSuiBox(boxID);

		info(true) << "BotManager: " << creature->getDisplayedName() << " closed a window (type " << (boxID & 0xFFFF) << ")";
	}, "BotCloseSuiBox", SUI_CLOSE_MS);
}
