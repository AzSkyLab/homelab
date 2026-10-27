/*
 * BotManager: bot players, characters the server plays itself (Phase 3, see patches/README.md).
 * Not part of upstream Core3; copied into src/server/zone/managers/bot/ at image build.
 *
 * A bot is a real player character (CreatureObject + PlayerObject, saved like ours) with no client attached. This
 * class owns its lifecycle:
 * - the roster (custom_scripts/bots/roster.lua, read by BotFactory) and making the characters (BotFactory) at boot;
 * - logging bots in (SelectCharacterCallback::connectApprovedPlayer minus the client steps, then notifySceneReady) and
 *   out (the link-dead unload path), by the online rule: in loginDelay seconds after the first human is online, out
 *   logoutDelay seconds after the last human leaves, with forced states from Lua or the console;
 * - the chores a client does: scene-ready after a teleport or zone switch, closing game windows (SUI boxes), and a
 *   clean logout at shutdown;
 * - the Lua events BotJobs:onLogin / onLogout (onHeard comes from BotChat).
 */

#ifndef BOTMANAGER_H_
#define BOTMANAGER_H_

#include "engine/engine.h"
#include "BotEntry.h"

namespace server {
namespace zone {

class ZoneServer;

namespace objects {
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

// One roster bot's state while the server runs. Guarded by BotManager's mutex.
class BotRuntime : public Object {
public:
	enum { OFFLINE, LOGGINGIN, ONLINE, LOGGINGOUT };

	Reference<BotEntry*> entry;
	String firstNameLower;
	uint64 oid = 0;					// 0 until the factory made or found the character
	int index = 0;					// its place in BotManager::bots
	bool gone = false;				// let go (Phase 9): never logs in again, out of every list; the character is being deleted
	int state = OFFLINE;
	bool forced = false;			// botLogin/botLogout: hold forcedOnline until the online rule changes state
	bool forcedOnline = false;
	Time nextAttempt;				// a failed login waits before the next try
	Time stateSince;
	ManagedWeakReference<server::zone::objects::creature::CreatureObject*> creature;	// set while not OFFLINE

	static const char* stateName(int state);
};

// What botList() returns for one bot
class BotListEntry : public Object {
public:
	String name;
	String firstName;
	String job;
	String city;
	uint64 oid = 0;
	bool online = false;
	String state;
	bool forced = false;
	// Phase 9 (own crews)
	String species;
	String sex;
	uint64 owner = 0;
	int64 hiredAt = 0;
};

// An own-crew owner's state for the "owner" online rule
class OwnerRule : public Object {
public:
	bool online = false;	// as of the last tick
	bool rule = false;		// what the rule says now
	Time changed;			// when online last flipped
};

class BotManager : public Singleton<BotManager>, public Object, public Logger {
	ManagedReference<ZoneServer*> zoneServer;
	BotRosterList roster;
	BotSettings settings;
	BotRosterList crewEntries;	// the own crews' file as it stands, hired bots and any entry the checks declined (written back whole)
	PendingDeletionList pendingDeletes;	// characters of bots let go, recorded in that file until a boot has checked them
	bool crewsBroken = false;	// the crews file exists but did not load: hires and let-gos are refused so it is never overwritten
	bool saveQueued = false;	// a write of the crews file is waiting in a task

	mutable Mutex stateMutex;
	Vector<Reference<BotRuntime*>> bots;	// same order as roster
	VectorMap<uint64, int> botIndexByOid;	// every created bot's oid -> index in bots

	bool ready = false;			// characters checked; the rule runs from here on
	bool shuttingDown = false;
	bool devHuman = false;		// botSetDevHuman: pretend a human is online
	bool humansOnline = false;	// as of the last tick
	Time humansChanged;			// when humansOnline last flipped
	bool ruleOnline = false;	// what the online rule says now
	VectorMap<String, uint64> planetSeen;	// zone name -> when a human was last on it (ms), for "planet" bots
	VectorMap<uint64, Reference<OwnerRule*>> ownerRules;	// own-crew owner oid -> its rule

	Reference<Task*> tickTask;

public:
	static const int TICK_MS = 2000;
	static const int RETRY_MS = 5 * 60 * 1000;	// after a failed login
	static const int SUI_CLOSE_MS = 1500;		// a client closes a window about this fast
	static const int SCENE_READY_MS = 1000;		// a client takes about this long on the load screen
	static const int LET_GO_SETTLE_MS = 10000;	// a bot let go is deleted this long after its logout (see finishLetGo)

	BotManager();

