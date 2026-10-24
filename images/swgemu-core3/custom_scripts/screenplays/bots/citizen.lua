-- Bot players (Phase 6): the player city's citizens, players with their own trades who live there. Spec:
-- ~/github/swgemu/specs/2026-10-23-player-city/. Each one (from its job tick, BotJobs):
--   - places its house on its lot once the city stands with zoning off, then declares residence (city_jobs.lua);
--   - lives a day like the Phase 1 crowd, walking (the mover, botMoveTo) between its house, the city's cantina, the
--     bank, the gardens, the square by the city hall and the streets between the houses: errands by day, the cantina
--     in the evening, home at night (by the server's clock; city bots are online only while a human is on Naboo);
--   - votes for any human running for mayor (two humans: the citizens split), else for the incumbent if running.
-- They talk through the brain (job "citizen", no actions), knowing their trade and the city.

if BotCityJobs == nil then
	includeFile("../custom_scripts/screenplays/bots/city_jobs.lua")
end

BotCitizen = ScreenPlay:new {
	screenplayName = "BotCitizen",

	-- What the talk bridge knows the job as (its trade goes in the request as role)
	kit = "traveller",
	place = "city",

	-- Where to go next, by the hour (weights; a place that isn't built yet is skipped)
	schedule = {
		{from = 0, to = 6, weights = {home = 1}},
		{from = 6, to = 9, weights = {home = 2, bank = 2, streets = 3, hall = 1}},
		{from = 9, to = 17, weights = {streets = 4, bank = 3, hall = 2, garden = 2, cantina = 1, home = 1}},
		{from = 17, to = 22, weights = {cantina = 5, streets = 2, garden = 1, hall = 1, home = 1}},
		{from = 22, to = 24, weights = {home = 4, cantina = 2}},
	},
	-- Seconds spent at each place
	linger = {home = {600, 1800}, cantina = {600, 1500}, bank = {180, 480}, streets = {120, 360}, hall = {180, 480},
		garden = {180, 480}},
	-- How far in front of a building visitors stand (m)
	frontOf = {bank = 8, garden = 6, house = 7},
	-- At the cantina it sits down this often (percent)
	sitChance = 35,
	-- An emote while out every emoteEvery seconds; a wave at a human who walks within waveRange, once per waveCooldown
	emoteEvery = {90, 300},
	emotes = {"stretch", "yawn", "ponder", "scratch", "fidget", "adjust", "nod", "sigh"},
	waveRange = 6,
	waveCooldown = 900,
	-- Seconds between vote checks
	voteEvery = 1800,
	-- Errands at a stroll (botMoveTo's pace)
	pace = "walk",

	-- Safety. The plain around the city has aggressive creatures (spineflap soldiers, nightspiders) that wander in and
	-- hurt citizens caught outdoors. A citizen under attack (in combat while outdoors) or knocked down goes straight
	-- into its house (put there: it can't outrun them), and the whole town keeps to houses and the cantina for
	-- dangerSeconds, so the next ones aren't caught out either. A citizen that dies clones itself (the nearest cloner:
	-- the city's own centre once it stands) and is put back at its house.
	handlesDeath = true,
	dangerSeconds = 900,
	shelterStay = {300, 900},
	-- Only these places while it isn't safe
	safePlaces = {home = true, cantina = true},
	-- Wait this long (ms) after it falls before checking it is up, and after dying before cloning, and after being
	-- cloned before putting it home
	hurtCheckMs = 12000,
	cloneDelayMs = 10000,
	homeAfterCloneMs = 15000,
	-- At most one shelter per bot this often (seconds)
	shelterEvery = 20,
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

local function flat(x1, y1, x2, y2)
	return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

-- Logging in: at home once its house stands (the C++ puts it at its roster station, on its lot, which the house now
-- covers), else at the station; about to set off
function BotCitizen:start(pBot, oid)
	self:clear(oid)

	local now = os.time()

	writeData(bk(oid, "cityLingerUntil"), now + getRandomNumber(5, 30))
	writeData(bk(oid, "nextIdle"), now + between(self.emoteEvery))
	writeData(bk(oid, "cityNextVote"), now + 60)

	local home = BotCityJobs:freshLogin(pBot, oid) and self:destination(pBot, oid, "home", false) or nil

	if home ~= nil then
		SceneObject(pBot):teleport(home.x, home.z, home.y, home.cell)
		writeStringData(bk(oid, "cityAt"), "home")
		writeData(bk(oid, "cityLingerUntil"), now + getRandomNumber(20, 120))
	end
end

function BotCitizen:clear(oid)
	self:releaseSpot(oid)
	BotCityJobs:release(oid)
	deleteStringData(bk(oid, "cityPlacing"))
	deleteStringData(bk(oid, "cityMove"))
	deleteStringData(bk(oid, "cityAt"))
	deleteStringData(bk(oid, "cityErrand"))
	deleteData(bk(oid, "cityNextCheck"))
	deleteData(bk(oid, "sitting"))
end

function BotCitizen:tick(pBot, oid, now)
	if BotCityJobs:cloneIfDead(pBot, oid, now) then
		return
	end

	BotCityJobs:checkMove(pBot, oid, now)

	-- Attacked on the way to its lot too: in, and the placement tried again later
	if BotCityJobs:placing(oid) and self:danger(pBot, oid, now, true) then
		return
	end

	if BotCityJobs:placing(oid) then
		if now - readData(bk(oid, "cityPlacingSince")) > BotCityJobs.holdTimeout then
			print("BotCity: " .. BotJobs:name(oid) .. ": placing took too long, dropped")
			deleteStringData(bk(oid, "cityPlacing"))
			deleteStringData(bk(oid, "cityMove"))
			BotCityJobs:release(oid)
		end

		return
	end

	if self:danger(pBot, oid, now) then
		return
	end

	if now >= readData(bk(oid, "cityNextCheck")) then
		writeData(bk(oid, "cityNextCheck"), now + BotCityJobs:checkEvery())

		local info = BotCityJobs:info()

		if info ~= nil then
			if BotCityJobs:houseChores(pBot, oid, now, info) then
				self:leaving(pBot, oid)
				return
			end

			if now >= readData(bk(oid, "cityNextVote")) then
				writeData(bk(oid, "cityNextVote"), now + (BotCityJobs:fast() and 30 or self.voteEvery))
				BotCityJobs:vote(pBot, oid, info)
			end
		end
	end

	if BotCityJobs:moving(oid) then
		return
	end

	if now >= readData(bk(oid, "cityLingerUntil")) then
		self:nextErrand(pBot, oid, now)
		return
	end

	self:idle(pBot, oid, now)
end

-- The hour's weights
function BotCitizen:weights()
	local hour = LivingCities ~= nil and LivingCities:hour() or tonumber(os.date("*t").hour)

	for _, part in ipairs(self.schedule) do
		if hour >= part.from and hour < part.to then
			return part.weights, hour
		end
	end

	return self.schedule[1].weights, hour
end

-- Where next: by the hour, not where it is now (unless that's home at night), only places that exist
function BotCitizen:pick(pBot, oid)
	local weights = self:weights()
	local here = readStringData(bk(oid, "cityAt"))
	local choices, total = {}, 0

	local unsafe = self:unsafe()

	for place, weight in pairs(weights) do
		if (place ~= here or place == "home") and (not unsafe or self.safePlaces[place]) and
			self:destination(pBot, oid, place, true) ~= nil then
			table.insert(choices, {place = place, weight = weight})
			total = total + weight
		end
	end

	if total == 0 then
		return unsafe and "home" or "streets"
	end

	table.sort(choices, function(a, b) return a.place < b.place end)

	local roll = getRandomNumber(1, math.max(1, math.floor(total * 100))) / 100

	for _, c in ipairs(choices) do
		roll = roll - c.weight

		if roll <= 0 then
			return c.place
		end
	end

	return choices[#choices].place
end

-- A point for a place ({x, z, y, cell}), or nil when the place isn't there (check: only whether it exists)
function BotCitizen:destination(pBot, oid, place, check)
	local plan = BotCityJobs:plan()
	local planet = plan.planet

	local function outdoors(x, y)
		return {x = x, z = BotCityJobs:ground(pBot, x, y), y = y, cell = 0}
	end

	local function towardCentre(x, y, metres)
		local cx, cy = plan.center.x, plan.center.y
		local d = flat(x, y, cx, cy)

		if d < 0.1 then
			return outdoors(x + metres, y)
		end

		return outdoors(x + (cx - x) / d * metres, y + (cy - y) / d * metres)
	end

	if place == "home" then
		local lot = BotCityJobs:houseLot(oid)
		local house = lot ~= nil and BotCityJobs:ownedAt(pBot, lot) or nil

		if house == nil then
			return nil
		end

		if check then
			return true
		end

		local inside = self:homeInside(oid, house)

		return inside or towardCentre(lot.x, lot.y, self.frontOf.house)
	elseif place == "cantina" then
		local _, cell = BotCityJobs:workplace("cantina", nil, nil)

		if cell == nil then
			return nil
		end

		if check then
			return true
		end

		local spot = self:claimSpot(oid)

		return spot ~= nil and {x = spot.x, z = spot.z, y = spot.y, cell = cell} or nil
	elseif place == "bank" or place == "garden" then
		local built = {}

		for _, item in ipairs(plan.civic) do
			if (item.kind == place or item.kind:match("^" .. place .. "_")) and readData(ck("built:" .. item.id)) ~= 0 then
				table.insert(built, item)
			end
		end

		if #built == 0 then
			return nil
		end

		if check then
			return true
		end

		local item = built[getRandomNumber(1, #built)]

		return towardCentre(item.x, item.y, self.frontOf[place])
	elseif place == "hall" then
		if readData(ck("knownRank")) == 0 then
			return nil
		end

		if check then
			return true
		end

		local spot = plan.squareSpots[getRandomNumber(1, #plan.squareSpots)]

		return outdoors(spot.x + getRandomNumber(-1, 1), spot.y + getRandomNumber(-1, 1))
	elseif place == "streets" then
		local points = self:streetPoints()

		if #points == 0 then
			return nil
		end

		if check then
			return true
		end

		local p = points[getRandomNumber(1, #points)]

		return outdoors(p.x + getRandomNumber(-3, 3), p.y + getRandomNumber(-3, 3))
	end

	return nil
end

-- The streets: the plan's own, else in front of each house lot and half way between neighbouring lots
function BotCitizen:streetPoints()
	local plan = BotCityJobs:plan()
	local points = {}

	if #plan.streets > 0 then
		return plan.streets
	end

	local cx, cy = plan.center.x, plan.center.y
	local fronts = {}

	for _, lot in ipairs(plan.houses) do
		local d = flat(lot.x, lot.y, cx, cy)

		if d > 0.1 then
			table.insert(fronts, {x = lot.x + (cx - lot.x) / d * 10, y = lot.y + (cy - lot.y) / d * 10})
		end
	end

	for i, p in ipairs(fronts) do
		table.insert(points, p)

		local q = fronts[i % #fronts + 1]

		if q ~= p then
			table.insert(points, {x = (p.x + q.x) / 2, y = (p.y + q.y) / 2})
		end
	end

	return points
end

-- Inside its house: a room of the building's template (city_jobs.lua homes), or nil
function BotCitizen:homeInside(oid, house)
	local houseOid = tonumber(house.oid) or 0
	local pHouse = getSceneObject(houseOid)

	if pHouse == nil then
		return nil
	end

	local template = tostring(house.template or SceneObject(pHouse):getTemplateObjectPath() or "")

	for _, home in ipairs(BotCityJobs.homes) do
		if template:find(home.match, 1, true) ~= nil then
			local pCell = BuildingObject(pHouse):getNamedCell(home.cell)

			if pCell ~= nil then
				return {x = home.x, z = home.z, y = home.y, cell = SceneObject(pCell):getObjectID()}
			end
		end
	end

	return nil
end

-- A free spot in the cantina, held until it leaves
function BotCitizen:claimSpot(oid)
	local spots = BotCityJobs:plan().interiors.cantina.spots or {}
	local start = getRandomNumber(1, math.max(1, #spots))

	self:releaseSpot(oid)

	for k = 0, #spots - 1 do
		local i = (start + k - 1) % #spots + 1
		local holder = readData(ck("cantinaSpot:" .. i))

		if holder == 0 or holder == oid or not BotJobs:online(holder) then
			writeData(ck("cantinaSpot:" .. i), oid)
			writeData(bk(oid, "citySpot"), i)
			return spots[i]
		end
	end

	return nil
end

function BotCitizen:releaseSpot(oid)
	local i = readData(bk(oid, "citySpot"))

	if i ~= 0 and readData(ck("cantinaSpot:" .. i)) == oid then
		deleteData(ck("cantinaSpot:" .. i))
	end

	deleteData(bk(oid, "citySpot"))
end

-- Off somewhere: stand up first if sitting
function BotCitizen:leaving(pBot, oid)
	if readData(bk(oid, "sitting")) == 1 then
		botEnqueue(pBot, "stand", 0, "")
		writeData(bk(oid, "sitting"), 0)
	end

	self:releaseSpot(oid)
end

function BotCitizen:nextErrand(pBot, oid, now)
	local place = self:pick(pBot, oid)
	local here = readStringData(bk(oid, "cityAt"))

	-- At home at night: stay in
	if place == "home" and here == "home" then
		writeData(bk(oid, "cityLingerUntil"), now + between(self.linger.home))
		return
	end

	local wasSitting = readData(bk(oid, "sitting")) == 1

	self:leaving(pBot, oid)

	local point = self:destination(pBot, oid, place, false)

	if point == nil and not self:unsafe() then
		place = "streets"
		point = self:destination(pBot, oid, place, false)
	end

	if point == nil then
		writeData(bk(oid, "cityLingerUntil"), now + 60)
		return
	end

	deleteStringData(bk(oid, "cityAt"))
	writeStringData(bk(oid, "cityErrand"), place)

	if wasSitting then
		-- A moment to stand up
		writeStringData(bk(oid, "cityNext"), table.concat({place, point.x, point.z, point.y, point.cell}, "|"))
		createEvent(1500, "BotCitizen", "setOff", pBot, tostring(readData(bk(oid, "gen"))))
		writeData(bk(oid, "cityLingerUntil"), now + 30)
		return
	end

	BotCityJobs:go(pBot, oid, point.x, point.z, point.y, point.cell, "errand:" .. place, self.pace)
end

function BotCitizen:setOff(pBot, gen)
	if not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local place, x, z, y, cell = readStringData(bk(oid, "cityNext")):match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")

	deleteStringData(bk(oid, "cityNext"))

	if place ~= nil and not BotCityJobs:moving(oid) then
		BotCityJobs:go(pBot, oid, tonumber(x), tonumber(z), tonumber(y), tonumber(cell), "errand:" .. place, self.pace)
	end
end

-- There (BotCityJobs:moved, whether it walked or was put there)
function BotCitizen:cityArrived(pBot, oid, purpose, how)
	local place = purpose:match("^errand:(.+)$")

	if place == nil then
		return
	end

	local now = os.time()

	writeStringData(bk(oid, "cityAt"), place)
	deleteStringData(bk(oid, "cityErrand"))
	writeData(bk(oid, "cityLingerUntil"), now + between(self.linger[place] or {120, 300}))
	writeData(ck("stat:" .. place), readData(ck("stat:" .. place)) + 1)

	if how ~= "arrived" and how ~= "put" then
		writeData(ck("stat:stuck"), readData(ck("stat:stuck")) + 1)
	end

	if place == "cantina" and getRandomNumber(1, 100) <= self.sitChance then
		botEnqueue(pBot, "sitserver", 0, "")
		writeData(bk(oid, "sitting"), 1)
	end
end

-- Lingering: an emote now and then, a wave at a human walking by (not at home)
function BotCitizen:idle(pBot, oid, now)
	local here = readStringData(bk(oid, "cityAt"))

	if here == "" or here == "home" then
		return
	end

	local pHuman = BotCityJobs:humanNear(pBot, self.waveRange)

	if pHuman ~= nil then
		local humanOid = SceneObject(pHuman):getObjectID()

		if now - readData(bk(oid, "waved:" .. humanOid)) >= self.waveCooldown then
			writeData(bk(oid, "waved:" .. humanOid), now)
			botEmote(pBot, "wave", humanOid)
			return
		end
	end

	if now >= readData(bk(oid, "nextIdle")) then
		writeData(bk(oid, "nextIdle"), now + between(self.emoteEvery))

		if readData(bk(oid, "sitting")) ~= 1 then
			botEmote(pBot, self.emotes[getRandomNumber(1, #self.emotes)], 0)
		end
	end
end

function BotCitizen:state(pBot, oid)
	if BotCityJobs:placing(oid) then
		return "placing its house"
	end

	local errand = readStringData(bk(oid, "cityErrand"))

	if BotCityJobs:moving(oid) and errand ~= "" then
		return "walking to the " .. errand
	end

	local here = readStringData(bk(oid, "cityAt"))

	if here == "" then
		return "about to set off"
	end

	return (here == "home" and "at home" or ("at the " .. here)) .. (readData(bk(oid, "sitting")) == 1 and ", sitting" or "")
end

-- The job module interface (bot_jobs.lua): citizens only talk, through the brain; no actions

function BotCitizen:intent(text)
	return nil
end

function BotCitizen:isAction(intent)
	return false
end

function BotCitizen:allowed(action)
	return nil
end

function BotCitizen:act(pBot, pPlayer, action, channel, brainLine)
end

function BotCitizen:onSpoken(pBot, oid, pSpeaker, channel)
	if channel == "spatial" and not BotCityJobs:moving(oid) then
		botFace(pBot, pSpeaker)
	end
end

function BotCitizen:onEvent(pBot, oid, name, pOther, detail)
	if name == "incapacitated" then
		self:hurt(pBot, oid)
	elseif name == "died" then
		self:died(pBot, oid)
	elseif name == "cloned" then
		self:cloned(pBot, oid)
	else
		BotCityJobs:onMoveEvent(pBot, oid, name, pOther, detail)
	end
end

-- Safety

-- Is the town on its guard (somebody was attacked lately)?
function BotCitizen:unsafe()
	return os.time() < readData(ck("danger"))
end

local function down(pBot)
	local creature = CreatureObject(pBot)

	return creature:isDead() or creature:isIncapacitated()
end

-- From the tick: attacked outdoors (not in a fight it chose), or the town on its guard and this one still out. True if
-- it did something (the rest of the tick waits).
function BotCitizen:danger(pBot, oid, now, attackOnly)
	if down(pBot) or SceneObject(pBot):getParentID() ~= 0 then
		return false
	end

	local creature = CreatureObject(pBot)

	if creature:isInCombat() and not (BotFight ~= nil and BotFight:busy(oid)) then
		self:shelter(pBot, oid, now, "attacked")
		return true
	end

	if attackOnly then
		return false
	end

	if self:unsafe() and not self.safePlaces[readStringData(bk(oid, "cityAt"))] and readStringData(bk(oid, "cityErrand")) ~= "home" and
		not BotCityJobs:placing(oid) and readData(bk(oid, "cityDangerHome")) < now then
		-- Out when the alarm went up: home now
		writeData(bk(oid, "cityDangerHome"), now + 60)
		self:leaving(pBot, oid)

		local point = self:destination(pBot, oid, "home", false)

		if point ~= nil then
			deleteStringData(bk(oid, "cityAt"))
			writeStringData(bk(oid, "cityErrand"), "home")
			BotCityJobs:go(pBot, oid, point.x, point.z, point.y, point.cell, "errand:home")
			return true
		end
	end

	return false
end

-- Put it indoors at home (else beside the city hall), stop whatever it was doing, and keep it in for a while
function BotCitizen:shelter(pBot, oid, now, why)
	if now - readData(bk(oid, "cityShelterAt")) < self.shelterEvery then
		return
	end

	writeData(bk(oid, "cityShelterAt"), now)
	writeData(ck("danger"), now + self.dangerSeconds)
	writeData(ck("stat:sheltered"), readData(ck("stat:sheltered")) + 1)

	if botStop ~= nil then
		botStop(pBot)
	end

	deleteStringData(bk(oid, "cityMove"))
	deleteData(bk(oid, "cityMoveUntil"))
	deleteStringData(bk(oid, "cityErrand"))

	if BotCityJobs:placing(oid) then
		-- Its placement is off for now (the house chores start it again; a check left over is ignored)
		writeData(bk(oid, "cityPlaceSeq"), readData(bk(oid, "cityPlaceSeq")) + 1)
		deleteStringData(bk(oid, "cityPlacing"))
		deleteData(bk(oid, "cityPlacingSince"))
		BotCityJobs:release(oid)
	end

	self:leaving(pBot, oid)

	local point = self:destination(pBot, oid, "home", false)
	local at = "home"

	-- No house of its own yet: any finished house in town (or the cantina), else the square
	if point == nil then
		for _, lot in ipairs(BotCityJobs:plan().houses) do
			local built = readData(ck("built:" .. lot.id))
			local inside = built ~= 0 and self:homeInside(oid, {oid = built}) or nil

			if inside ~= nil then
				point, at = inside, "home"
				break
			end
		end
	end

	if point == nil then
		local _, cell = BotCityJobs:workplace("cantina", nil, nil)
		local spots = BotCityJobs:plan().interiors.cantina.spots or {}

		if cell ~= nil and #spots > 0 then
			point, at = {x = spots[1].x, z = spots[1].z, y = spots[1].y, cell = cell}, "cantina"
		end
	end

	if point == nil then
		local plan = BotCityJobs:plan()
		local spot = plan.squareSpots[1] or plan.center

		point = {x = spot.x, z = BotCityJobs:ground(pBot, spot.x, spot.y), y = spot.y, cell = 0}
		at = "hall"
	end

	local creature = CreatureObject(pBot)

	if creature:isInCombat() then
		creature:clearCombatState(false)
	end

	SceneObject(pBot):teleport(point.x, point.z, point.y, point.cell)
	writeStringData(bk(oid, "cityAt"), at)
	writeData(bk(oid, "cityLingerUntil"), now + between(self.shelterStay))
	print("BotCity: " .. BotJobs:name(oid) .. " sheltered (" .. why .. ")")
end

-- Knocked down: whatever it was doing is over; once it is up it goes in
function BotCitizen:hurt(pBot, oid)
	writeData(ck("danger"), os.time() + self.dangerSeconds)

	if botStop ~= nil then
		botStop(pBot)
	end

	deleteStringData(bk(oid, "cityMove"))
	deleteData(bk(oid, "cityMoveUntil"))
	deleteStringData(bk(oid, "cityErrand"))
	writeData(ck("stat:hurt"), readData(ck("stat:hurt")) + 1)
	print("BotCity: " .. BotJobs:name(oid) .. " was knocked down")
	createEvent(self.hurtCheckMs, "BotCitizen", "afterHurt", pBot, tostring(readData(bk(oid, "gen"))) .. "|6")
end

function BotCitizen:afterHurt(pBot, args)
	local gen, tries = tostring(args):match("^(%d+)|(%d+)$")

	if gen == nil or not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local creature = CreatureObject(pBot)

	if creature:isDead() then
		return
	end

	if creature:isIncapacitated() then
		if tonumber(tries) > 0 then
			createEvent(5000, "BotCitizen", "afterHurt", pBot, gen .. "|" .. (tonumber(tries) - 1))
		end

		return
	end

	self:shelter(pBot, oid, os.time(), "knocked down")
end

-- Dead: the job's own business is over; cloned after a pause
function BotCitizen:died(pBot, oid)
	writeData(ck("danger"), os.time() + self.dangerSeconds)
	writeData(ck("stat:died"), readData(ck("stat:died")) + 1)

	if botStop ~= nil then
		botStop(pBot)
	end

	self:clear(oid)
	print("BotCity: " .. BotJobs:name(oid) .. " died; cloning")
	createEvent(self.cloneDelayMs, "BotCitizen", "cloneNow", pBot, tostring(readData(bk(oid, "gen"))))
end

function BotCitizen:cloneNow(pBot, gen)
	if BotJobs:current(pBot, gen) and CreatureObject(pBot):isDead() then
		if botClone == nil then
			print("BotCity: " .. BotJobs:name(SceneObject(pBot):getObjectID()) .. " died, and this build can't clone it")
			return
		end

		botClone(pBot)
	end
end

function BotCitizen:cloned(pBot, oid)
	createEvent(self.homeAfterCloneMs, "BotCitizen", "backFromCloning", pBot, tostring(readData(bk(oid, "gen"))))
end

-- Cloned: put back at its house, and kept in for a while
function BotCitizen:backFromCloning(pBot, gen)
	if not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if down(pBot) then
		createEvent(5000, "BotCitizen", "backFromCloning", pBot, gen)
		return
	end

	writeData(bk(oid, "cityShelterAt"), 0)
	self:shelter(pBot, oid, os.time(), "cloned")
end

-- For the brain (the request's extra fields, if BotJobs:ask asks the module): the city's news, the citizen's trade,
-- and where it is (the bridge's CITY_PLACES)
BotCitizen.brainPlaces = {home = "home", cantina = "cantina", bank = "bank", streets = "street", hall = "cityhall", garden = "garden"}

function BotCitizen:requestFields(pBot, oid)
	local here = readStringData(bk(oid, "cityAt"))

	return {cityInfo = BotCityJobs:summary(), cityName = BotCityJobs:name(),
		role = BotCityJobs:roleOf(BotJobs:entry(readStringData(bk(oid, "first")))),
		place = BotCityJobs:moving(oid) and "street" or (self.brainPlaces[here] or "street")}
end

BotJobModules = BotJobModules or {}
BotJobModules.citizen = BotCitizen
