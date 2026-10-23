-- Living Cities simulator: runs the real screenplays (custom_scripts/screenplays/living_cities/) against a mock of
-- the Core3 Lua API, with simulated time, and checks the crowd's invariants. No server needed.
--
--   lua living_cities_sim.lua [custom_scripts dir] [scenario ...]
--
-- Scenarios: evening (players everywhere for 3 h), night (03:00, nobody near), midnight (23:00 to 03:00, nobody near),
-- watchleave (players watch an hour, then leave for three), clock (a day, players near), restart
-- (restart twice mid-evening), stuck (some walks never arrive), talk (Phase 2 requests and replies, bridge faked).
-- Exits non-zero if an invariant broke or a Lua error happened. Plain Lua 5.3/5.4.

local scriptDir = arg[1] or "../../custom_scripts"
local wanted = {}
for i = 2, #arg do
	wanted[arg[i]] = true
end

-- Simulated clock

local sim = {now = 1792800000, hourOffset = 0, events = {}, seq = 0, errors = {}, log = {}}

local function simHour()
	return math.floor(((sim.now + sim.hourOffset) % 86400) / 3600)
end

os.time = function() return sim.now end
os.date = function(fmt) return {hour = simHour()} end

-- Shared memory (readData/writeData are screenplay.lua helpers over these in Core3)

local shared, sharedStr = {}, {}
function readData(k) return shared[k] or 0 end
function writeData(k, v) shared[k] = math.tointeger(v) or math.floor(v) end
function deleteData(k) shared[k] = nil end
function readStringData(k) return sharedStr[k] or "" end
function writeStringData(k, v) sharedStr[k] = tostring(v) end
function deleteStringData(k) sharedStr[k] = nil end

-- World objects

local objects, nextOid, players = {}, 100000, {}
local spawned, destroyed = 0, 0
local stats = {chat = 0, greet = 0, anim = 0, spawn = 0}
local walkOptions = {stuckChance = 0, speed = 1.4}

local Obj = {}
Obj.__index = Obj

local function newObject(fields)
	nextOid = nextOid + 1
	local o = setmetatable(fields, Obj)
	o.oid = nextOid
	o.observers = {}
	objects[o.oid] = o
	return o
end

function Obj:getObjectID() return self.oid end
function Obj:getZoneName() return self.inWorld and self.planet or "" end
function Obj:setCustomObjectName(n) self.name = n end
function Obj:updateDirection(a) self.heading = a end
function Obj:faceObject(o) self.facing = o.oid end
function Obj:getDistanceTo(o)
	local x, y = self:now()
	local ox, oy = o:now()
	return math.sqrt((x - ox) ^ 2 + (y - oy) ^ 2)
end
function Obj:getPlayersInRange(r)
	local out = {}
	for _, p in ipairs(players) do
		if p.planet == self.planet and (p.everywhere or self:getDistanceTo(p) <= r) then
			table.insert(out, p)
		end
	end
	return out
end
function Obj:teleport(x, z, y, cell) self.walk = nil; self.x, self.z, self.y, self.cell = x, z, y, cell; self.teleports = (self.teleports or 0) + 1 end
function Obj:destroyObjectFromWorld()
	if self.inWorld then
		self.inWorld = false
		destroyed = destroyed + 1
	end
end
-- Where a walking NPC is now: part way along its walk (same cell), or across the door half way through
function Obj:now()
	local w = self.walk
	if w == nil then
		return self.x, self.y, self.cell
	end
	local t = math.min(1, math.max(0, (sim.now * 1000 + (sim.subMs or 0) - w.t0) / math.max(1, w.t1 - w.t0)))
	if (w.cell0 or 0) == (w.cell1 or 0) then
		return w.x0 + (w.x1 - w.x0) * t, w.y0 + (w.y1 - w.y0) * t, w.cell0
	end
	if t < 0.5 then
		return w.x0, w.y0, w.cell0
	end
	return w.x1, w.y1, w.cell1
