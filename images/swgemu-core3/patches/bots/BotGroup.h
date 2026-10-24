/*
 * BotGroup: bot players in groups (Phase 5, ~/github/swgemu/specs/2026-10-23-bot-group-mates/).
 *
 * - Invites: a human's /invite sets the bot's group inviter. The watcher (BotTrade's task) tells the jobs,
 *   BotJobs:onEvent(pBot, "groupInvite", pInviter, ""); the jobs answer with botEnqueue(pBot, "join"/"decline", ...).
 * - Group chat from a human reaches the bots in its group as BotJobs:onHeard(pBot, pSpeaker, text, "group"). The
 *   hooks are in ChatManagerImplementation::handleGroupChat and handleChatRoomMessage (patches/0003).
 * - The ranger: a real camp from a camp kit (Core3's CampKitMenuComponent, as the kit's "use" radial runs it), and
 *   tracking, the area track's own scan (its results go only to a client window).
 * - Fairness (patches/0007): bots take no share of the credit split, random loot, the loot lottery or mission rewards,
 *   and their damage isn't an XP share of its own, so the humans get the XP they'd get alone, plus the group bonus.
 */

#ifndef BOTGROUP_H_
#define BOTGROUP_H_

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
namespace tangible {
namespace threat {
class ThreatMap;
}
}
}

namespace managers {
namespace bot {

// One thing the ranger's tracking found
class BotTrackEntry : public Object {
public:
	String name;
	int distance = -1;		// metres; -1 without the skill to tell
	String bearing;			// "north", "northeast", ...; "" without the skill to tell
	int degrees = 0;		// compass bearing, 0 north, 90 east
	uint64 oid = 0;
	String kind;			// "animal", "npc" or "player"
	int level = 0;
};

class BotGroup {
public:
	static const int TRACK_RANGE = 512;		// as the area track
	static const int TRACK_MAX = 50;		// nearest first

	// Hook (patches/0003): a player's group chat, after it went out. Bots in the sender's group hear it
	static void onGroupChat(server::zone::objects::creature::CreatureObject* sender, const UnicodeString& text);

	// From the watcher: a new invite to an online bot fires "groupInvite"
	static void poll(const Vector<Reference<server::zone::objects::creature::CreatureObject*>>& bots);

	static uint64 getInviter(server::zone::objects::creature::CreatureObject* bot);

	// Places a camp from kitTemplate (made in the bot's inventory if it has none), where the bot stands. Returns the
	// camp's oid (an existing camp's, with error "already camping"), or 0 and why. Locks the bot. When a camp, a
	// building or a lair is too close, blocker (if given) gets that object's oid
	static uint64 placeCamp(server::zone::objects::creature::CreatureObject* bot, const String& kitTemplate, String& error,
		uint64* blocker = nullptr);

	// Who is attacking a creature: the live creatures (never players) in its threat map that fight it, nearest
	// first. A creature that is attacked has no defender of its own until it hits back (Core3's startCombat only gives
	// the attacker one), so the main defender alone misses what attacks a bot or a player who isn't fighting back. Pre:
	// the creature is locked (a Lua event on it)
	static void attackers(server::zone::objects::creature::CreatureObject* creature, Vector<uint64>& out);

	// Disbands the bot's camp. Locks the bot
	static bool removeCamp(server::zone::objects::creature::CreatureObject* bot);

	// The bot's camp, or 0
	static uint64 getCamp(server::zone::objects::creature::CreatureObject* bot);

	// The area track: type 0 animals, 1 NPCs, 2 players (as the skills allow), nearest first. Locks the bot
	static bool track(server::zone::objects::creature::CreatureObject* bot, int type, Vector<Reference<BotTrackEntry*>>& out, String& error);

	// The players (bots included) and the people NPCs (the crowd, vendors; no animals) within range of the centre, by name:
	// who a spoken line might be for. name, oid and kind ("player" or "npc") are filled in. Reads only
	static void peopleNear(server::zone::objects::scene::SceneObject* center, float range, Vector<Reference<BotTrackEntry*>>& out);

	// Fairness (patches/0007)
	static bool isBotPlayer(server::zone::objects::scene::SceneObject* object);

	// The damage the humans' XP shares divide: the total less the bots' damage (the total if the humans did none)
	static uint32 getRewardDamage(server::zone::objects::tangible::threat::ThreatMap* threatMap, uint32 totalDamage);

	// True if object is a bot left out of `reward` (logged with Core3.BotManager.DevLogRewards = true)
	static bool skipReward(server::zone::objects::scene::SceneObject* object, const char* reward);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTGROUP_H_ */
