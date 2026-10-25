/*
 * BotCombat (Phase 5 bot group mates). See BotCombat.h.
 */

#include <atomic>

#include "BotCombat.h"
#include "BotManager.h"
#include "BotLua.h"
#include "BotChat.h"
#include "BotLoot.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/tangible/TangibleObject.h"
#include "server/zone/objects/tangible/weapon/WeaponObject.h"
#include "server/zone/objects/player/sui/SuiWindowType.h"
#include "server/zone/objects/player/sui/listbox/SuiListBox.h"
#include "server/zone/managers/sui/SuiManager.h"
#include "server/zone/managers/combat/CombatManager.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/objects/tangible/threat/ThreatMap.h"
#include "server/utils/LambdaObserver.h"
#include "server/chat/StringIdChatParameter.h"
#include "templates/params/ObserverEventType.h"
#include "templates/params/creature/CreaturePosture.h"
#include "templates/manager/TemplateManager.h"
#include "server/zone/objects/creature/ai/AiAgent.h"
#include "server/zone/objects/tangible/threat/ThreatStates.h"
#include "server/zone/objects/scene/ObserverType.h"
#include "templates/params/ObserverEventType.h"

namespace {

Logger& combatLog() {
	static Logger logger("BotCombat");

	return logger;
}

enum { ALIVE, INCAP, DEAD };

int lifeOf(CreatureObject* creature) {
	if (creature->isDead())
		return DEAD;

	if (creature->isIncapacitated())
		return INCAP;

	return ALIVE;
}

// What BotCombat knows about one bot. Guarded by stateMutex
class BotRecord : public Object {
public:
	ManagedWeakReference<CreatureObject*> creature;	// what the observer is on, while online
	ManagedReference<LambdaObserver*> observer;
	bool online = false;
	int life = ALIVE;
	ManagedWeakReference<SceneObject*> killer;		// from PLAYERKILLED, for "died"
	bool clonePending = false;
	Time cloneSince;
	SortedVector<uint64> challengers;				// duel challenges already announced
};

// A provoked fight or a duel, from the bot's side. Guarded by stateMutex
class FightRecord : public Object {
public:
	uint64 botOid = 0;
	uint64 otherOid = 0;
	bool duel = false;
	bool ending = false;
	Time started;
	ManagedWeakReference<CreatureObject*> bot;
	ManagedWeakReference<CreatureObject*> other;
	ManagedReference<LambdaObserver*> otherObserver;	// on the other side: its incap ends the fight
};

// A player's incaps (as times in seconds) within Core3's window, for its rule that the third in ten minutes kills.
// Core3's own list only drops old entries when a new incap comes, so it can't tell how many are recent
class IncapRecord : public Object {
public:
	Vector<uint32> times;
};

Mutex stateMutex;
VectorMap<uint64, Reference<BotRecord*>> records;
Vector<Reference<FightRecord*>> fights;
VectorMap<uint64, Reference<IncapRecord*>> incaps;
VectorMap<uint64, ManagedWeakReference<CreatureObject*>> watchedHumans;	// humans with humanObserver on them
ManagedReference<LambdaObserver*> humanObserver;
Time watchStarted;	// when the first tick ran: incaps before it (this boot) weren't seen

const uint32 lifeEvents[] = {ObserverEventType::POSTURECHANGED, ObserverEventType::PLAYERKILLED, ObserverEventType::CREATUREREVIVED};

class BotCombatTickTask : public Task {
public:
	BotCombatTickTask() {
		setTaskName("BotCombatTick");
	}

