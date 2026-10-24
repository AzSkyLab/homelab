-- Bot players (Phase 7): the crew loots, the ranger harvests, and what they picked up is handed over by trade.
-- Included from crew.lua (after BotCrew exists). Spec: ~/github/swgemu/specs/2026-10-24-crew-swoops-missions/ (4, 5, 6).
--
-- The kills: each crew bot notes what it fights (BotCrew:lootNote), and the players' targets are noted by scanHuman, in
-- lists of the last few oids. After a fight (every crew step that is out of combat, BotCrew:lootTurn) the group's dead
-- creatures are worked through, one corpse at a time:
--   1. the ranger walks up and harvests it (botHarvest: Core3's own harvest, the type the creature has most of);
--   2. then one crew bot, the first that isn't the ranger, loots it (botLootCorpse: everything into its pack, the
--      credits through Core3's group split to the humans). Looting waits for the harvest, as it did for players.
-- Corpses of players and other groups' are refused by the binding. A corpse is given up on after lootGiveUp seconds.
--
-- Goods: what a bot holds that isn't its gear (botGoods: what it looted, and every resource container). Handing over
-- (botOfferGoods: a trade window opens on the player's client, the bot has put everything in and accepted; the player
-- accepts) happens:
--   - when a group member says "hand it over" / "give me the loot" / "trade me" (each bot with goods offers);
--   - when the group breaks up, a bot is dismissed or sent home: before it heads home;
--   - when the bot is regrouped, for goods it still holds from before.
-- An offer is one chain of events per bot (lootOfferStep): it walks up to the player, offers, waits for the trade's
-- result (the "trade" events bundleDone / bundleCancelled from BotTrade), offers the rest in another trade, and ends.
-- The goods are never sold, dropped or kept for the bot: a cancelled trade leaves them in its pack for the next ask.

BotCrew.lootEvery = 2           -- seconds between a bot's loot and harvest actions
BotCrew.lootGiveUp = 120        -- seconds after a corpse is found dead until the crew stops trying for it
BotCrew.lootFromLeader = 70     -- a corpse further than this from the leader is left for now
BotCrew.harvestReach = 5        -- the ranger walks up to this far from a corpse (Core3 allows 7 m)
BotCrew.lootReach = 6           -- a looter walks up to this far (Core3 allows 16 m)
BotCrew.lootTries = 30          -- actions on one corpse before it is dropped
BotCrew.lootSayEvery = 20       -- seconds between a bot's loot and harvest lines
BotCrew.victimsKept = 16        -- kills remembered per fighter
BotCrew.offerRange = 12         -- a bot offers within this of the player (Core3 refuses a trade at 15 m)
BotCrew.offerStepMs = 2500
BotCrew.offerRoomMs = 5000        -- how often it looks again for room in the player's pack
BotCrew.offerRequestSeconds = 60   -- an asked-for handover gives up after this long
BotCrew.offerLeaveSeconds = 75     -- a handover before heading home
BotCrew.handoverWords = {"hand it over", "hand it all over", "hand over", "give me the loot", "give me my loot",
	"give me the goods", "give me what you", "trade me", "give me the hides", "give me the resources", "hand me the loot",
	"hand me the goods", "hand me what you", "hand me my loot", "give it over", "give me your loot", "give me everything"}

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function lkey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

local function packArgs(...)
	return table.concat({...}, ":")
end

local function corpseKey(oid, field)
	return "crew:corpse:" .. oid .. ":" .. field
end

local function listOf(text)
	local out = {}

	for digits in string.gmatch(text or "", "%d+") do
		table.insert(out, tonumber(digits))
	end

	return out
end

-- Oids in a string: writeStringData runs string.format on its value, so only digits and commas go in
local function addToList(k, oid, keep)
	local list = listOf(readStringData(k))

	for _, known in ipairs(list) do
		if known == oid then
			return
		end
	end

	table.insert(list, oid)

	while #list > keep do
		table.remove(list, 1)
	end

	writeStringData(k, table.concat(list, ","))
end

local function putInt(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
end

-- Kills

-- A crew bot's own target (BotCrew:fight)
function BotCrew:lootNote(oid, targetOid)
	if targetOid ~= nil and targetOid ~= 0 then
		addToList(lkey(oid, "victims"), targetOid, self.victimsKept)
	end
end

-- What a player is fighting (BotCrew:scanHuman)
function BotCrew:lootNoteHuman(humanOid, targetOid)
	if targetOid ~= nil and targetOid ~= 0 then
		addToList("crew:human:" .. humanOid .. ":victims", targetOid, self.victimsKept)
	end
end

-- The group's dead creatures still to work on, oldest first: {oid, p, harvest, loot} where harvest and loot say
-- what is still to do. Gives up on the ones found dead too long ago.
function BotCrew:lootCorpses(g, pLeader, now)
	local seen, out = {}, {}
	local lists = {}

	for _, m in ipairs(g.crew) do
		table.insert(lists, readStringData(lkey(m.oid, "victims")))
	end

	for _, m in ipairs(g.humans) do
		table.insert(lists, readStringData("crew:human:" .. m.oid .. ":victims"))
	end

	for _, text in ipairs(lists) do
		for _, corpseOid in ipairs(listOf(text)) do
			if not seen[corpseOid] and readData(corpseKey(corpseOid, "done")) ~= 1 then
				seen[corpseOid] = true

				local p = getSceneObject(corpseOid)

				if p == nil or not SceneObject(p):isCreatureObject() or SceneObject(p):isPlayerCreature() then
					putInt(corpseKey(corpseOid, "done"), 1)
				elseif CreatureObject(p):isDead() then
					if readData(corpseKey(corpseOid, "seen")) == 0 then
						putInt(corpseKey(corpseOid, "seen"), now)
					end

					local age = now - readData(corpseKey(corpseOid, "seen"))
					local away = BotJobs:distance(pLeader, p)

					if age > self.lootGiveUp or readData(corpseKey(corpseOid, "tries")) >= self.lootTries then
						putInt(corpseKey(corpseOid, "done"), 1)
					elseif away ~= nil and away <= self.lootFromLeader then
						table.insert(out, {oid = corpseOid, p = p, seen = readData(corpseKey(corpseOid, "seen")),
							harvest = readData(corpseKey(corpseOid, "harv")) ~= 1,
							loot = readData(corpseKey(corpseOid, "loot")) ~= 1})
					end
				end
			end
		end
	end

	table.sort(out, function(a, b) return a.seen < b.seen or (a.seen == b.seen and a.oid < b.oid) end)

	return out
end

-- The crew member who harvests (a ranger with the scout skill, alive), and who loots (the first other crew member
-- that is alive, else the ranger)
function BotCrew:lootRoles(g)
	local harvester, looter, any = nil, nil, nil

	for _, m in ipairs(g.crew) do
		if not CreatureObject(m.p):isDead() then
			any = any or m

			if m.job == "ranger" then
				if CreatureObject(m.p):hasSkill("outdoors_scout_novice") then
					harvester = m
				end
			elseif looter == nil then
				looter = m
			end
		end
	end

	return harvester, looter or harvester or any
end

local function say(self, pBot, oid, kind, fill)
	local now = os.time()

	if now - readData(lkey(oid, "lootSayAt")) < self.lootSayEvery then
		return
	end

	putInt(lkey(oid, "lootSayAt"), now)
	self:groupSay(pBot, oid, kind, nil, fill)
end

-- One loot or harvest action for this bot, if it is the one to do the next. True when the bot is busy with it (the
-- caller then doesn't send it back to follow the leader).
function BotCrew:lootTurn(pBot, oid, g, pLeader, now)
	-- (a build without the Phase 7 bindings still runs the rest)
	if botLootCorpse == nil or g == nil or pLeader == nil or readStringData(lkey(oid, "order")) == "stay" then
		return false
	end

	if CreatureObject(pBot):isInCombat() or CreatureObject(pBot):isDead() or self:groupFighting(g) then
		return false
	end

	local corpses = self:lootCorpses(g, pLeader, now)

	if #corpses == 0 then
		return false
	end

	local harvester, looter = self:lootRoles(g)
	local isHarvester = harvester ~= nil and harvester.oid == oid
	local isLooter = looter ~= nil and looter.oid == oid

	-- The ranger: the first corpse not harvested yet
	if isHarvester then
		for _, c in ipairs(corpses) do
			if c.harvest then
				return self:harvestStep(pBot, oid, c, now)
			end
		end
	end

	-- The looter: the first corpse that has been harvested (or has nobody to harvest it)
	if isLooter then
		for _, c in ipairs(corpses) do
			if c.loot and (not c.harvest or harvester == nil) then
				return self:lootStep(pBot, oid, c, now)
			end
		end
	end

	return false
end

-- Walk up to the corpse, or false if the bot is within reach
function BotCrew:lootApproach(pBot, oid, c, reach, now)
	local dist = BotJobs:distance(pBot, c.p)

	if dist == nil then
		putInt(corpseKey(c.oid, "done"), 1)
		return false, nil
	end

	if dist > reach then
		self:walkNear(pBot, oid, c.p, dist, now, math.max(reach - 2, 1))
		return true, dist
	end

	return false, dist
end

function BotCrew:harvestStep(pBot, oid, c, now)
	if now - readData(lkey(oid, "lootAt")) < self.lootEvery then
		return true
	end

	-- A creature the ranger can't harvest isn't worth a walk
	if not SceneObject(c.p):isCreature() then
		putInt(corpseKey(c.oid, "harv"), 1)
		return false
	end

	local walking = self:lootApproach(pBot, oid, c, self.harvestReach, now)

	putInt(corpseKey(c.oid, "tries"), readData(corpseKey(c.oid, "tries")) + 1)

	if walking then
		return true
	end

	putInt(lkey(oid, "lootAt"), now)
	self:stopMoving(pBot)

	local r = botHarvest(pBot, c.oid)

	if r ~= nil and r.ok then
		putInt(corpseKey(c.oid, "harv"), 1)
		self:goodsOf(pBot, oid)
		say(self, pBot, oid, "harvested", {amount = tostring(r.amount), kind = r.kind, what = r.resource})
	elseif r ~= nil and r.error == "too far" then
		-- Not yet: another step
	else
		-- Nothing to harvest, or the ranger can't: on to the loot
		putInt(corpseKey(c.oid, "harv"), 1)
	end

	return true
end

function BotCrew:lootStep(pBot, oid, c, now)
	if now - readData(lkey(oid, "lootAt")) < self.lootEvery then
		return true
	end

	local walking = self:lootApproach(pBot, oid, c, self.lootReach, now)

	putInt(corpseKey(c.oid, "tries"), readData(corpseKey(c.oid, "tries")) + 1)

	if walking then
		return true
	end

	putInt(lkey(oid, "lootAt"), now)
	self:stopMoving(pBot)

	local r = botLootCorpse(pBot, c.oid)

	if r == nil then
		return false
	end

	if r.ok then
		-- Done when the corpse is empty, the pack is full, or nothing more would move
		if r.left == 0 or r.full or r.moved == 0 then
			putInt(corpseKey(c.oid, "loot"), 1)
			putInt(corpseKey(c.oid, "done"), 1)
		end

		if r.moved > 0 then
			self:goodsOf(pBot, oid)
			say(self, pBot, oid, "looted", {n = tostring(r.moved)})
		end

		if r.full then
			-- No room: it hands over what it has now
			local leaderOid = readData(lkey(oid, "leader"))

			if leaderOid ~= 0 then
				self:lootStartOffer(pBot, oid, leaderOid, self.offerRequestSeconds, "lootFull")
			end
		end
	elseif r.error == "too far" then
		-- Another step
	else
		-- Not this group's, a player's, alive: nothing for the crew here
		putInt(corpseKey(c.oid, "loot"), 1)
		putInt(corpseKey(c.oid, "done"), 1)
	end

	return true
end

-- Goods

-- {oid, name, quantity, resource, tradable} for what the bot holds that isn't its gear
function BotCrew:goodsOf(pBot, oid)
	local goods = botGoods ~= nil and botGoods(pBot) or {}
	local tradable = 0

	for _, item in ipairs(goods) do
		if item.tradable then
			tradable = tradable + 1
		end
	end

	putInt(lkey(oid, "goodsN"), tradable)

	return goods, tradable
end

-- "40 Mammalian Hide, a lightsaber crystal and 2 other things": what the goods are, short
function BotCrew:goodsSummary(goods)
	local parts, resources, items, names = {}, {}, 0, {}

	for _, item in ipairs(goods) do
		if item.tradable then
			if item.resource then
				table.insert(resources, item.quantity .. " " .. item.name)
			else
				items = items + 1
				table.insert(names, item.name)
			end
		end
	end

	for i = 1, math.min(#resources, 2) do
		table.insert(parts, resources[i])
	end

	if #resources > 2 then
		table.insert(parts, (#resources - 2) .. " more resources")
	end

	if items == 1 then
		table.insert(parts, "a " .. names[1])
	elseif items > 1 then
		table.insert(parts, items .. " items")
	end

	if #parts == 0 then
		return "nothing"
	elseif #parts == 1 then
		return (parts[1]:gsub("%%", ""))
	end

	local last = table.remove(parts)

	return ((table.concat(parts, ", ") .. " and " .. last):gsub("%%", ""))
end

-- Is the text a request to hand the goods over?
function BotCrew:handoverWanted(text)
	local t = (tostring(text or ""):lower():gsub("[^%w' ]", " "))

	for _, words in ipairs(self.handoverWords) do
		if t:find(words, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- A member of the bot's group, by oid
function BotCrew:lootMember(pBot, playerOid)
	local g = self:group(pBot)

	if g == nil then
		return nil, nil
	end

	return g.byOid[playerOid], g
end

-- Does another crew member of the group hold goods?
function BotCrew:othersHold(g, oid)
	for _, m in ipairs(g.crew) do
		if m.oid ~= oid and readData(lkey(m.oid, "goodsN")) > 0 then
			return true
		end
	end

	return false
end

-- Group chat that asks for the loot: the bots with goods answer, and if none has any, the first crew member says so
-- (BotCrew:groupAddressed)
function BotCrew:handoverAnswers(oid, g)
	if readData(lkey(oid, "goodsN")) > 0 then
		return true
	end

	return not self:othersHold(g, oid) and g.crew[1] ~= nil and g.crew[1].oid == oid
end

-- BotCrew:groupAddressed: "hand it over" in group chat from a human in the bot's group. Every bot with goods offers
-- them; if none has any, the first crew member says so
function BotCrew:handoverSpoken(pBot, oid, pSpeaker, channel, text, g)
	if pSpeaker == nil or not self:handoverWanted(text) then
		return false
	end

	local playerOid = SceneObject(pSpeaker):getObjectID()
	local member = g.byOid[playerOid]

	if member == nil or not member.human then
		return false
	end

	local name = self:firstName(pSpeaker)
	local goods, count = self:goodsOf(pBot, oid)

	if count == 0 then
		-- Only the one that answers for the group says it has nothing
		if self:handoverAnswers(oid, g) then
			self:say(pBot, oid, playerOid, channel, "handoverNone", name)
		end

		return true
	end

	print("BotJobs: " .. self:name(oid) .. " is asked for the loot by " .. name .. " (" .. count .. " item(s))")
	self:lootStartOffer(pBot, oid, playerOid, self.offerRequestSeconds, nil)

	return true
end

-- The offer chain

local function offerCurrent(oid, seq)
	return readData(lkey(oid, "offerSeq")) == seq and readData(lkey(oid, "offerFor")) ~= 0 and
		os.time() <= readData(lkey(oid, "offerUntil"))
end

-- Is this bot busy handing over (so it doesn't go home yet)?
function BotCrew:lootHolding(oid)
	return readData(lkey(oid, "offerFor")) ~= 0 and os.time() <= readData(lkey(oid, "offerUntil"))
end

-- Starts the chain: opener is the line kind for the first offer ("lootFull" and so on), or nil for the usual
function BotCrew:lootStartOffer(pBot, oid, playerOid, seconds, opener)
	if self:lootHolding(oid) and readData(lkey(oid, "offerFor")) == playerOid then
		return
	end

	local seq = readData(lkey(oid, "offerSeq")) + 1

	putInt(lkey(oid, "offerSeq"), seq)
	putInt(lkey(oid, "offerFor"), playerOid)
	putInt(lkey(oid, "offerUntil"), os.time() + seconds)
	putInt(lkey(oid, "offerOpen"), 0)
	putInt(lkey(oid, "offerTries"), 0)
	putInt(lkey(oid, "offerBatches"), 0)
	putInt(lkey(oid, "offerSaid"), 0)

	if opener ~= nil then
		putInt(lkey(oid, "offerOpener"), opener == "lootFull" and 1 or 2)
	else
		putInt(lkey(oid, "offerOpener"), 0)
	end

	createEvent(300, "BotCrew", "lootOfferStep", pBot, packArgs(readData(key(oid, "gen")), seq))
end

local function splitArgs(args)
	local out = {}

	for part in string.gmatch(args or "", "[^:]+") do
		table.insert(out, part)
	end

	return out
end

-- The chain ends: a bot on its way home goes now
function BotCrew:lootEndOffer(pBot, oid, why)
	putInt(lkey(oid, "offerFor"), 0)
	putInt(lkey(oid, "offerOpen"), 0)

	if readStringData(lkey(oid, "mode")) == "leaving" then
		createEvent(1500, "BotCrew", "goHome", pBot, tostring(readData(key(oid, "gen"))))
	end

	print("BotJobs: " .. self:name(oid) .. " ends its handover (" .. why .. ")")
end

function BotCrew:lootOfferStep(pBot, args)
	local a = splitArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local seq = tonumber(a[2])

	if readData(lkey(oid, "offerSeq")) ~= seq or readData(lkey(oid, "offerFor")) == 0 then
		return
	end

	local now = os.time()
	local playerOid = readData(lkey(oid, "offerFor"))

	if now > readData(lkey(oid, "offerUntil")) then
		if readData(lkey(oid, "offerOpen")) == 1 and botCancelOffer ~= nil then
			botCancelOffer(pBot)
		end

		self:lootEndOffer(pBot, oid, "timed out")
		return
	end

	local function again(ms)
		createEvent(ms or self.offerStepMs, "BotCrew", "lootOfferStep", pBot, args)
	end

	-- The window is open: the trade's own result ends the wait (lootTradeEvent)
	if readData(lkey(oid, "offerOpen")) == 1 then
		again()
		return
	end

	local pPlayer = getSceneObject(playerOid)

	if pPlayer == nil then
		self:lootEndOffer(pBot, oid, "the player is gone")
		return
	end

	if CreatureObject(pBot):isDead() or CreatureObject(pBot):isInCombat() then
		again()
		return
	end

	local goods, count = self:goodsOf(pBot, oid)

	if count == 0 then
		self:lootEndOffer(pBot, oid, "nothing left")
		return
	end

	local dist = BotJobs:distance(pBot, pPlayer)

	if dist == nil then
		-- Another zone: the player left. Keep the goods for the next time
		self:lootEndOffer(pBot, oid, "the player is elsewhere")
		return
	end

	if dist > self.offerRange then
		self:walkNear(pBot, oid, pPlayer, dist, now, self.offerRange / 2)
		again()
		return
	end

	self:stopMoving(pBot)

	local ok, offered, remaining = false, "no bindings", 0

	if botOfferGoods ~= nil then
		ok, offered, remaining = botOfferGoods(pBot, playerOid)
	end

	if ok then
		putInt(lkey(oid, "offerOpen"), 1)
		putInt(lkey(oid, "offerBatches"), readData(lkey(oid, "offerBatches")) + 1)
		putInt(lkey(oid, "offerRemaining"), remaining)
		putInt(lkey(oid, "offerUntil"), math.max(readData(lkey(oid, "offerUntil")), now + 100))

		local name = self:firstName(pPlayer)
		local kind = "handover"
		local opener = readData(lkey(oid, "offerOpener"))

		if opener == 1 then
			kind = "handoverFull"
		elseif remaining > 0 then
			kind = "handoverPart"
		elseif readData(lkey(oid, "offerBatches")) > 1 then
			kind = "handoverRest"
		end

		-- To the group while it holds; the player alone once it doesn't
		local line = self:line(oid, kind, name, {goods = self:goodsSummary(goods)})

		if line ~= nil then
			local member = self:lootMember(pBot, playerOid)

			BotJobs:reply(pBot, playerOid, member ~= nil and "group" or "spatial", line)
		end

		again()
		return
	end

	-- offered false: why
	local why = offered

	if why == "busy" or why == "too far" then
		putInt(lkey(oid, "offerTries"), readData(lkey(oid, "offerTries")) + 1)

		if readData(lkey(oid, "offerTries")) > 20 then
			self:lootEndOffer(pBot, oid, "busy")
			return
		end

		again()
	elseif why == "inventory full" then
		-- It waits (until the chain's time is up) for the player to make room, and says so once
		if readData(lkey(oid, "offerSaid")) == 0 then
			putInt(lkey(oid, "offerSaid"), 1)
			self:say(pBot, oid, playerOid, self:lootMember(pBot, playerOid) ~= nil and "group" or "spatial", "handoverRoom",
				self:firstName(pPlayer))
		end

		again(self.offerRoomMs)
	else
		self:lootEndOffer(pBot, oid, tostring(why))
	end
end

-- BotTrade's events for a handover (BotCrew:onEvent "trade")
function BotCrew:lootTradeEvent(pBot, oid, pOther, detail)
	if detail ~= "bundleDone" and detail ~= "bundleCancelled" then
		return
	end

	local playerOid = pOther ~= nil and SceneObject(pOther):getObjectID() or readData(lkey(oid, "offerFor"))

	putInt(lkey(oid, "offerOpen"), 0)

	local _, count = self:goodsOf(pBot, oid)

	if detail == "bundleDone" then
		print("BotJobs: " .. self:name(oid) .. " handed its goods over (" .. count .. " left)")

		if count > 0 and readData(lkey(oid, "offerFor")) ~= 0 then
			-- The rest in another trade, once the player has room
			createEvent(1500, "BotCrew", "lootOfferStep", pBot,
				packArgs(readData(key(oid, "gen")), readData(lkey(oid, "offerSeq"))))
		else
			if readData(lkey(oid, "offerFor")) ~= 0 then
				self:lootEndOffer(pBot, oid, "done")
			end
		end
	else
		print("BotJobs: " .. self:name(oid) .. "'s handover was cancelled (" .. count .. " held)")

		if readData(lkey(oid, "offerFor")) ~= 0 then
			if count > 0 then
				local member = pOther ~= nil and self:lootMember(pBot, playerOid) or nil

				self:say(pBot, oid, playerOid, member ~= nil and "group" or "spatial", "handoverCancelled", pOther ~= nil and self:firstName(pOther) or nil)
			end

			self:lootEndOffer(pBot, oid, "cancelled")
		end
	end
end

-- Leaving

-- Before the bot heads home (dismissed, disbanded, sent home): hand the goods to the leader it was with
function BotCrew:lootBeforeHome(pBot, oid, now)
	local leaderOid = readData(lkey(oid, "leader"))

	if leaderOid == 0 then
		return
	end

	local pLeader = getSceneObject(leaderOid)

	if pLeader == nil or BotJobs:distance(pBot, pLeader) == nil then
		return
	end

	local _, count = self:goodsOf(pBot, oid)

	if count > 0 then
		print("BotJobs: " .. self:name(oid) .. " hands " .. count .. " item(s) over before heading home")
		self:lootStartOffer(pBot, oid, leaderOid, self.offerLeaveSeconds, nil)
	end
end

-- Back in a group, with goods still held from before: says so and offers them
function BotCrew:lootRegrouped(pBot, oid, pLeader, now)
	local goods, count = self:goodsOf(pBot, oid)

	if count == 0 then
		return
	end

	print("BotJobs: " .. self:name(oid) .. " still holds " .. count .. " item(s) from before")
	self:groupSay(pBot, oid, "holding", nil, {goods = self:goodsSummary(goods)})
	self:lootStartOffer(pBot, oid, SceneObject(pLeader):getObjectID(), self.offerRequestSeconds, "holding")
end

-- At login: what it holds is counted
function BotCrew:lootStart(pBot, oid)
	if botGoods ~= nil then
		self:goodsOf(pBot, oid)
	end
end

function BotCrew:lootClear(oid)
	for _, field in ipairs({"offerFor", "offerUntil", "offerOpen", "offerTries", "offerBatches", "offerOpener", "offerRemaining",
		"offerSaid", "lootAt", "lootSayAt", "victims", "goodsN"}) do
		deleteData(lkey(oid, field))
	end

	deleteStringData(lkey(oid, "victims"))
	putInt(lkey(oid, "offerSeq"), readData(lkey(oid, "offerSeq")) + 1)
end
