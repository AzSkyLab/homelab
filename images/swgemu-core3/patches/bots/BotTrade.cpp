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
#include "server/zone/objects/scene/variables/ContainerPermissions.h"
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

// What the bot got in a trade goes back by itself if the jobs haven't handed it back this long after (ms)
const int HELD_MS = 120000;

// A handover (BotTrade::giveBundle) is dropped if the owner hasn't taken it this long after the window opened (ms),
// or the window couldn't be opened
const int BUNDLE_MS = 90000;
const float BUNDLE_RANGE = 14.f;

// One handover trade at a time to a player: the next opens this long after the last one closed (ms). The 2005 client
// doesn't show a trade request that comes in the moment another closes, so the second handover was never seen
const int BUNDLE_GAP_MS = 4000;

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

	// Phase 7: a bundle of items handed to bundleTo in one give-back trade (BotLoot's handover), independent of the
	// single-item give above. bundleOpened: the window has been opened on the owner's client
	Vector<uint64> bundle;
	uint64 bundleTo = 0;
	bool bundleOpened = false;
	Time bundleSince;

	// What the bot got in its last trade, until the jobs hand it back (botSlice): if they don't, it goes back anyway
	Vector<uint64> heldItems;
	uint64 heldFrom = 0;
	Time heldSince;
	int heldCredits = 0;	// what was paid for them, refunded if they go back unsliced

	// Items owed from before a restart (item -> owner), read back at login: handed back one at a time
	VectorMap<uint64, uint64> owed;

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

	if (entry->giveItem == 0 && entry->heldItems.isEmpty() && entry->owed.isEmpty() && entry->bundle.isEmpty())
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

	// The trade that brought it destroyed the owner's copy (PlayerManager::handleVerifyTradeMessage); the move's link
	// alone shows the client nothing, so send the item itself
	item->sendTo(owner, true);

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

Mutex bundleEndMutex;
VectorMap<uint64, uint64> bundleEnded;	// owner oid -> when a handover trade to it last closed (ms)

void noteBundleEnd(uint64 ownerOid) {
	Locker locker(&bundleEndMutex);
	Time now;

	bundleEnded.put(ownerOid, now.getMiliTime());
}

// Has the last handover trade to this owner been closed long enough?
bool ownerRested(uint64 ownerOid) {
	Locker locker(&bundleEndMutex);
	Time now;
	int pos = bundleEnded.find(ownerOid);

	return pos == -1 || now.getMiliTime() - bundleEnded.elementAt(pos).getValue() >= (uint64) BUNDLE_GAP_MS;
}

// Ends a handover without it being taken. Pre: bot locked
void endBundle(CreatureObject* bot, Watched* entry, const char* detail, const char* why) {
	uint64 ownerOid = entry->bundleTo;

	tradeLog().info(true) << bot->getFirstName() << "'s handover to " << ownerOid << " ends: " << why;

	noteBundleEnd(ownerOid);

	if (getTradeSession(bot) != nullptr) {
		PlayerManager* playerManager = getPlayerManager(bot);

		if (playerManager != nullptr)
			playerManager->handleAbortTradeMessage(bot);
	}

	if (entry->giveItem == 0)
		bot->setTradeTargetID(0);

	entry->bundle.removeAll();
	entry->bundleTo = 0;
	entry->bundleOpened = false;
	entry->reset();

	fireEvent(bot, ownerOid, detail);
}