	void run() {
		try {
			BotCombat::tick();
		} catch (const Exception& e) {
			combatLog().error() << "tick: " << e.getMessage();
		}

		ZoneServer* zoneServer = ServerCore::getZoneServer();

		if (zoneServer != nullptr && zoneServer->isServerShuttingDown())
			return;

		reschedule(BotCombat::TICK_MS);
	}
};

BotRecord* getRecord(uint64 oid) {
	// pre: stateMutex locked
	int pos = records.find(oid);

	if (pos != -1)
		return records.elementAt(pos).getValue();

	Reference<BotRecord*> record = new BotRecord();
	records.put(oid, record);

	return record;
}

// A fight between the two that hasn't started ending (or, with ending, one still being cleaned up too)
FightRecord* findFight(uint64 botOid, uint64 otherOid, bool ending = false) {
	// pre: stateMutex locked
	for (int i = 0; i < fights.size(); ++i) {
		FightRecord* fight = fights.get(i);

		if (fight->botOid == botOid && fight->otherOid == otherOid && (ending || !fight->ending))
			return fight;
	}

	return nullptr;
}

void removeFight(FightRecord* fight) {
	Locker locker(&stateMutex);

	for (int i = fights.size() - 1; i >= 0; --i) {
		if (fights.get(i) == fight)
			fights.remove(i);
	}
}

void dropObservers(SceneObject* object, Observer* observer, const uint32* types, int count) {
	if (object == nullptr || observer == nullptr)
		return;

	for (int i = 0; i < count; ++i)
		object->dropObserver(types[i], observer);
}

// An event for the jobs, in the bot's ordered task queue with the bot locked
void fireEvent(CreatureObject* bot, const String& name, SceneObject* other, const String& detail) {
	Reference<CreatureObject*> botRef = bot;
	ManagedReference<SceneObject*> otherRef = other;
	String eventName = name;
	String eventDetail = detail;

	StringBuffer line;
	line << bot->getFirstName() << ": event " << name;

	if (!detail.isEmpty())
		line << " " << detail;

	if (other != nullptr)
		line << " (" << other->getDisplayedName() << ")";

	combatLog().info(true) << line.toString();

	bot->executeOrderedTask([botRef, otherRef, eventName, eventDetail]() {
		Locker locker(botRef);

		if (!BotManager::instance()->isOnlineBot(botRef))
			return;

		BotLua::callEvent(botRef, eventName, otherRef, eventDetail);
	}, "BotCombatEvent");
}

void noteIncap(uint64 oid) {
	Time now;
	uint32 seconds = now.getTime();

	Locker locker(&stateMutex);

	int pos = incaps.find(oid);

	if (pos == -1) {
		incaps.put(oid, new IncapRecord());
		pos = incaps.find(oid);
	}

	Vector<uint32>& times = incaps.elementAt(pos).getValue()->times;

	for (int i = times.size() - 1; i >= 0; --i) {
		if (seconds - times.get(i) >= (uint32) BotCombat::INCAP_WINDOW)
			times.remove(i);
	}

	times.add(seconds);
}

// One side of a fight stops being an enemy of the other at once (that side is locked): nothing can hit it again
// before the cleanup task runs
void dropOneSide(CreatureObject* creature, uint64 enemyOid, bool duel) {
	if (!duel) {
		creature->removePersonalEnemyFlag(enemyOid);
		return;
	}

	ZoneServer* zoneServer = creature->getZoneServer();
	PlayerObject* ghost = creature->getPlayerObject();

	if (zoneServer == nullptr || ghost == nullptr)
		return;

	ManagedReference<SceneObject*> object = zoneServer->getObject(enemyOid);
	CreatureObject* enemy = object != nullptr && object->isCreatureObject() ? object->asCreatureObject() : nullptr;

	if (enemy != nullptr && ghost->requestedDuelTo(enemy))
		ghost->removeFromDuelList(enemy);
}

void finishFight(FightRecord* fight, const String& detail) {
	ManagedReference<CreatureObject*> bot = fight->bot.get();
	ManagedReference<CreatureObject*> other = fight->other.get();

	if (bot == nullptr) {
		removeFight(fight);
		return;
	}

	Locker locker(bot);

	if (other != nullptr) {
		Locker clocker(other, bot);

		if (fight->duel) {
			PlayerObject* ghost = bot->getPlayerObject();
			PlayerObject* otherGhost = other->getPlayerObject();
			bool wasDueling = false;

			if (ghost != nullptr && ghost->requestedDuelTo(other)) {
				ghost->removeFromDuelList(other);
				wasDueling = true;
			}

			if (otherGhost != nullptr && otherGhost->requestedDuelTo(bot)) {
				otherGhost->removeFromDuelList(bot);
				wasDueling = true;
			}

			if (wasDueling) {
				StringIdChatParameter message("duel", "end_target");	// %TT has ended the duel
				message.setTT(bot->getObjectID());
				other->sendSystemMessage(message);
			}
		} else {
			bot->removePersonalEnemyFlag(other);
			other->removePersonalEnemyFlag(bot);
		}

		// Peace on both sides: each stops fighting the other, and leaves combat if nothing else is on its list
		bot->removeDefender(other);
		other->removeDefender(bot);

		if (other->getDefenderList()->size() == 0)
			other->clearCombatState(false);

		bot->sendPvpStatusTo(other);
		other->sendPvpStatusTo(bot);

		if (fight->otherObserver != nullptr) {
			const uint32 types[] = {ObserverEventType::POSTURECHANGED, ObserverEventType::PLAYERKILLED};
			dropObservers(other, fight->otherObserver, types, 2);
		}
	}

	fight->otherObserver = nullptr;

	if (bot->getTargetID() == fight->otherOid)
		bot->setTargetID(0, true);

	if (bot->getDefenderList()->size() == 0)
		bot->clearCombatState(false);

	// Kept until now, so the tick doesn't take a duel being cleaned up for a new one
	removeFight(fight);

	StringBuffer line;
	line << bot->getFirstName() << ": " << (fight->duel ? "duel" : "fight") << " with "
		<< (other != nullptr ? other->getFirstName() : String::valueOf(fight->otherOid)) << " ended: " << detail;

	if (other != nullptr) {
		bool left = fight->duel ? CombatManager::instance()->areInDuel(bot, other) : bot->hasPersonalEnemyFlag(other) || other->hasPersonalEnemyFlag(bot);
		line << (fight->duel ? ", still dueling: " : ", enemy flags left: ") << (left ? "yes" : "no");
	}

	combatLog().info(true) << line.toString();

	if (BotManager::instance()->isOnlineBot(bot))
		BotLua::callEvent(bot, "fightEnded", other, detail);
}

// Ends a fight once, in the bot's ordered task queue
void scheduleEnd(FightRecord* fight, const String& detail) {
	{
		Locker locker(&stateMutex);

		if (fight->ending)
			return;

		fight->ending = true;
	}

	ManagedReference<CreatureObject*> bot = fight->bot.get();

	if (bot == nullptr) {
		removeFight(fight);
		return;
	}

	Reference<FightRecord*> ref = fight;
	String why = detail;

	bot->executeOrderedTask([ref, why]() {
		finishFight(ref, why);
	}, "BotCombatEndFight");
}

// Every fight of this bot ends (it is down, or gone)
void endBotFights(CreatureObject* bot, const String& detail) {
	uint64 oid = bot->getObjectID();
	Vector<Reference<FightRecord*>> mine;

	{
		Locker locker(&stateMutex);

		for (int i = 0; i < fights.size(); ++i) {
			FightRecord* fight = fights.get(i);

			if (fight->botOid == oid && !fight->ending)
				mine.add(fight);
		}
	}

	bool locked = bot->isLockedByCurrentThread();

	for (int i = 0; i < mine.size(); ++i) {
		FightRecord* fight = mine.get(i);

		if (locked)
			dropOneSide(bot, fight->otherOid, fight->duel);

		scheduleEnd(fight, detail);
	}
}

// Who put the bot down: its main defender, else whoever threatens it most
SceneObject* attackerOf(CreatureObject* bot) {
	SceneObject* defender = bot->getMainDefender();

	if (defender != nullptr)
		return defender;

	ThreatMap* threatMap = bot->getThreatMap();

	return threatMap != nullptr ? threatMap->getHighestThreatAttacker() : nullptr;
}

// The bot's life: incap, death, revive, from its observer (bot locked) or the tick (not locked)
void checkLife(CreatureObject* bot, SceneObject* killer, bool fromPosture) {
	uint64 oid = bot->getObjectID();
	int life = lifeOf(bot);
	String event;
	ManagedReference<SceneObject*> other;

	// A death's posture change comes before PLAYERKILLED, which names the killer: that (or the tick) reports it
	if (fromPosture && life == DEAD)
		return;

	{
		Locker locker(&stateMutex);

		BotRecord* record = getRecord(oid);

		if (!record->online)
			return;

		if (killer != nullptr && life == DEAD && record->life != DEAD)
			record->killer = killer;

		if (life == record->life)
			return;

		int was = record->life;
		record->life = life;

		if (life == DEAD) {
			event = "died";
			other = record->killer.get();
		} else if (life == INCAP) {
			event = "incapacitated";
		} else if (was == DEAD && !record->clonePending) {
			event = "revived";
		}

		if (life != DEAD)
			record->killer = nullptr;
	}

	if (life == INCAP) {
		other = attackerOf(bot);
		noteIncap(oid);
	}

	// The event first, so the jobs hear "incapacitated" before "fightEnded" (both go through the bot's ordered queue;
	// the flags still drop at once)
	if (!event.isEmpty())
		fireEvent(bot, event, other, "");

	if (life != ALIVE)
		endBotFights(bot, "botIncap");

	if (event == "revived") {
		// The clone window a client would close
		Reference<CreatureObject*> ref = bot;

		bot->executeOrderedTask([ref]() {
			Locker locker(ref);

			PlayerObject* ghost = ref->getPlayerObject();

			if (ghost != nullptr && !ref->isDead())
				ghost->removeSuiBoxType(SuiWindowType::CLONE_REQUEST);
		}, "BotCombatCloseClone");
	}
}

ManagedReference<LambdaObserver*> makeBotObserver() {
	return new LambdaObserver(new LambdaObserverFunction([](uint32 eventType, Observable* observable, ManagedObject* arg1, uint64 arg2) -> int {
		CreatureObject* bot = dynamic_cast<CreatureObject*>(observable);

		if (bot == nullptr)
			return 0;

		SceneObject* killer = eventType == ObserverEventType::PLAYERKILLED ? dynamic_cast<SceneObject*>(arg1) : nullptr;

		checkLife(bot, killer, eventType == ObserverEventType::POSTURECHANGED);

		return 0;
	}, "BotCombatLife"));
}

// On the other side of a fight: its incap or death ends the fight
ManagedReference<LambdaObserver*> makeOtherObserver(FightRecord* fight) {
	Reference<FightRecord*> ref = fight;

	return new LambdaObserver(new LambdaObserverFunction([ref](uint32 eventType, Observable* observable, ManagedObject* arg1, uint64 arg2) -> int {
		CreatureObject* other = dynamic_cast<CreatureObject*>(observable);

		if (other == nullptr)
			return 0;

		{
			Locker locker(&stateMutex);

			if (ref->ending)
				return 1;
		}

		if (lifeOf(other) == ALIVE)
			return 0;

		if (other->isLockedByCurrentThread())
			dropOneSide(other, ref->botOid, ref->duel);

		scheduleEnd(ref, "humanIncap");

		return 1;
	}, "BotCombatFightOther"));
}

// Records a fight and watches the other side. pre: neither creature need be locked
FightRecord* addFight(CreatureObject* bot, CreatureObject* other, bool duel) {
	Reference<FightRecord*> fight = new FightRecord();
	fight->botOid = bot->getObjectID();
	fight->otherOid = other->getObjectID();
	fight->duel = duel;
	fight->started.updateToCurrentTime();
	fight->bot = bot;
	fight->other = other;
	fight->otherObserver = makeOtherObserver(fight);

	{
		Locker locker(&stateMutex);

		fights.add(fight);
	}

	other->registerObserver(ObserverEventType::POSTURECHANGED, fight->otherObserver);
	other->registerObserver(ObserverEventType::PLAYERKILLED, fight->otherObserver);

	return fight;
}

bool isGone(CreatureObject* creature) {
	PlayerObject* ghost = creature->getPlayerObject();

	return ghost == nullptr || creature->getZone() == nullptr || ghost->isOffline() || ghost->isLinkDead() || ghost->isLoggingOut();
}

// On every online human: their incaps, for recentIncaps
ManagedReference<LambdaObserver*> makeHumanObserver() {
	return new LambdaObserver(new LambdaObserverFunction([](uint32 eventType, Observable* observable, ManagedObject* arg1, uint64 arg2) -> int {
		CreatureObject* human = dynamic_cast<CreatureObject*>(observable);

		if (human != nullptr && arg2 == CreaturePosture::INCAPACITATED)
			noteIncap(human->getObjectID());

		return 0;
	}, "BotCombatHumanIncaps"));
}

// Watches the humans online now, and stops watching those who left
void watchHumans(const Vector<Reference<CreatureObject*>>& humans) {
	SortedVector<uint64> online;
	Vector<ManagedReference<CreatureObject*>> added, removed;

	for (int i = 0; i < humans.size(); ++i)
		online.put(humans.get(i)->getObjectID());

	ManagedReference<LambdaObserver*> observer;

	{
		Locker locker(&stateMutex);

		if (humanObserver == nullptr && !humans.isEmpty())
			humanObserver = makeHumanObserver();

		observer = humanObserver;

		for (int i = watchedHumans.size() - 1; i >= 0; --i) {
			if (online.contains(watchedHumans.elementAt(i).getKey()))
				continue;

			ManagedReference<CreatureObject*> creature = watchedHumans.elementAt(i).getValue().get();

			if (creature != nullptr)
				removed.add(creature);

			watchedHumans.remove(i);
		}

		for (int i = 0; i < humans.size(); ++i) {
			CreatureObject* human = humans.get(i);
			int pos = watchedHumans.find(human->getObjectID());

			if (pos != -1 && watchedHumans.elementAt(pos).getValue().get() == human)
				continue;

			if (pos != -1)
				watchedHumans.remove(pos);

			watchedHumans.put(human->getObjectID(), human);
			added.add(human);
		}
	}

	for (int i = 0; i < removed.size(); ++i)
		removed.get(i)->dropObserver(ObserverEventType::POSTURECHANGED, observer);

	for (int i = 0; i < added.size(); ++i)
		added.get(i)->registerObserver(ObserverEventType::POSTURECHANGED, observer);
}

// Online people a bot could duel: humans with a session, and the bots
void getPeople(ZoneServer* zoneServer, const Vector<Reference<CreatureObject*>>& bots, Vector<Reference<CreatureObject*>>& out) {
	for (int i = 0; i < bots.size(); ++i)
		out.add(bots.get(i));

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager == nullptr)
		return;

