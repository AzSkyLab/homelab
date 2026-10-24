/*
 * BotTradeLua: the Lua bindings for trade and slicing (Phase 4). Registered from BotLua::registerFunctions.
 *
 *   botTradeState(pBot)                    {partner, stage, items, credits, partnerAccepted, accepted, give}
 *   botTradeAccept(pBot)                   true, or false and why: opens the trade a human asked for
 *   botTradeVerify(pBot[, minCredits[, itemOid]])
 *                                          true when the trade completed; else false and why ("waiting", "changed",
 *                                          "credits", "items", "none", "failed"). Re-checks the offer against the last
 *                                          botTradeState, so read the state, decide, then verify
 *   botTradeAbort(pBot)                    cancel, or refuse a request
 *   botTradeGive(pBot, pOwner, itemOid)    hand an item back through a trade (botSlice does it when needed)
 *   botItemInfo(itemOid)                   {kind, sliced, sliceable, powerup, name, parent} or nil
 *   botSlice(pBot, itemOid, pOwner)        {ok, kind, stat, percent, error, returned}
 *   botStockSlicingTools(pBot, count)      true if stocked
 *
 * Events, BotJobs:onEvent(pBot, "trade", pHuman, detail): see BotTrade.h.
 *
 * Development (console, bot on bot: one bot plays the human through PlayerManager's own trade handlers):
 *   runLuaFunction BotTradeDev:request:<from>:<bot>          <from> drags something onto <bot>
 *   runLuaFunction BotTradeDev:offer:<from>:<itemOid>:<credits>
 *   runLuaFunction BotTradeDev:accept:<from>                 (verify, abort: the same for those buttons)
 *   runLuaFunction BotTradeDev:item:<first>:<template>       make an item in a bot's inventory (logs its oid)
 *   runLuaFunction BotTradeDev:inventory:<first>             a bot's inventory and cash
 *   runLuaFunction BotTradeDev:state:<bot>                   the bot's view (botTradeState)
 *   runLuaFunction BotTradeDev:botAccept:<bot>               (botVerify:<bot>[:<minCredits>[:<itemOid>]], botAbort:<bot>)
 *   runLuaFunction BotTradeDev:slice:<bot>:<itemOid>[:<owner>]  (stock:<bot>[:<count>], info:<itemOid>)
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

private:
	static int botTradeState(lua_State* L);
	static int botTradeAccept(lua_State* L);
	static int botTradeVerify(lua_State* L);
	static int botTradeAbort(lua_State* L);
	static int botTradeGive(lua_State* L);
	static int botItemInfo(lua_State* L);
	static int botSlice(lua_State* L);
	static int botStockSlicingTools(lua_State* L);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

#endif /* BOTTRADELUA_H_ */
