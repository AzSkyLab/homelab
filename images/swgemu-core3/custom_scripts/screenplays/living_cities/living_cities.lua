-- Living Cities: player-looking NPCs who run errands, hang out, chat and come and go in Mos Eisley, Coronet and Theed.
-- Spec: ~/github/swgemu/specs/2026-10-23-living-cities/. City data in cities/, chatter in lines.lua, bodies and outfits
-- in custom_scripts/mobile/living_cities/.
--
-- Core3 runs one Lua state per thread, so nothing here lives in Lua globals between calls: crowd state is in shared
-- memory (writeData / writeStringData). Every timer chain carries the generation it was started in; restart() bumps
-- the generation, so older chains stop on their next tick. Anything that changes an NPC runs in an event on that NPC,
-- so it holds the NPC's lock.
--
-- Console (output in the pod log):
--   runLuaFunction LivingCities:report     headcount, target and swaps per city
--   runLuaFunction LivingCities:restart    clear and rebuild every crowd (after reloadscreenplays in development)
--   runLuaFunction LivingCities:dump       every member: name, kit, state, spot, position
--   runLuaFunction LivingCities:devNight   pretend it is 03:00 (devEvening: 20:00, devClock: the real clock again)
--   runLuaFunction LivingCities:devAwake   act as if a player were always near (for a test server with no players;
--                                          devAsleep undoes it)
--   runLuaFunction LivingCities:devFast    lingers and crowd checks six times shorter (devNormal undoes it)
--   runLuaFunction LivingCities:lineup     one of each kit, twice, by the Mos Eisley starport for ten minutes

LivingCitiesData = LivingCitiesData or {}

includeFile("../custom_scripts/mobile/living_cities/bodies.lua")
includeFile("../custom_scripts/screenplays/living_cities/lines.lua")
includeFile("../custom_scripts/screenplays/living_cities/names.lua")
includeFile("../custom_scripts/screenplays/living_cities/cities/mos_eisley.lua")
includeFile("../custom_scripts/screenplays/living_cities/cities/coronet.lua")
includeFile("../custom_scripts/screenplays/living_cities/cities/theed.lua")

-- NPC states
local WALKING = 1
local LINGERING = 2
local LEAVING = 3
local TALKING = 4

