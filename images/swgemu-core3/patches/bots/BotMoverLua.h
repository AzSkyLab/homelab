/*
 * BotMoverLua: the Lua bindings for walking and following (Phase 5). Registered from BotLua::registerFunctions.
 */

#ifndef BOTMOVERLUA_H_
#define BOTMOVERLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotMoverLua {
public:
	static void registerFunctions(Lua* lua);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTMOVERLUA_H_ */
