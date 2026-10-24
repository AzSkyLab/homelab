/*
 * BotGroup (Phase 5 bot players). See BotGroup.h.
 */

#include "BotGroup.h"
#include "BotManager.h"
#include "BotLua.h"
#include "server/ServerCore.h"
#include "server/zone/Zone.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/creature/ai/AiAgent.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/group/GroupObject.h"
#include "server/zone/objects/structure/StructureObject.h"
#include "server/zone/objects/area/CampSiteActiveArea.h"
#include "server/zone/objects/region/CityRegion.h"
#include "server/zone/objects/tangible/threat/ThreatMap.h"
#include "server/zone/managers/planet/PlanetManager.h"
#include "server/zone/managers/structure/StructureManager.h"
#include "server/zone/packets/object/Emote.h"
#include "templates/manager/TemplateManager.h"
#include "templates/tangible/CampKitTemplate.h"
#include "templates/building/CampStructureTemplate.h"
#include "templates/params/creature/CreaturePosture.h"
#include "conf/ConfigManager.h"

namespace {

Logger& groupLog() {
	static Logger logger("BotGroup");

	return logger;
}

// The ranger's master camp kit, when the jobs don't name one
const char* DEFAULT_CAMP_KIT = "object/tangible/scout/camp/camp_luxury.iff";

// The area track's examine animation
const int TRACK_EMOTE = 72;

// The last invite each online bot was told about: inviter and Core3's invite counter
class InviteSeen : public Object {
public:
	uint64 inviter = 0;
	uint64 counter = 0;
};

Mutex inviteMutex;
VectorMap<uint64, Reference<InviteSeen*>> invites;

// A human speaker. Core3.BotManager.DevHearBots (config, off by default) lets bots count, to test without a client
bool isHuman(CreatureObject* creature) {
	static const bool devHearBots = ConfigManager::instance()->getBool("Core3.BotManager.DevHearBots", false);

	return creature != nullptr && creature->isPlayerCreature() && (devHearBots || !BotManager::instance()->isBot(creature));
}

const char* compassName(float degrees) {
	static const char* names[] = {"north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"};

	int sector = ((int) floor((degrees + 22.5f) / 45.f)) % 8;

	return names[sector < 0 ? sector + 8 : sector];
}

ManagedReference<StructureObject*> findCamp(CreatureObject* bot) {
	PlayerObject* ghost = bot->getPlayerObject();
	ZoneServer* zoneServer = bot->getZoneServer();

	if (ghost == nullptr || zoneServer == nullptr)
		return nullptr;

	for (int i = 0; i < ghost->getTotalOwnedStructureCount(); ++i) {
		ManagedReference<StructureObject*> structure = zoneServer->getObject(ghost->getOwnedStructure(i)).castTo<StructureObject*>();

		if (structure != nullptr && structure->isCampStructure())
			return structure;
	}

	return nullptr;
}

}

// --- Group chat ---

void BotGroup::onGroupChat(CreatureObject* sender, const UnicodeString& text) {
	if (!isHuman(sender) || text.length() == 0)
		return;

	ManagedReference<GroupObject*> group = sender->getGroup();

	if (group == nullptr)
		return;

	Reference<CreatureObject*> speaker = sender;
	String message = text.toString();

	// The members, read with the group locked, in a task of its own (the hooks run with the sender locked)
	Core::getTaskManager()->executeTask([group, speaker, message]() {
		Vector<Reference<CreatureObject*>> bots;

		{
			Locker locker(group);

			for (int i = 0; i < group->getGroupSize(); ++i) {
				Reference<CreatureObject*> member = group->getGroupMember(i);

				if (member != nullptr && member.get() != speaker.get() && BotManager::instance()->isOnlineBot(member))
					bots.add(member);
			}
		}

		for (int i = 0; i < bots.size(); ++i) {
			Reference<CreatureObject*> bot = bots.get(i);

			// Ordered per bot, like the spatial chat and tells it hears (BotChat)
			bot->executeOrderedTask([bot, speaker, message]() {
				Locker locker(bot);

				if (!BotManager::instance()->isOnlineBot(bot))
					return;

				groupLog().info(true) << bot->getFirstName() << " hears group chat from " << speaker->getFirstName();

				BotLua::callJobsHeard(bot, speaker, message, "group");
			}, "BotHeardGroup");
		}
	}, "BotGroupChat");
}

