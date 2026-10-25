-- Bot players (Phase 5): provoked fights and duels, for every bot. Not a job module: BotJobs calls
-- BotFight:tick(pBot, oid, now) every job tick, BotFight:onReply(pBot, playerOid, flags, channel) after each brain
-- reply (flags from reply line 5, e.g. "insult"), BotFight:onEvent(pBot, oid, name, pOther, detail) for the body's
-- events, and BotFight:clear(oid) at logout.
--
-- Provoked fights: the brain flags a player's line "insult". The insult before the last (insultsToFight within
-- insultWindow seconds, roster.lua's settings) gets a warning; the last starts a real fight (botStartFight: mutual
-- personal enemy flags and combat, patches/bots/BotCombat.h). A town bot fights with what it has: it sets its target
-- (botSetTarget queues a real attack, so auto-attack runs), and walks after the player to stay in reach (botFollow),
-- then back to where it stood. Afterwards it gloats or sulks and won't fight that player again for fightCooldown
-- seconds. Three incaps within ten minutes kill in Core3; the cooldown keeps a bot from getting near.
-- Duels: a /duel challenge (event "duel", "challenged") is accepted with /duel back, and fought to the first incap.
-- The body ends fights and duels itself at the first incap of either side, so nobody is death-blown, and says so
-- ("fightEnded"); this file only ends them itself as a backstop, or when the player runs off or it drags on.
--
-- Other jobs can ask BotFight:busy(oid) (fighting, or walking back after) and BotFight:fighting(oid) (the opponent's
-- oid, or 0), e.g. so a performer doesn't start its song in the middle of a fight.
--
-- Development, bot on bot (the local server has no game client):
--   runLuaFunction BotFight:devInsult:<first>:<from>   bot <from> insults bot <first> (as if the brain flagged it)
--   runLuaFunction BotFight:devDuel:<first>:<from>     bot <from> challenges bot <first> to a duel
--   runLuaFunction BotFight:devList                    every online bot's fight state
--   runLuaFunction BotFight:devInfo:<first>            one bot: combat, target, posture, health and range

