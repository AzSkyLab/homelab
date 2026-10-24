-- Bot players (Phase 7): the crew's destroy missions, included from crew.lua and part of BotCrew. In group chat the
-- leader says "grab two destroy missions north" ("missions NE", "get missions east"; north, northeast, east,
-- southeast, south, southwest, west, northwest or N, NE, E, SE, S, SW, W, NW): every grouped crew bot walks to a
-- general mission terminal near the group (spread over them if there are several), refreshes the list up to five times
-- for the best-paying destroy missions that lie within 45 degrees of that direction (as seen from the terminal),
-- accepts them with Core3's own accept (Core3's limit of two applies), and says in group chat what it took. "Drop your
-- missions" aborts them. A mission's waypoint is copied into the leader's datapad as "<Bot>: <lair>" and goes when the
-- mission ends or the bot leaves the group (the C++ side, patches/bots/BotMission.*: botMissionSync).
--
-- One crew member answers the group's chat (as for orders) and sends the others the same errand; a bot that was
-- named does its own. The errand is a chain of events on the bot (missionStep) that carries the bot's generation and
-- the errand's number; its state lives in shared memory under bot:<oid>:crew:m*. The language model is not asked.
--
-- Console (the bot-on-bot tests of crew.lua; there is no client on the local server):
--   runLuaFunction BotCrew:devMissions:<first>            the mission terminals near a bot and the missions it holds
--   runLuaFunction BotCrew:devMissionAsk:<first>:<text>   a crew bot gets the errand a group chat line asks for ("_" is a space)
--   runLuaFunction BotCrew:devTp:<first>:<x>:<z>:<y>[:<cell>]   teleport a bot (world coordinates outdoors)
--   runLuaFunction BotCrew:devMissionRange:<first>:<m>    the terminals within <m> metres
--   runLuaFunction BotCrew:devWaypoints:<first>           the waypoints in a bot's datapad (the leader's, with the crew's lairs)

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function ckey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

