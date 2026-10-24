/*
 * BotVehicleLua: the Lua bindings for a crew bot's swoop (Phase 7, see BotVehicle.h). Registered from
 * BotLua::registerFunctions, so every Lua state has them. Safe with nil, a non-bot or an offline bot.
 *
 *   botMount(pBot) -> bool        give it a swoop if it has none, call the swoop beside it and mount (Core3's own
 *                                 mount: outdoors, not in combat, upright). Queued on the bot's task: true means
 *                                 "tried", read botMounted a moment later
 *   botDismount(pBot) -> bool     get off and store the swoop (storing waits for the end of a fight: call again)
 *   botMounted(pBot) -> bool      riding a swoop, a speeder or a creature mount
 *   botVehicleOut(pBot) -> bool   one of its swoops stands in the world (riding or left standing)
 *   botMountAttacker(pCreature) -> oid   the creature attacking its swoop (a rider's vehicle is attacked, not the
 *                                 rider, who is not "in combat" meanwhile), else 0. Any creature, a player too
 *   botHasSwoop(pBot) -> bool     it has a swoop in its datapad
 */

#ifndef BOTVEHICLELUA_H_
#define BOTVEHICLELUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotVehicleLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botMount(lua_State* L);
	static int botDismount(lua_State* L);
	static int botMounted(lua_State* L);
	static int botVehicleOut(lua_State* L);
	static int botMountAttacker(lua_State* L);
	static int botHasSwoop(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTVEHICLELUA_H_ */
