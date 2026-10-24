-- Bot players (Phase 4): the master smuggler who slices armor and weapons by trade, in a corner of each cantina. It
-- idles and emotes and talks shop. The handover is the real trade window, through the trade bindings
-- (patches/bots/BotTradeLua.cpp, BotTrade.h), which tell the job about it with "trade" events:
--   "requested"        a player dragged something onto it: it opens the trade and names its price
--   "changed"          the offer (or the player's accept) changed: a moment later it checks it. Exactly one unsliced
--                      armor piece or weapon and the price in credits: it accepts (so the player's window moves on to
--                      verifying). Otherwise it says what's missing; a weapon's powerup gets a warning first, and a few
--                      seconds to pull it out
--   "partnerVerified"  the player verified: it checks the offer again and verifies last (botTradeVerify, which
--                      re-checks the offer in the same locked step as the transfer). The trade is done when that
--                      returns, and it slices at once (botSlice: Core3's own slicing with a clamp, so it never fails);
--                      the item goes straight back into the player's inventory (by a give-back trade if it's full).
--                      Then it says what the slice gave ("+27% effectiveness") and thanks them. A slice that can't be
--                      done gives the credits back with a /tip
--   "aborted"          the player called it off; "returned": a give-back trade went through
-- The price is roster.lua's slicePriceArmor or slicePriceWeapon; anything paid on top counts as a tip and is thanked
-- for. Its tools (laser knife, clamps, upgrade kits) are restocked after every job. Driven by BotJobs (bot_jobs.lua);
-- every step is an event on the bot.

BotSmuggler = ScreenPlay:new {
	screenplayName = "BotSmuggler",

	-- What the talk bridge knows the job as (Phase 2's kits and places; the brain's persona is by job)
	kit = "traveller",
	place = "cantina",

	-- roster.lua settings, when it doesn't set them
	defaults = {slicePriceArmor = 4000, slicePriceWeapon = 6000, sliceToolStock = 5},

	-- After the player changes the offer, it waits this long (ms) for them to finish before checking it
	reviewMs = 1500,
	-- What's wrong with an offer is said again when they accept it anyway, if they heard it this long ago (seconds)
	repeatAfter = 10,
	-- A weapon with a powerup: after the warning, this long (ms) to pull it out before it accepts
	powerupGraceMs = 8000,
	-- A trade open this long (seconds) with no deal is called off
	tradeTimeout = 300,
	-- The same customer within this long (seconds) gets the short opening line
	againWindow = 300,
	-- Within this range it talks out loud; further away it's a tell
	sayRange = 40,
	-- After a job, the thank-you follows the result this long after (ms)
	thankMs = 2500,
	-- Idle: an emote every idleEvery seconds
	idleEvery = {90, 240},
}

-- Trade steps: none, a trade open, slicing
local NONE, OPEN, SLICING = 0, 1, 2

-- How each result reads (botSlice's stat; its percent is always positive)
local STATS = {
	effectiveness = {"+", "effectiveness"},
	encumbrance = {"-", "encumbrance"},
	damage = {"+", "damage"},
	speed = {"-", "attack speed"},
}

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function tkey(oid, field)
	return "bot:" .. oid .. ":trade:" .. field
end

local function packArgs(...)
	return table.concat({...}, ":")
end

local function unpackArgs(args)
	local out = {}

	for part in string.gmatch(args or "", "[^:]+") do
		table.insert(out, part)
	end

	return out
end

local function between(range)
	return getRandomNumber(range[1], range[2])
end

-- 4000 -> "4,000"
local function credits(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()

	return (out:gsub("^,", ""):gsub("^%-,", "-"))
end

function BotSmuggler:setting(name)
	local value = BotJobs:setting(name)

	if value == nil then
		value = self.defaults[name]
	end

	return value
end

function BotSmuggler:price(kind)
	return math.floor(tonumber(self:setting(kind == "armor" and "slicePriceArmor" or "slicePriceWeapon")) or 0)
end

-- Does this build have what a slice needs? Without it, it never takes an item.
function BotSmuggler:ready()
	return botTradeState ~= nil and botTradeAccept ~= nil and botTradeVerify ~= nil and botTradeAbort ~= nil and
		botItemInfo ~= nil and botSlice ~= nil
end

-- Not while it's fighting, out cold or dead
function BotSmuggler:canWork(pBot, oid)
	local creature = CreatureObject(pBot)

	if creature:isInCombat() or creature:isIncapacitated() or creature:isDead() then
		return false
	end

	return not (BotFight ~= nil and BotFight.busy ~= nil and BotFight:busy(oid))
end

function BotSmuggler:restock(pBot)
	if botStockSlicingTools ~= nil then
		botStockSlicingTools(pBot, math.floor(tonumber(self:setting("sliceToolStock")) or 5))
	end
end

-- Logging in: tools stocked. After BotJobs:restart a trade may still be open: it carries on.
function BotSmuggler:start(pBot, oid)
	writeData(key(oid, "nextIdle"), os.time() + between(self.idleEvery))
	self:restock(pBot)

	if self:stage(pBot) == "none" then
		self:clearTrade(oid)
	end

	if not self:ready() then
		print("BotJobs: " .. BotJobs:name(oid) .. " can't slice: this build has no trade bindings")
	end
end

function BotSmuggler:clear(oid)
	self:clearTrade(oid)
end

function BotSmuggler:clearTrade(oid)
	writeData(tkey(oid, "seq"), readData(tkey(oid, "seq")) + 1)

	for _, field in ipairs({"step", "partner", "since", "warned", "graceUntil", "saidAt"}) do
		deleteData(tkey(oid, field))
	end

	deleteStringData(tkey(oid, "said"))
end

-- The trade's stage as the body sees it: "none", "requested", "open" or "partnerVerified"
function BotSmuggler:stage(pBot)
	if botTradeState == nil then
		return "none"
	end

	local state = botTradeState(pBot)

	return state ~= nil and tostring(state.stage or "none") or "none"
end

-- A line of a kind, with the job's numbers filled in
function BotSmuggler:line(oid, kind, name, vars)
	local line = BotLines:pick("smuggler", kind, name, BotJobs:city(oid))

	if line == nil then
		return nil
	end

	local fill = {armor = credits(self:price("armor")), weapon = credits(self:price("weapon")), item = "piece",
		kind = "it", price = "", credits = "0", missing = "", result = ""}

	for k, v in pairs(vars or {}) do
		fill[k] = v
	end

	return (line:gsub("{(%a+)}", function(k) return fill[k] ~= nil and tostring(fill[k]) or nil end))
end

-- Out loud when they're near, else by tell
function BotSmuggler:say(pBot, oid, playerOid, kind, name, vars, mood)
	local line = self:line(oid, kind, name, vars)
	local dist = BotJobs:distance(pBot, getSceneObject(playerOid))
	local channel = (dist ~= nil and dist <= self.sayRange) and "spatial" or "tell"

	BotJobs:reply(pBot, playerOid, channel, line, mood)
end

-- What the trade bindings say happened (BotJobs:onEvent)
function BotSmuggler:onEvent(pBot, oid, name, pOther, detail)
	if name ~= "trade" then
		return
	end

	if detail == "requested" then
		self:requested(pBot, oid, pOther)
	elseif detail == "changed" then
		self:changed(pBot, oid)
	elseif detail == "partnerVerified" then
		self:review(pBot, oid, true)
	elseif detail == "aborted" then
		self:aborted(pBot, oid, pOther)
	elseif detail == "returned" and pOther ~= nil then
		self:say(pBot, oid, SceneObject(pOther):getObjectID(), "returned", CreatureObject(pOther):getFirstName())
	end

	-- "done" needs nothing: the slice happened as botTradeVerify returned
end

-- A player dragged an item onto it: open the trade and name the price
function BotSmuggler:requested(pBot, oid, pHuman)
	if pHuman == nil then
		return
	end

	local now = os.time()
	local humanOid = SceneObject(pHuman):getObjectID()
	local name = CreatureObject(pHuman):getFirstName()
	local partner = readData(tkey(oid, "partner"))

	if partner ~= 0 and partner ~= humanOid and readData(tkey(oid, "step")) ~= NONE then
		self:say(pBot, oid, humanOid, "busy", name)
		return
	end

	if not self:ready() or not self:canWork(pBot, oid) then
		print("BotJobs: " .. BotJobs:name(oid) .. " turns down a trade with " .. name ..
			(self:ready() and " (busy fighting)" or " (no trade bindings)"))
		self:say(pBot, oid, humanOid, "closed", name)

		if botTradeAbort ~= nil then
			botTradeAbort(pBot)
		end

		return
	end

	local ok, why = botTradeAccept(pBot)

	if not ok then
		print("BotJobs: " .. BotJobs:name(oid) .. " couldn't open the trade " .. name .. " asked for: " .. tostring(why))
		return
	end

	self:clearTrade(oid)
	writeData(tkey(oid, "step"), OPEN)
	writeData(tkey(oid, "partner"), humanOid)
	writeData(tkey(oid, "since"), now)

	local again = readData(key(oid, "lastCustomer")) == humanOid and now - readData(key(oid, "lastCustomerAt")) <= self.againWindow

	writeData(key(oid, "lastCustomer"), humanOid)
	writeData(key(oid, "lastCustomerAt"), now)

	botFace(pBot, pHuman)
	self:say(pBot, oid, humanOid, again and "openAgain" or "open", name)
	print("BotJobs: " .. BotJobs:name(oid) .. " opens a trade with " .. name)
end

-- The offer changed: check it once they've stopped for a moment
function BotSmuggler:changed(pBot, oid)
	if readData(tkey(oid, "step")) == SLICING then
		return
	end

	self:reviewIn(pBot, oid, self.reviewMs)
end

function BotSmuggler:reviewIn(pBot, oid, ms)
	local seq = readData(tkey(oid, "seq")) + 1

	writeData(tkey(oid, "seq"), seq)
	createEvent(ms, "BotSmuggler", "reviewLater", pBot, packArgs(readData(key(oid, "gen")), seq))
end

function BotSmuggler:reviewLater(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if readData(tkey(oid, "seq")) ~= tonumber(a[2]) then
		return
	end

	self:review(pBot, oid, false)
end

-- What's wrong with the offer, or nil and the deal: {problem, detail, vars} or {item, info, kind, price, paid, vars}
function BotSmuggler:checkOffer(state)
	local items = state.items or {}
	local paid = math.floor(tonumber(state.credits) or 0)
	local vars = {credits = credits(paid)}

	if #items == 0 then
		return {problem = "noItem", detail = "", vars = vars}
	end

	if #items > 1 then
		return {problem = "tooMany", detail = tostring(#items), vars = vars}
	end

	local item = math.floor(tonumber(items[1]) or 0)
	local info = botItemInfo(item) or {}

	if info.name ~= nil and tostring(info.name) ~= "" then
		vars.item = tostring(info.name)
	end

	if info.kind ~= "armor" and info.kind ~= "weapon" then
		return {problem = "wrongKind", detail = tostring(item), vars = vars}
	end

	if info.sliced then
		return {problem = "sliced", detail = tostring(item), vars = vars}
	end

	-- (botItemInfo's sliceable: e.g. a Jedi weapon can't be)
	if info.sliceable == false then
		return {problem = "unsliceable", detail = tostring(item), vars = vars}
	end

	local price = self:price(info.kind)

	vars.price = credits(price)
	vars.kind = info.kind == "armor" and "armor" or "a weapon"

	if paid < price then
		vars.missing = credits(price - paid)
		return {problem = "short", detail = item .. "/" .. paid, vars = vars}
	end

	return {item = item, info = info, kind = info.kind, price = price, paid = paid, vars = vars}
end

-- Check the offer, and accept a right one (verifying last if they've verified). final: they've verified.
function BotSmuggler:review(pBot, oid, final)
	if readData(tkey(oid, "step")) == SLICING or botTradeState == nil then
		return
	end

	local state = botTradeState(pBot)

	if state == nil or state.stage == nil or state.stage == "none" or state.stage == "requested" then
		return
	end

	-- A give-back trade (an item it owes someone) is the body's own business
	if (tonumber(state.give) or 0) ~= 0 then
		return
	end

	local partnerOid = math.floor(tonumber(state.partner) or 0)

	if partnerOid == 0 then
		partnerOid = readData(tkey(oid, "partner"))
	end

	local pHuman = getSceneObject(partnerOid)

	if pHuman == nil then
		return
	end

	if readData(tkey(oid, "step")) == NONE or readData(tkey(oid, "partner")) ~= partnerOid then
		-- A trade it didn't see open (after BotJobs:restart): it's this one now
		writeData(tkey(oid, "step"), OPEN)
		writeData(tkey(oid, "partner"), partnerOid)
		writeData(tkey(oid, "since"), os.time())
	end

	local name = CreatureObject(pHuman):getFirstName()
	local offer = self:checkOffer(state)
	local said = readStringData(tkey(oid, "said"))

	final = final or state.stage == "partnerVerified"

	if offer.problem ~= nil then
		-- Each problem is said once; again if they verify with it, unless they heard it a moment ago
		local what = offer.problem .. ":" .. offer.detail

		if what ~= said or (final and os.time() - readData(tkey(oid, "saidAt")) >= self.repeatAfter) then
			self:say(pBot, oid, partnerOid, offer.problem, name, offer.vars)
			writeStringData(tkey(oid, "said"), what)
			writeData(tkey(oid, "saidAt"), os.time())
		end

		return
	end

	-- A weapon's powerup goes with the slice: the warning first, then a few seconds to pull it out
	if offer.info.powerup and readData(tkey(oid, "warned")) ~= offer.item then
		writeData(tkey(oid, "warned"), offer.item)
		writeData(tkey(oid, "graceUntil"), getTimestampMilli() + self.powerupGraceMs)
		writeStringData(tkey(oid, "said"), "powerup")
		self:say(pBot, oid, partnerOid, "powerup", name, offer.vars)
		self:reviewIn(pBot, oid, self.powerupGraceMs + 200)
		return
	end

	local wait = readData(tkey(oid, "graceUntil")) - getTimestampMilli()

	if wait > 0 then
		self:reviewIn(pBot, oid, wait + 200)
		return
	end

	self:deal(pBot, oid, pHuman, offer)
end

-- The offer is right: accept, and when they've verified, verify last. The body re-checks the offer (the one item,
-- at least the price) in the same locked step as the transfer; when that returns true, the item and credits are
-- the bot's, and it slices in this same step.
function BotSmuggler:deal(pBot, oid, pHuman, offer)
	local partnerOid = SceneObject(pHuman):getObjectID()
	local name = CreatureObject(pHuman):getFirstName()
	local ok, why = botTradeVerify(pBot, offer.price, offer.item)

	if ok then
		print("BotJobs: " .. BotJobs:name(oid) .. " took " .. name .. "'s " .. (offer.vars.item or "piece") .. " (" .. offer.kind ..
			") and " .. offer.paid .. " credits")
		self:slice(pBot, oid, pHuman, offer)
	elseif why == "waiting" then
		-- Accepted; their verify is next
		if readStringData(tkey(oid, "said")) ~= "ready" then
			writeStringData(tkey(oid, "said"), "ready")
			self:say(pBot, oid, partnerOid, "ready", name, offer.vars)
		end
	elseif why == "changed" or why == "credits" or why == "items" then
		-- The offer moved between the look and the verify: look again
		self:reviewIn(pBot, oid, self.reviewMs)
	elseif why == "failed" then
		-- Core3's own checks (room in an inventory, distance) failed, and the trade is closed
		print("BotJobs: " .. BotJobs:name(oid) .. "'s trade with " .. name .. " failed Core3's checks")
		self:clearTrade(oid)
		self:say(pBot, oid, partnerOid, "tradeFailed", name)
	else
		self:clearTrade(oid)
	end
end

-- "+27% effectiveness"
function BotSmuggler:describe(result)
	local percent = math.abs(tonumber(result.percent) or 0)

	if percent > 0 and percent < 1 then
		percent = percent * 100
	end

	percent = math.floor(percent + 0.5)

	local stat = STATS[tostring(result.stat or "")]

	if stat == nil then
		return percent .. "% " .. tostring(result.stat or "better")
	end

	return stat[1] .. percent .. "% " .. stat[2]
end

-- The trade went through: slice at once; the item goes straight back to its owner
function BotSmuggler:slice(pBot, oid, pHuman, offer)
	writeData(tkey(oid, "step"), SLICING)

	local ownerOid = SceneObject(pHuman):getObjectID()
	local name = CreatureObject(pHuman):getFirstName()
	local itemName = offer.vars.item or "piece"
	local result = botSlice(pBot, offer.item, pHuman) or {}
	local cash = BotJobs:cash(pBot)

	if result.ok then
		local text = self:describe(result)

		-- The payment is no tip, but anything over the price is: BotJobs:checkTips thanks them for that by name
		writeData(key(oid, "cash"), cash - (offer.paid - offer.price))
		writeData(key(oid, "lastPatient"), ownerOid)
		writeData(key(oid, "lastPatientAt"), os.time())
		writeData(key(oid, "slices"), readData(key(oid, "slices")) + 1)

		print("BotJobs: " .. BotJobs:name(oid) .. " sliced " .. name .. "'s " .. itemName .. ": " .. text ..
			(result.returned and "" or (" (handing it back by trade: " .. tostring(result.error) .. ")")))
		self:say(pBot, oid, ownerOid, "result", name, {item = itemName, result = text}, "happy")

		if result.returned == false then
			self:say(pBot, oid, ownerOid, "giveBack", name, {item = itemName})
		end

		createEvent(self.thankMs, "BotSmuggler", "thank", pBot, packArgs(readData(key(oid, "gen")), ownerOid))
	else
		-- None of it was a tip: their credits go back by /tip (the item went back with botSlice)
		writeData(key(oid, "cash"), cash)
		print("BotJobs: " .. BotJobs:name(oid) .. " couldn't slice " .. name .. "'s " .. itemName .. ": " ..
			tostring(result.error) .. "; " .. offer.paid .. " credits back")

		if offer.paid > 0 then
			botEnqueue(pBot, "tip", ownerOid, tostring(offer.paid))
		end

		self:say(pBot, oid, ownerOid, "failed", name)
	end

	self:clearTrade(oid)
	self:restock(pBot)
end

function BotSmuggler:thank(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local ownerOid = tonumber(a[2])
	local pOwner = getSceneObject(ownerOid)
	local dist = BotJobs:distance(pBot, pOwner)

	if dist ~= nil and dist <= self.sayRange then
		botEmote(pBot, "tiphat", ownerOid)
	end

	self:say(pBot, oid, ownerOid, "thanksJob", pOwner ~= nil and CreatureObject(pOwner):getFirstName() or nil)
end

-- The player called it off (or walked away, or logged out)
function BotSmuggler:aborted(pBot, oid, pHuman)
	local step = readData(tkey(oid, "step"))

	if step ~= OPEN then
		return
	end

	local partnerOid = readData(tkey(oid, "partner"))
	local name = pHuman ~= nil and CreatureObject(pHuman):getFirstName() or nil

	self:clearTrade(oid)
	print("BotJobs: " .. BotJobs:name(oid) .. ": the trade with " .. tostring(name or partnerOid) .. " was called off")

	if getRandomNumber(1, 100) <= 50 then
		self:say(pBot, oid, partnerOid, "aborted", name)
	end
end

-- From BotJobs:tick every few seconds: a trade that went nowhere is called off; else now and then an emote
function BotSmuggler:tick(pBot, oid, now)
	local step = readData(tkey(oid, "step"))

	if step ~= NONE then
		local partnerOid = readData(tkey(oid, "partner"))
		local pPartner = getSceneObject(partnerOid)

		if step == OPEN and self:stage(pBot) == "none" then
			-- It closed without a word
			self:clearTrade(oid)
		elseif now - readData(tkey(oid, "since")) > self.tradeTimeout then
			print("BotJobs: " .. BotJobs:name(oid) .. " calls off a trade that went nowhere")
			self:clearTrade(oid)

			if botTradeAbort ~= nil then
				botTradeAbort(pBot)
			end

			self:say(pBot, oid, partnerOid, "timeout", pPartner ~= nil and CreatureObject(pPartner):getFirstName() or nil)
		end

		return
	end

	if now < readData(key(oid, "nextIdle")) or not self:canWork(pBot, oid) then
		return
	end

	writeData(key(oid, "nextIdle"), now + between(self.idleEvery))
	botEmote(pBot, BotLines.smugglerIdle[getRandomNumber(1, #BotLines.smugglerIdle)], 0)
end

-- For BotJobs:list
function BotSmuggler:state(pBot, oid)
	local step = readData(tkey(oid, "step"))
	local state = "idle"

	if step ~= NONE then
		local pPartner = getSceneObject(readData(tkey(oid, "partner")))
		local who = pPartner ~= nil and CreatureObject(pPartner):getFirstName() or tostring(readData(tkey(oid, "partner")))

		state = (step == SLICING and "slicing for " or "trading with ") .. who
	end

	state = state .. ", " .. readData(key(oid, "slices")) .. " slices"

	if not self:ready() then
		state = state .. ", no trade bindings"
	end

	return state .. (BotFight ~= nil and BotFight.describe ~= nil and BotFight:describe(oid) or "")
end

-- The job module interface (bot_jobs.lua): keywords for when the language model can't answer. The smuggler has no
-- actions of the brain's; "price" and "howto" are its own lines.

function BotSmuggler:intent(text)
	local t = text:lower()

	for _, words in ipairs({"price", "how much", "cost", "charge"}) do
		if t:find(words, 1, true) ~= nil then
			return "price"
		end
	end

	if t:find("slice", 1, true) ~= nil or t:find("slicing", 1, true) ~= nil then
		return "howto"
	end

	return nil
end

function BotSmuggler:isAction(intent)
	return intent == "price" or intent == "howto"
end

function BotSmuggler:allowed(action)
	return nil
end

function BotSmuggler:act(pBot, pPlayer, action, channel, brainLine)
	if (action ~= "price" and action ~= "howto") or brainLine ~= nil then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	BotJobs:reply(pBot, SceneObject(pPlayer):getObjectID(), channel,
		self:line(oid, action, CreatureObject(pPlayer):getFirstName()))
end

-- Development, bot on bot: another bot plays the customer through BotTradeDev (BotTradeLua.h). Bots carry little
-- cash, so this gives one some (cash on hand):
--   runLuaFunction BotSmuggler:devCash:<first>:<credits>
function BotSmuggler:devCash(first, amount)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: usage devCash:<bot>:<credits>, the bot online")
		return
	end

	createEvent(10, "BotSmuggler", "devCashNow", pBot, tostring(math.floor(tonumber(amount) or 10000)))
end

function BotSmuggler:devCashNow(pBot, amount)
	CreatureObject(pBot):addCashCredits(tonumber(amount), true)
	print("BotJobs: " .. CreatureObject(pBot):getFirstName() .. " has " .. CreatureObject(pBot):getCashCredits() .. " credits on hand")
end

-- For the brain (the request's extra fields): the prices it names
function BotSmuggler:requestFields(pBot, oid)
	return {priceArmor = self:price("armor"), priceWeapon = self:price("weapon")}
end

BotJobModules = BotJobModules or {}
BotJobModules.smuggler = BotSmuggler