LivingCities = ScreenPlay:new {
	screenplayName = "LivingCities",

	cities = {"mos_eisley", "coronet", "theed"},

	planetNames = {tatooine = "Tatooine", corellia = "Corellia", naboo = "Naboo"},

	-- Live NPCs per city never exceed this, whatever the city data says
	maxCrowd = 30,

	-- Share of the evening crowd by local hour (0-23): 18-24 full, 8-18 60%, 0-2 half, 2-8 a quarter
	hourShare = {0.5, 0.5, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 1, 1, 1, 1, 1, 1},

	-- Kit shares of the crowd (percent) and where each kit likes to be (weights per place)
	kits = {
		{name = "fighter", share = 30, places = {starport = 3, cantina = 3, plaza = 2, bank = 1, shops = 1, medical = 1, hotel = 1}},
		{name = "crafter", share = 25, places = {bank = 3, shops = 3, plaza = 2, cantina = 1, starport = 1, hotel = 1, medical = 0.5}},
		{name = "entertainer", share = 15, places = {cantina = 5, plaza = 2, hotel = 1, starport = 0.5, bank = 0.5, shops = 0.5, medical = 0.5}},
		{name = "medic", share = 10, places = {medical = 4, cantina = 2, plaza = 1, starport = 1, bank = 1, shops = 0.5, hotel = 0.5}},
		{name = "traveller", share = 20, places = {starport = 3, cantina = 2, bank = 2, hotel = 2, plaza = 1, shops = 1, medical = 0.5}},
	},

	-- How likely a kit takes a slot with this act (dancing is for entertainers)
	actWeight = {dance = {entertainer = 1, other = 0.05}},

	-- Moods for each act; stand picks one at random
	actMoods = {
		stand = {"neutral", "calm", "neutral", "bored"},
		pair = {"conversation"},
		sit = {"npc_sitting_chair"},
		dance = {"themepark_oola"},
		terminal = {"npc_use_terminal_high"},
		drink = {"npc_standing_drinking"},
	},

	-- Seconds spent at a spot: by act first, then by place, then the default
	linger = {
		act = {dance = {240, 600}, sit = {240, 600}},
		place = {cantina = {180, 600}},
		default = {60, 300},
	},

	-- Seconds between crowd checks per city (headcount, arrivals, departures)
	swapInterval = {120, 360},
	-- Someone leaves about this often (seconds) even when the headcount is right
	turnover = 600,

	-- Chatter: checked every chatterSeconds seconds; an NPC with a player within chatterRange says something about once
	-- every chatterEvery seconds; greetings within greetRange, once per greetCooldown per NPC and player
	chatterSeconds = 15,
	chatterRange = 40,
	chatterEvery = 270,
	greetRange = 6,
	greetChance = 35,
	greetCooldown = 600,
	animationChance = 3,
	exchangeChance = 50,

	-- A walk not finished in time (with a player near) counts as stuck: walkTimeout seconds plus one per metre outdoors
	-- (NPCs walk at about 1.5 m/s), or walkTimeoutIndoors when a building is involved (cell positions aren't world ones)
	walkTimeout = 60,
	walkTimeoutIndoors = 360,
	-- Players within this range of an NPC see it arrive or leave; otherwise it just appears in a slot or vanishes
	seenRange = 100,
}

registerScreenPlay("LivingCities", true)

-- Helpers

local function rand(a, b)
	return getRandomNumber(a, b)
end

local function percent(chance)
	return getRandomNumber(1, 100) <= chance
end

local function pickWeighted(items, weightOf)
	local total = 0

	for i = 1, #items do
		total = total + weightOf(items[i])
	end

	if total <= 0 then
		return nil
	end

	local roll = getRandomNumber(1, 100000) / 100000 * total

	for i = 1, #items do
		roll = roll - weightOf(items[i])

		if roll <= 0 then
			return items[i]
		end
	end

	return items[#items]
end

local function pickOne(list)
	if list == nil or #list == 0 then
		return nil
	end

	return list[getRandomNumber(1, #list)]
end

local function npcKey(oid, field)
	return "lc:npc:" .. oid .. ":" .. field
end

local function cityKey(key, field)
	return "lc:" .. key .. ":" .. field
end

local function slotKey(key, spot, slot)
	return "lc:" .. key .. ":slot:" .. spot .. ":" .. slot
end

local function capitalize(word)
	return word:sub(1, 1):upper() .. word:sub(2):lower()
end

-- "a:b:c" for event arguments, and back
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

function LivingCities:generation()
	return readData("lc:gen")
end

-- Development: behave as if a player were near every NPC (a test server has none)
function LivingCities:awake()
	return readData("lc:awake") == 1
end

function LivingCities:devAwake()
	writeData("lc:awake", 1)
	print("LivingCities: awake, as if players were everywhere")
end

function LivingCities:devAsleep()
	deleteData("lc:awake")
	print("LivingCities: only near real players again")
end

-- Development: lingers and crowd checks six times faster, to see many errands in a short test
function LivingCities:fast()
	return readData("lc:fast") == 1
end

function LivingCities:devFast()
	writeData("lc:fast", 1)
	print("LivingCities: fast (lingers and crowd checks six times shorter)")
end

function LivingCities:devNormal()
	deleteData("lc:fast")
	print("LivingCities: normal speed")
end

function LivingCities:nobodyNear(pNpc, range)
	if self:awake() then
		return false
	end

	return #(SceneObject(pNpc):getPlayersInRange(range) or {}) == 0
end

-- Start and restart

function LivingCities:start()
	local gen = self:generation() + 1
	writeData("lc:gen", gen)

	print("LivingCities: started, local hour " .. self:hour() .. ", generation " .. gen)

	for _, key in ipairs(self.cities) do
		self:startCity(key, gen)
	end
end

function LivingCities:restart()
	local gen = self:generation() + 1
	writeData("lc:gen", gen)

	for _, key in ipairs(self.cities) do
		self:clearCity(key)
	end

	print("LivingCities: restarted, generation " .. gen)

	for _, key in ipairs(self.cities) do
		self:startCity(key, gen)
	end
end

function LivingCities:startCity(key, gen)
	local city = LivingCitiesData[key]

	if city == nil then
		print("LivingCities: no data for " .. key)
		return
	end

	if not isZoneEnabled(city.planet) then
		return
	end

	local target = self:target(key)

	for i = 1, target do
		self:spawnNpc(key, gen, false)
	end

	writeData(cityKey(key, "lastTurnover"), os.time())

	createEvent(rand(self.swapInterval[1], self.swapInterval[2]) * 1000, "LivingCities", "swapTick", nil, packArgs(key, gen))
	createEvent((self.chatterSeconds + rand(0, 5)) * 1000, "LivingCities", "chatterTick", nil, packArgs(key, gen))

	print("LivingCities: " .. city.name .. " crowd " .. self:liveCount(key) .. " (target " .. target .. ")")
end

function LivingCities:clearCity(key)
	local city = LivingCitiesData[key]

	if city == nil then
		return
	end

	for seat = 1, self.maxCrowd do
		local oid = readData(cityKey(key, "seat:" .. seat))

		if oid ~= 0 then
			self:despawn(oid)
		end
	end

	-- Slots left behind by NPCs that went some other way
	for spotIndex, spot in ipairs(city.spots) do
		for slotIndex = 1, #spot.slots do
			deleteData(slotKey(key, spotIndex, slotIndex))
		end
	end
end

-- The clock

function LivingCities:hour()
	local override = readData("lc:hourOverride")

	if override > 0 then
		return override - 1
	end

	return os.date("*t").hour
end

function LivingCities:devNight()
	writeData("lc:hourOverride", 3 + 1)
	print("LivingCities: clock set to 03:00")
end

function LivingCities:devEvening()
	writeData("lc:hourOverride", 20 + 1)
	print("LivingCities: clock set to 20:00")
end

function LivingCities:devClock()
	deleteData("lc:hourOverride")
	print("LivingCities: back to the real clock, hour " .. self:hour())
end

function LivingCities:target(key)
	local city = LivingCitiesData[key]
	local target = math.floor(city.crowd * self.hourShare[self:hour() + 1] + 0.5)

	return math.min(target, self.maxCrowd)
end

-- Seats: one shared-memory key per crowd member, so adding and removing never race on a list

function LivingCities:freeSeat(key)
	for seat = 1, self.maxCrowd do
		if readData(cityKey(key, "seat:" .. seat)) == 0 then
			return seat
		end
	end

	return nil
end

function LivingCities:members(key)
	local out = {}

	for seat = 1, self.maxCrowd do
		local oid = readData(cityKey(key, "seat:" .. seat))

		if oid ~= 0 then
			local pNpc = getSceneObject(oid)

			if pNpc ~= nil and SceneObject(pNpc):getZoneName() ~= "" then
				table.insert(out, pNpc)
			else
				-- Gone without telling us; free the seat
				self:forget(key, oid)
			end
		end
	end

	return out
end

function LivingCities:liveCount(key)
	local count = 0

	for _, pNpc in ipairs(self:members(key)) do
		if readData(npcKey(SceneObject(pNpc):getObjectID(), "state")) ~= LEAVING then
			count = count + 1
		end
	end

	return count
end

-- Choosing who and where

function LivingCities:pickKit()
	return pickWeighted(self.kits, function(kit) return kit.share end)
end

function LivingCities:pickBody(kitName)
	return pickWeighted(LivingCitiesBodies[kitName], function(body) return body.weight end)
end

function LivingCities:kitByName(name)
	for _, kit in ipairs(self.kits) do
		if kit.name == name then
			return kit
		end
	end

	return self.kits[1]
end

-- A free slot in a spot other than the current one, weighted by the kit's liking for the place and the act
function LivingCities:pickSlot(key, kit, currentSpot)
	local city = LivingCitiesData[key]
	local choices = {}

	for spotIndex, spot in ipairs(city.spots) do
		if spotIndex ~= currentSpot then
			local placeWeight = kit.places[spot.place] or 0
			local free = {}

			for slotIndex, slot in ipairs(spot.slots) do
				if readData(slotKey(key, spotIndex, slotIndex)) == 0 then
					local weight = 1
					local actWeight = self.actWeight[slot.act]

					if actWeight ~= nil then
						weight = actWeight[kit.name] or actWeight.other
					end

					if weight > 0 then
						table.insert(free, {spot = spotIndex, slot = slotIndex, weight = weight})
					end
				end
			end

			-- A spot's pull is its place weight, shared among its free slots
			for _, choice in ipairs(free) do
				choice.weight = choice.weight * placeWeight / #free
				table.insert(choices, choice)
			end
		end
	end

	return pickWeighted(choices, function(choice) return choice.weight end)
end

-- A first name nobody else in this city is using, and a surname: from names.lua (per species where it has a list),
-- falling back to Core3's name generator if the list runs dry
function LivingCities:makeName(key, species)
	local names = LivingCitiesNames[species] or LivingCitiesNames

	for i = 1, 30 do
		local first, last

		if i <= 20 then
			first, last = pickOne(names.first), pickOne(names.last)
		else
			first = capitalize(string.match(makeCreatureName(), "%a+") or "")
			last = capitalize(string.match(makeCreatureName(), "%a+") or "")
		end

		if #first >= 3 and #last >= 3 and first ~= last and readData(cityKey(key, "name:" .. first:lower())) == 0 then
			return first, last
		end
	end

	return nil, nil
end

-- Floor height for a slot: given for cells, asked of the world outdoors
function LivingCities:slotZ(city, pos)
	if pos.cell ~= nil and pos.cell ~= 0 then
		return pos.z or 0
	end

	return getWorldFloor(pos.x, pos.y, city.planet)
end

function LivingCities:slotOf(key, oid)
	local spot = LivingCitiesData[key].spots[readData(npcKey(oid, "spot"))]

	if spot == nil then
		return nil, nil
	end

	return spot, spot.slots[readData(npcKey(oid, "slot"))]
end

-- Spawning and despawning

-- atArrival: appear at the city's arrival point and walk in; otherwise appear straight in a free slot
function LivingCities:spawnNpc(key, gen, atArrival)
	local city = LivingCitiesData[key]
	local seat = self:freeSeat(key)

	if seat == nil then
		return nil
	end

	local kit = self:pickKit()
	local body = self:pickBody(kit.name)
	local first, last = self:makeName(key, body ~= nil and body.species or "human")

	if body == nil or first == nil then
		return nil
	end

	local choice = nil
	local pos = city.arrival

	if not atArrival then
		choice = self:pickSlot(key, kit, 0)

		if choice == nil then
			return nil
		end

		pos = city.spots[choice.spot].slots[choice.slot]
	end

	local template = "living_" .. kit.name .. "_" .. body.species .. "_" .. body.sex
	local pNpc = spawnMobile(city.planet, template, 0, pos.x, self:slotZ(city, pos), pos.y, pos.heading or 0, pos.cell or 0)

	if pNpc == nil then
		print("LivingCities: could not spawn " .. template .. " in " .. city.name)
		return nil
	end

	local oid = SceneObject(pNpc):getObjectID()

	writeData(cityKey(key, "seat:" .. seat), oid)
	writeData(cityKey(key, "name:" .. first:lower()), oid)
	writeData(npcKey(oid, "seat"), seat)
	writeData(npcKey(oid, "gen"), gen)
	writeData(npcKey(oid, "seq"), 0)
	writeStringData(npcKey(oid, "city"), key)
	writeStringData(npcKey(oid, "kit"), kit.name)
	writeStringData(npcKey(oid, "species"), body.species)
	writeStringData(npcKey(oid, "sex"), body.sex)
	writeStringData(npcKey(oid, "first"), first)
	writeStringData(npcKey(oid, "name"), first .. " " .. last)

	SceneObject(pNpc):setCustomObjectName(first .. " " .. last)
	CreatureObject(pNpc):setPvpStatusBitmask(0)
	AiAgent(pNpc):addObjectFlag(AI_STATIONARY)
	createObserver(DESTINATIONREACHED, "LivingCities", "onArrived", pNpc)

	-- Phase 2: NPCs that talk
	if LivingTalk ~= nil then
		LivingTalk:setupNpc(pNpc)
	end

	if atArrival then
		writeData(npcKey(oid, "state"), LINGERING)
		createEvent(rand(3, 8) * 1000, "LivingCities", "nextErrand", pNpc, packArgs(gen, 0))
		self:count(key, "arrived")
	else
		self:occupy(pNpc, key, choice.spot, choice.slot)
		-- Spread out the first moves after a boot
		self:startLinger(pNpc, key, gen, 0.3)
	end

	return pNpc
end

function LivingCities:occupy(pNpc, key, spot, slot)
	local oid = SceneObject(pNpc):getObjectID()

	writeData(slotKey(key, spot, slot), oid)
	writeData(npcKey(oid, "spot"), spot)
	writeData(npcKey(oid, "slot"), slot)
end

function LivingCities:release(oid, key)
	local spot = readData(npcKey(oid, "spot"))
	local slot = readData(npcKey(oid, "slot"))

	if spot ~= 0 and readData(slotKey(key, spot, slot)) == oid then
		deleteData(slotKey(key, spot, slot))
	end

	writeData(npcKey(oid, "spot"), 0)
	writeData(npcKey(oid, "slot"), 0)
end

-- Remove an NPC from the world and from every record. Call it from an event without the NPC's lock
-- (despawnLater), the console, or a crowd tick.
function LivingCities:despawn(oid)
	local pNpc = getSceneObject(oid)
	local key = readStringData(npcKey(oid, "city"))

	self:forget(key, oid)

	if pNpc ~= nil then
		SceneObject(pNpc):destroyObjectFromWorld()
	end
end

function LivingCities:despawnLater(pNothing, args)
	self:despawn(tonumber(args))
end

function LivingCities:forget(key, oid)
	if key ~= "" then
		self:release(oid, key)

		local seat = readData(npcKey(oid, "seat"))

		if seat ~= 0 and readData(cityKey(key, "seat:" .. seat)) == oid then
			deleteData(cityKey(key, "seat:" .. seat))
		end

		local first = readStringData(npcKey(oid, "first"))

		if first ~= "" and readData(cityKey(key, "name:" .. first:lower())) == oid then
			deleteData(cityKey(key, "name:" .. first:lower()))
		end
	end

	if LivingTalk ~= nil then
		LivingTalk:npcGone(oid)
	end

	for _, field in ipairs({"seat", "gen", "seq", "state", "spot", "slot", "stuck", "walkTimeout"}) do
		deleteData(npcKey(oid, field))
	end

	for _, field in ipairs({"city", "kit", "species", "sex", "first", "name"}) do
		deleteStringData(npcKey(oid, field))
	end
end

-- The errand cycle: linger at a slot, pick the next, walk there, linger again

-- Is this event still meant for this NPC? (same generation, NPC still in the world, still one of ours)
function LivingCities:current(pNpc, gen)
	if pNpc == nil or SceneObject(pNpc):getZoneName() == "" then
		return false
	end

	local oid = SceneObject(pNpc):getObjectID()

	return readData(npcKey(oid, "gen")) == tonumber(gen) and tonumber(gen) == self:generation()
end

function LivingCities:startLinger(pNpc, key, gen, shorten)
	local oid = SceneObject(pNpc):getObjectID()
	local spot, slot = self:slotOf(key, oid)

	if slot == nil then
		return
	end

	writeData(npcKey(oid, "state"), LINGERING)

	if slot.heading ~= nil then
		SceneObject(pNpc):updateDirection(math.rad(slot.heading))
	end

	CreatureObject(pNpc):setMoodString(pickOne(self.actMoods[slot.act] or self.actMoods.stand))

	-- Pairs face each other when both are there (the partner turns in its own event)
	if slot.act == "pair" and slot.pair ~= nil then
		local partnerOid = readData(slotKey(key, readData(npcKey(oid, "spot")), slot.pair))
		local pPartner = partnerOid ~= 0 and getSceneObject(partnerOid) or nil

		if pPartner ~= nil and readData(npcKey(partnerOid, "state")) == LINGERING then
			SceneObject(pNpc):faceObject(pPartner, true)
			createEvent(500, "LivingCities", "faceTowards", pPartner, packArgs(gen, oid))
		end
	end

	local range = self.linger.act[slot.act] or self.linger.place[spot.place] or self.linger.default
	local seconds = rand(range[1], range[2])

	if shorten ~= nil then
		seconds = math.max(20, math.floor(seconds * shorten))
	end

	if self:fast() then
		seconds = math.max(10, seconds // 6)
	end

	local seq = readData(npcKey(oid, "seq"))
	createEvent(seconds * 1000, "LivingCities", "nextErrand", pNpc, packArgs(gen, seq))
end

function LivingCities:faceTowards(pNpc, args)
	local a = unpackArgs(args)

	if not self:current(pNpc, a[1]) then
		return
	end

	local pOther = getSceneObject(tonumber(a[2]))

	if pOther ~= nil then
		SceneObject(pNpc):faceObject(pOther, true)
	end
end

function LivingCities:nextErrand(pNpc, args)
	local a = unpackArgs(args)
	local gen, seq = a[1], tonumber(a[2])

	if not self:current(pNpc, gen) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local key = readStringData(npcKey(oid, "city"))
	local state = readData(npcKey(oid, "state"))

	-- A newer errand took over, or the NPC is walking or on its way out
	if readData(npcKey(oid, "seq")) ~= seq or state == LEAVING or state == WALKING then
		return
	end

	-- Talking to a player (Phase 2): ask again later
	if state == TALKING then
		createEvent(20 * 1000, "LivingCities", "nextErrand", pNpc, args)
		return
	end

	local kit = self:kitByName(readStringData(npcKey(oid, "kit")))
	local choice = self:pickSlot(key, kit, readData(npcKey(oid, "spot")))

	if choice == nil then
		-- Everywhere is taken: stay a while longer
		createEvent(60 * 1000, "LivingCities", "nextErrand", pNpc, args)
		return
	end

	self:release(oid, key)
	self:occupy(pNpc, key, choice.spot, choice.slot)
	self:walkTo(pNpc, key, gen, LivingCitiesData[key].spots[choice.spot].slots[choice.slot], WALKING)
end

function LivingCities:walkTo(pNpc, key, gen, pos, state)
	local city = LivingCitiesData[key]
	local oid = SceneObject(pNpc):getObjectID()
	local seq = readData(npcKey(oid, "seq")) + 1

	writeData(npcKey(oid, "seq"), seq)
	writeData(npcKey(oid, "state"), state)

	CreatureObject(pNpc):setMoodString("neutral")
	AiAgent(pNpc):setNextPosition(pos.x, self:slotZ(city, pos), pos.y, pos.cell or 0)

	local timeout = self.walkTimeoutIndoors

	if (pos.cell or 0) == 0 and SceneObject(pNpc):getParentID() == 0 then
		local dx = pos.x - SceneObject(pNpc):getPositionX()
		local dy = pos.y - SceneObject(pNpc):getPositionY()
		timeout = self.walkTimeout + math.floor(math.sqrt(dx * dx + dy * dy))
	end

	writeData(npcKey(oid, "walkTimeout"), timeout)
	createEvent(timeout * 1000, "LivingCities", "walkWatchdog", pNpc, packArgs(gen, seq))
end

function LivingCities:onArrived(pNpc)
	if pNpc == nil then
		return 0
	end

	local oid = SceneObject(pNpc):getObjectID()
	local gen = readData(npcKey(oid, "gen"))

	if gen == 0 or gen ~= self:generation() then
		return 0
	end

	local key = readStringData(npcKey(oid, "city"))
	local state = readData(npcKey(oid, "state"))

	if state == WALKING then
		writeData(npcKey(oid, "stuck"), 0)
		self:startLinger(pNpc, key, gen)
	elseif state == LEAVING then
		-- Destroy it outside this observer's lock
		createEvent(1000, "LivingCities", "despawnLater", nil, tostring(oid))
		self:count(key, "left")
	end

	return 0
end

-- A walk that hasn't arrived: if nobody is near, the AI is simply asleep; otherwise the NPC is stuck
function LivingCities:walkWatchdog(pNpc, args)
	local a = unpackArgs(args)
	local gen, seq = a[1], tonumber(a[2])

	if not self:current(pNpc, gen) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local state = readData(npcKey(oid, "state"))

	if readData(npcKey(oid, "seq")) ~= seq or (state ~= WALKING and state ~= LEAVING) then
		return
	end

	if AiAgent(pNpc):getNumberOfPlayersInRange() == 0 and not self:awake() then
		createEvent(readData(npcKey(oid, "walkTimeout")) * 1000, "LivingCities", "walkWatchdog", pNpc, args)
		return
	end

	local key = readStringData(npcKey(oid, "city"))
	local city = LivingCitiesData[key]
	local spot = self:slotOf(key, oid)
	local stuck = readData(npcKey(oid, "stuck")) + 1

	print(string.format("LivingCities: %s stuck in %s at %.1f %.1f cell %d on the way to %s", readStringData(npcKey(oid, "name")),
		city.name, SceneObject(pNpc):getPositionX(), SceneObject(pNpc):getPositionY(), SceneObject(pNpc):getParentID(),
		state == LEAVING and "the arrival point" or (spot ~= nil and spot.id or "?")))
	self:count(key, "stuck")

	if state == LEAVING or stuck >= 2 then
		-- Give up on this one: it goes, and the crowd check brings someone new
		createEvent(1000, "LivingCities", "despawnLater", nil, tostring(oid))
		return
	end

	writeData(npcKey(oid, "stuck"), stuck)
	writeData(npcKey(oid, "state"), LINGERING)
	self:nextErrand(pNpc, packArgs(gen, seq))
end

-- Comings and goings

function LivingCities:swapTick(pNothing, args)
	local a = unpackArgs(args)
	local key, gen = a[1], tonumber(a[2])

	if gen ~= self:generation() then
		return
	end

	local target = self:target(key)
	local live = self:liveCount(key)
	local now = os.time()

	if live > target then
		self:sendAway(key, gen)
	elseif live < target then
		self:arrive(key, gen)
	elseif now - readData(cityKey(key, "lastTurnover")) >= self.turnover then
		-- A steady evening: one leaves, and the next check brings a new face
		writeData(cityKey(key, "lastTurnover"), now)
		self:sendAway(key, gen)
	end

	local wait = rand(self.swapInterval[1], self.swapInterval[2])

	if self:fast() then
		wait = wait // 6
	end

	createEvent(wait * 1000, "LivingCities", "swapTick", nil, args)
end

function LivingCities:sendAway(key, gen)
	local candidates, unseen = {}, {}

	for _, pNpc in ipairs(self:members(key)) do
		local state = readData(npcKey(SceneObject(pNpc):getObjectID(), "state"))

		if state == LINGERING then
			table.insert(candidates, pNpc)
		elseif state == WALKING and self:nobodyNear(pNpc, self.seenRange) then
			-- With nobody near, Core3 pauses the AI mid-walk; such an NPC can leave unseen
			table.insert(unseen, pNpc)
		end
	end

	local pNpc = pickOne(candidates) or pickOne(unseen)

	if pNpc == nil then
		return
	end

	-- Nobody watching: just go
	if self:nobodyNear(pNpc, self.seenRange) then
		self:despawn(SceneObject(pNpc):getObjectID())
		self:count(key, "left")
		return
	end

	createEvent(100, "LivingCities", "leaveNow", pNpc, tostring(gen))
end

function LivingCities:leaveNow(pNpc, args)
	if not self:current(pNpc, args) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local key = readStringData(npcKey(oid, "city"))

	if readData(npcKey(oid, "state")) ~= LINGERING then
		return
	end

	self:release(oid, key)
	self:walkTo(pNpc, key, tonumber(args), LivingCitiesData[key].arrival, LEAVING)
end

function LivingCities:arrive(key, gen)
	local city = LivingCitiesData[key]
	local pNpc = self:spawnNpc(key, gen, true)

	if pNpc == nil or not self:nobodyNear(pNpc, self.seenRange) then
		return
	end

	-- Nobody at the starport to see them arrive: put them straight into the city
	local oid = SceneObject(pNpc):getObjectID()
	local choice = self:pickSlot(key, self:kitByName(readStringData(npcKey(oid, "kit"))), 0)

	if choice ~= nil then
		local pos = city.spots[choice.spot].slots[choice.slot]

		self:occupy(pNpc, key, choice.spot, choice.slot)
		writeData(npcKey(oid, "seq"), readData(npcKey(oid, "seq")) + 1)
		SceneObject(pNpc):teleport(pos.x, self:slotZ(city, pos), pos.y, pos.cell or 0)
		self:startLinger(pNpc, key, gen)
	end
end

-- Chatter: the city tick decides, then each NPC acts in its own event

function LivingCities:fill(line, city)
	line = line:gsub("{city}", city.name)
	line = line:gsub("{planet}", self.planetNames[city.planet] or city.planet)

	return line
end

function LivingCities:pickLine(key, oid)
	local lines = LivingCitiesLines
	local spot = self:slotOf(key, oid)
	local roll = rand(1, 100)
	local pool

	if roll <= 35 and spot ~= nil then
		pool = lines.place[spot.place]
	elseif roll <= 60 then
		pool = lines.kit[readStringData(npcKey(oid, "kit"))]
	elseif roll <= 80 then
		pool = lines.city[key]
	end

	return self:fill(pickOne(pool) or pickOne(lines.general), LivingCitiesData[key])
end

function LivingCities:chatterTick(pNothing, args)
	local a = unpackArgs(args)
	local key, gen = a[1], tonumber(a[2])

	if gen ~= self:generation() then
		return
	end

	local now = os.time()
	local speakChance = math.floor(100000 * self.chatterSeconds / self.chatterEvery)

	for _, pNpc in ipairs(self:members(key)) do
		local oid = SceneObject(pNpc):getObjectID()
		local state = readData(npcKey(oid, "state"))

		if state == LINGERING or state == WALKING then
			local players = SceneObject(pNpc):getPlayersInRange(self.chatterRange) or {}

			if #players > 0 or self:awake() then
				local action = self:greetTarget(pNpc, oid, players, now)

				if action == nil and rand(1, 100000) <= speakChance then
					action = "speak"
				elseif action == nil and state == LINGERING and percent(self.animationChance) then
					action = "animate"
				end

				if action ~= nil then
					createEvent(rand(0, self.chatterSeconds * 900), "LivingCities", "chatterAct", pNpc, packArgs(gen, action))
				end
			end
		end
	end

	createEvent(self.chatterSeconds * 1000, "LivingCities", "chatterTick", nil, args)
end

-- A player close by who hasn't been greeted by this NPC lately; returns "greet" plus the player's id, or nil
function LivingCities:greetTarget(pNpc, oid, players, now)
	for _, pPlayer in ipairs(players) do
		if SceneObject(pNpc):getDistanceTo(pPlayer) <= self.greetRange then
			local cooldown = npcKey(oid, "greet:" .. SceneObject(pPlayer):getObjectID())

			if now - readData(cooldown) >= self.greetCooldown then
				-- One roll per pass-by: the cooldown starts whether or not they speak
				writeData(cooldown, now)

				if percent(self.greetChance) then
					return "greet:" .. SceneObject(pPlayer):getObjectID()
				end
			end
		end
	end

	return nil
end

function LivingCities:chatterAct(pNpc, args)
	local a = unpackArgs(args)
	local gen, action = a[1], a[2]

	if not self:current(pNpc, gen) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local key = readStringData(npcKey(oid, "city"))
	local state = readData(npcKey(oid, "state"))

	if state ~= LINGERING and state ~= WALKING then
		return
	end

	if action == "greet" then
		local pPlayer = getSceneObject(tonumber(a[3]))

		if pPlayer ~= nil then
			if state == LINGERING then
				SceneObject(pNpc):faceObject(pPlayer, true)
			end

			spatialChat(pNpc, self:fill(pickOne(LivingCitiesLines.greetings), LivingCitiesData[key]))
		end
	elseif action == "speak" then
		self:speak(pNpc, oid, key, gen)
	elseif action == "animate" then
		local spot, slot = self:slotOf(key, oid)

		if slot ~= nil and (slot.act == "stand" or slot.act == "pair" or slot.act == "drink") then
			CreatureObject(pNpc):doAnimation(pickOne(LivingCitiesLines.animations))
		end
	end
end

function LivingCities:speak(pNpc, oid, key, gen)
	local city = LivingCitiesData[key]
	local spot, slot = self:slotOf(key, oid)
	local lingering = readData(npcKey(oid, "state")) == LINGERING

	-- Two standing together: a line, and the partner replies
	if lingering and slot ~= nil and slot.act == "pair" and slot.pair ~= nil and percent(self.exchangeChance) then
		local partnerOid = readData(slotKey(key, readData(npcKey(oid, "spot")), slot.pair))
		local pPartner = partnerOid ~= 0 and getSceneObject(partnerOid) or nil

		if pPartner ~= nil and readData(npcKey(partnerOid, "state")) == LINGERING then
			local index = rand(1, #LivingCitiesLines.exchanges)

			spatialChat(pNpc, self:fill(LivingCitiesLines.exchanges[index][1], city))
			createEvent(rand(3, 6) * 1000, "LivingCities", "reply", pPartner, packArgs(gen, index))
			return
		end
	end

	spatialChat(pNpc, self:pickLine(key, oid))

	-- About one line in five comes with a gesture
	if lingering and slot ~= nil and slot.act ~= "sit" and slot.act ~= "dance" and percent(20) then
		CreatureObject(pNpc):doAnimation(pickOne(LivingCitiesLines.animations))
	end
end

function LivingCities:reply(pNpc, args)
	local a = unpackArgs(args)
	local gen, index = a[1], tonumber(a[2])

	if not self:current(pNpc, gen) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local key = readStringData(npcKey(oid, "city"))
	local exchange = LivingCitiesLines.exchanges[index]

	if exchange ~= nil and readData(npcKey(oid, "state")) == LINGERING then
		spatialChat(pNpc, self:fill(exchange[2], LivingCitiesData[key]))
	end
end

-- Counters, the report and the dump

function LivingCities:count(key, what)
	local name = cityKey(key, "stat:" .. what)
	writeData(name, readData(name) + 1)
end

function LivingCities:report()
	print("LivingCities: generation " .. self:generation() .. ", local hour " .. self:hour())

	for _, key in ipairs(self.cities) do
		local city = LivingCitiesData[key]

		if city ~= nil and isZoneEnabled(city.planet) then
			local states = {0, 0, 0, 0}
			local members = self:members(key)

			for _, pNpc in ipairs(members) do
				local state = readData(npcKey(SceneObject(pNpc):getObjectID(), "state"))

				if states[state] ~= nil then
					states[state] = states[state] + 1
				end
			end

			print(string.format("LivingCities: %s: %d in town (target %d): %d walking, %d lingering, %d leaving, %d talking; " ..
				"since start %d arrived, %d left, %d stuck", city.name, #members, self:target(key), states[WALKING],
				states[LINGERING], states[LEAVING], states[TALKING], readData(cityKey(key, "stat:arrived")),
				readData(cityKey(key, "stat:left")), readData(cityKey(key, "stat:stuck"))))
		end
	end
end

function LivingCities:dump()
	for _, key in ipairs(self.cities) do
		local city = LivingCitiesData[key]

		if city ~= nil and isZoneEnabled(city.planet) then
			for _, pNpc in ipairs(self:members(key)) do
				local oid = SceneObject(pNpc):getObjectID()
				local spot = self:slotOf(key, oid)

				print(string.format("LivingCities: %s | %s %s %s | state %d | %s slot %d | at %.1f %.1f cell %d", city.name,
					readStringData(npcKey(oid, "name")), readStringData(npcKey(oid, "species")), readStringData(npcKey(oid, "kit")),
					readData(npcKey(oid, "state")), spot ~= nil and spot.id or "-", readData(npcKey(oid, "slot")),
					SceneObject(pNpc):getPositionX(), SceneObject(pNpc):getPositionY(), SceneObject(pNpc):getParentID()))
			end
		end
	end
end

-- Development: spawn every template once (by the Mos Eisley starport), log any that fail, remove them again
function LivingCities:devTemplates()
	local x, y = 3560, -4760
	local spawned, failed = 0, 0

	for kit, bodies in pairs(LivingCitiesBodies) do
		for _, body in ipairs(bodies) do
			local template = "living_" .. kit .. "_" .. body.species .. "_" .. body.sex
			local pNpc = spawnMobile("tatooine", template, 0, x, getWorldFloor(x, y, "tatooine"), y, 0, 0)

			if pNpc == nil then
				failed = failed + 1
				print("LivingCities: template " .. template .. " did not spawn")
			else
				spawned = spawned + 1
				SceneObject(pNpc):destroyObjectFromWorld()
			end
		end
	end

	print("LivingCities: " .. spawned .. " templates spawned, " .. failed .. " failed")
end

-- One of each kit in a row near the Mos Eisley starport, for a look in game; they go after ten minutes
function LivingCities:lineup()
	local x, y = 3560, -4760
	local i = 0

	for _, kit in ipairs(self.kits) do
		for n = 1, 2 do
			local body = self:pickBody(kit.name)
			local template = "living_" .. kit.name .. "_" .. body.species .. "_" .. body.sex
			local px = x + i * 2

			local pNpc = spawnMobile("tatooine", template, 0, px, getWorldFloor(px, y, "tatooine"), y, 180, 0)

			if pNpc ~= nil then
				local names = LivingCitiesNames[body.species] or LivingCitiesNames
				local first, last = pickOne(names.first), pickOne(names.last)

				SceneObject(pNpc):setCustomObjectName(first .. " " .. last)
				CreatureObject(pNpc):setPvpStatusBitmask(0)
				AiAgent(pNpc):addObjectFlag(AI_STATIONARY)
				createEvent(600 * 1000, "LivingCities", "despawnLater", nil, tostring(SceneObject(pNpc):getObjectID()))
				print("LivingCities: lineup " .. first .. " " .. last .. " (" .. template .. ")")
			end

			i = i + 1
		end
	end
end

-- Development: send a walker from the arrival point to every slot of every city at once (on a test server with
-- AiAgentLoadTesting, so the AI runs with no players), then devProbeReport lists the slots nobody reached and how far
-- the floor height of the reached ones was off.
function LivingCities:devProbe()
	local sent = 0

	for _, key in ipairs(self.cities) do
		local city = LivingCitiesData[key]

		if city ~= nil and isZoneEnabled(city.planet) then
			for spotIndex, spot in ipairs(city.spots) do
				for slotIndex, slot in ipairs(spot.slots) do
					local pos = city.arrival
					local pProbe = spawnMobile(city.planet, "living_traveller_human_male", 0, pos.x, self:slotZ(city, pos), pos.y, 0, pos.cell or 0)

					if pProbe ~= nil then
						local oid = SceneObject(pProbe):getObjectID()
						local id = key .. ":" .. spotIndex .. ":" .. slotIndex

						writeStringData("lcp:probe:" .. oid, id)
						writeData("lcp:oid:" .. id, oid)
						deleteData("lcp:ok:" .. id)
						AiAgent(pProbe):addObjectFlag(AI_STATIONARY)
						CreatureObject(pProbe):setPvpStatusBitmask(0)
						createObserver(DESTINATIONREACHED, "LivingCities", "probeArrived", pProbe)
						AiAgent(pProbe):setNextPosition(slot.x, self:slotZ(city, slot), slot.y, slot.cell or 0)
						sent = sent + 1
					end
				end
			end
		end
	end

	print("LivingCities: " .. sent .. " probes walking; devProbeReport in a few minutes")
end

function LivingCities:probeArrived(pProbe)
	local oid = SceneObject(pProbe):getObjectID()
	local id = readStringData("lcp:probe:" .. oid)

	if id ~= "" then
		local a = unpackArgs(id)
		local city = LivingCitiesData[a[1]]
		local slot = city.spots[tonumber(a[2])].slots[tonumber(a[3])]
		local dz = math.abs(SceneObject(pProbe):getPositionZ() - self:slotZ(city, slot))

		writeData("lcp:ok:" .. id, 1 + math.floor(dz * 100))
	end

	return 0
end

function LivingCities:devProbeReport()
	for _, key in ipairs(self.cities) do
		local city = LivingCitiesData[key]

		if city ~= nil and isZoneEnabled(city.planet) then
			local total, reached = 0, 0

			for spotIndex, spot in ipairs(city.spots) do
				for slotIndex, slot in ipairs(spot.slots) do
					local id = key .. ":" .. spotIndex .. ":" .. slotIndex
					local ok = readData("lcp:ok:" .. id)
					local pProbe = getSceneObject(readData("lcp:oid:" .. id))

					total = total + 1

					if ok > 0 then
						reached = reached + 1

						if ok - 1 > 50 then
							print(string.format("LivingCities: probe %s %s slot %d reached, floor %.2f m off", city.name, spot.id, slotIndex, (ok - 1) / 100))
						end
					elseif pProbe ~= nil then
						print(string.format("LivingCities: probe %s %s slot %d NOT reached: at %.1f %.1f %.1f cell %d, target %.1f %.1f cell %d",
							city.name, spot.id, slotIndex, SceneObject(pProbe):getPositionX(), SceneObject(pProbe):getPositionY(),
							SceneObject(pProbe):getPositionZ(), SceneObject(pProbe):getParentID(), slot.x, slot.y, slot.cell or 0))
					end
				end
			end

			print("LivingCities: probe " .. city.name .. ": " .. reached .. " of " .. total .. " slots reached")
		end
	end
end

-- Development: remove the probes
function LivingCities:devProbeClear()
	for _, key in ipairs(self.cities) do
		local city = LivingCitiesData[key]

		if city ~= nil then
			for spotIndex, spot in ipairs(city.spots) do
				for slotIndex = 1, #spot.slots do
					local id = key .. ":" .. spotIndex .. ":" .. slotIndex
					local oid = readData("lcp:oid:" .. id)
					local pProbe = oid ~= 0 and getSceneObject(oid) or nil

					if pProbe ~= nil then
						SceneObject(pProbe):destroyObjectFromWorld()
					end

					deleteStringData("lcp:probe:" .. oid)
					deleteData("lcp:oid:" .. id)
				end
			end
		end
	end

	print("LivingCities: probes removed")
end
