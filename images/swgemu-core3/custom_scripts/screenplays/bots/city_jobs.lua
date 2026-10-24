-- Bot players (Phase 6): the player city's shared work, for the mayor (mayor.lua), the citizens (citizen.lua) and the
-- city's dancer, musician and doctor. Spec: ~/github/swgemu/specs/2026-10-23-player-city/ (interfaces.md has the
-- contract with the C++ city and mover).
--
-- The plan (custom_scripts/bots/city.lua, BotCityPlan) says where everything goes; the world says what is already
-- there: botCityInfo for the city, botOwnedStructures for each bot's buildings, the bot's inventory for its deeds. So
-- every step is idempotent across restarts, and shared memory only caches what was looked up.
--   - Placing a building: the deed into the bot's inventory (giveItem, or the one left there by a failed try), stop
--     performing, walk within reach (outdoors), then the real /placestructure. Checked a few seconds later; a failure
--     is logged and tried again later.
--   - The city's dancer, musician and doctor keep their own jobs (dancer.lua, musician.lua, doctor.lua). This file
--     wraps those three modules for city bots only: until their building exists they work at their station outdoors
--     by the city hall; once it does, the job is held while they walk in (or, at login, they are put straight inside,
--     as a player logs in where they logged out), then it runs as usual. Bots of the other cities are not touched.
--   - Walking goes through the mover (botMoveTo); when it refuses, gives up ("stuck") or takes too long, the bot is put
--     where it was going.
--
-- Console (output in the pod log):
--   runLuaFunction BotCityJobs:status            the city: rank, citizens, treasury, next update, election, what is
--                                                built and what is next, and each city bot
--   runLuaFunction BotCityJobs:showPlan          the plan as read from city.lua, with any problems found in it
-- Development (the local server; ranks normally come one a week):
--   runLuaFunction BotCityJobs:fastForward       expand the city one rank now and place that rank's buildings at once
--   runLuaFunction BotCityJobs:toRank:<n>        expand rank by rank to n, placing each rank's buildings in between
--   runLuaFunction BotCityJobs:devFast:on        city chores every 10 s instead of every minute (off: back)
--   runLuaFunction BotCityJobs:devVote           every online city bot votes now

if BotCityPlan == nil then
	-- The plan (roster agent). A missing file must not stop the bots' jobs from loading.
	pcall(includeFile, "../custom_scripts/bots/city.lua")
end

BotCityJobs = ScreenPlay:new {
	screenplayName = "BotCityJobs",

	-- The bots' city key (roster city = "varenhal") and, without a plan, its name
	cityKey = "varenhal",
	defaultName = "Varenhal",
	planet = "naboo",

	-- Seconds between the mayor's chores (founding, buildings, taxes, treasury, election), and with devFast on
	choreSeconds = 60,
	fastChoreSeconds = 10,
	-- Seconds between each city bot's own checks (its house, its residence, its building, moving in, its vote)
	checkSeconds = 30,
	fastCheckSeconds = 5,

	-- Placing: walk to within this many metres of the spot first (Core3 allows 100 m, the client scrolls that far);
	-- the bot stops this far short of the spot, and never inside the building's footprint (clearance, metres from the
	-- centre by kind: the city hall's front terrace reaches 46 m)
	reach = 80,
	approachShort = 12,
	clearance = {
		house = 14, cityhall = 56, cantina = 26, hospital = 20, theater = 22, shuttleport = 26, cloning = 20, garage = 20,
		bank = 12, garden_sml = 12, garden_med = 16, garden_lrg = 20,
	},
	-- The square in front of the city hall (ply_nboo_capitol_s01: the doors face the building's +y, its terrace ends at
	-- 46 m): where the mayor stands, metres in front of the hall's centre, and where the city's dancer, musician and
	-- doctor wait for their buildings (metres to the side of the mayor). A plan's mayorSpot / waitSpots replace these.
	frontMetres = 52,
	waitSide = {dancer = -9, musician = -6, doctor = 8},
	-- After /placestructure, check after this long (ms): a house goes up after its construction marker (lots x 3 s)
	checkHouseMs = 25000,
	checkCivicMs = 6000,
	checkTries = 3,
	-- With botPlaceStructure, its watcher reports within two minutes; this is the check if it never does
	watchBackstopMs = 150000,
	-- After a failed placement, try again after this long (seconds; fast: fastRetry)
	retrySeconds = 900,
	fastRetrySeconds = 60,
	-- A city hold (placing, walking in) that lasts longer than this is dropped (seconds)
	holdTimeout = 600,
	-- A structure within this many metres of a planned spot is the planned building
	matchMetres = 10,

	-- Credits. The bots' income is simulated (spec: the one place we create credits): each city bot's bank is kept at
	-- least at bankFloor (house upkeep and property tax are taken from it weekly), and the mayor deposits to keep the
	-- treasury above treasuryWeeks of upkeep, topping it up to treasuryTopUpWeeks (for the weeks nobody visits Naboo)
	bankFloor = 50000,
	bankSeed = 150000,
	treasuryWeeks = 3,
	treasuryTopUpWeeks = 5,
	-- When a human is mayor, the old bot mayor still keeps the treasury paid (a patron of the city)
	fundWhenHumanMayor = true,

	-- Walking: seconds allowed per metre outdoors, plus a margin; indoors, a flat time
	walkSecondsPerMetre = 1.0,
	walkMargin = 45,
	walkIndoors = 150,

	-- Weekly upkeep the city pays (Core3 templates and city_manager.lua): civic structures by kind, the city hall's
	-- base plus per rank above 1, decorations, the registration and the specializations
	upkeep = {
		cityhall = 35000, cityhallPerRank = 25000, garden_sml = 10000, garden_med = 20000, garden_lrg = 30000, bank = 1500,
		garage = 20000, cloning = 20000, shuttleport = 25000, decoration = 1500, registration = 5000,
	},
	specCost = {
		sample_rich = 70000, industry = 50000, doctor = 80000, cloning = 80000, research = 125000, missions = 80000,
		entertainer = 80000, stronghold = 150000,
	},
	specNames = {
		["entertainment district"] = "entertainer", entertainment = "entertainer", entertainer = "entertainer",
		["manufacturing center"] = "industry", manufacturing = "industry", industry = "industry",
		["medical center"] = "doctor", medical = "doctor", doctor = "doctor", ["clone lab"] = "cloning", cloning = "cloning",
		["research center"] = "research", research = "research", ["improved job market"] = "missions", missions = "missions",
		["sample rich"] = "sample_rich", sample_rich = "sample_rich", stronghold = "stronghold",
	},
	specLabels = {
		entertainer = "Entertainment District", industry = "Manufacturing Center", doctor = "Medical Center",
		cloning = "Clone Lab", research = "Research Center", missions = "Improved Job Market", sample_rich = "Sample Rich",
		stronghold = "Stronghold",
	},
	rankNames = {"Outpost", "Village", "Township", "City", "Metropolis"},

	-- Civic buildings: the rank that unlocks each, and who places it (master entertainers place the cantina and the
	-- theater, the master doctor the hospital, the politician the rest)
	kindRank = {
		garden_sml = 1, bank = 2, garage = 2, cantina = 2, garden_med = 2, cloning = 3, hospital = 3, garden_lrg = 3,
		shuttleport = 4, theater = 4,
	},
	kindBy = {cantina = "dancer", hospital = "doctor", theater = "musician"},
	kindLabels = {
		garden_sml = "small garden", garden_med = "medium garden", garden_lrg = "large garden", bank = "bank",
		garage = "garage", cantina = "cantina", cloning = "cloning centre", hospital = "hospital", shuttleport = "shuttleport",
		theater = "theater", cityhall = "city hall",
	},
	specRank = 3,
	registerRank = 3,
	decorationRank = 5,

	-- Inside the player-built Naboo cantina and hospital (client portal layouts ply_nboo_cantina_s01.pob and
	-- ply_nboo_hospital_s01.pob, checked on their floor meshes with swgemu tools/snapshot.py): the cell, where each job
	-- stands (cell-local, z the floor), and in the cantina where visitors stand. The dancer is on the sunken dance floor
	-- facing the door, the musician on the stage behind it, the doctor in the middle of the main room. A plan's own
	-- `interiors` table replaces these.
	interiors = {
		cantina = {
			cell = "cantina",
			stations = {
				dancer = {x = 0, z = -0.25, y = -6},
				musician = {x = 0, z = 0.504, y = -12.2},
			},
			spots = {
				{x = -7, z = 0.75, y = 1}, {x = 7, z = 0.75, y = 1}, {x = -4, z = 0.75, y = 2}, {x = 4, z = 0.75, y = 2},
				{x = -10, z = 0.78, y = -2}, {x = 10, z = 0.78, y = -2}, {x = -3, z = -0.25, y = -8}, {x = 3, z = -0.25, y = -8},
				{x = -1.5, z = -0.25, y = -9}, {x = 1.5, z = -0.25, y = -9},
			},
		},
		hospital = {
			cell = "mainroom",
			stations = {doctor = {x = 0, z = 0.188, y = -3}},
			spots = {{x = 3, z = 0.188, y = -4}, {x = -3, z = 0.188, y = -6}},
		},
	},
	-- Which building each city job works in
	workplaces = {dancer = "cantina", musician = "cantina", doctor = "hospital"},
	-- Inside each Naboo house (by building template): a room and a point on its floor, for "home"
	homes = {
		{match = "naboo_small_style_01", cell = "room1", x = -4.3, z = 0.7, y = 0.5},
		{match = "naboo_small_style_02", cell = "room2", x = -4.1, z = 0.7, y = 0.9},
		{match = "naboo_medium_style_01", cell = "mainchamber", x = -2.0, z = 1.1, y = 0.8},
		{match = "naboo_large_style_01", cell = "mainfoyer", x = 0, z = 1.1, y = -1.9},
	},
}