	Vector<uint64> online = playerManager->getOnlinePlayerList();

	for (int i = 0; i < online.size(); ++i) {
		uint64 oid = online.get(i);

		if (BotManager::instance()->isBotOid(oid))
			continue;

		ManagedReference<SceneObject*> object = zoneServer->getObject(oid);

		if (object != nullptr && object->isPlayerCreature())
			out.add(object->asCreatureObject());
	}
}

// Duel challenges to a bot, and duels that started
void scanDuels(CreatureObject* bot, const Vector<Reference<CreatureObject*>>& people) {
	PlayerObject* ghost = bot->getPlayerObject();
	Zone* zone = bot->getZone();

	if (ghost == nullptr || zone == nullptr)
		return;

	uint64 oid = bot->getObjectID();
	Vector3 position = bot->getWorldPosition();
	CombatManager* combatManager = CombatManager::instance();

	for (int i = 0; i < people.size(); ++i) {
		CreatureObject* person = people.get(i);

		if (person == bot || person->getZone() != zone)
			continue;

		PlayerObject* personGhost = person->getPlayerObject();

		if (personGhost == nullptr)
			continue;

		uint64 personOid = person->getObjectID();
		float rangeSq = (float) BotCombat::DUEL_RANGE * BotCombat::DUEL_RANGE;
		bool near = person->getWorldPosition().squaredDistanceTo(position) <= rangeSq;
		bool challenged = near && personGhost->requestedDuelTo(bot) && !ghost->requestedDuelTo(person);
		bool dueling = combatManager->areInDuel(bot, person);
		bool announce = false;
		bool started = false;

		{
			Locker locker(&stateMutex);

			BotRecord* record = getRecord(oid);

			if (challenged && !record->challengers.contains(personOid)) {
				record->challengers.put(personOid);
				announce = true;
			} else if (!challenged) {
				record->challengers.drop(personOid);
			}

			// Only the tick adds duels, so this check and addFight below can't race
			started = dueling && findFight(oid, personOid, true) == nullptr;
		}

		if (announce)
			fireEvent(bot, "duel", person, "challenged");

		if (started) {
			// If someone is already down, checkFights ends it straight away
			addFight(bot, person, true);
			fireEvent(bot, "duel", person, "started");
		}
	}
}

