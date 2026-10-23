/*
 * BotTradeLua: the Lua bindings for trade and slicing (Phase 4). Registered from BotLua::registerFunctions.
 */

#ifndef BOTTRADELUA_H_
#define BOTTRADELUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotTradeLua {
public:
	static void registerFunctions(Lua* lua);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTTRADELUA_H_ */
