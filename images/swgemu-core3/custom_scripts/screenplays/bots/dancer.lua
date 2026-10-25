-- Bot players (Phase 3, with Phase 8's band): the master dancer. It dances on its cantina's floor the whole time it's online, like an AFK
-- dancer in 2004: startdance at login, a flourish every 20-40 s, another dance every 10-20 minutes. Core3's own
-- entertaining session heals its watchers' battle fatigue and mind wounds. Asked for a buff, it makes the player its
-- buff target (setperformancebufftarget), and the mind buff lands when they stop watching. Driven by BotJobs
-- (bot_jobs.lua); every step is an event on the bot.

local ACTION = 3 -- CreatureAttribute::ACTION

BotDancer = ScreenPlay:new {
	screenplayName = "BotDancer",

	-- The master dancer's dances that heal best (performance.iff: 12-14 mind and 7 battle fatigue a tick, which a
	-- master dancer in a cantina turns into about 8)
	dances = {"exotic4", "exotic3", "lyrical2"},

	flourishEvery = {20, 40},
	changeEvery = {600, 1200},
	-- Seconds before a dance that didn't start (or stopped) is started again
	restartGap = 15,
	-- Dancing costs action every loop; below this share of it (percent) the dancer's action is topped up, so the dance
	-- never stops for tiredness
	actionFloor = 30,
	-- A player who asks from further than this (or another planet) is made the buff target when they come within it,
	-- if that's within pendingSeconds
	targetRange = 30,
	pendingSeconds = 120,
}

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function between(range)
	return getRandomNumber(range[1], range[2])
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

