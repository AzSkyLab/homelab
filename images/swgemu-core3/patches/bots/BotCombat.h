/*
 * BotCombat: bot players in a fight (Phase 5 bot group mates, ~/github/swgemu/specs/2026-10-23-bot-group-mates/;
 * the contract is the bot-players interfaces.md, "Phases 4-6: additions").
 *
 * - Targets: setTarget sets the bot's target and, when the bot may attack it, queues a real attack. From then on the
 *   player auto-attack in PlayerObject::doRecovery keeps hitting it while the bot is in combat.
 * - Duels are the real ones (/duel both ways). A duel with a bot ends at the first incap of either side.
 * - Provoked fights: startFight sets mutual personal enemy flags (as the Force Ranking System does) and starts combat.
 *   The fight ends itself at the first incap of either side, so the bot never death-blows: the flags clear and both
 *   sides make peace. Duels end the same way.
 * - Life: the bot's posture and death are watched (observers, and the tick as a backstop), and cloning answers the
 *   clone window, which BotManager leaves open for bots.
 * - Gear: equip (create if missing, equip, repair) and repairGear.
 * - Tactics (Phase 7c crew tactics, ~/github/swgemu/specs/2026-10-24-crew-tactics/): weaponRange (the held weapon's
 *   ranges and their accuracies) and threatOn (who a creature is on, its taunt state and lockout), read from Core3's
 *   own data so the crew's Lua doesn't guess.
 *
 * Events, through BotLua::callEvent in the bot's ordered task queue with the bot locked:
 *   "incapacitated"  pOther = the bot's main defender (or nil)
 *   "died"           pOther = the killer (or nil)
 *   "revived"        a dead bot stood up without cloning (a revive pack)
 *   "cloned"         after clone(): at the cloning facility, scene-ready and standing
 *   "duel"           detail "challenged" (pOther challenged the bot; accept with botEnqueue(pBot, "duel", oid, "")) or
 *                    "started" (the duel is on)
 *   "fightEnded"     pOther = the other side; detail "humanIncap", "botIncap" or "ended" (botEndFight, a logout, too
 *                    far apart, too long, /endduel). Also for duels
 *
 * A tick task (TICK_MS) runs from the first Lua state's registration on: it watches the online bots, scans for duel
 * challenges and ends fights. Its cost is a handful of checks per online bot.
 */

#ifndef BOTCOMBAT_H_
#define BOTCOMBAT_H_

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

// A weapon's ranges (metres) and the accuracy modifiers Core3 gives at them (CombatManager::getWeaponRangeModifier)
class BotWeaponRange {
public:
	String templateName;		// the held weapon's template; empty when unarmed
	bool ranged = false;
	int pointBlankRange = 0;
	int pointBlankAccuracy = 0;
	int idealRange = 0;
	int idealAccuracy = 0;
	int maxRange = 0;
	int maxAccuracy = 0;
};

// One attacker on a creature's threat map
class BotThreatEntry : public Object {
public:
	uint64 oid = 0;
	String name;
	uint32 damage = 0;
	int aggro = 0;
	int heal = 0;
	bool taunted = false;
};

// A creature's threat picture
class BotThreat {
public:
	uint64 target = 0;			// who it fights now (its main defender), 0 for nobody
	bool tauntable = true;		// AiAgent::isTauntable
	bool taunted = false;		// someone holds the TAUNTED state on it (a taunt in force)
	uint64 tauntedBy = 0;		// ...and who
	int lockoutMs = 0;			// until the next taunt takes effect (the TAUNTED state's cooldown), 0 when over
	bool poisoned = false;		// the creature is poisoned / diseased now (a pack's DoT is running)
	bool diseased = false;
	bool poisonImmune = false;	// a DoT pack can't take (DotPackCommand::checkTarget: dot immunity, or the NODOT flag)
	bool diseaseImmune = false;
	Vector<Reference<BotThreatEntry*>> entries;
};

// A lair near a bot (a creature spawner a hunting group should not walk into)
class BotLairInfo : public Object {
public:
	uint64 oid = 0;
	float x = 0;
	float y = 0;
};

