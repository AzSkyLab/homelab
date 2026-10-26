-- Bot players (Phase 4): the master musician beside each cantina's dancer. It plays a hand-held instrument (the
-- roster's outfit puts it in hold_r) the whole time it's online: startmusic with a song name at login, a flourish
-- every 20-40 s, another song every 10-20 minutes, and a fresh start if the music stops (after the 15 s outro, which
-- Core3 counts as still playing). Core3's own entertaining session heals its listeners' battle fatigue and mind
-- wounds; listening and watching are separate, so with the dancer it heals twice as fast. Asked for a buff, it makes
-- the player its buff target (setperformancebufftarget), and the focus and willpower buffs land when they stop
-- listening. It never sits or stands (that would end the song) and keeps its action topped up. It doesn't play
-- while it's in a fight (fight.lua). Driven by BotJobs (bot_jobs.lua); every step is an event on the bot.

local ACTION = 3 -- CreatureAttribute::ACTION

BotMusician = ScreenPlay:new {
	screenplayName = "BotMusician",

	-- What the talk bridge knows the job as (Phase 2's kits and places)
	kit = "entertainer",
	place = "cantina",

	-- The songs that heal best on every instrument (performance.iff: virtuoso 14 mind / 7 battle fatigue a tick,
	-- jazz and waltz 12/6)
	songs = {"virtuoso", "jazz", "waltz"},

	flourishEvery = {20, 40},
	changeEvery = {600, 1200},
	-- Seconds before a song that didn't start (or stopped) is started again. Core3's /stopmusic outro is 15 s, and
	-- isPlayingMusic() stays true through it, so this only spaces out the attempts
	restartGap = 15,
	-- Playing costs action every loop; below this share of it (percent) the musician's action is topped up, so the
	-- song never stops for tiredness
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

-- A song other than the current one
function BotMusician:pickSong(current)
	local choices = {}

	for _, song in ipairs(self.songs) do
		if song ~= current then
			table.insert(choices, song)
		end
	end

	if #choices == 0 then
		return self.songs[1]
	end

	return choices[getRandomNumber(1, #choices)]
end

-- Fighting, out cold or dead: no music (combat stops a performance, and startmusic would fail)
function BotMusician:canPlay(pBot, oid)
	local creature = CreatureObject(pBot)

	if creature:isInCombat() or creature:isIncapacitated() or creature:isDead() then
		return false
	end

	return not (BotFight ~= nil and BotFight.busy ~= nil and BotFight:busy(oid))
end

-- Logging in: start playing (after BotJobs:restart it may be playing already: it carries on)
function BotMusician:start(pBot, oid)
	local now = os.time()
	local playing = CreatureObject(pBot):isPlayingMusic()
	local song = readStringData(key(oid, "song"))

	if not playing or song == "" then
		song = self:pickSong("")
	end

	self:clear(oid)
	writeStringData(key(oid, "song"), song)
	writeData(key(oid, "startedAt"), now)
	writeData(key(oid, "nextFlourish"), now + between(self.flourishEvery))
	writeData(key(oid, "nextChange"), now + between(self.changeEvery))

	self:topUpAction(pBot)
	self:checkInstrument(pBot, oid)

	if not playing and self:canPlay(pBot, oid) then
		botEnqueue(pBot, "startmusic", 0, song)
	end
end

function BotMusician:clear(oid)
	if BotBand ~= nil then
		BotBand:left(oid)
	end

	deleteData(key(oid, "pendingTarget"))
	deleteData(key(oid, "buffTarget"))
	deleteData(key(oid, "retarget"))
	deleteData(key(oid, "restarts"))
	deleteData(key(oid, "flourishes"))
end

-- startmusic needs an instrument in hand. If the hand is empty, the roster's instrument is equipped again (botEquip,
-- when the build has it)
function BotMusician:checkInstrument(pBot, oid)
	if SceneObject(pBot):getSlottedObject("hold_r") ~= nil then
		return
	end

	local entry = BotJobs:entry(CreatureObject(pBot):getFirstName()) or {}
	local instrument = nil

	for _, template in ipairs(entry.outfit or {}) do
		if tostring(template):find("/instrument/", 1, true) ~= nil then
			instrument = template
		end
	end

	if instrument ~= nil and botEquip ~= nil then
		local item = botEquip(pBot, instrument)

		print("BotJobs: " .. BotJobs:name(oid) .. " had nothing in hand, equipping " .. instrument .. ": " .. tostring(item))
	else
		print("BotJobs: " .. BotJobs:name(oid) .. " has no instrument in hand" ..
			(instrument == nil and " and none in its roster outfit" or ""))
	end
end

function BotMusician:topUpAction(pBot)
	local creature = CreatureObject(pBot)
	local full = creature:getMaxHAM(ACTION) - botGetWounds(pBot, ACTION)

	if creature:getHAM(ACTION) * 100 < full * self.actionFloor then
		creature:setHAM(ACTION, full)
	end
end

-- From BotJobs:tick every few seconds
function BotMusician:tick(pBot, oid, now)
	self:checkPending(pBot, oid, now)

	if BotBand ~= nil then
		BotBand:strays(pBot, oid, now)
	end

	if not self:canPlay(pBot, oid) then
		return
	end

	self:topUpAction(pBot)

	if not CreatureObject(pBot):isPlayingMusic() then
		-- Not started yet, or stopped (the outro is over): start again, and set the buff target again (stopping drops it)
		if now - readData(key(oid, "startedAt")) >= self.restartGap then
			local song = readStringData(key(oid, "song"))
			local restarts = readData(key(oid, "restarts")) + 1

			if song == "" then
				song = self:pickSong("")
				writeStringData(key(oid, "song"), song)
			end

			if restarts % 10 == 3 then
				-- Three tries in a row came to nothing: maybe the instrument went missing
				self:checkInstrument(pBot, oid)
			end

			botEnqueue(pBot, "startmusic", 0, song)
			writeData(key(oid, "startedAt"), now)
			writeData(key(oid, "restarts"), restarts)

			if readData(key(oid, "buffTarget")) ~= 0 then
				writeData(key(oid, "retarget"), 1)
			end

			if restarts <= 3 or restarts % 20 == 0 then
				print("BotJobs: " .. BotJobs:name(oid) .. " wasn't playing, starting " .. song .. " again (" .. restarts .. ")")
			end
		end

		return
	end

	if readData(key(oid, "retarget")) == 1 then
		writeData(key(oid, "retarget"), 0)
		botEnqueue(pBot, "setperformancebufftarget", readData(key(oid, "buffTarget")), "")
	end

	if now >= readData(key(oid, "nextChange")) then
		local song = self:pickSong(readStringData(key(oid, "song")))

		botEnqueue(pBot, "changemusic", 0, song)
		writeStringData(key(oid, "song"), song)
		writeData(key(oid, "nextChange"), now + between(self.changeEvery))
		return
	end

	-- Flourishes: with the band, together with the dancer; alone, on its own timer
	local together = nil

	if BotBand ~= nil then
		together = BotBand:flourishDue(pBot, oid, now)
	end

	if together == true or (together == nil and now >= readData(key(oid, "nextFlourish"))) then
		botEnqueue(pBot, "flourish", 0, tostring(getRandomNumber(1, 8)))
		writeData(key(oid, "nextFlourish"), now + between(self.flourishEvery))
		writeData(key(oid, "flourishes"), readData(key(oid, "flourishes")) + 1)
	end
end

-- A player asked for a buff: make them the buff target and tell them to listen. brainLine: what the language model
-- answered them (it tells them to listen, or to come over), nil if it didn't.
function BotMusician:buffTarget(pBot, pPatient, channel, brainLine)
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

	print("BotJobs: " .. BotJobs:name(oid) .. " waits for " .. patientName .. " to come and listen")

	if brainLine == nil then
		BotJobs:reply(pBot, patientOid, channel, BotLines:pick("musician", "far", patientName, BotJobs:city(oid)))
	end
end

function BotMusician:setTarget(pBot, oid, pPatient, channel, spoke)
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
		BotJobs:reply(pBot, patientOid, channel, BotLines:pick("musician", "listen", patientName, BotJobs:city(oid)))
	end
end

-- A player who asked from afar and has come in becomes the buff target; after pendingSeconds they're forgotten
function BotMusician:checkPending(pBot, oid, now)
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
function BotMusician:state(pBot, oid)
	local playing = pBot ~= nil and CreatureObject(pBot):isPlayingMusic()
	local state = playing and "playing" or "not playing"
	local target = readData(key(oid, "buffTarget"))

	state = state .. " " .. readStringData(key(oid, "song")) .. ", " .. readData(key(oid, "flourishes")) .. " flourishes"

	if readData(key(oid, "restarts")) > 0 then
		state = state .. ", " .. readData(key(oid, "restarts")) .. " restarts"
	end

	if pBot ~= nil and SceneObject(pBot):getSlottedObject("hold_r") == nil then
		state = state .. ", nothing in hand"
	end

	if target ~= 0 then
		local pTarget = getSceneObject(target)

		state = state .. ", buff target " .. (pTarget ~= nil and CreatureObject(pTarget):getFirstName() or tostring(target))
	end

	return state .. (BotFight ~= nil and BotFight.describe ~= nil and BotFight:describe(oid) or "")
end

-- The job module interface (bot_jobs.lua)

-- "bufftarget", "watchHint" for battle fatigue, wounds or healing, or nil
function BotMusician:intent(text)
	local t = text:lower()

	if t:find("buff", 1, true) ~= nil then
		return "bufftarget"
	elseif t:find("fatigue", 1, true) ~= nil or t:find("wound", 1, true) ~= nil or t:find("heal", 1, true) ~= nil then
		return "watchHint"
	end

	return nil
end

function BotMusician:isAction(intent)
	return intent == "bufftarget"
end

function BotMusician:allowed(action)
	if action == "bufftarget" or action == "buff" then
		return "bufftarget"
	end

	return nil
end

function BotMusician:act(pBot, pPlayer, action, channel, brainLine)
	if action == "bufftarget" then
		self:buffTarget(pBot, pPlayer, channel, brainLine)

		if BotBand ~= nil then
			BotBand:askPartner(pBot, SceneObject(pBot):getObjectID(), pPlayer)
		end
	end
end

-- Development, bot on bot: another bot listens to the musician (there is no game client on the local server):
--   runLuaFunction BotMusician:devListen:<first>:<musician>      /listen (devStopListen:<first>: stop)
function BotMusician:devListen(first, musician)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil
	local pMusician = botGetCreature ~= nil and botGetCreature(musician or "") or nil

	if pBot == nil or pMusician == nil then
		print("BotJobs: usage devListen:<bot>:<musician bot>, both online")
		return
	end

	print("BotJobs: " .. tostring(first) .. " listens to " .. tostring(musician) .. ": " ..
		tostring(botEnqueue(pBot, "listen", SceneObject(pMusician):getObjectID(), "")))
end

function BotMusician:devStopListen(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: no online bot called " .. tostring(first))
		return
	end

	print("BotJobs: " .. tostring(first) .. " stops listening: " .. tostring(botEnqueue(pBot, "stoplistening", 0, "")))
end

-- For the brain (the request's extra fields): the roster's instrument
function BotMusician:requestFields(pBot, oid)
	local entry = BotJobs:entry(CreatureObject(pBot):getFirstName()) or {}

	for _, template in ipairs(entry.outfit or {}) do
		if tostring(template):find("/instrument/", 1, true) ~= nil then
			return {instrument = template}
		end
	end

	return {}
end

-- Phase 11: "buffs" in a tell opens the window with the buff times (no model is asked)
function BotMusician:onSpoken(pBot, oid, pSpeaker, channel, text)
	if channel == "tell" and text ~= nil and BotBuffs ~= nil and BotBuffs:wanted(text) and BotCrew ~= nil and BotCrew:human(pSpeaker) then
		BotBuffs:window(pBot, pSpeaker, channel)

		return true
	end

	return false
end

BotJobModules = BotJobModules or {}
BotJobModules.musician = BotMusician
