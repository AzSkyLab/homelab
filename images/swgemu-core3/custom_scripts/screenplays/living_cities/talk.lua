-- Living Cities, Phase 2: the crowd answers a player who targets or names one of them in spatial chat.
-- Spec: ~/github/swgemu/specs/2026-10-23-npcs-that-talk/.
--
-- Lua can't call the language model without stalling a server thread, so it writes a request file and the talk
-- bridge (images/swgemu-core3/talk/talk_bridge.py, a second container in the pod) writes the reply:
--   /run/talk/req/<id>.json   {"type": "say", ...}, {"type": "gone", "npc": ...}, {"type": "warm"}
--   /run/talk/rep/<id>.txt    "ok" or "fallback", a mood, the line
-- The NPC checks for its reply once a second (an event on the NPC, so it holds the NPC's lock) and gives up after
-- `deadline` seconds with a canned line.
--
-- The bot players (screenplays/bots/, Phase 3) use the same mailbox: send, newId, canAsk/asked/answered (the
-- per-player limits), the quiet minute and readReply. Their replies carry a fourth line, the action, which the crowd
-- ignores. The crowd never answers a bot.

local TALKING = 4
local LINGERING = 2
local LEAVING = 3

LivingTalk = ScreenPlay:new {
	screenplayName = "LivingTalk",

	dir = "/run/talk",
	-- Seconds to wait for a reply before a canned line
	deadline = 12,
	-- The NPC stays with the player this long after the last exchange
	holdSeconds = 60,
	-- At most one message every minGapMs per player
	minGapMs = 3000,
	-- After a timeout or a failed answer the crowd stays quiet this long (seconds), instead of a fallback line for
	-- every message
	quietAfterTimeout = 60,
	-- Keep the model loaded while players are near a crowd (seconds between pings)
	warmEvery = 240,
	maxChars = 200,
	-- The bridge counts as gone when its heartbeat is older than this (seconds)
	aliveSeconds = 60,
}

registerScreenPlay("LivingTalk", true)

local function npcKey(oid, field)
	return "lc:npc:" .. oid .. ":" .. field
end

local function talkKey(playerOid, field)
	return "lc:talk:" .. playerOid .. ":" .. field
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

local function jsonString(s)
	s = tostring(s or "")
	s = s:gsub('[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		end

		return string.format("\\u%04x", string.byte(c))
	end)

	return '"' .. s .. '"'
end

-- {key = value, ...} -> a JSON object (strings and numbers only)
local function toJson(fields)
	local parts = {}

	for key, value in pairs(fields) do
		if type(value) == "number" then
			table.insert(parts, jsonString(key) .. ":" .. string.format("%d", value))
		else
			table.insert(parts, jsonString(key) .. ":" .. jsonString(value))
		end
	end

	return "{" .. table.concat(parts, ",") .. "}"
end

function LivingTalk:start()
	local probe = self.dir .. "/req/.probe"
	local f = io.open(probe, "w")

	if f ~= nil then
		f:close()
		os.remove(probe)
		print("LivingTalk: talk bridge directory ready" .. (self:bridgeAlive() and ", bridge running" or ", bridge not running yet"))
	else
		print("LivingTalk: no talk bridge directory at " .. self.dir .. "; the crowd won't answer")
	end
end

-- Is the bridge running? It rewrites /run/talk/alive with the time several times a second.
function LivingTalk:bridgeAlive()
	local f = io.open(self.dir .. "/alive", "r")

	if f == nil then
		return false
	end

	local t = tonumber(f:read("l") or "")
	f:close()

	return t ~= nil and os.time() - t <= self.aliveSeconds
end

-- Write one request; false if no bridge is reading (no answers then, and no fallback lines, and nothing piles up in
-- the shared directory)
function LivingTalk:send(id, fields)
	if not self:bridgeAlive() then
		return false
	end

	local path = self.dir .. "/req/" .. id
	local f = io.open(path .. ".tmp", "w")

	if f == nil then
		return false
	end

	f:write(toJson(fields))
	f:close()

	return os.rename(path .. ".tmp", path .. ".json") ~= nil
end

function LivingTalk:newId(oid)
	return oid .. "-" .. getTimestampMilli() .. "-" .. getRandomNumber(1000, 9999)
end

-- After a timeout or a failed answer nobody talks for quietAfterTimeout seconds (the crowd and the bots)
function LivingTalk:isQuiet()
	return readData("lc:talk:quietUntil") > os.time()
end

function LivingTalk:startQuiet()
	writeData("lc:talk:quietUntil", os.time() + self.quietAfterTimeout)
end

-- May this player ask now? One question at a time per player, not too fast, and not in the quiet minute
function LivingTalk:canAsk(playerOid)
	local now = getTimestampMilli()

	return readData(talkKey(playerOid, "pending")) <= now and now - readData(talkKey(playerOid, "last")) >= self.minGapMs and
		not self:isQuiet()
end

-- A question from this player went out: nothing more from them until its reply or the deadline
function LivingTalk:asked(playerOid)
	local now = getTimestampMilli()

	writeData(talkKey(playerOid, "pending"), now + (self.deadline + 2) * 1000)
	writeData(talkKey(playerOid, "last"), now)
end

function LivingTalk:answered(playerOid)
	deleteData(talkKey(playerOid, "pending"))
end

-- The reply to a request, once the bridge has written it (the file is removed): status ("ok" or "fallback"), mood,
-- line and action. A bot's reply always has the action line (empty for none, and on a fallback); a crowd reply has
-- three lines, so its action reads as "".
function LivingTalk:readReply(id)
	local path = self.dir .. "/rep/" .. id .. ".txt"
	local f = io.open(path, "r")

	if f == nil then
		return nil
	end

	local status = f:read("l") or ""
	local mood = f:read("l") or ""
	local line = f:read("l") or ""
	local action = f:read("l") or ""
	f:close()
	os.remove(path)

	return status, mood, line, action
end

-- A line fit for chat: no control characters, at most maxChars
function LivingTalk:cleanLine(line)
	line = (tostring(line or ""):gsub("[%c]", " "))

	if #line > self.maxChars then
		line = line:sub(1, self.maxChars - 3) .. "..."
	end

	return line
end

-- A bot player (Phase 3)? Guarded, so the crowd works the same on a server without the bot patch
local function isBotObject(pObject)
	return isBot ~= nil and pObject ~= nil and isBot(pObject) == true
end

-- Called by LivingCities for every NPC it spawns
function LivingTalk:setupNpc(pNpc)
	createObserver(SPATIALCHAT, "LivingTalk", "onHeard", pNpc)
end

-- Called by LivingCities when an NPC leaves: the bridge forgets its conversations
function LivingTalk:npcGone(oid)
	self:send(self:newId(oid), {type = "gone", npc = oid})
end

-- Called by LivingCities' chatter tick while a player is near a crowd
function LivingTalk:warm()
	local now = os.time()

	if now - readData("lc:talk:lastWarm") >= self.warmEvery then
		writeData("lc:talk:lastWarm", now)
		self:send(self:newId(0), {type = "warm"})
	end
end

-- Did the player mean this NPC? Their target, or its first name in the line (unless they target another of ours: a
-- crowd NPC or a bot player)
function LivingTalk:addressed(oid, pPlayer, text)
	local target = CreatureObject(pPlayer):getTargetID()

	if target == oid then
		return true
	end

	if target ~= 0 and (readStringData(npcKey(target, "city")) ~= "" or isBotObject(getSceneObject(target))) then
		return false
	end

	local first = readStringData(npcKey(oid, "first")):lower()

	if first == "" then
		return false
	end

	local words = " " .. (text:lower():gsub("[^%a]", " ")) .. " "

	return string.find(words, " " .. first .. " ", 1, true) ~= nil
end

-- SPATIALCHAT fires on an NPC with this observer when someone speaks within 25 m of it
function LivingTalk:onHeard(pNpc, pChatMessage, speakerId)
	if pNpc == nil or pChatMessage == nil then
		return 0
	end

	local pPlayer = getSceneObject(speakerId)

	-- Bot players are player characters too, but the crowd only answers people
	if pPlayer == nil or not SceneObject(pPlayer):isPlayerCreature() or isBotObject(pPlayer) then
		return 0
	end

	local oid = SceneObject(pNpc):getObjectID()
	local key = readStringData(npcKey(oid, "city"))
	local state = readData(npcKey(oid, "state"))

	if key == "" or state == LEAVING or state == 0 then
		return 0
	end

	local text = getChatMessage(pChatMessage)

	if text == nil or text == "" or not self:addressed(oid, pPlayer, text) then
		return 0
	end

	self:ask(pNpc, oid, key, SceneObject(pPlayer):getObjectID(), CreatureObject(pPlayer):getFirstName(), text)

	return 0
end

-- Send what the player said to the bridge and start waiting for the reply
function LivingTalk:ask(pNpc, oid, key, playerOid, playerName, text)
	-- One question at a time per player, not too fast, and quiet for a while after the model timed out
	if not self:canAsk(playerOid) then
		return false
	end

	local spot = LivingCitiesData[key].spots[readData(npcKey(oid, "spot"))]
	local id = self:newId(oid)
	local sent = self:send(id, {
		type = "say", id = id, at = os.time(),
		npc = oid, name = readStringData(npcKey(oid, "name")), first = readStringData(npcKey(oid, "first")),
		species = readStringData(npcKey(oid, "species")), sex = readStringData(npcKey(oid, "sex")),
		kit = readStringData(npcKey(oid, "kit")), city = key, place = spot ~= nil and spot.place or "plaza",
		hour = LivingCities:hour(),
		player = playerOid, playerName = playerName, text = text,
	})

	if not sent then
		return false
	end

	self:asked(playerOid)

	-- Turn to the player now, then wait for the reply (both in events that hold the NPC's lock)
	createEvent(10, "LivingTalk", "startTalk", pNpc, packArgs(readData(npcKey(oid, "gen")), playerOid))
	createEvent(1000, "LivingTalk", "poll", pNpc, packArgs(id, playerOid, 1))

	return true
end

-- Development: a Mos Eisley crowd member is asked a question by a pretend player (the round trip through the bridge
-- without a game client; the reply shows in the log as LivingTalk: <name> says ...)
function LivingTalk:devAsk()
	local members = LivingCities:members("mos_eisley")
	local pNpc = members[getRandomNumber(1, math.max(1, #members))]

	if pNpc == nil then
		print("LivingTalk: nobody in Mos Eisley to ask")
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local questions = {"where's the bank?", "how do I get to the cantina?", "where can I train marksman?", "seen anything interesting lately?"}
	local text = questions[getRandomNumber(1, #questions)]

	print("LivingTalk: asking " .. readStringData(npcKey(oid, "name")) .. ": " .. text)

	if not self:ask(pNpc, oid, "mos_eisley", 1, "Tester", text) then
		print("LivingTalk: not sent (no bridge running, a question still waiting, or the quiet minute after a fallback)")
	end
end

function LivingTalk:startTalk(pNpc, args)
	local a = unpackArgs(args)

	if not LivingCities:current(pNpc, a[1]) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()
	local state = readData(npcKey(oid, "state"))

	if state == LEAVING then
		return
	end

	if state ~= TALKING then
		writeData(npcKey(oid, "state"), TALKING)

		-- Stop where it stands if it was walking (Core3 keeps queued points, so empty the queue)
		LivingCities:clearWalk(pNpc)

		createEvent(15 * 1000, "LivingTalk", "talkCheck", pNpc, a[1])
	end

	writeData(npcKey(oid, "talkUntil"), os.time() + self.holdSeconds)

	-- Seated or dancing NPCs keep at it; the rest turn to the player
	local key = readStringData(npcKey(oid, "city"))
	local spot, slot = LivingCities:slotOf(key, oid)
	local pPlayer = getSceneObject(tonumber(a[2]))

	if pPlayer ~= nil and (slot == nil or (slot.act ~= "sit" and slot.act ~= "dance")) then
		SceneObject(pNpc):faceObject(pPlayer, true)
	end
end

function LivingTalk:poll(pNpc, args)
	local a = unpackArgs(args)
	local id, playerOid, tries = a[1], tonumber(a[2]), tonumber(a[3])
	local alive = pNpc ~= nil and SceneObject(pNpc):getZoneName() ~= ""
	local status, mood, line = self:readReply(id)

	if status ~= nil then
		self:answered(playerOid)

		if alive then
			if status == "ok" and line ~= "" then
				self:say(pNpc, line, mood)
			else
				-- The bridge couldn't get an answer (no key, LiteLLM down, the GPU busy): one canned line, then quiet
				self:startQuiet()
				self:fallback(pNpc)
			end
		end

		return
	end

	if not alive then
		self:answered(playerOid)
		return
	end

	if tries >= self.deadline then
		-- No answer in time: one canned line, then the crowd keeps quiet for a minute
		self:answered(playerOid)
		self:startQuiet()
		self:fallback(pNpc)
		return
	end

	createEvent(1000, "LivingTalk", "poll", pNpc, packArgs(id, playerOid, tries + 1))
end

function LivingTalk:say(pNpc, line, mood)
	local oid = SceneObject(pNpc):getObjectID()

	line = self:cleanLine(line)

	writeData(npcKey(oid, "talkUntil"), os.time() + self.holdSeconds)

	local key = readStringData(npcKey(oid, "city"))
	local spot, slot = LivingCities:slotOf(key, oid)

	-- A mood shows in the voice and the stance, except for NPCs sitting or dancing
	if mood ~= "" and (slot == nil or (slot.act ~= "sit" and slot.act ~= "dance")) then
		CreatureObject(pNpc):setMoodString(mood)
	end

	spatialChat(pNpc, line)
	print("LivingTalk: " .. readStringData(npcKey(oid, "name")) .. " says: " .. line)
end

function LivingTalk:fallback(pNpc)
	local line = nil

	if LivingCitiesLines ~= nil and LivingCitiesLines.fallback ~= nil and #LivingCitiesLines.fallback > 0 then
		line = LivingCitiesLines.fallback[getRandomNumber(1, #LivingCitiesLines.fallback)]
	end

	if line ~= nil then
		spatialChat(pNpc, line)
	else
		CreatureObject(pNpc):doAnimation("shrug_shoulders")
	end
end

-- Back to its errands once the player has been quiet for holdSeconds
function LivingTalk:talkCheck(pNpc, gen)
	if not LivingCities:current(pNpc, gen) then
		return
	end

	local oid = SceneObject(pNpc):getObjectID()

	if readData(npcKey(oid, "state")) ~= TALKING then
		return
	end

	if os.time() < readData(npcKey(oid, "talkUntil")) then
		createEvent(15 * 1000, "LivingTalk", "talkCheck", pNpc, gen)
		return
	end

	deleteData(npcKey(oid, "talkUntil"))
	writeData(npcKey(oid, "state"), LINGERING)
	LivingCities:nextErrand(pNpc, packArgs(gen, readData(npcKey(oid, "seq"))))
end
