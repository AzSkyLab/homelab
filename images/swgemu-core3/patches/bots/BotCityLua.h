/*
 * BotCityLua: the Lua bindings for the player city (Phase 6). Registered from BotLua::registerFunctions.
 */

#ifndef BOTCITYLUA_H_
#define BOTCITYLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotCityLua {
public:
	static void registerFunctions(Lua* lua);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTCITYLUA_H_ */
