/*
 * BotLootLua: the Lua bindings for looting, harvesting and handing over (Phase 7). Registered from
 * BotLua::registerFunctions. See BotLoot.h.
 *
 *   botLootCorpse(pBot, corpseOid)       {ok, moved, left, credits, full, error}: everything the bot's group may loot
 *                                        off the corpse goes into the bot's inventory (under any loot rule); the
 *                                        credits go through Core3's group split to the humans. error: "no bot",
 *                                        "no corpse", "player corpse", "alive", "not grouped", "not the group's",
 *                                        "too far" (it must be within 16 m)
 *   botHarvest(pBot, corpseOid[, kind])  {ok, kind, amount, resource, error}: Core3's own harvest ("meat", "hide",
 *                                        "bone"; default the one the creature has most of). error: "too far" (within
 *                                        7 m), "cannot harvest" (skill, combat, already harvested), "nothing to
 *                                        harvest", "alive", "not a creature", "no corpse"
 *   botGoods(pBot)                       array of {oid, name, quantity, resource, tradable}: what the bot holds that
 *                                        isn't its own gear (what it looted, and every resource container)
 *   botOfferGoods(pBot, playerOid)       true, offered, remaining: opens a hand-over trade on the player's client with
 *                                        all the goods that fit (at most 20 items); or false and why ("no player",
 *                                        "too far" (13 m), "busy", "no goods", "inventory full"). Events:
 *                                        BotJobs:onEvent(pBot, "trade", pPlayer, "bundleDone" | "bundleCancelled")
 *   botCancelOffer(pBot)                 drops an offer that hasn't been taken
 *
 * Development (console):
 *   runLuaFunction BotLootDev:loot:<first>:<corpseOid>
 *   runLuaFunction BotLootDev:harvest:<first>:<corpseOid>[:<kind>]
 *   runLuaFunction BotLootDev:goods:<first>
 *   runLuaFunction BotLootDev:offer:<first>:<playerFirstOrOid>      (cancel:<first>)
 *   runLuaFunction BotLootDev:mark:<first>:<itemOid>                an item in the pack counts as goods
 */

#ifndef BOTLOOTLUA_H_
#define BOTLOOTLUA_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace managers {
namespace bot {

class BotLootLua {
public:
	static void registerFunctions(Lua* lua);

private:
	static int botLootCorpse(lua_State* L);
	static int botHarvest(lua_State* L);
	static int botGoods(lua_State* L);
	static int botOfferGoods(lua_State* L);
	static int botCancelOffer(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTLOOTLUA_H_ */
