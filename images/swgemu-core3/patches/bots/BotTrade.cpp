/*
 * BotTrade (Phase 4 bot players). See BotTrade.h.
 */

#include "BotTrade.h"
#include "BotManager.h"
#include "BotLua.h"
#include "BotGroup.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/player/sessions/TradeSession.h"
#include "server/zone/objects/scene/SessionFacadeType.h"
#include "server/zone/objects/transaction/TransactionLog.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/managers/objectcontroller/ObjectController.h"
#include "server/zone/packets/trade/BeginTradeMessage.h"
#include "server/zone/packets/trade/AbortTradeMessage.h"
#include "server/chat/StringIdChatParameter.h"

namespace {

Logger& tradeLog() {
	static Logger logger("BotTrade");

	return logger;
}

enum { STAGE_NONE, STAGE_REQUESTED, STAGE_OPEN, STAGE_VERIFIED };

// What the watcher last saw of one bot's trade, and what the jobs last read. Changed only with the bot locked; the map
// itself is guarded by watchMutex
class Watched : public Object {
public:
	uint64 partner = 0;
	int stage = STAGE_NONE;
	Vector<uint64> items;
	int credits = 0;
	bool partnerAccepted = false;

	// The offer as the jobs last read it (botTradeState): verify re-checks against this
	bool seenValid = false;
	uint64 seenPartner = 0;
	Vector<uint64> seenItems;
	int seenCredits = 0;

	// An item the bot owes its owner (give-back trade, or waiting for room in the owner's inventory)
	uint64 giveItem = 0;
	uint64 giveTo = 0;

	// What the bot got in its last trade, until the jobs hand it back (botSlice): if they don't, it goes back anyway
	Vector<uint64> heldItems;
	uint64 heldFrom = 0;
	Time heldSince;

