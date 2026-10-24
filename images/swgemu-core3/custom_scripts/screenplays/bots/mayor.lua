-- Bot players (Phase 6): the mayor of the player city (a master politician). Spec:
-- ~/github/swgemu/specs/2026-10-23-player-city/. The city's shared work (the plan, placing, walking, the city's
-- entertainers and doctor) is in city_jobs.lua; this is what only the mayor does, from its job tick (BotJobs):
--   - founds the city at the plan's spot the first time it is online (botFoundCity; idempotent: botCityInfo first);
--   - gives the city's bots their house deeds and seed credits (simulated income), and keeps its own bank for upkeep;
--   - turns zoning off, sets the taxes, and at rank 3 the specialization and the planetary map registration;
--   - at each rank places that rank's civic buildings (the cantina, hospital and theater are placed by the city's
--     entertainers and doctor, whose skills allow them), and at rank 5 walks to each decoration spot and places it;
--   - keeps the treasury above two weeks of upkeep, topping it up to four (botCityDeposit, from its own bank);
--   - runs for mayor unless a human holds the seat or is running (then it votes for the human, as the citizens do);
--   - stands at the city hall and talks politics: taxes, the rank, the treasury, the next election.
-- When a human is mayor it no longer governs (it can't), but still keeps the treasury paid. Every step is an event on
-- the mayor; chores run every minute (BotCityJobs:devFast: every 10 s).

-- Always (re)loaded here, first: a console reloadscreenplays then picks up city_jobs.lua too (citizen.lua, loaded
-- after this, finds it there)
includeFile("../custom_scripts/screenplays/bots/city_jobs.lua")

BotMayor = ScreenPlay:new {
	screenplayName = "BotMayor",

	-- What the talk bridge knows the job as
	kit = "politician",
	place = "city hall",

	-- Politics now and then with a human within talkRange (seconds between lines), a greeting for a human who comes
	-- within greetRange (once per greetCooldown each)
	talkEvery = {240, 480},
	talkRange = 25,
	greetRange = 10,
	greetCooldown = 1800,
	-- An emote at the city hall every idleEvery seconds
	idleEvery = {60, 180},
	idleEmotes = {"nod", "ponder", "adjust", "stretch", "contemplate", "tap"},
	-- Back at the station when further than this (m)
	stationSlack = 4,
	-- After a refused specialization, registration or candidacy, try again after this long (seconds; Core3's
	-- specialization cooldown is a week, a candidacy once a day)
	retrySeconds = 21600,
	-- Development (toRank): expand anyway when a rank's buildings aren't all up after this long (seconds)
	devStepTimeout = 600,
}

local function bk(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function ck(field)
	return "botcity:" .. field
end

local function between(range)
	return getRandomNumber(range[1], range[2])
end

local function firstOf(name)
	return tostring(name or ""):match("^(%S+)") or ""
end

local function credits(n)
	local s = tostring(math.floor(tonumber(n) or 0))

	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function BotMayor:start(pBot, oid)
	self:clear(oid)

	local now = os.time()

	writeData(bk(oid, "cityNextChore"), now + 3)
	writeData(bk(oid, "nextIdle"), now + between(self.idleEvery))
	writeData(bk(oid, "nextTalk"), now + between(self.talkEvery))

	-- Once the hall stands, it logs in on the square in front of it (its roster station is where the hall went up)
	if BotCityJobs:freshLogin(pBot, oid) and BotCityJobs:info() ~= nil then
		local s = self:station(oid)

		SceneObject(pBot):teleport(s.x, BotCityJobs:ground(pBot, s.x, s.y), s.y, 0)
	end
end

function BotMayor:clear(oid)
	BotCityJobs:release(oid)
	deleteStringData(bk(oid, "cityPlacing"))
	deleteStringData(bk(oid, "cityMove"))
	deleteData(bk(oid, "cityNextChore"))
end

-- Where it stands: on the square in front of the city hall
function BotMayor:station(oid)
	local spot = BotCityJobs:plan().mayorSpot

	return {x = spot.x, y = spot.y, z = 0, cell = 0}
end

function BotMayor:busy(oid)
	return BotCityJobs:placing(oid) or BotCityJobs:moving(oid)
end

function BotMayor:tick(pBot, oid, now)
	if BotCityJobs:cloneIfDead(pBot, oid, now) then
		return
	end

	BotCityJobs:checkMove(pBot, oid, now)

	if self:busy(oid) then
		if BotCityJobs:placing(oid) and now - readData(bk(oid, "cityPlacingSince")) > BotCityJobs.holdTimeout then
			print("BotCity: " .. BotJobs:name(oid) .. ": " .. readStringData(bk(oid, "cityPlacing")) .. " took too long, dropped")
			self:clear(oid)
			writeData(bk(oid, "cityNextChore"), now + 2)
		end

		return
	end

	if now >= readData(bk(oid, "cityNextChore")) then
		self:chores(pBot, oid, now)

		if self:busy(oid) then
			return
		end
	end

	self:talk(pBot, oid, now)
end

-- The city's business, once a minute
function BotMayor:chores(pBot, oid, now)
	writeData(bk(oid, "cityNextChore"), now + BotCityJobs:choreEvery())

	local info = BotCityJobs:info()

	if info == nil then
		self:found(pBot, oid, now)
		return
	end

	BotCityJobs:publish(info)
	self:announce(pBot, oid, info)
	self:grants(oid, now)

	local isMayor = info.mayor == oid

	self:treasury(pBot, oid, info, isMayor, now)

	if isMayor and self:govern(pBot, oid, info, now) then
		return
	end

	self:election(pBot, oid, info, isMayor, now)
	BotCityJobs:vote(pBot, oid, info)

	if BotCityJobs:houseChores(pBot, oid, now, info) then
		return
	end

	if self:devStep(pBot, oid, info, now) then
		return
	end

	self:backToStation(pBot, oid)
end

-- Founding: the city hall at the plan's spot, by name (the C++ makes the deed and does what the naming window would)
function BotMayor:found(pBot, oid, now)
	if botFoundCity == nil then
		if readData(ck("noBindings")) == 0 then
			writeData(ck("noBindings"), 1)
			print("BotCity: this build has no city bindings; the mayor waits")
		end

		return
	end

	if now < readData(ck("foundRetry")) then
		return
	end

	writeData(ck("foundRetry"), now + (BotCityJobs:fast() and 30 or 300))

	local plan = BotCityJobs:plan()
	local hall = plan.hall
	local x, y = BotCityJobs:worldXY(pBot)

	-- Not where the hall goes up: out on the square first
	if math.sqrt((x - hall.x) ^ 2 + (y - hall.y) ^ 2) < (BotCityJobs.clearance.cityhall or 56) then
		local s = self:station(oid)

		BotCityJobs:go(pBot, oid, s.x, BotCityJobs:ground(pBot, s.x, s.y), s.y, 0, "found")
		return
	end

	self:foundNow(pBot, oid, now)
end

function BotMayor:foundNow(pBot, oid, now)
	local plan = BotCityJobs:plan()
	local hall = plan.hall

	if botCheckSite ~= nil then
		local site = botCheckSite(plan.planet, hall.x, hall.y, 150) or {}

		if site.ok == false then
			local reasons = type(site.reasons) == "table" and table.concat(site.reasons, ", ") or tostring(site.reasons)
			print("BotCity: the site check says no: " .. reasons .. "; founding anyway (the founding makes the same checks)")
		end
	end

	local id = botFoundCity(pBot, hall.x, hall.y, hall.angle, plan.name)

	print("BotCity: " .. BotJobs:name(oid) .. " founds " .. plan.name .. " at " .. hall.x .. " " .. hall.y .. ": city " .. tostring(id))

	if (tonumber(id) or 0) ~= 0 then
		writeData(bk(oid, "cityNextChore"), now + 5)
		BotJobs:reply(pBot, 0, "spatial", BotLines:pick("mayor", "founded", nil, plan.key), "happy")
	end
end

-- A rank-up since the last chore: said out loud
function BotMayor:announce(pBot, oid, info)
	local known = readData(ck("announcedRank"))

	writeData(ck("announcedRank"), info.rank)

	if known == 0 or info.rank <= known then
		return
	end

	print("BotCity: " .. BotCityJobs:name() .. " is rank " .. info.rank .. " (" .. BotCityJobs:rankName(info.rank) .. ")")

	local built = {}

	for _, item in ipairs(BotCityJobs:plan().civic) do
		if item.rank == info.rank then
			table.insert(built, BotCityJobs.kindLabels[item.kind] or item.kind)
		end
	end

	local line = BotLines:pick("mayor", "rankUp", nil, BotCityJobs:plan().key)

	if line ~= nil and #built == 0 and line:find("{built}", 1, true) then
		line = BotLines.mayor.rankUp[1]:gsub("{city}", BotCityJobs:name())
	end

	BotJobs:reply(pBot, 0, "spatial", BotCityJobs:fill(line, {rank = info.rank, rankName = BotCityJobs:rankName(info.rank),
		built = table.concat(built, " and ")}), "happy")
end

-- The mayor's gifts to the city's bots: house deeds and seed credits, each in an event on that bot
function BotMayor:grants(oid, now)
	for _, entry in ipairs(BotCityJobs:cityEntries()) do
		local pOther = botGetCreature ~= nil and botGetCreature(firstOf(entry.name)) or nil

		if pOther ~= nil then
			local otherOid = SceneObject(pOther):getObjectID()

			if now >= readData(bk(otherOid, "cityGrantAt")) then
				writeData(bk(otherOid, "cityGrantAt"), now + (BotCityJobs:fast() and 60 or 1800))
				createEvent(100, "BotCityJobs", "grant", pOther, "")
			end
		end
	end
end

-- Keep the treasury above two weeks of upkeep (counting the next rank's buildings), topping it up to four, from the
-- mayor's bank; its bank is kept up by its (simulated) income
function BotMayor:treasury(pBot, oid, info, isMayor, now)
	if botCityDeposit == nil or (not isMayor and not BotCityJobs.fundWhenHumanMayor) then
		return
	end

	local plan = BotCityJobs:plan()
	local nextRank = math.min(info.rank + 1, 5)
	local decorations = nextRank >= BotCityJobs.decorationRank and math.max(info.decorations, #plan.decorations) or info.decorations
	-- The plan's next-rank costs, or the city's own weekly bill if that is higher
	local weekly = math.max(BotCityJobs:upkeepAt(nextRank, decorations), info.upkeep or 0)

	if info.treasury >= weekly * BotCityJobs.treasuryWeeks or now < readData(ck("depositAt")) then
		return
	end

	local amount = math.ceil((weekly * BotCityJobs.treasuryTopUpWeeks - info.treasury) / 1000) * 1000
	local creature = CreatureObject(pBot)
	local funds = creature:getCashCredits() + creature:getBankCredits()

	if funds < amount then
		creature:addBankCredits(amount - funds, false)
	end

	-- From the mayor's own cash and bank (the C++ pays it in a task of its own: the next chores see it)
	local ok = botCityDeposit(BotCityJobs:name(), amount, pBot)

	-- So BotJobs:checkTips doesn't take the income for a tip
	writeData(bk(oid, "cash"), BotJobs:cash(pBot) - (ok and amount or 0))
	writeData(ck("depositAt"), now + 30)

	print("BotCity: " .. BotJobs:name(oid) .. " deposits " .. credits(amount) .. " credits (treasury " .. credits(info.treasury) ..
		", upkeep about " .. credits(weekly) .. " a week): " .. tostring(ok))
end

-- Governing (only while it is mayor): zoning, taxes, the rank's buildings, registration, specialization,
-- decorations. True if it started a placement (the next chores wait for it).
function BotMayor:govern(pBot, oid, info, now)
	local plan = BotCityJobs:plan()
	local name = plan.name

	if info.zoning and plan.zoningOff and botCityZoning ~= nil then
		print("BotCity: zoning off: " .. tostring(botCityZoning(name, false)))
	end

	-- Taxes: Core3 refuses them below rank 2, and the travel tax until a shuttleport stands (index 3). Each is set once,
	-- as soon as it may be; a refusal is tried again later.
	if botCitySetTax ~= nil and info.rank >= 2 and now >= readData(ck("taxRetry")) then
		local set, failed = {}, false

		for _, tax in ipairs(plan.taxes) do
			if readData(ck("taxSet:" .. tax.index)) ~= 1 and (tax.index ~= 3 or self:shuttleportUp(pBot, info)) then
				local ok = botCitySetTax(name, tax.index, tax.value)

				if ok then
					writeData(ck("taxSet:" .. tax.index), 1)
				else
					failed = true
				end

				table.insert(set, tax.index .. "=" .. tax.value .. " " .. tostring(ok))
			end
		end

		if failed then
			writeData(ck("taxRetry"), now + (BotCityJobs:fast() and 30 or 300))
		end

		if #set > 0 then
			print("BotCity: taxes " .. table.concat(set, ", "))
		end
	end

	-- The rank's civic buildings (its own; the entertainers and the doctor place theirs)
	for _, item in ipairs(plan.civic) do
		if item.by == "mayor" and item.rank <= info.rank and BotCityJobs:mayTry(item) and BotCityJobs:builtOid(item, info, pBot) == nil then
			BotCityJobs:startPlace(pBot, oid, item)
			return true
		end
	end

	if info.rank >= plan.registerRank and not info.registered and botCityRegister ~= nil and now >= readData(ck("registerRetry")) then
		local ok = botCityRegister(name)

		print("BotCity: " .. name .. " registered on the planetary map: " .. tostring(ok))

		if not ok then
			writeData(ck("registerRetry"), now + (BotCityJobs:fast() and 60 or self.retrySeconds))
		end
	end

	local specNow = info.spec:match("city_spec_([%w_]+)") or info.spec

	if plan.spec ~= nil and info.rank >= plan.specRank and specNow ~= plan.specKey and botCitySetSpec ~= nil and
		now >= readData(ck("specRetry")) then
		local ok = botCitySetSpec(name, plan.spec)

		print("BotCity: specialization " .. plan.spec .. ": " .. tostring(ok))

		if not ok then
			writeData(ck("specRetry"), now + (BotCityJobs:fast() and 60 or self.retrySeconds))
		end
	end

	if info.rank >= BotCityJobs.decorationRank then
		local item = self:nextDecoration(info)

		if item ~= nil then
			self:startDecoration(pBot, oid, item)
			return true
		end
	end

	return false
end

-- Is the shuttleport standing (the travel tax needs it)?
function BotMayor:shuttleportUp(pBot, info)
	for _, item in ipairs(BotCityJobs:plan().civic) do
		if item.kind == "shuttleport" and BotCityJobs:builtOid(item, info, pBot) ~= nil then
			return true
		end
	end

	return false
end

-- The next planned decoration not yet standing: by position when the C++ lists them, else in plan order by count
function BotMayor:nextDecoration(info)
	if botPlaceDecoration == nil then
		return nil
	end

	for i, item in ipairs(BotCityJobs:plan().decorations) do
		local standing = false

		if info.decorationList ~= nil then
			for _, d in ipairs(info.decorationList) do
				if math.sqrt((d.x - item.x) ^ 2 + (d.y - item.y) ^ 2) <= 3 then
					standing = true
				end
			end
		else
			standing = i <= info.decorations
		end

		if not standing and BotCityJobs:mayTry(item) then
			return item
		end
	end

	return nil
end

-- Decorations go where the mayor stands (Core3's CityDecorationTask): walk to the spot, then place
function BotMayor:startDecoration(pBot, oid, item)
	writeStringData(bk(oid, "cityPlacing"), item.id)
	writeData(bk(oid, "cityPlacingSince"), os.time())
	BotCityJobs:go(pBot, oid, item.x, BotCityJobs:ground(pBot, item.x, item.y), item.y, 0, "deco:" .. item.index)
end

-- The walk is over (BotCityJobs:moved): out of the hall's way to found the city, a decoration spot, or back at the
-- station
function BotMayor:cityArrived(pBot, oid, purpose, how)
	if purpose == "found" then
		self:foundNow(pBot, oid, os.time())
		return
	end

	local index = tonumber(purpose:match("^deco:(%d+)$") or "")

	if index == nil then
		return
	end

	local item = BotCityJobs:plan().decorations[index]

	deleteStringData(bk(oid, "cityPlacing"))

	if item == nil then
		return
	end

	-- It goes up facing as the mayor faces
	if item.heading ~= nil then
		SceneObject(pBot):updateDirection(math.rad(item.heading))
	end

	local decoration = botPlaceDecoration(pBot, item.template)

	if (tonumber(decoration) or 0) ~= 0 then
		writeData(ck("built:" .. item.id), tonumber(decoration))
		print("BotCity: " .. BotJobs:name(oid) .. " placed decoration " .. index .. " (" .. item.template .. ")")
	else
		writeData(ck("retry:" .. item.id), os.time() + BotCityJobs:retryEvery())
		print("BotCity: " .. BotJobs:name(oid) .. " couldn't place decoration " .. index .. " (" .. item.template .. ")")
	end

	-- On to the next one soon
	writeData(bk(oid, "cityNextChore"), os.time() + 2)
end

-- A placement is over (BotCityJobs:placeDone): the next chores soon
function BotMayor:cityPlaced(pBot, oid, item, ok)
	writeData(bk(oid, "cityNextChore"), os.time() + 2)
end

-- Elections: run unless a human holds the seat (and is still a citizen) or is running
function BotMayor:election(pBot, oid, info, isMayor, now)
	if botCityCandidate == nil or info.votingLocked or now < readData(ck("candidateRetry")) then
		return
	end

	local running, humanRunning = false, false

	for _, c in ipairs(info.candidates) do
		if c.oid == oid then
			running = true
		elseif not BotCityJobs:isBotOid(c.oid) then
			humanRunning = true
		end
	end

	local humanSeat = not isMayor and info.mayor ~= 0 and not BotCityJobs:isBotOid(info.mayor)

	if humanSeat and info.citizenOids ~= nil and not info.citizenOids[info.mayor] then
		-- The human mayor has left the city: stepped down
		humanSeat = false
	end

	if running or humanRunning or humanSeat then
		return
	end

	local ok = botCityCandidate(pBot, BotCityJobs:name())

	print("BotCity: " .. BotJobs:name(oid) .. " registers for the mayoral race: " .. tostring(ok))

	if not ok then
		writeData(ck("candidateRetry"), now + (BotCityJobs:fast() and 60 or self.retrySeconds))
	end
end

function BotMayor:backToStation(pBot, oid)
	local s = self:station(oid)
	local x, y = BotCityJobs:worldXY(pBot)

	if SceneObject(pBot):getParentID() == (s.cell or 0) and math.sqrt((x - s.x) ^ 2 + (y - s.y) ^ 2) <= self.stationSlack then
		return
	end

	local z = (s.z ~= nil and s.z ~= 0) and s.z or BotCityJobs:ground(pBot, s.x, s.y)

	BotCityJobs:go(pBot, oid, s.x, z, s.y, s.cell or 0, "station")
end

-- Development: after BotCityJobs:fastForward / toRank (an event on the mayor)
function BotMayor:devExpand(pBot, args)
	local oid = SceneObject(pBot):getObjectID()
	local info = BotCityJobs:info()

	writeData(bk(oid, "cityNextChore"), 0)

	if info == nil then
		print("BotCity: not founded yet; founding first")
		return
	end

	if info.rank >= 5 then
		print("BotCity: already rank 5")
		return
	end

	local ok = botCityExpand(BotCityJobs:name())
	local after = BotCityJobs:info()

	writeData(ck("toRankSince"), os.time())

	if readData(ck("toRank")) == -1 and after ~= nil then
		-- fastForward: just this rank
		writeData(ck("toRank"), after.rank)
	end
	print("BotCity: dev expand: " .. tostring(ok) .. ", now rank " .. tostring(after ~= nil and after.rank or "?"))

	-- The city's other bots look at once too
	for _, entry in ipairs(BotCityJobs:cityEntries()) do
		local pOther = botGetCreature(firstOf(entry.name))

		if pOther ~= nil then
			deleteData(bk(SceneObject(pOther):getObjectID(), "cityNextCheck"))
		end
	end
end

-- Development (toRank): the rank's buildings are all up (or it has waited long enough): the next rank
function BotMayor:devStep(pBot, oid, info, now)
	local target = readData(ck("toRank"))

	if target <= 0 then
		return false
	end

	local missing = {}

	for _, item in ipairs(BotCityJobs:plan().civic) do
		if item.rank <= info.rank and BotCityJobs:builtOid(item, info, item.by == "mayor" and pBot or nil) == nil then
			table.insert(missing, item.kind)
		end
	end

	if info.rank >= BotCityJobs.decorationRank and self:nextDecoration(info) ~= nil then
		table.insert(missing, "decorations")
	end

	if info.rank >= target then
		if #missing == 0 then
			deleteData(ck("toRank"))
			writeData(ck("fast"), 0)
			print("BotCity: fast-forward done: rank " .. info.rank .. ", every building up, treasury " .. credits(info.treasury))
		end

		return false
	end

	if #missing > 0 and now - readData(ck("toRankSince")) < self.devStepTimeout then
		return false
	end

	if #missing > 0 then
		print("BotCity: fast-forward: still missing at rank " .. info.rank .. ": " .. table.concat(missing, ", ") .. "; expanding anyway")
	end

	createEvent(10, "BotMayor", "devExpand", pBot, "")

	return true
end

-- Talk: a greeting for a human who comes up, politics with one near, an emote now and then
function BotMayor:talk(pBot, oid, now)
	local pHuman = BotCityJobs:humanNear(pBot, self.greetRange)

	if pHuman ~= nil then
		local humanOid = SceneObject(pHuman):getObjectID()

		if now - readData(bk(oid, "greeted:" .. humanOid)) >= self.greetCooldown then
			writeData(bk(oid, "greeted:" .. humanOid), now)
			writeData(bk(oid, "nextTalk"), now + between(self.talkEvery))
			botEmote(pBot, "wave", humanOid)
			BotJobs:reply(pBot, 0, "spatial", self:line("greet", CreatureObject(pHuman):getFirstName()), "happy")
			return
		end
	end

	if now >= readData(bk(oid, "nextTalk")) then
		writeData(bk(oid, "nextTalk"), now + between(self.talkEvery))

		if BotCityJobs:humanNear(pBot, self.talkRange) ~= nil then
			BotJobs:reply(pBot, 0, "spatial", self:line(readData(ck("knownRank")) >= 5 and "politicsTop" or "politics", nil), "")
			return
		end
	end

	if now >= readData(bk(oid, "nextIdle")) then
		writeData(bk(oid, "nextIdle"), now + between(self.idleEvery))
		botEmote(pBot, self.idleEmotes[getRandomNumber(1, #self.idleEmotes)], 0)
	end
end

-- A line with the city's numbers filled in (from the last chores)
function BotMayor:line(kind, name)
	local plan = BotCityJobs:plan()
	local rank = math.max(readData(ck("knownRank")), 1)
	local nextUp = BotCityJobs:nextBuildings(rank)
	local line = BotLines:pick("mayor", kind, name, plan.key)

	-- A next-rank line needs a next rank
	if line ~= nil and nextUp == nil and line:find("{next}", 1, true) then
		line = BotLines:pick("mayor", "politicsTop", name, plan.key)
	end

	return BotCityJobs:fill(line, {rank = rank, rankName = BotCityJobs:rankName(rank), next = nextUp or "",
		treasury = credits(readData(ck("treasury"))) .. " credits", citizens = readData(ck("citizens"))})
end

function BotMayor:state(pBot, oid)
	local rank = readData(ck("knownRank"))
	local state = rank > 0 and ("mayor of " .. BotCityJobs:name() .. ", rank " .. rank) or "city not founded"

	if BotCityJobs:placing(oid) then
		state = state .. ", placing " .. readStringData(bk(oid, "cityPlacing"))
	elseif BotCityJobs:moving(oid) then
		state = state .. ", walking"
	end

	if readData(ck("mayor")) ~= 0 and readData(ck("mayor")) ~= oid then
		state = state .. " (someone else holds the seat)"
	end

	return state
end

-- The job module interface (bot_jobs.lua): the mayor only talks, through the brain; no actions

function BotMayor:intent(text)
	return nil
end

function BotMayor:isAction(intent)
	return false
end

function BotMayor:allowed(action)
	return nil
end

function BotMayor:act(pBot, pPlayer, action, channel, brainLine)
end

function BotMayor:onSpoken(pBot, oid, pSpeaker, channel)
	if channel == "spatial" and not self:busy(oid) then
		botFace(pBot, pSpeaker)
	end
end

function BotMayor:onEvent(pBot, oid, name, pOther, detail)
	BotCityJobs:onMoveEvent(pBot, oid, name, pOther, detail)
end

-- For the brain (the request's extra fields, if BotJobs:ask asks the module): the city's news, and where it is
function BotMayor:requestFields(pBot, oid)
	return {cityInfo = BotCityJobs:summary(), cityName = BotCityJobs:name(), place = "cityhall"}
end

BotJobModules = BotJobModules or {}
BotJobModules.mayor = BotMayor
