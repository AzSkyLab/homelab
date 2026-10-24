/*
 * BotFactory: makes a bot's account and character on first boot (Phase 3 bot players).
 */

#ifndef BOTFACTORY_H_
#define BOTFACTORY_H_

#include "BotEntry.h"

namespace server {
namespace zone {

class ZoneServer;

namespace objects {
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

class BotFactory {
public:
	// Reads custom_scripts/bots/roster.lua (path relative to bin/, e.g. "scripts/custom_scripts/bots/roster.lua") into
	// `out` and `settings`. Returns false, logged, if the file is missing or broken. An entry that can't work (an
	// unknown species, job, skill or template, a bad name, a duplicate name or account) is logged and left out.
	static bool loadRoster(const String& path, BotRosterList& out, BotSettings& settings);

	// Creates the MySQL account and the character the first time (skips whatever already exists), awards the skills,
	// equips the outfit and puts the character at its station, saved and offline. Returns the character's object id,
	// or 0 on failure (logged). Call from a task, not from a Lua callback or a network thread.
	// Later calls return the same character after adding any roster skill, hair or outfit item it lacks, and put it
	// back at its station if it is offline.
	static uint64 ensureCharacter(ZoneServer* zoneServer, const BotEntry& entry);

private:
	// The starting profession for a job ("doctor" -> "science_medic", "dancer" -> "social_entertainer"); it sets the
	// starting HAM, as the profession picked at character creation does
	static String getStartingProfession(const String& job);

	// Checks one roster entry against the templates, the skills and the entries already accepted
	static bool validateEntry(const BotEntry& entry, const BotRosterList& accepted, String& reason);

	// The MySQL account's id, creating the account with a random password nobody knows; 0 on failure
	static uint32 ensureAccount(const String& username);

	// The character with this first name on the account, in `characters` or `characters_dirty`; 0 if none
	static uint64 findCharacter(uint32 accountID, int galaxyID, const String& firstName);

	// PlayerCreationManager::createCharacter without a client: returns the new character's object id or 0
	static uint64 createCharacter(ZoneServer* zoneServer, const BotEntry& entry, uint32 accountID);

	// The parts that are also repaired on later boots. The creature must be locked.
	static void awardSkills(server::zone::objects::creature::CreatureObject* creature, const BotEntry& entry);
	static void ensureHair(ZoneServer* zoneServer, server::zone::objects::creature::CreatureObject* creature, const BotEntry& entry);
	static void ensureOutfit(ZoneServer* zoneServer, server::zone::objects::creature::CreatureObject* creature, const BotEntry& entry);
	static void ensureCarry(ZoneServer* zoneServer, server::zone::objects::creature::CreatureObject* creature, const BotEntry& entry);
	static bool placeAtStation(ZoneServer* zoneServer, server::zone::objects::creature::CreatureObject* creature, const BotEntry& entry);

	// Starting HAM: the profession's creation mods plus the species' racial mods (datatables/creation/*.iff)
	static void setStartingHam(server::zone::objects::creature::CreatureObject* creature, const String& profession, const String& raceName);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTFACTORY_H_ */