	void reset() {
		partner = 0;
		stage = STAGE_NONE;
		items.removeAll();
		credits = 0;
		partnerAccepted = false;
		seenValid = false;
		seenPartner = 0;
		seenItems.removeAll();
		seenCredits = 0;
	}
};

Mutex watchMutex;
VectorMap<uint64, Reference<Watched*>> watched;	// bot oid ->
SortedVector<uint64> devTraders;				// bots playing a human in a dev trade
bool watchStarted = false;

Reference<Watched*> getWatched(uint64 oid, bool create) {
	Locker locker(&watchMutex);

	int pos = watched.find(oid);

	if (pos != -1)
		return watched.elementAt(pos).getValue();

	if (!create)
		return nullptr;

	Reference<Watched*> entry = new Watched();
	watched.put(oid, entry);

	return entry;
}

void forget(uint64 oid) {
	Locker locker(&watchMutex);

	int pos = watched.find(oid);

	if (pos == -1)
		return;

	Watched* entry = watched.elementAt(pos).getValue();

	if (entry->giveItem == 0 && entry->heldItems.isEmpty())
		watched.drop(oid);
}

bool isDevTrader(uint64 oid) {
	Locker locker(&watchMutex);

	return devTraders.contains(oid);
}

ManagedReference<TradeSession*> getTradeSession(CreatureObject* creature) {
	return creature->getActiveSession(SessionFacadeType::TRADE).castTo<TradeSession*>();
}

PlayerManager* getPlayerManager(CreatureObject* creature) {
	ZoneServer* zoneServer = creature->getZoneServer();

	return zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;
}

// The offer in a trade session, the item oids sorted
void readOffer(TradeSession* session, Vector<uint64>& items, int& credits) {
	SortedVector<uint64> sorted;

	for (int i = 0; i < session->getTradeSize(); ++i) {
		ManagedReference<SceneObject*> item = session->getTradeItem(i);

		if (item != nullptr)
			sorted.put(item->getObjectID());
	}

	items.removeAll();

	for (int i = 0; i < sorted.size(); ++i)
		items.add(sorted.get(i));

	credits = session->getMoneyToTrade();
}

bool sameItems(const Vector<uint64>& a, const Vector<uint64>& b) {
	if (a.size() != b.size())
		return false;

	for (int i = 0; i < a.size(); ++i) {
		if (a.get(i) != b.get(i))
			return false;
	}

	return true;
}

// A human (or a dev trader) whose trade target is this bot, or 0
uint64 findRequester(CreatureObject* bot) {
	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

	if (playerManager == nullptr)
		return 0;

	uint64 botOid = bot->getObjectID();
	Vector<uint64> candidates = playerManager->getOnlinePlayerList();

	{
		Locker locker(&watchMutex);

		for (int i = 0; i < devTraders.size(); ++i)
			candidates.add(devTraders.get(i));
	}

	for (int i = 0; i < candidates.size(); ++i) {
		uint64 oid = candidates.get(i);

		if (oid == botOid)
			continue;

		ManagedReference<SceneObject*> object = zoneServer->getObject(oid);

		if (object == nullptr || !object->isPlayerCreature())
			continue;

		if (object->asCreatureObject()->getTradeTargetID() == botOid)
			return oid;
	}

	return 0;
}

// BotJobs:onEvent(pBot, "trade", pPartner, detail). Pre: bot locked
void fireEvent(CreatureObject* bot, uint64 partnerOid, const String& detail) {
	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> partner;

	if (zoneServer != nullptr && partnerOid != 0)
		partner = zoneServer->getObject(partnerOid);

	tradeLog().info(true) << bot->getFirstName() << ": trade " << detail << " (" << (partner != nullptr ? partner->getDisplayedName() : String("nobody")) << ")";

	BotLua::callEvent(bot, "trade", partner, detail);
}

// The same, in the bot's own task (after the caller's Lua returns)
void fireEventLater(CreatureObject* bot, uint64 partnerOid, const String& detail) {
	Reference<CreatureObject*> ref = bot;
	String name = detail;

	bot->executeOrderedTask([ref, partnerOid, name]() {
		Locker locker(ref);

		if (BotManager::instance()->isOnlineBot(ref))
			fireEvent(ref, partnerOid, name);
	}, "BotTradeEvent");
}

// Opens the trade both ways, as ItemDropTradeCallback does once each side targets the other. Pre: bot locked
bool openTrade(CreatureObject* bot, CreatureObject* human, String& error) {
	uint64 botOid = bot->getObjectID();
	uint64 humanOid = human->getObjectID();

	Locker clocker(human, bot);

	if (human->getTradeTargetID() != botOid) {
		error = "not requested";
		return false;
	}

	ManagedReference<TradeSession*> humanSession = getTradeSession(human);

	if (humanSession != nullptr && humanSession->getTradeTargetPlayer() != botOid) {
		error = "partner busy";
		return false;
	}

	ManagedReference<TradeSession*> botSession = getTradeSession(bot);

	if (botSession != nullptr && botSession->getTradeTargetPlayer() != humanOid) {
		error = "busy";
		return false;
	}

	bot->setTradeTargetID(humanOid);

	if (botSession == nullptr) {
		botSession = new TradeSession();
		bot->addActiveSession(SessionFacadeType::TRADE, botSession);
	} else {
		botSession->clearTradeContainer();
	}

	botSession->setTradeTargetPlayer(humanOid);

	if (humanSession == nullptr) {
		humanSession = new TradeSession();
		human->addActiveSession(SessionFacadeType::TRADE, humanSession);
	} else {
		humanSession->clearTradeContainer();
	}

	humanSession->setTradeTargetPlayer(botOid);

	// The human's client opens its trade window; the bot has none
	human->sendMessage(new BeginTradeMessage(botOid));

	return true;
}

// Straight into the owner's inventory, if it fits. Pre: bot and owner locked
bool transferToOwner(CreatureObject* bot, SceneObject* item, CreatureObject* owner, String& error) {
	ZoneServer* zoneServer = bot->getZoneServer();
	ObjectController* objectController = zoneServer != nullptr ? zoneServer->getObjectController() : nullptr;
	SceneObject* inventory = owner->getSlottedObject("inventory");

	if (objectController == nullptr || inventory == nullptr) {
		error = "no inventory";
		return false;
	}

	if (owner->getZone() == nullptr || !owner->isOnline()) {
		error = "owner offline";
		return false;
	}

	String err;

	// The same room rule as a trade (checkTradeItems)
	if (inventory->canAddObject(item, -1, err) != 0 || inventory->getContainerObjectsSize() + 1 >= inventory->getContainerVolumeLimit()) {
		error = "inventory full";
		return false;
	}

	TransactionLog trx(bot, owner, item, TrxCode::PLAYERTRADE);

	if (!objectController->transferObject(item, inventory, -1, true)) {
		trx.errorMessage() << "transferObject failed";
		error = "transfer failed";
		return false;
	}

	item->sendDestroyTo(bot);

	owner->sendSystemMessage(bot->getFirstName() + " hands " + item->getDisplayedName() + " back to you.");

	return true;
}

// A give-back trade that's open: offer the item, accept, and verify last. Pre: bot locked. Returns true when done
bool runGive(CreatureObject* bot, CreatureObject* owner, Watched* entry) {
	PlayerManager* playerManager = getPlayerManager(bot);
	ManagedReference<TradeSession*> session = getTradeSession(bot);

	if (playerManager == nullptr || session == nullptr)
		return false;

	Locker clocker(owner, bot);

	ManagedReference<TradeSession*> ownerSession = getTradeSession(owner);

	if (ownerSession == nullptr || ownerSession->getTradeTargetPlayer() != bot->getObjectID())
		return false;

	bool offered = false;

	for (int i = 0; i < session->getTradeSize(); ++i) {
		ManagedReference<SceneObject*> item = session->getTradeItem(i);

		if (item != nullptr && item->getObjectID() == entry->giveItem)
			offered = true;
	}

	if (!offered) {
		playerManager->handleAddItemToTradeWindow(bot, entry->giveItem);

		if (getTradeSession(bot) == nullptr)
			return false;	// Core3 refused the item and aborted
	}

	if (!session->getAcceptedTrade())
		playerManager->handleAcceptTransactionMessage(bot);

	// Only a hand-back (a tip is fine): if the owner offers items, it isn't verified
	if (!ownerSession->hasVerifiedTrade() || ownerSession->getTradeSize() > 0)
		return false;

	if (!playerManager->checkTradeItems(bot, owner)) {
		playerManager->handleAbortTradeMessage(bot);
		return false;
	}

	playerManager->handleVerifyTradeMessage(bot);

	return getTradeSession(bot) == nullptr;
}

class BotTradeWatchTask : public Task {
public:
	BotTradeWatchTask() {
		setTaskName("BotTradeWatch");
	}

