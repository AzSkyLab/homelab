-- Bot players (Phase 7): the crew's destroy missions, included from crew.lua and part of BotCrew. In group chat the
-- leader says "grab two destroy missions north" ("missions NE", "get missions east"; north, northeast, east,
-- southeast, south, southwest, west, northwest or N, NE, E, SE, S, SW, W, NW): every grouped crew bot walks to a
-- general mission terminal near the group (spread over them if there are several), refreshes the list up to five times
-- for the best-paying destroy missions that lie within 45 degrees of that direction (as seen from the terminal),
-- accepts them with Core3's own accept (Core3's limit of two applies), and says in group chat what it took. "Drop your
-- missions" aborts them. A mission's waypoint is copied into the leader's datapad as "<Bot>: <lair>" and goes when the
-- mission ends or the bot leaves the group (the C++ side, patches/bots/BotMission.*: botMissionSync).
--
-- By creature (Phase 7b): "janta missions", "grab two dragonet lairs east", "womp rat lairs north", "kreetle missions any
-- direction". A creature name in the request (plurals and "lair", "nest", "camp" ignored) that lives in a destroy-mission
-- lair on this planet (botMissionCreatures) keeps only the missions whose lair has it, among the lair's name and its
-- creatures (botMissionList's creatures). With a direction, the best-paying within 45 degrees as always; with none, the best
-- anywhere. Nothing on offer after the refreshes: it takes nothing and says so (missionNoneOf), no fall back to other
-- creatures. Follow-ups ("search again", a bare direction) keep the creature, as they keep the direction. A word that is
-- no creature of this planet leaves the request as it was (any creature).
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

local function hasAny(text, list)
	for _, words in ipairs(list) do
		if text:find(words, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- " words like this " (lowercase letters, digits and apostrophes)
local function wordsOf(text)
	return " " .. (tostring(text or ""):lower():gsub("[^%w']", " "):gsub("%s+", " ")) .. " "
end

local function mkey(missionOid, field)
	return "crew:mission:" .. missionOid .. ":" .. field
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
	wideArc = 90,     -- ...and, after the last list, when that left it short
	max = 2,          -- Core3's limit
	stepMs = 1600,    -- between steps: the list's refresh cooldown is 1.4 s
	timeout = 120,    -- seconds for the whole errand
	retries = 4,      -- walks to the terminal before it gives up
	syncEvery = 5,    -- seconds between waypoint syncs
}

-- Creature talk

-- Words that are never the creature: mission talk, counts, directions, chat
local CREATURE_STOP = {}

for word in ([[mission missions lair lairs nest nests camp camps grab get take accept fetch pick run find need want give
	two one three a an the me us any direction directions anywhere nearby close closest nearest near please for of from to in at
	and on my your our some all destroy destroying hunt hunting go up out down again search them it that this those these
	north northeast east southeast south southwest west northwest n ne e se s sw w nw side way there here also then
	tatooine naboo corellia dantooine dathomir endor lok rori talus yavin4 yavin planet]]):gmatch("%a+") do
	CREATURE_STOP[word] = true
end

-- Words that name a kind of animal or person, not which: alone they are not a request for a creature
local CREATURE_GENERIC = {}

for word in ([[greater lesser giant young elder great small large little big wild desert mountain plains canyon dune
	male female baby old leader captain soldier death clan rock sand spice pa lord king queen chief elder guard hunter warrior
	scout champion master boss lieutenant commander sergeant officer apprentice acolyte assassin thug thief bandit]]):gmatch("%a+") do
	CREATURE_GENERIC[word] = true
end

-- "womp rats" -> "womp rat", "wolves" -> "wolf"; the same on both sides, so it only has to be consistent
local function singular(word)
	if #word > 4 and word:sub(-3) == "ies" then
		return word:sub(1, -4) .. "y"
	elseif #word > 4 and word:sub(-3) == "ves" then
		return word:sub(1, -4) .. "f"
	elseif #word > 3 and word:sub(-1) == "s" and word:sub(-2) ~= "ss" and word:sub(-2) ~= "us" and word:sub(-2) ~= "is" then
		return word:sub(1, -2)
	end

	return word
end

-- A name's words, singular, lowercase, without "lair", "nest" and "camp"
local function nameWords(name)
	local out = {}

	for word in tostring(name or ""):lower():gmatch("%a+") do
		if word ~= "lair" and word ~= "lairs" and word ~= "nest" and word ~= "nests" and word ~= "camp" and word ~= "camps" then
			table.insert(out, singular(word))
		end
	end

	return out
end

-- Per planet (the Lua state is the thread's own, and the spawn groups never change): every phrase of one or more
-- consecutive words in a creature's or lair's name, "womp rat" and "womp", "rat" of it, except a lone generic word
local vocabulary = {}

function BotCrew:missionVocabulary(pBot)
	local zone = SceneObject(pBot):getZoneName()

	if vocabulary[zone] ~= nil then
		return vocabulary[zone]
	end

	local names = bot("botMissionCreatures", pBot)

	if names == nil or #names == 0 then
		return nil
	end

	local phrases = {}

	for _, name in ipairs(names) do
		local words = nameWords(name)

		for i = 1, #words do
			for j = i, #words do
				if i ~= j or not CREATURE_GENERIC[words[i]] then
					phrases[table.concat(words, " ", i, j)] = true
				end
			end
		end
	end

	vocabulary[zone] = phrases

	return phrases
end

-- The creature a request names: the longest run of its words that is a phrase of this planet's destroy-mission creatures
-- ("womp rat", "janta"); nil when there is none
function BotCrew:missionCreatureOf(pBot, text)
	local phrases = self:missionVocabulary(pBot)

	if phrases == nil then
		return nil
	end

	local words = {}

	for word in tostring(text or ""):lower():gsub("'", ""):gmatch("%a+") do
		if CREATURE_STOP[word] then
			table.insert(words, false)
		else
			table.insert(words, singular(word))
		end
	end

	local best, bestLength = nil, 0

	for i = 1, #words do
		local phrase = nil

		for j = i, #words do
			if words[j] == false then
				break
			end

			phrase = phrase == nil and words[j] or (phrase .. " " .. words[j])

			if phrases[phrase] and (j - i + 1 > bestLength or (j - i + 1 == bestLength and #phrase > #best)) and
				not (i == j and (CREATURE_GENERIC[words[i]] or #words[i] < 3)) then
				best, bestLength = phrase, j - i + 1
			end
		end
	end

	return best
end

-- Does the mission's lair, or a creature in it, have this creature in its name?
function BotCrew:missionHas(m, creature)
	local needle = " " .. creature .. " "
	local names = {m.target}

	for _, name in ipairs(m.creatures or {}) do
		table.insert(names, name)
	end

	for _, name in ipairs(names) do
		if (" " .. table.concat(nameWords(name), " ") .. " "):find(needle, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- The missions of the list that have the creature (all of them with no creature asked)
function BotCrew:missionFilter(missions, creature)
	if creature == nil or creature == "" then
		return missions
	end

	local out = {}

	for _, m in ipairs(missions or {}) do
		if self:missionHas(m, creature) then
			table.insert(out, m)
		end
	end

	return out
end

-- Mission talk

-- No direction asked: any (the best paying), or the nearest. Stored as the mission's direction
local ANY, NEAR = -1, -2
local ANY_NAME, NEAR_NAME = "any direction", "nearby"
local ANY_PHRASES = {"any direction", "dont care", "whatever direction", "doesnt matter", "anywhere", "whichever",
	"no preference", "any way", "dont mind"}
local NEAR_PHRASES = {"closest", "nearest", "close by", "closeby", "nearby", "near by", "semi close", "pretty close", "not far"}
-- A retry, in a few words ("search again", "get them", "pick two"): only counts soon after the crew was asked for missions
local RETRY_PHRASES = {" again", "get them", "take them", "grab them", "pick them", "pick two", "pick one", "pick some",
	"grab some", "grab two", "get two", "take two", "get some", "take some", " any ", "whatever", "anything", "anywhere"}
local QUESTION_WORDS = {did = true, ["do"] = true, does = true, have = true, has = true, what = true, why = true, how = true,
	are = true, is = true, was = true, were = true, who = true, where = true, when = true}
local LEAD_WORDS = {well = true, so = true, ok = true, okay = true, hey = true, but = true, ["and"] = true, ["then"] = true,
	just = true, please = true, now = true, yo = true, oh = true}
BotCrew.missionAsked = 180   -- seconds after a request for missions that a retry still counts

-- The line without its lead-in words, as wordsOf gives it (" did you get two ")
local function leadless(text)
	local t = wordsOf(text)

	while true do
		local first, rest = t:match("^ (%S+)( .*)$")

		if first == nil or not LEAD_WORDS[first] then
			break
		end

		t = rest
	end

	return t
end

-- "did you get two?", "what missions do you have": a question, not an order
local function questionLike(text)
	local first = leadless(text):match("^ (%S+)")

	return first ~= nil and QUESTION_WORDS[first] == true
end

-- What a group chat line asks of the missions: nil, {kind = "drop"} or {kind = "take", dir = <degrees, ANY or NEAR, or
-- nil>, name = <direction name>, count = 1 or 2}. A take with no direction only counts when it says to take (grab, get,
-- ...). With loose, no word "mission" is needed (a retry), and only a direction, "any" or "nearby" makes a take.
function BotCrew:missionRequest(text, loose, creature)
	local t = tostring(text or ""):lower():gsub("'", "")

	t = t:gsub("north[%s%-]+east", "northeast"):gsub("north[%s%-]+west", "northwest"):gsub("south[%s%-]+east", "southeast")
		:gsub("south[%s%-]+west", "southwest")

	local mission, drop, take, direction = false, false, false, nil

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

	-- "grab two dragonet lairs east": a lair or a nest is a mission when a creature is asked for with a take verb (talk
	-- about a lair on a hunt, "kill that womp rat lair", isn't)
	if not mission and take and creature ~= nil and (t:find("%f[%a]lairs?%f[%A]") or t:find("%f[%a]nests?%f[%A]")) then
		mission = true
	end

	if not mission and not loose then
		return nil
	end

	if drop then
		return mission and {kind = "drop"} or nil
	end

	local count = (t:find("%f[%a]one%f[%A]") or t:find("%f[%d]1%f[%D]")) and 1 or 2

	if direction ~= nil then
		return {kind = "take", dir = DIRECTIONS[direction], name = direction, count = count}
	end

	if hasAny(t, NEAR_PHRASES) or t:find("%f[%a]close%f[%A]") then
		return {kind = "take", dir = NEAR, name = NEAR_NAME, count = count}
	end

	if hasAny(t, ANY_PHRASES) then
		return {kind = "take", dir = ANY, name = ANY_NAME, count = count}
	end

	-- ("janta missions": the creature asks, with or without a verb; with no direction it means anywhere)
	if (take or creature ~= nil) and mission then
		return {kind = "take", count = count}
	end

	return nil
end

-- A short line that retries ("search again", "get them", "pick two semi close", "i dont care which direction", "east"):
-- a take, with a direction only if it gave one. nil for a question or a longer line.
function BotCrew:missionRetry(text)
	if questionLike(text) then
		return nil
	end

	local t = leadless(text)
	local words = 0

	for _ in t:gmatch("%S+") do
		words = words + 1
	end

	if words > 8 then
		return nil
	end

	local request = self:missionRequest(text, true)

	-- A direction, "any" or "nearby" (a bare direction only when it is nearly all the line says)
	if request ~= nil and request.kind == "take" and request.dir ~= nil and (request.dir < 0 or words <= 4) then
		return request
	end

	local plain = t:gsub("'", "")

	if hasAny(plain, RETRY_PHRASES) then
		local count = plain:find("%f[%a]one%f[%A]") and 1 or 2

		if plain:find(" any ", 1, true) or plain:find("whatever", 1, true) or plain:find("anything", 1, true) then
			return {kind = "take", dir = ANY, name = ANY_NAME, count = count}
		end

		return {kind = "take", count = count}
	end

	return nil
end

function BotCrew:missionDirOf(name)
	if name == ANY_NAME then
		return ANY
	elseif name == NEAR_NAME then
		return NEAR
	end

	return DIRECTIONS[name or ""]
end

-- The destroy missions within arc degrees of dir (compass degrees; any direction when dir is below 0), best paying first
-- (the nearest first for NEAR), at most need of them
function BotCrew:missionPick(missions, dir, need, arc)
	local picks = {}

	for _, m in ipairs(missions or {}) do
		local off = dir < 0 and 0 or math.abs((((m.degrees or 0) - dir + 180) % 360) - 180)

		if off <= arc then
			table.insert(picks, m)
		end
	end

	table.sort(picks, function(a, b)
		if dir == NEAR and (a.distance or 0) ~= (b.distance or 0) then
			return (a.distance or 0) < (b.distance or 0)
		end

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

	local g = self:group(pBot)
	local speaker = g ~= nil and g.byOid[SceneObject(pSpeaker):getObjectID()] or nil

	if speaker == nil or not speaker.human then
		return false
	end

	local now = os.time()
	local forGroup = readData(ckey(oid, "forGroup")) == 1
	local retryable = self:missionRetryable(g, oid, forGroup, now)
	local lower = tostring(text or ""):lower()
	local creature = nil
	local saysMission = lower:find("mission", 1, true) ~= nil

	-- Orders to fight and move are the crew's own talk ("kill that womp rat lair", "get over to the lair east"), unless the
	-- line asks for missions in so many words
	if not saysMission then
		local intent = self:intentFor(text, nil)

		if intent == "attack" or intent == "follow" or intent == "stay" or intent == "home" then
			return false
		end
	end

	-- (only a line about missions, lairs or nests, or a follow-up soon after an errand, can name a creature)
	if retryable or lower:find("mission", 1, true) or lower:find("lair", 1, true) or lower:find("nest", 1, true) then
		creature = self:missionCreatureOf(pBot, text)
	end

	local request = self:missionRequest(text, false, creature)
	local followUp = false

	-- A lair line without "missions" (grab two dragonet lairs east) is for a mission terminal: with none by, it is hunting talk
	if request ~= nil and not saysMission and not self:missionTerminalNear(pBot, g) then
		return false
	end

	-- Not about missions, but soon after the crew was asked for some and is short: "search again", "get them", "any"
	if request == nil then
		if not retryable then
			return false
		end

		request = self:missionRetry(text)

		-- ("just the janta", said right after the terminal had none of them; or "get the kreetles" with a take verb)
		if request == nil and creature ~= nil and not questionLike(text) and not tostring(text):find("?", 1, true) and
			select(2, leadless(text):gsub("%S+", "")) <= 4 and
			(self:missionNoneRecently(g, oid, forGroup, now) or self:missionTakeVerb(text)) then
			request = {kind = "take", count = 2}
		end

		if request == nil then
			return false
		end

		followUp = true
	end

	-- A follow-up keeps the creature it was asked for; a new order with none asks for any
	if creature == nil and followUp then
		creature = self:missionLastCreature(g, oid, forGroup, now)
	end

	request.creature = creature

	local name = self:firstName(pSpeaker)

	put(ckey(oid, "forGroup"), 0)

	if request.kind == "take" then
		put(ckey(oid, "mAskAt"), now)

		if request.dir == nil then
			-- A question about missions is the brain's; an order with no direction takes the last one asked
			local last = not questionLike(text) and self:missionLastName(g, oid, forGroup, now) or nil

			if creature ~= nil and not questionLike(text) and (not followUp or last == nil) then
				-- "janta missions": a creature and no direction means anywhere
				request.name, request.dir = ANY_NAME, ANY
			elseif last ~= nil then
				request.name, request.dir = last, self:missionDirOf(last)
			elseif questionLike(text) then
				return false
			else
				self:groupSay(pBot, oid, "missionWhere", name)

				return true
			end
		end
	end

	self:missionOrder(pBot, oid, request, name)

	-- Said to the whole group (this bot answered for it): the others get the same errand
	if forGroup then
		for i, m in ipairs(g.crew) do
			if m.oid ~= oid then
				createEvent(500 * i, "BotCrew", "missionGroup", m.p,
					packArgs(readData(key(m.oid, "gen")), request.kind, request.name or "-", request.count or 2, creature or "-"))
			end
		end
	end

	return true
end

-- Was this bot (said to it alone) or the crew (said to the group) asked for missions lately, and is it short of two?
function BotCrew:missionRetryable(g, oid, forGroup, now)
	for _, m in ipairs(g.crew) do
		if (forGroup or m.oid == oid) and now - readData(ckey(m.oid, "mAskAt")) <= self.missionAsked and
			#(bot("botMissions", m.p) or {}) < self.missionCfg.max then
			return true
		end
	end

	return false
end

-- Does the line have a verb that takes missions (grab, get, take, ...)?
function BotCrew:missionTakeVerb(text)
	for word in tostring(text or ""):lower():gmatch("%a+") do
		if TAKE_WORDS[word] then
			return true
		end
	end

	return false
end

-- Did this bot (said to it alone) or the crew (said to the group) just say it found none of the creature asked for?
function BotCrew:missionNoneRecently(g, oid, forGroup, now)
	for _, m in ipairs(g.crew) do
		if (forGroup or m.oid == oid) and now - readData(ckey(m.oid, "mNoneAt")) <= self.missionAsked and readData(ckey(m.oid, "mNoneAt")) ~= 0 then
			return true
		end
	end

	return false
end

-- Is there a general mission terminal by the bot, or by the group's leader?
function BotCrew:missionTerminalNear(pBot, g)
	local terminals = bot("botMissionTerminals", pBot, self.missionCfg.range)

	if terminals ~= nil and #terminals > 0 then
		return true
	end

	if g ~= nil and g.leader ~= nil then
		terminals = bot("botMissionTerminals", g.leader.p, self.missionCfg.range)
	end

	return terminals ~= nil and #terminals > 0
end

-- The direction last asked of this bot (or, said to the group, of a crew mate), if that was lately
function BotCrew:missionLastName(g, oid, forGroup, now)
	local own = readStringData(ckey(oid, "mLastName"))

	if own ~= "" and now - readData(ckey(oid, "mAskAt")) <= self.missionAsked then
		return own
	end

	if forGroup then
		for _, m in ipairs(g.crew) do
			local last = readStringData(ckey(m.oid, "mLastName"))

			if last ~= "" and now - readData(ckey(m.oid, "mAskAt")) <= self.missionAsked then
				return last
			end
		end
	end

	return nil
end

-- The creature last asked of this bot (or, said to the group, of a crew mate), if that was lately; "" when it was none
function BotCrew:missionLastCreature(g, oid, forGroup, now)
	if now - readData(ckey(oid, "mAskAt")) <= self.missionAsked and readData(ckey(oid, "mLastSet")) == 1 then
		return readStringData(ckey(oid, "mLastCreature")) ~= "" and readStringData(ckey(oid, "mLastCreature")) or nil
	end

	if forGroup then
		for _, m in ipairs(g.crew) do
			if now - readData(ckey(m.oid, "mAskAt")) <= self.missionAsked and readData(ckey(m.oid, "mLastSet")) == 1 then
				local last = readStringData(ckey(m.oid, "mLastCreature"))

				return last ~= "" and last or nil
			end
		end
	end

	return nil
end

function BotCrew:missionGroup(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) or not CreatureObject(pBot):isGrouped() then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local g = self:group(pBot)
	local pLeader = g ~= nil and g.humans[1] ~= nil and g.humans[1].p or nil

	self:missionOrder(pBot, oid, {kind = a[2], name = a[3] ~= "-" and a[3] or nil, dir = self:missionDirOf(a[3]),
		count = num(a[4]) or 2, creature = a[5] ~= nil and a[5] ~= "-" and a[5] or nil},
		pLeader ~= nil and self:firstName(pLeader) or "friend")
end

function BotCrew:missionOrder(pBot, oid, request, name)
	if request.kind == "drop" then
		self:missionDrop(pBot, oid, name)
	elseif request.dir ~= nil then
		put(ckey(oid, "mAskAt"), os.time())
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
	deleteStringData(ckey(oid, "mHeld"))
	deleteData(ckey(oid, "mHeldN"))
	deleteStringData(ckey(oid, "mName"))
	deleteStringData(ckey(oid, "mDirName"))
	deleteStringData(ckey(oid, "mLastName"))
	deleteStringData(ckey(oid, "mCreature"))
	deleteStringData(ckey(oid, "mLastCreature"))
	deleteData(ckey(oid, "mLastSet"))
	deleteData(ckey(oid, "mNoneAt"))
	deleteData(ckey(oid, "mAskAt"))
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

	-- None by the bot (still catching up): the ones by the leader, who asked at a terminal
	if terminals == nil or #terminals == 0 then
		local gl = self:group(pBot)

		if gl ~= nil and gl.leader ~= nil and gl.leader.oid ~= oid then
			terminals = bot("botMissionTerminals", gl.leader.p, self.missionCfg.range)
		end
	end

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
	writeStringData(ckey(oid, "mLastName"), request.name)
	writeStringData(ckey(oid, "mCreature"), (tostring(request.creature or ""):gsub("%%", "")))
	writeStringData(ckey(oid, "mLastCreature"), (tostring(request.creature or ""):gsub("%%", "")))
	put(ckey(oid, "mLastSet"), 1)
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

	print("BotJobs: " .. self:name(oid) .. " goes for " .. need .. " destroy mission(s) " .. request.name ..
		(request.creature ~= nil and (" (" .. request.creature .. ")") or "") .. ", terminal " ..
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
	local dir = readData(ckey(oid, "mDir"))
	local creature = readStringData(ckey(oid, "mCreature"))
	local offered = #missions

	-- Asked for a creature: only its lairs count (none of the others, however well they pay)
	missions = self:missionFilter(missions, creature)

	local picks = self:missionPick(missions, dir, need, cfg.arc)

	put(ckey(oid, "mTries"), tries)

	-- One line a list, for the log: what the terminal offered, and how much of it lies the way it was asked
	print("BotJobs: " .. self:name(oid) .. " reads list " .. tries .. ": " .. offered .. " destroy, " ..
		(creature ~= "" and (#missions .. " " .. creature .. ", ") or "") ..
		#self:missionPick(missions, dir, #missions, cfg.arc) .. " " .. readStringData(ckey(oid, "mDirName")) ..
		" (" .. #self:missionPick(missions, dir, #missions, cfg.wideArc) .. " within " .. cfg.wideArc .. " degrees)")

	if #picks >= need then
		self:missionTake(pBot, oid, terminal, picks, now)
		return
	end

	if tries >= cfg.refreshes then
		-- Short after the last list: the best within the wider arc (the ones in the narrow arc are among them)
		local wide = self:missionPick(missions, dir, need, cfg.wideArc)

		self:missionTake(pBot, oid, terminal, wide, now, #wide > #picks)
		return
	end

	again()
end

function BotCrew:missionTake(pBot, oid, terminal, picks, now, widened)
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

	local anyDirection = readData(ckey(oid, "mDir")) < 0
	local creature = readStringData(ckey(oid, "mCreature"))

	if #taken == 0 then
		if creature ~= "" then
			put(ckey(oid, "mNoneAt"), os.time())
			self:groupSay(pBot, oid, "missionNoneOf", name, {creature = creature, dir = dirName, tries = tostring(tries)})
		else
			self:groupSay(pBot, oid, anyDirection and "missionNoneAny" or "missionNone", name, {dir = dirName, tries = tostring(tries)})
		end

		return
	end

	local parts = {}

	for _, m in ipairs(taken) do
		table.insert(parts, self:missionText(m))
	end

	local word = COUNT_WORDS[#taken + 1] or tostring(#taken)

	-- Wider than asked: where the lairs lie ("northeast and north")
	local where, seen = {}, {}

	for _, m in ipairs(taken) do
		local d = tostring(m.direction or "")

		if d ~= "" and not seen[d] then
			seen[d] = true
			table.insert(where, d)
		end
	end

	local whereText = table.concat(where, " and ")

	if widened then
		dirName = dirName .. " (took " .. whereText .. ")"
	end

	print("BotJobs: " .. self:name(oid) .. " took " .. #taken .. " mission(s) " .. dirName .. ": " .. table.concat(parts, "; "))

	-- Remembered for the hunt: what each is (so its completion can be told), and that the bot holds them now
	for _, m in ipairs(taken) do
		writeStringData(mkey(m.oid, "text"), (tostring(m.target or "lair"):gsub("[%%|]", "")))
	end

	self:missionHeldSet(pBot, oid)
	self:huntEvent(pBot, self:firstName(pBot) .. " took " .. #taken .. " destroy mission" .. (#taken == 1 and "" or "s") .. " " ..
		dirName .. ": " .. table.concat(parts, "; "))
	if widened then
		self:groupSay(pBot, oid, "missionWide", name, {dir = readStringData(ckey(oid, "mDirName")), count = word,
			Count = word:sub(1, 1):upper() .. word:sub(2), where = whereText, list = table.concat(parts, "; ")})
		return
	end

	self:groupSay(pBot, oid, anyDirection and "missionTookAny" or "missionTook", name, {dir = dirName, count = word, Count = word:sub(1, 1):upper() .. word:sub(2),
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

	-- (dropped on purpose: not a completion)
	self:missionHeldSet(pBot, oid)

	if aborted > 0 then
		self:huntEvent(pBot, self:firstName(pBot) .. " dropped " .. aborted .. " mission" .. (aborted == 1 and "" or "s"))
	end

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

-- The destroy missions the bot holds, as a list of oids ("123,456")
function BotCrew:missionHeldList(pBot)
	local held = bot("botMissions", pBot) or {}
	local oids = {}

	for _, m in ipairs(held) do
		table.insert(oids, tostring(math.floor(m.oid)))
	end

	return table.concat(oids, ","), #oids
end

-- What the bot holds now is what it should hold: a mission that goes after this isn't ours to explain
function BotCrew:missionHeldSet(pBot, oid)
	local list, n = self:missionHeldList(pBot)

	writeStringData(ckey(oid, "mHeld"), list)
	put(ckey(oid, "mHeldN"), n)
end

-- How a mission left a datapad: "done" (completed and rewarded: the lair was destroyed), "dropped" (its lair was up and it
-- went anyway: abandoned or expired) or "failed" (it never got a lair). The reward hook (patches/0008) says "done"; a
-- build without it takes a lair that was up for destroyed.
local function missionOutcome(digits)
	local lair = readData(mkey(digits, "lair")) == 1

	if botMissionDone ~= nil then
		if botMissionDone(tonumber(digits)) then
			return "done"
		end

		return lair and "dropped" or "failed"
	end

	return lair and "done" or "failed"
end

-- From the bot's loop, in a fight or out of one (every few seconds): has a mission left the datapad without the bot
-- dropping it? Core3 removes a destroy mission when its lair is destroyed (done), and also when it can't find a spot to
-- spawn the lair (failed). The lair having been up at a look (lairUp) tells them apart; that is why this runs in fights
-- too, where a lair spawns and falls without a quiet moment between. One log line each, and a count of the lairs done
-- for the hunt's tally.
function BotCrew:missionWatch(pBot, oid, now)
	if now - readData(ckey(oid, "mWatchAt")) < 4 or botMissions == nil then
		return
	end

	put(ckey(oid, "mWatchAt"), now)

	local before = readStringData(ckey(oid, "mHeld"))

	if before == "" then
		return
	end

	local held = bot("botMissions", pBot) or {}
	local list, nowSet = {}, {}

	for _, m in ipairs(held) do
		local digits = tostring(math.floor(m.oid))

		table.insert(list, digits)
		nowSet[digits] = true

		if m.lairUp then
			put(mkey(digits, "lair"), 1)
		end
	end

	for digits in before:gmatch("%d+") do
		if not nowSet[digits] then
			local text = readStringData(mkey(digits, "text"))
			local name = text ~= "" and text or "destroy"

			local outcome = missionOutcome(digits)

			if outcome == "done" then
				print("BotJobs: " .. self:name(oid) .. "'s mission is done: " .. name)
				self:huntTallyAdd(pBot, "lairs", 1)
				self:huntEvent(pBot, "Lair destroyed: " .. self:firstName(pBot) .. "'s " .. name .. " mission is done")
			elseif outcome == "dropped" then
				print("BotJobs: " .. self:name(oid) .. "'s mission was dropped: " .. name)
			else
				print("BotJobs: " .. self:name(oid) .. "'s mission failed: " .. name)
				self:huntEvent(pBot, self:firstName(pBot) .. "'s " .. name .. " mission failed (it never got a lair)")
			end

			deleteStringData(mkey(digits, "text"))
			deleteData(mkey(digits, "lair"))
		end
	end

	writeStringData(ckey(oid, "mHeld"), table.concat(list, ","))
	put(ckey(oid, "mHeldN"), #list)
end

-- The group's humans' own destroy missions, read the same way (botPlayerMissions) for the hunt's tally: from the
-- group's loop of any crew member, in an event on the human (so only the human is locked), at most every 4 s per human.
-- The state is shared and keyed by the human, so a mission that ends is counted once, whoever looked.
function BotCrew:missionWatchHumans(g)
	if botPlayerMissions == nil then
		return
	end

	local now = os.time()

	for _, m in ipairs(g.humans) do
		local base = "crew:human:" .. m.oid

		if now - readData(base .. ":mWatchAt") >= 4 then
			put(base .. ":mWatchAt", now)
			createEvent(1, "BotCrew", "missionWatchHuman", m.p, "")
		end
	end
end

function BotCrew:missionWatchHuman(pHuman, args)
	local held = pHuman ~= nil and botPlayerMissions ~= nil and botPlayerMissions(pHuman) or nil

	if held == nil then
		return
	end

	local now = os.time()
	local base = "crew:human:" .. SceneObject(pHuman):getObjectID()
	local before = readStringData(base .. ":mHeld")

	-- Not looked at for a while (no crew with them): what ended in between isn't this hunt's
	if now - readData(base .. ":mSeenAt") > 120 then
		before = ""
	end

	local list, nowSet = {}, {}

	for _, m in ipairs(held) do
		local digits = tostring(math.floor(m.oid))

		table.insert(list, digits)
		nowSet[digits] = true
		writeStringData(mkey(digits, "text"), (tostring(m.target or "lair"):gsub("[%%|]", "")))

		if m.lairUp then
			put(mkey(digits, "lair"), 1)
		end
	end

	for digits in before:gmatch("%d+") do
		if not nowSet[digits] then
			local text = readStringData(mkey(digits, "text"))
			local name = text ~= "" and text or "destroy"
			local who = self:firstName(pHuman)

			if missionOutcome(digits) == "done" then
				print("BotJobs: " .. who .. "'s mission is done: " .. name)
				self:huntTallyAdd(pHuman, "lairs", 1)
				self:huntEvent(pHuman, "Lair destroyed: " .. who .. "'s " .. name .. " mission is done")
			else
				-- (re-rolled at a terminal, abandoned or expired: not a lair destroyed)
				print("BotJobs: " .. who .. "'s mission was dropped: " .. name)
			end

			deleteStringData(mkey(digits, "text"))
			deleteData(mkey(digits, "lair"))
		end
	end

	writeStringData(base .. ":mHeld", table.concat(list, ","))
	put(base .. ":mHeldN", #list)
	put(base .. ":mSeenAt", now)
end

-- Out of the group: its waypoints leave the leader's datapad, an errand on its way ends
function BotCrew:missionLeft(pBot, oid)
	if readStringData(ckey(oid, "mState")) == "walking" then
		put(ckey(oid, "mSeq"), readData(ckey(oid, "mSeq")) + 1)
		writeStringData(ckey(oid, "mState"), "idle")
	end

	deleteData(ckey(oid, "mSyncAt"))

	-- Out of the group, its missions go: a bot's lair could otherwise pay nobody, or be done by the bot alone
	local count = bot("botMissionAbort", pBot) or 0

	deleteStringData(ckey(oid, "mHeld"))
	deleteData(ckey(oid, "mHeldN"))

	if count > 0 then
		print("BotJobs: " .. self:name(oid) .. " drops " .. count .. " mission(s) on leaving the group")
	end

	bot("botMissionSync", pBot)
end

-- Logging in out of a group (a restart broke it up) with missions from before: they go, as on leaving the group
function BotCrew:missionLogin(pBot, oid)
	if botMissionAbort == nil or CreatureObject(pBot):isGrouped() then
		return
	end

	local count = bot("botMissionAbort", pBot) or 0

	if count > 0 then
		print("BotJobs: " .. self:name(oid) .. " drops " .. count .. " mission(s) from before (not in a group)")
	end
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
	local line = (text or ""):gsub("_", " ")
	local creature = pBot ~= nil and self:missionCreatureOf(pBot, line) or nil
	local request = self:missionRequest(line, false, creature)

	if pBot == nil or request == nil then
		print("BotCrew: usage devMissionAsk:<first>:<text with _ for spaces> (a missions line); got " .. tostring(text))
		return
	end

	if request.dir == nil and creature ~= nil then
		request.name = ANY_NAME
	end

	createEvent(10, "BotCrew", "devMissionNow", pBot, packArgs(request.kind, request.name or "-", request.count or 2, creature or "-"))
end

function BotCrew:devMissionNow(pBot, args)
	local a = unpackArgs(args)
	local name = a[2] ~= "-" and a[2] or nil

	self:missionOrder(pBot, SceneObject(pBot):getObjectID(), {kind = a[1], name = name, dir = self:missionDirOf(name),
		count = num(a[3]) or 2, creature = a[4] ~= nil and a[4] ~= "-" and a[4] or nil}, "Tester")
end