// The bot's handover, one round of the watcher. Returns true when it was the bot's business (no customer events
// then), like a single give-back. Pre: bot locked
bool runBundle(CreatureObject* bot, Watched* entry, TradeSession* session, uint64 partnerOid) {
	ZoneServer* zoneServer = bot->getZoneServer();
	PlayerManager* playerManager = getPlayerManager(bot);
	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (zoneServer == nullptr || playerManager == nullptr || inventory == nullptr)
		return false;

	// A customer's trade is the jobs' business: the handover waits
	if (session != nullptr && partnerOid != entry->bundleTo)
		return false;

	for (int i = entry->bundle.size() - 1; i >= 0; --i) {
		if (!inventory->hasObjectInContainer(entry->bundle.get(i)))
			entry->bundle.remove(i);
	}

	ManagedReference<CreatureObject*> owner = zoneServer->getObject(entry->bundleTo).castTo<CreatureObject*>();

	if (entry->bundle.isEmpty()) {
		endBundle(bot, entry, "bundleCancelled", "nothing left to hand over");
		return true;
	}

	if (owner == nullptr || !owner->isOnline() || owner->getZone() == nullptr) {
		endBundle(bot, entry, "bundleCancelled", "the owner is gone");
		return true;
	}

	if (entry->bundleSince.miliDifference() > BUNDLE_MS) {
		endBundle(bot, entry, "bundleCancelled", "not taken in time");
		return true;
	}

	Locker clocker(owner, bot);

	if (session == nullptr) {
		if (entry->bundleOpened) {
			endBundle(bot, entry, "bundleCancelled", "the owner cancelled");
			return true;
		}

		// Wait for the owner to be near and free, then open the window on its client: the same two halves as a
		// player's drag onto the bot (ItemDropTradeCallback), done from this side
		ManagedReference<TradeSession*> ownerSession = getTradeSession(owner);

		if (ownerSession != nullptr || (owner->getTradeTargetID() != 0 && owner->getTradeTargetID() != bot->getObjectID()))
			return true;

		if (bot->getDistanceTo(owner) >= BUNDLE_RANGE)
			return true;

		// Another handover to this owner closed a moment ago: wait
		if (!ownerRested(entry->bundleTo))
			return true;

		owner->setTradeTargetID(bot->getObjectID());

		String error;

		if (!openTrade(bot, owner, error)) {
			owner->setTradeTargetID(0);
			return true;
		}

		entry->bundleOpened = true;
		entry->bundleSince.updateToCurrentTime();

		tradeLog().info(true) << bot->getFirstName() << " opens a handover trade with " << owner->getFirstName() << " (" << entry->bundle.size() << " item(s))";

		// The jobs say "trade's open" now, not when the handover was queued
		fireEvent(bot, entry->bundleTo, "bundleOpened");

		return true;
	}

	ManagedReference<TradeSession*> ownerSession = getTradeSession(owner);

	if (ownerSession == nullptr || ownerSession->getTradeTargetPlayer() != bot->getObjectID()) {
		endBundle(bot, entry, "bundleCancelled", "the owner's side is gone");
		return true;
	}

	SortedVector<uint64> offered;

	for (int i = 0; i < session->getTradeSize(); ++i) {
		ManagedReference<SceneObject*> item = session->getTradeItem(i);

		if (item != nullptr)
			offered.put(item->getObjectID());
	}

	// What Core3 would refuse (and abort the whole trade for) stays out of it, so the rest still goes over
	ZoneServer* bundleServer = bot->getZoneServer();

	for (int i = entry->bundle.size() - 1; i >= 0; --i) {
		ManagedReference<SceneObject*> item = bundleServer != nullptr ? bundleServer->getObject(entry->bundle.get(i)) : nullptr;

		if (item == nullptr || !item->isASubChildOf(bot) || !item->checkContainerPermission(bot, ContainerPermissions::MOVECONTAINER) ||
				item->isNoTrade() || item->containsNoTradeObjectRecursive()) {
			tradeLog().info(true) << bot->getFirstName() << " leaves item " << entry->bundle.get(i) << " out of the handover: it can't be traded";
			entry->bundle.remove(i);
		}
	}

	if (entry->bundle.isEmpty()) {
		endBundle(bot, entry, "bundleCancelled", "nothing in it can be traded");
		return true;
	}

	for (int i = 0; i < entry->bundle.size(); ++i) {
		if (offered.contains(entry->bundle.get(i)))
			continue;

		playerManager->handleAddItemToTradeWindow(bot, entry->bundle.get(i));

		if (getTradeSession(bot) == nullptr) {
			// Core3 refused an item and aborted
			entry->bundle.removeAll();
			endBundle(bot, entry, "bundleCancelled", "Core3 refused an item");
			return true;
		}
	}

	if (!session->getAcceptedTrade())
		playerManager->handleAcceptTransactionMessage(bot);

	// Only a hand-over: if the owner offers items or credits, it isn't verified (bots never take credits)
	if (!ownerSession->hasVerifiedTrade() || ownerSession->getTradeSize() > 0 || ownerSession->getMoneyToTrade() > 0)
		return true;

	if (!playerManager->checkTradeItems(bot, owner)) {
		endBundle(bot, entry, "bundleCancelled", "Core3's checks failed");
		return true;
	}

	playerManager->handleVerifyTradeMessage(bot);

	if (getTradeSession(bot) == nullptr) {
		tradeLog().info(true) << bot->getFirstName() << " handed " << entry->bundle.size() << " item(s) to " << owner->getFirstName() << " by trade";

		uint64 ownerOid = entry->bundleTo;

		entry->bundle.removeAll();
		entry->bundleTo = 0;
		entry->bundleOpened = false;
		entry->reset();

		noteBundleEnd(ownerOid);
		fireEvent(bot, ownerOid, "bundleDone");
	}

	return true;
}