	void run() {
		ZoneServer* zoneServer = ServerCore::getZoneServer();

		if (zoneServer != nullptr && zoneServer->isServerShuttingDown())
			return;

		try {
			BotTrade::watch();
		} catch (const Exception& e) {
			tradeLog().error() << "watch: " << e.getMessage();
		}

		reschedule(BotTrade::WATCH_MS);
	}
};

}

void BotTrade::startWatch() {
	{
		Locker locker(&watchMutex);

		if (watchStarted)
			return;

		watchStarted = true;
	}

	Reference<Task*> task = new BotTradeWatchTask();
	task->schedule(10000);
}

// --- The watcher ---

void BotTrade::watch() {
	ZoneServer* zoneServer = ServerCore::getZoneServer();

	if (zoneServer == nullptr || zoneServer->isServerLoading())
		return;

	Vector<Reference<CreatureObject*>> bots;
	BotManager::instance()->getOnlineBots(bots);

	BotGroup::poll(bots);

	if (bots.isEmpty())
		return;

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager == nullptr)
		return;

	// Who wants to trade with which bot: humans (players with a client), and bots playing one in a dev test
	Vector<uint64> candidates = playerManager->getOnlinePlayerList();

	{
		Locker locker(&watchMutex);

		for (int i = 0; i < devTraders.size(); ++i)
			candidates.add(devTraders.get(i));
	}

	VectorMap<uint64, uint64> requests;	// bot -> human
	requests.setNoDuplicateInsertPlan();

	for (int i = 0; i < candidates.size(); ++i) {
		uint64 oid = candidates.get(i);

		if (BotManager::instance()->isBotOid(oid) && !isDevTrader(oid))
			continue;

		ManagedReference<SceneObject*> object = zoneServer->getObject(oid);

		if (object == nullptr || !object->isPlayerCreature())
			continue;

		uint64 target = object->asCreatureObject()->getTradeTargetID();

		if (target != 0 && target != oid && BotManager::instance()->isBotOid(target))
			requests.put(target, oid);
	}

	for (int i = 0; i < bots.size(); ++i) {
		CreatureObject* bot = bots.get(i);
		uint64 oid = bot->getObjectID();
		uint64 requester = requests.contains(oid) ? requests.get(oid) : 0;
		bool tracked = false;

		{
			Locker locker(&watchMutex);

			int pos = watched.find(oid);

			if (pos != -1) {
				Watched* entry = watched.elementAt(pos).getValue();
				tracked = entry->stage != STAGE_NONE || entry->giveItem != 0 || !entry->heldItems.isEmpty();
			}
		}

		// A bot in a trade has a trade target (a plain field: the sessions are read in the bot's own task)
		if (requester == 0 && !tracked && bot->getTradeTargetID() == 0)
			continue;

		Reference<CreatureObject*> ref = bot;

		bot->executeOrderedTask([ref, requester]() {
			Locker locker(ref);

			if (BotManager::instance()->isOnlineBot(ref))
				check(ref, requester);
		}, "BotTradeCheck");
	}
}