local function put(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
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

local function num(s)
	return tonumber(s or "")
end

local function bot(name, ...)
	local fn = _G[name]

	if fn == nil then
		return nil
	end

	return fn(...)
end

local DIRECTIONS = {north = 0, northeast = 45, east = 90, southeast = 135, south = 180, southwest = 225, west = 270,
	northwest = 315}
local ABBREVIATIONS = {n = "north", ne = "northeast", e = "east", se = "southeast", s = "south", sw = "southwest",
	w = "west", nw = "northwest"}
local DROP_WORDS = {drop = true, abort = true, cancel = true, scrap = true, dump = true, abandon = true, forget = true}
local TAKE_WORDS = {grab = true, get = true, take = true, accept = true, fetch = true, pick = true, run = true, find = true,
	need = true, want = true, give = true}
local COUNT_WORDS = {"", "one", "two"}

BotCrew.missionCfg = {
	range = 30,       -- the terminal is within this of the bot (the leader is beside it)
	refreshes = 5,    -- lists it reads before it takes what it has
	arc = 45,         -- degrees either side of the asked direction
	max = 2,          -- Core3's limit
	stepMs = 1600,    -- between steps: the list's refresh cooldown is 1.4 s
	timeout = 120,    -- seconds for the whole errand
	retries = 4,      -- walks to the terminal before it gives up
	syncEvery = 5,    -- seconds between waypoint syncs
}

-- Mission talk

-- What a group chat line asks of the missions: nil, {kind = "drop"} or {kind = "take", dir = <degrees or nil>, name =
-- <direction name>, count = 1 or 2}. A take with no direction only counts when it says to take (grab, get, ...)
function BotCrew:missionRequest(text)
	local t = tostring(text or ""):lower():gsub("'", "")

	t = t:gsub("north[%s%-]+east", "northeast"):gsub("north[%s%-]+west", "northwest"):gsub("south[%s%-]+east", "southeast")
		:gsub("south[%s%-]+west", "southwest")

	local words, mission, drop, take, direction = {}, false, false, false, nil

	for word in t:gmatch("%a+") do
		if word:find("^mission") then
			mission = true
		elseif DROP_WORDS[word] then
			drop = true
		elseif TAKE_WORDS[word] then
			take = true
		end

		local name = DIRECTIONS[word] ~= nil and word or ABBREVIATIONS[word]

		if name ~= nil and direction == nil then
			direction = name
		end
	end

	if not mission then
		return nil
	end

	if drop then
		return {kind = "drop"}
	end

	local count = (t:find("%f[%a]one%f[%A]") or t:find("%f[%d]1%f[%D]")) and 1 or 2

	if direction ~= nil then
		return {kind = "take", dir = DIRECTIONS[direction], name = direction, count = count}
	end

	if take then
		return {kind = "take", count = count}
	end

	return nil
end

-- The destroy missions within arc degrees of dir (compass degrees), best paying first, at most need of them
function BotCrew:missionPick(missions, dir, need, arc)
	local picks = {}

	for _, m in ipairs(missions or {}) do
		local off = math.abs((((m.degrees or 0) - dir + 180) % 360) - 180)

		if off <= arc then
			table.insert(picks, m)
		end
	end

	table.sort(picks, function(a, b)
		if a.reward ~= b.reward then
			return a.reward > b.reward
		end

		return (a.distance or 0) < (b.distance or 0)
	end)

	while #picks > need do
		table.remove(picks)
	end

	return picks
end

-- "4,300"
local function credits(n)
	local s = tostring(math.floor(tonumber(n) or 0))

	while true do
		local r, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")

		s = r

		if k == 0 then
			break
		end
	end

	return s
end

local function distanceText(metres)
	if metres >= 1000 then
		return string.format("%.1f km", metres / 1000)
	end

	return math.floor((metres + 5) / 10) * 10 .. " m"
end

-- "womp rat lair 1.8 km out, 4,300"
function BotCrew:missionText(m)
	return string.format("%s %s out, %s", m.target or "lair", distanceText(m.distance or 0), credits(m.reward))
end

-- Hearing it (from onSpoken): true when the line was about missions and this bot dealt with it
function BotCrew:missionHeard(pBot, oid, pSpeaker, channel, text)
	if botMissionTerminals == nil then
		return false
	end

	local request = self:missionRequest(text)

	if request == nil then
		return false
	end

	local g = self:group(pBot)
	local speaker = g ~= nil and g.byOid[SceneObject(pSpeaker):getObjectID()] or nil

	if speaker == nil or not speaker.human then
		return false
	end

	local name = self:firstName(pSpeaker)
	local forGroup = readData(ckey(oid, "forGroup")) == 1

	put(ckey(oid, "forGroup"), 0)

	if request.kind == "take" and request.dir == nil then
		if forGroup then
			self:groupSay(pBot, oid, "missionWhere", name)
		end

		return true
	end

	self:missionOrder(pBot, oid, request, name)

	-- Said to the whole group (this bot answered for it): the others get the same errand
	if forGroup then
		for i, m in ipairs(g.crew) do
			if m.oid ~= oid then
				createEvent(500 * i, "BotCrew", "missionGroup", m.p,
					packArgs(readData(key(m.oid, "gen")), request.kind, request.name or "-", request.count or 2))
			end
		end
	end

	return true
end

function BotCrew:missionGroup(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) or not CreatureObject(pBot):isGrouped() then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local g = self:group(pBot)
	local pLeader = g ~= nil and g.humans[1] ~= nil and g.humans[1].p or nil

	self:missionOrder(pBot, oid, {kind = a[2], name = a[3] ~= "-" and a[3] or nil, dir = DIRECTIONS[a[3] or ""],
		count = num(a[4]) or 2}, pLeader ~= nil and self:firstName(pLeader) or "friend")
end

function BotCrew:missionOrder(pBot, oid, request, name)
	if request.kind == "drop" then
		self:missionDrop(pBot, oid, name)
	elseif request.dir ~= nil then
		self:missionStart(pBot, oid, request, name)
	end
end

-- The errand

function BotCrew:missionBusy(oid, now)
	return readStringData(ckey(oid, "mState")) == "walking" and now - readData(ckey(oid, "mStartAt")) < self.missionCfg.timeout
end

-- Clear the errand (crew.lua clear, leaving the group)
function BotCrew:missionClear(oid)
	put(ckey(oid, "mSeq"), readData(ckey(oid, "mSeq")) + 1)

	for _, field in ipairs({"mStartAt", "mDir", "mNeed", "mTerm", "mTx", "mTz", "mTy", "mCell", "mTries", "mRetry", "mSyncAt"}) do
		deleteData(ckey(oid, field))
	end

	deleteStringData(ckey(oid, "mState"))
	deleteStringData(ckey(oid, "mName"))
	deleteStringData(ckey(oid, "mDirName"))
end

function BotCrew:missionStart(pBot, oid, request, name)
	local creature = CreatureObject(pBot)

	if creature:isDead() or creature:isIncapacitated() or not creature:isGrouped() then
		return
	end

	if creature:isInCombat() then
		self:groupSay(pBot, oid, "missionCombat", name)
		return
	end

	local held = bot("botMissions", pBot) or {}
	local need = math.min(request.count or 2, self.missionCfg.max - #held)

	if need <= 0 then
		self:missionFull(pBot, oid, name, held)
		return
	end

	local terminals = bot("botMissionTerminals", pBot, self.missionCfg.range)

	if terminals == nil or #terminals == 0 then
		self:groupSay(pBot, oid, "missionNoTerminal", name)
		return
	end

	-- Several terminals: the crew spreads over them
	local g = self:group(pBot)
	local index = 1

	for i, m in ipairs(g ~= nil and g.crew or {}) do
		if m.oid == oid then
			index = i
		end
	end

	local t = terminals[((index - 1) % #terminals) + 1]
	local seq = readData(ckey(oid, "mSeq")) + 1

	put(ckey(oid, "mSeq"), seq)
	writeStringData(ckey(oid, "mState"), "walking")
	writeStringData(ckey(oid, "mName"), (tostring(name or "friend"):gsub("%%", "")))
	writeStringData(ckey(oid, "mDirName"), request.name)
	put(ckey(oid, "mStartAt"), os.time())
	put(ckey(oid, "mDir"), request.dir)
	put(ckey(oid, "mNeed"), need)
	put(ckey(oid, "mTerm"), t.oid)
	put(ckey(oid, "mTx"), t.x * 10)
	put(ckey(oid, "mTz"), t.z * 10)
	put(ckey(oid, "mTy"), t.y * 10)
	put(ckey(oid, "mCell"), t.cell)
	put(ckey(oid, "mTries"), 0)
	put(ckey(oid, "mRetry"), 0)

	print("BotJobs: " .. self:name(oid) .. " goes for " .. need .. " destroy mission(s) " .. request.name .. ", terminal " ..
		t.oid .. " " .. string.format("%.0f", t.distance) .. " m away")

	self:standUp(pBot, oid)
	bot("botMoveTo", pBot, t.x, t.z, t.y, t.cell, "run")
	createEvent(self.missionCfg.stepMs, "BotCrew", "missionStep", pBot, packArgs(readData(key(oid, "gen")), seq))
end

-- Already holding what it may: say which
function BotCrew:missionFull(pBot, oid, name, held)
	local parts = {}

	for _, m in ipairs(held) do
		table.insert(parts, self:missionText(m))
	end

	self:groupSay(pBot, oid, "missionFull", name, {list = table.concat(parts, "; ")})
end

function BotCrew:missionStep(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if num(a[2]) ~= readData(ckey(oid, "mSeq")) or readStringData(ckey(oid, "mState")) ~= "walking" then
		return
	end

	local cfg = self.missionCfg
	local now = os.time()
	local creature = CreatureObject(pBot)
	local name = readStringData(ckey(oid, "mName"))

	if not creature:isGrouped() or creature:isDead() or now - readData(ckey(oid, "mStartAt")) > cfg.timeout then
		self:missionEnd(pBot, oid, now)
		self:groupSay(pBot, oid, "missionLost", name)
		return
	end

	local again = function()
		createEvent(cfg.stepMs, "BotCrew", "missionStep", pBot, args)
	end

	if creature:isInCombat() or creature:isIncapacitated() then
		again()
		return
	end

	local terminal = readData(ckey(oid, "mTerm"))
	local missions, why = bot("botMissionList", pBot, terminal, true)

	if missions == nil then
		if why == "far" then
			-- Not there yet, or it stopped short: walk to it again (a few times)
			local move = bot("botMoveState", pBot) or {}

			if move.state == nil or move.state == "idle" then
				local retry = readData(ckey(oid, "mRetry")) + 1

				put(ckey(oid, "mRetry"), retry)

				if retry > cfg.retries then
					self:missionEnd(pBot, oid, now)
					self:groupSay(pBot, oid, "missionLost", name)
					return
				end

				self:standUp(pBot, oid)
				bot("botMoveTo", pBot, readData(ckey(oid, "mTx")) / 10, readData(ckey(oid, "mTz")) / 10,
					readData(ckey(oid, "mTy")) / 10, readData(ckey(oid, "mCell")), "run")
			end
		elseif why ~= "wait" then
			self:missionEnd(pBot, oid, now)
			self:groupSay(pBot, oid, "missionLost", name)
			return
		end

		again()
		return
	end

	local tries = readData(ckey(oid, "mTries")) + 1
	local need = readData(ckey(oid, "mNeed"))
	local picks = self:missionPick(missions, readData(ckey(oid, "mDir")), need, cfg.arc)

	put(ckey(oid, "mTries"), tries)

	if #picks >= need or tries >= cfg.refreshes then
		self:missionTake(pBot, oid, terminal, picks, now)
		return
	end

	again()
end

function BotCrew:missionTake(pBot, oid, terminal, picks, now)
	local taken = {}
	local name = readStringData(ckey(oid, "mName"))
	local dirName = readStringData(ckey(oid, "mDirName"))

	for _, m in ipairs(picks) do
		local ok, why = bot("botMissionAccept", pBot, terminal, m.oid)

		if ok then
			table.insert(taken, m)
		elseif why == "full" then
			break
		end
	end

	local tries = readData(ckey(oid, "mTries"))

	self:missionEnd(pBot, oid, now)

	local g = self:group(pBot)
	local pLeader = g ~= nil and g.leader ~= nil and g.leader.p or nil

	if pLeader ~= nil then
		bot("botMissionSync", pBot, pLeader)
	end

	if #taken == 0 then
		self:groupSay(pBot, oid, "missionNone", name, {dir = dirName, tries = tostring(tries)})
		return
	end

	local parts = {}

	for _, m in ipairs(taken) do
		table.insert(parts, self:missionText(m))
	end

	local word = COUNT_WORDS[#taken + 1] or tostring(#taken)

	print("BotJobs: " .. self:name(oid) .. " took " .. #taken .. " mission(s) " .. dirName .. ": " .. table.concat(parts, "; "))
	self:groupSay(pBot, oid, "missionTook", name, {dir = dirName, count = word, Count = word:sub(1, 1):upper() .. word:sub(2),
		lairs = #taken == 1 and "lair" or "lairs", list = table.concat(parts, "; ")})
end

-- The errand is over: back to following
function BotCrew:missionEnd(pBot, oid, now)
	writeStringData(ckey(oid, "mState"), "idle")
	put(ckey(oid, "mSeq"), readData(ckey(oid, "mSeq")) + 1)
	deleteData(ckey(oid, "followAt"))
	self:stopMoving(pBot)
end

function BotCrew:missionDrop(pBot, oid, name)
	local aborted, why = bot("botMissionAbort", pBot)

	aborted = aborted or 0

	-- An errand on its way is over too
	if readStringData(ckey(oid, "mState")) == "walking" then
		self:missionEnd(pBot, oid, os.time())
	end

	if aborted == 0 and why == "combat" then
		self:groupSay(pBot, oid, "missionCombat", name)
	elseif aborted == 0 then
		self:groupSay(pBot, oid, "missionNoneHeld", name)
	else
		self:groupSay(pBot, oid, "missionDropped", name, {count = tostring(aborted)})
	end

	local g = self:group(pBot)

	if g ~= nil and g.leader ~= nil then
		bot("botMissionSync", pBot, g.leader.p)
	end
end

-- From outOfCombat: keep the leader's waypoints in step with the missions the bot holds. true while it is on an
-- errand (it doesn't follow then)
function BotCrew:missionTick(pBot, oid, pLeader, now)
	if self:missionBusy(oid, now) then
		return true
	end

	if botMissionSync ~= nil and now - readData(ckey(oid, "mSyncAt")) >= self.missionCfg.syncEvery then
		put(ckey(oid, "mSyncAt"), now)
		bot("botMissionSync", pBot, pLeader)
	end

	return false
end

-- Out of the group: its waypoints leave the leader's datapad, an errand on its way ends
function BotCrew:missionLeft(pBot, oid)
	if readStringData(ckey(oid, "mState")) == "walking" then
		put(ckey(oid, "mSeq"), readData(ckey(oid, "mSeq")) + 1)
		writeStringData(ckey(oid, "mState"), "idle")
	end

	deleteData(ckey(oid, "mSyncAt"))
	bot("botMissionSync", pBot)
end

-- Console

function BotCrew:devTp(first, x, z, y, cell)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	createEvent(10, "BotCrew", "devTpNow", pBot, packArgs(x, z, y, cell or 0))
end

function BotCrew:devTpNow(pBot, args)
	local a = unpackArgs(args)

	SceneObject(pBot):teleport(tonumber(a[1]), tonumber(a[2]), tonumber(a[3]), tonumber(a[4]))
	print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " teleported to " .. args)
end

function BotCrew:devWaypoints(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil
	local list = pBot ~= nil and botWaypoints ~= nil and botWaypoints(pBot) or nil

	if list == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	print("BotCrew: " .. first .. " has " .. #list .. " waypoint(s)")

	for _, w in ipairs(list) do
		print(string.format("BotCrew:   waypoint %d '%s' at %.0f %.0f active %s: %s", w.oid, w.name, w.x, w.y, tostring(w.active),
			w.description))
	end
end

function BotCrew:devMissionRange(first, metres)
	self.missionCfg.range = tonumber(metres) or self.missionCfg.range
	self:devMissions(first)
end

function BotCrew:devMissions(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil

	if pBot == nil or botMissionTerminals == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	local terminals, why = botMissionTerminals(pBot, self.missionCfg.range)

	print(string.format("BotCrew: %s is at %.1f %.1f %.1f cell %d (%s)", first, SceneObject(pBot):getWorldPositionX(),
		SceneObject(pBot):getWorldPositionZ(), SceneObject(pBot):getWorldPositionY(), SceneObject(pBot):getParentID(),
		SceneObject(pBot):getZoneName()))
	print("BotCrew: " .. first .. " mission terminals: " .. (terminals and #terminals or ("none: " .. tostring(why))))

	for _, t in ipairs(terminals or {}) do
		print(string.format("BotCrew:   terminal %d %.1f m at %.1f %.1f %.1f cell %d", t.oid, t.distance, t.x, t.z, t.y, t.cell))
	end

	for _, m in ipairs(botMissions(pBot) or {}) do
		print(string.format("BotCrew:   holds %d: %s, %s %d deg, %.0f m, %d credits", m.oid, m.target, m.direction, m.degrees,
			m.distance, m.reward))
	end
end

function BotCrew:devMissionAsk(first, text)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil
	local request = self:missionRequest((text or ""):gsub("_", " "))

	if pBot == nil or request == nil then
		print("BotCrew: usage devMissionAsk:<first>:<text with _ for spaces> (a missions line); got " .. tostring(text))
		return
	end

	createEvent(10, "BotCrew", "devMissionNow", pBot, packArgs(request.kind, request.name or "-", request.count or 2))
end

function BotCrew:devMissionNow(pBot, args)
	local a = unpackArgs(args)

	self:missionOrder(pBot, SceneObject(pBot):getObjectID(), {kind = a[1], name = a[2] ~= "-" and a[2] or nil,
		dir = DIRECTIONS[a[2] or ""], count = num(a[3]) or 2}, "Tester")
end
