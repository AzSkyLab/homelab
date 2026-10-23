/*
 * BotCombatLua: the Lua bindings for combat, groups, cloning, fights, ranger (Phase 5). Registered from BotLua::registerFunctions.
 */

#ifndef BOTCOMBATLUA_H_
#define BOTCOMBATLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotCombatLua {
public:
	static void registerFunctions(Lua* lua);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTCOMBATLUA_H_ */
