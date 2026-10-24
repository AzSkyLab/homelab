/*
 * BotVehicle: a swoop for a crew bot (Phase 7, ~/github/swgemu/specs/2026-10-24-crew-swoops-missions/).
 *
 * A crew bot owns a real swoop: a vehicle control device in its datapad with a speederbike_swoop in it, made the way
 * a speederbike_swoop_deed makes one (VehicleDeed: device, vehicle, 1500 hit points). Calling it is the control
 * device's own spawnObject, mounting and dismounting are Core3's own `mount` / `dismount` commands, and storing is
 * the device's storeObject. The 15 s wait for calling a vehicle outside a city is skipped: the crew mounts when the
 * leader does. Nothing here opens a window (a bot has no client).
 *
 * The bindings hand the work to the bot's own task (as BotChat does) and don't wait for it: Lua asks, then reads
 * botMounted / botVehicleOut on a later tick. A swoop that is disabled (destroyed) is replaced by a new one at the
 * next mount. BotMover moves a mounted bot and its swoop together.
 */

#ifndef BOTVEHICLE_H_
#define BOTVEHICLE_H_

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

class BotVehicle {
public:
	// Make sure the bot has a swoop in its datapad, call it beside the bot and mount it. Only outdoors, upright, not
	// in combat, not dead or incapacitated, not already riding. False if it can't even be tried; true means it was
	// queued (the result shows in botMounted a moment later, and in the log)
	static bool mount(server::zone::objects::creature::CreatureObject* bot);

	// Get off (if riding) and store the swoop. Storing waits for the end of a fight, as it does for a player: the
	// swoop stays standing, and botVehicleOut stays true, until a later call stores it. True if queued
	static bool dismount(server::zone::objects::creature::CreatureObject* bot);

	// Riding a mount or vehicle. Reads without locking
	static bool isMounted(server::zone::objects::creature::CreatureObject* bot);

	// A creature attacking the bot's vehicle: its oid, else 0. Creatures attack a rider's swoop (a vehicle is a target of
	// its own), and the rider itself is not "in combat" while they do. Reads without locking
	static uint64 mountAttacker(server::zone::objects::creature::CreatureObject* bot);

	// One of the bot's swoops stands in the world. Reads without locking
	static bool isOut(server::zone::objects::creature::CreatureObject* bot);

	// The bot has a swoop in its datapad (called or stored). Reads without locking
	static bool hasSwoop(server::zone::objects::creature::CreatureObject* bot);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTVEHICLE_H_ */
