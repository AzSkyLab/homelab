-- Bot players (Phase 3): the master doctor. It stands in its city's medical centre and, on request, gives the six
-- medical enhancements (then heals any wounds too) or heals wounds alone, with the real commands (healenhance,
-- healwound) and packs the server keeps stocked (botStockPack, power and duration from roster.lua's settings).
-- Patients in reach wait their turn in a short queue; one who asked from out of reach (a tell, or across the room) is
-- remembered for a couple of minutes and treated on arrival. Between patients its mind is topped up, and now and
-- then it sits, stretches or emotes. Driven by BotJobs (bot_jobs.lua); every step is an event on the bot.

local MIND = 6 -- CreatureAttribute::MIND

BotDoctor = ScreenPlay:new {
	screenplayName = "BotDoctor",

	-- Core3's ranges: HealEnhanceCommand 7 m, HealWoundCommand 6 m
	enhanceRange = 7,
	woundRange = 6,
	-- Further than this, or on another planet, a patient gets directions instead of "come closer"
	roomRange = 30,
	-- A request from out of reach waits this long (seconds) for the patient to come over (checked every tick)
	pendingSeconds = 120,
	maxPending = 6,

	-- The six enhancements, in this order, and their packs
	enhancements = {"health", "action", "strength", "constitution", "quickness", "stamina"},
	enhancePacks = {
		health = "object/tangible/medicine/crafted/medpack_enhance_health_d.iff",
		action = "object/tangible/medicine/crafted/medpack_enhance_action_d.iff",
		strength = "object/tangible/medicine/crafted/medpack_enhance_strength_d.iff",
		constitution = "object/tangible/medicine/crafted/medpack_enhance_constitution_d.iff",
		quickness = "object/tangible/medicine/crafted/medpack_enhance_quickness_d.iff",
		stamina = "object/tangible/medicine/crafted/medpack_enhance_stamina_d.iff",
	},
	-- The six health and action pools a doctor heals wounds on (CreatureAttribute HEALTH 0 .. STAMINA 5), and their packs
	woundPools = {
		{name = "health", pool = 0, pack = "object/tangible/medicine/crafted/medpack_wound_health_e.iff"},
		{name = "strength", pool = 1, pack = "object/tangible/medicine/crafted/medpack_wound_strength_e.iff"},
		{name = "constitution", pool = 2, pack = "object/tangible/medicine/crafted/medpack_wound_constitution_e.iff"},
		{name = "action", pool = 3, pack = "object/tangible/medicine/crafted/medpack_wound_action_e.iff"},
		{name = "quickness", pool = 4, pack = "object/tangible/medicine/crafted/medpack_wound_quickness_e.iff"},
		{name = "stamina", pool = 5, pack = "object/tangible/medicine/crafted/medpack_wound_stamina_e.iff"},
	},
	-- Wound treatments for one patient at most (a pool with more wounds than one pack heals takes two)
	maxWoundSteps = 12,

	-- Core3's wait between treatments (deactivateWoundTreatment in HealEnhanceCommand.h and HealWoundCommand.h):
	-- 20 s less 0.08 s per point of healing_wound_speed (a master doctor has 100: 12 s), at least 3 s. Plus a margin.
	treatmentMarginMs = 1500,
	-- A treatment costs 150 mind (enhance) or 50 (wound); below this the doctor's mind is topped up first
	mindFloor = 400,

	-- Patients waiting in reach, at most
	maxQueue = 4,
	-- After a buff: a tip line this often (percent; never when the model's answer already mentioned tips, which it
	-- does about one time in five), else a done line this often
	tipChance = 10,
	doneChance = 60,
	-- A treatment that hasn't finished after this long (seconds) is dropped, in case an event was lost
	workTimeout = 400,

	-- Idle: an emote or a sit every idleEvery seconds; a sit lasts sitFor seconds
	idleEvery = {90, 240},
	sitChance = 20,
	sitFor = {60, 240},
}

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
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

local function percent(chance)
	return getRandomNumber(1, 100) <= chance
end

local function between(range)
	return getRandomNumber(range[1], range[2])
end

-- Does the model's answer already ask them over ("come over", "step closer", ...)?
local function invitesOver(line)
	local t = tostring(line or ""):lower()

	for _, words in ipairs({"closer", "come over", "come by", "come here", "come see", "over here", "swing by", "step in",
		"head over", "when you get here", "get over"}) do
		if t:find(words, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- Logging in: a clean slate, full packs, full mind
function BotDoctor:start(pBot, oid)
	self:clear(oid)
	self:restock(pBot)
	self:topUpMind(pBot)
	writeData(key(oid, "nextIdle"), os.time() + between(self.idleEvery))
end

-- Logging out (or in again): nobody waiting, nothing running
function BotDoctor:clear(oid)
	writeData(key(oid, "workSeq"), readData(key(oid, "workSeq")) + 1)
	writeData(key(oid, "busy"), 0)
	deleteData(key(oid, "patient"))
	deleteData(key(oid, "sitting"))
	deleteData(key(oid, "readyAt"))
	deleteStringData(key(oid, "kind"))
	deleteStringData(key(oid, "queue"))
	deleteStringData(key(oid, "pending"))
end

-- Is this treatment chain still the one running?
function BotDoctor:current(pBot, gen, seq)
	return BotJobs:current(pBot, gen) and readData(key(SceneObject(pBot):getObjectID(), "workSeq")) == seq
end

function BotDoctor:treatmentMs(pBot)
	local speed = CreatureObject(pBot):getSkillMod("healing_wound_speed") or 0
	local delay = math.floor(20 - speed * 2 / 25 + 0.5)

	if delay < 3 then
		delay = 3
	end

	return delay * 1000 + self.treatmentMarginMs
end

function BotDoctor:restock(pBot)
	local uses = BotJobs:setting("packStock")
	local power, duration = BotJobs:setting("enhancePower"), BotJobs:setting("enhanceDuration")

	for _, attribute in ipairs(self.enhancements) do
		botStockPack(pBot, self.enhancePacks[attribute], uses, power, duration)
	end

	for _, wound in ipairs(self.woundPools) do
		botStockPack(pBot, wound.pack, uses, BotJobs:setting("woundPower"), 0)
	end
end

-- Mind back to full (less any mind wounds)
function BotDoctor:topUpMind(pBot)
	local creature = CreatureObject(pBot)
	local full = creature:getMaxHAM(MIND) - botGetWounds(pBot, MIND)

	if creature:getHAM(MIND) < full then
		creature:setHAM(MIND, full)
	end
end

-- The first wounded health or action pool and its wounds, or nil
function BotDoctor:nextWound(pPatient)
	for _, wound in ipairs(self.woundPools) do
		local amount = botGetWounds(pPatient, wound.pool)

		if amount > 0 then
			return wound, amount
		end
	end

	return nil
end

-- What an enhancement adds: the buff's value if the body reports it, else the pool's maximum over its base
local POOLS = {health = 0, strength = 1, constitution = 2, action = 3, quickness = 4, stamina = 5}

function BotDoctor:buffAmount(pPatient, attribute, buff)
	if tonumber(buff.value) ~= nil then
		return math.floor(tonumber(buff.value))
	end

	local pool = POOLS[attribute]

	if pool == nil then
		return 0
	end

	return math.floor(CreatureObject(pPatient):getMaxHAM(pool) - CreatureObject(pPatient):getBaseHAM(pool))
end

-- The queue (patients in reach) and the pending list (asked from out of reach): "oid/kind/channel/spoke/tipped/until;"
-- spoke: the model answered them; tipped: its answer mentioned tips; until: when a pending request lapses
function BotDoctor:loadList(oid, name)
	local list = {}

	for item in string.gmatch(readStringData(key(oid, name)), "[^;]+") do
		local patient, kind, channel, spoke, tipped, untilTime = item:match("^(%d+)/(%a+)/(%a+)/(%d)/(%d)/(%d+)$")

		if patient ~= nil then
			table.insert(list, {oid = tonumber(patient), kind = kind, channel = channel, spoke = spoke, tipped = tipped,
				untilTime = tonumber(untilTime)})
		end
	end

	return list
end

function BotDoctor:saveList(oid, name, list)
	local parts = {}

	for _, item in ipairs(list) do
		table.insert(parts, table.concat({item.oid, item.kind, item.channel, item.spoke, item.tipped, item.untilTime or 0}, "/"))
	end

	if #parts == 0 then
		deleteStringData(key(oid, name))
	else
		writeStringData(key(oid, name), table.concat(parts, ";"))
	end
end

-- Packed treatment arguments: gen:seq:patient:kind:channel:spoke:tipped
function BotDoctor:packItem(gen, seq, item)
	return packArgs(gen, seq, item.oid, item.kind, item.channel, item.spoke, item.tipped)
end

function BotDoctor:say(pBot, oid, patientOid, channel, kind, patientName)
	BotJobs:reply(pBot, patientOid, channel, BotLines:pick("doctor", kind, patientName, BotJobs:city(oid)))
end

function BotDoctor:rangeFor(kind)
	return kind == "buff" and self.enhanceRange or self.woundRange
end

-- Turn to someone who talks to it in the room, unless it's working on a patient
function BotDoctor:faceIfFree(pBot, oid, pSpeaker)
	local dist = BotJobs:distance(pBot, pSpeaker)

	if readData(key(oid, "busy")) ~= 1 and dist ~= nil and dist <= self.roomRange then
		botFace(pBot, pSpeaker)
	end
end

-- A patient asked for "buff" (the six enhancements, then any wounds) or "wounds". brainLine: what the language model
-- answered them, nil if it didn't.
function BotDoctor:request(pBot, pPatient, kind, channel, brainLine)
	local oid = SceneObject(pBot):getObjectID()
	local patientOid = SceneObject(pPatient):getObjectID()
	local patientName = CreatureObject(pPatient):getFirstName()
	local item = {oid = patientOid, kind = kind, channel = channel, spoke = brainLine ~= nil and "1" or "0",
		tipped = (brainLine ~= nil and brainLine:lower():find("tip", 1, true) ~= nil) and "1" or "0", untilTime = 0}

	if self:waiting(oid, patientOid, kind) then
		return
	end

	local dist = BotJobs:distance(pBot, pPatient)

	if dist ~= nil and dist <= self:rangeFor(kind) then
		self:enqueue(pBot, item, patientName)
		return
	end

	-- Out of reach: remembered until they come over. The model tells them so itself on a tell, or when its answer
	-- asks them over; otherwise the doctor does.
	local pending = self:loadList(oid, "pending")

	item.untilTime = os.time() + self.pendingSeconds

	if #pending >= self.maxPending then
		table.remove(pending, 1)
	end

	table.insert(pending, item)
	self:saveList(oid, "pending", pending)

	print("BotJobs: " .. BotJobs:name(oid) .. " waits for " .. patientName .. " to come over (" .. kind .. ", " ..
		(dist ~= nil and (math.floor(dist) .. " m") or "elsewhere") .. ")")

	if brainLine == nil or (channel ~= "tell" and not invitesOver(brainLine)) then
		self:say(pBot, oid, patientOid, channel, (dist == nil or dist > self.roomRange) and "far" or "closer", patientName)
	end
end

-- Already being treated for it, queued or pending? (A buff covers wounds.) A pending entry of the same kind is
-- dropped, so the new request replaces it.
function BotDoctor:waiting(oid, patientOid, kind)
	local currentKind = readStringData(key(oid, "kind"))

	if readData(key(oid, "busy")) == 1 and readData(key(oid, "patient")) == patientOid and
		(currentKind == kind or currentKind == "buff") then
		return true
	end

	for _, item in ipairs(self:loadList(oid, "queue")) do
		if item.oid == patientOid and (item.kind == kind or item.kind == "buff") then
			return true
		end
	end

	local pending = self:loadList(oid, "pending")
	local kept = {}

	for _, item in ipairs(pending) do
		if not (item.oid == patientOid and item.kind == kind) then
			table.insert(kept, item)
		end
	end

	if #kept ~= #pending then
		self:saveList(oid, "pending", kept)
	end

	return false
end

-- In reach: into the queue, and start if free
function BotDoctor:enqueue(pBot, item, patientName)
	local oid = SceneObject(pBot):getObjectID()
	local queue = self:loadList(oid, "queue")
	local busy = readData(key(oid, "busy")) == 1

	if #queue >= self.maxQueue then
		self:say(pBot, oid, item.oid, item.channel, "full", patientName)
		return
	end

	item.untilTime = 0
	table.insert(queue, item)
	self:saveList(oid, "queue", queue)

	if busy then
		if readData(key(oid, "patient")) ~= item.oid then
			self:say(pBot, oid, item.oid, item.channel, "busy", patientName)
		end

		return
	end

	self:nextPatient(pBot)
end

-- From the tick: pending patients who have come within reach join the queue; lapsed ones are forgotten
function BotDoctor:checkPending(pBot, oid, now)
	local pending = self:loadList(oid, "pending")

	if #pending == 0 then
		return
	end

	local kept, arrived = {}, {}

	for _, item in ipairs(pending) do
		local pPatient = getSceneObject(item.oid)
		local dist = BotJobs:distance(pBot, pPatient)

		if dist ~= nil and dist <= self:rangeFor(item.kind) then
			table.insert(arrived, item)
		elseif now < item.untilTime then
			table.insert(kept, item)
		else
			print("BotJobs: " .. BotJobs:name(oid) .. " stops waiting for " ..
				(pPatient ~= nil and CreatureObject(pPatient):getFirstName() or tostring(item.oid)))
		end
	end

	self:saveList(oid, "pending", kept)

	-- They're here now: the doctor talks to them out loud
	for _, item in ipairs(arrived) do
		local pPatient = getSceneObject(item.oid)

		item.channel = "spatial"
		self:enqueue(pBot, item, CreatureObject(pPatient):getFirstName())
	end
end

-- Take the next patient off the queue, if any
function BotDoctor:nextPatient(pBot)
	local oid = SceneObject(pBot):getObjectID()
	local queue = self:loadList(oid, "queue")
	local item = table.remove(queue, 1)

	self:saveList(oid, "queue", queue)

	if item == nil then
		writeData(key(oid, "busy"), 0)
		return
	end

	local seq = readData(key(oid, "workSeq")) + 1

	writeData(key(oid, "workSeq"), seq)
	writeData(key(oid, "busy"), 1)
	writeData(key(oid, "patient"), item.oid)
	writeData(key(oid, "workSince"), os.time())
	writeStringData(key(oid, "kind"), item.kind)

	createEvent(300, "BotDoctor", "begin", pBot, self:packItem(readData(key(oid, "gen")), seq, item))
end

-- Face the patient, stand up if sitting, then start
function BotDoctor:begin(pBot, args)
	local a = unpackArgs(args)
	local gen, seq = a[1], num(a[2])
	local item = {oid = num(a[3]), kind = a[4], channel = a[5], spoke = a[6], tipped = a[7]}

	if not self:current(pBot, gen, seq) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local pPatient = getSceneObject(item.oid)

	if pPatient == nil then
		self:finish(pBot)
		return
	end

	local patientName = CreatureObject(pPatient):getFirstName()

	if item.kind == "wounds" and self:nextWound(pPatient) == nil then
		self:say(pBot, oid, item.oid, item.channel, "noWounds", patientName)
		self:finish(pBot)
		return
	end

	local dist = BotJobs:distance(pBot, pPatient)

	if dist == nil or dist > self:rangeFor(item.kind) then
		-- Stepped away while waiting their turn: back on the pending list
		local pending = self:loadList(oid, "pending")

		item.untilTime = os.time() + self.pendingSeconds
		table.insert(pending, item)
		self:saveList(oid, "pending", pending)

		if item.spoke ~= "1" then
			self:say(pBot, oid, item.oid, item.channel, (dist == nil or dist > self.roomRange) and "far" or "closer", patientName)
		end

		self:finish(pBot)
		return
	end

	botFace(pBot, pPatient)

	local delay = 200

	if readData(key(oid, "sitting")) == 1 then
		botEnqueue(pBot, "stand", 0, "")
		writeData(key(oid, "sitting"), 0)
		delay = 1500
	end

	-- An earlier patient's treatment wait may still be running
	local wait = readData(key(oid, "readyAt")) - getTimestampMilli()

	if wait > delay then
		delay = wait
	end

	self:topUpMind(pBot)

	if item.spoke ~= "1" then
		self:say(pBot, oid, item.oid, item.channel, item.kind == "buff" and "buffStart" or "woundsStart", patientName)
	end

	print("BotJobs: " .. BotJobs:name(oid) .. " treats " .. patientName .. " (" .. item.kind .. ")")

	createEvent(delay, "BotDoctor", "step", pBot, self:packItem(gen, seq, item) .. ":1:-1:0")
end

-- One treatment, then the next after Core3's wait. A buff is the six enhancements (steps 1-6), then any wounds.
function BotDoctor:step(pBot, args)
	local a = unpackArgs(args)
	local gen, seq = a[1], num(a[2])
	local item = {oid = num(a[3]), kind = a[4], channel = a[5], spoke = a[6], tipped = a[7]}
	local n, lastPool, lastAmount = num(a[8]), num(a[9]) or -1, num(a[10]) or 0

	if not self:current(pBot, gen, seq) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local pPatient = getSceneObject(item.oid)
	local dist = BotJobs:distance(pBot, pPatient)
	local enhancing = item.kind == "buff" and n <= #self.enhancements
	local range = enhancing and self.enhanceRange or self.woundRange
	local base = self:packItem(gen, seq, item)

	if dist == nil or dist > range + 1 then
		if enhancing or item.kind == "wounds" then
			self:say(pBot, oid, item.oid, item.channel, "wandered", pPatient ~= nil and CreatureObject(pPatient):getFirstName() or nil)
			self:finish(pBot)
		else
			-- The buff is done; they left before the wounds
			self:done(pBot, base)
		end

		return
	end

	if CreatureObject(pBot):getHAM(MIND) < self.mindFloor then
		self:topUpMind(pBot)
	end

	local gap = self:treatmentMs(pBot)

	if enhancing then
		self:command(pBot, oid, "healenhance", item.oid, self.enhancements[n], gap)
		createEvent(gap, "BotDoctor", "step", pBot, base .. ":" .. (n + 1))
		return
	end

	-- Wounds: the first wounded pool each time, until none is left, the cap, or a treatment that didn't take
	local wound, amount = self:nextWound(pPatient)
	local cap = (item.kind == "buff" and #self.enhancements or 0) + self.maxWoundSteps

	if wound == nil or n > cap or (wound.pool == lastPool and amount >= lastAmount) then
		self:done(pBot, base)
		return
	end

	self:command(pBot, oid, "healwound", item.oid, wound.name, gap)
	createEvent(gap, "BotDoctor", "step", pBot, base .. ":" .. (n + 1) .. ":" .. wound.pool .. ":" .. amount)
end

function BotDoctor:command(pBot, oid, command, targetOid, argument, gap)
	if not botEnqueue(pBot, command, targetOid, argument) then
		print("BotJobs: " .. BotJobs:name(oid) .. " couldn't queue " .. command .. " " .. argument)
	end

	writeData(key(oid, "readyAt"), getTimestampMilli() + gap)
end

-- The treatment is over: log what landed, a line, the next patient
function BotDoctor:done(pBot, args)
	local a = unpackArgs(args)
	local gen, seq = a[1], num(a[2])
	local item = {oid = num(a[3]), kind = a[4], channel = a[5], spoke = a[6], tipped = a[7]}

	if not self:current(pBot, gen, seq) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local pPatient = getSceneObject(item.oid)
	local patientName = pPatient ~= nil and CreatureObject(pPatient):getFirstName() or tostring(item.oid)

	if pPatient ~= nil then
		local wound, amount = self:nextWound(pPatient)
		local woundsLeft = wound ~= nil and ("; " .. amount .. " wounds left on " .. wound.name) or ""

		if item.kind == "buff" then
			local landed = {}

			for _, buff in ipairs(botGetBuffs(pPatient) or {}) do
				local attribute = tostring(buff.name or ""):lower():match("medical_enhance_(%a+)")

				if attribute ~= nil then
					table.insert(landed, attribute .. " +" .. self:buffAmount(pPatient, attribute, buff) .. " " ..
						math.floor((tonumber(buff.secondsLeft) or 0) / 60) .. " min")
				end
			end

			print("BotJobs: " .. BotJobs:name(oid) .. " buffed " .. patientName .. ": " ..
				(#landed > 0 and table.concat(landed, ", ") or "no enhancement buffs found") .. woundsLeft)

			if item.tipped ~= "1" and percent(self.tipChance) then
				self:say(pBot, oid, item.oid, item.channel, "tip", patientName)
			elseif percent(self.doneChance) then
				self:say(pBot, oid, item.oid, item.channel, "buffDone", patientName)
			end
		else
			print("BotJobs: " .. BotJobs:name(oid) .. " healed " .. patientName .. "'s wounds" .. woundsLeft)

			if wound == nil then
				self:say(pBot, oid, item.oid, item.channel, "woundsDone", patientName)
			end
		end
	end

	writeData(key(oid, "lastPatient"), item.oid)
	writeData(key(oid, "lastPatientAt"), os.time())

	self:finish(pBot)
end

-- Ready for the next patient: refill packs and mind
function BotDoctor:finish(pBot)
	local oid = SceneObject(pBot):getObjectID()

	writeData(key(oid, "workSeq"), readData(key(oid, "workSeq")) + 1)
	writeData(key(oid, "busy"), 0)
	deleteData(key(oid, "patient"))
	deleteStringData(key(oid, "kind"))
	writeData(key(oid, "nextIdle"), os.time() + between(self.idleEvery))

	self:restock(pBot)
	self:topUpMind(pBot)
	self:nextPatient(pBot)
end

-- From BotJobs:tick every few seconds: pending patients, the watchdog, then idling (an emote, or a sit and later
-- standing up)
function BotDoctor:tick(pBot, oid, now)
	self:checkPending(pBot, oid, now)

	if readData(key(oid, "busy")) == 1 then
		if now - readData(key(oid, "workSince")) > self.workTimeout then
			print("BotJobs: " .. BotJobs:name(oid) .. ": a treatment ran over " .. self.workTimeout .. " s, dropped")
			self:finish(pBot)
		end

		return
	end

	self:topUpMind(pBot)

	if readData(key(oid, "sitting")) == 1 then
		if now >= readData(key(oid, "sitUntil")) then
			botEnqueue(pBot, "stand", 0, "")
			writeData(key(oid, "sitting"), 0)
			writeData(key(oid, "nextIdle"), now + between(self.idleEvery))
		end

		return
	end

	if now < readData(key(oid, "nextIdle")) then
		return
	end

	writeData(key(oid, "nextIdle"), now + between(self.idleEvery))

	if percent(self.sitChance) then
		botEnqueue(pBot, "sitserver", 0, "")
		writeData(key(oid, "sitting"), 1)
		writeData(key(oid, "sitUntil"), now + between(self.sitFor))
	else
		botEmote(pBot, BotLines.doctorIdle[getRandomNumber(1, #BotLines.doctorIdle)], 0)
	end
end

-- For BotJobs:list
function BotDoctor:state(pBot, oid)
	local queued, pending = #self:loadList(oid, "queue"), #self:loadList(oid, "pending")
	local state = "idle"

	if readData(key(oid, "busy")) == 1 then
		local pPatient = getSceneObject(readData(key(oid, "patient")))

		state = readStringData(key(oid, "kind")) .. " for " ..
			(pPatient ~= nil and CreatureObject(pPatient):getFirstName() or tostring(readData(key(oid, "patient"))))
	elseif readData(key(oid, "sitting")) == 1 then
		state = "sitting"
	end

	if queued > 0 then
		state = state .. ", " .. queued .. " waiting"
	end

	if pending > 0 then
		state = state .. ", " .. pending .. " asked from afar"
	end

	if pBot ~= nil then
		state = state .. ", mind " .. math.floor(CreatureObject(pBot):getHAM(MIND)) .. "/" ..
			math.floor(CreatureObject(pBot):getMaxHAM(MIND))
	end

	return state
end
