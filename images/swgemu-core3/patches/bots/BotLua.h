/*
 * BotLua: the bot players' Lua globals and the BotJobs events (Phase 3, see BotManager.h and
 * ~/github/swgemu/specs/2026-10-23-bot-players/interfaces.md).
 *
 * registerFunctions runs from DirectorManager::initializeLuaEngine (patches/0004), so every Lua state has them. Every
 * function is safe with nil, a non-bot or an offline bot: it returns false, nil or 0.
 */

#ifndef BOTLUA_H_
#define BOTLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

class BotLua {
public:
	static void registerFunctions(Lua* lua);

	// BotJobs:<fn>(pBot) on this thread's screenplay Lua state, if the jobs screenplay defines it. Bot locked
	static void callJobsEvent(const char* fn, server::zone::objects::creature::CreatureObject* bot);

	// BotJobs:onHeard(pBot, pSpeaker, text, channel). Bot locked
	static void callJobsHeard(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::creature::CreatureObject* speaker,
			const String& text, const String& channel);

private:
	static int botList(lua_State* L);
	static int botGetCreature(lua_State* L);
	static int isBot(lua_State* L);
	static int botLogin(lua_State* L);
	static int botLogout(lua_State* L);
	static int botSetDevHuman(lua_State* L);
	static int botEnqueue(lua_State* L);
	static int botSay(lua_State* L);
	static int botTell(lua_State* L);
	static int botEmote(lua_State* L);
	static int botFace(lua_State* L);
	static int botStockPack(lua_State* L);
	static int botGetWounds(lua_State* L);
	static int botGetShockWounds(lua_State* L);
	static int botGetBuffs(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTLUA_H_ */