// --- Invites ---

void BotGroup::poll(const Vector<Reference<CreatureObject*>>& bots) {
	for (int i = 0; i < bots.size(); ++i) {
		CreatureObject* bot = bots.get(i);
		uint64 oid = bot->getObjectID();
		uint64 inviter = bot->getGroupInviterID();
		uint64 counter = bot->getGroupInviteCounter();
		bool fresh = false;

		{
			Locker locker(&inviteMutex);

			int pos = invites.find(oid);
			Reference<InviteSeen*> seen;

			if (pos == -1) {
				seen = new InviteSeen();
				invites.put(oid, seen);
			} else {
				seen = invites.elementAt(pos).getValue();
			}

			fresh = inviter != 0 && (inviter != seen->inviter || counter != seen->counter);
			seen->inviter = inviter;
			seen->counter = counter;
		}

		if (!fresh)
			continue;

		Reference<CreatureObject*> ref = bot;

		bot->executeOrderedTask([ref, inviter]() {
			Locker locker(ref);

			if (!BotManager::instance()->isOnlineBot(ref) || ref->getGroupInviterID() != inviter)
				return;

			ZoneServer* zoneServer = ref->getZoneServer();
			ManagedReference<SceneObject*> from = zoneServer != nullptr ? zoneServer->getObject(inviter) : nullptr;

			groupLog().info(true) << ref->getFirstName() << ": group invite from " << (from != nullptr ? from->getDisplayedName() : String::valueOf(inviter));

			BotLua::callEvent(ref, "groupInvite", from, "");
		}, "BotGroupInvite");
	}
}

uint64 BotGroup::getInviter(CreatureObject* bot) {
	return bot != nullptr ? bot->getGroupInviterID() : 0;
}

// --- The ranger's camp ---

uint64 BotGroup::getCamp(CreatureObject* bot) {
	if (bot == nullptr)
		return 0;

	ManagedReference<StructureObject*> camp = findCamp(bot);

	return camp != nullptr ? camp->getObjectID() : 0;
}