// End conditions the observers can't see: logouts, distance, time, flags or duels ended elsewhere, and a backstop
// for incaps
void checkFights() {
	Vector<Reference<FightRecord*>> current;

	{
		Locker locker(&stateMutex);

		for (int i = 0; i < fights.size(); ++i) {
			if (!fights.get(i)->ending)
				current.add(fights.get(i));
		}
	}

	CombatManager* combatManager = CombatManager::instance();

	for (int i = 0; i < current.size(); ++i) {
		FightRecord* fight = current.get(i);
		ManagedReference<CreatureObject*> bot = fight->bot.get();
		ManagedReference<CreatureObject*> other = fight->other.get();

		if (bot == nullptr || other == nullptr) {
			scheduleEnd(fight, "ended");
			continue;
		}

		if (lifeOf(bot) != ALIVE) {
			scheduleEnd(fight, "botIncap");
			continue;
		}

		if (lifeOf(other) != ALIVE) {
			scheduleEnd(fight, "humanIncap");
			continue;
		}

		bool ended = !BotManager::instance()->isOnlineBot(bot) || isGone(other) || bot->getZone() != other->getZone()
			|| bot->getWorldPosition().squaredDistanceTo(other->getWorldPosition()) > (float) BotCombat::FIGHT_RANGE * BotCombat::FIGHT_RANGE
			|| fight->started.miliDifference() > BotCombat::FIGHT_MAX_MS;

		if (!ended && fight->duel)
			ended = !combatManager->areInDuel(bot, other);
		else if (!ended)
			ended = !bot->hasPersonalEnemyFlag(other) || !other->hasPersonalEnemyFlag(bot);

		if (ended)
			scheduleEnd(fight, "ended");
	}
}

}

// --- The tick ---

void BotCombat::start() {
	static std::atomic<bool> started(false);

	if (started.exchange(true))
		return;

	{
		Locker locker(&stateMutex);

		watchStarted.updateToCurrentTime();
	}

	Reference<Task*> task = new BotCombatTickTask();
	task->schedule(TICK_MS * 10);
}

