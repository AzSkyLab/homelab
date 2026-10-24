/*
 * BotVehicle (bot players, Phase 7). See BotVehicle.h.
 */

#include "BotVehicle.h"
#include "BotManager.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/creature/VehicleObject.h"
#include "server/zone/objects/intangible/VehicleControlDevice.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/player/sessions/TradeSession.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "templates/params/creature/CreaturePosture.h"

namespace {

const char* SWOOP_DEVICE = "object/intangible/vehicle/speederbike_swoop_pcd.iff";
const char* SWOOP = "object/mobile/vehicle/speederbike_swoop.iff";
const int SWOOP_HIT_POINTS = 1500;	// a deed rolls 1000-2500
const float MOUNT_RANGE = 7.f;		// MountCommand's own

Logger& vehicleLog() {
	static Logger logger("BotVehicle");
	static bool init = [] {
		logger.setGlobalLogging(true);
		logger.setLogging(true);
		return true;
	}();

	(void)init;

	return logger;
}

bool isSwoop(SceneObject* object) {
	return object != nullptr && object->getServerObjectCRC() == String(SWOOP).hashCode();
}

// The control device of a swoop in the bot's datapad, or nullptr. Reads without locking
VehicleControlDevice* findSwoopDevice(CreatureObject* bot) {
	SceneObject* datapad = bot->getSlottedObject("datapad");

	if (datapad == nullptr)
		return nullptr;

	for (int i = 0; i < datapad->getContainerObjectsSize(); ++i) {
		SceneObject* object = datapad->getContainerObject(i);

		if (object == nullptr || !object->isVehicleControlDevice())
			continue;

		VehicleControlDevice* device = cast<VehicleControlDevice*>(object);
		ManagedReference<TangibleObject*> vehicle = device->getControlledObject();

		if (isSwoop(vehicle.get()))
			return device;
	}

	return nullptr;
}

// Wipes a device and its vehicle (a disabled swoop, or a device whose vehicle is gone). pre: bot locked
void discard(CreatureObject* bot, VehicleControlDevice* device) {
	Locker locker(device, bot);

	ManagedReference<TangibleObject*> vehicle = device->getControlledObject();

	// The device's own destroy dismounts a rider and takes the vehicle with it
	device->destroyObjectFromWorld(true);
	device->destroyObjectFromDatabase(true);

	if (vehicle != nullptr && vehicle->isInQuadTree()) {
		Locker vlocker(vehicle, bot);

		vehicle->destroyObjectFromWorld(true);
	}
}

// A swoop in the datapad, the way VehicleDeed::handleObjectMenuSelect makes one. pre: bot locked
VehicleControlDevice* makeSwoop(CreatureObject* bot) {
	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* datapad = bot->getSlottedObject("datapad");

	if (zoneServer == nullptr || datapad == nullptr)
		return nullptr;

	// A device whose vehicle is gone, or a destroyed (disabled) swoop, is replaced; the player's limit is 3 vehicles
	for (int i = datapad->getContainerObjectsSize() - 1; i >= 0; --i) {
		SceneObject* object = datapad->getContainerObject(i);

		if (object == nullptr || !object->isVehicleControlDevice())
			continue;

		VehicleControlDevice* old = cast<VehicleControlDevice*>(object);
		ManagedReference<TangibleObject*> vehicle = old->getControlledObject();

		if (vehicle == nullptr || (isSwoop(vehicle.get()) && vehicle->isDisabled())) {
			vehicleLog().info(true) << "BotVehicle: " << bot->getFirstName() << "'s swoop is " << (vehicle == nullptr ? "gone" : "destroyed")
				<< ", making a new one";
			discard(bot, old);
		}
	}

	Reference<VehicleControlDevice*> device = zoneServer->createObject(String(SWOOP_DEVICE).hashCode(), 1).castTo<VehicleControlDevice*>();

	if (device == nullptr) {
		vehicleLog().error() << "BotVehicle: no control device template " << SWOOP_DEVICE;
		return nullptr;
	}

	Locker dlocker(device);

	Reference<VehicleObject*> vehicle = zoneServer->createObject(String(SWOOP).hashCode(), 1).castTo<VehicleObject*>();

	if (vehicle == nullptr) {
		device->destroyObjectFromDatabase(true);
		vehicleLog().error() << "BotVehicle: no vehicle template " << SWOOP;
		return nullptr;
	}

	Locker vlocker(vehicle, bot);

	vehicle->createChildObjects();
	vehicle->setMaxCondition(SWOOP_HIT_POINTS);
	vehicle->setConditionDamage(0);
	device->setControlledObject(vehicle);

	if (!datapad->transferObject(device, -1)) {
		device->destroyObjectFromDatabase(true);
		vehicle->destroyObjectFromDatabase(true);
		vehicleLog().error() << "BotVehicle: no room in " << bot->getFirstName() << "'s datapad for a swoop";
		return nullptr;
	}

	vehicleLog().info(true) << "BotVehicle: " << bot->getFirstName() << " has a new swoop (device " << device->getObjectID() << ")";

	return device;
}

// Calls the swoop beside the bot, as VehicleControlDevice::generateObject does but without its wait outside a city.
// pre: bot locked. Returns the standing vehicle, or nullptr
Reference<VehicleObject*> callSwoop(CreatureObject* bot, VehicleControlDevice* device) {
	ManagedReference<TangibleObject*> controlled = device->getControlledObject();

	if (controlled == nullptr)
		return nullptr;

	// Left standing by a fight, or called already: use it when it is here, else store it and call again
	if (controlled->isInQuadTree() || controlled->getLocalZone() != nullptr) {
		CreatureObject* standing = controlled->asCreatureObject();

		if (standing != nullptr && standing->getParent().get() == nullptr && standing->isInRange(bot, MOUNT_RANGE) && CollisionManager::checkLineOfSight(standing, bot))
			return controlled.castTo<VehicleObject*>();

		device->storeObject(bot, true);

		if (controlled->isInQuadTree())
			return nullptr;
	}

	ManagedReference<TradeSession*> trade = bot->getActiveSession(SessionFacadeType::TRADE).castTo<TradeSession*>();

	if (trade != nullptr) {
		PlayerManager* playerManager = bot->getZoneServer()->getPlayerManager();

		if (playerManager != nullptr)
			playerManager->handleAbortTradeMessage(bot);
	}

	Locker dlocker(device, bot);
	Locker vlocker(controlled, bot);

	device->spawnObject(bot);

	if (!controlled->isInQuadTree())
		return nullptr;

	return controlled.castTo<VehicleObject*>();
}

// pre: bot locked
void doMount(CreatureObject* bot) {
	String name = bot->getFirstName();

	if (!BotManager::instance()->isOnlineBot(bot) || bot->getZone() == nullptr || bot->isRidingMount())
		return;

	if (bot->isDead() || bot->isIncapacitated() || bot->isInCombat() || bot->getParent().get() != nullptr
			|| bot->getPosture() != CreaturePosture::UPRIGHT) {
		vehicleLog().info(true) << "BotVehicle: " << name << " can't mount now (indoors, in combat, down or not upright)";
		return;
	}

	VehicleControlDevice* device = findSwoopDevice(bot);

	if (device != nullptr) {
		ManagedReference<TangibleObject*> vehicle = device->getControlledObject();

		if (vehicle != nullptr && vehicle->isDisabled())
			device = nullptr;	// destroyed: a new one
	}

	Reference<VehicleControlDevice*> keep = device != nullptr ? device : makeSwoop(bot);

	if (keep == nullptr)
		return;

	Reference<VehicleObject*> vehicle = callSwoop(bot, keep);

	if (vehicle == nullptr) {
		vehicleLog().info(true) << "BotVehicle: " << name << " couldn't call its swoop";
		return;
	}

	// Core3's own mount: range, line of sight, outdoors, the vehicle's owner, the rider's state
	bot->executeObjectControllerAction(STRING_HASHCODE("mount"), vehicle->getObjectID(), "");

	if (bot->isRidingMount()) {
		vehicleLog().info(true) << "BotVehicle: " << name << " mounted its swoop (" << vehicle->getObjectID() << ", run speed "
			<< bot->getRunSpeed() << ")";
	} else {
		vehicleLog().info(true) << "BotVehicle: " << name << " couldn't mount its swoop, storing it";
		keep->storeObject(bot, true);
	}
}

// pre: bot locked
void doDismount(CreatureObject* bot, bool force) {
	String name = bot->getFirstName();

	if (bot->isRidingMount()) {
		bot->updateCooldownTimer("mount_dismount", 0);
		bot->executeObjectControllerAction(STRING_HASHCODE("dismount"));

		if (bot->isRidingMount()) {
			vehicleLog().info(true) << "BotVehicle: " << name << " couldn't get off";
			return;
		}

		vehicleLog().info(true) << "BotVehicle: " << name << " got off its swoop";
	}

	// Stored the player's way (not while in a fight; the swoop stays out until a later call), or at once when forced
	// (leaving the group: nobody would store it later)
	VehicleControlDevice* device = findSwoopDevice(bot);

	if (device == nullptr)
		return;

	ManagedReference<TangibleObject*> vehicle = device->getControlledObject();

	if (vehicle == nullptr || !vehicle->isInQuadTree())
		return;

	Reference<VehicleControlDevice*> keep = device;

	keep->storeObject(bot, force);

	if (!vehicle->isInQuadTree())
		vehicleLog().info(true) << "BotVehicle: " << name << " stored its swoop";
}

// Runs `work` on the bot with its lock: now when the caller holds it, else in the bot's own task
template<typename F>
bool onBot(CreatureObject* bot, const char* taskName, F work) {
	if (!BotManager::instance()->isOnlineBot(bot))
		return false;

	if (bot->isLockedByCurrentThread()) {
		work(bot);
		return true;
	}

	Reference<CreatureObject*> ref = bot;

	bot->executeOrderedTask([ref, work]() {
		Locker locker(ref);

		work(ref.get());
	}, taskName);

	return true;
}

}

