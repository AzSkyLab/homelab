/*
 * BotMover: walking for bot players (Phase 5, ~/github/swgemu/specs/2026-10-23-bot-group-mates/).
 *
 * A bot has no client to send DataTransform packets, so the mover moves it the way the server handles a client's
 * movement: one task per moving bot, every 300-400 ms, holding only the bot's lock. Each step sets the position (the
 * world floor outdoors, the cell's floor mesh indoors), the direction and the speed, updates the locomotion, increments
 * the movement counter, updates the zone with packets (updateZone outdoors, updateZoneWithParent in a cell, which is
 * also how it goes through a doorway) and the ghost's validated position. Stopping sends a full transform. A bot never
 * moves while it is sitting or lying down, performing, incapacitated or dead, on the load screen or teleporting.
 *
 * - Following walks the leader's own trail, a ring of breadcrumbs (its positions and cells), so it goes through doors
 *   and between buildings with no pathfinding. It keeps followNear-followFar metres behind (the distance and a little
 *   side offset outdoors are fixed per bot), runs when the leader runs or it is more than 8 m behind, checks a
 *   building's entry permission before stepping into a cell, and copies a jump in the trail (an elevator) with a
 *   teleport. More than 80 m behind, or stuck for 5 s, it appears about 10 m behind the leader on its trail.
 * - A leap (the leader changes planet, takes a shuttle, or is teleported far): if the bot was within 64 m, it follows
 *   2-6 s after the leader's load screen ends (switchZone to another planet, a teleport on the same one), as if it took
 *   the same flight. BotManager's watchdog makes it scene-ready.
 * - The leader logs out or goes link-dead: the bot waits 180 s, then stops and the jobs hear "leaderGone".
 * - Going to a point uses PathFinderManager::findPath once (within one building, outdoors, or in and out of one); across
 *   two buildings it goes out by the first one's exit and in by the second one's entrance. Done: "arrived". Given up
 *   (a door it may not enter, no way on): "stuck".
 * - Moved by someone else (a teleport, cloning): the trail is dropped; a follower more than 64 m from its leader
 *   waits until the leader is back within 64 m or Lua calls botFollow again.
 *
 * Followers read the leader without locking it, as AiAgent reads what it follows. The bindings never lock the bot:
 * they hand the order to the bot's task, which applies it on its next step.
 */

#ifndef BOTMOVER_H_
#define BOTMOVER_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

// What botMoveState returns
class BotMoveStatus {
public:
	String state = "idle";	// "idle", "follow", "goto" or "zoning"
	uint64 leader = 0;		// the leader's oid while following
	float distance = 0;		// to the leader (-1 when it isn't on the bot's planet or is away), or what's left of the way
	bool stuck = false;		// can't go on: a door it may not enter, no trail, or it lost the leader
};

class BotMover {
public:
	enum { PACE_AUTO, PACE_WALK, PACE_RUN };

	static const int STEP_MIN_MS = 300;			// a client sends a transform about this often while moving
	static const int STEP_RANDOM_MS = 100;
	static const int WAIT_MS = 500;				// on the load screen, or waiting for a leader
	static const int LEADER_GONE_MS = 180000;	// Core3's LinkDeadDelay
	static const int STUCK_MS = 5000;			// following: no progress this long, catch up
	static const int GOTO_STUCK_MS = 10000;		// going to a point: no progress this long, give up
	static const int LEAP_DELAY_MIN_MS = 2000;	// after the leader's load screen
	static const int LEAP_DELAY_MAX_MS = 6000;

	// Follow `leader` (a player, a bot or any creature), keeping between nearDist and farDist metres behind. Replaces
	// any other order. False for an offline bot, a missing leader or the bot itself
	static bool follow(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* leader,
			float nearDist, float farDist);

	// Stop walking (a full transform goes out if it was moving). False if it wasn't an online bot
	static bool stop(server::zone::objects::creature::CreatureObject* bot);

	// Walk to x, z, y: world coordinates with cellOid 0, else coordinates in that cell (the building's frame). z 0
	// outdoors means the floor there. pace PACE_AUTO walks a short way and runs a long one (over 30 m). False if there
	// is no way there (the path is worked out here, once)
	static bool moveTo(server::zone::objects::creature::CreatureObject* bot, float x, float z, float y, uint64 cellOid, int pace);

	// For botMoveState. False if `bot` isn't an online bot
	static bool getStatus(server::zone::objects::creature::CreatureObject* bot, BotMoveStatus& out);

	// Development (BotMoverDev in BotMoverLua): walk these points in a loop, as a sequence of moveTo legs.
	// Each point is x, z, y with its cell oid in `cells`
	static bool patrol(server::zone::objects::creature::CreatureObject* bot, const Vector<Vector3>& points, const Vector<uint64>& cells, int pace);

	// One line for the log: the order, the state, the movement counter, where it is
	static String describe(server::zone::objects::creature::CreatureObject* bot);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTMOVER_H_ */