// Hands back what the bot got in its last trade and still holds (the jobs never sliced it). Pre: bot locked
void returnHeld(CreatureObject* bot, Watched* entry, const char* why) {
	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");
	ManagedReference<CreatureObject*> owner = zoneServer != nullptr ? zoneServer->getObject(entry->heldFrom).castTo<CreatureObject*>() : nullptr;
	Vector<uint64> items = entry->heldItems;

	for (int i = 0; i < items.size(); ++i) {
		uint64 oid = items.get(i);
		ManagedReference<SceneObject*> item = zoneServer != nullptr ? zoneServer->getObject(oid) : nullptr;

		if (item == nullptr || inventory == nullptr || !inventory->hasObjectInContainer(oid) || owner == nullptr) {
			entry->heldItems.removeElement(oid);
			continue;
		}

		tradeLog().info(true) << bot->getFirstName() << " still holds " << item->getDisplayedName() << " from " << owner->getFirstName()
			<< " (" << why << "): handing it back";

		// Never sliced: the credits go back too (once)
		if (entry->heldCredits > 0) {
			Locker clocker(owner, bot);

			if (bot->getCashCredits() >= entry->heldCredits) {
				bot->subtractCashCredits(entry->heldCredits);
				owner->addCashCredits(entry->heldCredits, true);
				tradeLog().info(true) << bot->getFirstName() << " refunds " << entry->heldCredits << " credits to " << owner->getFirstName();
			}

			entry->heldCredits = 0;
		}

		String error;
		BotTrade::returnItem(bot, item, owner, error);

		if (entry->giveItem != 0)
			break;	// one give-back trade at a time; the rest wait
	}
}

// Hands back the first owed item whose owner is online (pre: bot locked). Items no longer in the inventory are dropped
void returnOwed(CreatureObject* bot, Watched* entry) {
	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");

	for (int i = entry->owed.size() - 1; i >= 0; --i) {
		uint64 itemOid = entry->owed.elementAt(i).getKey();
		uint64 ownerOid = entry->owed.elementAt(i).getValue();

		if (zoneServer == nullptr || inventory == nullptr || !inventory->hasObjectInContainer(itemOid)) {
			entry->owed.drop(itemOid);
			continue;
		}

		ManagedReference<CreatureObject*> owner = zoneServer->getObject(ownerOid).castTo<CreatureObject*>();

		if (owner == nullptr) {
			entry->owed.drop(itemOid);
			continue;
		}

		if (!owner->isOnline())
			continue;

		ManagedReference<SceneObject*> item = zoneServer->getObject(itemOid);

		if (item == nullptr) {
			entry->owed.drop(itemOid);
			continue;
		}

		tradeLog().info(true) << bot->getFirstName() << " still owes " << item->getDisplayedName() << " to " << owner->getFirstName()
			<< " from before a restart: handing it back";

		// Straight back, or a give-back trade / held for room (returnItem takes it over either way)
		entry->owed.drop(itemOid);

		String error;
		BotTrade::returnItem(bot, item, owner, error);

		return;
	}
}