void BotCombat::tick() {
	ZoneServer* zoneServer = ServerCore::getZoneServer();

	if (zoneServer == nullptr || zoneServer->isServerLoading() || zoneServer->isServerShuttingDown())
		return;

	Vector<Reference<CreatureObject*>> bots;
	BotManager::instance()->getOnlineBots(bots);

	// Bots that left: their observers go, their fights end
	SortedVector<uint64> onlineOids;

	for (int i = 0; i < bots.size(); ++i)
		onlineOids.put(bots.get(i)->getObjectID());

	Vector<ManagedReference<CreatureObject*>> gone;
	Vector<ManagedReference<LambdaObserver*>> goneObservers;

	{
		Locker locker(&stateMutex);

		for (int i = 0; i < records.size(); ++i) {
			BotRecord* record = records.elementAt(i).getValue();

			if (!record->online || onlineOids.contains(records.elementAt(i).getKey()))
				continue;

			record->online = false;
			record->clonePending = false;
			record->challengers.removeAll();

			ManagedReference<CreatureObject*> creature = record->creature.get();

			if (creature != nullptr) {
				gone.add(creature);
				goneObservers.add(record->observer);
			}

			record->creature = nullptr;
		}
	}

	for (int i = 0; i < gone.size(); ++i) {
		dropObservers(gone.get(i), goneObservers.get(i), lifeEvents, 3);
		endBotFights(gone.get(i), "ended");
	}

	// Online bots: watched from their login on; the life backstop; clones that finished
	// (Creatures are never touched with stateMutex held: observers take it with their creature locked)
	for (int i = 0; i < bots.size(); ++i) {
		CreatureObject* bot = bots.get(i);
		uint64 oid = bot->getObjectID();
		int life = lifeOf(bot);
		PlayerObject* ghost = bot->getPlayerObject();
		bool settled = ghost != nullptr && life == ALIVE && !ghost->isCloning() && !ghost->isOnLoadScreen() && !ghost->isTeleporting();
		bool newlyOnline = false;
		bool cloned = false;
		bool cloneTimedOut = false;
		ManagedReference<LambdaObserver*> observer;

		{
			Locker locker(&stateMutex);

			BotRecord* record = getRecord(oid);

			newlyOnline = !record->online;
			observer = record->observer;

			if (record->clonePending && settled) {
				record->clonePending = false;
				cloned = true;
			} else if (record->clonePending && record->cloneSince.miliDifference() > CLONE_WAIT_MS) {
				record->clonePending = false;
				cloneTimedOut = true;
			}
		}

		if (newlyOnline) {
			// Watched from its login on; what it is now raises no event
			if (observer == nullptr)
				observer = makeBotObserver();

			{
				Locker locker(&stateMutex);

				BotRecord* record = getRecord(oid);
				record->observer = observer;
				record->online = true;
				record->creature = bot;
				record->life = life;
				record->killer = nullptr;
			}

			for (int j = 0; j < 3; ++j)
				bot->registerObserver(lifeEvents[j], observer);
		}

		checkLife(bot, nullptr, false);

		if (cloned)
			fireEvent(bot, "cloned", nullptr, "");
		else if (cloneTimedOut)
			combatLog().error() << bot->getFirstName() << ": cloning did not finish in " << CLONE_WAIT_MS / 1000 << " s";
	}

	// Humans' incaps, and duels
	Vector<Reference<CreatureObject*>> people;
	getPeople(zoneServer, bots, people);

	Vector<Reference<CreatureObject*>> humans;

	for (int i = bots.size(); i < people.size(); ++i)
		humans.add(people.get(i));

	watchHumans(humans);

	for (int i = 0; i < bots.size(); ++i)
		scanDuels(bots.get(i), people);

	checkFights();
}

// --- Targets and duels ---

bool BotCombat::setTarget(CreatureObject* bot, uint64 targetOid, bool engage) {
	if (!BotManager::instance()->isOnlineBot(bot))
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();

	if (zoneServer == nullptr)
		return false;

	Locker locker(bot);

	if (targetOid == 0) {
		bot->setTargetID(0, true);
		return true;
	}

	ManagedReference<SceneObject*> target = zoneServer->getObject(targetOid);

	if (target == nullptr || target == bot || target->getZone() == nullptr || target->getZone() != bot->getZone())
		return false;

	bot->setTargetID(targetOid, true);

	if (!engage || !target->isTangibleObject())
		return true;

	TangibleObject* tano = target.castTo<TangibleObject*>();

	if (tano == nullptr || !tano->isAttackableBy(bot))
		return true;

	// Combat starts with a real attack; auto-attack follows. One that's already on needs nothing
	if (!(bot->isInCombat() && bot->hasDefender(tano)))
		BotChat::enqueue(bot, "attack", targetOid, "");

	return true;
}

String BotCombat::duelState(CreatureObject* bot, CreatureObject* other) {
	if (!BotManager::instance()->isOnlineBot(bot) || other == nullptr || other == bot || !other->isPlayerCreature())
		return "none";

	PlayerObject* ghost = bot->getPlayerObject();
	PlayerObject* otherGhost = other->getPlayerObject();

	if (ghost == nullptr || otherGhost == nullptr)
		return "none";

	bool mine = ghost->requestedDuelTo(other);
	bool theirs = otherGhost->requestedDuelTo(bot);

	if (mine && theirs)
		return "dueling";

	if (mine)
		return "challenging";

	if (theirs)
		return "challenged";

	return "none";
}

// --- Provoked fights ---