uint64 BotGroup::placeCamp(CreatureObject* bot, const String& kitTemplate, String& error, uint64* blocker) {
	if (bot == nullptr)
		return 0;

	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();
	Zone* zone = bot->getZone();
	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (zoneServer == nullptr || zone == nullptr || inventory == nullptr) {
		error = "not in the world";
		return 0;
	}

	uint64 existing = getCamp(bot);

	if (existing != 0) {
		error = "already camping";
		return existing;
	}

	String kitName = kitTemplate.isEmpty() ? String(DEFAULT_CAMP_KIT) : kitTemplate;
	uint32 kitCrc = kitName.hashCode();
	CampKitTemplate* kitData = dynamic_cast<CampKitTemplate*>(TemplateManager::instance()->getTemplate(kitCrc));
	CampStructureTemplate* campData = kitData != nullptr
		? dynamic_cast<CampStructureTemplate*>(TemplateManager::instance()->getTemplate(kitData->getSpawnObjectTemplate().hashCode())) : nullptr;

	if (campData == nullptr) {
		error = "not a camp kit";
		return 0;
	}

	// The kit's own checks report only to a client: the common ones first, with reasons the jobs can say
	if (bot->getSkillMod("camp") < campData->getSkillRequired()) {
		error = "skill";
		return 0;
	}

	if (bot->isInCombat()) {
		error = "in combat";
		return 0;
	}

	ManagedReference<SceneObject*> parent = bot->getParent().get();

	if (parent != nullptr && parent->isCellObject()) {
		error = "inside";
		return 0;
	}

	if (bot->getCityRegion().get() != nullptr) {
		error = "in a city";
		return 0;
	}

	PlanetManager* planetManager = zone->getPlanetManager();

	if (planetManager != nullptr && !planetManager->isCampingPermittedAt(bot->getPositionX(), bot->getPositionY(), campData->getRadius())) {
		error = "no camping here";
		return 0;
	}

	if (bot->isSwimming() || bot->isInWater()) {
		error = "in water";
		return 0;
	}

	if (bot->getCurrentCamp() != nullptr) {
		error = "in another camp";
		return 0;
	}

	// The kit's scan for what is too close (it tells only a client): buildings within 100 m, camps and lairs by their radii
	{
		SortedVector<ManagedReference<TreeEntry*>> nearby;
		zone->getInRangeObjects(bot->getPositionX(), bot->getPositionZ(), bot->getPositionY(), 512, &nearby, true, false);

		for (int i = 0; i < nearby.size(); ++i) {
			SceneObject* object = static_cast<SceneObject*>(nearby.get(i).get());

			if (object == nullptr || object == bot)
				continue;

			float distance = object->getDistanceTo(bot);

			if (object->isCampStructure() && distance <= object->getObjectTemplate()->getNoBuildRadius() + campData->getRadius()) {
				error = "camp too close";

				if (blocker != nullptr)
					*blocker = object->getObjectID();

				return 0;
			}

			if (!object->isCampStructure() && object->isStructureObject() && distance <= 100) {
				error = "building too close";

				if (blocker != nullptr)
					*blocker = object->getObjectID();

				return 0;
			}

			if (distance <= object->getObjectTemplate()->getNoBuildRadius() + campData->getRadius()
					&& (object->getObserverCount(ObserverEventType::OBJECTDESTRUCTION) > 0 || object->getObserverCount(ObserverEventType::CREATUREDESPAWNED) > 0)) {
				// A lair has one of these two observers; the kit looks for the lair type among them
				SortedVector<ManagedReference<Observer*>> observers = object->getObservers(ObserverEventType::OBJECTDESTRUCTION);
				observers.addAll(object->getObservers(ObserverEventType::CREATUREDESPAWNED));

				for (int j = 0; j < observers.size(); ++j) {
					if (observers.get(j)->isObserverType(ObserverType::LAIR)) {
						error = "lair too close";

						if (blocker != nullptr)
							*blocker = object->getObjectID();

						return 0;
					}
				}
			}
		}
	}

	if (!bot->isStanding())
		bot->setPosture(CreaturePosture::UPRIGHT, true);

	// The kit: one of this template in the inventory, or a new one
	ManagedReference<SceneObject*> kit;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->getServerObjectCRC() == kitCrc) {
			kit = object;
			break;
		}
	}

	if (kit == nullptr) {
		kit = zoneServer->createObject(kitCrc, 1);

		if (kit == nullptr || !kit->isCampKit()) {
			if (kit != nullptr)
				kit->destroyObjectFromDatabase(true);

			error = "not a camp kit";
			return 0;
		}

		Locker klocker(kit, bot);

		if (!inventory->transferObject(kit, -1, true)) {
			kit->destroyObjectFromDatabase(true);
			error = "inventory full";
			return 0;
		}
	}

	{
		// What the kit's "use" radial runs
		Locker klocker(kit, bot);

		kit->handleObjectMenuSelect(bot, 20);
	}

	uint64 camp = getCamp(bot);

	if (camp == 0) {
		error = "not placed (too close to a building, camp or lair, or in water)";
		return 0;
	}

	Vector3 position = bot->getWorldPosition();

	groupLog().info(true) << bot->getFirstName() << " placed a camp (" << kitName << ", oid " << camp << ") on " << zone->getZoneName()
		<< " at " << (int) position.getX() << " " << (int) position.getY();

	return camp;
}