end
function Obj:getPositionX() local x = self:now() return x end
function Obj:getPositionY() local _, y = self:now() return y end
function Obj:getPositionZ() return self.z end
function Obj:getParentID() local _, _, c = self:now() return c end
function Obj:isPlayerCreature() return self.isPlayer == true end
function Obj:setPvpStatusBitmask(b) self.pvp = b end
function Obj:setMoodString(m) self.mood = m end
function Obj:doAnimation(a) stats.anim = stats.anim + 1 end
function Obj:getTargetID() return self.target or 0 end
function Obj:getFirstName() return self.first or "Player" end
function Obj:addObjectFlag(f) end
function Obj:setHomeLocation(x, z, y, cell) self.home = {x, z, y, cell} end
function Obj:getNumberOfPlayersInRange() return #self:getPlayersInRange(128) end
-- Like Core3: setNextPosition puts the point in FRONT of any older ones (patrolPoints.add(0, point)) and the agent
-- keeps walking its queue, reporting DESTINATIONREACHED at each point; clearPatrolPoints empties it
function Obj:setNextPosition(x, z, y, cell)
	self.patrol = self.patrol or {}
	table.insert(self.patrol, 1, {x, z, y, cell})
	self:moveOn()
end
function Obj:settle()
	if self.walk ~= nil then
		self.x, self.y, self.cell = self:now()
		self.walk = nil
	end
end
function Obj:clearPatrolPoints()
	self:settle()
	self.patrol = {}
	self.walkId = (self.walkId or 0) + 1
end
function Obj:clearCurrentPath() end
function Obj:moveOn()
	self:settle()
	self.walkId = (self.walkId or 0) + 1
	local id = self.walkId
	local point = self.patrol[1]
	if point == nil then
		return
	end
	local x, z, y, cell = point[1], point[2], point[3], point[4]
	-- Cell positions are cell-local, so a walk into, out of or between buildings counts as a nominal 60 m
	local dist = 60
	if (cell or 0) == 0 and (self.cell or 0) == 0 then
		dist = math.sqrt((self.x - x) ^ 2 + (self.y - y) ^ 2)
	end
	if math.random() < walkOptions.stuckChance then
		return
	end
	local awake = #self:getPlayersInRange(128) > 0 or readData("lc:awake") == 1
	if not awake then
		-- Core3 stops the AI with nobody near: the walk waits
		return
	end
	local ms = math.floor(dist / walkOptions.speed * 1000) + 500
	local nowMs = sim.now * 1000 + (sim.subMs or 0)
	self.walk = {x0 = self.x, y0 = self.y, cell0 = self.cell, x1 = x, y1 = y, cell1 = cell, t0 = nowMs, t1 = nowMs + ms}
	local function finish()
		if not (self.inWorld and self.walkId == id) then
			return
		end
		-- Core3 pauses the AI when every player has gone: the walk freezes until someone comes back
		if #self:getPlayersInRange(128) == 0 and readData("lc:awake") ~= 1 then
			if self.walk ~= nil then
				self.walk.t0, self.walk.t1 = self.walk.t0 + 5000, self.walk.t1 + 5000
			end
			sim.schedule(5000, finish)
			return
		end
		do
			self.walk = nil
			self.x, self.z, self.y, self.cell = x, z, y, cell
			table.remove(self.patrol, 1)
			self:fire("DESTINATIONREACHED")
			if self.walkId == id then
				self:moveOn()
			end
		end
	end
	sim.schedule(ms, finish)
end
function Obj:fire(event, a1, a2)
	for _, ob in ipairs(self.observers) do
		if ob.event == event then
			sim.call(ob.play, ob.fn, self, a1, a2)
		end
	end
end

function SceneObject(p) return p end
function CreatureObject(p) return p end
function AiAgent(p) return p end

-- Scheduling and calls

-- A binary heap of events, earliest first (ties in scheduling order)
local function before(a, b)
	return a.at < b.at or (a.at == b.at and a.seq < b.seq)
end

