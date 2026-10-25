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
};

class BotManager : public Singleton<BotManager>, public Object, public Logger {
	ManagedReference<ZoneServer*> zoneServer;
	BotRosterList roster;
	BotSettings settings;

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

	Reference<Task*> tickTask;

public:
	static const int TICK_MS = 2000;
	static const int RETRY_MS = 5 * 60 * 1000;	// after a failed login
	static const int SUI_CLOSE_MS = 1500;		// a client closes a window about this fast
	static const int SCENE_READY_MS = 1000;		// a client takes about this long on the load screen

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

	// Lua and console controls
	bool forceState(const String& firstName, bool online);
	void setDevHuman(bool on);
	bool isDevHuman() const;

	// From PlayerObjectImplementation::getNewSuiBoxID: a game window is being made for `playerOid`. A bot closes it
	// shortly after, without answering, like a client closing the window
	void onSuiBoxCreated(uint64 playerOid, uint32 boxID);

private:
	bool countHumans() const;
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