bool BotGroup::removeCamp(CreatureObject* bot) {
	if (bot == nullptr)
		return false;

	Locker locker(bot);

	ManagedReference<StructureObject*> camp = findCamp(bot);

	if (camp == nullptr || camp->getZone() == nullptr)
		return false;

	// As the camp terminal's "disband"
	ManagedReference<CampSiteActiveArea*> campArea;
	SortedVector<ManagedReference<ActiveArea*>>* areas = camp->getActiveAreas();

	for (int i = 0; i < areas->size(); ++i) {
		ManagedReference<ActiveArea*> area = areas->get(i);

		if (area != nullptr && area->isCampArea()) {
			campArea = area.castTo<CampSiteActiveArea*>();
			break;
		}
	}

	groupLog().info(true) << bot->getFirstName() << " disbands its camp " << camp->getObjectID();

	if (campArea != nullptr && campArea->despawnCamp())
		return true;

	StructureManager::instance()->destroyStructure(camp);

	if (campArea != nullptr) {
		campArea->destroyObjectFromWorld(true);
		campArea->destroyObjectFromDatabase(true);
	}

	return true;
}

// --- Tracking ---

void BotGroup::attackers(CreatureObject* creature, Vector<uint64>& out) {
	if (creature == nullptr)
		return;

	ThreatMap* threatMap = creature->getThreatMap();

	if (threatMap == nullptr)
		return;

	VectorMap<float, uint64> sorted;
	sorted.setAllowDuplicateInsertPlan();

	for (int i = 0; i < threatMap->size(); ++i) {
		TangibleObject* attacker = threatMap->elementAt(i).getKey().get();

		if (attacker == nullptr || !attacker->isAiAgent())
			continue;

		AiAgent* agent = attacker->asAiAgent();

		if (agent == nullptr || agent->isDead() || agent->isIncapacitated() || agent->isPet() || agent->getZone() == nullptr)
			continue;

		// Still fighting it: a creature that gave up or lost the thread has it no more as a defender
		if (!agent->isInCombat() || !agent->hasDefender(creature))
			continue;

		sorted.put(creature->getDistanceTo(agent), agent->getObjectID());
	}

	for (int i = 0; i < sorted.size(); ++i)
		out.add(sorted.elementAt(i).getValue());
}

void BotGroup::peopleNear(SceneObject* center, float range, Vector<Reference<BotTrackEntry*>>& out) {
	if (center == nullptr || range <= 0)
		return;

	Zone* zone = center->getZone();

	if (zone == nullptr)
		return;

	Vector3 at = center->getWorldPosition();

	SortedVector<ManagedReference<TreeEntry*>> objects(256, 256);
	zone->getInRangeObjects(at.getX(), at.getZ(), at.getY(), range, &objects, true);

	for (int i = 0; i < objects.size() && out.size() < 64; ++i) {
		SceneObject* object = static_cast<SceneObject*>(objects.get(i).get());

		if (object == nullptr || object == center || !object->isCreatureObject())
			continue;

		CreatureObject* creature = object->asCreatureObject();

		if (creature == nullptr || creature->isInvisible() || creature->isDead())
			continue;

		bool player = creature->isPlayerCreature();

		if (!player && (creature->isCreature() || !creature->isNonPlayerCreatureObject()))
			continue;

		Reference<BotTrackEntry*> entry = new BotTrackEntry();
		entry->name = creature->getDisplayedName();
		entry->oid = creature->getObjectID();
		entry->kind = player ? "player" : "npc";
		out.add(entry);
	}
}

