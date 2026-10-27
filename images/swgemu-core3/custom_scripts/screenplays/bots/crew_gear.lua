-- Own crews, Part 3 (spec ~/github/swgemu/specs/2026-10-26-crew-grows/, "You gear them"): an own-crew bot fights with what its owner gives it.
-- Included from crew.lua (after BotCrew exists). The C++ side is patches/bots/BotGear.* and BotGearLua.*.
--
-- What the owner gives. A trade from the owner (only the owner; anyone else is politely refused) of weapons, armour, clothes, medicine,
-- grenades and camp kits: the bot opens the window, looks at the offer (nothing that is no gear), accepts, and verifies last when the
-- owner has (the same steps as the smuggler's). What came is recorded as given (botGearGiven): a given item is what "hand over your gear"
-- and the recruiter's let-go return.
--
-- What it uses. Once a trade is done it looks at each piece it can put on and equips it through a container transfer (botGearEquip: Core3's
-- own checks run: species, faction, encumbrance, skill; a weapon's certification is looked at first), when it is better than what it has:
--   - a weapon by damage per second, among the weapons of the family the role fights with (rifle, carbine, pistol; the commando's flame
--     thrower too; the tank's unarmed weapons, knuckles and the like), certified ones only; the tank with none is bare-handed;
--   - armour per slot by its rating (the average of its protections, the condition counted), when the slot is free or the new piece is
--     better; clothes only into a free slot.
-- When it can't it says why ("Not certified for that one.", "Too heavy for me.") and the piece stays in its pack. The weapon it fights with
-- is its mainWeapon (a template the crew job equips; the commando swaps to its acid rifle and back as before). A box learned later
-- (Part 2) looks again at what it holds, quietly.
--
-- Medicine and grenades are used as they are held: the turns pick the best pack of the kind in the pack that the bot's skill allows
-- (botGearPack), and nothing is stocked for it. It says when it is low and when it is out (stockTick), and when a piece is badly worn or
-- broken (wearTick): Core3's own decay, repaired by the owner.
--
-- Free gear stops for own crews: no restock, no repair, nothing made when it logs in (the factory), no camp kit made. What it was hired
-- with (a weapon, clothes, a few basic stims if its role has the medic box) it keeps. The Mos Eisley crew keeps its free master gear.
--
-- Console (output in the pod log):
--   runLuaFunction BotCrew:devGive:<first>:<template>[:<uses>]    an item in the bot's pack as if the owner had traded it
--   runLuaFunction BotCrew:devGear:<first>                        what it holds and wears, and the condition
--   runLuaFunction BotCrew:devWear:<first>:<oid>:<percent>        an item's condition left
--   runLuaFunction BotCrew:devReview:<first>                      look at the pack again as after a trade
--   runLuaFunction BotCrew:devEquip:<first>:<oid>                 put an item on, whatever it is (a weapon becomes the one it fights with)

BotCrew.gearReviewMs = 1500     -- after a change to the offer, or a trade, before the bot looks
BotCrew.gearTradeRange = 12     -- the owner must be this near (Core3 calls a trade off at 15 m)
BotCrew.stockEvery = 10         -- seconds between looks at the packs
BotCrew.stockGap = 20           -- seconds between a bot's stock lines
BotCrew.wearEvery = 30          -- seconds between looks at the condition
BotCrew.wearGap = 60            -- seconds between a bot's wear lines
BotCrew.wearBelow = 25          -- percent of the condition left that is "badly worn"
BotCrew.stockLow = {stim = 3, ranged = 3, revive = 1, state = 2, cure = 2, dot = 2, grenade = 2}

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function ckey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

local function put(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
end

local function putString(k, v)
	writeStringData(k, v)
end

local function bot(fn, ...)
	local f = _G[fn]

	if f == nil then
		return nil
	end

	return f(...)
end

-- The weapon families a role fights with
local FAMILIES = {
	tank = {unarmed = true},
	rifleman = {rifle = true},
	medic = {rifle = true},
	ranger = {carbine = true},
	squadleader = {carbine = true},
	entertainer = {pistol = true},
	commando = {carbine = true, heavy = true},
}

-- The kinds of medicine a pack template stands for (the crew job names its packs by template)
local function packKinds()
	local packs = BotCrew.packs
	local out = {}

	out[packs.stim] = "stim"
	out[packs.ranged] = "ranged"
	out[packs.revive] = "revive"
	out[packs.poison] = "cure:poison"
	out[packs.disease] = "cure:disease"
	out[packs.dotPoison] = "dot:poison"
	out[packs.dotDisease] = "dot:disease"
	out[packs.dotPoisonArea] = "dotarea:poison"
	out[packs.dotDiseaseArea] = "dotarea:disease"

	return out
end

BotCrew.packKindOf = packKinds()

BotCrew.stateKinds = {"state:stunned", "state:blinded", "state:dizzy", "state:intimidated"}

local STOCK_WORDS = {stim = "stims", ranged = "ranged stims", revive = "revive packs", state = "state packs", cure = "cure packs",
	dot = "damage packs", grenade = "grenades"}

-- Is a hand-back of the owner's gifts under way (the filter is set until the handover chain ends)? Then nothing given is put on
function BotCrew:giving(pBot)
	return botGearGiveMode ~= nil and botGearGiveMode(pBot) ~= ""
end

-- Its own: not the Mos Eisley crew's
function BotCrew:owned(oid)
	return self:ownerOf(oid) ~= 0
end

-- A pack of a template (or its kind, for an own-crew bot) it holds: its oid, or 0
function BotCrew:packHeld(pBot, oid, template)
	if self:owned(oid) then
		return self:ownPack(pBot, template)
	end

	return bot("botFindPack", pBot, template) or 0
end

-- The grenade to throw: the Mos Eisley commando's stock, else one an own-crew commando holds; 0 for none
function BotCrew:grenadeOid(pBot, oid)
	if self:owned(oid) then
		return self:ownGrenade(pBot)
	end

	return bot("botStockItem", pBot, self.grenade, self.grenadeStock) or 0
end

-- The best usable pack of a template's kind in an own-crew bot's pack: its oid, or 0
function BotCrew:ownPack(pBot, template)
	if botGearPack == nil then
		return 0
	end

	local kind = BotCrew.packKindOf[template]

	if kind == nil then
		return 0
	end

	return (botGearPack(pBot, kind)) or 0
end

-- Does the pack hold a usable pack of any of these kinds?
function BotCrew:ownHas(pBot, kinds)
	for _, kind in ipairs(kinds) do
		if ((botGearPack ~= nil and botGearPack(pBot, kind)) or 0) ~= 0 then
			return true
		end
	end

	return false
end

-- The state packs are named by state, the cures by what they cure
function BotCrew:ownHasFor(pBot, command)
	if command == "healstate" then
		return self:ownHas(pBot, self.stateKinds)
	elseif command == "curepoison" then
		return self:ownHas(pBot, {"cure:poison"})
	elseif command == "curedisease" then
		return self:ownHas(pBot, {"cure:disease"})
	end

	return true
end

-- A thrown grenade it holds: its oid, or 0
function BotCrew:ownGrenade(pBot)
	return (botGearPack ~= nil and (botGearPack(pBot, "grenade"))) or 0
end

-- The camp kit it holds that its camp skill and the order of the kits suit best: a template, or nil
function BotCrew:ownCampKit(pBot)
	if botGearCamps == nil then
		return nil
	end

	local held = botGearCamps(pBot) or {}
	local best, bestAt = nil, 0

	for _, template in ipairs(held) do
		local at = 1

		for i, camp in ipairs(BotCrewData.camps or {}) do
			if camp.kit == template then
				at = i + 1
			end
		end

		if best == nil or at > bestAt then
			best, bestAt = template, at
		end
	end

	return best
end

-- Logging in: the weapon it fights with is the one in its hand if that is one of its kind, else the best it holds; stock baselines; the
-- hand-back mode off
function BotCrew:gearStart(pBot, oid)
	if not self:owned(oid) or botGearList == nil then
		return
	end

	if botGearGiveEnd ~= nil then
		botGearGiveEnd(pBot)
	end

	putString(ckey(oid, "mainWeapon"), "")
	put(ckey(oid, "gearTradeWith"), 0)

	for _, kind in ipairs({"stim", "ranged", "revive", "state", "cure", "dot", "grenade"}) do
		put(ckey(oid, "stock" .. kind), -1)
	end

	local items = botGearList(pBot) or {}
	local best = self:bestWeapon(oid, items, true)

	if best ~= nil then
		putString(ckey(oid, "mainWeapon"), best.template)

		if not best.worn then
			local ok = botGearEquip(pBot, best.oid)

			print("BotJobs: " .. self:name(oid) .. " takes up " .. best.name .. (ok and "" or " (couldn't)"))
		end
	end
end

-- Its fighting weapon: of the role's families, certified, the best by damage per second. A worn one counts as it is; the acid rifle stays
-- in the pack for the commando's cones. items: botGearList. held: only what is in its hand or in the pack (not a different kind)
function BotCrew:bestWeapon(oid, items, includePack)
	local fits = FAMILIES[self:role(oid)] or {}
	local best = nil

	for _, item in ipairs(items) do
		if item.kind == "weapon" and fits[item.family] and item.certified and not item.broken and
			item.template:find("acid", 1, true) == nil and (item.worn or includePack) then
			if best == nil or item.power > best.power + 0.001 or (item.power > best.power - 0.001 and item.worn and not best.worn) then
				best = item
			end
		end
	end

	return best
end

-- Its owner, by oid, if online and near enough to talk to
function BotCrew:ownerHere(pBot, oid)
	local pOwner = getSceneObject(self:ownerOf(oid))

	if pOwner == nil then
		return nil
	end

	local dist = BotJobs:distance(pBot, pOwner)

	return pOwner, dist
end

-- A line to the owner: in group chat when it is grouped with them, else out loud when near, else by tell
function BotCrew:ownerSay(pBot, oid, kind, fill)
	local ownerOid = self:ownerOf(oid)
	local pOwner, dist = self:ownerHere(pBot, oid)

	if pOwner == nil then
		return
	end

	local name = self:firstName(pOwner)
	local member = self:group(pBot)
	local channel = (member ~= nil and member.byOid[ownerOid] ~= nil) and "group" or ((dist ~= nil and dist <= 20) and "spatial" or "tell")

	self:say(pBot, oid, ownerOid, channel, kind, name, fill)
end

-- Trades -------------------------------------------------------------------------------------------------------------------------

-- BotTrade's events for an own-crew bot (BotCrew:onEvent "trade"). false: not ours (a handover's, or the Mos Eisley crew's)
function BotCrew:gearTradeEvent(pBot, oid, pOther, detail)
	if detail == "bundleOpened" or detail == "bundleDone" or detail == "bundleCancelled" or detail == "bundleLost" or not self:owned(oid) or
		botTradeState == nil then
		return false
	end

	if detail == "requested" then
		self:tradeRequested(pBot, oid, pOther)
	elseif detail == "changed" then
		self:tradeReviewIn(pBot, oid, self.gearReviewMs)
	elseif detail == "partnerVerified" then
		self:tradeReview(pBot, oid)
	elseif detail == "aborted" then
		put(ckey(oid, "gearTradeWith"), 0)
		put(ckey(oid, "gearTradeSeq"), readData(ckey(oid, "gearTradeSeq")) + 1)
	end

	return true
end

function BotCrew:tradeRequested(pBot, oid, pHuman)
	if pHuman == nil then
		return
	end

	local humanOid = SceneObject(pHuman):getObjectID()
	local name = self:firstName(pHuman)

	-- A give-back trade of its own (it opened it): the window is the loot code's
	local state = botTradeState(pBot)

	if state ~= nil and (tonumber(state.give) or 0) ~= 0 then
		return
	end

	if humanOid ~= self:ownerOf(oid) then
		botTradeAbort(pBot)
		self:say(pBot, oid, humanOid, "spatial", "gearNotOwner", name, {owner = self:ownerName(oid)})
		print("BotJobs: " .. self:name(oid) .. " turns down a trade with " .. name .. ": it works for " .. self:ownerName(oid))
		return
	end

	local creature = CreatureObject(pBot)

	if creature:isInCombat() or creature:isDead() or creature:isIncapacitated() then
		botTradeAbort(pBot)
		self:say(pBot, oid, humanOid, "spatial", "gearBusy", name)
		return
	end

	local ok, why = botTradeAccept(pBot)

	if not ok then
		print("BotJobs: " .. self:name(oid) .. " couldn't open the trade " .. name .. " asked for: " .. tostring(why))
		return
	end

	put(ckey(oid, "gearTradeWith"), humanOid)
	put(ckey(oid, "gearTradeSaid"), 0)
	botFace(pBot, pHuman)
	self:say(pBot, oid, humanOid, "spatial", "gearOpen", name)
	print("BotJobs: " .. self:name(oid) .. " opens a trade with " .. name)
end

function BotCrew:tradeReviewIn(pBot, oid, ms)
	local seq = readData(ckey(oid, "gearTradeSeq")) + 1

	put(ckey(oid, "gearTradeSeq"), seq)
	createEvent(ms, "BotCrew", "tradeReviewLater", pBot, readData(key(oid, "gen")) .. ":" .. seq)
end

function BotCrew:tradeReviewLater(pBot, args)
	local gen, seq = tostring(args):match("^(%d+):(%d+)$")

	if gen == nil or not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if readData(ckey(oid, "gearTradeSeq")) ~= tonumber(seq) then
		return
	end

	self:tradeReview(pBot, oid)
end

-- Look at the offer; if it is right, accept (and verify last when the owner has)
function BotCrew:tradeReview(pBot, oid)
	local state = botTradeState(pBot)

	if state == nil or state.stage == nil or state.stage == "none" or state.stage == "requested" or (tonumber(state.give) or 0) ~= 0 then
		return
	end

	local partnerOid = math.floor(tonumber(state.partner) or 0)
	local pOwner = getSceneObject(partnerOid)

	if pOwner == nil then
		return
	end

	local name = self:firstName(pOwner)

	if partnerOid ~= self:ownerOf(oid) then
		botTradeAbort(pBot)
		return
	end

	local items = state.items or {}
	local credits = math.floor(tonumber(state.credits) or 0)

	if #items == 0 and credits == 0 then
		return
	end

	-- Credits would only be lost in its pack: gear is what it takes
	if credits > 0 then
		if readData(ckey(oid, "gearTradeSaid")) ~= -2 then
			put(ckey(oid, "gearTradeSaid"), -2)
			self:say(pBot, oid, partnerOid, "spatial", "gearNoCredits", name)
		end

		return
	end

	-- Nothing that is no gear
	for _, item in ipairs(items) do
		local kind, _, itemName = botGearKind(math.floor(tonumber(item) or 0))

		if kind == nil or kind == "other" then
			if readData(ckey(oid, "gearTradeSaid")) ~= item then
				put(ckey(oid, "gearTradeSaid"), item)
				self:say(pBot, oid, partnerOid, "spatial", "gearNoUse", name, {item = tostring(itemName or "that"):gsub("%%", "")})
			end

			return
		end
	end

	-- Core3 calls the trade off at their verify when they are further apart
	local dist = BotJobs:distance(pBot, pOwner)

	if dist ~= nil and dist > self.gearTradeRange then
		if readData(ckey(oid, "gearTradeSaid")) ~= -1 then
			put(ckey(oid, "gearTradeSaid"), -1)
			self:say(pBot, oid, partnerOid, "spatial", "gearTooFar", name)
		end

		self:tradeReviewIn(pBot, oid, 3000)
		return
	end

	local oids = {}

	for _, item in ipairs(items) do
		table.insert(oids, math.floor(tonumber(item) or 0))
	end

	local ok, why = botTradeVerify(pBot, 0, 0)

	if ok then
		-- (the oids it took are the bot's now: recorded as gifts, and looked at in a moment)
		if botGearGiven ~= nil then
			botGearGiven(pBot, oids)
		end

		put(ckey(oid, "gearTradeWith"), 0)
		print("BotJobs: " .. self:name(oid) .. " took " .. #oids .. " item(s) from " .. name)
		self:say(pBot, oid, partnerOid, "spatial", "gearThanks", name)
		self:reviewLater(pBot, oid, oids, self.gearReviewMs, false)
	elseif why == "changed" or why == "credits" or why == "items" then
		self:tradeReviewIn(pBot, oid, self.gearReviewMs)
	elseif why == "failed" then
		put(ckey(oid, "gearTradeWith"), 0)
		self:say(pBot, oid, partnerOid, "spatial", "gearFailed", name)
	end
end

-- What to put on ----------------------------------------------------------------------------------------------------------------

function BotCrew:reviewLater(pBot, oid, oids, ms, quiet)
	putString(ckey(oid, "reviewOids"), table.concat(oids or {}, ","))
	createEvent(ms, "BotCrew", "gearReviewNow", pBot, readData(key(oid, "gen")) .. ":" .. (quiet and "1" or "0"))
end

function BotCrew:gearReviewNow(pBot, args)
	local gen, quiet = tostring(args):match("^(%d+):(%d)$")

	if gen == nil or not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local only = {}

	for digits in string.gmatch(readStringData(ckey(oid, "reviewOids")), "%d+") do
		only[tonumber(digits)] = true
	end

	putString(ckey(oid, "reviewOids"), "")
	self:gearReview(pBot, oid, next(only) ~= nil and only or nil, quiet == "1")
end

-- The words for why an item was refused
local WHY = {cert = "gearCert", heavy = "gearHeavy", species = "gearSpecies", faction = "gearFaction", slot = "gearSlot", failed = "gearSlot"}

-- Look at the gifts in the pack. only: the oids of a trade just done (nil: all that are given); quiet: say nothing when nothing is put on
function BotCrew:gearReview(pBot, oid, only, quiet)
	if botGearList == nil or not self:owned(oid) or self:giving(pBot) then
		return
	end

	local items = botGearList(pBot) or {}
	local worn = {}
	local main = self:bestWeapon(oid, items, false)
	local fits = FAMILIES[self:role(oid)] or {}
	local said = 0

	-- What is worn, by each slot name it covers (a chest plate and a shirt can share one)
	local function wornBySlot()
		worn = {}

		for _, item in ipairs(botGearList(pBot) or {}) do
			if item.worn and (item.kind == "armor" or item.kind == "clothing") then
				for name in string.gmatch(item.slot, "[^|]+") do
					worn[name] = item
				end
			end
		end
	end

	wornBySlot()

	-- The best of what stands in the way of a piece
	local function inTheWay(item)
		local best = nil

		for name in string.gmatch(item.slot, "[^|]+") do
			if worn[name] ~= nil and (best == nil or worn[name].power > best.power) then
				best = worn[name]
			end
		end

		return best
	end

	local function say(kind, item)
		if quiet or said >= 3 then
			return
		end

		said = said + 1
		self:ownerSay(pBot, oid, kind, {item = (tostring(item.name or "that"):gsub("%%", ""))})
	end

	for _, item in ipairs(items) do
		local wanted = not item.worn and item.given and (only == nil or only[item.oid])

		if wanted and item.kind == "weapon" then
			if item.template:find("acid", 1, true) ~= nil then
				say("gearKeep", item)
			elseif not fits[item.family] then
				say("gearWrongKind", item)
			elseif not item.certified then
				say("gearCert", item)
			elseif main ~= nil and item.power <= main.power + 0.001 then
				say("gearNotBetter", item)
			else
				local ok, why = botGearEquip(pBot, item.oid)

				if ok then
					putString(ckey(oid, "mainWeapon"), item.template)
					main = item
					main.worn = true
					self:learn(pBot, oid, self:role(oid))
					say("gearWield", item)
					print("BotJobs: " .. self:name(oid) .. " takes up " .. item.name .. " (" .. string.format("%.1f", item.power) .. " dps)")
				else
					say(WHY[why] or "gearSlot", item)
				end
			end
		elseif wanted and item.kind == "armor" then
			local current = inTheWay(item)

			if current ~= nil and item.power <= current.power + 0.001 then
				say("gearNotBetter", item)
			else
				local ok, why = botGearEquip(pBot, item.oid)

				if ok then
					wornBySlot()
					say("gearWear", item)
					print("BotJobs: " .. self:name(oid) .. " puts on " .. item.name)
				else
					say(WHY[why] or "gearSlot", item)
				end
			end
		elseif wanted and item.kind == "clothing" then
			if inTheWay(item) == nil then
				local ok, why = botGearEquip(pBot, item.oid)

				if ok then
					wornBySlot()
					say("gearWear", item)
				else
					say(WHY[why] or "gearSlot", item)
				end
			else
				say("gearKeep", item)
			end
		end
	end
end

-- How low the packs are, how worn the gear --------------------------------------------------------------------------------------

local STOCK_KINDS = {
	{kind = "stim", ability = "stims", pack = "stim"},
	{kind = "ranged", ability = "rangedStims", pack = "ranged"},
	{kind = "revive", ability = "revive", pack = "revive"},
	{kind = "state", ability = "states", pack = nil},
	{kind = "cure", ability = "curePoison", pack = nil},
	{kind = "dot", ability = "poisonPack", pack = nil},
	{kind = "grenade", ability = "grenade", pack = "grenade"},
}

-- The uses it holds of a kind
function BotCrew:stockOf(pBot, kind)
	local total = 0

	if kind == "state" then
		for _, k in ipairs(self.stateKinds) do
			local _, uses = botGearPack(pBot, k)

			total = total + (uses or 0)
		end
	elseif kind == "cure" then
		for _, k in ipairs({"cure:poison", "cure:disease"}) do
			local _, uses = botGearPack(pBot, k)

			total = total + (uses or 0)
		end
	elseif kind == "dot" then
		for _, k in ipairs({"dot:poison", "dot:disease"}) do
			local _, uses = botGearPack(pBot, k)

			total = total + (uses or 0)
		end
	else
		local _, uses = botGearPack(pBot, kind)

		total = uses or 0
	end

	return total
end

-- Nothing in its hands (what it fought with went back to its owner, or broke into the pack): the best weapon of its kind it holds goes up
function BotCrew:armCheck(pBot, oid)
	local creature = CreatureObject(pBot)

	if self:giving(pBot) then
		return
	end

	-- (the entertainer's flute is in its hand while it plays: the pistol comes back with perfPistol)
	if next(FAMILIES[self:role(oid)] or {}) == nil or creature:isInCombat() or creature:isPlayingMusic() or readData(ckey(oid, "instrument")) == 1 then
		return
	end

	local items = botGearList(pBot) or {}

	for _, item in ipairs(items) do
		if item.kind == "weapon" and item.worn then
			return
		end
	end

	local best = self:bestWeapon(oid, items, true)

	if best == nil then
		putString(ckey(oid, "mainWeapon"), "")
		return
	end

	local ok = botGearEquip(pBot, best.oid)

	putString(ckey(oid, "mainWeapon"), best.template)
	print("BotJobs: " .. self:name(oid) .. " takes up " .. best.name .. (ok and "" or " (couldn't)"))
end

-- From the tick: "low" and "out" for what the bot uses, and a weapon in its hand
function BotCrew:stockTick(pBot, oid, now)
	if not self:owned(oid) or botGearPack == nil or now - readData(ckey(oid, "stockAt")) < self.stockEvery then
		return
	end

	put(ckey(oid, "stockAt"), now)
	self:armCheck(pBot, oid)

	for _, entry in ipairs(STOCK_KINDS) do
		if self:can(oid, entry.ability) then
			local have = self:stockOf(pBot, entry.kind)
			local before = readData(ckey(oid, "stock" .. entry.kind))
			local low = self.stockLow[entry.kind] or 2

			put(ckey(oid, "stock" .. entry.kind), have)

			if before >= 0 and have < before and now - readData(ckey(oid, "stockSaidAt")) >= self.stockGap then
				local kind = nil

				if have == 0 then
					kind = "stockOut"
				elseif have <= low and before > low then
					kind = "stockLow"
				end

				if kind ~= nil and CreatureObject(pBot):isGrouped() then
					put(ckey(oid, "stockSaidAt"), now)
					self:groupSay(pBot, oid, kind, nil, {what = STOCK_WORDS[entry.kind], n = tostring(have)})
					print("BotJobs: " .. self:name(oid) .. " says " .. kind .. " for " .. entry.kind .. " (" .. have .. " left)")

					return
				end
			end
		end
	end
end

-- From the tick: a worn or broken weapon or piece of armour
function BotCrew:wearTick(pBot, oid, now)
	if not self:owned(oid) or botGearList == nil or now - readData(ckey(oid, "wearAt")) < self.wearEvery then
		return
	end

	put(ckey(oid, "wearAt"), now)

	local said = false

	for _, item in ipairs(botGearList(pBot) or {}) do
		if item.worn and (item.kind == "weapon" or item.kind == "armor") then
			local k = "gearWear" .. item.oid
			local was = readData(ckey(oid, k))
			local state = item.broken and 2 or (item.left < self.wearBelow and 1 or 0)

			if state < was then
				-- (repaired, or traded away and back: it may say so again when it wears down)
				put(ckey(oid, k), state)
			elseif state > was and not said and now - readData(ckey(oid, "wearSaidAt")) >= self.wearGap then
				-- (a line held back by the gap is said at a later look: the state is only recorded when it is said)
				said = true
				put(ckey(oid, k), state)
				put(ckey(oid, "wearSaidAt"), now)
				self:ownerSay(pBot, oid, state == 2 and "gearBroken" or "gearWorn", {item = (tostring(item.name or "gear"):gsub("%%", ""))})
				print("BotJobs: " .. self:name(oid) .. "'s " .. item.name .. " is " .. (state == 2 and "broken" or "badly worn") .. " (" .. item.left .. "% left)")
			end
		end
	end
end

-- Giving it back ----------------------------------------------------------------------------------------------------------------

BotCrew.giveKinds = {
	{words = {"gear", "equipment", "stuff", "things", "kit"}, filter = "all"},
	{words = {"armor", "armour", "plates"}, filter = "armor"},
	{words = {"clothes", "clothing", "outfit"}, filter = "clothing"},
	{words = {"weapon", "weapons", "gun", "guns", "blaster", "blasters"}, filter = "weapon"},
	{words = {"rifle", "rifles"}, filter = "rifle"},
	{words = {"carbine", "carbines"}, filter = "carbine"},
	{words = {"pistol", "pistols"}, filter = "pistol"},
	{words = {"stims", "stim", "stimpacks", "stimpack", "stim packs"}, filter = "stim"},
	{words = {"medicine", "medpacks", "medpack", "packs", "pack", "meds"}, filter = "medicine"},
	{words = {"grenades", "grenade"}, filter = "grenade"},
	{words = {"camp kit", "camp kits", "camp"}, filter = "camp"},
}

-- "give me your rifle", "hand over your armour", "give me back my stims": the filter it asks for, else nil
function BotCrew:gearGiveWanted(text)
	local t = " " .. (tostring(text or ""):lower():gsub("[^%w' ]", " "):gsub("%s+", " ")) .. " "
	local asks = false

	for _, verb in ipairs({" hand over ", " hand me ", " give me ", " give back ", " hand it back ", " return ", " trade me ", " take back "}) do
		if t:find(verb, 1, true) ~= nil then
			asks = true
			break
		end
	end

	if not asks or (t:find(" your ", 1, true) == nil and t:find(" my ", 1, true) == nil) then
		return nil
	end

	for _, entry in ipairs(self.giveKinds) do
		for _, word in ipairs(entry.words) do
			if t:find(" " .. word .. " ", 1, true) ~= nil then
				return entry.filter
			end
		end
	end

	return nil
end

local GIVE_WORDS = {all = "gear", armor = "armour", clothing = "clothes", weapon = "weapons", rifle = "rifle", carbine = "carbine",
	pistol = "pistol", stim = "stims", medicine = "medicine", grenade = "grenades", camp = "camp kit"}

local MEDICINE = {stim = true, ranged = true, state = true, cure = true, curearea = true, revive = true, dot = true, dotarea = true,
	enhance = true, wound = true, medicine = true}

-- Does a listed item (botGearList) answer to the filter? The same as BotGear's
local function matches(filter, item)
	if filter == "all" or filter == item.kind or (item.family ~= "" and filter == item.family) then
		return true
	end

	if filter == "medicine" or filter == "packs" then
		return MEDICINE[item.kind] == true
	end

	return filter == "gear" and (item.kind == "weapon" or item.kind == "armor")
end

-- How many of its gifts answer to the filter (worn ones too)
function BotCrew:giveCount(pBot, filter)
	local n = 0

	for _, item in ipairs(botGearList ~= nil and botGearList(pBot) or {}) do
		if item.given and matches(filter, item) then
			n = n + 1
		end
	end

	return n
end

-- Said to this bot (or to the group): the gifts that match go back to the owner by a trade, through the loot code's handover. The first
-- crew bot of the group says there is nothing when no bot of the group has any
function BotCrew:gearGiveSpoken(pBot, oid, pSpeaker, channel, filter, g)
	local speakerOid = SceneObject(pSpeaker):getObjectID()
	local name = self:firstName(pSpeaker)

	if speakerOid ~= self:ownerOf(oid) then
		return false
	end

	local count = self:giveCount(pBot, filter)

	if count == 0 then
		local first = g == nil or g.crew[1] == nil or g.crew[1].oid == oid

		if channel ~= "group" or first then
			local anyone = false

			for _, m in ipairs(g ~= nil and channel == "group" and g.crew or {}) do
				if m.oid ~= oid and self:owned(m.oid) and self:giveCount(m.p, filter) > 0 then
					anyone = true
				end
			end

			if not anyone then
				self:say(pBot, oid, speakerOid, channel, "giveNone", name, {what = GIVE_WORDS[filter] or "gear"})
			end
		end

		return true
	end

	count = botGearGiveBack ~= nil and botGearGiveBack(pBot, filter) or 0

	if count == 0 then
		return true
	end

	-- (the weapon it fought with may be on its way back: it keeps no name of it, and takes nothing up until the hand-back is over)
	local armed = false

	for _, item in ipairs(botGearList(pBot) or {}) do
		if item.kind == "weapon" and item.worn then
			armed = true
		end
	end

	if not armed then
		putString(ckey(oid, "mainWeapon"), "")
	end

	print("BotJobs: " .. self:name(oid) .. " is asked for its " .. filter .. " by " .. name .. " (" .. count .. " item(s))")
	self:say(pBot, oid, speakerOid, channel, "giveGear", name, {what = GIVE_WORDS[filter] or "gear", n = tostring(count)})
	self:lootStartOffer(pBot, oid, speakerOid, self.offerRequestSeconds, nil)

	return true
end

-- Development -------------------------------------------------------------------------------------------------------------------

local SHORT = {
	stim = "object/tangible/medicine/crafted/crafted_stimpack_sm_s1_e.iff",
	stima = "object/tangible/medicine/crafted/crafted_stimpack_sm_s1_a.iff",
	stimc = "object/tangible/medicine/crafted/crafted_stimpack_sm_s1_c.iff",
	rstim = "object/tangible/medicine/crafted/medpack_grenade_damage_e.iff",
	revive = "object/tangible/medicine/crafted/medpack_revive.iff",
	cure = "object/tangible/medicine/crafted/medpack_cure_poison_c.iff",
	grenade = "object/weapon/ranged/grenade/grenade_fragmentation.iff",
	camp = "object/tangible/scout/camp/camp_basic.iff",
	rifle = "object/weapon/ranged/rifle/rifle_t21.iff",
	rifleold = "object/weapon/ranged/rifle/rifle_dlt20.iff",
	carbine = "object/weapon/ranged/carbine/carbine_e11.iff",
	pistol = "object/weapon/ranged/pistol/pistol_dh17.iff",
}

local function devBot(first)
	return botGetCreature ~= nil and botGetCreature(first or "") or nil
end

function BotCrew:devGive(first, template, uses)
	local pBot = devBot(first)

	if pBot == nil or botGearDevGive == nil or template == nil then
		print("BotCrew: usage devGive:<online bot>:<template or short name>[:<uses>]")
		return
	end

	local full = SHORT[template] or template
	local oid = botGearDevGive(pBot, full, tonumber(uses or "") or 0)

	print("BotCrew: " .. first .. " was given " .. full .. ": oid " .. tostring(oid))
end

function BotCrew:devGear(first)
	local pBot = devBot(first)

	if pBot == nil or botGearList == nil then
		print("BotCrew: usage devGear:<online bot>")
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	print("BotCrew: " .. first .. " mainWeapon " .. readStringData(ckey(oid, "mainWeapon")) .. ", owner " .. tostring(self:ownerOf(oid)))

	for _, item in ipairs(botGearList(pBot) or {}) do
		print(string.format("BotCrew:   %d %s %s%s %s%s uses %d req %d usable %s power %.1f left %d%%%s cert %s | %s", item.oid, item.kind,
			item.family ~= "" and (item.family .. " ") or "", item.name, item.worn and "worn" or "pack", item.given and " given" or "",
			item.uses, item.required, tostring(item.usable), item.power, item.left, item.broken and " BROKEN" or "", tostring(item.certified),
			item.template))
	end
end

function BotCrew:devWear(first, oid, percent)
	local pBot = devBot(first)

	if pBot == nil or botGearDevCondition == nil then
		print("BotCrew: usage devWear:<online bot>:<item oid>:<percent left>")
		return
	end

	print("BotCrew: " .. first .. " item " .. tostring(oid) .. " condition " .. tostring(percent) .. "%: " ..
		tostring(botGearDevCondition(pBot, tonumber(oid), tonumber(percent))))
end

function BotCrew:devReview(first)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrew: usage devReview:<online bot>")
		return
	end

	self:gearReview(pBot, SceneObject(pBot):getObjectID(), nil, false)
end

function BotCrew:devEquip(first, itemOid)
	local pBot = devBot(first)

	if pBot == nil or botGearEquip == nil then
		print("BotCrew: usage devEquip:<online bot>:<item oid>")
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local ok, why = botGearEquip(pBot, tonumber(itemOid))

	for _, item in ipairs(botGearList(pBot) or {}) do
		if item.oid == tonumber(itemOid) and item.kind == "weapon" and ok then
			putString(ckey(oid, "mainWeapon"), item.template)
		end
	end

	print("BotCrew: " .. first .. " equips " .. tostring(itemOid) .. ": " .. tostring(ok) .. " " .. tostring(why))
end
