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
-- The pair is not a Core3 group (a group needs a leader, and a bot never leads): Core3 stacks the two healings as it
-- always has, and the buffs are the dancer's mind buff and the musician's focus and willpower. A city's pair only; a bot
-- whose partner is offline keeps its own timers. Mos Eisley's pair does lead a group now and then, for the crew's mind buffs
-- (the band session, below).
BotBand = ScreenPlay:new {
	screenplayName = "BotBand",

	bandFlourish = {20, 40},
	-- The cantina bands: these three cities only (Varenhal's dancer and musician stay as they were)
	bandCities = {mos_eisley = true, coronet = true, theed = true},
	-- The partner's flourish and buff set-up follow the first by this long (ms)
	followMs = 800,
	joinMs = 1200,

	-- The band session (Phase 8b): in sessionCity only, where the crew waits
	sessionCity = "mos_eisley",
	-- The band's group buffs the crew bots at home: the dancer leads, the musician and up to sessionMax crew are in the group
	-- (the group holds 8), and a crew bot that doesn't fit is both band bots' buff target. They watch and listen sessionMinutes
	sessionMinutes = 8,
	sessionMax = 6,
	-- A session starts when a crew bot at home has less than this many seconds of mind buffs left, and is not tried again for
	-- the same bot within retryGap seconds
	rebuffBelow = 1800,
	retryGap = 1800,
	-- A crew bot this close to the dancer (m) is at home in the cantina
	bandRange = 40,
	-- Seconds to get the group together; a session that is past its end by sessionGrace seconds is dead (a restart)
	joinWindow = 45,
	sessionGrace = 60,
	-- A player who asked for a buff this recently (s) keeps the buff target
	humanHold = 300,
	-- ...and for as long as they watch or listen within this of the band bot (Core3's patron range)
	humanNear = 60,
	-- Seconds between looks at who needs a session, after a session before the next one starts, and before a stray group is
	-- dissolved again
	checkEvery = 30,
	sessionGap = 60,
	strayGap = 10,
	-- The end of a session: the disband follows the unwatching by this long (ms), the report of the buffs by this much more
	disbandMs = 3000,
	reportMs = 4000,
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

-- The band session (Phase 8b, specs/2026-10-25-crew-mind-buffs/). Core3 builds a performance buff for a patron (someone who
-- watches the dancer or listens to the musician) who is in the entertainer's group or is her buff target. So the dancer
-- leads a group of the musician and the crew at home, who all watch and listen on their feet for sessionMinutes, and the
-- crew bot that doesn't fit is both band bots' buff target. Then they stop (the buffs land) and the dancer disbands.
-- Shared state, under band:<city>: session (a number; 0 none) with until, startedAt, dancer, musician, members (crew oids),
-- target (the crew bot outside the group, 0 none). A session that is past its end by sessionGrace is dead; the crew bots
-- (crew.lua, bandTick) and the band bots (strays) leave a group that has none.

-- The live session of a city (its number), or 0
function BotBand:live(city)
	local session = readData(bandKey(city, "session"))

	if session == 0 or os.time() > readData(bandKey(city, "until")) + self.sessionGrace then
		return 0
	end

	return session
end

local function oidsOf(text)
	local out = {}

	for digits in string.gmatch(text or "", "%d+") do
		table.insert(out, tonumber(digits))
	end

	return out
end

-- Has the dancer of this city's live session invited this crew bot to join it? The session's number, or 0
function BotBand:invites(city, oid, inviterOid)
	local session = self:live(city)

	if session == 0 or inviterOid ~= readData(bandKey(city, "dancer")) then
		return 0
	end

	for _, memberOid in ipairs(oidsOf(readStringData(bandKey(city, "members")))) do
		if memberOid == oid then
			return session
		end
	end

	return 0
end

-- A band bot in a group with no live session leaves it: the dancer (its leader) disbands, the musician leaves
function BotBand:strays(pBot, oid, now)
	local city = BotJobs:city(oid)

	if city ~= self.sessionCity or not CreatureObject(pBot):isGrouped() or self:live(city) ~= 0 or
		now - readData(key(oid, "strayAt")) < self.strayGap then
		return
	end

	writeData(key(oid, "strayAt"), now)

	local info = botGroupInfo ~= nil and botGroupInfo(pBot) or nil

	print("BotJobs: " .. BotJobs:name(oid) .. " is in a group with no band session, leaving it")
	botEnqueue(pBot, (info ~= nil and info.leader == oid) and "disband" or "leavegroup", 0, "")
end

-- The band bots stop on the session's account: a login (BotJobs:restart too) or a logout of either ends it
function BotBand:left(oid)
	local city = BotJobs:city(oid)

	if readData(bandKey(city, "dancer")) == oid or readData(bandKey(city, "musician")) == oid then
		deleteData(bandKey(city, "session"))
	end
end

local function inFight(pBot, oid)
	return CreatureObject(pBot):isInCombat() or (BotFight ~= nil and BotFight.busy ~= nil and BotFight:busy(oid))
end

-- The dancer's tick: start a session, keep one going, end it
function BotBand:session(pDancer, oid, now)
	local city = BotJobs:city(oid)

	if city ~= self.sessionCity or BotCrew == nil or botList == nil then
		return
	end

	local pMusician, musicianOid = self:partner(oid)

	if readData(bandKey(city, "session")) == 0 then
		self:strays(pDancer, oid, now)
		self:start(pDancer, oid, city, pMusician, musicianOid, now)
	else
		self:keep(pDancer, oid, city, pMusician, musicianOid, now)
	end
end

function BotBand:start(pDancer, oid, city, pMusician, musicianOid, now)
	if pMusician == nil or not CreatureObject(pDancer):isDancing() or not CreatureObject(pMusician):isPlayingMusic() or
		inFight(pDancer, oid) or inFight(pMusician, musicianOid) or CreatureObject(pDancer):isGrouped() or
		CreatureObject(pMusician):isGrouped() or now - readData(bandKey(city, "endedAt")) < self.sessionGap or
		now < readData(bandKey(city, "checkAt")) then
		return
	end

	writeData(bandKey(city, "checkAt"), now + self.checkEvery)

	-- The crew at home, the neediest first (the entertainer, who has no group of her own to be in, last)
	local ready, due = {}, false

	for _, entry in ipairs(botList() or {}) do
		-- (Phase 9: the Mos Eisley crew only; the bots a player hired are theirs)
		local pCrew = (entry.online and entry.city == city and entry.oid ~= 0 and (entry.owner or 0) == 0 and BotCrew:isCrew(entry.job)) and
			getSceneObject(entry.oid) or nil

		if pCrew ~= nil and BotCrew:bandReady(pCrew, entry.oid, pDancer) then
			local left = BotCrew:mindBuffsLeft(pCrew)

			table.insert(ready, {p = pCrew, oid = entry.oid, left = left, last = entry.job == "entertainer" and 1 or 0})

			if left < self.rebuffBelow and now - readData("bot:" .. entry.oid .. ":crew:bandAt") >= self.retryGap then
				due = true
			end
		end
	end

	if not due then
		return
	end

	table.sort(ready, function(a, b)
		if a.last ~= b.last then
			return a.last < b.last
		end

		if a.left ~= b.left then
			return a.left < b.left
		end

		return a.oid < b.oid
	end)

	local members, names = {}, {}

	for i = 1, math.min(#ready, self.sessionMax) do
		table.insert(members, ready[i].oid)
		table.insert(names, BotJobs:name(ready[i].oid))
	end

	local session = readData(bandKey(city, "seq")) + 1
	local target = ready[self.sessionMax + 1]

	writeData(bandKey(city, "seq"), session)
	writeData(bandKey(city, "session"), session)
	writeData(bandKey(city, "startedAt"), now)
	writeData(bandKey(city, "until"), now + self.sessionMinutes * 60)
	writeData(bandKey(city, "dancer"), oid)
	writeData(bandKey(city, "musician"), musicianOid)
	writeStringData(bandKey(city, "members"), table.concat(members, ","))
	writeData(bandKey(city, "target"), 0)

	-- The musician first; the crew once her group stands (keep). Invites accepted at once each make a group of their own
	-- around a leader with none yet, as Phase 8's call found
	botEnqueue(pDancer, "invite", musicianOid, "")

	-- The seventh is the buff target of both, unless a player holds the target
	if target ~= nil and not self:humanHolds(oid, now) and not self:humanHolds(musicianOid, now) then
		writeData(bandKey(city, "target"), target.oid)
		BotCrew:bandEnroll(target.oid, session, true, now)
		self:setTarget(pDancer, oid, target.oid)
		self:setTarget(pMusician, musicianOid, target.oid)
		table.insert(names, BotJobs:name(target.oid) .. " (buff target)")
	end

	print("BotJobs: band session " .. session .. " starts for " .. table.concat(names, ", ") .. ": " .. self.sessionMinutes .. " min")
end

-- Does a player hold this band bot's buff target (asked for a buff lately)? A crew bot as target doesn't count
function BotBand:humanHolds(oid, now)
	local target = readData(key(oid, "buffTarget"))

	if target == 0 or target == readData(bandKey(BotJobs:city(oid), "target")) or BotCrew:isCrew(BotJobs:job(target)) then
		return false
	end

	if now - readData(key(oid, "lastPatientAt")) < self.humanHold then
		return true
	end

	-- Still watching or listening by the band (longer than humanHold, say): theirs until they stop (Core3 builds the buff only
	-- for the target). A patron's mood reads "entertained"
	local pBand, pTarget = getSceneObject(oid), getSceneObject(target)
	local dist = (pBand ~= nil and pTarget ~= nil) and BotJobs:distance(pBand, pTarget) or nil

	return dist ~= nil and dist <= self.humanNear and CreatureObject(pTarget):getMoodString() == "entertained"
end

-- The crew bot as the buff target (silent: no line, not "the last patient")
function BotBand:setTarget(pBot, oid, targetOid)
	botEnqueue(pBot, "setperformancebufftarget", targetOid, "")
	writeData(key(oid, "buffTarget"), targetOid)
end

function BotBand:keep(pDancer, oid, city, pMusician, musicianOid, now)
	if readData(bandKey(city, "dancer")) ~= oid then
		return
	end

	if now >= readData(bandKey(city, "until")) then
		self:finish(pDancer, oid, city, pMusician, musicianOid, now, "done")
		return
	end

	if pMusician == nil or inFight(pDancer, oid) or inFight(pMusician, musicianOid) then
		self:finish(pDancer, oid, city, pMusician, musicianOid, now, pMusician == nil and "the musician is gone" or "a fight")
		return
	end

	local session = readData(bandKey(city, "session"))
	local dancing = CreatureObject(pDancer):isDancing()
	local playing = CreatureObject(pMusician):isPlayingMusic()
	local joining = now - readData(bandKey(city, "startedAt")) < self.joinWindow
	local members = oidsOf(readStringData(bandKey(city, "members")))
	local kept = {}
	local formed = CreatureObject(pDancer):isGrouped()

	-- The musician accepts the dancer's invite here (she has no crew code)
	if not CreatureObject(pMusician):isGrouped() and botGetGroupInviter ~= nil and botGetGroupInviter(pMusician) == oid then
		botEnqueue(pMusician, "join", 0, "")
	elseif joining and not CreatureObject(pMusician):isGrouped() and (botGetGroupInviter == nil or botGetGroupInviter(pMusician) == 0) then
		botEnqueue(pDancer, "invite", musicianOid, "")
	end

	for _, memberOid in ipairs(members) do
		local pMember = getSceneObject(memberOid)
		local mine = pMember ~= nil and BotCrew:inBand(memberOid) and readData("bot:" .. memberOid .. ":crew:band") == session

		if mine then
			table.insert(kept, memberOid)

			if dancing then
				BotCrew:watch(pMember, memberOid, pDancer, "dance")
			end

			if playing then
				BotCrew:watch(pMember, memberOid, pMusician, "music")
			end
		elseif joining and formed and pMember ~= nil and not CreatureObject(pMember):isGrouped() and
			(botGetGroupInviter == nil or botGetGroupInviter(pMember) == 0) then
			-- Not in yet: invited (once the dancer's group stands), and again if an invite was lost in the queue
			table.insert(kept, memberOid)
			botEnqueue(pDancer, "invite", memberOid, "")
		elseif joining then
			table.insert(kept, memberOid)
		end
	end

	-- A member that never came is dropped from the list
	if #kept ~= #members then
		writeStringData(bandKey(city, "members"), table.concat(kept, ","))
	end

	self:keepTarget(pDancer, oid, pMusician, musicianOid, city, session, dancing, playing)
end

-- The buff target outside the group watches and listens as long as both band bots still have her as their target (a player
-- who asks takes it from her: she stops, and what she has built lands)
function BotBand:keepTarget(pDancer, oid, pMusician, musicianOid, city, session, dancing, playing)
	local targetOid = readData(bandKey(city, "target"))
	local pTarget = targetOid ~= 0 and getSceneObject(targetOid) or nil

	if pTarget == nil or not BotCrew:inBand(targetOid) then
		return
	end

	if dancing and readData(key(oid, "buffTarget")) == targetOid then
		if BotCrew:watch(pTarget, targetOid, pDancer, "dance") then
			botEnqueue(pDancer, "setperformancebufftarget", targetOid, "")
		end
	else
		BotCrew:unwatch(pTarget, targetOid, "dance")
	end

	if playing and readData(key(musicianOid, "buffTarget")) == targetOid then
		if BotCrew:watch(pTarget, targetOid, pMusician, "music") then
			botEnqueue(pMusician, "setperformancebufftarget", targetOid, "")
		end
	else
		BotCrew:unwatch(pTarget, targetOid, "music")
	end
end

-- Everyone stops watching (the buffs land), then the dancer disbands; the buffs are logged a few seconds after
function BotBand:finish(pDancer, oid, city, pMusician, musicianOid, now, why)
	local members = oidsOf(readStringData(bandKey(city, "members")))
	local targetOid = readData(bandKey(city, "target"))
	local session = readData(bandKey(city, "session"))

	if targetOid ~= 0 then
		table.insert(members, targetOid)
	end

	for _, memberOid in ipairs(members) do
		local pMember = getSceneObject(memberOid)

		if pMember ~= nil and BotCrew:inBand(memberOid) then
			BotCrew:bandRelease(pMember, memberOid, now)
		end
	end

	-- The target given up is cleared, a player's stays
	for _, pair in ipairs({{oid, "dancer"}, {musicianOid, "musician"}}) do
		if targetOid ~= 0 and readData(key(pair[1], "buffTarget")) == targetOid then
			deleteData(key(pair[1], "buffTarget"))
			deleteData(key(pair[1], "retarget"))
		end
	end

	writeStringData(bandKey(city, "lastMembers"), table.concat(members, ","))
	writeData(bandKey(city, "endedAt"), now)
	deleteData(bandKey(city, "session"))
	deleteData(bandKey(city, "target"))
	print("BotJobs: band session " .. session .. " ends (" .. why .. ")")

	local gen = tostring(readData(key(oid, "gen")))

	createEvent(self.disbandMs, "BotBand", "disband", pDancer, gen)
	createEvent(self.disbandMs + self.reportMs, "BotBand", "report", pDancer, gen)
end

function BotBand:disband(pBot, gen)
	if BotJobs:current(pBot, gen) and CreatureObject(pBot):isGrouped() then
		botEnqueue(pBot, "disband", 0, "")
	end
end

function BotBand:report(pBot, gen)
	if not BotJobs:current(pBot, gen) then
		return
	end

	local city = BotJobs:city(SceneObject(pBot):getObjectID())
	local parts = {}

	for _, memberOid in ipairs(oidsOf(readStringData(bandKey(city, "lastMembers")))) do
		local pMember = getSceneObject(memberOid)

		if pMember ~= nil then
			local left = {}

			for _, buff in ipairs(botGetBuffs ~= nil and botGetBuffs(pMember) or {}) do
				left[buff.name] = math.floor((tonumber(buff.secondsLeft) or 0) / 60)
			end

			table.insert(parts, BotJobs:name(memberOid) .. ": mind " .. (left.performance_enhance_dance_mind or 0) .. " min, focus " ..
				(left.performance_enhance_music_focus or 0) .. " min")
		end
	end

	print("BotJobs: band session buffed " .. table.concat(parts, "; "))
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
	BotBand:left(oid)
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
	BotBand:session(pBot, oid, now)

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

local CREW_JOBS = {tank = true, rifleman = true, medic = true, ranger = true, squadleader = true, entertainer = true, commando = true}

-- Development: the band session in a city, and each crew bot's part in it (group, posture, watching, distance to the
-- dancer), from the console:  runLuaFunction BotBand:devStatus:mos_eisley   (devAgain:mos_eisley: let it run again now)
function BotBand:devStatus(city)
	city = city or "mos_eisley"
	print("BotJobs: band " .. city .. ": session " .. readData(bandKey(city, "session")) .. ", live " .. tostring(self:live(city)) ..
		", until " .. (readData(bandKey(city, "until")) - os.time()) .. " s")

	local pDancer

	for _, bot in ipairs(botList() or {}) do
		local pBot = bot.online and botGetCreature(bot.firstName) or nil

		if pBot ~= nil and BotJobs:job(SceneObject(pBot):getObjectID()) == "dancer" and BotJobs:city(SceneObject(pBot):getObjectID()) == city then
			pDancer = pBot
		end
	end

	for _, bot in ipairs(botList() or {}) do
		local pBot = bot.online and botGetCreature(bot.firstName) or nil
		local oid = pBot ~= nil and SceneObject(pBot):getObjectID() or 0

		if pBot ~= nil and (CREW_JOBS[BotJobs:job(oid)] or BotJobs:job(oid) == "dancer" or BotJobs:job(oid) == "musician") and
			BotJobs:city(oid) == city then
			local g = botGroupInfo(pBot)
			local c = "bot:" .. oid .. ":crew:"
			print(string.format("BotJobs:   %-16s %-11s mode %-6s group %s%s posture %d mood %s watching %s listening %s dist %s", BotJobs:name(oid),
				BotJobs:job(oid), readStringData(c .. "mode"), g ~= nil and tostring(g.id) or "-",
				(g ~= nil and g.leader == oid) and " (leads, " .. #g.members .. ")" or "", CreatureObject(pBot):getPosture(),
				tostring(CreatureObject(pBot):getMoodString()), tostring(readData(c .. "watching")), tostring(readData(c .. "listening")),
				pDancer ~= nil and string.format("%.1f", BotJobs:distance(pBot, pDancer) or -1) or "?"))
		end
	end
end

function BotBand:devAgain(city)
	for _, bot in ipairs(botList() or {}) do
		local pBot = bot.online and botGetCreature(bot.firstName) or nil

		if pBot ~= nil then
			deleteData("bot:" .. SceneObject(pBot):getObjectID() .. ":crew:bandAt")
		end
	end

	print("BotJobs: band sessions may start again now")
end

-- Phase 11: "buffs" in a tell opens the window with the buff times (no model is asked)
function BotDancer:onSpoken(pBot, oid, pSpeaker, channel, text)
	if channel == "tell" and text ~= nil and BotBuffs ~= nil and BotBuffs:wanted(text) and BotCrew ~= nil and BotCrew:human(pSpeaker) then
		BotBuffs:window(pBot, pSpeaker, channel)

		return true
	end

	return false
end

BotJobModules = BotJobModules or {}
BotJobModules.dancer = BotDancer