void BotTrade::check(CreatureObject* bot, uint64 requester) {
	// pre: bot locked
	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

	if (playerManager == nullptr)
		return;

	uint64 oid = bot->getObjectID();
	Reference<Watched*> entry = getWatched(oid, true);

	int stage = STAGE_NONE;
	uint64 partnerOid = 0;
	Vector<uint64> items;
	int credits = 0;
	bool partnerAccepted = false;

	ManagedReference<TradeSession*> session = getTradeSession(bot);
	ManagedReference<CreatureObject*> partner;

	if (session != nullptr) {
		partnerOid = session->getTradeTargetPlayer();
		partner = zoneServer->getObject(partnerOid).castTo<CreatureObject*>();

		bool valid = false;

		if (partner != nullptr) {
			Locker plocker(partner, bot);

			ManagedReference<TradeSession*> partnerSession = getTradeSession(partner);

			if (partnerSession != nullptr && partnerSession->getTradeTargetPlayer() == oid) {
				valid = true;
				readOffer(partnerSession, items, credits);
				partnerAccepted = partnerSession->getAcceptedTrade();
				stage = partnerSession->hasVerifiedTrade() ? STAGE_VERIFIED : STAGE_OPEN;
			}
		}

		if (!valid) {
			// Half a trade: the partner dropped its side (a logout drops only its own). Close ours
			playerManager->handleAbortTradeMessage(bot);
			bot->setTradeTargetID(0);
			partnerOid = 0;
		}
	} else if (requester != 0) {
		partnerOid = requester;
		stage = STAGE_REQUESTED;
	}

	// An item the bot owes (a give-back trade is the bot's own business: no customer events for it)
	if (entry->giveItem != 0) {
		ManagedReference<CreatureObject*> owner = zoneServer->getObject(entry->giveTo).castTo<CreatureObject*>();
		ManagedReference<SceneObject*> item = zoneServer->getObject(entry->giveItem);
		SceneObject* inventory = bot->getSlottedObject("inventory");

		if (item == nullptr || inventory == nullptr || !inventory->hasObjectInContainer(entry->giveItem) || owner == nullptr) {
			tradeLog().info(true) << bot->getFirstName() << " no longer holds item " << entry->giveItem << " for " << entry->giveTo;
			entry->giveItem = 0;
			entry->giveTo = 0;
		} else if (session != nullptr && partnerOid == entry->giveTo) {
			// The give-back trade is open
			if (runGive(bot, owner, entry)) {
				tradeLog().info(true) << bot->getFirstName() << " handed " << item->getDisplayedName() << " back to " << owner->getFirstName() << " by trade";

				entry->giveItem = 0;
				entry->giveTo = 0;
				entry->reset();

				fireEvent(bot, owner->getObjectID(), "returned");
			}

			return;
		} else if (session == nullptr) {
			// Straight back, once there's room
			String error;
			bool done = false;

			{
				Locker clocker(owner, bot);

				done = transferToOwner(bot, item, owner, error);
			}

			if (done) {
				tradeLog().info(true) << bot->getFirstName() << " handed " << item->getDisplayedName() << " back to " << owner->getFirstName();

				entry->giveItem = 0;
				entry->giveTo = 0;

				fireEvent(bot, owner->getObjectID(), "returned");
			} else if (requester == entry->giveTo) {
				// The owner answered the bot's request: open the window (the item goes in at the next check)
				String openError;
				openTrade(bot, owner, openError);

				return;
			} else {
				// Keep asking the owner (another trade may have taken the bot's trade target)
				if (bot->getTradeTargetID() != entry->giveTo)
					bot->setTradeTargetID(entry->giveTo);

				if (requester == 0)
					return;
			}
		}
	}

	int previous = entry->stage;
	uint64 previousPartner = entry->partner;
	String detail;

	if (stage == STAGE_NONE) {
		if (previous != STAGE_NONE)
			detail = "aborted";
	} else if (previous == STAGE_NONE || previousPartner != partnerOid) {
		detail = stage == STAGE_REQUESTED ? "requested" : stage == STAGE_VERIFIED ? "partnerVerified" : "changed";
	} else if (stage == STAGE_VERIFIED && previous != STAGE_VERIFIED) {
		detail = "partnerVerified";
	} else if (stage != STAGE_REQUESTED && (previous == STAGE_REQUESTED || !sameItems(items, entry->items) || credits != entry->credits
			|| partnerAccepted != entry->partnerAccepted)) {
		detail = "changed";
	}

	if (stage == STAGE_NONE) {
		entry->reset();
		forget(oid);
	} else {
		entry->stage = stage;
		entry->partner = partnerOid;
		entry->items = items;
		entry->credits = credits;
		entry->partnerAccepted = partnerAccepted;
	}

	if (!detail.isEmpty())
		fireEvent(bot, stage == STAGE_NONE ? previousPartner : partnerOid, detail);
}