int BotCombat::recentIncaps(CreatureObject* creature) {
	if (creature == nullptr || !creature->isPlayerCreature())
		return 0;

	PlayerObject* ghost = creature->getPlayerObject();
	int listed = ghost != nullptr ? ghost->getIncapacitationCounter() : 0;
	Time now;
	uint32 seconds = now.getTime();
	int seen = 0;

	{
		Locker locker(&stateMutex);

		int pos = incaps.find(creature->getObjectID());

		if (pos != -1) {
			const Vector<uint32>& times = incaps.elementAt(pos).getValue()->times;

			for (int i = 0; i < times.size(); ++i) {
				if (seconds - times.get(i) < (uint32) INCAP_WINDOW)
					++seen;
			}
		}
	}

	// Core3's list holds every recent incap (and maybe old ones, until the next incap prunes them); ours only what we
	// saw. Within the window of our start, incaps from before it are only in Core3's list
	bool sawAll = false;

	{
		Locker locker(&stateMutex);

		sawAll = watchStarted.miliDifference() >= INCAP_WINDOW * 1000;
	}

	return sawAll ? Math::min(listed, seen) : listed;
}

int BotCombat::dropDeadDefenders(CreatureObject* creature) {
	if (creature == nullptr)
		return 0;

	Locker locker(creature);

	auto* defenders = creature->getDefenderList();
	Vector<Reference<SceneObject*>> gone;

	for (int i = 0; i < defenders->size(); ++i) {
		SceneObject* defender = defenders->get(i);

		if (defender == nullptr || defender->getZone() == nullptr ||
			(defender->isCreatureObject() && defender->asCreatureObject()->isDead()))
			gone.add(defender);
	}

	for (int i = 0; i < gone.size(); ++i)
		creature->removeDefender(gone.get(i));

	// (removeDefender leaves combat with the last one; this is for a list that was left empty)
	if (gone.size() > 0 && creature->getDefenderList()->size() == 0)
		creature->clearCombatState(false);

	return gone.size();
}

bool BotCombat::startFight(CreatureObject* bot, CreatureObject* human) {
	if (!BotManager::instance()->isOnlineBot(bot) || human == nullptr || human == bot || !human->isPlayerCreature())
		return false;

	PlayerObject* humanGhost = human->getPlayerObject();
	Zone* zone = bot->getZone();

	if (humanGhost == nullptr || zone == nullptr || isGone(human) || humanGhost->isOnLoadScreen() || human->getZone() != zone)
		return false;

	if (bot->getWorldPosition().squaredDistanceTo(human->getWorldPosition()) > (float) FIGHT_RANGE * FIGHT_RANGE)
		return false;

	if (lifeOf(bot) != ALIVE || lifeOf(human) != ALIVE)
		return false;

	// The fight ends at the first incap so it can't kill: not if that incap would be the third in ten minutes
	if (recentIncaps(human) >= 2) {
		combatLog().info(true) << bot->getFirstName() << ": won't fight " << human->getFirstName() << ", incapacitated twice in ten minutes";
		return false;
	}

	uint64 botOid = bot->getObjectID();
	uint64 humanOid = human->getObjectID();

	{
		Locker locker(&stateMutex);

		for (int i = 0; i < fights.size(); ++i) {
			FightRecord* fight = fights.get(i);

			if (fight->botOid == botOid && !fight->ending)
				return fight->otherOid == humanOid && !fight->duel;
		}
	}

	Locker locker(bot);
	Locker clocker(human, bot);

	// Mutual personal enemy flags, as the Force Ranking System sets them; their own expiry is a safety net
	bot->addPersonalEnemyFlag(human, FIGHT_FLAG_MS);
	human->addPersonalEnemyFlag(bot, FIGHT_FLAG_MS);

	if (!human->isAttackableBy(bot) || !bot->isAttackableBy(human)) {
		bot->removePersonalEnemyFlag(human);
		human->removePersonalEnemyFlag(bot);

		combatLog().info(true) << bot->getFirstName() << ": can't fight " << human->getFirstName() << " here";
		return false;
	}

	addFight(bot, human, false);

	bot->setTargetID(humanOid, true);
	CombatManager::instance()->startCombat(bot, human);

	clocker.release();

	BotChat::enqueue(bot, "attack", humanOid, "");

	combatLog().info(true) << bot->getFirstName() << ": fight with " << human->getFirstName() << " started";

	return true;
}

bool BotCombat::endFight(CreatureObject* bot, CreatureObject* human) {
	if (bot == nullptr || human == nullptr)
		return false;

	Reference<FightRecord*> fight;

	{
		Locker locker(&stateMutex);

		fight = findFight(bot->getObjectID(), human->getObjectID());
	}

	if (fight == nullptr)
		return false;

	scheduleEnd(fight, "ended");

	return true;
}

// --- Death ---

bool BotCombat::clone(CreatureObject* bot) {
	if (!BotManager::instance()->isOnlineBot(bot) || !bot->isDead())
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

	if (playerManager == nullptr)
		return false;

	Locker locker(bot);

	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return false;

	ManagedReference<SuiBox*> box = ghost->getSuiBoxFromWindowType(SuiWindowType::CLONE_REQUEST);

	if (box == nullptr) {
		// Gone (a reload, say): ask again, as /activateClone does
		playerManager->sendActivateCloneRequest(bot, 0);
		box = ghost->getSuiBoxFromWindowType(SuiWindowType::CLONE_REQUEST);
	}

	if (box == nullptr || !box->isListBox()) {
		combatLog().error() << bot->getFirstName() << ": no clone window";
		return false;
	}

	SuiListBox* listBox = cast<SuiListBox*>(box.get());
	int choice = -1;

	for (int i = 0; i < listBox->getMenuSize() && choice == -1; ++i) {
		if (listBox->getMenuItemName(i) == "@base_player:revive_closest")
			choice = i;
	}

	if (choice == -1 && listBox->getMenuSize() > 0)
		choice = 0;

	if (choice == -1) {
		combatLog().error() << bot->getFirstName() << ": no cloning facility on " << (bot->getZone() != nullptr ? bot->getZone()->getZoneName() : String("no planet"));
		return false;
	}

	uint64 clonerOid = listBox->getMenuObjectID(choice);

	{
		Locker slocker(&stateMutex);

		BotRecord* record = getRecord(bot->getObjectID());
		record->clonePending = true;
		record->cloneSince.updateToCurrentTime();
	}

	// The player's answer to the window: CloningRequestSuiCallback sends it to that facility
	Vector<UnicodeString> args;
	args.add(UnicodeString(String::valueOf(choice)));

	SuiManager::instance()->handleSuiEventNotification(box->getBoxID(), bot, 0, &args);

	combatLog().info(true) << bot->getFirstName() << ": cloning at " << clonerOid;

	return true;
}