bool BotGroup::track(CreatureObject* bot, int type, Vector<Reference<BotTrackEntry*>>& out, String& error) {
	if (bot == nullptr)
		return false;

	Locker locker(bot);

	Zone* zone = bot->getZone();

	if (zone == nullptr) {
		error = "not in the world";
		return false;
	}

	// AreatrackCommand and AreaTrackTask's rules
	if (!bot->hasSkill("outdoors_ranger_novice")) {
		error = "skill";
		return false;
	}

	ManagedReference<SceneObject*> parent = bot->getParent().get();

	if (parent != nullptr && parent->isCellObject()) {
		error = "inside";
		return false;
	}

	if (bot->isInCombat()) {
		error = "in combat";
		return false;
	}

	int maxType = bot->hasSkill("outdoors_ranger_harvest_04") ? 2 : bot->hasSkill("outdoors_ranger_harvest_02") ? 1 : 0;

	if (type < 0 || type > maxType) {
		error = "skill";
		return false;
	}

	bool canGetDirection = bot->hasSkill("outdoors_ranger_harvest_01");
	bool canGetDistance = bot->hasSkill("outdoors_ranger_harvest_03");

	// The examine animation, as the area track plays
	uint64 oid = bot->getObjectID();
	bot->broadcastMessage(new Emote(oid, oid, 0, TRACK_EMOTE, true, false), true);

	Vector3 from = bot->getWorldPosition();

	SortedVector<ManagedReference<TreeEntry*>> objects(512, 512);
	zone->getInRangeObjects(bot->getPositionX(), bot->getPositionZ(), bot->getPositionY(), TRACK_RANGE, &objects, true);

	VectorMap<int, Reference<BotTrackEntry*>> found;	// by distance
	found.setAllowDuplicateInsertPlan();

	for (int i = 0; i < objects.size(); ++i) {
		SceneObject* object = static_cast<SceneObject*>(objects.get(i).get());

		if (object == nullptr || object == bot || !object->isCreatureObject())
			continue;

		CreatureObject* creature = object->asCreatureObject();

		if (creature == nullptr || creature->isInvisible())
			continue;

		const char* kind = nullptr;

		if (type == 0) {
			if (!creature->isCreature() || creature->isDroidSpecies() || creature->isWalkerSpecies())
				continue;

			kind = "animal";
		} else if (type == 1) {
			if (!creature->isNonPlayerCreatureObject() || creature->isVendor() || creature->isProbotSpecies())
				continue;

			kind = "npc";
		} else {
			if (!creature->isPlayerCreature())
				continue;

			kind = "player";
		}

		Vector3 to = creature->getWorldPosition();
		float dx = to.getX() - from.getX();
		float dy = to.getY() - from.getY();
		float degrees = atan2(dx, dy) * 180.f / M_PI;

		if (degrees < 0)
			degrees += 360.f;

		Reference<BotTrackEntry*> entry = new BotTrackEntry();
		entry->name = creature->getDisplayedName();
		entry->oid = creature->getObjectID();
		entry->kind = kind;
		entry->level = creature->getLevel();

		int distance = (int) bot->getDistanceTo(creature);

		if (canGetDistance)
			entry->distance = distance;

		if (canGetDirection) {
			entry->bearing = compassName(degrees);
			entry->degrees = (int) degrees;
		}

		found.put(distance, entry);
	}

	for (int i = 0; i < found.size() && i < TRACK_MAX; ++i)
		out.add(found.elementAt(i).getValue());

	groupLog().info(true) << bot->getFirstName() << " tracked " << found.size() << " " << (type == 0 ? "animals" : type == 1 ? "NPCs" : "players")
		<< " within " << TRACK_RANGE << " m";

	return true;
}

// --- Fairness ---

bool BotGroup::isBotPlayer(SceneObject* object) {
	return object != nullptr && object->isPlayerCreature() && BotManager::instance()->isBotOid(object->getObjectID());
}

bool BotGroup::skipReward(SceneObject* object, const char* reward) {
	if (!isBotPlayer(object))
		return false;

	static const bool devLog = ConfigManager::instance()->getBool("Core3.BotManager.DevLogRewards", false);

	if (devLog)
		groupLog().info(true) << "fairness: " << object->getDisplayedName() << " left out of " << reward;

	return true;
}

uint32 BotGroup::getRewardDamage(ThreatMap* threatMap, uint32 totalDamage) {
	if (threatMap == nullptr)
		return totalDamage;

	uint32 botDamage = 0;

	for (int i = 0; i < threatMap->size(); ++i) {
		TangibleObject* attacker = threatMap->elementAt(i).getKey();

		if (isBotPlayer(attacker))
			botDamage += threatMap->elementAt(i).getValue().getTotalDamage();
	}

	// Humans who did no damage get nothing either way; keep the divisor
	if (botDamage == 0 || botDamage >= totalDamage)
		return totalDamage;

	static const bool devLog = ConfigManager::instance()->getBool("Core3.BotManager.DevLogRewards", false);

	if (devLog)
		groupLog().info(true) << "fairness: XP shares divide " << (totalDamage - botDamage) << " of " << totalDamage << " damage (bots did " << botDamage << ")";

	return totalDamage - botDamage;
}