	// Called once from ZoneServerImplementation::initialize, after the managers start
	void start(ZoneServer* zoneServer);

	// Called from ServerCore::shutdown before players are disconnected: logs every bot out cleanly
	void shutdown();

	// The online rule, forced states and the client chores; runs every TICK_MS
	void tick();
	bool keepTicking() const;

	// Bot lookups (any thread, no locks needed by the caller)
	bool isBotOid(uint64 oid) const;
	bool isBot(server::zone::objects::creature::CreatureObject* creature) const;
	bool isOnlineBot(server::zone::objects::creature::CreatureObject* creature) const;
	Reference<server::zone::objects::creature::CreatureObject*> getOnlineBot(const String& firstName) const;
	void getOnlineBots(Vector<Reference<server::zone::objects::creature::CreatureObject*>>& out) const;
	void getBotList(Vector<Reference<BotListEntry*>>& out) const;

	// The oids of the players online with a client (never a bot), for the crew's group cap
	void getOnlineHumans(Vector<uint64>& out) const;

	// --- Own crews (Phase 9, Part 1; see BotCrews.h) ---

	// Hires a bot at runtime: checks the entry (the roster's checks, a free name, one bot per role, seven at most per
	// owner), adds it to the manager and the crews file, and makes its account and character in a task. Returns false
	// with the reason when it can't. Safe from any thread (no blocking work)
	bool hire(BotEntry* entry, String& reason);

	// Lets an own-crew bot go: out of every list at once, logged out and its character deleted in a task. The roster's
	// own bots can't be let go. Returns false with the reason when it can't
	bool letGo(uint64 oid, String& reason);

	// Part 2: an own-crew bot trained a box. Its entry takes the new skills, outfit, carry, weapon and camp kit (saved with the crews),
	// and, if it is online, the gear is put on in a task. Returns false for a roster bot or one that is gone
	bool updateGear(uint64 oid, const BotEntry& fresh);

	// A squad leader bot trained a box: the group's squad leader modifiers are rebuilt from its skills (Core3 only does it for the leader).
	// A task takes the group's lock; false for a bot that isn't online and in a group
	bool refreshSquadAura(uint64 oid);

	// A bot's entry by first name (any bot that hasn't been let go), or null
	Reference<BotEntry*> getEntry(const String& firstName) const;

	// The owner of an own-crew bot, 0 for any other
	uint64 getOwner(uint64 botOid) const;

	// An owner's crew, in hire order (a bot whose character is still being made has oid 0 and online false)
	void getCrewOf(uint64 owner, Vector<Reference<BotListEntry*>>& out) const;

	// Is a first name free of every bot, character and reserved name? On false, `reason` says why
	bool nameFree(const String& firstName, String& reason) const;

	// Lua and console controls
	bool forceState(const String& firstName, bool online);
	void setDevHuman(bool on);
	bool isDevHuman() const;

	// From PlayerObjectImplementation::getNewSuiBoxID: a game window is being made for `playerOid`. A bot closes it
	// shortly after, without answering, like a client closing the window
	void onSuiBoxCreated(uint64 playerOid, uint32 boxID);

private:
	bool countHumans() const;
	bool ownerOnline(uint64 owner, const SortedVector<uint64>& online) const;	// pre: stateMutex locked
	bool ownerWants(uint64 owner, const SortedVector<uint64>& online);			// pre: stateMutex locked
	void requestSave();															// pre: stateMutex locked; the write runs in a task
	void writeCrews();															// copies under the lock, writes outside it
	void deleteCharacter(uint64 oid, const String& firstName);					// a task, no locks held
	void removeUnmade(BotRuntime* bot);
	void finishLetGo(Reference<BotRuntime*> runtime, int step);
	void notePlanets();				// pre: stateMutex locked
	bool planetOccupied(const String& planet) const;	// pre: stateMutex locked
	void updateRule();
	void scheduleLogin(BotRuntime* bot);
	void scheduleLogout(BotRuntime* bot, bool fromShutdown);
	void checkOnlineBot(BotRuntime* bot);

	// Run in tasks with the bot locked
	bool loginBot(server::zone::objects::creature::CreatureObject* creature, BotEntry* entry);
	void sceneReady(server::zone::objects::creature::CreatureObject* creature);
	void logoutBot(server::zone::objects::creature::CreatureObject* creature, bool callLua);

	void setState(uint64 oid, int state);
	BotRuntime* findByOid(uint64 oid) const;
	BotRuntime* findByFirstName(const String& firstName) const;
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTMANAGER_H_ */