// What the bot owes, as "item:owner,..." on its own character (saved with it): read back at the next login
void saveOwed(CreatureObject* bot, Watched* entry) {
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return;

	VectorMap<uint64, uint64> all = entry->owed;

	if (entry->giveItem != 0)
		all.put(entry->giveItem, entry->giveTo);

	for (int i = 0; i < entry->heldItems.size(); ++i)
		all.put(entry->heldItems.get(i), entry->heldFrom);

	if (all.isEmpty()) {
		ghost->deleteScreenPlayData("BotTrade", "owed");
		return;
	}

	StringBuffer list;

	for (int i = 0; i < all.size(); ++i)
		list << (i > 0 ? "," : "") << all.elementAt(i).getKey() << ":" << all.elementAt(i).getValue();

	ghost->setScreenPlayData("BotTrade", "owed", list.toString());
	tradeLog().info(true) << bot->getFirstName() << " logs out owing " << all.size() << " item(s): " << list.toString();
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
				tracked = entry->stage != STAGE_NONE || entry->giveItem != 0 || !entry->heldItems.isEmpty() || !entry->owed.isEmpty() || !entry->bundle.isEmpty();
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

	// A handover (BotLoot): the bot's own business too
	if (!entry->bundle.isEmpty() && runBundle(bot, entry, session, partnerOid))
		return;

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

	// The bot never keeps a customer's item: what the jobs didn't hand back in HELD_MS goes back by itself
	if (!entry->heldItems.isEmpty() && session == nullptr && entry->giveItem == 0 && entry->heldSince.miliDifference() > HELD_MS)
		returnHeld(bot, entry, "not handed back");

	// Owed from before a restart: one at a time, once nothing else is going on and the owner is online
	if (!entry->owed.isEmpty() && session == nullptr && entry->giveItem == 0 && entry->heldItems.isEmpty())
		returnOwed(bot, entry);

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

	// Held until the jobs hand it back (botSlice), or HELD_MS
	entry->heldItems = items;
	entry->heldFrom = partnerOid;
	entry->heldSince.updateToCurrentTime();
	entry->heldCredits = credits;

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
	entry->bundle.removeAll();	// the goods stay in the pack, and the jobs offer them again
	entry->bundleOpened = false;

	if (!entry->heldItems.isEmpty() && entry->giveItem == 0)
		returnHeld(bot, entry, "logging out");

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

	// Kept on the character too, so a restart doesn't lose it (an empty list clears it)
	saveOwed(bot, entry);

	forget(oid);
}

void BotTrade::restoreOwed(CreatureObject* bot) {
	// pre: bot locked
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return;

	String list = ghost->getScreenPlayData("BotTrade", "owed");

	if (list.isEmpty())
		return;

	Reference<Watched*> entry = getWatched(bot->getObjectID(), true);
	StringTokenizer pairs(list);
	pairs.setDelimeter(",");

	while (pairs.hasMoreTokens()) {
		String pair;
		pairs.getStringToken(pair);

		int colon = pair.indexOf(":");

		if (colon <= 0)
			continue;

		uint64 itemOid = UnsignedLong::valueOf(pair.subString(0, colon));
		uint64 ownerOid = UnsignedLong::valueOf(pair.subString(colon + 1));

		if (itemOid != 0 && ownerOid != 0)
			entry->owed.put(itemOid, ownerOid);
	}

	tradeLog().info(true) << bot->getFirstName() << " logs in owing " << entry->owed.size() << " item(s)";
}