// --- What the jobs call ---

bool BotTrade::getState(CreatureObject* bot, BotTradeInfo& out) {
	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();

	if (zoneServer == nullptr)
		return false;

	uint64 oid = bot->getObjectID();
	Reference<Watched*> entry = getWatched(oid, true);
	ManagedReference<TradeSession*> session = getTradeSession(bot);

	if (session != nullptr) {
		uint64 partnerOid = session->getTradeTargetPlayer();
		ManagedReference<CreatureObject*> partner = zoneServer->getObject(partnerOid).castTo<CreatureObject*>();

		if (partner != nullptr) {
			Locker clocker(partner, bot);

			ManagedReference<TradeSession*> partnerSession = getTradeSession(partner);

			if (partnerSession != nullptr && partnerSession->getTradeTargetPlayer() == oid) {
				out.partner = partnerOid;
				out.stage = partnerSession->hasVerifiedTrade() ? "partnerVerified" : "open";
				readOffer(partnerSession, out.items, out.credits);
				out.partnerAccepted = partnerSession->getAcceptedTrade();
				out.accepted = session->getAcceptedTrade();
			}
		}
	} else {
		uint64 requester = findRequester(bot);

		if (requester != 0) {
			out.partner = requester;
			out.stage = "requested";
		}
	}

	if (entry->giveItem != 0 && out.partner == entry->giveTo)
		out.give = entry->giveItem;

	// What verify re-checks against
	entry->seenValid = out.stage == "open" || out.stage == "partnerVerified";
	entry->seenPartner = out.partner;
	entry->seenItems = out.items;
	entry->seenCredits = out.credits;

	return true;
}

bool BotTrade::accept(CreatureObject* bot, String& error) {
	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();

	if (zoneServer == nullptr)
		return false;

	uint64 requester = findRequester(bot);

	if (requester == 0) {
		error = "no request";
		return false;
	}

	ManagedReference<CreatureObject*> human = zoneServer->getObject(requester).castTo<CreatureObject*>();

	if (human == nullptr) {
		error = "no request";
		return false;
	}

	if (!openTrade(bot, human, error))
		return false;

	Reference<Watched*> entry = getWatched(bot->getObjectID(), true);
	entry->reset();
	entry->stage = STAGE_OPEN;
	entry->partner = requester;

	tradeLog().info(true) << bot->getFirstName() << " opened a trade with " << human->getFirstName();

	return true;
}