local function heapPush(h, e)
	table.insert(h, e)
	local i = #h
	while i > 1 do
		local parent = i // 2
		if not before(h[i], h[parent]) then
			break
		end
		h[i], h[parent] = h[parent], h[i]
		i = parent
	end
end

local function heapPop(h)
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, smallest = i * 2, i * 2 + 1, i
			if l <= #h and before(h[l], h[smallest]) then smallest = l end
			if r <= #h and before(h[r], h[smallest]) then smallest = r end
			if smallest == i then break end
			h[i], h[smallest] = h[smallest], h[i]
			i = smallest
		end
	end
	return top
end

function sim.schedule(ms, fn)
	sim.seq = sim.seq + 1
	heapPush(sim.events, {at = sim.now * 1000 + (sim.subMs or 0) + math.max(math.floor(ms), 0), seq = sim.seq, fn = fn})
end

function sim.call(play, fn, ...)
	local p = _G[play]
	local args = table.pack(...)
	local ok, err = xpcall(function() return p[fn](p, table.unpack(args, 1, args.n)) end, debug.traceback)
	if not ok then
		table.insert(sim.errors, play .. ":" .. fn .. ": " .. tostring(err))
	end
	return err
end

function sim.run(seconds)
	local stop = (sim.now + seconds) * 1000
	while true do
		local e = sim.events[1]
		if e == nil or e.at > stop then
			break
		end
		heapPop(sim.events)
		sim.now = e.at // 1000
		sim.subMs = e.at % 1000
		e.fn()
		if sim.tick then
			sim.tick()
		end
	end
	sim.now = stop // 1000
	sim.subMs = 0
end

-- The Core3 Lua API the screenplays use

AI_STATIONARY = 1
DESTINATIONREACHED = "DESTINATIONREACHED"
SPATIALCHAT = "SPATIALCHAT"

function createEvent(ms, play, fn, obj, args)
	sim.schedule(ms, function() sim.call(play, fn, obj, args) end)
end

function createObserver(event, play, fn, obj)
	table.insert(obj.observers, {event = event, play = play, fn = fn})
end

function spawnMobile(planet, template, respawn, x, z, y, heading, cell)
	assert(type(template) == "string" and template:match("^living_%a+_%a+_%a+$"), "bad template " .. tostring(template))
	assert(type(x) == "number" and type(z) == "number" and type(y) == "number", "bad position")
	spawned = spawned + 1
	stats.spawn = stats.spawn + 1
	return newObject({planet = planet, template = template, x = x, z = z, y = y, cell = cell, inWorld = true})
end

function getSceneObject(oid)
	return objects[oid]
end

function getRandomNumber(a, b)
	if b == nil then
		return math.random(1, a)
	end
	return math.random(a, b)
end