// --- Gear ---

namespace {

bool isGear(SceneObject* object) {
	return object != nullptr && (object->isWearableObject() || object->isArmorObject() || object->isWeaponObject() || object->isInstrument());
}

bool repairItem(SceneObject* object) {
	if (object == nullptr || !object->isTangibleObject())
		return false;

	TangibleObject* tano = object->asTangibleObject();

	if (tano->getConditionDamage() <= 0)
		return false;

	tano->setConditionDamage(0, true);

	return true;
}

SceneObject* findEquipped(CreatureObject* creature, uint32 crc) {
	for (int i = 0; i < creature->getSlottedObjectsSize(); ++i) {
		SceneObject* object = creature->getSlottedObject(i);

		if (object != nullptr && object->getServerObjectCRC() == crc && isGear(object))
			return object;
	}

	return nullptr;
}

}

uint64 BotCombat::equip(CreatureObject* bot, const String& templateName) {
	if (!BotManager::instance()->isOnlineBot(bot) || templateName.isEmpty())
		return 0;

	uint32 crc = templateName.hashCode();

	if (TemplateManager::instance()->getTemplate(crc) == nullptr) {
		combatLog().error() << "equip: unknown template " << templateName;
		return 0;
	}

	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (zoneServer == nullptr || inventory == nullptr)
		return 0;

	Locker locker(bot);

	bool inWorld = bot->getZone() != nullptr;

	ManagedReference<SceneObject*> item = findEquipped(bot, crc);

	if (item != nullptr) {
		Locker ilocker(item, bot);

		repairItem(item);

		return item->getObjectID();
	}

	for (int i = 0; i < inventory->getContainerObjectsSize() && item == nullptr; ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		// (a looted weapon of this template is goods, not the bot's own)
		if (object != nullptr && object->getServerObjectCRC() == crc && !BotLoot::isGood(bot, object->getObjectID()))
			item = object;
	}

	if (item == nullptr) {
		item = zoneServer->createObject(crc, 1);

		if (item == nullptr || !item->isTangibleObject()) {
			combatLog().error() << bot->getFirstName() << ": could not create " << templateName;

			if (item != nullptr)
				item->destroyObjectFromDatabase(true);

			return 0;
		}

		Locker ilocker(item, bot);

		if (!inventory->transferObject(item, -1, inWorld, true)) {
			combatLog().error() << bot->getFirstName() << ": no room for " << templateName;

			item->destroyObjectFromDatabase(true);
			return 0;
		}

		combatLog().info(true) << bot->getFirstName() << " got " << templateName;
	}

	Locker ilocker(item, bot);

	// Make room: what's in its slots goes to the inventory
	if (item->getArrangementDescriptorSize() > 0) {
		const Vector<String>* slots = item->getArrangementDescriptor(0);

		for (int i = 0; slots != nullptr && i < slots->size(); ++i) {
			ManagedReference<SceneObject*> occupant = bot->getSlottedObject(slots->get(i));

			if (occupant == nullptr || occupant == item)
				continue;

			if (!isGear(occupant)) {
				combatLog().error() << bot->getFirstName() << ": can't equip " << templateName << ", slot " << slots->get(i) << " holds " << occupant->getObjectTemplate()->getFullTemplateString();
				return 0;
			}

			Locker olocker(occupant, bot);

			if (!inventory->transferObject(occupant, -1, inWorld, true)) {
				combatLog().error() << bot->getFirstName() << ": no room to take off " << occupant->getDisplayedName();
				return 0;
			}
		}
	}

	String error;
	int result = bot->canAddObject(item, 4, error);

	if (result != 0) {
		combatLog().error() << bot->getFirstName() << ": can't equip " << templateName << " (" << result << " " << error << ")";
		return 0;
	}

	if (!bot->transferObject(item, 4, inWorld)) {
		combatLog().error() << bot->getFirstName() << ": equipping " << templateName << " failed";
		return 0;
	}

	if (item->isWeaponObject()) {
		// As TransferItemWeaponCommand does
		ManagedReference<WeaponObject*> weapon = item.castTo<WeaponObject*>();

		bot->setWeapon(weapon, true);
		weapon->setCertified(weapon->isCertifiedFor(bot));

		PlayerManager* playerManager = zoneServer->getPlayerManager();

		if (playerManager != nullptr)
			bot->setLevel(playerManager->calculatePlayerLevel(bot));
	}

	repairItem(item);

	combatLog().info(true) << bot->getFirstName() << " equipped " << templateName;

	return item->getObjectID();
}

int BotCombat::repairGear(CreatureObject* bot) {
	if (!BotManager::instance()->isOnlineBot(bot))
		return 0;

	Locker locker(bot);

	Vector<ManagedReference<SceneObject*>> items;

	for (int i = 0; i < bot->getSlottedObjectsSize(); ++i) {
		SceneObject* object = bot->getSlottedObject(i);

		if (isGear(object))
			items.add(object);
	}

	SceneObject* inventory = bot->getSlottedObject("inventory");

	for (int i = 0; inventory != nullptr && i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && (object->isWeaponObject() || object->isArmorObject()))
			items.add(object);
	}

	int count = 0;

	for (int i = 0; i < items.size(); ++i) {
		SceneObject* item = items.get(i);

		Locker ilocker(item, bot);

		if (repairItem(item))
			++count;
	}

	if (count > 0)
		combatLog().info(true) << bot->getFirstName() << " repaired " << count << " items";

	return count;
}

