/*
 * BotManager: bot players (Phase 3). See BotManager.h and patches/README.md.
 */

#include "BotManager.h"
#include "BotFactory.h"
#include "BotCrews.h"
#include "BotLua.h"
#include "BotTrade.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/cell/CellObject.h"
#include "server/zone/CloseObjectsVector.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/db/ServerDatabase.h"
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

// pre: creature locked. Entering a cell, Core3 sends the creature to the players already in the building before it
// has its zone (BuildingObject::notifyObjectInsertedToZone), so its baselines are skipped and their clients never draw
// it. Send it again now that it's in the world.
void showToNearbyPlayers(CreatureObject* creature) {
	if (creature->getZone() == nullptr || creature->getParent().get() == nullptr)
		return;

	CloseObjectsVector* closeObjects = creature->getCloseObjects();

	if (closeObjects == nullptr)
		return;

	Vector<TreeEntry*> players;
	closeObjects->safeCopyReceiversTo(players, CloseObjectsVector::PLAYERTYPE);

	for (int i = 0; i < players.size(); ++i) {
		SceneObject* player = static_cast<SceneObject*>(players.get(i));

		if (player != nullptr && player != creature && player->getClient() != nullptr)
			creature->sendTo(player, true, false);
	}
}

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

	int rosterBots = roster.size();

	// Phase 9: the own crews hired at runtime (a fresh volume has no file)
	{
		String crewsPath = BotCrews::getPath();
		File crewsFile(crewsPath);

		if (crewsFile.setReadOnly()) {
			crewsFile.close();

			BotRosterList crews, declined;
			BotSettings unused;

			if (BotFactory::loadRoster(crewsPath, crews, unused, "BotOwnCrews", &roster, &declined)) {
				for (int i = 0; i < crews.size(); ++i) {
					roster.add(crews.get(i));
					crewEntries.add(crews.get(i));
				}

				for (int i = 0; i < declined.size(); ++i)
					crewEntries.add(declined.get(i));

				BotCrews::loadPending(crewsPath, pendingDeletes);
			} else {
				// Never overwrite what could not be read: keep a copy, and let no hire or let-go write the file until a restart
				// has read a good one
				String copy;

				crewsBroken = true;
				BotCrews::copyAside(crewsPath, copy);
				error() << "BotManager: " << crewsPath << " exists but did not load; a copy is in " << copy
					<< ". No crew can be hired or let go until it is fixed and the server restarted";
			}
		} else {
			info(true) << "BotManager: no own crews yet (" << crewsPath << " is not there)";
		}
	}

	{
		Locker locker(&stateMutex);

		for (int i = 0; i < roster.size(); ++i) {
			Reference<BotRuntime*> bot = new BotRuntime();
			bot->entry = roster.get(i);
			bot->firstNameLower = bot->entry->firstName.toLowerCase();
			bot->index = i;
			bots.add(bot);
		}
	}

	info(true) << "BotManager: started, " << rosterBots << " bots in the roster and " << (roster.size() - rosterBots)
		<< " in own crews, login delay " << settings.loginDelay << " s, logout delay " << settings.logoutDelay << " s";

	// Make any bot that doesn't exist yet, once the zones have loaded; then the online rule starts
	Core::getTaskManager()->scheduleTask([this]() {
		// Characters of bots let go in an earlier session: gone for good (the rows could have come back with a save, or the
		// server stopped before the deletion ran)
		for (int i = 0; i < 600 && zoneServer->isServerLoading(); ++i)
			Thread::sleep(500);

		PendingDeletionList sweep;

		{
			Locker locker(&stateMutex);

			sweep = pendingDeletes;
		}

		for (int i = 0; i < sweep.size(); ++i) {
			info(true) << "BotManager: checking that " << sweep.get(i)->firstName << " (oid " << sweep.get(i)->oid << ") is gone";
			deleteCharacter(sweep.get(i)->oid, sweep.get(i)->firstName);
			BotCrews::removeDoctrine(sweep.get(i)->firstName);
		}

		if (!sweep.isEmpty()) {
			{
				Locker locker(&stateMutex);

				pendingDeletes.removeAll();
			}

			writeCrews();
		}

		Vector<Reference<BotRuntime*>> todo;

		{
			Locker locker(&stateMutex);

			todo = bots;
		}

		for (int i = 0; i < todo.size(); ++i) {
			BotRuntime* runtime = todo.get(i);
			BotEntry* entry = runtime->entry;

			uint64 oid = BotFactory::ensureCharacter(zoneServer, *entry);

			if (oid == 0) {
				error() << "BotManager: " << entry->name << " not created";
				continue;
			}

			info(true) << "BotManager: " << entry->name << " ready, oid " << oid;

			{
				Locker locker(&stateMutex);

				runtime->oid = oid;
				botIndexByOid.put(oid, runtime->index);
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

		if (!bot->gone && bot->firstNameLower == lower)
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

	// (a bot that has been let go is out of the game's lists at once, even while it is still logging out)
	return bot != nullptr && !bot->gone && bot->state == BotRuntime::ONLINE;
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

		if (bot->gone || bot->state != BotRuntime::ONLINE)
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

		if (bot->gone)
			continue;

		Reference<BotListEntry*> item = new BotListEntry();
		item->name = entry->name;
		item->firstName = entry->firstName;
		item->job = entry->job;
		item->city = entry->city;
		item->oid = bot->oid;
		item->online = bot->state == BotRuntime::ONLINE;
		item->state = BotRuntime::stateName(bot->state);
		item->forced = bot->forced;
		item->species = entry->species;
		item->sex = entry->sex;
		item->owner = entry->owner;
		item->hiredAt = entry->hiredAt;

		out.add(item);
	}
}

// --- Own crews (Phase 9) ---

bool BotManager::ownerOnline(uint64 owner, const SortedVector<uint64>& online) const {
	// pre: stateMutex locked
	if (online.contains(owner))
		return true;

	// A bot standing in for a human on the local server (BotCrew:devLead) counts while it is logged in
	BotRuntime* stand = findByOid(owner);

	return stand != nullptr && !stand->gone && stand->state == BotRuntime::ONLINE;
}

bool BotManager::ownerWants(uint64 owner, const SortedVector<uint64>& online) {
	// pre: stateMutex locked. The global rule's delays, for one owner: in loginDelay seconds after the character is
	// online, out logoutDelay seconds after it left
	int pos = ownerRules.find(owner);
	Reference<OwnerRule*> rule;

	if (pos == -1) {
		rule = new OwnerRule();
		rule->changed.updateToCurrentTime();
		ownerRules.put(owner, rule);
	} else {
		rule = ownerRules.elementAt(pos).getValue();
	}

	bool now = ownerOnline(owner, online);

	if (now != rule->online) {
		rule->online = now;
		rule->changed.updateToCurrentTime();
	}

	int64 since = rule->changed.miliDifference();
	bool want = rule->rule;

	if (rule->online && !rule->rule && since >= (int64)settings.loginDelay * 1000)
		want = true;
	else if (!rule->online && rule->rule && since >= (int64)settings.logoutDelay * 1000)
		want = false;

	if (want != rule->rule) {
		rule->rule = want;

		// A forced state lasts until the rule next changes
		for (int i = 0; i < bots.size(); ++i) {
			if (bots.get(i)->entry->owner == owner)
				bots.get(i)->forced = false;
		}

		info(true) << "BotManager: the online rule for " << owner << "'s crew says " << (want ? "online" : "offline");
	}

	return rule->rule;
}

void BotManager::requestSave() {
	// pre: stateMutex locked. One write at a time waits in a task; it copies the lists when it runs, so a burst of hires is one write
	if (saveQueued)
		return;

	saveQueued = true;

	Core::getTaskManager()->executeTask([this]() { writeCrews(); }, "BotSaveCrews", "slowQueue");
}

void BotManager::writeCrews() {
	BotRosterList entries;
	PendingDeletionList pending;

	{
		Locker locker(&stateMutex);

		saveQueued = false;

		if (crewsBroken)
			return;

		entries = crewEntries;
		pending = pendingDeletes;
	}

	BotCrews::save(entries, pending);
}

Reference<BotEntry*> BotManager::getEntry(const String& firstName) const {
	Locker locker(&stateMutex);

	BotRuntime* bot = findByFirstName(firstName);

	if (bot == nullptr)
		return nullptr;

	return bot->entry;
}

uint64 BotManager::getOwner(uint64 botOid) const {
	Locker locker(&stateMutex);

	BotRuntime* bot = findByOid(botOid);

	return bot != nullptr && !bot->gone ? bot->entry->owner : 0;
}

void BotManager::getCrewOf(uint64 owner, Vector<Reference<BotListEntry*>>& out) const {
	if (owner == 0)
		return;

	Locker locker(&stateMutex);

	for (int i = 0; i < bots.size(); ++i) {
		BotRuntime* bot = bots.get(i);
		BotEntry* entry = bot->entry;

		if (bot->gone || entry->owner != owner)
			continue;

		Reference<BotListEntry*> item = new BotListEntry();
		item->name = entry->name;
		item->firstName = entry->firstName;
		item->job = entry->job;
		item->city = entry->city;
		item->oid = bot->oid;
		item->online = bot->state == BotRuntime::ONLINE;
		item->state = BotRuntime::stateName(bot->state);
		item->forced = bot->forced;
		item->species = entry->species;
		item->sex = entry->sex;
		item->owner = entry->owner;
		item->hiredAt = entry->hiredAt;

		out.add(item);
	}
}

bool BotManager::nameFree(const String& firstName, String& reason) const {
	if (firstName.isEmpty()) {
		reason = "no name";
		return false;
	}

	{
		Locker locker(&stateMutex);

		if (findByFirstName(firstName) != nullptr) {
			reason = "a crew member already has that name";
			return false;
		}

		for (int i = 0; i < pendingDeletes.size(); ++i) {
			if (!pendingDeletes.get(i)->done && pendingDeletes.get(i)->firstName.toLowerCase() == firstName.toLowerCase()) {
				reason = "that name is still being cleared";
				return false;
			}
		}
	}

	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

	if (playerManager != nullptr && playerManager->existsName(firstName)) {
		reason = "a character already has that name";
		return false;
	}

	return true;
}

bool BotManager::hire(BotEntry* given, String& reason) {
	Reference<BotEntry*> entry = given;
	Reference<BotRuntime*> runtime;

	if (entry == nullptr || zoneServer == nullptr) {
		reason = "no entry";
		return false;
	}

	// A runtime entry is always an own-crew bot
	entry->online = "owner";

	if (entry->account.isEmpty())
		entry->account = BotCrews::accountFor(entry->firstName);

	{
		Locker locker(&stateMutex);

		if (crewsBroken) {
			reason = "the crews file is broken";
			return false;
		}

		if (!ready || shuttingDown) {
			reason = "the server is still starting";
			return false;
		}

		if (entry->owner == 0) {
			reason = "no owner";
			return false;
		}

		// (a let-go bot's character is still being cleared: its name, and so its account, can't be used yet)
		for (int i = 0; i < pendingDeletes.size(); ++i) {
			if (!pendingDeletes.get(i)->done && pendingDeletes.get(i)->firstName.toLowerCase() == entry->firstName.toLowerCase()) {
				reason = "that name is still being cleared";
				return false;
			}
		}

		BotRosterList scope;
		int ownerCrew = 0;

		for (int i = 0; i < bots.size(); ++i) {
			BotRuntime* other = bots.get(i);

			if (other->gone)
				continue;

			scope.add(other->entry);

			if (other->entry->owner == entry->owner) {
				++ownerCrew;

				if (other->entry->job == entry->job) {
					reason = "the crew already has a " + entry->job;
					return false;
				}
			}
		}

		if (ownerCrew >= 7) {
			reason = "a crew has seven at most";
			return false;
		}

		if (!BotFactory::validateEntry(*entry, scope, reason))
			return false;

		runtime = new BotRuntime();
		runtime->entry = entry;
		runtime->firstNameLower = entry->firstName.toLowerCase();
		runtime->index = bots.size();
		bots.add(runtime);
		crewEntries.add(entry);
		requestSave();
	}

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager != nullptr && playerManager->existsName(entry->firstName)) {
		removeUnmade(runtime);
		reason = "a character already has that name";
		return false;
	}

	info(true) << "BotManager: hired " << entry->name << " (" << entry->species << " " << entry->sex << ", " << entry->job
		<< ") for " << entry->owner << ", " << entry->skills.size() << " boxes listed";

	// The account and the character, in a task (the factory sleeps while the server loads and writes to the database)
	Core::getTaskManager()->executeTask([this, runtime, entry]() {
		uint64 oid = 0;

		// (the file first: a character the file does not list would be lost to a crash)
		writeCrews();

		try {
			oid = BotFactory::ensureCharacter(zoneServer, *entry);
		} catch (Exception& e) {
			error() << "BotManager: exception making " << entry->name << ": " << e.getMessage();
		}

		if (oid == 0) {
			error() << "BotManager: " << entry->name << " could not be made, dropping the hire";
			removeUnmade(runtime);
			return;
		}

		{
			Locker locker(&stateMutex);

			if (runtime->gone)
				return;

			runtime->oid = oid;
			botIndexByOid.put(oid, runtime->index);
		}

		BotCrews::writeDoctrine(*entry);

		info(true) << "BotManager: " << entry->name << " ready, oid " << oid;
	}, "BotHire", "slowQueue");

	return true;
}

void BotManager::removeUnmade(BotRuntime* bot) {
	Locker locker(&stateMutex);

	bot->gone = true;

	for (int i = 0; i < crewEntries.size(); ++i) {
		if (crewEntries.get(i) == bot->entry) {
			crewEntries.remove(i);
			break;
		}
	}

	requestSave();
}

bool BotManager::letGo(uint64 oid, String& reason) {
	Reference<BotRuntime*> runtime;
	Reference<BotEntry*> entry;

	{
		Locker locker(&stateMutex);

		if (crewsBroken) {
			reason = "the crews file is broken";
			return false;
		}

		runtime = findByOid(oid);

		if (runtime == nullptr || runtime->gone) {
			reason = "no such crew member";
			return false;
		}

		if (runtime->entry->owner == 0) {
			reason = "that bot isn't in an own crew";
			return false;
		}

		entry = runtime->entry;
		runtime->gone = true;

		for (int i = 0; i < crewEntries.size(); ++i) {
			if (crewEntries.get(i) == entry) {
				crewEntries.remove(i);
				break;
			}
		}

		Reference<PendingDeletion*> pending = new PendingDeletion();

		pending->oid = oid;
		pending->firstName = entry->firstName;
		pending->account = entry->account;
		pendingDeletes.add(pending);

		requestSave();
	}

	info(true) << "BotManager: letting " << entry->name << " go";

	finishLetGo(runtime, 0);

	return true;
}

// The character goes in steps: wait for a login in progress to finish, log it out the way the online rule does (BotJobs:onLogout
// ends its Lua chains), give the tasks a bot leaves behind a few seconds, then delete it. The file lists the deletion from the
// let-go on, so a stop in between, or a save that writes the row back, is put right at the next boot.
void BotManager::finishLetGo(Reference<BotRuntime*> runtime, int step) {
	Reference<BotEntry*> entry = runtime->entry;
	uint64 oid = runtime->oid;

	if (step < 100) {
		int state;

		{
			Locker locker(&stateMutex);

			state = runtime->state;

			if (state == BotRuntime::ONLINE && step < 90) {
				runtime->state = BotRuntime::LOGGINGOUT;
				runtime->stateSince.updateToCurrentTime();
				state = -1;
			}
		}

		if (state == -1) {
			scheduleLogout(runtime, false);
			Core::getTaskManager()->scheduleTask([this, runtime, step]() { finishLetGo(runtime, step + 1); }, "BotLetGoWait", 1000);
		} else if (state == BotRuntime::OFFLINE || step >= 90) {
			Core::getTaskManager()->scheduleTask([this, runtime]() { finishLetGo(runtime, 100); }, "BotLetGoSettle", LET_GO_SETTLE_MS);
		} else {
			// (a login or logout in progress)
			Core::getTaskManager()->scheduleTask([this, runtime, step]() { finishLetGo(runtime, step + 1); }, "BotLetGoWait", 1000);
		}

		return;
	}

	Core::getTaskManager()->executeTask([this, runtime, entry, oid]() {
		writeCrews();	// (the deletion is listed on disk before it runs)
		deleteCharacter(oid, entry->firstName);
		BotCrews::removeDoctrine(entry->firstName);

		// Not a bot any more: nothing refers to the oid
		Locker locker(&stateMutex);

		botIndexByOid.drop(oid);
		runtime->state = BotRuntime::OFFLINE;
		runtime->creature = nullptr;

		for (int i = 0; i < pendingDeletes.size(); ++i) {
			if (pendingDeletes.get(i)->oid == oid)
				pendingDeletes.get(i)->done = true;
		}

		requestSave();
	}, "BotLetGo", "slowQueue");
}

void BotManager::deleteCharacter(uint64 oid, const String& firstName) {
	// Core3's character deletion (LoginPacketHandler, then DeleteCharactersTask) in one go: the row moves to
	// deleted_characters, the name is released, and the character and what it owns are destroyed
	ManagedReference<SceneObject*> object = zoneServer->getObject(oid, true);
	ManagedReference<CreatureObject*> creature = object != nullptr && object->isPlayerCreature() ? object->asCreatureObject() : nullptr;

	if (creature != nullptr) {
		Locker locker(creature);

		PlayerObject* ghost = creature->getPlayerObject();

		// (BotCrew's onLogout runs; a trade or group it is in ends)
		if (ghost != nullptr && (ghost->isOnline() || ghost->isLinkDead() || creature->getZone() != nullptr))
			logoutBot(creature, true);

		ChatManager* chatManager = zoneServer->getChatManager();

		if (chatManager != nullptr)
			chatManager->removePlayer(firstName);
	}

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager != nullptr)
		playerManager->removePlayer(oid);

	// (each statement on its own: the copy into deleted_characters fails when a boot checks a character that was already moved)
	StringBuffer statements[3];

	statements[0] << "INSERT INTO deleted_characters SELECT *, 1 as db_deleted FROM characters WHERE character_oid = " << oid;
	statements[1] << "DELETE FROM characters WHERE character_oid = " << oid;
	statements[2] << "DELETE FROM characters_dirty WHERE character_oid = " << oid;

	for (int i = 0; i < 3; ++i) {
		try {
			UniqueReference<ResultSet*> result(ServerDatabase::instance()->executeQuery(statements[i]));
		} catch (const DatabaseException& e) {
			if (i != 0)
				error() << "BotManager: deleting " << firstName << "'s rows: " << e.getMessage();
		}
	}

	if (creature != nullptr) {
		Locker locker(creature);

		if (creature->getZone() != nullptr)
			creature->destroyObjectFromWorld(false);

		creature->destroyPlayerCreatureFromDatabase(true);
	}

	info(true) << "BotManager: " << firstName << " deleted (oid " << oid << ")";
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

void BotManager::getOnlineHumans(Vector<uint64>& out) const {
	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

	if (playerManager == nullptr)
		return;

	Vector<uint64> online = playerManager->getOnlinePlayerList();

	for (int i = 0; i < online.size(); ++i) {
		if (!isBotOid(online.get(i)))
			out.add(online.get(i));
	}
}

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
		for (int i = 0; i < bots.size(); ++i) {
			if (!bots.get(i)->gone)
				planetSeen.put(bots.get(i)->entry->planet, now);
		}
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

		// The owners of own crews who are online with a client (or are a bot standing in for one, see ownerOnline)
		SortedVector<uint64> onlineOwners;
		{
			PlayerManager* playerManager = zoneServer->getPlayerManager();

			if (playerManager != nullptr) {
				Vector<uint64> online = playerManager->getOnlinePlayerList();

				for (int i = 0; i < online.size(); ++i)
					onlineOwners.put(online.get(i));
			}
		}

		for (int i = 0; i < bots.size(); ++i) {
			BotRuntime* bot = bots.get(i);

			if (bot->oid == 0 || bot->gone)
				continue;

			bool desired;

			if (bot->forced)
				desired = bot->forcedOnline;
			else if (bot->entry->online == "owner")
				desired = ownerWants(bot->entry->owner, onlineOwners);
			else
				desired = ruleOnline && (bot->entry->online != "planet" || planetOccupied(bot->entry->planet));

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
	showToNearbyPlayers(creature);

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

		Core::getTaskManager()->scheduleTask([this, ref]() {
			// (a bot let go in the meantime is gone: leave it)
			if (!isOnlineBot(ref))
				return;

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

	// (a write that is still waiting in a task would not run before the process ends)
	writeCrews();

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
			showToNearbyPlayers(ref);
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
