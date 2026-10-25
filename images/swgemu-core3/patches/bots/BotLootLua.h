/*
 * BotLootLua: the Lua bindings for looting, harvesting and handing over (Phase 7). Registered from
 * BotLua::registerFunctions. See BotLoot.h.
 *
 *   botLootCorpse(pBot, corpseOid)       {ok, moved, left, credits, full, error}: everything the bot's group may loot
 *                                        off the corpse goes into the bot's inventory (under any loot rule); the
 *                                        credits go through Core3's group split to the humans. error: "no bot",
 *                                        "no corpse", "player corpse", "alive", "not grouped", "not the group's",
 *                                        "too far" (it must be within 16 m). names: the item names that moved (at most 12)
 *   botHarvest(pBot, corpseOid[, kind])  {ok, kind, amount, resource, spawn, score, fallback, lead, leadValue,
 *                                        stats, altKind, altScore, error}: Core3's own harvest ("meat", "hide", "bone";
 *                                        default the one with the best crafting score, then the most yield). A kind the
 *                                        creature hasn't got falls back to that pick, with fallback = true. spawn,
 *                                        score, lead (its best stat, "OQ"...), stats ("OQ 870, SR 640, ...") say what was taken; altKind, altScore the
 *                                        best resource passed over. error: "too far" (within 7 m), "cannot harvest"
 *                                        (skill, combat, already harvested), "nothing to harvest", "alive", "not a
 *                                        creature", "no corpse"
 *   botHarvestChoice(pBot, corpseOid)    array of {kind, spawn, resource, yield, oq, sr, ut, ma, dr, fl, pe, score,
 *                                        harvestable}: the creature's meat, hide and bone with this planet's current
 *                                        spawn of each. Reads only
 *   botCorpsesNear(pBot, range[, pCenter])  array of {oid, distance, items, credits, harvest, name}, nearest first: the
 *                                        corpses within range of pCenter (default the bot) that the bot's group may loot
 *                                        or harvest (Core3's permission: the loot container belongs to the group), with
 *                                        something on them or to harvest. Reads only
 *   botGoods(pBot)                       array of {oid, name, quantity, resource, tradable}: what the bot holds that
 *                                        isn't its own gear (what it looted, and every resource container)
 *   botOfferGoods(pBot, playerOid)       true, offered, remaining: opens a hand-over trade on the player's client with
 *                                        all the goods that fit (at most 20 items); or false and why ("no player",
 *                                        "too far" (13 m), "busy", "no goods", "inventory full"). Events:
 *                                        BotJobs:onEvent(pBot, "trade", pPlayer, "bundleOpened" | "bundleDone" | "bundleLost" | "bundleCancelled")
 *   botCancelOffer(pBot)                 drops an offer that hasn't been taken
 *
 * Development (console):
 *   runLuaFunction BotLootDev:loot:<first>:<corpseOid>
 *   runLuaFunction BotLootDev:harvest:<first>:<corpseOid>[:<kind>]
 *   runLuaFunction BotLootDev:harvestChoice:<first>:<corpseOid>
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
	static int botHarvestChoice(lua_State* L);
	static int botGoods(lua_State* L);
	static int botCorpsesNear(lua_State* L);
	static int botOfferGoods(lua_State* L);
	static int botCancelOffer(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTLOOTLUA_H_ */