int BotTrade::verify(CreatureObject* bot, int minCredits, uint64 itemOid, String& why) {
	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;
	ManagedReference<TradeSession*> session = getTradeSession(bot);

	if (playerManager == nullptr || session == nullptr) {
		why = "none";
		return REFUSED;
	}

	uint64 oid = bot->getObjectID();
	uint64 partnerOid = session->getTradeTargetPlayer();
	ManagedReference<CreatureObject*> partner = zoneServer->getObject(partnerOid).castTo<CreatureObject*>();

	if (partner == nullptr) {
		why = "none";
		return REFUSED;
	}

	Reference<Watched*> entry = getWatched(oid, true);

	// Both locked from here to the transfer: the offer can't change in between
	Locker clocker(partner, bot);

	ManagedReference<TradeSession*> partnerSession = getTradeSession(partner);

	if (partnerSession == nullptr || partnerSession->getTradeTargetPlayer() != oid) {
		why = "none";
		return REFUSED;
	}

	Vector<uint64> items;
	int credits = 0;
	readOffer(partnerSession, items, credits);

	if (!entry->seenValid || entry->seenPartner != partnerOid || !sameItems(entry->seenItems, items) || entry->seenCredits != credits) {
		why = "changed";
		return REFUSED;
	}

	if (minCredits >= 0 && credits < minCredits) {
		why = "credits";
		return REFUSED;
	}

	if (itemOid != 0 && (items.size() != 1 || items.get(0) != itemOid)) {
		why = "items";
		return REFUSED;
	}

	if (!partnerSession->hasVerifiedTrade()) {
		// Accept (again, in case the human's window reset it after a change), and wait for the human to verify
		playerManager->handleAcceptTransactionMessage(bot);

		why = "waiting";
		return WAITING;
	}

	if (!session->getAcceptedTrade())
		playerManager->handleAcceptTransactionMessage(bot);

	if (!playerManager->checkTradeItems(bot, partner)) {
		// What Core3's verify would do: abort
		playerManager->handleAbortTradeMessage(bot);
		entry->reset();

		why = "failed";
		return REFUSED;
	}

	// Verify last: the human verified, so this verify moves the goods
	playerManager->handleVerifyTradeMessage(bot);

	if (getTradeSession(bot) != nullptr) {
		why = "failed";
		return REFUSED;
	}

	tradeLog().info(true) << bot->getFirstName() << " completed a trade with " << partner->getFirstName() << ": " << items.size()
		<< " item(s), " << credits << " credits";

	entry->reset();

	fireEventLater(bot, partnerOid, "done");

	why = "done";
	return DONE;
}

bool BotTrade::abort(CreatureObject* bot) {
	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerManager* playerManager = zoneServer != nullptr ? zoneServer->getPlayerManager() : nullptr;

	if (playerManager == nullptr)
		return false;

	bool done = false;
	Reference<Watched*> entry = getWatched(bot->getObjectID(), true);

	if (getTradeSession(bot) != nullptr) {
		playerManager->handleAbortTradeMessage(bot);
		done = true;
	} else {
		// Refuse a request: the human no longer targets the bot
		uint64 requester = findRequester(bot);
		ManagedReference<CreatureObject*> human = requester != 0 ? zoneServer->getObject(requester).castTo<CreatureObject*>() : nullptr;

		if (human != nullptr) {
			Locker clocker(human, bot);

			if (human->getTradeTargetID() == bot->getObjectID()) {
				human->setTradeTargetID(0);
				human->sendMessage(new AbortTradeMessage());
				done = true;
			}
		}
	}

	if (entry->giveItem == 0)
		bot->setTradeTargetID(0);

	entry->reset();

	if (done)
		tradeLog().info(true) << bot->getFirstName() << " cancelled a trade";

	return done;
}

void BotTrade::abortAtLogout(CreatureObject* bot) {
	// pre: bot locked
	if (bot == nullptr)
		return;

	PlayerManager* playerManager = getPlayerManager(bot);
	uint64 oid = bot->getObjectID();

	if (playerManager != nullptr && getTradeSession(bot) != nullptr) {
		playerManager->handleAbortTradeMessage(bot);
		tradeLog().info(true) << bot->getFirstName() << " logging out: open trade aborted";
	}

	bot->setTradeTargetID(0);

	{
		Locker locker(&watchMutex);

		devTraders.drop(oid);
	}

	Reference<Watched*> entry = getWatched(oid, false);

	if (entry == nullptr)
		return;

	entry->reset();

	if (entry->giveItem != 0) {
		ZoneServer* zoneServer = bot->getZoneServer();
		ManagedReference<SceneObject*> item = zoneServer != nullptr ? zoneServer->getObject(entry->giveItem) : nullptr;
		ManagedReference<CreatureObject*> owner = zoneServer != nullptr ? zoneServer->getObject(entry->giveTo).castTo<CreatureObject*>() : nullptr;
		String error;
		bool done = false;

		if (item != nullptr && owner != nullptr) {
			Locker clocker(owner, bot);

			done = transferToOwner(bot, item, owner, error);
		}

		if (done) {
			entry->giveItem = 0;
			entry->giveTo = 0;
		} else {
			tradeLog().error() << bot->getFirstName() << " logs out still holding item " << entry->giveItem << " for "
				<< entry->giveTo << " (" << error << "); it goes back when the bot is next online";
		}
	}

	forget(oid);
}

