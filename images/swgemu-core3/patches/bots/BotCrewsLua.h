/*
 * BotCrewsLua: the Lua bindings for own crews (Phase 9, Part 1). Registered from BotLua::registerFunctions. The work is in
 * BotManager (hire, letGo) and BotCrews. Documented, with the rest of the bot bindings, in
 * ~/github/swgemu/specs/2026-10-23-bot-players/interfaces.md ("Phase 9").
 *
 *   botCrewOf(ownerOid)          array of {oid, name, firstName, job, species, sex, city, hiredAt, online, ready, state},
 *                                in hire order: the owner's crew. ready is false while the character is still being made
 *   botHire(ownerOid, entry)     ok, reason: a roster-shaped table (name, species, sex, hair, hairColor, skinTone, job, city,
 *                                skills, outfit, carry, weapon, campKit, station) becomes an own-crew bot of that character,
 *                                online "owner". Checked as the roster is (names by Core3's rules, templates, skills),
 *                                plus one bot per role and seven at most; the account and character are made in a task.
 *                                On false, reason says why (a line to show the player); on true, reason is the first name
 *   botLetGo(botOid)             ok, reason: an own-crew bot goes (logged out, its character deleted in a task)
 *   botOwner(botOid)             the owner's object id, or 0 for a roster bot or no bot
 *   botNameFree(first)           ok, reason: no bot or character has the first name (the crowd's names are the caller's)
 *   botNameCheck(name, species)  ok, reason: Core3's NameManager rules for a species ("human", "wookiee"...)
 *   botBoxCount(oid)             a character's skill boxes counted as its level: all but the novice, species and language
 *   botEntry(first)              the bot's entry as a roster-shaped table (the jobs' BotJobs:entry for a bot that is not in
 *                                roster.lua), or nil
 */

#ifndef BOTCREWSLUA_H_
#define BOTCREWSLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotCrewsLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botCrewOf(lua_State* L);
	static int botHire(lua_State* L);
	static int botLetGo(lua_State* L);
	static int botOwner(lua_State* L);
	static int botNameFree(lua_State* L);
	static int botNameCheck(lua_State* L);
	static int botBoxCount(lua_State* L);
	static int botEntry(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTCREWSLUA_H_ */
