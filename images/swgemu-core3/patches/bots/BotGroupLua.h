/*
 * BotGroupLua: the Lua bindings for groups, group chat, the ranger's camp and tracking (Phase 5). Registered from BotLua::registerFunctions.
 */

#ifndef BOTGROUPLUA_H_
#define BOTGROUPLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotGroupLua {
public:
	static void registerFunctions(Lua* lua);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTGROUPLUA_H_ */