bool BotTrade::returnItem(CreatureObject* bot, SceneObject* item, CreatureObject* owner, String& error) {
	// pre: bot locked
	if (bot == nullptr || item == nullptr || owner == nullptr) {
		error = "no owner";
		return false;
	}

	bool done = false;
	uint64 itemOid = item->getObjectID();
	Reference<Watched*> entry = getWatched(bot->getObjectID(), true);

	// Handed back (sliced, or refused by the jobs): no refund owed any more; returnHeld refunds before it gets here
	entry->heldCredits = 0;

	{
		Locker clocker(owner, bot);

		done = transferToOwner(bot, item, owner, error);
	}

	if (done) {
		entry->heldItems.removeElement(itemOid);
		return true;
	}

	if (error == "inventory full" || error == "owner offline") {
		if (entry->giveItem == 0 || entry->giveItem == itemOid) {
			// Hold it for the owner: a give-back trade, or straight back once there's room
			entry->heldItems.removeElement(itemOid);
			give(bot, owner, itemOid);
		} else if (!entry->heldItems.contains(itemOid)) {
			// Another give-back is under way: this one waits its turn
			entry->heldItems.add(itemOid);
			entry->heldFrom = owner->getObjectID();
		}
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

bool BotTrade::giveBundle(CreatureObject* bot, CreatureObject* owner, const Vector<uint64>& items) {
	// pre: bot locked
	if (bot == nullptr || owner == nullptr || items.isEmpty())
		return false;

	Reference<Watched*> entry = getWatched(bot->getObjectID(), true);

	if (!entry->bundle.isEmpty())
		return false;

	entry->bundle = items;
	entry->bundleTo = owner->getObjectID();
	entry->bundleOpened = false;
	entry->bundleSince.updateToCurrentTime();

	tradeLog().info(true) << bot->getFirstName() << " hands " << items.size() << " item(s) to " << owner->getFirstName() << ": opening a trade";

	return true;
}

bool BotTrade::hasBundle(CreatureObject* bot) {
	// pre: bot locked
	Reference<Watched*> entry = getWatched(bot->getObjectID(), false);

	return entry != nullptr && !entry->bundle.isEmpty();
}

void BotTrade::cancelBundle(CreatureObject* bot) {
	// pre: bot locked
	Reference<Watched*> entry = getWatched(bot->getObjectID(), false);

	if (entry == nullptr || entry->bundle.isEmpty())
		return;

	PlayerManager* playerManager = getPlayerManager(bot);
	ManagedReference<TradeSession*> session = getTradeSession(bot);

	if (playerManager != nullptr && session != nullptr && session->getTradeTargetPlayer() == entry->bundleTo) {
		playerManager->handleAbortTradeMessage(bot);
		noteBundleEnd(entry->bundleTo);
	}

	if (entry->giveItem == 0)
		bot->setTradeTargetID(0);

	entry->bundle.removeAll();
	entry->bundleTo = 0;
	entry->bundleOpened = false;
	entry->reset();

	tradeLog().info(true) << bot->getFirstName() << " drops its handover";
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

	// Why Core3 would refuse it (checkTradeItems' tests on this side's items), for the log
	ManagedReference<TradeSession*> session = getTradeSession(from);
	ManagedReference<CreatureObject*> target = session != nullptr ? from->getZoneServer()->getObject(session->getTradeTargetPlayer()).castTo<CreatureObject*>() : nullptr;

	if (session != nullptr && target != nullptr) {
		Locker clocker(target, from);
		SceneObject* targetInventory = target->getInventory();
		SceneObject* fromInventory = from->getInventory();

		for (int i = 0; i < session->getTradeSize(); ++i) {
			ManagedReference<SceneObject*> item = session->getTradeItem(i);
			String err;
			int add = targetInventory != nullptr ? targetInventory->canAddObject(item, -1, err) : -99;

			tradeLog().info(true) << "dev: offered " << item->getObjectID() << " " << item->getDisplayedName() << ": noTrade " << item->isNoTrade()
				<< ", canAdd " << add << " " << err << ", in the giver's inventory " << (fromInventory != nullptr && fromInventory->hasObjectInContainer(item->getObjectID()));
		}

		SceneObject* fromDatapad = from->getSlottedObject("datapad");
		SceneObject* targetDatapad = target->getSlottedObject("datapad");
		auto fill = [](SceneObject* c) { StringBuffer b; if (c == nullptr) b << "none"; else b << c->getContainerObjectsSize() << "/" << c->getContainerVolumeLimit(); return b.toString(); };

		tradeLog().info(true) << "dev: checkTradeItems " << playerManager->checkTradeItems(from, target) << ", the bot accepted " << getTradeSession(target)->getAcceptedTrade()
			<< "; inventories " << fill(fromInventory) << " / " << fill(targetInventory) << ", datapads " << fill(fromDatapad) << " / " << fill(targetDatapad)
			<< ", the bot's offer " << getTradeSession(target)->getTradeSize();
	}

	playerManager->handleVerifyTradeMessage(from);

	tradeLog().info(true) << "dev: " << from->getFirstName() << " verifies" << (getTradeSession(from) == nullptr ? ": trade closed (complete, or Core3 refused it: too far, no room, ...)" : "");

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
