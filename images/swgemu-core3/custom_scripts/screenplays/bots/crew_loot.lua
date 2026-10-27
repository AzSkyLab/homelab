-- Bot players (Phase 7): the ranger loots and harvests, and what it picked up is handed over by trade.
-- Included from crew.lua (after BotCrew exists). Spec: ~/github/swgemu/specs/2026-10-24-crew-swoops-missions/ (4, 5, 6).
--
-- The kills: each crew bot notes what it fights (BotCrew:lootNote), and the players' targets are noted by scanHuman, in
-- lists of the last few oids. After a fight (every crew step that is out of combat, BotCrew:lootTurn) the group's dead
-- creatures are worked through, one corpse at a time, by the ranger alone:
--   1. it walks up and loots it (botLootCorpse: everything into its pack, the credits through Core3's group split to
--      the humans);
--   2. then harvests it (botHarvest: Core3's own harvest, the type the creature has most of).
-- Only while the ranger is dead, told to stay, on a camp search or on a mission errand does another crew member (the
-- first that is up) loot, as before: it waits for the harvest, or for the ranger to be away, or lootHarvestWait.
-- Corpses of players and other groups' are refused by the binding. A corpse is given up on after lootGiveUp seconds.
--
-- The area scan: the kill lists miss corpses (a creature a mission lair spawned, one the leader killed while the crew
-- was away), so after a fight, and whenever the group asks ("harvest", "skin them", "loot", "loot the bodies"), one
-- crew bot scans for the group's corpses within lootScanRange of the leader (botCorpsesNear: Core3's own permission,
-- the corpse's loot belongs to the group) and adds them to the list. An asked-for scan also wakes up the corpses the
-- crew had given up on, if there is still something on them.
--
-- What they got is said in group chat (lootFlush): the looter names what it harvested and what it took, one line each
-- for everything done since the last one, so a pile of corpses is one line, not a dozen.
--
-- Goods: what a bot holds that isn't its gear (botGoods: what it looted, and every resource container). Handing over
-- (botOfferGoods: a trade window opens on the player's client, the bot has put everything in and accepted; the player
-- accepts) happens:
--   - when a group member says "hand it over" / "give me the loot" / "trade me" (each bot with goods offers);
--   - when the group breaks up, a bot is dismissed or sent home: before it heads home;
--   - when the bot is regrouped, for goods it still holds from before.
-- An offer is one chain of events per bot (lootOfferStep): it walks up to the player, offers, waits for the trade's
-- result (the "trade" events bundleOpened / bundleDone / bundleCancelled from BotTrade), offers the rest in another
-- trade, and ends. BotTrade opens one trade at a time to a player (a few seconds after the last one closed), so bots
-- handing over together go one after the other; each says its line when its own trade opens. A handover that is
-- cancelled while other bots hold goods too is offered once more before it gives up.
-- The 2005 client sometimes loses a trade window opened close to other activity (a group that has just disbanded): so
-- a bot leaving the group waits offerLeaveDelayMs before it offers, a window that closed on its own before the player
-- touched it ("bundleLost" from BotTrade) is offered once more offerRetryMs later, and a second loss makes the bot say
-- handoverRetryAsk and wait offerWaitSeconds nearby for "trade me" before it heads home.
-- Out of the group: "hand it over" said out loud to the bot, or by tell, works too. A bot that has gone home answers a
-- tell with where it is (handoverWhere) and offers when the player comes within wantRange (BotCrew:lootWantTick).
-- The goods are never sold, dropped or kept for the bot: a cancelled trade leaves them in its pack for the next ask.

BotCrew.lootEvery = 2           -- seconds between a bot's loot and harvest actions
BotCrew.lootGiveUp = 120        -- seconds after a corpse is found dead until the crew stops trying for it
BotCrew.lootFromLeader = 70     -- a corpse further than this from the leader is left for now
BotCrew.harvestReach = 5        -- the ranger walks up to this far from a corpse (Core3 allows 7 m)
BotCrew.lootReach = 6           -- a looter walks up to this far (Core3 allows 16 m)
BotCrew.lootTries = 30          -- actions on one corpse before it is dropped
BotCrew.lootSayDelay = 20       -- seconds a bot gathers what it got before saying it (it says it at once when it has no more to do)
BotCrew.lootScanRange = 60      -- metres around the leader for the corpses a scan looks for
BotCrew.lootScanEvery = 4       -- seconds between scans after a fight
BotCrew.lootScanAfter = 40      -- seconds after a fight the crew keeps scanning
BotCrew.lootAskWindow = 90      -- seconds an asked-for round of looting and harvesting lasts
BotCrew.victimsKept = 16        -- kills remembered per fighter
BotCrew.offerRange = 12         -- a bot offers within this of the player (Core3 refuses a trade at 15 m)
BotCrew.offerStepMs = 2500
BotCrew.offerRoomMs = 5000        -- how often it looks again for room in the player's pack
BotCrew.offerRequestSeconds = 60   -- an asked-for handover gives up after this long
BotCrew.offerLeaveSeconds = 75     -- a handover before heading home
BotCrew.offerRetryMs = 8000        -- a cancelled handover is offered once more after this, when others hold goods too
BotCrew.offerLeaveDelayMs = 4000   -- a bot that has left the group waits this before it offers (the client is busy with the disband)
BotCrew.offerWaitSeconds = 120     -- after two lost windows it waits this long, nearby, for "trade me"
BotCrew.wantSeconds = 600          -- a tell "hand it over" to a bot at home stands this long
BotCrew.wantRange = 30             -- ...and the bot offers once the player is within this
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

local function gkey(leaderOid, field)
	return "crew:group:" .. leaderOid .. ":" .. field
end

-- "a greater desert womp rat" -> "greater desert womp rat"
local function bareName(name)
	return (tostring(name or "creature"):gsub("^[Aa]n? ", ""):gsub("^[Tt]he ", ""))
end

-- Not for the string store: "%" (string.format) and the separators we use
local function clean(text)
	return (tostring(text or ""):gsub("[%%|;\n]", ""))
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

local function putString(k, v)
	writeStringData(k, (tostring(v or ""):gsub("%%", "")))
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
function BotCrew:lootCorpses(g, pLeader, now, pBot)
	local seen, out = {}, {}
	local lists = {}

	for _, m in ipairs(g.crew) do
		table.insert(lists, readStringData(lkey(m.oid, "victims")))
	end

	for _, m in ipairs(g.humans) do
		table.insert(lists, readStringData("crew:human:" .. m.oid .. ":victims"))
	end

	-- What the area scans found (the leader's group)
	table.insert(lists, readStringData(gkey(pLeader ~= nil and SceneObject(pLeader):getObjectID() or 0, "areaCorpses")))

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

					-- The kills are counted by one crew bot (pBot), or the bots' threads would count them twice
					if pBot ~= nil and readData(corpseKey(corpseOid, "counted")) == 0 then
						putInt(corpseKey(corpseOid, "counted"), 1)
						self:huntKill(pBot, SceneObject(p):getDisplayedName())
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

-- The crew member who harvests (a ranger with the scout skill, alive), and who loots: the ranger too, unless it is
-- told to stay, on a camp search or a mission errand (or is down), then the first other crew member that is alive
function BotCrew:lootRoles(g, now)
	local harvester, ranger, other, any = nil, nil, nil, nil

	for _, m in ipairs(g.crew) do
		if not CreatureObject(m.p):isDead() then
			any = any or m

			if m.job == "ranger" then
				ranger = m

				if CreatureObject(m.p):hasSkill("outdoors_scout_novice") then
					harvester = m
				end
			elseif other == nil then
				other = m
			end
		end
	end

	local rangerFree = false

	if ranger ~= nil then
		local order = readStringData(lkey(ranger.oid, "order"))

		rangerFree = not CreatureObject(ranger.p):isIncapacitated() and order ~= "stay" and order ~= "campSearch" and
			not (self.missionBusy ~= nil and self:missionBusy(ranger.oid, now))
	end

	return harvester, (rangerFree and ranger) or other or ranger or any
end

-- The area scan

-- Looks for the group's corpses around the leader and adds them to the list. force (a request) wakes up the ones the
-- crew gave up on that still have something on them; kind says what was asked ("harvest", "loot" or "both"). Returns
-- how many corpses have something to harvest and something to loot.
function BotCrew:lootScan(pBot, pLeader, now, force, kind)
	if botCorpsesNear == nil or pLeader == nil then
		return 0, 0
	end

	local leaderOid = SceneObject(pLeader):getObjectID()

	putInt(gkey(leaderOid, "lootScanAt"), now)

	local found = botCorpsesNear(pBot, self.lootScanRange, pLeader) or {}
	local harvestN, lootN = 0, 0

	for _, c in ipairs(found) do
		local done = readData(corpseKey(c.oid, "done")) == 1
		local wantLoot = c.items > 0 or c.credits > 0
		local wantHarvest = c.harvest and readData(corpseKey(c.oid, "harvOk")) ~= 1

		if force and done then
			-- Back in the list: only the part that was asked for
			if wantLoot and (kind == "loot" or kind == "both") then
				putInt(corpseKey(c.oid, "loot"), 0)
				done = false
			end

			if wantHarvest and (kind == "harvest" or kind == "both") then
				putInt(corpseKey(c.oid, "harv"), 0)
				done = false
			end

			if not done then
				putInt(corpseKey(c.oid, "done"), 0)
				putInt(corpseKey(c.oid, "tries"), 0)
				putInt(corpseKey(c.oid, "seen"), now)
			end
		end

		if not done and (wantLoot or wantHarvest) then
			addToList(gkey(leaderOid, "areaCorpses"), c.oid, 40)

			if wantHarvest then
				harvestN = harvestN + 1
			end

			if wantLoot then
				lootN = lootN + 1
			end
		end
	end

	return harvestN, lootN
end

-- A scan is due: asked for a moment ago, or a fight has just ended
function BotCrew:lootScanDue(pLeader, now)
	local leaderOid = SceneObject(pLeader):getObjectID()

	if now - readData(gkey(leaderOid, "lootScanAt")) < self.lootScanEvery then
		return false
	end

	return now - readData(gkey(leaderOid, "lootAskAt")) <= self.lootAskWindow or
		now - readData(gkey(leaderOid, "fightAt")) <= self.lootScanAfter
end

-- "harvest" / "loot" from a group member (BotCrew:act): this bot scans at once and says how many it found; the crew
-- then works through them as it always does (the scans after it keep finding what comes up in the next minute)
function BotCrew:lootRequest(pBot, oid, pPlayer, kind, channel, brainLine)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local name = self:firstName(pPlayer)
	local g = self:group(pBot)

	if g == nil or g.byOid[playerOid] == nil then
		if brainLine == nil then
			self:say(pBot, oid, playerOid, channel, "notWith", name)
		end

		return
	end

	local now = os.time()
	local pLeader = self:leaderOf(pBot, oid, g, now) or pPlayer
	local leaderOid = SceneObject(pLeader):getObjectID()

	-- A fight on: it happens when it's over
	putInt(gkey(leaderOid, "lootAskAt"), now)

	if botCorpsesNear == nil then
		return
	end

	local harvestN, lootN = self:lootScan(pBot, pLeader, now, true, kind)
	local n = kind == "harvest" and harvestN or (kind == "loot" and lootN or math.max(harvestN, lootN))

	print("BotJobs: " .. self:name(oid) .. " is asked to " .. kind .. " by " .. name .. ": " .. harvestN .. " to harvest, " .. lootN .. " to loot")

	if brainLine == nil then
		local line = n == 0 and (kind == "harvest" and "harvestAskNone" or "lootAskNone") or (kind == "harvest" and "harvestAsk" or "lootAsk")

		self:say(pBot, oid, playerOid, channel, line, name, {n = tostring(n)})
	end
end

-- What they got

local function addTo(k, text)
	local list = readStringData(k)

	writeStringData(k, list == "" and text or (list .. "|" .. text))
end

-- A harvest, for the line (lootFlush)
function BotCrew:lootNoteHarvest(oid, creature, amount, resource)
	if readData(lkey(oid, "hvN")) == 0 and readData(lkey(oid, "ltN")) == 0 then
		putInt(lkey(oid, "sayFirstAt"), os.time())
	end

	putInt(lkey(oid, "hvN"), readData(lkey(oid, "hvN")) + 1)
	writeStringData(lkey(oid, "hvName"), clean(bareName(creature)))
	addTo(lkey(oid, "hvList"), clean(resource) .. ";" .. math.floor(amount))
end

-- A loot, for the line
function BotCrew:lootNoteLoot(oid, creature, names, moved, credits)
	if readData(lkey(oid, "hvN")) == 0 and readData(lkey(oid, "ltN")) == 0 then
		putInt(lkey(oid, "sayFirstAt"), os.time())
	end

	putInt(lkey(oid, "ltN"), readData(lkey(oid, "ltN")) + 1)
	putInt(lkey(oid, "ltItems"), readData(lkey(oid, "ltItems")) + moved)
	putInt(lkey(oid, "ltCredits"), readData(lkey(oid, "ltCredits")) + credits)
	writeStringData(lkey(oid, "ltName"), clean(bareName(creature)))

	for _, name in ipairs(names or {}) do
		if #readStringData(lkey(oid, "ltNames")) < 400 then
			addTo(lkey(oid, "ltNames"), clean(name))
		end
	end
end

-- "A, B and 3 more" from a "|" list, at most `shown` names (a repeat counted: "2 Power Cores" would need plurals, so
-- "Power Core x2")
local function itemList(text, total, shown)
	local counts, order = {}, {}

	for name in string.gmatch(text, "[^|]+") do
		if counts[name] == nil then
			counts[name] = 0
			table.insert(order, name)
		end

		counts[name] = counts[name] + 1
	end

	local parts = {}

	for i = 1, math.min(#order, shown) do
		local name = order[i]

		table.insert(parts, counts[name] > 1 and (name .. " x" .. counts[name]) or name)
	end

	local listed = 0

	for i = 1, math.min(#order, shown) do
		listed = listed + counts[order[i]]
	end

	local more = total - listed

	if more > 0 then
		table.insert(parts, more .. " more")
	end

	if #parts <= 1 then
		return parts[1] or "nothing"
	end

	local last = table.remove(parts)

	return table.concat(parts, ", ") .. " and " .. last
end

-- "373 Tatooinian Herbivore Meat" or "40 Mammalian Hide, 12 Bone": the totals by resource
local function resourceList(text)
	local totals, order = {}, {}

	for entry in string.gmatch(text, "[^|]+") do
		local resource, amount = entry:match("^(.-);(%d+)$")

		if resource ~= nil then
			if totals[resource] == nil then
				totals[resource] = 0
				table.insert(order, resource)
			end

			totals[resource] = totals[resource] + tonumber(amount)
		end
	end

	local parts = {}

	for i = 1, math.min(#order, 3) do
		table.insert(parts, totals[order[i]] .. " " .. order[i])
	end

	if #order > 3 then
		table.insert(parts, (#order - 3) .. " more kinds")
	end

	return table.concat(parts, ", ")
end

-- Says what the bot harvested and looted since its last line, in group chat. When the bot has no more to do, or has
-- been gathering for lootSayDelay seconds.
function BotCrew:lootFlush(pBot, oid, now, idle)
	local hvN, ltN = readData(lkey(oid, "hvN")), readData(lkey(oid, "ltN"))

	if hvN == 0 and ltN == 0 then
		return
	end

	if not idle and now - readData(lkey(oid, "sayFirstAt")) < self.lootSayDelay then
		return
	end

	if not CreatureObject(pBot):isGrouped() then
		hvN, ltN = 0, 0
	end

	if hvN > 0 then
		local what = resourceList(readStringData(lkey(oid, "hvList")))
		local creature = readStringData(lkey(oid, "hvName"))

		if what ~= "" then
			if hvN == 1 then
				self:groupSay(pBot, oid, "harvestedOne", nil, {creature = creature, what = what})
			else
				self:groupSay(pBot, oid, "harvestedMany", nil, {n = tostring(hvN), what = what})
			end
		end
	end

	if ltN > 0 then
		local items = readData(lkey(oid, "ltItems"))
		local credits = readData(lkey(oid, "ltCredits"))
		local creature = readStringData(lkey(oid, "ltName"))
		local fill = {n = tostring(ltN), creature = creature,
			credits = credits > 0 and (" (" .. credits .. " credits split)") or ""}

		if items > 0 then
			fill.items = itemList(readStringData(lkey(oid, "ltNames")), items, 3)
			self:groupSay(pBot, oid, ltN == 1 and "lootedOne" or "lootedMany", nil, fill)
		else
			self:groupSay(pBot, oid, ltN == 1 and "lootedNothing" or "lootedNothingMany", nil, fill)
		end
	end

	for _, field in ipairs({"hvN", "ltN", "ltItems", "ltCredits", "sayFirstAt"}) do
		deleteData(lkey(oid, field))
	end

	for _, field in ipairs({"hvName", "hvList", "ltName", "ltNames"}) do
		deleteStringData(lkey(oid, field))
	end
end

-- One loot or harvest action for this bot, if it is the one to do the next. True when the bot is busy with it (the
-- caller then doesn't send it back to follow the leader).
BotCrew.lootHarvestWait = 20

function BotCrew:lootTurn(pBot, oid, g, pLeader, now)
	-- (a build without the Phase 7 bindings still runs the rest)
	-- (told to stay, or out looking for a camp spot: it doesn't walk off to a corpse)
	local order = readStringData(lkey(oid, "order"))

	if botLootCorpse == nil or g == nil or pLeader == nil or order == "stay" or order == "campSearch" then
		return false
	end

	if CreatureObject(pBot):isInCombat() or CreatureObject(pBot):isDead() or self:groupFighting(g) then
		return false
	end

	-- After a fight, or when asked, look around for the group's corpses
	if self:lootScanDue(pLeader, now) then
		self:lootScan(pBot, pLeader, now, false, "both")
	end

	-- One crew bot (the first that is up) counts the kills and writes them into the hunt log
	local counter = nil

	for _, m in ipairs(g.crew) do
		local mOrder = readStringData(lkey(m.oid, "order"))

		if not CreatureObject(m.p):isDead() and not CreatureObject(m.p):isIncapacitated() and mOrder ~= "stay" and mOrder ~= "campSearch" then
			counter = m.oid
			break
		end
	end

	local corpses = self:lootCorpses(g, pLeader, now, counter == oid and pBot or nil)

	if counter == oid then
		self:huntKillsFlush(pBot, g.leader.oid)
	end

	if #corpses == 0 then
		self:lootFlush(pBot, oid, now, true)
		return false
	end

	local harvester, looter = self:lootRoles(g, now)
	local isHarvester = harvester ~= nil and harvester.oid == oid
	local isLooter = looter ~= nil and looter.oid == oid

	-- The ranger does both, a corpse at a time: it loots it first, then harvests it
	if isHarvester and isLooter then
		for _, c in ipairs(corpses) do
			if c.loot then
				self:lootFlush(pBot, oid, now, false)
				return self:lootStep(pBot, oid, c, now)
			end

			if c.harvest then
				self:lootFlush(pBot, oid, now, false)
				return self:harvestStep(pBot, oid, c, now)
			end
		end

		self:lootFlush(pBot, oid, now, true)

		return false
	end

	-- The ranger, when another loots (it was away): the first corpse not harvested yet
	if isHarvester then
		for _, c in ipairs(corpses) do
			if c.harvest then
				self:lootFlush(pBot, oid, now, false)
				return self:harvestStep(pBot, oid, c, now)
			end
		end
	end

	-- The looter: the first corpse that has been harvested, or has nobody free to harvest it (the ranger told to stay,
	-- on a camp search or a mission errand), or has waited lootHarvestWait for the ranger
	local harvesterOrder = harvester ~= nil and readStringData(lkey(harvester.oid, "order")) or ""
	local harvesterAway = harvester == nil or harvesterOrder == "stay" or harvesterOrder == "campSearch" or
		(self.missionBusy ~= nil and self:missionBusy(harvester.oid, now))

	if isLooter then
		for _, c in ipairs(corpses) do
			if c.loot and (not c.harvest or harvesterAway or now - (c.seen or now) >= self.lootHarvestWait) then
				self:lootFlush(pBot, oid, now, false)
				return self:lootStep(pBot, oid, c, now)
			end
		end
	end

	-- Nothing for this bot to do just now
	self:lootFlush(pBot, oid, now, true)

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

-- The leader of the bot's group (the harvest choice, the hunt and the kind asked for live under it)
function BotCrew:harvestLeader(pBot, oid)
	local g = self:group(pBot)

	if g ~= nil and g.leader ~= nil then
		return g.leader.oid
	end

	return readData(lkey(oid, "leader"))
end

-- "hide" -> "Hide"
local function capital(word)
	return (tostring(word or ""):gsub("^%l", string.upper))
end

-- The ranger's own harvest, or the kind it was asked for ("hide", "meat", "bone"; "" for its own pick: the resource
-- with the best crafting score on this planet today, botHarvest)
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

	local leaderOid = self:harvestLeader(pBot, oid)
	local asked = leaderOid ~= 0 and readStringData(gkey(leaderOid, "harvestKind")) or ""
	local r = botHarvest(pBot, c.oid, asked)

	if r ~= nil and r.ok then
		putInt(corpseKey(c.oid, "harv"), 1)
		putInt(corpseKey(c.oid, "harvOk"), 1)
		self:goodsOf(pBot, oid)
		self:harvestDone(pBot, oid, leaderOid, asked, r, SceneObject(c.p):getDisplayedName())
		self:huntTallyAdd(pBot, "harvested", 1)
	elseif r ~= nil and r.error == "too far" then
		-- Not yet: another step
	else
		-- Nothing to harvest, or the ranger can't: on to the loot
		putInt(corpseKey(c.oid, "harv"), 1)
	end

	return true
end

-- What a harvest gave, for the lines: noted for the short line, remembered for "what are you harvesting?", and the
-- reasons said once: why this pick (own pick: the first carcass of a hunt, then whenever the spawn or the kind changes),
-- or that the creature had none of the kind asked for (once a hunt)
function BotCrew:harvestDone(pBot, oid, leaderOid, asked, r, creature)
	local resource = (r.resource ~= nil and r.resource ~= "") and r.resource or tostring(r.kind)
	local spawn = r.spawn or ""
	local what = spawn ~= "" and (resource .. " (" .. spawn .. ")") or resource

	self:lootNoteHarvest(oid, creature, r.amount, what)

	if leaderOid == 0 then
		return
	end

	writeStringData(gkey(leaderOid, "harvestLast"), clean(r.kind) .. "|" .. clean(resource) .. "|" .. clean(spawn) .. "|" .. clean(r.stats))

	if r.fallback then
		if readData(gkey(leaderOid, "harvestNoKindSaid")) ~= 1 then
			putInt(gkey(leaderOid, "harvestNoKindSaid"), 1)
			self:groupSay(pBot, oid, "harvestNoKind", nil, {asked = asked, Asked = capital(asked), kind = tostring(r.kind), Kind = capital(r.kind)})
		end

		return
	end

	if asked ~= "" then
		return
	end

	local sig = tostring(r.kind) .. "|" .. spawn

	if readStringData(gkey(leaderOid, "harvestSaid")) == sig then
		return
	end

	writeStringData(gkey(leaderOid, "harvestSaid"), sig)

	local stats, alt = "no stats worth the name, so it's the biggest yield", ""

	if (r.lead or "") ~= "" then
		stats = r.lead .. " " .. tostring(r.leadValue)
	end

	if (r.altKind or "") ~= "" then
		if (r.altScore or 0) * 2 <= (r.score or 0) then
			alt = "The " .. r.altKind .. "'s junk."
		elseif (r.altScore or 0) < (r.score or 0) then
			alt = "Better than the " .. r.altKind .. "."
		end
	end

	self:groupSay(pBot, oid, "harvestWhy", nil, {kind = tostring(r.kind), Kind = capital(r.kind), what = what, stats = stats, alt = alt})
end

-- Forget the hunt's harvest choice (the group broke up, or a new hunt began)
function BotCrew:harvestClear(leaderOid)
	deleteStringData(gkey(leaderOid, "harvestKind"))
	deleteStringData(gkey(leaderOid, "harvestSaid"))
	deleteStringData(gkey(leaderOid, "harvestLast"))
	deleteData(gkey(leaderOid, "harvestNoKindSaid"))
end

-- What the crew is harvesting, in words: for "what are you harvesting?" and the brain
function BotCrew:harvestState(leaderOid)
	local asked = leaderOid ~= 0 and readStringData(gkey(leaderOid, "harvestKind")) or ""
	local kind, resource, spawn, stats = readStringData(gkey(leaderOid or 0, "harvestLast")):match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
	local last = nil

	if kind ~= nil and kind ~= "" then
		last = resource .. (spawn ~= "" and (" (" .. spawn .. ")") or "") .. (stats ~= "" and (", " .. stats) or "")
	end

	return asked, kind, last
end

-- The brain's fact: what the ranger is harvesting
function BotCrew:harvestFacts(leaderOid)
	local asked, kind, last = self:harvestState(leaderOid)
	local text = asked ~= "" and ("you were asked for " .. asked .. " only") or "you choose the resource with the best crafting stats yourself"

	if last ~= nil then
		text = text .. "; the last carcass gave " .. kind .. ": " .. last
	else
		text = text .. "; nothing harvested yet this hunt"
	end

	return text
end

-- "what are you harvesting?": the ranger says whether it was asked for a type, and what it is taking
function BotCrew:harvestAnswer(pBot, oid, playerOid, channel, name)
	local asked, kind, last = self:harvestState(self:harvestLeader(pBot, oid))
	local text

	if asked ~= "" then
		text = capital(asked) .. " only, as you asked." .. (last ~= nil and (" Last was " .. last .. ".") or " Nothing skinned yet.")
	elseif last ~= nil then
		text = "My own pick, by the stats. Last was " .. kind .. ": " .. last .. "."
	else
		text = "Nothing skinned yet. I go for the best stats on the planet today, whichever the creature has."
	end

	self:say(pBot, oid, playerOid, channel, "harvestStatus", name, {what = text})
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
		-- Done when the corpse is empty, the pack is full, or nothing more would move (and, if the ranger loots first,
		-- it has been harvested: the corpse stays in the list until then)
		if r.left == 0 or r.full or r.moved == 0 then
			putInt(corpseKey(c.oid, "loot"), 1)

			if readData(corpseKey(c.oid, "harv")) == 1 then
				putInt(corpseKey(c.oid, "done"), 1)
			end
		end

		-- (a corpse with nothing on it isn't announced or counted as looted)
		if r.moved > 0 or r.credits > 0 then
			self:goodsOf(pBot, oid)
			self:lootNoteLoot(oid, SceneObject(c.p):getDisplayedName(), r.names, r.moved, r.credits)
			self:huntTallyAdd(pBot, "looted", 1)
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
		putInt(corpseKey(c.oid, "harv"), 1)
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

-- Is another crew member of the group handing over, or holding goods to?
function BotCrew:othersHandOver(pBot, oid)
	local g = self:group(pBot)

	for _, m in ipairs(g ~= nil and g.crew or {}) do
		if m.oid ~= oid and (self:lootHolding(m.oid) or readData(lkey(m.oid, "goodsN")) > 0) then
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

-- Starts the chain: opener is the line kind for the first offer ("lootFull" and so on), or nil for the usual; delayMs
-- is the wait before the first step (a bot that has just left the group gives the client a moment). Already handing
-- over to this player: nothing new starts, but one that is waiting for "trade me" (two windows lost) offers at once
function BotCrew:lootStartOffer(pBot, oid, playerOid, seconds, opener, delayMs)
	-- Part 3: while its owner's gifts are being handed back, no one else's loot offer starts (it would end the owner's)
	if botGearGiveMode ~= nil and ((botOwner and botOwner(oid)) or 0) ~= 0 and botOwner(oid) ~= playerOid and botGearGiveMode(pBot) ~= "" then
		return
	end

	if self:lootHolding(oid) and readData(lkey(oid, "offerFor")) == playerOid then
		if readData(lkey(oid, "offerWait")) == 1 then
			putInt(lkey(oid, "offerWait"), 0)
			putInt(lkey(oid, "offerUntil"), math.max(readData(lkey(oid, "offerUntil")), os.time() + self.offerRequestSeconds))
		end

		return
	end

	local seq = readData(lkey(oid, "offerSeq")) + 1

	putInt(lkey(oid, "offerSeq"), seq)
	putInt(lkey(oid, "offerFor"), playerOid)
	putInt(lkey(oid, "offerUntil"), os.time() + seconds + math.floor((delayMs or 0) / 1000))
	putInt(lkey(oid, "offerOpen"), 0)
	putInt(lkey(oid, "offerTries"), 0)
	putInt(lkey(oid, "offerBatches"), 0)
	putInt(lkey(oid, "offerSaid"), 0)
	putInt(lkey(oid, "offerRetried"), 0)
	putInt(lkey(oid, "offerLost"), 0)
	putInt(lkey(oid, "offerWait"), 0)
	putInt(lkey(oid, "offerHold"), 0)
	deleteStringData(lkey(oid, "offerLineKind"))

	if opener ~= nil then
		putInt(lkey(oid, "offerOpener"), opener == "lootFull" and 1 or 2)
	else
		putInt(lkey(oid, "offerOpener"), 0)
	end

	createEvent(math.max(delayMs or 0, 300), "BotCrew", "lootOfferStep", pBot, packArgs(readData(key(oid, "gen")), seq))
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
	local who = readData(lkey(oid, "offerFor"))

	putInt(lkey(oid, "offerFor"), 0)
	putInt(lkey(oid, "offerOpen"), 0)

	-- (Part 3: a hand-back of the owner's gear is over: the goods are the loot again. Only the owner's chain ends it)
	if botGearGiveEnd ~= nil and (((botOwner and botOwner(oid)) or 0) == 0 or who == botOwner(oid) or who == 0) then
		botGearGiveEnd(pBot)
	end

	-- (the mode is in the crew's own key: crew.lua's ckey is lkey)
	local mode = readStringData(lkey(oid, "mode"))

	-- A bot at home that walked out to the player goes back to its station
	if mode == "home" and not CreatureObject(pBot):isGrouped() then
		putString(lkey(oid, "mode"), "leaving")
		putInt(lkey(oid, "leavingAt"), os.time())
		mode = "leaving"
	end

	if mode == "leaving" then
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

	-- A window just closed: a few seconds before the next (the client takes a moment)
	if now < readData(lkey(oid, "offerHold")) then
		again()
		return
	end

	-- Two windows lost: it waits (offerWait is cleared by "trade me", lootStartOffer; the time is offerUntil)
	if readData(lkey(oid, "offerWait")) == 1 then
		again()
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

		-- Said when the window really opens (BotTrade queues the handover behind other bots' trades to the player): the
		-- "bundleOpened" event (lootTradeEvent)
		writeStringData(lkey(oid, "offerLineKind"), kind)
		writeStringData(lkey(oid, "offerLineGoods"), (self:goodsSummary(goods):gsub("%%", "")))

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
	if detail ~= "bundleDone" and detail ~= "bundleCancelled" and detail ~= "bundleOpened" and detail ~= "bundleLost" then
		return
	end

	local playerOid = pOther ~= nil and SceneObject(pOther):getObjectID() or readData(lkey(oid, "offerFor"))

	-- The trade window is open on the player's client: say so now (to the group while it holds; the player alone once
	-- it doesn't)
	if detail == "bundleOpened" then
		local kind = readStringData(lkey(oid, "offerLineKind"))

		if kind ~= "" and readData(lkey(oid, "offerFor")) ~= 0 then
			local name = pOther ~= nil and self:firstName(pOther) or nil
			local line = self:line(oid, kind, name, {goods = readStringData(lkey(oid, "offerLineGoods"))})

			if line ~= nil then
				local member = self:lootMember(pBot, playerOid)

				BotJobs:reply(pBot, playerOid, member ~= nil and "group" or "spatial", line)
			end
		end

		deleteStringData(lkey(oid, "offerLineKind"))
		putInt(lkey(oid, "offerUntil"), math.max(readData(lkey(oid, "offerUntil")), os.time() + 100))

		return
	end

	deleteStringData(lkey(oid, "offerLineKind"))

	putInt(lkey(oid, "offerOpen"), 0)

	local _, count = self:goodsOf(pBot, oid)

	if detail == "bundleDone" then
		print("BotJobs: " .. self:name(oid) .. " handed its goods over (" .. count .. " left)")

		if count > 0 and readData(lkey(oid, "offerFor")) ~= 0 then
			-- The rest in another trade, once the player has room: the chain that waited for this one goes on (a second
			-- chain on the same offer would only double the steps)
			putInt(lkey(oid, "offerHold"), os.time() + 1)
		else
			if readData(lkey(oid, "offerFor")) ~= 0 then
				self:lootEndOffer(pBot, oid, "done")
			end
		end
	elseif detail == "bundleLost" then
		-- The window closed before the player touched it (the client lost it): once more, then ask and wait
		local lost = readData(lkey(oid, "offerLost")) + 1

		print("BotJobs: " .. self:name(oid) .. "'s handover window was lost (" .. count .. " held, lost " .. lost .. " time(s))")

		if readData(lkey(oid, "offerFor")) == 0 then
			return
		end

		if count == 0 then
			self:lootEndOffer(pBot, oid, "nothing left")
			return
		end

		putInt(lkey(oid, "offerLost"), lost)

		-- (the window never counted: the next is still the first trade)
		putInt(lkey(oid, "offerBatches"), math.max(readData(lkey(oid, "offerBatches")) - 1, 0))

		if lost == 1 then
			putInt(lkey(oid, "offerUntil"), math.max(readData(lkey(oid, "offerUntil")), os.time() + 60))
			putInt(lkey(oid, "offerHold"), os.time() + math.ceil(self.offerRetryMs / 1000))
			print("BotJobs: " .. self:name(oid) .. " will offer again")
		else
			putInt(lkey(oid, "offerWait"), 1)
			putInt(lkey(oid, "offerUntil"), os.time() + self.offerWaitSeconds)

			local member = pOther ~= nil and self:lootMember(pBot, playerOid) or nil

			self:say(pBot, oid, playerOid, member ~= nil and "group" or "spatial", "handoverRetryAsk", pOther ~= nil and self:firstName(pOther) or nil)
			print("BotJobs: " .. self:name(oid) .. " waits for 'trade me'")
		end
	else
		print("BotJobs: " .. self:name(oid) .. "'s handover was cancelled (" .. count .. " held)")

		if readData(lkey(oid, "offerFor")) ~= 0 and count > 0 and readData(lkey(oid, "offerRetried")) == 0 and
			self:othersHandOver(pBot, oid) then
			-- Others were handing over too: once more, after them, before giving up
			putInt(lkey(oid, "offerRetried"), 1)
			putInt(lkey(oid, "offerUntil"), math.max(readData(lkey(oid, "offerUntil")), os.time() + 60))
			putInt(lkey(oid, "offerHold"), os.time() + math.ceil(self.offerRetryMs / 1000))
			print("BotJobs: " .. self:name(oid) .. " will offer again after the others")

			return
		end

		if readData(lkey(oid, "offerFor")) ~= 0 then
			if count > 0 then
				local member = pOther ~= nil and self:lootMember(pBot, playerOid) or nil

				self:say(pBot, oid, playerOid, member ~= nil and "group" or "spatial", "handoverCancelled", pOther ~= nil and self:firstName(pOther) or nil)
			end

			self:lootEndOffer(pBot, oid, "cancelled")
		end
	end
end

-- Out of the group

-- "Hand it over", said out loud to a bot or by tell, to a bot that isn't grouped (it left the group holding goods, and
-- may be home by now). A human asks: with goods held and the player within wantRange the bot offers at once; farther,
-- by tell, it says where it is and offers when the player comes within range (lootWantTick). Returns true when the
-- line was handled
function BotCrew:handoverUngrouped(pBot, oid, pSpeaker, channel, text)
	if pSpeaker == nil or not self:handoverWanted(text) or not self:human(pSpeaker) then
		return false
	end

	local playerOid = SceneObject(pSpeaker):getObjectID()
	local name = self:firstName(pSpeaker)
	local goods, count = self:goodsOf(pBot, oid)

	if count == 0 then
		self:say(pBot, oid, playerOid, channel, "handoverNone", name)
		return true
	end

	local dist = BotJobs:distance(pBot, pSpeaker)

	print("BotJobs: " .. self:name(oid) .. " is asked for the loot by " .. name .. " out of the group (" .. count .. " item(s), " ..
		(dist ~= nil and (math.floor(dist) .. " m away") or "elsewhere") .. ")")

	if dist ~= nil and dist <= self.wantRange then
		putInt(lkey(oid, "wantBy"), 0)
		self:lootHoldHome(pBot, oid)
		self:lootStartOffer(pBot, oid, playerOid, self.offerRequestSeconds, nil)
	else
		-- Where it is; it hands over when the player comes by (it keeps going home meanwhile)
		putInt(lkey(oid, "wantBy"), playerOid)
		putInt(lkey(oid, "wantUntil"), os.time() + self.wantSeconds)
		self:say(pBot, oid, playerOid, channel, readStringData(lkey(oid, "mode")) == "home" and "handoverWhere" or "handoverWhereBound",
			name, {place = self.place})
	end

	return true
end

-- A bot on its way home stops, to hand over first (its chain sends it home again)
function BotCrew:lootHoldHome(pBot, oid)
	if readStringData(lkey(oid, "mode")) == "walkingHome" then
		self:stopMoving(pBot)
		putString(lkey(oid, "mode"), "leaving")
		putInt(lkey(oid, "leavingAt"), os.time())
	end
end

-- Out loud, naming nobody ("trade me"), from the player this bot is offering to or was asked by, within offerRange: an
-- ungrouped bot hears it as it would a grouped one (BotJobs:heard asks, after spatialGroup)
function BotCrew:spatialHandover(pBot, pSpeaker, text)
	if CreatureObject(pBot):isGrouped() or not self:handoverWanted(text) or not self:human(pSpeaker) then
		return false
	end

	local oid = SceneObject(pBot):getObjectID()
	local playerOid = SceneObject(pSpeaker):getObjectID()
	local mine = (self:lootHolding(oid) and readData(lkey(oid, "offerFor")) == playerOid) or
		(readData(lkey(oid, "wantBy")) == playerOid and os.time() <= readData(lkey(oid, "wantUntil")))
	local dist = BotJobs:distance(pBot, pSpeaker)

	return mine and dist ~= nil and dist <= self.offerRange
end

-- From BotCrew:tick (every 5 s): a bot that was asked for its goods by tell offers them once the player comes near
function BotCrew:lootWantTick(pBot, oid, now)
	local playerOid = readData(lkey(oid, "wantBy"))

	if playerOid == 0 then
		return
	end

	if now > readData(lkey(oid, "wantUntil")) or CreatureObject(pBot):isGrouped() then
		putInt(lkey(oid, "wantBy"), 0)
		return
	end

	local pPlayer = getSceneObject(playerOid)
	local dist = pPlayer ~= nil and BotJobs:distance(pBot, pPlayer) or nil

	if dist == nil or dist > self.wantRange or self:lootHolding(oid) or CreatureObject(pBot):isDead() then
		return
	end

	local _, count = self:goodsOf(pBot, oid)

	putInt(lkey(oid, "wantBy"), 0)

	if count > 0 then
		self:lootHoldHome(pBot, oid)
		self:lootStartOffer(pBot, oid, playerOid, self.offerRequestSeconds, nil)
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
		self:lootStartOffer(pBot, oid, leaderOid, self.offerLeaveSeconds, nil, self.offerLeaveDelayMs)
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
		"offerSaid", "offerRetried", "offerLost", "offerWait", "offerHold", "wantBy", "wantUntil", "lootAt", "lootSayAt", "victims", "goodsN", "hvN", "ltN", "ltItems", "ltCredits", "sayFirstAt"}) do
		deleteData(lkey(oid, field))
	end

	for _, field in ipairs({"victims", "hvName", "hvList", "ltName", "ltNames", "offerLineKind", "offerLineGoods"}) do
		deleteStringData(lkey(oid, field))
	end
	putInt(lkey(oid, "offerSeq"), readData(lkey(oid, "offerSeq")) + 1)
end