-- Helpers

local function bk(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function ck(field)
	return "botcity:" .. field
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

local function firstOf(name)
	return tostring(name or ""):match("^(%S+)") or ""
end

local function num(v, default)
	return tonumber(v) or default
end

local function oidString(oid)
	return string.format("%.0f", tonumber(oid) or 0)
end

local function credits(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()

	return (out:gsub("^,", ""):gsub("^%-,", "-"))
end

local function flat(x1, y1, x2, y2)
	return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

-- A building-frame offset turned by a structure angle (0-3, quarter turns clockwise from north, as /placestructure)
local function rotate(dx, dy, angle)
	local a = math.rad((angle or 0) * 90)

	return dx * math.cos(a) + dy * math.sin(a), -dx * math.sin(a) + dy * math.cos(a)
end

function BotCityJobs:fast()
	return readData(ck("fast")) == 1
end

function BotCityJobs:choreEvery()
	return self:fast() and self.fastChoreSeconds or self.choreSeconds
end

function BotCityJobs:checkEvery()
	return self:fast() and self.fastCheckSeconds or self.checkSeconds
end

function BotCityJobs:retryEvery()
	return self:fast() and self.fastRetrySeconds or self.retrySeconds
end

function BotCityJobs:log(text)
	print("BotCity: " .. text)
end

-- The plan

local planCache = nil

-- What kind of civic building a deed makes ("bank", "garden_med", ...), or nil
local function kindOfDeed(deed)
	deed = tostring(deed or "")

	local size = deed:match("garden_%a+_(%a%a%a)_%d+")

	if size ~= nil then
		return "garden_" .. size
	end

	return deed:match("city_deed/(%a+)_%a+_deed")
end

local function angleOf(a)
	a = tonumber(a) or 0

	if a > 3 or a < 0 then
		a = math.floor(a / 90 + 0.5) % 4
	end

	return math.floor(a)
end

local function pointOf(t)
	if type(t) ~= "table" then
		return nil
	end

	local x, y = tonumber(t.x or t[1]), tonumber(t.y or t[2])

	if x == nil or y == nil then
		return nil
	end

	return x, y
end

-- city.lua, read into one shape (see the header of city.lua for its own). Cached per Lua state: it is data.
function BotCityJobs:plan()
	if planCache ~= nil then
		return planCache
	end

	local src = BotCityPlan or BotCityData or {}
	local plan = {problems = {}, houses = {}, spareLots = {}, civic = {}, decorations = {}, taxes = {}, items = {}}

	local function problem(text)
		table.insert(plan.problems, text)
	end

	local settings = BotRoster ~= nil and BotRoster.settings or {}

	plan.name = src.name or settings.cityName or self.defaultName
	plan.key = src.key or self.cityKey
	plan.planet = src.planet or self.planet

	local hall = src.cityHall or src.cityhall or src.hall or src.site
	local hx, hy = pointOf(hall)

	if hx == nil then
		problem("no city hall spot")
		hx, hy = 0, 0
	end

	plan.hall = {x = hx, y = hy, angle = angleOf(hall ~= nil and (hall.angle or hall.rotation or hall.heading) or 0)}
	plan.center = {x = hx, y = hy}
	local site = src.site

	if type(site) == "table" and pointOf(site) ~= nil then
		local sx, sy = pointOf(site)
		plan.center = {x = sx, y = sy}
	end

	-- Houses: one lot per bot, by first name
	for i, lot in ipairs(src.houses or src.lots or src.houseLots or {}) do
		local x, y = pointOf(lot)
		local owner = firstOf(lot.owner or lot.bot or lot.first or lot.name or ""):lower()
		local deed = lot.deed or lot.template

		if x == nil or deed == nil then
			problem("house lot " .. i .. " lacks a spot or a deed")
		elseif owner == "" then
			-- A spare lot (for a human): nobody's to place
			table.insert(plan.spareLots, {x = x, y = y})
		else
			local item = {id = "house." .. owner, house = true, kind = "house", owner = owner, deed = deed, x = x, y = y,
				angle = angleOf(lot.angle or lot.rotation or lot.heading), rank = 1}
			table.insert(plan.houses, item)
			plan.items[item.id] = item
		end
	end

	-- Civic buildings, as a list with ranks or by rank
	local civicSrc = src.civic or src.buildings or src.civicSpots or src.ranks or {}
	local civicList = {}

	for k, v in pairs(civicSrc) do
		if type(k) == "number" and type(v) == "table" and v.deed == nil and v.template == nil and v[1] ~= nil then
			for _, b in ipairs(v) do
				b.rank = b.rank or k
				table.insert(civicList, b)
			end
		elseif type(v) == "table" and (v.deed ~= nil or v.template ~= nil) then
			if type(k) == "string" then
				v.kind = v.kind or k
			end
			table.insert(civicList, v)
		end
	end

	table.sort(civicList, function(a, b)
		local ra, rb = tonumber(a.rank) or 0, tonumber(b.rank) or 0

		if ra ~= rb then
			return ra < rb
		end

		return tostring(a.kind or a.deed) < tostring(b.kind or b.deed)
	end)

	local seen = {}

	for i, b in ipairs(civicList) do
		local x, y = pointOf(b)
		local deed = b.deed or b.template
		local kind = b.kind or kindOfDeed(deed)

		if kind == "garden" then
			kind = kindOfDeed(deed) or "garden_sml"
		end

		if x == nil or deed == nil or kind == nil then
			problem("civic building " .. i .. " (" .. tostring(kind or deed) .. ") lacks a spot or a deed")
		else
			local id = "civic." .. kind

			if seen[id] then
				seen[id] = seen[id] + 1
				id = id .. seen[id]
			else
				seen[id] = 1
			end

			local by = tostring(b.by or b.placer or self.kindBy[kind] or "mayor"):lower()
			local item = {id = id, kind = kind, deed = deed, x = x, y = y, angle = angleOf(b.angle or b.rotation or b.heading),
				rank = tonumber(b.rank) or self.kindRank[kind] or 1, by = by}
			table.insert(plan.civic, item)
			plan.items[id] = item
		end
	end

	for i, d in ipairs(src.decorations or src.decorationSpots or {}) do
		local x, y = pointOf(d)
		local template = d.template or d.deed or d.object

		if x == nil or template == nil then
			problem("decoration " .. i .. " lacks a spot or a template")
		else
			local item = {id = "deco." .. i, index = i, template = template, x = x, y = y, heading = tonumber(d.heading),
				rank = tonumber(d.rank) or self.decorationRank}
			table.insert(plan.decorations, item)
			plan.items[item.id] = item
		end
	end

	-- Taxes: {income, property, sales, travel, garage} by name, as a list of values (index 0 first), or {index, value}
	local taxNames = {income = 0, property = 1, sales = 2, travel = 3, garage = 4}
	local taxes = src.taxes or {}

	for k, v in pairs(taxes) do
		if type(k) == "string" and taxNames[k] ~= nil and tonumber(v) ~= nil then
			table.insert(plan.taxes, {index = taxNames[k], value = tonumber(v)})
		elseif type(k) == "number" and tonumber(v) ~= nil then
			table.insert(plan.taxes, {index = k - 1, value = tonumber(v)})
		elseif type(v) == "table" then
			local index = tonumber(v.index) or taxNames[tostring(v.name or v.tax or "")]

			if index ~= nil and tonumber(v.value) ~= nil then
				table.insert(plan.taxes, {index = index, value = tonumber(v.value)})
			end
		end
	end

	table.sort(plan.taxes, function(a, b) return a.index < b.index end)

	-- The specialization: Core3's "@city/city:city_spec_<x>", from that, the bare key, or its English name
	local spec = src.specialization or src.spec

	if type(spec) == "table" then
		spec = spec.name or spec.id or spec[1]
	end

	if spec ~= nil then
		local s = tostring(spec)
		local bare = s:match("city_spec_([%w_]+)") or self.specNames[s:lower()] or s:lower()
		plan.specKey = bare
		plan.spec = "@city/city:city_spec_" .. bare
	end

	-- Where the mayor stands and the workers wait: on the square in front of the city hall (unless the plan says), clear
	-- of the decorations, the planned buildings and each other
	local fx, fy = rotate(0, 1, plan.hall.angle)
	local sx, sy = rotate(1, 0, plan.hall.angle)
	local taken = {}

	local function clearAt(x, y)
		for _, d in ipairs(plan.decorations) do
			if flat(x, y, d.x, d.y) < 10 then
				return false
			end
		end

		for _, item in pairs(plan.items) do
			if item.deed ~= nil and flat(x, y, item.x, item.y) < (self.clearance[item.kind] or 20) then
				return false
			end
		end

		for _, t in ipairs(taken) do
			if flat(x, y, t.x, t.y) < 3 then
				return false
			end
		end

		return true
	end

	local function squareSpot(depth, side)
		for k = 0, 12 do
			for _, sign in ipairs(k == 0 and {1} or {1, -1}) do
				local s = side + sign * k * 3
				local x, y = plan.hall.x + fx * depth + sx * s, plan.hall.y + fy * depth + sy * s

				if clearAt(x, y) then
					table.insert(taken, {x = x, y = y})
					return {x = x, y = y}
				end
			end
		end

		problem("no clear spot on the square at " .. depth .. " m, side " .. side)

		return {x = plan.hall.x + fx * depth + sx * side, y = plan.hall.y + fy * depth + sy * side}
	end

	local mx, my = pointOf(src.mayorSpot)

	plan.mayorSpot = mx ~= nil and {x = mx, y = my} or squareSpot(self.frontMetres, 0)
	table.insert(taken, plan.mayorSpot)
	plan.waitSpots = {}

	for _, job in ipairs({"dancer", "musician", "doctor"}) do
		local wx, wy = pointOf(type(src.waitSpots) == "table" and src.waitSpots[job] or nil)

		plan.waitSpots[job] = wx ~= nil and {x = wx, y = wy} or squareSpot(self.frontMetres + 1, self.waitSide[job])
	end

	-- Where citizens stand about on the square
	plan.squareSpots = {}

	for i = 1, 6 do
		table.insert(plan.squareSpots, squareSpot(self.frontMetres - 1 + (i % 2) * 3, (i % 2 == 0 and 1 or -1) * (8 + i * 3)))
	end

	plan.zoningOff = src.zoning ~= true
	plan.streets = {}

	for _, p in ipairs(src.streets or {}) do
		local x, y = pointOf(p)

		if x ~= nil then
			table.insert(plan.streets, {x = x, y = y})
		end
	end

	plan.specRank = tonumber(src.specRank or src.specializationRank) or self.specRank
	plan.registerRank = tonumber(src.registerRank) or self.registerRank
	plan.interiors = src.interiors or self.interiors

	if #plan.houses == 0 then
		problem("no house lots")
	end

	planCache = plan

	return plan
end

-- Read city.lua again on the next use (the simulator swaps plans; a reloadscreenplays reloads this file anyway)
function BotCityJobs:resetPlan()
	planCache = nil
end

function BotCityJobs:name()
	return self:plan().name
end

-- Info about the city, read from the C++ (botCityInfo) into one shape; nil when there is no city yet
function BotCityJobs:info()
	if botCityInfo == nil then
		return nil
	end

	local raw = botCityInfo(self:name())

	if type(raw) ~= "table" or next(raw) == nil or raw.exists == false or tonumber(raw.id or raw.cityId or 1) == 0 or
		tonumber(raw.rank or 1) == 0 then
		return nil
	end

	local info = {raw = raw}

	info.rank = num(raw.rank, 1)
	info.radius = num(raw.radius, 0)
	info.treasury = num(raw.treasury, 0)
	info.upkeep = num(raw.upkeep, 0)
	info.nextUpdate = num(raw.nextUpdate or raw.nextUpdateIn or raw.update, 0)
	info.nextUpdateText = raw.nextUpdateText
	info.zoning = raw.zoning == true or raw.zoningEnabled == true
	info.registered = raw.registered == true or raw.isRegistered == true
	info.spec = tostring(raw.specialization or raw.spec or "")

	local mayor = raw.mayor or raw.mayorID or raw.mayorId or raw.mayorOid

	if type(mayor) == "table" then
		info.mayorName = mayor.name
		mayor = mayor.oid or mayor.id
	end

	info.mayor = num(mayor, 0)
	info.mayorName = info.mayorName or raw.mayorName

	local citizens = type(raw.citizenList) == "table" and raw.citizenList or raw.citizens

	if type(citizens) == "table" then
		info.citizenOids = {}

		for _, c in ipairs(citizens) do
			local oid = type(c) == "table" and num(c.oid or c.id, 0) or num(c, 0)
			info.citizenOids[oid] = true
		end

		info.citizens = num(raw.citizenCount, #citizens)
	else
		info.citizens = num(citizens or raw.citizenCount, 0)
	end

	-- The city's buildings; decorations come in the same list (kind "decoration") or a list of their own
	info.structures = {}

	local decorationList = {}

	for _, s in ipairs(raw.structures or {}) do
		if type(s) == "table" then
			local entry = {oid = num(s.oid or s.id, 0), template = tostring(s.template or ""), x = num(s.x, 0), y = num(s.y, 0),
				kind = tostring(s.kind or "")}

			table.insert(entry.kind == "decoration" and decorationList or info.structures, entry)
		end
	end

	local decorations = raw.decorations

	if type(decorations) ~= "table" and #decorationList > 0 then
		decorations = decorationList
	end

	if type(decorations) == "table" then
		info.decorationList = {}

		for _, d in ipairs(decorations) do
			if type(d) == "table" then
				table.insert(info.decorationList, {oid = num(d.oid or d.id, 0), template = tostring(d.template or ""),
					x = num(d.x, 0), y = num(d.y, 0)})
			end
		end

		info.decorations = #info.decorationList
	else
		info.decorations = num(decorations or raw.decorationCount, 0)
	end

	-- The election: candidates {oid, name, votes}, whether the ballot is locked, and when it is decided
	local election = type(raw.election) == "table" and raw.election or {}
	local candidates = election.candidates or raw.candidates or {}

	info.candidates = {}

	for k, c in pairs(candidates) do
		if type(c) == "table" then
			table.insert(info.candidates, {oid = num(c.oid or c.id, 0), name = c.name, votes = num(c.votes, 0)})
		elseif type(k) == "number" and tonumber(c) ~= nil and k > 1000 then
			-- a map of candidate oid -> votes
			table.insert(info.candidates, {oid = k, votes = tonumber(c)})
		elseif tonumber(c) ~= nil then
			table.insert(info.candidates, {oid = tonumber(c), votes = 0})
		end
	end

	info.votingLocked = election.locked == true or raw.votingLocked == true
	info.electionIn = num(election.seconds or election.nextElection or raw.electionIn, nil)

	return info
end

-- Bots and humans

-- Roster bots, by object id, and the city's roster entries
function BotCityJobs:botOids()
	local out = {}

	for _, bot in ipairs(botList ~= nil and botList() or {}) do
		local oid = tonumber(bot.oid) or 0

		if oid ~= 0 then
			out[oid] = bot
		end
	end

	return out
end

function BotCityJobs:isBotOid(oid)
	return self:botOids()[tonumber(oid) or 0] ~= nil
end

function BotCityJobs:cityEntries()
	local out = {}

	for _, entry in ipairs(BotRoster ~= nil and BotRoster.bots or {}) do
		if entry.city == self:plan().key then
			table.insert(out, entry)
		end
	end

	return out
end

-- A citizen's trade, for the brain: the roster's role, else from its first master skill ("weaponsmith", "scout", ...)
function BotCityJobs:roleOf(entry)
	if entry == nil then
		return ""
	end

	if entry.role ~= nil then
		return entry.role
	end

	local names = {creaturehandler = "creature handler", bountyhunter = "bounty hunter", combatmedic = "combat medic",
		architect = "architect", droidengineer = "droid engineer"}

	for _, skill in ipairs(entry.skills or {}) do
		local trade = tostring(skill):match("^%a+_(%a+)_master$")

		if trade ~= nil and trade ~= "artisan" then
			return names[trade] or trade
		end
	end

	return ""
end

-- The roster entry of the city bot with this job ("dancer", ...), or nil
function BotCityJobs:entryWithJob(job)
	for _, entry in ipairs(self:cityEntries()) do
		if entry.job == job then
			return entry
		end
	end

	return nil
end

function BotCityJobs:isCityBot(oid)
	return BotJobs:city(oid) == self:plan().key
end

function BotCityJobs:firstName(oid)
	return readStringData(bk(oid, "first")):lower()
end

-- Is a human within range of the bot?
function BotCityJobs:humanNear(pBot, range)
	for _, pPlayer in ipairs(SceneObject(pBot):getPlayersInRange(range) or {}) do
		if pPlayer ~= pBot and not (isBot ~= nil and isBot(pPlayer)) then
			return pPlayer
		end
	end

	return nil
end

-- Did the bot just log in? The C++ puts it at its roster station at every login; a BotJobs:restart (after a
-- reloadscreenplays) starts the job again wherever it is, and then it isn't moved
function BotCityJobs:freshLogin(pBot, oid)
	local entry = BotJobs:entry(readStringData(bk(oid, "first")))
	local s = entry ~= nil and entry.station or nil

	if s == nil then
		return true
	end

	if SceneObject(pBot):getParentID() ~= (s.cell or 0) then
		return false
	end

	local x, y = SceneObject(pBot):getPositionX(), SceneObject(pBot):getPositionY()

	return flat(x, y, s.x, s.y) <= 3
end

-- Where a bot is in the world (a bot in a building has cell-local coordinates)
function BotCityJobs:worldXY(pBot)
	local obj = SceneObject(pBot)

	if obj.getWorldPositionX ~= nil then
		return obj:getWorldPositionX(), obj:getWorldPositionY()
	end

	return obj:getPositionX(), obj:getPositionY()
end

-- Credits

-- Keep the bot's bank at the floor (its house and building upkeep), with the simulated income. In an event on the bot.
function BotCityJobs:topUpBank(pBot, oid)
	local bank = CreatureObject(pBot):getBankCredits()

	if bank >= self.bankFloor then
		return 0
	end

	local add = self.bankSeed - bank

	CreatureObject(pBot):addBankCredits(add, false)
	-- So BotJobs:checkTips doesn't take it for a tip
	writeData(bk(oid, "cash"), BotJobs:cash(pBot))

	return add
end

-- The mayor's gift to a city bot (an event on that bot): its house deed and seed credits
function BotCityJobs:grant(pBot, args)
	if pBot == nil then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if not self:isCityBot(oid) or not BotJobs:online(oid) then
		return
	end

	local given = {}
	local added = self:topUpBank(pBot, oid)

	if added > 0 then
		table.insert(given, credits(added) .. " credits")
	end

	local lot = self:houseLot(oid)

	if lot ~= nil and self:ownedAt(pBot, lot) == nil and self:deedIn(pBot, lot.deed) == nil then
		local pDeed = self:takeDeed(pBot, lot.deed)

		if pDeed ~= nil then
			table.insert(given, "a house deed")
		end
	end

	if #given > 0 then
		self:log("the mayor gives " .. BotJobs:name(oid) .. " " .. table.concat(given, " and "))
	end
end

-- Buildings

-- The bot's house lot in the plan, or nil
function BotCityJobs:houseLot(oid)
	return self:plan().items["house." .. self:firstName(oid)]
end

-- The structure the bot owns at a planned spot ({oid, template, x, y, city}), or nil
function BotCityJobs:ownedAt(pBot, item)
	if botOwnedStructures == nil then
		return nil
	end

	for _, s in ipairs(botOwnedStructures(pBot) or {}) do
		if flat(num(s.x, 1e9), num(s.y, 1e9), item.x, item.y) <= self.matchMetres then
			return s
		end
	end

	return nil
end

-- A structure in the city at a planned spot, or nil
function BotCityJobs:cityStructureAt(info, item)
	for _, s in ipairs(info ~= nil and info.structures or {}) do
		if flat(s.x, s.y, item.x, item.y) <= self.matchMetres then
			return s
		end
	end

	return nil
end

-- Is the planned item built? Its oid from the cache, the city's list, or (placer) the bot's own structures
function BotCityJobs:builtOid(item, info, pPlacer)
	local cached = readData(ck("built:" .. item.id))

	if cached ~= 0 and getSceneObject(cached) ~= nil then
		return cached
	end

	local s = self:cityStructureAt(info, item)

	if s == nil and pPlacer ~= nil then
		s = self:ownedAt(pPlacer, item)
	end

	if s ~= nil and num(s.oid, 0) ~= 0 then
		writeData(ck("built:" .. item.id), num(s.oid, 0))
		return num(s.oid, 0)
	end

	if cached ~= 0 then
		deleteData(ck("built:" .. item.id))
	end

	return nil
end

-- The civic item of a kind ("cantina", ...), or nil
function BotCityJobs:civicOfKind(kind)
	for _, item in ipairs(self:plan().civic) do
		if item.kind == kind then
			return item
		end
	end

	return nil
end

-- The building of a kind if it stands: its oid and the oid of its main cell (nil when it isn't built or has no such
-- cell). info: botCityInfo's, if the caller has it; pPlacer: the bot that places it, if that's the caller. Cached in
-- shared memory by whoever finds it first.
function BotCityJobs:workplace(kind, info, pPlacer)
	local item = self:civicOfKind(kind)
	local interior = self:plan().interiors[kind]

	if item == nil or interior == nil then
		return nil
	end

	local oid = self:builtOid(item, info, pPlacer)

	if oid == nil then
		return nil
	end

	local cellOid = readData(ck("cell:" .. kind))

	if cellOid == 0 or readData(ck("cellOf:" .. kind)) ~= oid then
		local pBuilding = getSceneObject(oid)
		local pCell = pBuilding ~= nil and BuildingObject(pBuilding):getNamedCell(interior.cell) or nil

		if pCell == nil then
			return oid, nil
		end

		cellOid = SceneObject(pCell):getObjectID()
		writeData(ck("cell:" .. kind), cellOid)
		writeData(ck("cellOf:" .. kind), oid)
	end

	return oid, cellOid
end

-- A deed of this template in the bot's inventory (a failed try leaves it there), or nil
function BotCityJobs:deedIn(pBot, template)
	local pInventory = CreatureObject(pBot):getSlottedObject("inventory")

	if pInventory == nil then
		return nil
	end

	return getContainerObjectByTemplate(pInventory, template, true)
end

-- The deed from the inventory, or a new one there
function BotCityJobs:takeDeed(pBot, template)
	local pDeed = self:deedIn(pBot, template)

	if pDeed ~= nil then
		return pDeed
	end

	local pInventory = CreatureObject(pBot):getSlottedObject("inventory")

	if pInventory == nil then
		return nil
	end

	return giveItem(pInventory, template, -1)
end

-- Holding a job (the wrapped dancer, musician and doctor: their own job pauses while they place or walk in)

function BotCityJobs:hold(oid, why)
	writeData(bk(oid, "cityHold"), os.time())
	writeStringData(bk(oid, "cityHoldWhy"), why)
end

function BotCityJobs:release(oid)
	deleteData(bk(oid, "cityHold"))
	deleteStringData(bk(oid, "cityHoldWhy"))
end

function BotCityJobs:held(oid)
	return readData(bk(oid, "cityHold")) ~= 0
end

-- Stop dancing or playing (a performer can't place a structure or walk while performing); true if it was
function BotCityJobs:stopPerforming(pBot)
	local creature = CreatureObject(pBot)
	local was = false

	if creature.isDancing ~= nil and creature:isDancing() then
		botEnqueue(pBot, "stopdance", 0, "")
		was = true
	end

	if creature.isPlayingMusic ~= nil and creature:isPlayingMusic() then
		botEnqueue(pBot, "stopmusic", 0, "")
		was = true
	end

	return was
end

-- Walking

-- Walk the bot to a point (cell 0 outdoors, else cell-local) for a purpose: what to do on arrival (see moved). With no
-- mover, or when it refuses, the bot is put there.
function BotCityJobs:go(pBot, oid, x, z, y, cell, purpose, pace)
	local seq = readData(bk(oid, "cityMoveSeq")) + 1
	local wx, wy = self:worldXY(pBot)
	local timeout = self.walkIndoors

	if (cell or 0) == 0 and SceneObject(pBot):getParentID() == 0 then
		timeout = math.floor(flat(wx, wy, x, y) * self.walkSecondsPerMetre) + self.walkMargin
	end

	writeData(bk(oid, "cityMoveSeq"), seq)
	writeStringData(bk(oid, "cityMove"), table.concat({purpose, x, z, y, cell or 0}, "|"))
	writeData(bk(oid, "cityMoveUntil"), os.time() + timeout)

	local moving = false

	if botMoveTo ~= nil then
		if pace ~= nil then
			moving = botMoveTo(pBot, x, z, y, cell or 0, pace)
		else
			moving = botMoveTo(pBot, x, z, y, cell or 0)
		end
	end

	if not moving then
		createEvent(200, "BotCityJobs", "moveFallback", pBot, packArgs(readData(bk(oid, "gen")), seq))
	end
end

function BotCityJobs:moving(oid)
	return readStringData(bk(oid, "cityMove")) ~= ""
end

-- The walk is over: "arrived", "stuck", "timeout" or "put" (no mover). Anything but arrived puts the bot there.
function BotCityJobs:moveEnded(pBot, oid, how)
	local move = readStringData(bk(oid, "cityMove"))

	if move == "" then
		return false
	end

	deleteStringData(bk(oid, "cityMove"))
	deleteData(bk(oid, "cityMoveUntil"))

	local purpose, x, z, y, cell = move:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")

	if how ~= "arrived" and x ~= nil then
		if botStop ~= nil and how ~= "put" then
			botStop(pBot)
		end

		SceneObject(pBot):teleport(tonumber(x), tonumber(z), tonumber(y), tonumber(cell))

		if how ~= "put" then
			self:log(BotJobs:name(oid) .. " couldn't walk to " .. purpose .. " (" .. how .. "), put there")
		end
	end

	self:moved(pBot, oid, purpose or "", how)

	return true
end

function BotCityJobs:moveFallback(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if readData(bk(oid, "cityMoveSeq")) == tonumber(a[2]) then
		self:moveEnded(pBot, oid, "put")
	end
end

-- From a city bot's tick: a walk that has run out of time
function BotCityJobs:checkMove(pBot, oid, now)
	if self:moving(oid) and now > readData(bk(oid, "cityMoveUntil")) then
		self:moveEnded(pBot, oid, "timeout")
	end
end

-- The C++ events the city's work waits for: the mover's ("arrived", "stuck") and botPlaceStructure's ("placed",
-- "placeFailed"). True if it was one of ours.
function BotCityJobs:onMoveEvent(pBot, oid, name, pOther, detail)
	if name == "placed" or name == "placeFailed" then
		return self:placeEvent(pBot, oid, name, pOther, detail)
	end

	if not self:moving(oid) then
		return false
	end

	if name == "arrived" then
		return self:moveEnded(pBot, oid, "arrived")
	elseif name == "stuck" then
		return self:moveEnded(pBot, oid, "stuck")
	end

	return false
end

-- Where a walk was going: placing ("place:<id>"), moving in ("in:<kind>"), or the job's own ("errand:...", ...)
function BotCityJobs:moved(pBot, oid, purpose, how)
	local id = purpose:match("^place:(.+)$")

	if id ~= nil then
		self:placeNow(pBot, oid, id)
		return
	end

	local kind = purpose:match("^in:(.+)$") or purpose:match("^post:(.+)$")

	if kind ~= nil then
		self:movedIn(pBot, oid, kind)
		return
	end

	local module = BotJobs:module(BotJobs:job(oid))

	if module ~= nil and module.cityArrived ~= nil then
		module:cityArrived(pBot, oid, purpose, how)
	end
end

-- Placing a building

-- Is a placement under way for this bot?
function BotCityJobs:placing(oid)
	return readStringData(bk(oid, "cityPlacing")) ~= ""
end

-- May this item be tried now (not failed lately)?
function BotCityJobs:mayTry(item)
	return os.time() >= readData(ck("retry:" .. item.id))
end

-- Start placing a planned item (an event on the placing bot). done: "residence" for a house (declare once built)
function BotCityJobs:startPlace(pBot, oid, item)
	if self:placing(oid) then
		return
	end

	writeStringData(bk(oid, "cityPlacing"), item.id)
	writeData(bk(oid, "cityPlacingSince"), os.time())
	-- Each try has its own number, so a check left over from an earlier try of the same building is ignored
	writeData(bk(oid, "cityPlaceSeq"), readData(bk(oid, "cityPlaceSeq")) + 1)
	self:hold(oid, "placing " .. (self.kindLabels[item.kind] or item.kind))

	local stopped = self:stopPerforming(pBot)

	self:log(BotJobs:name(oid) .. " goes to place " .. self:label(item) .. " at " .. math.floor(item.x) .. " " .. math.floor(item.y))
	createEvent(stopped and 2500 or 200, "BotCityJobs", "placeApproach", pBot, packArgs(readData(bk(oid, "gen")), item.id))
end

function BotCityJobs:label(item)
	if item.house then
		return "a house"
	end

	return "the " .. (self.kindLabels[item.kind] or item.kind)
end

-- Outdoors and within reach, or walk there first
function BotCityJobs:placeApproach(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local item = self:plan().items[a[2]]

	if item == nil or readStringData(bk(oid, "cityPlacing")) ~= item.id then
		return
	end

	local x, y = self:worldXY(pBot)
	local dist = flat(x, y, item.x, item.y)
	local clear = self.clearance[item.kind] or 20

	if SceneObject(pBot):getParentID() ~= 0 or dist > self.reach or dist < clear then
		-- Stop short of the spot on the bot's side of it, clear of the footprint (from the spot itself: towards the
		-- city's centre)
		local short = math.max(self.approachShort, clear + 4)
		local ux, uy = x - item.x, y - item.y

		if dist < 1 then
			local c = self:plan().center
			ux, uy = c.x - item.x, c.y - item.y

			if flat(c.x, c.y, item.x, item.y) < 1 then
				ux, uy = 0, 1
			end
		end

		local len = math.sqrt(ux * ux + uy * uy)
		local tx, ty = item.x + ux / len * short, item.y + uy / len * short

		self:go(pBot, oid, tx, getWorldFloor(tx, ty, self:plan().planet), ty, 0, "place:" .. item.id)
		return
	end

	self:placeNow(pBot, oid, item.id)
end

-- The deed and /placestructure
function BotCityJobs:placeNow(pBot, oid, id)
	local item = self:plan().items[id]

	if item == nil or readStringData(bk(oid, "cityPlacing")) ~= id then
		return
	end

	if SceneObject(pBot):getParentID() ~= 0 then
		self:placeFailed(pBot, oid, item, "still indoors")
		return
	end

	local pDeed = self:takeDeed(pBot, item.deed)

	if pDeed == nil then
		self:placeFailed(pBot, oid, item, "no deed (" .. item.deed .. ")")
		return
	end

	local deedOid = SceneObject(pDeed):getObjectID()
	local gen = readData(bk(oid, "gen")) .. "." .. readData(bk(oid, "cityPlaceSeq"))

	if botPlaceStructure ~= nil then
		-- The C++ checks what Core3 would, logs the reason for a refusal, runs the real /placestructure and tells us
		-- "placed" or "placeFailed" (placeEvent); the check here is only a backstop
		if not botPlaceStructure(pBot, deedOid, item.x, item.y, item.angle) then
			self:placeFailed(pBot, oid, item, "refused (the BotCity log line above says why)")
			return
		end

		createEvent(self.watchBackstopMs, "BotCityJobs", "placeCheck", pBot, packArgs(gen, id, self.checkTries))
		return
	end

	local command = oidString(deedOid) .. " " .. string.format("%.1f %.1f %d", item.x, item.y, item.angle)

	if not botEnqueue(pBot, "placestructure", 0, command) then
		self:placeFailed(pBot, oid, item, "placestructure wasn't queued")
		return
	end

	createEvent(item.house and self.checkHouseMs or self.checkCivicMs, "BotCityJobs", "placeCheck", pBot, packArgs(gen, id, 1))
end

-- botPlaceStructure's watcher: "placed" (pOther the structure) or "placeFailed" (detail why)
function BotCityJobs:placeEvent(pBot, oid, name, pOther, detail)
	local item = self:plan().items[readStringData(bk(oid, "cityPlacing"))]

	if item == nil then
		return false
	end

	if name == "placeFailed" then
		self:placeFailed(pBot, oid, item, tostring(detail))
		return true
	end

	local s = self:ownedAt(pBot, item)

	if s == nil and pOther ~= nil then
		s = {oid = SceneObject(pOther):getObjectID()}
	end

	if s ~= nil then
		writeData(ck("built:" .. item.id), num(s.oid, 0))
		deleteData(ck("retry:" .. item.id))
		self:log(BotJobs:name(oid) .. " placed " .. self:label(item) .. " (" .. oidString(s.oid) .. ")")
		self:placeDone(pBot, oid, item, true)
	end

	return true
end

-- Did it go up? The reason for a refusal goes to the bot's (missing) client, so all we see is that it didn't.
function BotCityJobs:placeCheck(pBot, args)
	local a = unpackArgs(args)
	local gen, seq = tostring(a[1]):match("^(%d+)%.(%d+)$")

	if not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local item = self:plan().items[a[2]]
	local tries = tonumber(a[3]) or 1

	if item == nil or readStringData(bk(oid, "cityPlacing")) ~= item.id or readData(bk(oid, "cityPlaceSeq")) ~= tonumber(seq) then
		return
	end

	local s = self:ownedAt(pBot, item)

	if s == nil and not item.house then
		s = self:cityStructureAt(self:info(), item)
	end

	if s ~= nil then
		writeData(ck("built:" .. item.id), num(s.oid, 0))
		deleteData(ck("retry:" .. item.id))
		self:log(BotJobs:name(oid) .. " placed " .. self:label(item) .. " (" .. oidString(s.oid) .. ")")
		self:placeDone(pBot, oid, item, true)
		return
	end

	if tries < self.checkTries then
		createEvent(10000, "BotCityJobs", "placeCheck", pBot, packArgs(a[1], item.id, tries + 1))
		return
	end

	self:placeFailed(pBot, oid, item, "nothing there after /placestructure (see the bot's placement checks in the server log)")
end

function BotCityJobs:placeFailed(pBot, oid, item, why)
	writeData(ck("retry:" .. item.id), os.time() + self:retryEvery())
	writeData(ck("fails:" .. item.id), readData(ck("fails:" .. item.id)) + 1)
	self:log(BotJobs:name(oid) .. " couldn't place " .. self:label(item) .. ": " .. why .. "; trying again in " ..
		self:retryEvery() .. " s")
	self:placeDone(pBot, oid, item, false)
end

function BotCityJobs:placeDone(pBot, oid, item, ok)
	deleteStringData(bk(oid, "cityPlacing"))
	deleteData(bk(oid, "cityPlacingSince"))
	self:release(oid)

	if ok and item.house then
		self:declare(pBot, oid)
	end

	local module = BotJobs:module(BotJobs:job(oid))

	if module ~= nil and module.cityPlaced ~= nil then
		module:cityPlaced(pBot, oid, item, ok)
	end
end

-- Residence: declared once the house stands (the C++ does what /declareresidence does, without walking in)
function BotCityJobs:declare(pBot, oid)
	local lot = self:houseLot(oid)
	local house = lot ~= nil and self:ownedAt(pBot, lot) or nil

	-- The mayor lives in the city hall (Core3 declares it there at founding)
	if house == nil or botDeclareResidence == nil or BotJobs:job(oid) == "mayor" then
		return false
	end

	local info = self:info()

	if info ~= nil and info.citizenOids ~= nil and info.citizenOids[oid] then
		writeData(bk(oid, "cityResident"), 1)
		return true
	end

	local ok = botDeclareResidence(pBot, num(house.oid, 0))

	writeData(bk(oid, "cityResident"), ok and 1 or 0)
	writeData(bk(oid, "cityResidentTried"), os.time())
	self:log(BotJobs:name(oid) .. " declares residence in " .. oidString(house.oid) .. ": " .. tostring(ok))

	return ok
end

-- A city bot's own checks (from its job's tick): its house and residence. Returns true if it started something.
function BotCityJobs:houseChores(pBot, oid, now, info)
	local lot = self:houseLot(oid)

	if lot == nil or info == nil or info.zoning or self:placing(oid) then
		return false
	end

	if self:ownedAt(pBot, lot) == nil then
		if self:mayTry(lot) then
			self:startPlace(pBot, oid, lot)
			return true
		end

		return false
	end

	local house = self:ownedAt(pBot, lot)
	local resident = (info.citizenOids ~= nil and info.citizenOids[oid]) or (house ~= nil and house.residence == true) or
		readData(bk(oid, "cityResident")) == 1

	if not resident and BotJobs:job(oid) ~= "mayor" and now - readData(bk(oid, "cityResidentTried")) >= 3600 then
		self:declare(pBot, oid)
	end

	return false
end

-- Votes: for a human candidate (two humans: the bots split between them), else the incumbent if running, else the
-- bot mayor if it runs (for a seat a human mayor gave up by leaving). The candidate oid to vote for, or 0
function BotCityJobs:choice(info, oid)
	local humans = {}
	local mayorRunning, botRunning = false, 0

	for _, c in ipairs(info.candidates) do
		if c.oid ~= 0 and not self:isBotOid(c.oid) then
			table.insert(humans, c.oid)
		elseif c.oid ~= 0 then
			botRunning = c.oid
		end

		if c.oid == info.mayor then
			mayorRunning = true
		end
	end

	if #humans > 0 then
		table.sort(humans)

		return humans[(oid % #humans) + 1]
	end

	return mayorRunning and info.mayor or botRunning
end

-- Cast again now and then: Core3 clears the ballot at each election, and botCityInfo doesn't say who voted
BotCityJobs.revoteSeconds = 10800

function BotCityJobs:vote(pBot, oid, info)
	if info == nil or botCityVote == nil then
		return
	end

	local resident = info.citizenOids == nil or info.citizenOids[oid]

	if not resident then
		return
	end

	local want = self:choice(info, oid)
	local last = readData(bk(oid, "cityVote"))
	local again = os.time() - readData(bk(oid, "cityVoteAt")) >= (self:fast() and 20 or self.revoteSeconds)

	if want == 0 or (last == want and not again) then
		return
	end

	local ok = botCityVote(pBot, self:name(), want)

	writeData(bk(oid, "cityVoteAt"), os.time())

	if ok then
		writeData(bk(oid, "cityVote"), want)
	end

	if last ~= want or not ok then
		self:log(BotJobs:name(oid) .. " votes for " .. self:candidateName(info, want) .. ": " .. tostring(ok))
	end
end

function BotCityJobs:candidateName(info, candidateOid)
	for _, c in ipairs(info.candidates or {}) do
		if c.oid == candidateOid and c.name ~= nil then
			return c.name
		end
	end

	local pCandidate = getSceneObject(candidateOid)

	if pCandidate ~= nil then
		return CreatureObject(pCandidate):getFirstName()
	end

	return oidString(candidateOid)
end

-- The city's dancer, musician and doctor

-- Where this job stands in its building ({x, z, y}), or nil
function BotCityJobs:stationIn(kind, job)
	local interior = self:plan().interiors[kind]

	return interior ~= nil and interior.stations ~= nil and interior.stations[job] or nil
end

-- Its building, if it stands: kind, building oid, cell oid (the placer also finds it among its own structures)
function BotCityJobs:jobBuilding(pBot, oid, job, info)
	local kind = self.workplaces[job]

	if kind == nil then
		return nil
	end

	local item = self:civicOfKind(kind)
	local placer = item ~= nil and item.by == job and pBot or nil
	local building, cell = self:workplace(kind, info or self:info(), placer)

	return kind, building, cell
end

-- Logging in: inside its building if that stands (as a player logs in where they logged out); true if it was put there
function BotCityJobs:jobLogin(pBot, oid, job)
	self:release(oid)
	deleteStringData(bk(oid, "cityPlacing"))
	deleteStringData(bk(oid, "cityMove"))

	local info = self:info()
	local kind, building, cell = self:jobBuilding(pBot, oid, job, info)
	local station = kind ~= nil and self:stationIn(kind, job) or nil

	if not self:freshLogin(pBot, oid) then
		-- A job restart: it carries on where it is (the tick walks it in if need be)
		return false
	end

	if cell == nil or station == nil then
		-- No building yet: it waits on the square by the city hall, once there is one
		local wait = self:plan().waitSpots[job]

		if info ~= nil and wait ~= nil then
			SceneObject(pBot):teleport(wait.x, getWorldFloor(wait.x, wait.y, self:plan().planet), wait.y, 0)
		end

		return false
	end

	SceneObject(pBot):teleport(station.x, station.z, station.y, cell)
	self:log(BotJobs:name(oid) .. " logs in inside the " .. kind)

	return true
end

-- Walk to the square by the city hall to wait there (the job held until then)
function BotCityJobs:goWait(pBot, oid, job)
	local wait = self:plan().waitSpots[job]

	if wait == nil then
		return false
	end

	local x, y = self:worldXY(pBot)

	if SceneObject(pBot):getParentID() == 0 and flat(x, y, wait.x, wait.y) <= 6 then
		return false
	end

	self:hold(oid, "walking to the square")
	self:stopPerforming(pBot)
	self:go(pBot, oid, wait.x, getWorldFloor(wait.x, wait.y, self:plan().planet), wait.y, 0, "post:square")

	return true
end

-- Walk in (the job is held until there)
function BotCityJobs:moveIn(pBot, oid, kind, cell, job)
	local station = self:stationIn(kind, job)

	if station == nil then
		return
	end

	self:hold(oid, "walking into the " .. kind)
	self:stopPerforming(pBot)
	self:log(BotJobs:name(oid) .. " walks into the " .. kind)
	self:go(pBot, oid, station.x, station.z, station.y, cell, "in:" .. kind)
end

function BotCityJobs:movedIn(pBot, oid, kind)
	self:release(oid)

	local module = BotJobs:module(BotJobs:job(oid))

	if module ~= nil and module.inner ~= nil and module.inner.start ~= nil then
		-- The job starts afresh where it now stands (the dancer starts dancing, the doctor restocks)
		module.inner:start(pBot, oid)
	end
end

-- The wrapped job's tick for a city bot. Returns true while the job is held (its own tick is skipped).
function BotCityJobs:jobTick(pBot, oid, now, job)
	self:checkMove(pBot, oid, now)

	if self:held(oid) then
		if now - readData(bk(oid, "cityHold")) > self.holdTimeout then
			self:log(BotJobs:name(oid) .. ": " .. readStringData(bk(oid, "cityHoldWhy")) .. " took over " .. self.holdTimeout .. " s, dropped")
			deleteStringData(bk(oid, "cityPlacing"))
			deleteStringData(bk(oid, "cityMove"))
			self:release(oid)
		end

		return true
	end

	if now < readData(bk(oid, "cityNextCheck")) then
		return false
	end

	writeData(bk(oid, "cityNextCheck"), now + self:checkEvery())

	local info = self:info()

	if info == nil then
		return false
	end

	writeData(ck("knownRank"), info.rank)

	if self:houseChores(pBot, oid, now, info) then
		return true
	end

	-- Its own building (the dancer's cantina, the musician's theater, the doctor's hospital), once the rank allows
	for _, item in ipairs(self:plan().civic) do
		if item.by == job and item.rank <= info.rank and self:mayTry(item) and self:builtOid(item, info, pBot) == nil then
			self:startPlace(pBot, oid, item)
			return true
		end
	end

	self:vote(pBot, oid, info)

	-- Its workplace stands and it isn't inside: walk in; else wait on the square
	local kind, building, cell = self:jobBuilding(pBot, oid, job, info)

	if cell ~= nil then
		if SceneObject(pBot):getParentID() ~= cell then
			self:moveIn(pBot, oid, kind, cell, job)
			return true
		end

		return false
	end

	return self:goWait(pBot, oid, job)
end

-- Wrap a job module so the city's own bots of that job get the city's work first; other bots are untouched
function BotCityJobs:wrap(job)
	local inner = BotJobModules ~= nil and BotJobModules[job] or nil

	if inner == nil or inner.cityWrapped then
		return
	end

	local proxy = setmetatable({cityWrapped = true, inner = inner, job = job}, {__index = inner})

	proxy.start = function(self, pBot, oid)
		if BotCityJobs:isCityBot(oid) then
			BotCityJobs:jobLogin(pBot, oid, job)
		end

		if inner.start ~= nil then
			return inner:start(pBot, oid)
		end
	end

	proxy.tick = function(self, pBot, oid, now)
		if BotCityJobs:isCityBot(oid) and BotCityJobs:jobTick(pBot, oid, now, job) then
			return
		end

		if inner.tick ~= nil then
			return inner:tick(pBot, oid, now)
		end
	end

	proxy.clear = function(self, oid)
		if BotCityJobs:isCityBot(oid) then
			BotCityJobs:release(oid)
			deleteStringData(bk(oid, "cityPlacing"))
			deleteStringData(bk(oid, "cityMove"))
			deleteData(bk(oid, "cityNextCheck"))
		end

		if inner.clear ~= nil then
			return inner:clear(oid)
		end
	end

	proxy.onEvent = function(self, pBot, oid, name, pOther, detail)
		if BotCityJobs:isCityBot(oid) and BotCityJobs:onMoveEvent(pBot, oid, name, pOther, detail) then
			return
		end

		if inner.onEvent ~= nil then
			return inner:onEvent(pBot, oid, name, pOther, detail)
		end
	end

	-- For the brain (the request's extra fields, if BotJobs:ask asks the module): the city's news, and where the bot is
	proxy.requestFields = function(self, pBot, oid)
		local fields = inner.requestFields ~= nil and inner:requestFields(pBot, oid) or {}

		if BotCityJobs:isCityBot(oid) then
			fields.cityInfo = BotCityJobs:summary()
			fields.cityName = BotCityJobs:name()

			local kind = BotCityJobs.workplaces[job]
			local cell = kind ~= nil and readData(ck("cell:" .. kind)) or 0

			fields.place = (cell ~= 0 and pBot ~= nil and SceneObject(pBot):getParentID() == cell) and kind or "cityhall"
		end

		return fields
	end

	proxy.state = function(self, pBot, oid)
		local state = inner.state ~= nil and inner:state(pBot, oid) or ""

		if BotCityJobs:isCityBot(oid) then
			state = state .. "; " .. BotCityJobs:whereState(pBot, oid, job)
		end

		return state
	end

	BotJobModules[job] = proxy
end

function BotCityJobs:whereState(pBot, oid, job)
	if self:held(oid) then
		return readStringData(bk(oid, "cityHoldWhy"))
	end

	local kind = self.workplaces[job]
	local cell = kind ~= nil and readData(ck("cell:" .. kind)) or 0

	if cell ~= 0 and pBot ~= nil and SceneObject(pBot):getParentID() == cell then
		return "in the " .. kind
	end

	local wait = self:plan().waitSpots[job]

	if wait ~= nil and pBot ~= nil and SceneObject(pBot):getParentID() == 0 then
		local x, y = self:worldXY(pBot)

		if flat(x, y, wait.x, wait.y) <= 8 then
			return "waiting on the square for the " .. tostring(kind)
		end
	end

	return "outdoors"
end

-- What the city is like, for the brain (cityInfo) and the mayor's talk: cached by the mayor's chores
function BotCityJobs:summary()
	return readStringData(ck("summary"))
end

-- Weekly upkeep at a rank: the hall, the planned civic buildings up to that rank, the decorations, the registration
-- and the specialization once their rank is reached
function BotCityJobs:upkeepAt(rank, decorations)
	local plan = self:plan()
	local cost = self.upkeep.cityhall + self.upkeep.cityhallPerRank * math.max(0, rank - 1)

	for _, item in ipairs(plan.civic) do
		if item.rank <= rank then
			cost = cost + (self.upkeep[item.kind] or 0)
		end
	end

	cost = cost + self.upkeep.decoration * (decorations or 0)

	if rank >= plan.registerRank then
		cost = cost + self.upkeep.registration
	end

	if plan.specKey ~= nil and rank >= plan.specRank then
		cost = cost + (self.specCost[plan.specKey] or 80000)
	end

	return cost
end

-- Rank of the city in words
function BotCityJobs:rankName(rank)
	return self.rankNames[rank] or ("rank " .. tostring(rank))
end

-- What the next rank brings, in words ("bank, garage, cantina and medium garden"), or nil
function BotCityJobs:nextBuildings(rank)
	local names = {}

	for _, item in ipairs(self:plan().civic) do
		if item.rank == rank + 1 then
			table.insert(names, self.kindLabels[item.kind] or item.kind)
		end
	end

	if rank + 1 == self.decorationRank and #self:plan().decorations > 0 then
		table.insert(names, "statues and fountains")
	end

	if #names == 0 then
		return nil
	elseif #names == 1 then
		return names[1]
	end

	return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

function BotCityJobs:writeSummary(info)
	local plan = self:plan()
	local parts = {}
	local mayorName = info.mayorName

	if mayorName == nil then
		local pMayor = info.mayor ~= 0 and getSceneObject(info.mayor) or nil

		mayorName = pMayor ~= nil and CreatureObject(pMayor):getFirstName() or "unknown"
	end

	table.insert(parts, plan.name .. ", a player city on Naboo near Theed: rank " .. info.rank .. " (" .. self:rankName(info.rank) ..
		"), " .. info.citizens .. " citizens, mayor " .. mayorName .. (self:isBotOid(info.mayor) and "" or " (a player)"))

	if info.spec ~= "" then
		local key = info.spec:match("city_spec_([%w_]+)") or info.spec
		table.insert(parts, "specialization " .. (self.specLabels[key] or key))
	end

	local built = {"city hall"}

	for _, item in ipairs(plan.civic) do
		if readData(ck("built:" .. item.id)) ~= 0 or self:cityStructureAt(info, item) ~= nil then
			table.insert(built, self.kindLabels[item.kind] or item.kind)
		end
	end

	table.insert(parts, "built: " .. table.concat(built, ", "))

	local nextUp = self:nextBuildings(info.rank)

	if nextUp ~= nil then
		table.insert(parts, "next rank brings " .. nextUp)
	end

	table.insert(parts, "treasury " .. credits(info.treasury) .. " credits")

	if #info.candidates > 0 then
		local names = {}

		for _, c in ipairs(info.candidates) do
			table.insert(names, self:candidateName(info, c.oid))
		end

		table.insert(parts, "running for mayor: " .. table.concat(names, ", "))
	end

	if info.registered then
		table.insert(parts, "on the planetary map")
	end

	writeStringData(ck("summary"), table.concat(parts, "; "))
end

-- The mayor's chores publish what they see, for everyone's lines and the status
function BotCityJobs:publish(info)
	writeData(ck("knownRank"), info.rank)
	writeData(ck("mayor"), info.mayor)
	writeData(ck("treasury"), math.floor(info.treasury))
	writeData(ck("citizens"), info.citizens)
	self:writeSummary(info)
end

-- Lines: {name} the player, {city} the city, plus the mayor's {rank}, {treasury}, {next}, {citizens}, {spec}
function BotCityJobs:fill(line, extra)
	if line == nil then
		return nil
	end

	for k, v in pairs(extra or {}) do
		line = line:gsub("{" .. k .. "}", function() return tostring(v) end)
	end

	return line
end

-- Console

function BotCityJobs:status()
	local plan = self:plan()
	local info = self:info()

	if info == nil then
		print("BotCity: " .. plan.name .. " is not founded" .. (botCityInfo == nil and " (this build has no city bindings)" or ""))
	else
		local mayorName = self:candidateName(info, info.mayor)

		print(string.format("BotCity: %s rank %d (%s), %d citizens, radius %d m, treasury %s, next update %s, mayor %s%s",
			plan.name, info.rank, self:rankName(info.rank), info.citizens, info.radius, credits(info.treasury),
			tostring(info.nextUpdate), mayorName, self:isBotOid(info.mayor) and " (bot)" or " (human)"))
		print(string.format("BotCity:   zoning %s, registered %s, specialization %s, decorations %d, upkeep about %s a week",
			tostring(info.zoning), tostring(info.registered), info.spec ~= "" and info.spec or "none", info.decorations,
			credits(self:upkeepAt(info.rank, info.decorations))))

		local names = {}

		for _, c in ipairs(info.candidates) do
			table.insert(names, self:candidateName(info, c.oid) .. " " .. c.votes)
		end

		print("BotCity:   election: " .. (#names > 0 and table.concat(names, ", ") or "no candidates") ..
			(info.votingLocked and " (ballot locked)" or "") .. (info.electionIn ~= nil and (", decided in " .. info.electionIn) or ""))

		for rank = 1, 5 do
			local line = {}

			for _, item in ipairs(plan.civic) do
				if item.rank == rank then
					local built = self:builtOid(item, info, nil) ~= nil
					table.insert(line, (self.kindLabels[item.kind] or item.kind) .. (built and " built" or
						(" missing (" .. item.by .. (readData(ck("fails:" .. item.id)) > 0 and (", " .. readData(ck("fails:" .. item.id)) .. " fails") or "") .. ")")))
				end
			end

			if rank == self.decorationRank and #plan.decorations > 0 then
				table.insert(line, info.decorations .. "/" .. #plan.decorations .. " decorations")
			end

			if #line > 0 then
				print("BotCity:   rank " .. rank .. (rank <= info.rank and "" or " (not yet)") .. ": " .. table.concat(line, ", "))
			end
		end
	end

	for _, entry in ipairs(self:cityEntries()) do
		local first = firstOf(entry.name)
		local pBot = botGetCreature ~= nil and botGetCreature(first) or nil
		local state = "offline"

		if pBot ~= nil then
			local oid = SceneObject(pBot):getObjectID()
			local lot = self:houseLot(oid)
			local house = lot ~= nil and self:ownedAt(pBot, lot) or nil

			state = "online, " .. (lot == nil and "no lot" or (house ~= nil and ("house " .. oidString(house.oid)) or "no house yet")) ..
				", " .. (info ~= nil and info.citizenOids ~= nil and (info.citizenOids[oid] and "citizen" or "not a citizen") or
				(readData(bk(oid, "cityResident")) == 1 and "resident" or "residence not declared")) ..
				", bank " .. credits(CreatureObject(pBot):getBankCredits())

			if self:placing(oid) then
				state = state .. ", placing " .. readStringData(bk(oid, "cityPlacing"))
			end
		end

		print(string.format("BotCity:   %-22s %-9s %s", tostring(entry.name), tostring(entry.job), state))
	end

	if self:summary() ~= "" then
		print("BotCity:   brain: " .. self:summary())
	end
end

function BotCityJobs:planDump()
	local plan = self:plan()

	print("BotCity: plan " .. plan.name .. " on " .. plan.planet .. ", hall " .. plan.hall.x .. " " .. plan.hall.y .. ", " ..
		#plan.houses .. " house lots, " .. #plan.civic .. " civic buildings, " .. #plan.decorations .. " decorations, " ..
		#plan.taxes .. " taxes, specialization " .. tostring(plan.spec))

	for _, item in ipairs(plan.houses) do
		print(string.format("BotCity:   %-22s %8.1f %8.1f angle %d %s", item.id, item.x, item.y, item.angle, item.deed))
	end

	for _, item in ipairs(plan.civic) do
		print(string.format("BotCity:   %-22s %8.1f %8.1f angle %d rank %d by %s %s", item.id, item.x, item.y, item.angle,
			item.rank, item.by, item.deed))
	end

	local square = {}

	for job, spot in pairs(plan.waitSpots) do
		table.insert(square, string.format("%s %.0f %.0f", job, spot.x, spot.y))
	end

	table.sort(square)
	print(string.format("BotCity:   mayor at %.0f %.0f; waiting: %s; %d spots on the square", plan.mayorSpot.x, plan.mayorSpot.y,
		table.concat(square, ", "), #plan.squareSpots))

	for _, p in ipairs(plan.problems) do
		print("BotCity:   problem: " .. p)
	end
end

function BotCityJobs:showPlan()
	self:planDump()
end

-- The mayor, if online
function BotCityJobs:mayorBot()
	local entry = self:entryWithJob("mayor")

	return entry ~= nil and botGetCreature ~= nil and botGetCreature(firstOf(entry.name)) or nil
end

function BotCityJobs:devFast(on)
	local value = on == "on" or on == "1" or on == "true"

	writeData(ck("fast"), value and 1 or 0)
	print("BotCity: fast city chores " .. tostring(value))
end

-- Development: one rank now, and its buildings placed straight away
function BotCityJobs:fastForward()
	local pMayor = self:mayorBot()

	if pMayor == nil or botCityExpand == nil then
		print("BotCity: fastForward needs the mayor online and a build with the city bindings")
		return
	end

	writeData(ck("fast"), 1)
	-- One rank: the mayor's devExpand turns this into the new rank, and fast mode ends when its buildings are up
	writeData(ck("toRank"), -1)
	writeData(ck("toRankSince"), os.time())
	createEvent(10, "BotMayor", "devExpand", pMayor, "")
end

function BotCityJobs:toRank(rank)
	local pMayor = self:mayorBot()

	if pMayor == nil or botCityExpand == nil then
		print("BotCity: toRank needs the mayor online and a build with the city bindings")
		return
	end

	writeData(ck("fast"), 1)
	writeData(ck("toRank"), tonumber(rank) or 5)
	writeData(ck("toRankSince"), os.time())
	print("BotCity: fast-forwarding to rank " .. (tonumber(rank) or 5))
	createEvent(10, "BotMayor", "devExpand", pMayor, "")
end

function BotCityJobs:devVote()
	for _, entry in ipairs(self:cityEntries()) do
		local pBot = botGetCreature ~= nil and botGetCreature(firstOf(entry.name)) or nil

		if pBot ~= nil then
			createEvent(10, "BotCityJobs", "devVoteNow", pBot, "")
		end
	end
end

function BotCityJobs:devVoteNow(pBot, args)
	local oid = SceneObject(pBot):getObjectID()

	deleteData(bk(oid, "cityVote"))
	self:vote(pBot, oid, self:info())
end

-- Lines

BotLines = BotLines or {}
BotLines.cityNames = BotLines.cityNames or {}
BotLines.cityNames.varenhal = BotLines.cityNames.varenhal or "Varenhal"

BotLines.mayor = {
	-- Now and then at the city hall with someone near: taxes, the rank, the treasury, the election
	politics = {
		"Rank {rank} already. Not bad for a town that was grass and shaak a few weeks back.",
		"Treasury's at {treasury}. The city hall alone eats thirty-five thousand a week, and that's before the gardens.",
		"Next rank brings the {next}. We just need the update to come through.",
		"{citizens} citizens on the rolls. Every one of them counts at the weekly update.",
		"Taxes stay low in {city}. I'd rather fill the streets than the treasury.",
		"Theed has its Palace. We have a cantina that stays open all night.",
		"Anyone can run for mayor here. Train Novice Politician, register at the terminal, and win the vote.",
		"If you want to settle down, zoning's open. Put a house inside the limits and declare residence.",
		"The upkeep bill came in again. I swear the gardeners charge by the leaf.",
		"Somebody keeps asking for a shuttleport. Rank four, friend. Patience.",
	},
	-- At rank 5 (the next-rank lines no longer apply)
	politicsTop = {
		"A metropolis. Rank five. They said a town this far from Theed would never last.",
		"Shuttleport, theater, statues on the square. {city} has it all now.",
		"Treasury's at {treasury}. Keeping a metropolis running isn't cheap.",
	},
	-- A human comes up to the city hall
	greet = {
		"Welcome to {city}, {name}.",
		"Good to see a new face in {city}, {name}.",
		"{name}! Looking for a place to settle? {city} has room.",
	},
	fallback = {
		"Sorry, city business. Ask me about {city} later.",
		"One moment, I'm going over the treasury reports.",
		"Hmm? Busy with the paperwork. The terminal inside has everything about {city}.",
	},
	thanks = {
		"Thank you, {name}. It all goes to the city.",
		"Generous of you, {name}. The treasury thanks you.",
	},
	thanksAnon = {
		"Thank you kindly. Every credit helps.",
	},
	-- Founding and rank-ups, said out loud at the city hall
	founded = {
		"And with that, {city} is a city. Welcome home, everyone.",
	},
	rankUp = {
		"The update's in: {city} is a {rankName} now!",
		"Rank {rank}! Time to put up the {built}.",
	},
}

BotLines.citizen = {
	fallback = {
		"Sorry, can't talk now, I've got errands.",
		"Hm? Oh, busy day. Catch me later.",
		"Not now, friend. Maybe at the cantina tonight.",
	},
	thanks = {
		"Oh! Thanks, {name}.",
		"That's kind of you, {name}.",
	},
	thanksAnon = {
		"Huh, thanks, whoever that was.",
	},
}

-- The city's dancer, musician and doctor: their own jobs, with the city's work first
BotCityJobs:wrap("dancer")
BotCityJobs:wrap("musician")
BotCityJobs:wrap("doctor")