bool BotVehicle::mount(CreatureObject* bot) {
	if (bot == nullptr || bot->isRidingMount())
		return false;

	return onBot(bot, "BotMount", [](CreatureObject* b) {
		try {
			doMount(b);
		} catch (Exception& e) {
			vehicleLog().error() << "BotVehicle: exception mounting " << b->getFirstName() << ": " << e.getMessage();
		}
	});
}

bool BotVehicle::dismount(CreatureObject* bot, bool force) {
	if (bot == nullptr)
		return false;

	return onBot(bot, "BotDismount", [force](CreatureObject* b) {
		try {
			doDismount(b, force);
		} catch (Exception& e) {
			vehicleLog().error() << "BotVehicle: exception dismounting " << b->getFirstName() << ": " << e.getMessage();
		}
	});
}

bool BotVehicle::isMounted(CreatureObject* bot) {
	return bot != nullptr && bot->isRidingMount();
}

uint64 BotVehicle::mountAttacker(CreatureObject* bot) {
	if (bot == nullptr || !bot->isRidingMount())
		return 0;

	ManagedReference<SceneObject*> parent = bot->getParent().get();

	if (parent == nullptr || !parent->isCreatureObject())
		return 0;

	CreatureObject* vehicle = parent->asCreatureObject();

	if (!vehicle->isInCombat())
		return 0;

	ManagedReference<SceneObject*> defender = vehicle->getMainDefender();

	return defender != nullptr ? defender->getObjectID() : 0;
}

bool BotVehicle::isOut(CreatureObject* bot) {
	if (bot == nullptr)
		return false;

	VehicleControlDevice* device = findSwoopDevice(bot);

	if (device == nullptr)
		return false;

	ManagedReference<TangibleObject*> vehicle = device->getControlledObject();

	return vehicle != nullptr && vehicle->isInQuadTree();
}

bool BotVehicle::hasSwoop(CreatureObject* bot) {
	return bot != nullptr && findSwoopDevice(bot) != nullptr;
}