bool BotTrade::returnItem(CreatureObject* bot, SceneObject* item, CreatureObject* owner, String& error) {
	// pre: bot locked
	if (bot == nullptr || item == nullptr || owner == nullptr) {
		error = "no owner";
		return false;
	}

	bool done = false;

	{
		Locker clocker(owner, bot);

		done = transferToOwner(bot, item, owner, error);
	}

	if (done)
		return true;

	if (error == "inventory full" || error == "owner offline") {
		// Hold it for the owner: a give-back trade, or straight back once there's room
		give(bot, owner, item->getObjectID());
	}

	return false;
}

bool BotTrade::give(CreatureObject* bot, CreatureObject* owner, uint64 itemOid) {
	// pre: bot locked
	if (bot == nullptr || owner == nullptr || itemOid == 0)
		return false;

	Reference<Watched*> entry = getWatched(bot->getObjectID(), true);
	entry->giveItem = itemOid;
	entry->giveTo = owner->getObjectID();

	tradeLog().info(true) << bot->getFirstName() << " owes item " << itemOid << " to " << owner->getFirstName() << ": asking to trade";

	if (getTradeSession(bot) != nullptr)
		return true;	// after the current trade

	bot->setTradeTargetID(owner->getObjectID());

	if (owner->getTradeTargetID() == bot->getObjectID()) {
		String error;
		openTrade(bot, owner, error);

		return true;
	}

	// What a player's trade request tells its target
	StringIdChatParameter request("ui_trade", "requested_prose");
	request.setTU(bot->getFirstName());
	owner->sendSystemMessage(request);

	return true;
}

// --- Development: a bot plays the human ---

bool BotTrade::devRequest(CreatureObject* from, CreatureObject* to) {
	if (from == nullptr || to == nullptr || from == to)
		return false;

	{
		Locker locker(&watchMutex);

		devTraders.put(from->getObjectID());
	}

	Locker locker(from);

	// ItemDropTradeCallback's first half: the drop sets the trade target
	from->setTradeTargetID(to->getObjectID());

	tradeLog().info(true) << "dev: " << from->getFirstName() << " asks " << to->getFirstName() << " to trade";

	return true;
}

bool BotTrade::devOffer(CreatureObject* from, uint64 itemOid, int credits) {
	PlayerManager* playerManager = from != nullptr ? getPlayerManager(from) : nullptr;

	if (playerManager == nullptr)
		return false;

	Locker locker(from);

	if (getTradeSession(from) == nullptr)
		return false;

	if (itemOid != 0)
		playerManager->handleAddItemToTradeWindow(from, itemOid);

	if (credits >= 0) {
		if (from->getCashCredits() < credits)
			from->addCashCredits(credits - from->getCashCredits(), true);

		playerManager->handleGiveMoneyMessage(from, credits);
	}

	tradeLog().info(true) << "dev: " << from->getFirstName() << " offers item " << itemOid << " and " << credits << " credits";

	return true;
}

bool BotTrade::devAccept(CreatureObject* from) {
	PlayerManager* playerManager = from != nullptr ? getPlayerManager(from) : nullptr;

	if (playerManager == nullptr)
		return false;

	playerManager->handleAcceptTransactionMessage(from);

	return true;
}

bool BotTrade::devVerify(CreatureObject* from) {
	PlayerManager* playerManager = from != nullptr ? getPlayerManager(from) : nullptr;

	if (playerManager == nullptr)
		return false;

	Locker locker(from);

	playerManager->handleVerifyTradeMessage(from);

	tradeLog().info(true) << "dev: " << from->getFirstName() << " verifies" << (getTradeSession(from) == nullptr ? ": trade complete" : "");

	return true;
}

bool BotTrade::devAbort(CreatureObject* from) {
	PlayerManager* playerManager = from != nullptr ? getPlayerManager(from) : nullptr;

	if (playerManager == nullptr)
		return false;

	Locker locker(from);

	playerManager->handleAbortTradeMessage(from);
	from->setTradeTargetID(0);

	tradeLog().info(true) << "dev: " << from->getFirstName() << " cancels the trade";

	return true;
}