BotFight = ScreenPlay:new {
	screenplayName = "BotFight",

	-- roster.lua settings, when it doesn't set them
	defaults = {insultsToFight = 3, insultWindow = 600, fightCooldown = 600},

	-- It fights a player within this range (spatial chat reaches 25 m); further away it tells them to come over
	fightRange = 25,
	-- Core3's /duel reaches 25 m
	duelRange = 25,
	-- Its own line follows the brain's reply this long after (ms)
	lineDelayMs = 2500,
	-- A fight that runs longer than this (seconds), or a player further than this (m), is called off
	maxSeconds = 300,
	leaveRange = 80,
	-- A fight is watched this often (ms), as a backstop: the body ends fights and duels at the first incap itself
	-- ("fightEnded"). Someone down this long (seconds) with no word from the body, and it ends the fight itself
	duelWatchMs = 1000,
	fightWatchMs = 2000,
	backstopSeconds = 5,
	-- A town bot keeps this close (m) to the player in a fight, in reach of its fists (botFollow's near and far)
	fightNear = 2,
	fightFar = 3,
	-- A duel that hasn't started this long (seconds) after the bot's /duel back is given up
	duelStartSeconds = 10,
	-- /endduel is sent again this often (ms), this many times, until Core3 shows the duel over (an incapacitated
	-- bot's command may not go through)
	endRetryMs = 3000,
	endRetries = 20,
	-- The sulk waits until the bot is back on its feet, checking this often (ms), this many times
	upCheckMs = 3000,
	upChecks = 15,
	-- Town bots walk after the player in a fight and back afterwards (the crew and the city folk move themselves)
	townJobs = {doctor = true, dancer = true, musician = true, smuggler = true},
	-- After the fight it waits this long (ms) before walking back, and gives the walk this long (seconds)
	homeDelayMs = 6000,
	returnSeconds = 120,
	-- Jobs that look after their own death (the crew revives or clones itself); others are cloned here and go home
	selfReviving = {tank = true, rifleman = true, medic = true, ranger = true, squadleader = true, entertainer = true, commando = true},
	cloneDelayMs = 10000,
	homeAfterCloneMs = 20000,
}

local PROVOKED, DUEL = 1, 2

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function fkey(oid, field)
	return "bot:" .. oid .. ":fight:" .. field
end

-- Per player: the insults' times and the cooldown
local function pkey(oid, field, playerOid)
	return "bot:" .. oid .. ":fight:" .. field .. ":" .. playerOid
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

local function hasFlag(flags, flag)
	for part in string.gmatch(tostring(flags or ""):lower(), "[^,%s]+") do
		if part == flag then
			return true
		end
	end

	return false
end

local function firstName(pCreature)
	return pCreature ~= nil and CreatureObject(pCreature):getFirstName() or nil
end

local function down(pCreature)
	return pCreature ~= nil and (CreatureObject(pCreature):isIncapacitated() or CreatureObject(pCreature):isDead())
end

function BotFight:setting(name)
	local value = BotJobs:setting(name)

	if value == nil then
		value = self.defaults[name]
	end

	return math.floor(tonumber(value) or self.defaults[name])
end

-- The opponent's oid, or 0
function BotFight:fighting(oid)
	return readData(fkey(oid, "with"))
end

-- Fighting, or walking back after one
function BotFight:busy(oid)
	return readData(fkey(oid, "with")) ~= 0 or readData(fkey(oid, "returning")) > os.time()
end

-- Does this bot walk in its fights?
function BotFight:moves(oid)
	return self.townJobs[BotJobs:job(oid)] == true and botMoveTo ~= nil
end

-- A line of the fight's, now, out loud or by tell, with an emote of that kind
function BotFight:say(pBot, oid, playerOid, channel, kind, mood)
	local pPlayer = getSceneObject(playerOid)

	BotJobs:reply(pBot, playerOid, channel, BotLines:pick("fight", kind, firstName(pPlayer), BotJobs:city(oid)), mood)

	local emotes = BotLines.fightEmotes ~= nil and BotLines.fightEmotes[kind] or nil

	if emotes ~= nil and channel ~= "tell" then
		botEmote(pBot, emotes[getRandomNumber(1, #emotes)], playerOid)
	end
end

-- ...or a moment later (after the brain's reply). upTries > 0: wait until the bot is on its feet
function BotFight:sayLater(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local upTries = tonumber(a[6]) or 0

	if upTries > 0 and down(pBot) then
		createEvent(self.upCheckMs, "BotFight", "sayLater", pBot, packArgs(a[1], a[2], a[3], a[4], a[5], upTries - 1))
		return
	end

	-- A warning overtaken by the last insult (the fight starts instead)
	if a[4] == "warn" and (readData(fkey(oid, "with")) ~= 0 or
		#self:insults(oid, tonumber(a[2]), os.time()) >= math.max(1, self:setting("insultsToFight"))) then
		return
	end

	self:say(pBot, oid, tonumber(a[2]), a[3], a[4], a[5] ~= "-" and a[5] or "")
end

function BotFight:sayIn(pBot, oid, ms, playerOid, channel, kind, mood, upTries)
	createEvent(ms, "BotFight", "sayLater", pBot, packArgs(readData(key(oid, "gen")), playerOid, channel, kind, mood or "-",
		upTries or 0))
end

-- The insults from a player within the window, oldest first
function BotFight:insults(oid, playerOid, now)
	local window = self:setting("insultWindow")
	local out = {}

	for t in string.gmatch(readStringData(pkey(oid, "insults", playerOid)), "%d+") do
		if now - tonumber(t) <= window then
			table.insert(out, tonumber(t))
		end
	end

	return out
end

function BotFight:clearInsults(oid, playerOid)
	deleteStringData(pkey(oid, "insults", playerOid))
end

-- After a brain reply: count an insult, warn, or fight
function BotFight:onReply(pBot, playerOid, flags, channel)
	if pBot == nil or not hasFlag(flags, "insult") then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local now = os.time()
	local pPlayer = getSceneObject(playerOid)

	if pPlayer == nil or readData(fkey(oid, "with")) == playerOid then
		return
	end

	if now < readData(pkey(oid, "cd", playerOid)) then
		print("BotJobs: " .. BotJobs:name(oid) .. " insulted by " .. firstName(pPlayer) .. ", not again so soon")
		return
	end

	local times = self:insults(oid, playerOid, now)
	local need = math.max(1, self:setting("insultsToFight"))

	table.insert(times, now)

	while #times > need do
		table.remove(times, 1)
	end

	writeStringData(pkey(oid, "insults", playerOid), table.concat(times, ","))

	print("BotJobs: " .. BotJobs:name(oid) .. " insulted by " .. firstName(pPlayer) .. " (" .. #times .. " of " .. need .. ")")

	if #times >= need then
		createEvent(self.lineDelayMs, "BotFight", "provoked", pBot, packArgs(readData(key(oid, "gen")), playerOid, channel))
	elseif #times == need - 1 then
		self:sayIn(pBot, oid, self.lineDelayMs, playerOid, channel, "warn", "angry")
	end
end

-- Why it can't fight this player now, or nil
function BotFight:cannotFight(pBot, oid, pPlayer, range)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local with = readData(fkey(oid, "with"))

	if with ~= 0 then
		return with == playerOid and "already" or "busy"
	end

	if down(pBot) or down(pPlayer) then
		return "down"
	end

	if os.time() < readData(pkey(oid, "cd", playerOid)) then
		return "cooldown"
	end

	local dist = BotJobs:distance(pBot, pPlayer)

	if dist == nil or dist > range then
		return "far"
	end

	return nil
end

-- The last insult: the fight (a moment after the brain's reply)
function BotFight:provoked(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local playerOid, channel = tonumber(a[2]), a[3]
	local pPlayer = getSceneObject(playerOid)

	if pPlayer == nil then
		return
	end

	if botStartFight == nil then
		print("BotJobs: " .. BotJobs:name(oid) .. " would fight " .. firstName(pPlayer) .. ", but this build has no fights")
		return
	end

	local why = self:cannotFight(pBot, oid, pPlayer, self.fightRange)

	if why == "far" then
		-- The count stands: the next insult in reach starts it
		self:say(pBot, oid, playerOid, channel, "faceMe", "angry")
		return
	elseif why ~= nil then
		print("BotJobs: " .. BotJobs:name(oid) .. " won't fight " .. firstName(pPlayer) .. " now (" .. why .. ")")
		return
	end

	botFace(pBot, pPlayer)
	self:say(pBot, oid, playerOid, "spatial", "start", "angry")

	if not botStartFight(pBot, pPlayer) then
		print("BotJobs: " .. BotJobs:name(oid) .. " couldn't start a fight with " .. firstName(pPlayer))
		return
	end

	self:begin(pBot, oid, pPlayer, PROVOKED)
end

-- A fight has started (provoked, or a duel the bot accepted): remember it, go at them, watch it
function BotFight:begin(pBot, oid, pPlayer, kind)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local now = os.time()

	writeData(fkey(oid, "with"), playerOid)
	writeData(fkey(oid, "kind"), kind)
	writeData(fkey(oid, "since"), now)
	writeData(fkey(oid, "lastTarget"), now)
	self:clearInsults(oid, playerOid)

	-- Where it stood, to walk back to (kept if it was still walking back from the last fight)
	if readData(fkey(oid, "returning")) <= now or readStringData(fkey(oid, "home")) == "" then
		local o = SceneObject(pBot)

		writeStringData(fkey(oid, "home"), string.format("%.3f:%.3f:%.3f:%d", o:getPositionX(), o:getPositionZ(),
			o:getPositionY(), o:getParentID()))
	end

	deleteData(fkey(oid, "returning"))

	if botSetTarget ~= nil then
		botSetTarget(pBot, playerOid)
	end

	if self:moves(oid) and botFollow ~= nil then
		botFollow(pBot, pPlayer, self.fightNear, self.fightFar)
	end

	print("BotJobs: " .. BotJobs:name(oid) .. " fights " .. firstName(pPlayer) .. (kind == DUEL and " (a duel)" or " (provoked)"))

	self:watchAgain(pBot, oid)
end

-- A new watch chain (the old one, if any, stops)
function BotFight:watchAgain(pBot, oid)
	local seq = readData(fkey(oid, "seq")) + 1
	local ms = readData(fkey(oid, "kind")) == DUEL and self.duelWatchMs or self.fightWatchMs

	writeData(fkey(oid, "seq"), seq)
	writeData(fkey(oid, "beat"), os.time())
	createEvent(ms, "BotFight", "watch", pBot, packArgs(readData(key(oid, "gen")), seq))
end

function BotFight:watch(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if readData(fkey(oid, "seq")) ~= tonumber(a[2]) or readData(fkey(oid, "with")) == 0 then
		return
	end

	writeData(fkey(oid, "beat"), os.time())

	local result = self:check(pBot, oid)

	if result ~= nil then
		self:finish(pBot, oid, result, false)
		return
	end

	createEvent(readData(fkey(oid, "kind")) == DUEL and self.duelWatchMs or self.fightWatchMs, "BotFight", "watch", pBot, args)
end

-- How the fight stands: nil while it goes on, else "humanIncap", "botIncap", "ended" or "notStarted"
function BotFight:check(pBot, oid)
	local withOid, kind = readData(fkey(oid, "with")), readData(fkey(oid, "kind"))
	local pOther = getSceneObject(withOid)
	local now = os.time()

	if pOther == nil then
		return "ended"
	end

	-- Someone's down: the body ends it and says so; if it hasn't in a few seconds, this does
	local downResult = down(pOther) and "humanIncap" or (down(pBot) and "botIncap" or nil)

	if downResult ~= nil then
		local since = readData(fkey(oid, "downSince"))

		if since == 0 then
			writeData(fkey(oid, "downSince"), now)
		elseif now - since >= self.backstopSeconds then
			return downResult
		end

		return nil
	end

	deleteData(fkey(oid, "downSince"))

	if kind == DUEL then
		local state = botDuelState ~= nil and botDuelState(pBot, pOther) or "none"

		if state == "none" then
			return "ended"
		elseif state ~= "dueling" and now - readData(fkey(oid, "since")) > self.duelStartSeconds then
			return "notStarted"
		end
	end

	local dist = BotJobs:distance(pBot, pOther)

	if dist == nil or dist > self.leaveRange or now - readData(fkey(oid, "since")) > self.maxSeconds then
		return "ended"
	end

	-- Keep at it: the target again if its combat dropped
	if botSetTarget ~= nil and not CreatureObject(pBot):isInCombat() and now - readData(fkey(oid, "lastTarget")) >= 5 then
		writeData(fkey(oid, "lastTarget"), now)
		botSetTarget(pBot, withOid)
	end

	return nil
end

-- The fight is over. byBody: the body ended it already ("fightEnded"); otherwise the bot ends it here.
function BotFight:finish(pBot, oid, result, byBody)
	local withOid, kind = readData(fkey(oid, "with")), readData(fkey(oid, "kind"))

	if withOid == 0 then
		return
	end

	local pOther = getSceneObject(withOid)
	local now = os.time()
	local incap = result == "humanIncap" or result == "botIncap"

	-- Forget it first: the calls below may come back here as events
	deleteData(fkey(oid, "with"))
	deleteData(fkey(oid, "kind"))
	deleteData(fkey(oid, "downSince"))
	writeData(fkey(oid, "seq"), readData(fkey(oid, "seq")) + 1)
	self:clearInsults(oid, withOid)

	-- No fight with them for a while after a provoked one, or after anyone went down
	if kind == PROVOKED or incap then
		writeData(pkey(oid, "cd", withOid), now + self:setting("fightCooldown"))
	end

	if botSetTarget ~= nil then
		botSetTarget(pBot, 0)
	end

	if not byBody then
		-- The body hasn't ended it: this does (botEndFight ends a duel too; /endduel as well, in case)
		if botEndFight ~= nil and pOther ~= nil then
			botEndFight(pBot, pOther)
		end

		if kind == DUEL then
			self:endDuel(pBot, oid, withOid)
		end
	end

	if botStop ~= nil and self:moves(oid) then
		botStop(pBot)
	end

	print("BotJobs: " .. BotJobs:name(oid) .. "'s " .. (kind == DUEL and "duel" or "fight") .. " with " ..
		tostring(firstName(pOther) or withOid) .. " is over: " .. result)

	-- Its line: gloat or sulk (once it's up again)
	local lines = kind == DUEL and {humanIncap = "duelWon", botIncap = "duelLost", ended = "duelEnded"} or
		{humanIncap = "gloat", botIncap = "sulk", ended = "ended"}
	local moods = {humanIncap = "happy", botIncap = "sad", ended = "angry"}

	if lines[result] ~= nil and pOther ~= nil then
		self:sayIn(pBot, oid, 2000, withOid, "spatial", lines[result], moods[result], result == "botIncap" and self.upChecks or 0)
	end

	-- Then back to where it stood
	if self:moves(oid) and readStringData(fkey(oid, "home")) ~= "" then
		writeData(fkey(oid, "returning"), now + self.returnSeconds)
		createEvent(self.homeDelayMs, "BotFight", "goHome", pBot, packArgs(readData(key(oid, "gen")), self.upChecks))
	end
end

-- /endduel, and again until Core3 shows the duel over
function BotFight:endDuel(pBot, oid, withOid)
	local pOther = getSceneObject(withOid)

	if pOther == nil or botDuelState == nil or botDuelState(pBot, pOther) == "none" then
		return
	end

	botEnqueue(pBot, "endduel", withOid, "")
	createEvent(self.endRetryMs, "BotFight", "endDuelRetry", pBot, packArgs(readData(key(oid, "gen")), withOid, self.endRetries))
end

function BotFight:endDuelRetry(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local withOid, tries = tonumber(a[2]), tonumber(a[3]) or 0
	local pOther = getSceneObject(withOid)

	-- Over, or a new duel with them
	if pOther == nil or botDuelState == nil or botDuelState(pBot, pOther) == "none" or readData(fkey(oid, "with")) == withOid then
		return
	end

	botEnqueue(pBot, "endduel", withOid, "")

	if tries > 1 then
		createEvent(self.endRetryMs, "BotFight", "endDuelRetry", pBot, packArgs(a[1], withOid, tries - 1))
	else
		print("BotJobs: " .. BotJobs:name(oid) .. " couldn't end its duel with " .. tostring(firstName(pOther)))
	end
end

-- Walk back to where it stood when the fight started (once it's on its feet)
function BotFight:goHome(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local tries = tonumber(a[2]) or 0

	if readData(fkey(oid, "with")) ~= 0 then
		return
	end

	if down(pBot) then
		if tries > 0 then
			writeData(fkey(oid, "returning"), os.time() + self.returnSeconds)
			createEvent(self.upCheckMs, "BotFight", "goHome", pBot, packArgs(a[1], tries - 1))
		end

		return
	end

	local home = unpackArgs(readStringData(fkey(oid, "home")))
	local x, z, y, cell = tonumber(home[1]), tonumber(home[2]), tonumber(home[3]), math.floor(tonumber(home[4]) or 0)

	if x == nil or z == nil or y == nil then
		deleteData(fkey(oid, "returning"))
		return
	end

	local o = SceneObject(pBot)

	if o:getParentID() == cell and math.abs(o:getPositionX() - x) < 1.5 and math.abs(o:getPositionY() - y) < 1.5 then
		-- Never left
		self:arrived(oid)
		return
	end

	if not botMoveTo(pBot, x, z, y, cell) then
		self:teleportHome(pBot, oid)
	end
end

function BotFight:arrived(oid)
	deleteData(fkey(oid, "returning"))
	deleteStringData(fkey(oid, "home"))
end

-- Straight back (the walk failed or took too long, or after cloning)
function BotFight:teleportHome(pBot, oid)
	local home = unpackArgs(readStringData(fkey(oid, "home")))
	local x, z, y, cell = tonumber(home[1]), tonumber(home[2]), tonumber(home[3]), math.floor(tonumber(home[4]) or 0)

	if x == nil then
		-- No spot of its own from a fight: its roster station
		local entry = BotJobs:entry(readStringData(key(oid, "first"))) or {}
		local s = entry.station

		if s == nil then
			self:arrived(oid)
			return
		end

		x, z, y, cell = s.x, s.z, s.y, s.cell or 0
	end

	if botStop ~= nil then
		botStop(pBot)
	end

	SceneObject(pBot):teleport(x, z, y, cell)
	print("BotJobs: " .. BotJobs:name(oid) .. " is back at its spot")
	self:arrived(oid)
end

-- From BotJobs:tick every few seconds: a fight's watch chain that died (BotJobs:restart) starts again; a walk back
-- that didn't arrive in time ends at the spot
function BotFight:tick(pBot, oid, now)
	if readData(fkey(oid, "with")) ~= 0 then
		if now - readData(fkey(oid, "beat")) > 4 then
			self:watchAgain(pBot, oid)
		end

		return
	end

	local returning = readData(fkey(oid, "returning"))

	if returning ~= 0 and now >= returning then
		self:teleportHome(pBot, oid)
	end
end

-- The body's events (BotJobs:onEvent)
function BotFight:onEvent(pBot, oid, name, pOther, detail)
	if name == "fightEnded" then
		-- The body ended a fight or a duel (an incap, botEndFight, a logout, too far, too long, /endduel)
		local result = detail

		if result ~= "humanIncap" and result ~= "botIncap" then
			result = "ended"
		end

		if pOther == nil or readData(fkey(oid, "with")) == SceneObject(pOther):getObjectID() then
			self:finish(pBot, oid, result, true)
		end
	elseif name == "duel" then
		self:duel(pBot, oid, pOther, detail)
	elseif name == "died" then
		self:died(pBot, oid)
	elseif name == "cloned" then
		self:cloned(pBot, oid)
	elseif name == "arrived" or name == "stuck" then
		if readData(fkey(oid, "returning")) ~= 0 and readData(fkey(oid, "with")) == 0 then
			if name == "stuck" then
				self:teleportHome(pBot, oid)
			else
				self:arrived(oid)
			end
		end
	end
end

-- The body's duel news: "challenged" (accept it) or "started" (the duel is on: go at them)
function BotFight:duel(pBot, oid, pOther, detail)
	if pOther == nil or botDuelState == nil then
		return
	end

	local otherOid = SceneObject(pOther):getObjectID()
	local state = botDuelState(pBot, pOther)

	if state == "challenged" then
		self:acceptDuel(pBot, oid, pOther)
	elseif state == "dueling" then
		if readData(fkey(oid, "with")) == 0 then
			-- A duel it didn't accept here (the bot challenged them, say): it's on all the same
			self:begin(pBot, oid, pOther, DUEL)
		elseif readData(fkey(oid, "with")) == otherOid and botSetTarget ~= nil then
			-- Now it may attack them
			writeData(fkey(oid, "lastTarget"), os.time())
			botSetTarget(pBot, otherOid)
		end
	elseif state == "none" and readData(fkey(oid, "with")) == otherOid and readData(fkey(oid, "kind")) == DUEL then
		self:finish(pBot, oid, "ended", true)
	end
end

function BotFight:acceptDuel(pBot, oid, pOther)
	local otherOid = SceneObject(pOther):getObjectID()
	local why = self:cannotFight(pBot, oid, pOther, self.duelRange)

	if why == "busy" then
		self:say(pBot, oid, otherOid, "spatial", "busy", "")
		return
	elseif why == "cooldown" then
		self:say(pBot, oid, otherOid, "spatial", "tooSoon", "")
		return
	elseif why ~= nil then
		print("BotJobs: " .. BotJobs:name(oid) .. " won't duel " .. firstName(pOther) .. " now (" .. why .. ")")
		return
	end

	-- A third incap within ten minutes kills (Core3): a duel ends at the first incap, so it can't start at two
	if botRecentIncaps ~= nil and botRecentIncaps(pOther) >= 2 then
		self:say(pBot, oid, otherOid, "spatial", "tooHurt", "")
		return
	end

	botFace(pBot, pOther)
	botEnqueue(pBot, "duel", otherOid, "")
	self:say(pBot, oid, otherOid, "spatial", "duelAccept", "")
	self:begin(pBot, oid, pOther, DUEL)
end

-- Dead (a deathblow, three incaps): the crew looks after itself; anyone else clones and comes back
function BotFight:died(pBot, oid)
	if readData(fkey(oid, "with")) ~= 0 then
		self:finish(pBot, oid, "botIncap", false)
	end

	local job = BotJobs:job(oid)
	local module = BotJobs:module(job)

	if self.selfReviving[job] or (module ~= nil and module.handlesDeath) then
		return
	end

	if botClone == nil then
		print("BotJobs: " .. BotJobs:name(oid) .. " died, and this build can't clone it")
		return
	end

	print("BotJobs: " .. BotJobs:name(oid) .. " died; cloning")
	createEvent(self.cloneDelayMs, "BotFight", "clone", pBot, tostring(readData(key(oid, "gen"))))
end

function BotFight:clone(pBot, gen)
	if BotJobs:current(pBot, gen) and CreatureObject(pBot):isDead() then
		botClone(pBot)
	end
end

-- Cloned: a little later it's back at its spot, and its job starts afresh
function BotFight:cloned(pBot, oid)
	local job = BotJobs:job(oid)
	local module = BotJobs:module(job)

	if self.selfReviving[job] or (module ~= nil and module.handlesDeath) then
		return
	end

	createEvent(self.homeAfterCloneMs, "BotFight", "backFromCloning", pBot, tostring(readData(key(oid, "gen"))))
end

function BotFight:backFromCloning(pBot, gen)
	if not BotJobs:current(pBot, gen) then
		return
	end

	self:teleportHome(pBot, SceneObject(pBot):getObjectID())
	createEvent(1000, "BotJobs", "onLogin", pBot, "")
end

-- Logging out: the fight ends with it (cooldowns and insults are kept; they run on the clock)
function BotFight:clear(oid)
	local withOid, kind = readData(fkey(oid, "with")), readData(fkey(oid, "kind"))
	local pBot = getSceneObject(oid)
	local pOther = getSceneObject(withOid)

	deleteData(fkey(oid, "with"))
	deleteData(fkey(oid, "kind"))
	deleteData(fkey(oid, "returning"))
	deleteStringData(fkey(oid, "home"))
	writeData(fkey(oid, "seq"), readData(fkey(oid, "seq")) + 1)

	if withOid == 0 or pBot == nil or pOther == nil then
		return
	end

	-- (the body ends a logged-out bot's fights too; this is in case)
	if botEndFight ~= nil then
		botEndFight(pBot, pOther)
	end

	if kind == DUEL then
		botEnqueue(pBot, "endduel", withOid, "")
	end
end

-- "" or ", fighting <name>" / ", walking back", for the jobs' state lines
function BotFight:describe(oid)
	local withOid = readData(fkey(oid, "with"))

	if withOid ~= 0 then
		local pOther = getSceneObject(withOid)

		return ", " .. (readData(fkey(oid, "kind")) == DUEL and "dueling " or "fighting ") .. tostring(firstName(pOther) or withOid)
	end

	if readData(fkey(oid, "returning")) > os.time() then
		return ", walking back"
	end

	return ""
end

-- Development, bot on bot

function BotFight:devInsult(first, from)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil
	local pFrom = botGetCreature ~= nil and botGetCreature(from or "") or nil

	if pBot == nil or pFrom == nil then
		print("BotJobs: usage devInsult:<bot>:<from bot>, both online")
		return
	end

	createEvent(10, "BotFight", "devInsulted", pBot, tostring(SceneObject(pFrom):getObjectID()))
end

function BotFight:devInsulted(pBot, fromOid)
	self:onReply(pBot, tonumber(fromOid), "insult", "spatial")
end

-- <from> sends /duel at <first>; the body's "duel" event does the rest
function BotFight:devDuel(first, from)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil
	local pFrom = botGetCreature ~= nil and botGetCreature(from or "") or nil

	if pBot == nil or pFrom == nil then
		print("BotJobs: usage devDuel:<bot>:<from bot>, both online")
		return
	end

	print("BotJobs: " .. tostring(from) .. " challenges " .. tostring(first) .. ": " ..
		tostring(botEnqueue(pFrom, "duel", SceneObject(pBot):getObjectID(), "")))
end

function BotFight:devList()
	for _, bot in ipairs(botList ~= nil and botList() or {}) do
		local oid = tonumber(bot.oid) or 0

		if bot.online then
			local state = self:describe(oid)

			print("BotJobs:   " .. tostring(bot.name) .. ": " .. (state == "" and "at peace" or state:sub(3)))
		end
	end
end

function BotFight:devInfo(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: no online bot called " .. tostring(first))
		return
	end

	local bot = CreatureObject(pBot)
	local oid = SceneObject(pBot):getObjectID()
	local withOid = readData(fkey(oid, "with"))
	local text = first .. ": inCombat " .. tostring(bot:isInCombat()) .. ", posture " .. tostring(bot:getPosture()) ..
		", target " .. tostring(bot:getTargetID()) .. ", with " .. tostring(withOid) .. ", health " ..
		tostring(bot:getHAM(0)) .. "/" .. tostring(bot:getMaxHAM(0))
	local pWith = withOid ~= 0 and getSceneObject(withOid) or nil

	if pWith ~= nil then
		text = text .. ", range " .. string.format("%.1f", SceneObject(pBot):getDistanceTo(pWith))
	end

	print("BotJobs: " .. text)
end
