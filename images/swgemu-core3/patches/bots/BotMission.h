/*
 * BotMission: destroy missions for the crew (Phase 7, ~/github/swgemu/specs/2026-10-24-crew-swoops-missions/).
 *
 * A bot works a general mission terminal with Core3's own code and no client or window: it asks for the list as the
 * terminal's "list missions" does (MissionManager::handleMissionListRequest: within 6 m, the list refills, a short
 * cooldown between refreshes), reads the destroy missions out of its mission bag, and accepts one with
 * MissionManager::handleMissionAccept (so the limit of two, the lair and the rewards are Core3's). Aborting is
 * handleMissionAbort.
 *
 * Waypoints: each destroy mission a grouped bot holds gets a waypoint in its group leader's datapad, named
 * "<Bot first name>: <target>", and it goes when the mission ends (done, aborted) or the bot leaves the group. The
 * waypoint carries "Crew mission #<mission oid> bot <bot oid>" as its description, so a restart finds and removes
 * what an earlier run left (the sync scans the leader's waypoints once for each bot and leader).
 *
 * Every function locks the bot (the Lua bindings run with it locked already) and, when it must, the leader.
 */

#ifndef BOTMISSION_H_
#define BOTMISSION_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace scene {
class SceneObject;
}
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

// A general mission terminal near a bot
class BotMissionTerminal : public Object {
public:
	uint64 oid = 0;
	float distance = 0;		// metres from the bot
	float x = 0, z = 0, y = 0;	// where it stands, in its cell when it has one (as botMoveTo takes)
	uint64 cell = 0;		// the cell's oid, 0 outdoors
	String planet;
};

// A mission, in the bot's mission bag (offered) or its datapad (accepted)
class BotMissionInfo : public Object {
public:
	uint64 oid = 0;
	int reward = 0;			// credits
	float x = 0, y = 0;		// the start point (the lair's), world coordinates
	String planet;
	float distance = 0;		// metres from the terminal (offered) or from the bot (accepted)
	int degrees = 0;		// compass bearing from the terminal (offered) or the bot (accepted): 0 north, 90 east
	String direction;		// "north", "northeast", ...
	String target;			// what the lair is, as the client shows it ("womp rat lair")
	int level = 0;			// the difficulty shown to the player
	bool lairUp = false;	// an accepted mission: its lair has spawned (the objective watches it)
	String lair;			// the lair template's name, e.g. "tatooine_dragonet_dragonet_neutral_medium_boss_01"
	Vector<String> creatures;	// what lives in it: its mobiles' and boss mobiles' names as the client shows them ("womp rat"), lowercase, no repeats
};

// A waypoint in a player's datapad
class BotWaypointInfo : public Object {
public:
	uint64 oid = 0;
	String name;
	float x = 0, y = 0;
	uint32 planetCRC = 0;
	String description;
	bool active = false;
};

class BotMission {
public:
	static const int LIST_RANGE = 6;		// handleMissionListRequest's range

	// The general mission terminals within range metres of the bot, nearest first
	static bool findTerminals(server::zone::objects::creature::CreatureObject* bot, float range, Vector<Reference<BotMissionTerminal*>>& out);

	// The destroy missions the terminal offers the bot, after a refresh when refresh is set (the list refills as a
	// refresh does). On failure, error says why: "terminal", "far", "wait" (the refresh cooldown: try again in a
	// moment), "refused" (Core3 didn't refill the list: banned from the city)
	static bool list(server::zone::objects::creature::CreatureObject* bot, uint64 terminalOid, bool refresh,
		Vector<Reference<BotMissionInfo*>>& out, String& error);

	// Accepts an offered mission. error: "terminal", "far", "gone" (not on offer), "full" (two already)
	static bool accept(server::zone::objects::creature::CreatureObject* bot, uint64 terminalOid, uint64 missionOid, String& error);

	// Aborts every mission the bot holds; returns how many went. error: "combat" if some could not
	static int abortAll(server::zone::objects::creature::CreatureObject* bot, String& error);

	// Every creature name that can appear in this planet's destroy-mission lairs (Core3's <planet>_destroy_missions spawn
	// group): the lairs' display names ("womp rat lair") and their creatures' names, lowercase, no repeats. Cached per
	// planet. Reads only
	static bool creatures(server::zone::objects::creature::CreatureObject* bot, Vector<String>& out);

	// The destroy missions the bot holds
	static bool current(server::zone::objects::creature::CreatureObject* bot, Vector<Reference<BotMissionInfo*>>& out);

	// Brings the waypoints in step with the missions: a grouped bot passes its leader (each destroy mission it holds
	// has a waypoint in the leader's datapad, and a finished one is gone); a bot that left the group passes none
	// (what it put in its old leader's datapad goes). The work runs in a task of its own (it locks only the leader),
	// a few moments later; returns 1 if it queued one, 0 if everything was in step already
	static int syncWaypoints(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* leader);

	// The waypoints in a creature's datapad (the leader's, to see what the sync made)
	static bool listWaypoints(server::zone::objects::creature::CreatureObject* owner, Vector<Reference<BotWaypointInfo*>>& out);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTMISSION_H_ */
