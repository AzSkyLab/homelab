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
	String online;		// "" (online while a human is) or "planet" (only while a human is on its station's planet)
	Vector<String> skills;	// each awarded with every skill it requires
	Vector<String> outfit;	// wearable templates, equipped

	// Station: where it stands while online. cell 0 means world coordinates.
	String planet;
	float x = 0, z = 0, y = 0;
	uint64 cell = 0;
	float heading = 0;
};

typedef Vector<Reference<BotEntry*>> BotRosterList;

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
