-- Bot players (Phase 4): the master smuggler who slices armor and weapons by trade, in a corner of each cantina. It
-- idles and emotes and talks shop. The handover is the real trade window, through the trade bindings
-- (patches/bots/BotTradeLua.cpp, BotTrade.h), which tell the job about it with "trade" events:
--   "requested"        a player dragged something onto it: it opens the trade and names its price
--   "changed"          the offer (or the player's accept) changed: a moment later it checks it. Unsliced armor pieces
--                      and weapons, any number, each loose in the player's pack, and their prices in credits: it
--                      accepts (so the player's window moves on to verifying). Otherwise it says what's missing; a weapon's powerup gets a warning first, and a few
--                      seconds to pull it out
--   "partnerVerified"  the player verified: it checks the offer again and verifies last (botTradeVerify, which
--                      re-checks the offer in the same locked step as the transfer). The trade is done when that
--                      returns, and it slices each piece at once (botSlice: Core3's own slicing with a clamp, so it
--                      never fails); each goes straight back into the player's inventory (by a give-back trade if it's
--                      full). Then it says what the slices gave ("+27% effectiveness") and thanks them. A piece that
--                      can't be done gets its price back with a /tip
--   "aborted"          the player called it off; "returned": a give-back trade went through
-- The customer may name the slice type in chat ("encumbrance", "effectiveness", "damage", "speed"; "random" to leave
-- it to the roll): it's kept for them and given to botSlice, which puts that type on in Core3's own range.
-- The price is roster.lua's slicePriceArmor or slicePriceWeapon for each piece; anything paid on top counts as a tip and is thanked
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
	-- Core3 calls a trade off at the verify when the two are 15 m apart or more (checkTradeItems); past this, it asks
	-- them to come closer instead of accepting
	tradeRange = 13,
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

	for _, field in ipairs({"step", "partner", "since", "graceUntil", "saidAt"}) do
		deleteData(tkey(oid, field))
	end

	deleteStringData(tkey(oid, "said"))
	deleteStringData(tkey(oid, "warned"))
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

-- What's wrong with the offer, or nil and the deal: {problem, detail, vars} or {items, price, paid, powerup, vars}.
-- Any number of armor pieces and weapons, each at its price; each must be loose in the customer's pack (Core3 calls
-- the trade off at their verify otherwise: a worn piece, or one in a bag). inventoryOid: their pack, 0 if unknown
function BotSmuggler:checkOffer(state, inventoryOid)
	local items = state.items or {}
	local paid = math.floor(tonumber(state.credits) or 0)
	local vars = {credits = credits(paid)}

	if #items == 0 then
		return {problem = "noItem", detail = "", vars = vars}
	end

	local deal = {items = {}, price = 0, paid = paid, powerup = {}, vars = vars}
	local armor, weapons = 0, 0

	for _, oidValue in ipairs(items) do
		local item = math.floor(tonumber(oidValue) or 0)
		local info = botItemInfo(item) or {}
		local name = (info.name ~= nil and tostring(info.name) ~= "") and tostring(info.name) or nil

		vars.item = name

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

		if (inventoryOid or 0) ~= 0 and math.floor(tonumber(info.parent) or 0) ~= inventoryOid then
			return {problem = "notLoose", detail = tostring(item), vars = vars}
		end

		if info.kind == "armor" then
			armor = armor + 1
		else
			weapons = weapons + 1
		end

		deal.price = deal.price + self:price(info.kind)
		table.insert(deal.items, {oid = item, kind = info.kind, name = name or "piece", price = self:price(info.kind)})

		if info.powerup then
			table.insert(deal.powerup, name or "weapon")
		end
	end

	vars.item = #deal.items == 1 and deal.items[1].name or "gear"
	vars.price = credits(deal.price)
	vars.kind = self:describeLot(armor, weapons)

	if paid < deal.price then
		vars.missing = credits(deal.price - paid)
		return {problem = "short", detail = #deal.items .. "/" .. paid, vars = vars}
	end

	return deal
end

-- "armor", "a weapon", "3 armor pieces and a weapon"
function BotSmuggler:describeLot(armor, weapons)
	local parts = {}

	if armor == 1 and weapons == 0 then
		return "armor"
	elseif armor == 0 and weapons == 1 then
		return "a weapon"
	end

	if armor > 0 then
		table.insert(parts, armor == 1 and "an armor piece" or (armor .. " armor pieces"))
	end

	if weapons > 0 then
		table.insert(parts, weapons == 1 and "a weapon" or (weapons .. " weapons"))
	end

	return table.concat(parts, " and ")
end

-- The offer's items as one key ("12,34"), to tell one offer from another
local function lotKey(deal)
	local oids = {}

	for _, item in ipairs(deal.items) do
		table.insert(oids, tostring(item.oid))
	end

	return table.concat(oids, ",")
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
	local pInventory = SceneObject(pHuman):getSlottedObject("inventory")
	local offer = self:checkOffer(state, pInventory ~= nil and SceneObject(pInventory):getObjectID() or 0)
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
	if #offer.powerup > 0 and readStringData(tkey(oid, "warned")) ~= lotKey(offer) then
		writeStringData(tkey(oid, "warned"), lotKey(offer))
		offer.vars.item = table.concat(offer.powerup, ", ")
		writeData(tkey(oid, "graceUntil"), getTimestampMilli() + self.powerupGraceMs)
		writeStringData(tkey(oid, "said"), "powerup")
		self:say(pBot, oid, partnerOid, "powerup", name, offer.vars)
		self:reviewIn(pBot, oid, self.powerupGraceMs + 200)
		return
	end

	-- Too far apart: Core3 would call it off at their verify
	local dist = BotJobs:distance(pBot, pHuman)

	if dist ~= nil and dist > self.tradeRange then
		if said ~= "tooFar" or (final and os.time() - readData(tkey(oid, "saidAt")) >= self.repeatAfter) then
			self:say(pBot, oid, partnerOid, "tooFar", name, offer.vars)
			writeStringData(tkey(oid, "said"), "tooFar")
			writeData(tkey(oid, "saidAt"), os.time())
		end

		self:reviewIn(pBot, oid, 3000)
		return
	end

	local wait = readData(tkey(oid, "graceUntil")) - getTimestampMilli()

	if wait > 0 then
		self:reviewIn(pBot, oid, wait + 200)
		return
	end

	self:deal(pBot, oid, pHuman, offer)
end

-- The offer is right: accept, and when they've verified, verify last. The body re-checks the offer (the same items
-- it looked at, at least the price) in the same locked step as the transfer; when that returns true, the items and
-- credits are the bot's, and it slices in this same step.
function BotSmuggler:deal(pBot, oid, pHuman, offer)
	local partnerOid = SceneObject(pHuman):getObjectID()
	local name = CreatureObject(pHuman):getFirstName()
	-- (the body checks a lone item by oid; a lot, by the offer being the one it looked at)
	local ok, why = botTradeVerify(pBot, offer.price, #offer.items == 1 and offer.items[1].oid or 0)

	if ok then
		print("BotJobs: " .. BotJobs:name(oid) .. " took " .. name .. "'s " .. #offer.items .. " piece(s) (" .. offer.vars.kind ..
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

-- The trade went through: slice each piece at once; each goes straight back to its owner
function BotSmuggler:slice(pBot, oid, pHuman, offer)
	writeData(tkey(oid, "step"), SLICING)

	local ownerOid = SceneObject(pHuman):getObjectID()
	local name = CreatureObject(pHuman):getFirstName()
	local cash = BotJobs:cash(pBot)
	local done, refund, results, held = 0, 0, {}, {}

	-- Tools for every piece (a clamp and a kit each), when the lot is bigger than the stock
	if botStockSlicingTools ~= nil and #offer.items > (math.floor(tonumber(self:setting("sliceToolStock")) or 5)) then
		botStockSlicingTools(pBot, #offer.items)
	end

	for _, item in ipairs(offer.items) do
		local result = botSlice(pBot, item.oid, pHuman, self:wanted(oid, ownerOid, item.kind)) or {}

		if result.ok then
			local text = self:describe(result)

			done = done + 1
			print("BotJobs: " .. BotJobs:name(oid) .. " sliced " .. name .. "'s " .. item.name .. ": " .. text ..
				(result.returned and "" or (" (handing it back by trade: " .. tostring(result.error) .. ")")))
			table.insert(results, #offer.items == 1 and text or (item.name .. " " .. text))

			if result.returned == false then
				table.insert(held, item.name)
			end
		else
			-- Not sliced (the piece went back with botSlice): its price goes back
			refund = refund + item.price
			print("BotJobs: " .. BotJobs:name(oid) .. " couldn't slice " .. name .. "'s " .. item.name .. ": " .. tostring(result.error))
		end
	end

	-- The payment is no tip, but anything over the price is: BotJobs:checkTips thanks them for that by name
	writeData(key(oid, "cash"), cash - (offer.paid - offer.price))

	if refund > 0 then
		print("BotJobs: " .. BotJobs:name(oid) .. " gives " .. name .. " " .. refund .. " credits back")
		botEnqueue(pBot, "tip", ownerOid, tostring(refund))
	end

	if done > 0 then
		writeData(key(oid, "lastPatient"), ownerOid)
		writeData(key(oid, "lastPatientAt"), os.time())
		writeData(key(oid, "slices"), readData(key(oid, "slices")) + done)

		if #offer.items == 1 then
			self:say(pBot, oid, ownerOid, "result", name, {item = offer.items[1].name, result = results[1]}, "happy")
		else
			self:say(pBot, oid, ownerOid, "resultLot", name, {result = table.concat(results, ", ")}, "happy")
		end

		if #held > 0 then
			self:say(pBot, oid, ownerOid, "giveBack", name, {item = table.concat(held, ", ")})
		end

		if refund > 0 then
			self:say(pBot, oid, ownerOid, "partFailed", name, {credits = credits(refund)})
		end

		createEvent(self.thankMs, "BotSmuggler", "thank", pBot, packArgs(readData(key(oid, "gen")), ownerOid))
	else
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

-- Slice types a customer can name, by the words they'd use
BotSmuggler.sliceTypes = {
	{kind = "armor", stat = "encumbrance", words = {"encumbrance", "encumb", "enc slice", "enc "}},
	{kind = "armor", stat = "effectiveness", words = {"effectiveness", "effective", "eff slice", "eff "}},
	{kind = "weapon", stat = "damage", words = {"damage", "dmg"}},
	{kind = "weapon", stat = "speed", words = {"speed", "attack speed", "faster"}},
}

-- The type this customer named for armor or weapons, "" for the roll
function BotSmuggler:wanted(oid, customerOid, kind)
	return readStringData(key(oid, "want:" .. customerOid .. ":" .. kind))
end

-- Spoken to: a slice type named is kept for this customer and confirmed (no brain reply for it)
function BotSmuggler:onSpoken(pBot, oid, pSpeaker, channel, text)
	local t = " " .. tostring(text or ""):lower() .. " "

	-- Only when it's about the slice: a short answer ("encumbrance"), or a sentence about slicing or wanting it
	local _, words = t:gsub("%S+", "")

	if words > 6 and t:find("slice", 1, true) == nil and t:find("want", 1, true) == nil and t:find("prefer", 1, true) == nil then
		return false
	end

	local customerOid = SceneObject(pSpeaker):getObjectID()
	local name = CreatureObject(pSpeaker):getFirstName()
	local chosen = {}

	for _, choice in ipairs(self.sliceTypes) do
		for _, word in ipairs(choice.words) do
			if chosen[choice.kind] == nil and t:find(word, 1, true) ~= nil then
				chosen[choice.kind] = choice.stat
			end
		end
	end

	if chosen.armor == nil and chosen.weapon == nil then
		if t:find(" random ", 1, true) ~= nil or t:find("either", 1, true) ~= nil or t:find("whatever", 1, true) ~= nil then
			deleteStringData(key(oid, "want:" .. customerOid .. ":armor"))
			deleteStringData(key(oid, "want:" .. customerOid .. ":weapon"))
			BotJobs:reply(pBot, customerOid, channel, self:line(oid, "chosenRandom", name))
			return true
		end

		return false
	end

	local said = {}

	for _, kind in ipairs({"armor", "weapon"}) do
		if chosen[kind] ~= nil then
			writeStringData(key(oid, "want:" .. customerOid .. ":" .. kind), chosen[kind])
			table.insert(said, (STATS[chosen[kind]] ~= nil and STATS[chosen[kind]][2] or chosen[kind]) .. " on " ..
				(kind == "armor" and "armor" or "weapons"))
		end
	end

	print("BotJobs: " .. BotJobs:name(oid) .. ": " .. name .. " wants " .. table.concat(said, ", "))
	BotJobs:reply(pBot, customerOid, channel, self:line(oid, "chosen", name, {choice = table.concat(said, " and ")}))

	return true
end

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