-- The cantina band (Phase 8, specs/2026-10-25-full-group/): a city's dancer and musician play as one. The musician plays
-- and the dancer dances together, and they flourish together (the first to come due flourishes and sets its partner's
-- flourish a moment behind it; a round ends when both have, and the next comes due after bandFlourish seconds). Asked for a
-- buff, either one makes the player its buff target and gets its partner to as well, which says to listen (or watch) too.
-- The band is not a Core3 group (a group needs a leader, and a bot never leads): Core3 stacks the two healings as it
-- always has, and the buffs are the dancer's mind buff and the musician's focus and willpower. A city's pair only; a bot
-- whose partner is offline keeps its own timers.
BotBand = ScreenPlay:new {
	screenplayName = "BotBand",

	bandFlourish = {20, 40},
	-- The cantina bands: these three cities only (Varenhal's dancer and musician stay as they were)
	bandCities = {mos_eisley = true, coronet = true, theed = true},
	-- The partner's flourish and buff set-up follow the first by this long (ms)
	followMs = 800,
	joinMs = 1200,
}

local function bandKey(city, field)
	return "band:" .. city .. ":" .. field
end

-- The other half of the band: an online musician for a dancer and a dancer for a musician in the same cantina city. Its
-- creature and oid, or nil
function BotBand:partner(oid)
	local city = BotJobs:city(oid)
	local job = BotJobs:job(oid)
	local want = job == "dancer" and "musician" or (job == "musician" and "dancer" or nil)

	if want == nil or city == nil or not self.bandCities[city] or botList == nil then
		return nil
	end

	for _, entry in ipairs(botList() or {}) do
		if entry.job == want and entry.city == city and entry.online and entry.oid ~= 0 then
			local pPartner = getSceneObject(entry.oid)

			if pPartner ~= nil then
				return pPartner, entry.oid
			end
		end
	end

	return nil
end

local function performing(pBot)
	local creature = CreatureObject(pBot)

	return creature:isDancing() or creature:isPlayingMusic()
end

-- Is it time for this bot's flourish? nil without a band (its own timer then), else true once per round for each of the two.
-- The first to come due flourishes now and the partner follows moments later.
function BotBand:flourishDue(pBot, oid, now)
	local pPartner, partnerOid = self:partner(oid)

	if pPartner == nil or not performing(pPartner) then
		return nil
	end

	local city = BotJobs:city(oid)
	local round = readData(bandKey(city, "round")) + 1
	local due = readData(bandKey(city, "due"))

	if due == 0 then
		due = now + between(self.bandFlourish)
		writeData(bandKey(city, "due"), due)
	end

	if now < due or readData(key(oid, "bandRound")) == round then
		return false
	end

	writeData(key(oid, "bandRound"), round)

	if readData(key(partnerOid, "bandRound")) == round then
		self:endRound(city, round, now)
	else
		createEvent(self.followMs, "BotBand", "partnerFlourish", pPartner, packArgs(readData(key(partnerOid, "gen")), round))
	end

	return true
end

function BotBand:endRound(city, round, now)
	writeData(bandKey(city, "round"), round)
	writeData(bandKey(city, "due"), now + between(self.bandFlourish))
end

function BotBand:partnerFlourish(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) or not performing(pBot) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local round = tonumber(a[2])

	if readData(key(oid, "bandRound")) == round then
		return
	end

	writeData(key(oid, "bandRound"), round)
	botEnqueue(pBot, "flourish", 0, tostring(getRandomNumber(1, 8)))
	writeData(key(oid, "flourishes"), readData(key(oid, "flourishes")) + 1)
	self:endRound(BotJobs:city(oid), round, os.time())
end

-- Asked for a buff, the asked one has made the player its buff target; its partner does the same a moment later, with a line
-- of its own (the dancer: watch, the musician: listen)
function BotBand:askPartner(pBot, oid, pPatient)
	local pPartner, partnerOid = self:partner(oid)

	if pPartner == nil then
		return
	end

	createEvent(self.joinMs, "BotBand", "partnerBuff", pPartner, packArgs(readData(key(partnerOid, "gen")), SceneObject(pPatient):getObjectID()))
end

function BotBand:partnerBuff(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local patientOid = tonumber(a[2])
	local pPatient = getSceneObject(patientOid)
	local job = BotJobs:job(oid)
	local module = BotJobs:module(job)

	if pPatient == nil or module == nil or module.buffTarget == nil or not performing(pBot) then
		return
	end

	-- (silent: the line below is the partner's)
	module:buffTarget(pBot, pPatient, "spatial", true)

	if readData(key(oid, "buffTarget")) == patientOid then
		BotJobs:reply(pBot, patientOid, "spatial", BotLines:pick(job, "band", CreatureObject(pPatient):getFirstName(), BotJobs:city(oid)))
		print("BotJobs: " .. BotJobs:name(oid) .. " joins the band's buff for " .. CreatureObject(pPatient):getFirstName())
	end
end

-- A dance other than the current one
function BotDancer:pickDance(current)
	local choices = {}

	for _, dance in ipairs(self.dances) do
		if dance ~= current then
			table.insert(choices, dance)
		end
	end

	if #choices == 0 then
		return self.dances[1]
	end

	return choices[getRandomNumber(1, #choices)]
end

-- Logging in: start dancing (after BotJobs:restart it may be dancing already: it carries on)
function BotDancer:start(pBot, oid)
	local now = os.time()
	local dancing = CreatureObject(pBot):isDancing()
	local dance = readStringData(key(oid, "dance"))

	if not dancing or dance == "" then
		dance = self:pickDance("")
	end

	self:clear(oid)
	writeStringData(key(oid, "dance"), dance)
	writeData(key(oid, "startedAt"), now)
	writeData(key(oid, "nextFlourish"), now + between(self.flourishEvery))
	writeData(key(oid, "nextChange"), now + between(self.changeEvery))

	self:topUpAction(pBot)

	if not dancing then
		botEnqueue(pBot, "startdance", 0, dance)
	end
end

function BotDancer:clear(oid)
	deleteData(key(oid, "pendingTarget"))
	deleteData(key(oid, "buffTarget"))
	deleteData(key(oid, "retarget"))
	deleteData(key(oid, "restarts"))
	deleteData(key(oid, "flourishes"))
end

function BotDancer:topUpAction(pBot)
	local creature = CreatureObject(pBot)
	local full = creature:getMaxHAM(ACTION) - botGetWounds(pBot, ACTION)

	if creature:getHAM(ACTION) * 100 < full * self.actionFloor then
		creature:setHAM(ACTION, full)
	end
end

-- From BotJobs:tick every few seconds
function BotDancer:tick(pBot, oid, now)
	self:topUpAction(pBot)
	self:checkPending(pBot, oid, now)

	if not CreatureObject(pBot):isDancing() then
		-- Not started yet, or stopped: start again, and set the buff target again (stopping drops it)
		if now - readData(key(oid, "startedAt")) >= self.restartGap then
			local dance = readStringData(key(oid, "dance"))
			local restarts = readData(key(oid, "restarts")) + 1

			if dance == "" then
				dance = self:pickDance("")
				writeStringData(key(oid, "dance"), dance)
			end

			botEnqueue(pBot, "startdance", 0, dance)
			writeData(key(oid, "startedAt"), now)
			writeData(key(oid, "restarts"), restarts)

			if readData(key(oid, "buffTarget")) ~= 0 then
				writeData(key(oid, "retarget"), 1)
			end

			if restarts <= 3 or restarts % 20 == 0 then
				print("BotJobs: " .. BotJobs:name(oid) .. " wasn't dancing, starting " .. dance .. " again (" .. restarts .. ")")
			end
		end

		return
	end

	if readData(key(oid, "retarget")) == 1 then
		writeData(key(oid, "retarget"), 0)
		botEnqueue(pBot, "setperformancebufftarget", readData(key(oid, "buffTarget")), "")
	end

	if now >= readData(key(oid, "nextChange")) then
		local dance = self:pickDance(readStringData(key(oid, "dance")))

		botEnqueue(pBot, "changedance", 0, dance)
		writeStringData(key(oid, "dance"), dance)
		writeData(key(oid, "nextChange"), now + between(self.changeEvery))
		return
	end

	-- Flourishes: with the band, together with the musician; alone, on its own timer
	local together = BotBand:flourishDue(pBot, oid, now)

	if together == true or (together == nil and now >= readData(key(oid, "nextFlourish"))) then
		botEnqueue(pBot, "flourish", 0, tostring(getRandomNumber(1, 8)))
		writeData(key(oid, "nextFlourish"), now + between(self.flourishEvery))
		writeData(key(oid, "flourishes"), readData(key(oid, "flourishes")) + 1)
	end
end

-- A player asked for a buff: make them the buff target and tell them to watch. brainLine: what the language model
-- answered them (it tells them to watch, or to come over), nil if it didn't.
function BotDancer:buffTarget(pBot, pPatient, channel, brainLine)
	local oid = SceneObject(pBot):getObjectID()
	local patientOid = SceneObject(pPatient):getObjectID()
	local patientName = CreatureObject(pPatient):getFirstName()
	local dist = BotJobs:distance(pBot, pPatient)

	if dist ~= nil and dist <= self.targetRange then
		self:setTarget(pBot, oid, pPatient, channel, brainLine ~= nil)
		return
	end

	-- Not here yet: their turn when they come in (the latest asker wins; there is one buff target)
	writeData(key(oid, "pendingTarget"), patientOid)
	writeData(key(oid, "pendingUntil"), os.time() + self.pendingSeconds)
	writeData(key(oid, "pendingSpoke"), brainLine ~= nil and 1 or 0)

	print("BotJobs: " .. BotJobs:name(oid) .. " waits for " .. patientName .. " to come and watch")

	if brainLine == nil then
		BotJobs:reply(pBot, patientOid, channel, BotLines:pick("dancer", "far", patientName, BotJobs:city(oid)))
	end
end

function BotDancer:setTarget(pBot, oid, pPatient, channel, spoke)
	local patientOid = SceneObject(pPatient):getObjectID()
	local patientName = CreatureObject(pPatient):getFirstName()
	local previous = readData(key(oid, "buffTarget"))

	botEnqueue(pBot, "setperformancebufftarget", patientOid, "")
	writeData(key(oid, "buffTarget"), patientOid)
	writeData(key(oid, "lastPatient"), patientOid)
	writeData(key(oid, "lastPatientAt"), os.time())

	print("BotJobs: " .. BotJobs:name(oid) .. " buff target " .. patientName ..
		((previous ~= 0 and previous ~= patientOid) and (", instead of " .. previous) or ""))

	if not spoke then
		BotJobs:reply(pBot, patientOid, channel, BotLines:pick("dancer", "watch", patientName, BotJobs:city(oid)))
	end
end

-- A player who asked from afar and has come in becomes the buff target; after pendingSeconds they're forgotten
function BotDancer:checkPending(pBot, oid, now)
	local patientOid = readData(key(oid, "pendingTarget"))

	if patientOid == 0 then
		return
	end

	local pPatient = getSceneObject(patientOid)
	local dist = BotJobs:distance(pBot, pPatient)

	if dist ~= nil and dist <= self.targetRange then
		deleteData(key(oid, "pendingTarget"))
		-- They're here now: said out loud
		self:setTarget(pBot, oid, pPatient, "spatial", readData(key(oid, "pendingSpoke")) == 1)
	elseif now >= readData(key(oid, "pendingUntil")) then
		deleteData(key(oid, "pendingTarget"))
		print("BotJobs: " .. BotJobs:name(oid) .. " stops waiting for " ..
			(pPatient ~= nil and CreatureObject(pPatient):getFirstName() or tostring(patientOid)))
	end
end

-- For BotJobs:list
function BotDancer:state(pBot, oid)
	local state = (pBot ~= nil and CreatureObject(pBot):isDancing()) and "dancing" or "not dancing"
	local target = readData(key(oid, "buffTarget"))

	state = state .. " " .. readStringData(key(oid, "dance")) .. ", " .. readData(key(oid, "flourishes")) .. " flourishes"

	if readData(key(oid, "restarts")) > 0 then
		state = state .. ", " .. readData(key(oid, "restarts")) .. " restarts"
	end

	if target ~= 0 then
		local pTarget = getSceneObject(target)

		state = state .. ", buff target " .. (pTarget ~= nil and CreatureObject(pTarget):getFirstName() or tostring(target))
	end

	return state
end

-- The job module interface (bot_jobs.lua)

-- "bufftarget", "watchHint" for battle fatigue or wounds, or nil
function BotDancer:intent(text)
	local t = text:lower()

	if t:find("buff", 1, true) ~= nil then
		return "bufftarget"
	elseif t:find("fatigue", 1, true) ~= nil or t:find("wound", 1, true) ~= nil or t:find("heal", 1, true) ~= nil then
		return "watchHint"
	end

	return nil
end

function BotDancer:isAction(intent)
	return intent == "bufftarget"
end

function BotDancer:allowed(action)
	if action == "bufftarget" or action == "buff" then
		return "bufftarget"
	end

	return nil
end

function BotDancer:act(pBot, pPlayer, action, channel, brainLine)
	if action == "bufftarget" then
		self:buffTarget(pBot, pPlayer, channel, brainLine)
		BotBand:askPartner(pBot, SceneObject(pBot):getObjectID(), pPlayer)
	end
end

BotJobModules = BotJobModules or {}
BotJobModules.dancer = BotDancer