local syllables = {"ka", "ri", "von", "tel", "mar", "dos", "an", "eth", "lo", "zi", "bre", "nor", "sha", "vek", "ul", "ti"}
function makeCreatureName()
	local n = ""
	for i = 1, math.random(2, 3) do
		n = n .. syllables[math.random(#syllables)]
	end
	return n
end

function getWorldFloor(x, y, planet) return 5.0 end
function isZoneEnabled(planet) return true end
function getTimestampMilli() return sim.now * 1000 + (sim.subMs or 0) end
function getChatMessage(m) return m.text end
function spatialChat(p, text)
	assert(type(text) == "string" and #text > 0, "empty chat line")
	assert(not text:find("{city}") and not text:find("{planet}"), "unfilled placeholder: " .. text)
	stats.chat = stats.chat + 1
	if sim.chatLog then
		table.insert(sim.chatLog, (p.name or "?") .. ": " .. text)
	end
end

local screenplayBase = scriptDir .. "/screenplays/"
function includeFile(path)
	local file = path:gsub("^%.%./custom_scripts/", scriptDir .. "/")
	if file == path then
		file = screenplayBase .. path
	end
	local chunk, err = loadfile(file)
	if chunk == nil then
		error("includeFile " .. path .. ": " .. tostring(err))
	end
	chunk()
end

ScreenPlay = {}
function ScreenPlay:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end
function registerScreenPlay(name, start) sim.registered = sim.registered or {}; table.insert(sim.registered, name) end

local realPrint = print
print = function(...)
	local line = table.concat({...}, " ")
	table.insert(sim.log, line)
	if os.getenv("SIM_VERBOSE") then
		realPrint(line)
	end
end

-- Load the screenplays the way Core3 does
includeFile("../custom_scripts/screenplays/screenplays.lua")

-- Invariants

local failures = {}
local function fail(msg)
	table.insert(failures, msg)
end

local function checkCity(key, label)
	local city = LivingCitiesData[key]
	local members = LivingCities:members(key)
	local seen, names, slotOwner = {}, {}, {}

	if #members > LivingCities.maxCrowd then
		fail(label .. ": " .. #members .. " members over the cap")
	end

	for _, p in ipairs(members) do
		local oid = p:getObjectID()
		if seen[oid] then
			fail(label .. ": " .. oid .. " in two seats")
		end
		seen[oid] = true
		local first = readStringData("lc:npc:" .. oid .. ":first")
		if names[first] then
			fail(label .. ": first name " .. first .. " twice")
		end
		names[first] = true
		local spot, slot = readData("lc:npc:" .. oid .. ":spot"), readData("lc:npc:" .. oid .. ":slot")
		if spot ~= 0 then
			local k = spot .. ":" .. slot
			if slotOwner[k] then
				fail(label .. ": slot " .. k .. " held by two NPCs")
			end
			slotOwner[k] = oid
			if readData("lc:" .. key .. ":slot:" .. k) ~= oid then
				fail(label .. ": slot " .. k .. " record doesn't point back at " .. oid)
			end
		end
		if not p.inWorld then
			fail(label .. ": member " .. oid .. " not in the world")
		end
		-- A lingering NPC stands at its slot (a leftover Core3 move queue would walk it elsewhere)
		if spot ~= 0 and readData("lc:npc:" .. oid .. ":state") == 2 then
			local s = city.spots[spot].slots[slot]
			local px, py, pc = p:now()
			local d = math.sqrt((px - s.x) ^ 2 + (py - s.y) ^ 2)
			if (pc or 0) ~= (s.cell or 0) or d > 2.5 then
				fail(string.format("%s: %d lingers %.1f m from its slot %d:%d (cell %s, slot cell %s)", label, oid, d, spot, slot,
					tostring(p.cell), tostring(s.cell)))
			end
		end
	end

	-- Every slot record points at a live member
	for spotIndex, spot in ipairs(city.spots) do
		for slotIndex = 1, #spot.slots do
			local oid = readData("lc:" .. key .. ":slot:" .. spotIndex .. ":" .. slotIndex)
			if oid ~= 0 and not seen[oid] then
				fail(label .. ": slot " .. spotIndex .. ":" .. slotIndex .. " held by a gone NPC " .. oid)
			end
		end
	end

	return #members
end

local function inWorldCount(planet)
	local n = 0
	for _, o in pairs(objects) do
		if o.inWorld and not o.isPlayer and o.planet == planet then
			n = n + 1
		end
	end
	return n
end

local function checkAll(label)
	for _, key in ipairs(LivingCities.cities) do
		local members = checkCity(key, label .. " " .. key)
		local planet = LivingCitiesData[key].planet
		if inWorldCount(planet) ~= members then
			fail(label .. " " .. key .. ": " .. inWorldCount(planet) .. " NPCs in the world but " .. members .. " members (leak)")
		end
	end
end

local function reset()
	for k in pairs(shared) do shared[k] = nil end
	for k in pairs(sharedStr) do sharedStr[k] = nil end
	for k in pairs(objects) do objects[k] = nil end
	sim.events, sim.errors, sim.log = {}, {}, {}
	players = {}
	stats = {chat = 0, greet = 0, anim = 0, spawn = 0}
	walkOptions.stuckChance = 0
	spawned, destroyed = 0, 0
end

local function setHour(h)
	sim.hourOffset = 0
	sim.hourOffset = ((h - simHour()) % 24) * 3600
end

local function addPlayerEverywhere(planetList)
	for _, planet in ipairs(planetList) do
		local p = newObject({planet = planet, x = 0, y = 0, z = 0, cell = 0, inWorld = true, isPlayer = true, everywhere = true})
		table.insert(players, p)
	end
end

local function allPlanets()
	local out = {}
	for _, key in ipairs(LivingCities.cities) do
		table.insert(out, LivingCitiesData[key].planet)
	end
	return out
end

local function report(name)
	local line = string.format("%-8s spawned %d, destroyed %d, chat lines %d, animations %d", name, spawned, destroyed, stats.chat, stats.anim)
	realPrint(line)
	for _, key in ipairs(LivingCities.cities) do
		realPrint(string.format("         %s: %d members, target %d; arrived %d, left %d, rerouted %d, stuck %d", key, #LivingCities:members(key),
			LivingCities:target(key), readData("lc:" .. key .. ":stat:arrived"), readData("lc:" .. key .. ":stat:left"),
			readData("lc:" .. key .. ":stat:rerouted"), readData("lc:" .. key .. ":stat:stuck")))
	end
end

-- Scenarios

local scenarios = {}

function scenarios.evening()
	setHour(18)
	addPlayerEverywhere(allPlanets())
	LivingCities:start()
	checkAll("evening start")
	sim.tick = nil
	for i = 1, 36 do
		sim.run(300)
		checkAll("evening +" .. (i * 5) .. "m")
	end
	for _, key in ipairs(LivingCities.cities) do
		local n = #LivingCities:members(key)
		local target = LivingCities:target(key)
		if math.abs(n - target) > 3 then
			fail("evening " .. key .. ": " .. n .. " members, target " .. target)
		end
		if readData("lc:" .. key .. ":stat:left") < 10 then
			fail("evening " .. key .. ": only " .. readData("lc:" .. key .. ":stat:left") .. " left in 3 h (turnover)")
		end
	end
	-- About one line per NPC every 4.5 minutes with a player near: 75 NPCs over 3 h ~ 3000
	local expected = 75 * 180 / 4.5
	if stats.chat < expected * 0.4 or stats.chat > expected * 1.6 then
		fail(string.format("evening: %d chat lines, expected about %d", stats.chat, expected))
	end
	report("evening")
end

function scenarios.night()
	setHour(3)
	LivingCities:start()
	sim.run(2 * 3600)
	checkAll("night")
	for _, key in ipairs(LivingCities.cities) do
		local n, target = #LivingCities:members(key), LivingCities:target(key)
		if math.abs(n - target) > 1 then
			fail("night " .. key .. ": " .. n .. " members, target " .. target)
		end
	end
	if stats.chat > 0 then
		fail("night: " .. stats.chat .. " chat lines with nobody near")
	end
	report("night")
end

-- Players watch for an hour, then all leave: NPCs sent away while watched must not keep their seats forever
function scenarios.watchleave()
	setHour(18)
	addPlayerEverywhere(allPlanets())
	LivingCities:start()
	sim.run(3600)
	players = {}
	sim.run(3 * 3600)
	checkAll("watchleave")
	for _, key in ipairs(LivingCities.cities) do
		local leaving = 0
		for _, p in ipairs(LivingCities:members(key)) do
			if readData("lc:npc:" .. p:getObjectID() .. ":state") == 3 then
				leaving = leaving + 1
			end
		end
		local n, target = #LivingCities:members(key), LivingCities:target(key)
		if leaving > 0 then
			fail("watchleave " .. key .. ": " .. leaving .. " NPCs still leaving 3 h after the players went")
		end
		if n > target + 2 then
			fail("watchleave " .. key .. ": " .. n .. " members, target " .. target)
		end
	end
	report("watchleave")
end

-- The crowd thins after midnight even with nobody around to see it (Core3 pauses AI with no player near)
function scenarios.midnight()
	setHour(23)
	LivingCities:start()
	sim.run(4 * 3600)
	checkAll("midnight")
	for _, key in ipairs(LivingCities.cities) do
		local n, target = #LivingCities:members(key), LivingCities:target(key)
		if n > target + 2 then
			fail("midnight " .. key .. ": " .. n .. " members at 03:00, target " .. target)
		end
	end
	report("midnight")
end

function scenarios.clock()
	setHour(0)
	addPlayerEverywhere(allPlanets())
	LivingCities:start()
	local seen = {}
	for h = 1, 24 do
		sim.run(3600)
		checkAll("clock " .. h .. "h")
		seen[simHour()] = #LivingCities:members("mos_eisley")
	end
	if not (seen[4] < seen[12] and seen[12] < seen[21]) then
		fail(string.format("clock: crowd at 04:00 %s, 12:00 %s, 21:00 %s should rise", tostring(seen[4]), tostring(seen[12]), tostring(seen[21])))
	end
	report("clock")
end

function scenarios.restart()
	setHour(20)
	addPlayerEverywhere(allPlanets())
	LivingCities:start()
	sim.run(1800)
	LivingCities:restart()
	LivingCities:restart()
	sim.run(1800)
	checkAll("restart")
	for _, key in ipairs(LivingCities.cities) do
		local n, target = #LivingCities:members(key), LivingCities:target(key)
		if math.abs(n - target) > 3 then
			fail("restart " .. key .. ": " .. n .. " members, target " .. target)
		end
	end
	report("restart")
end

function scenarios.stuck()
	setHour(20)
	addPlayerEverywhere(allPlanets())
	walkOptions.stuckChance = 0.1
	LivingCities:start()
	sim.run(2 * 3600)
	checkAll("stuck")
	local stuck = 0
	for _, key in ipairs(LivingCities.cities) do
		stuck = stuck + readData("lc:" .. key .. ":stat:stuck")
		local n, target = #LivingCities:members(key), LivingCities:target(key)
		if math.abs(n - target) > 4 then
			fail("stuck " .. key .. ": " .. n .. " members, target " .. target)
		end
	end
	if stuck == 0 then
		fail("stuck: the walk check never caught a stuck walk")
	end
	local rerouted = 0
	for _, key in ipairs(LivingCities.cities) do
		rerouted = rerouted + readData("lc:" .. key .. ":stat:rerouted")
	end
	if rerouted == 0 then
		fail("stuck: no walk was rerouted by the hub")
	end
	report("stuck")
end

function scenarios.talk()
	if LivingTalk == nil then
		realPrint("talk     skipped (no LivingTalk)")
		return
	end
	local dir = os.getenv("SIM_TALK_DIR")
	if dir == nil then
		realPrint("talk     skipped (set SIM_TALK_DIR to an empty directory with req/ and rep/)")
		return
	end
	LivingTalk.dir = dir
	-- Only replies in the chat log: no ambient chatter or greetings during this scenario
	local saved = {LivingCities.chatterEvery, LivingCities.greetChance}
	LivingCities.chatterEvery, LivingCities.greetChance = 1e12, 0
	setHour(20)
	LivingCities:start()
	local key = "mos_eisley"
	local members = LivingCities:members(key)
	local npc = members[1]
	local other = members[2]
	local player = newObject({planet = npc.planet, x = npc.x + 2, y = npc.y, z = 5, cell = 0, inWorld = true, isPlayer = true, first = "Cameren"})
	table.insert(players, player)
	sim.chatLog = {}

	local function say(text, target)
		player.target = target and target:getObjectID() or 0
		npc:fire("SPATIALCHAT", {text = text}, player:getObjectID())
		other:fire("SPATIALCHAT", {text = text}, player:getObjectID())
	end

	-- Fake bridge: a heartbeat, and an answer to every request after 2 s
	local function heartbeat()
		local f = io.open(dir .. "/alive", "w")
		f:write(tostring(sim.now) .. "\n")
		f:close()
	end
	local function bridgeTick()
		heartbeat()
		local handle = io.popen('ls "' .. dir .. '/req" 2>/dev/null')
		for name in handle:lines() do
			if name:match("%.json$") then
				local path = dir .. "/req/" .. name
				local f = io.open(path)
				local body = f:read("a")
				f:close()
				os.remove(path)
				local rid = body:match('"id":"([^"]+)"')
				local kind = body:match('"type":"(%a+)"')
				if kind == "say" and rid then
					sim.schedule(2000, function()
						local out = io.open(dir .. "/rep/" .. rid .. ".txt", "w")
						out:write("ok\nhappy\nThe bank's across the square, friend.\n")
						out:close()
					end)
				end
			end
		end
		handle:close()
	end
	sim.tick = nil

	heartbeat()
	local before = #sim.chatLog
	say("hello there", npc)
	for i = 1, 6 do bridgeTick(); sim.run(1) end
	local answered = #sim.chatLog - before
	if answered ~= 1 then
		fail("talk: targeted line got " .. answered .. " replies")
	end
	if readData("lc:npc:" .. npc:getObjectID() .. ":state") ~= 4 then
		fail("talk: NPC not in the talking state")
	end

	-- Untargeted, unnamed: nobody answers
	before = #sim.chatLog
	sim.run(4)
	say("nice weather today", nil)
	for i = 1, 6 do bridgeTick(); sim.run(1) end
	if #sim.chatLog ~= before then
		fail("talk: an unaddressed line got a reply")
	end

	-- By name, untargeted
	before = #sim.chatLog
	sim.run(4)
	local first = readStringData("lc:npc:" .. other:getObjectID() .. ":first")
	say("hey " .. first:lower() .. ", where's the bank?", nil)
	for i = 1, 6 do bridgeTick(); sim.run(1) end
	if #sim.chatLog - before ~= 1 then
		fail("talk: named line got " .. (#sim.chatLog - before) .. " replies")
	end

	-- No bridge answer: one fallback after the deadline
	before = #sim.chatLog
	sim.run(4)
	heartbeat()
	say("are you there?", npc)
	sim.run(LivingTalk.deadline + 2)
	if #sim.chatLog - before ~= 1 then
		fail("talk: timeout gave " .. (#sim.chatLog - before) .. " lines, expected one fallback")
	end

	-- No bridge at all (stale heartbeat): no request written, no reply, no fallback
	sim.run(LivingTalk.quietAfterTimeout + 5)
	os.remove(dir .. "/alive")
	before = #sim.chatLog
	say("anyone home?", npc)
	sim.run(LivingTalk.deadline + 2)
	if #sim.chatLog ~= before then
		fail("talk: with no bridge an addressed line still got " .. (#sim.chatLog - before) .. " lines")
	end

	-- Back to errands after the hold
	sim.run(LivingTalk.holdSeconds + 40)
	if readData("lc:npc:" .. npc:getObjectID() .. ":state") == 4 then
		fail("talk: NPC still talking after the hold")
	end
	checkAll("talk")
	realPrint(string.format("talk     %d lines in the chat log", #sim.chatLog))
	for i = 1, math.min(#sim.chatLog, 8) do
		realPrint("         " .. sim.chatLog[i])
	end
	sim.chatLog = nil
	LivingCities.chatterEvery, LivingCities.greetChance = saved[1], saved[2]
end

local order = {"evening", "night", "midnight", "watchleave", "clock", "restart", "stuck", "talk"}
math.randomseed(tonumber(os.getenv("SIM_SEED") or "") or 42)

for _, name in ipairs(order) do
	if next(wanted) == nil or wanted[name] then
		reset()
		scenarios[name]()
		for _, e in ipairs(sim.errors) do
			fail(name .. ": Lua error: " .. e)
		end
	end
end

for _, line in ipairs(sim.log) do
	if line:find("could not spawn") then
		fail("log: " .. line)
	end
end

if #failures > 0 then
	realPrint("\nFAILED (" .. #failures .. "):")
	for i = 1, math.min(#failures, 30) do
		realPrint("  " .. failures[i])
	end
	os.exit(1)
end

realPrint("\nall invariants held")