// --- Tactics (Phase 7c) ---

namespace {

// ThreatMap keeps its cooldowns and lock protected, and a taunt's lockout is the cooldown it sets for the TAUNTED
// state. Taking the member pointers through an explicit instantiation is the one place C++ lets us name them without
// changing Core3's header
template <typename Tag, typename Tag::type Member>
struct Steal {
	friend typename Tag::type steal(Tag) {
		return Member;
	}
};

struct ThreatCooldowns {
	typedef CooldownTimerMap ThreatMap::*type;
	friend type steal(ThreatCooldowns);
};

struct ThreatLock {
	typedef Mutex ThreatMap::*type;
	friend type steal(ThreatLock);
};

template struct Steal<ThreatCooldowns, &ThreatMap::cooldownTimerMap>;
template struct Steal<ThreatLock, &ThreatMap::lockMutex>;

}

bool BotCombat::weaponRange(CreatureObject* bot, BotWeaponRange& out) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot))
		return false;

	Reference<WeaponObject*> weapon = bot->getWeapon();

	if (weapon == nullptr)
		return false;

	out.ranged = weapon->isRangedWeapon();
	out.pointBlankRange = weapon->getPointBlankRange();
	out.pointBlankAccuracy = weapon->getPointBlankAccuracy();
	out.idealRange = weapon->getIdealRange();
	out.idealAccuracy = weapon->getIdealAccuracy();
	out.maxRange = weapon->getMaxRange();
	out.maxAccuracy = weapon->getMaxRangeAccuracy();

	// A weapon the bot holds (not the default fists): its template
	SceneObject* held = bot->getSlottedObject("hold_r");

	out.templateName = held != nullptr && held == weapon.get() ? held->getObjectTemplate()->getFullTemplateString() : String();

	return true;
}

bool BotCombat::threatOn(CreatureObject* bot, CreatureObject* creature, BotThreat& out) {
	if (bot == nullptr || creature == nullptr || !creature->isAiAgent())
		return false;

	AiAgent* agent = creature->asAiAgent();

	if (agent == nullptr)
		return false;

	// The bot is locked by the event this runs in (the lock is re-entrant); the creature's lock lets us read its map
	Locker locker(bot);
	Locker clocker(creature, bot);

	out.tauntable = agent->isTauntable();
	out.poisoned = creature->hasState(CreatureState::POISONED);
	out.diseased = creature->hasState(CreatureState::DISEASED);

	bool noDot = (agent->getCreatureBitmask() & ObjectFlag::NODOT) != 0;

	out.poisonImmune = noDot || creature->hasDotImmunity(CreatureState::POISONED);
	out.diseaseImmune = noDot || creature->hasDotImmunity(CreatureState::DISEASED);

	SceneObject* defender = creature->getMainDefender();

	out.target = defender != nullptr ? defender->getObjectID() : 0;

	ThreatMap* threatMap = creature->getThreatMap();

	if (threatMap == nullptr)
		return true;

	Mutex& mapLock = threatMap->*steal(ThreatLock());
	Locker mlocker(&mapLock);

	for (int i = 0; i < threatMap->size(); ++i) {
		TangibleObject* attacker = threatMap->elementAt(i).getKey().get();

		if (attacker == nullptr)
			continue;

		ThreatMapEntry& entry = threatMap->elementAt(i).getValue();
		Reference<BotThreatEntry*> info = new BotThreatEntry();

		info->oid = attacker->getObjectID();
		info->name = attacker->getDisplayedName();
		info->damage = entry.getTotalDamage();
		info->aggro = entry.getAggroMod();
		info->heal = entry.getHeal();
		info->taunted = entry.hasState(ThreatStates::TAUNTED);

		if (info->taunted) {
			out.taunted = true;
			out.tauntedBy = info->oid;
		}

		out.entries.add(info);
	}

	CooldownTimerMap& cooldowns = threatMap->*steal(ThreatCooldowns());
	const Time* lockout = cooldowns.getTime(String::valueOf((uint64) ThreatStates::TAUNTED));

	if (lockout != nullptr && !lockout->isPast()) {
		Time now;

		out.lockoutMs = (int) now.miliDifference(*lockout);
	}

	return true;
}

void BotCombat::lairsNear(CreatureObject* bot, float range, Vector<Reference<BotLairInfo*>>& out) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot))
		return;

	Zone* zone = bot->getZone();

	if (zone == nullptr)
		return;

	SortedVector<ManagedReference<TreeEntry*>> nearby;
	zone->getInRangeObjects(bot->getPositionX(), bot->getPositionZ(), bot->getPositionY(), range, &nearby, true, false);

	for (int i = 0; i < nearby.size() && out.size() < 8; ++i) {
		SceneObject* object = static_cast<SceneObject*>(nearby.get(i).get());

		if (object == nullptr || object == bot || object->isCreatureObject())
			continue;

		if (object->getObserverCount(ObserverEventType::OBJECTDESTRUCTION) == 0 && object->getObserverCount(ObserverEventType::CREATUREDESPAWNED) == 0)
			continue;

		SortedVector<ManagedReference<Observer*>> observers = object->getObservers(ObserverEventType::OBJECTDESTRUCTION);
		observers.addAll(object->getObservers(ObserverEventType::CREATUREDESPAWNED));

		for (int j = 0; j < observers.size(); ++j) {
			if (observers.get(j)->isObserverType(ObserverType::LAIR)) {
				Reference<BotLairInfo*> lair = new BotLairInfo();

				lair->oid = object->getObjectID();
				lair->x = object->getWorldPositionX();
				lair->y = object->getWorldPositionY();
				out.add(lair);
				break;
			}
		}
	}
}