class BotCombat {
public:
	static const int TICK_MS = 1000;
	static const int FIGHT_MAX_MS = 5 * 60 * 1000;		// a fight that goes on this long ends ("ended")
	// The flags' own expiry, in case a fight is never ended (a crash). Core3's expiry task can't be cancelled, so it
	// must fire before the same pair can fight again: under fight.lua's fightCooldown (600 s) after the fight's end.
	static const int FIGHT_FLAG_MS = FIGHT_MAX_MS + 60 * 1000;
	static const int FIGHT_RANGE = 128;					// metres apart, or the fight ends ("ended")
	static const int DUEL_RANGE = 30;					// challenges are looked for this close (/duel needs 25 m)
	static const int CLONE_WAIT_MS = 60000;				// a clone not done by then is given up (botClone again)
	static const int INCAP_WINDOW = 600;				// Core3: the third incap within this many seconds kills

	// Starts the tick, once. Called from BotCombatLua::registerFunctions
	static void start();
	static void tick();

	// The bot's target (0 clears it). With engage, a target the bot may attack gets an "attack" queued, so combat
	// starts and auto-attack runs (the bot must be in weapon range for the attack to land). False if the target isn't
	// in the bot's zone.
	static bool setTarget(server::zone::objects::creature::CreatureObject* bot, uint64 targetOid, bool engage);

	// "none", "challenged" (other challenged the bot), "challenging" (the bot challenged other) or "dueling"
	static String duelState(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* other);

	// A real fight with a player (a human; a bot works for tests). False if it can't start: offline, another planet,
	// over FIGHT_RANGE, someone down, a no-combat area, the bot already fights someone else, or the player was
	// incapacitated twice in the last ten minutes (the fight's incap would kill). True if this fight is already on.
	static bool startFight(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* human);

	// How many times the player was incapacitated in the last INCAP_WINDOW seconds: what BotCombat saw, capped by Core3's
	// own list (which only drops old entries when a new incap comes, so alone it overcounts); in the first INCAP_WINDOW
	// after the first tick, Core3's list alone. At 2, the next incap kills: no fight, and no duel worth accepting
	static int recentIncaps(server::zone::objects::creature::CreatureObject* creature);

	// Takes the dead (or no longer in the world) off a creature's defender list, and the combat state with them when the
	// list is then empty; live defenders stay (duels, adds still fighting). Core3 clears a corpse from its killer's list
	// and from its own, not from a third party's who had attacked it: that player stays in combat until /peace. Returns
	// how many it removed. The creature should be locked (an event on it).
	static int dropDeadDefenders(server::zone::objects::creature::CreatureObject* creature);

	// Ends a fight or a duel with that player now: event "fightEnded", detail "ended". False if there was none
	static bool endFight(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* human);

	// A dead bot clones at the closest cloning facility, through the clone window as a player would. Event "cloned"
	// once it stands at the facility
	static bool clone(server::zone::objects::creature::CreatureObject* bot);

	// Makes sure the bot wears or holds `templateName` (armor, clothing; a weapon goes to hold_r): taken from the
	// inventory, or created. Whatever is in its slots goes to the inventory. Repaired. Returns its oid, or 0
	static uint64 equip(server::zone::objects::creature::CreatureObject* bot, const String& templateName);

	// The held weapon's ranges (the unarmed default when nothing is held). False for a non-bot or an offline bot
	static bool weaponRange(server::zone::objects::creature::CreatureObject* bot, BotWeaponRange& out);

	// What the creature (an AiAgent; anything else gives false) is on and how it can be taunted. Reads its threat map under
	// its lock, so call it from an event on the bot (the bot is locked, as the crew's Lua is)
	static bool threatOn(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* creature, BotThreat& out);

	// The lairs within `range` metres of the bot (its zone): objects with a lair observer, as the camp kit's scan finds them.
	// A scan of the bot's neighbourhood: call it now and then, not every step
	static void lairsNear(server::zone::objects::creature::CreatureObject* bot, float range, Vector<Reference<BotLairInfo*>>& out);

	// Repairs everything worn or held, and the weapons and armor in the inventory. Returns how many were damaged
	static int repairGear(server::zone::objects::creature::CreatureObject* bot);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTCOMBAT_H_ */
