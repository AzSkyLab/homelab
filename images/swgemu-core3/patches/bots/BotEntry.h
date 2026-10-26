/*
 * One bot from custom_scripts/bots/roster.lua (Phase 3 bot players). Shared by BotManager and BotFactory.
 */

#ifndef BOTENTRY_H_
#define BOTENTRY_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotEntry : public Object {
public:
	String name;		// "Firstname Lastname"
	String firstName;	// how players address it, unique among bots
	String account;		// MySQL account name
	String species;		// as in object/creature/player/<species>_<sex>.iff
	String sex;			// "male" or "female"
	String hair;		// hair object template, or empty
	String job;			// "doctor" or "dancer"
	String city;		// Living Cities city key, e.g. "mos_eisley"
	String online;		// "" (online while a human is), "planet" (only while a human is on its station's planet) or "owner"
						// (an own-crew bot, Phase 9: online while its owner's character is)
	Vector<String> skills;	// each awarded with every skill it requires
	Vector<String> outfit;	// wearable templates, equipped
	Vector<String> carry;	// templates kept in the inventory (a spare weapon, a camp kit), not equipped

	// Phase 9 (own crews, BotCrews). The jobs read weapon and campKit through botEntry; the factory reads the rest.
	uint64 owner = 0;		// the human character this bot belongs to; 0 for a roster bot
	int64 hiredAt = 0;		// unix seconds
	int hairColor = -1;		// a palette index for the hair, or -1 for the template's own colour
	int skinTone = -1;		// a palette index for the skin, or -1
	String weapon;			// the weapon in hand, when the outfit has none or has several
	String campKit;			// the ranger's camp kit, when it carries none
	String doctrine;		// the Mos Eisley crew bot's first name (lower case) whose doctrine file seeds this bot's

	// Station: where it stands while online. cell 0 means world coordinates.
	String planet;
	float x = 0, z = 0, y = 0;
	uint64 cell = 0;
	float heading = 0;
};

typedef Vector<Reference<BotEntry*>> BotRosterList;

// A character of a bot that was let go, recorded in the own-crews file from the let-go until the next boot has checked it is
// gone (a save running at the moment of the deletion could write the row back; a stop between the let-go and the deletion would
// leave it). done: the deletion has run in this session.
class PendingDeletion : public Object {
public:
	uint64 oid = 0;
	String firstName;
	String account;
	bool done = false;
};

typedef Vector<Reference<PendingDeletion*>> PendingDeletionList;

// roster.lua's settings table (the jobs screenplay reads the rest of it itself)
class BotSettings : public Object {
public:
	int loginDelay = 60;	// seconds after the first human logs in
	int logoutDelay = 600;	// seconds after the last human logs out
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTENTRY_H_ */
