/*
 * BotTrade: trading with bot players (Phase 4, ~/github/swgemu/specs/2026-10-23-musicians-smugglers/).
 *
 * A human starts a trade by dragging an item onto a bot (ItemDropTradeCallback sets the human's trade target). A
 * watcher task notices that every WATCH_MS and tells the jobs, BotJobs:onEvent(pBot, "trade", pHuman, detail):
 * - "requested": the human asked to trade (botTradeAccept opens the window, botTradeAbort refuses);
 * - "changed": the human's offer (items, credits) or its accept changed;
 * - "partnerVerified": the human verified; the bot may now verify last (botTradeVerify), which completes the trade;
 * - "done": the trade completed (after botTradeVerify returned true);
 * - "aborted": the human cancelled, walked away or logged out;
 * - "returned": a give-back trade (an item the bot owed the human, see give) completed.
 * The bot verifies last and re-checks the offer against what the jobs last read (getState) in the same locked step
 * as the transfer: Core3 moves the goods on the second verify, and a change to the offer doesn't reset a verify.
 * An open trade is aborted when the bot logs out (BotManager::logoutBot).
 */

#ifndef BOTTRADE_H_
#define BOTTRADE_H_

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

// What botTradeState returns
class BotTradeInfo : public Object {
public:
	uint64 partner = 0;			// the human, 0 for none
	String stage = "none";		// "none", "requested", "open" or "partnerVerified"
	Vector<uint64> items;		// what the human offers (oids)
	int credits = 0;			// the credits the human offers
	bool partnerAccepted = false;
	bool accepted = false;		// the bot accepted
	uint64 give = 0;			// a give-back trade: the item the bot is handing back, else 0
};

class BotTrade {
public:
	static const int WATCH_MS = 1000;

	// Verify results
	enum { DONE, WAITING, REFUSED };

	// Starts the watcher (trades and group invites) once; any thread
	static void startWatch();

	// The bot's trade. Also remembers the offer as what the jobs saw, for verify's re-check. Locks the bot
	static bool getState(server::zone::objects::creature::CreatureObject* bot, BotTradeInfo& out);

	// Opens the trade window a human asked for (mirrors ItemDropTradeCallback from the bot's side). Locks the bot
	static bool accept(server::zone::objects::creature::CreatureObject* bot, String& error);

	// Accepts, and if the human has verified, verifies last, completing the trade. Refused if the offer differs from
	// the last getState, or if credits < minCredits (when >= 0), or if itemOid is set and isn't the one item offered.
	// why: "done", "waiting" (accepted; the human hasn't verified), "none", "changed", "credits", "items", "failed"
	// (Core3's own checks failed, e.g. a full inventory or more than 15 m apart: the trade is aborted). Locks the bot
	static int verify(server::zone::objects::creature::CreatureObject* bot, int minCredits, uint64 itemOid, String& why);

	// Cancels the bot's trade or refuses a request. No "aborted" event: the jobs asked for it. Locks the bot
	static bool abort(server::zone::objects::creature::CreatureObject* bot);

	// From BotManager::logoutBot (bot locked): aborts an open trade, and hands back an owed item if it can
	static void abortAtLogout(server::zone::objects::creature::CreatureObject* bot);

	// From BotManager's login (bot locked): reads back what it owed at its last logout, to hand back
	static void restoreOwed(server::zone::objects::creature::CreatureObject* bot);

	// Hand an item in the bot's inventory to its owner: straight into the owner's inventory if there's room, else
	// through a give-back trade (the bot asks the owner to trade, offers the item and verifies once the owner has).
	// Pre: bot locked. Returns true if the item went straight in (returned), false if a trade was started or the
	// item can't be handed back (error says which: "inventory full", "owner offline", ...)
	static bool returnItem(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::scene::SceneObject* item,
			server::zone::objects::creature::CreatureObject* owner, String& error);

	// Starts a give-back trade of itemOid to owner. Pre: bot locked
	static bool give(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* owner, uint64 itemOid);

	// Development: another bot plays the human's side through PlayerManager's own trade handlers
	static bool devRequest(server::zone::objects::creature::CreatureObject* from, server::zone::objects::creature::CreatureObject* to);
	static bool devOffer(server::zone::objects::creature::CreatureObject* from, uint64 itemOid, int credits);
	static bool devAccept(server::zone::objects::creature::CreatureObject* from);
	static bool devVerify(server::zone::objects::creature::CreatureObject* from);
	static bool devAbort(server::zone::objects::creature::CreatureObject* from);

	// The watcher's work (BotTradeWatchTask)
	static void watch();

private:
	static void check(server::zone::objects::creature::CreatureObject* bot, uint64 requester);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTTRADE_H_ */
