/*
 * BotGroup: bot players in groups (Phase 5, ~/github/swgemu/specs/2026-10-23-bot-group-mates/).
 *
 * - Invites: a human's /invite sets the bot's group inviter. The watcher (BotTrade's task) tells the jobs,
 *   BotJobs:onEvent(pBot, "groupInvite", pInviter, ""); the jobs answer with botEnqueue(pBot, "join"/"decline", ...).
 * - Group chat from a human reaches the bots in its group as BotJobs:onHeard(pBot, pSpeaker, text, "group"). The
 *   hooks are in ChatManagerImplementation::handleGroupChat and handleChatRoomMessage (patches/0003).
 * - The ranger: a real camp from a camp kit (Core3's CampKitMenuComponent, as the kit's "use" radial runs it), and
 *   tracking, the area track's own scan (its results go only to a client window).
 * - Squad leader (patches/0009): a bot squad leader calls the squad leader commands in a group a human leads, and gives
 *   the aura.
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
namespace group {
class GroupObject;
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

// A creature's group as the crew's Lua reads it (Phase 8): lock-free, through the group's @dirty getters, so that asking after
// another creature from a bot's event never locks that creature (LuaCreatureObject::getGroupSize does, then the group)
class BotGroupInfo : public Object {
public:
	uint64 id = 0;
	uint64 leader = 0;
	Vector<uint64> members;		// in group order, the leader first
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

	// Would a camp from kitTemplate take at each of these points? points is x, y, x, y, ... (world coordinates, on the bot's
	// planet); reasons gets one entry per point: "" for clear ground, else why not ("camp too close", "building too close",
	// "lair too close", "in a city", "no camping here", "in water"). The kit's own scan (buildings within 100 m, camps and
	// lairs by their radii) read once for the whole set, plus the planet's no-camping, water and city checks. Reads only
	// (it never places anything); false for a bot that is not in a zone or a kit that isn't one
	static bool campSpots(server::zone::objects::creature::CreatureObject* bot, const String& kitTemplate, const Vector<float>& points,
		Vector<String>& reasons);

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

	// Hook (patches/0008): a mission is being rewarded, so it was completed (a mission that leaves the datapad any other
	// way was dropped, failed or expired). Remembers the last few; wasMissionDone asks. Thread-safe
	static void missionDone(uint64 missionOid);
	static bool wasMissionDone(uint64 missionOid);

	// The creature's group: false when it has none. Reads only, no creature is locked
	static bool groupInfo(server::zone::objects::creature::CreatureObject* creature, BotGroupInfo& out);

	// Squad leader (patches/0009): a bot with Novice Squad Leader in a group it doesn't lead may call the six commands
	// (steady aim, rally, volley, form up, boost morale, retreat) for it, and gives the group its aura (the passive
	// group defense, burst run and slope move) when the leader has no squad leader skills of its own. We lead, it calls.
	static bool isSquadLeaderBot(server::zone::objects::scene::SceneObject* object);
	static bool mayCallSquadLeader(server::zone::objects::creature::CreatureObject* caster, server::zone::objects::group::GroupObject* group);
	static server::zone::objects::creature::CreatureObject* squadLeaderBotIn(server::zone::objects::group::GroupObject* group);

	// True if object is a bot left out of `reward` (logged with Core3.BotManager.DevLogRewards = true)
	static bool skipReward(server::zone::objects::scene::SceneObject* object, const char* reward);

	// Phase 9 Part 2: an own-crew bot (hired at a recruiter) earns experience from kills as a player does, by its damage share;
	// the Mos Eisley crew, which is master and never trains, earns none (patch 0011)
	static bool isOwnCrewBot(server::zone::objects::scene::SceneObject* object);
	static bool skipXp(server::zone::objects::scene::SceneObject* object);
	// The own-crew squad leader bot in a group, which earns the squad leader experience the leader would (patch 0011), or null
	// The own-crew squad leader bots in the group other than its leader (who is paid by the upstream path): each earns the squad leader
	// experience a leader would
	static void trainingSquadLeadersIn(server::zone::objects::group::GroupObject* group, Vector<server::zone::objects::creature::CreatureObject*>& out);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTGROUP_H_ */
