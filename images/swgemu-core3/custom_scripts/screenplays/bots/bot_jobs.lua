-- Bot players (Phase 3): the jobs of the master doctors and dancers that the server plays in Mos Eisley, Coronet and
-- Theed. Spec: ~/github/swgemu/specs/2026-10-23-bot-players/ (interfaces.md is the contract with the C++ body).
--
-- The C++ part (patches/bots/) gives a bot its body: it logs the bot in and out, runs its commands and carries its
-- chat. It calls three events here, in a task with the bot locked:
--   BotJobs:onLogin(pBot)                           in the world and scene-ready: start the job
--   BotJobs:onLogout(pBot)                          just before it logs out
--   BotJobs:onHeard(pBot, pSpeaker, text, channel)  a human spoke within 25 m ("spatial") or sent a tell ("tell")
-- The jobs (doctor.lua, dancer.lua) run as events on the bot, so they hold its lock. Lua state is per thread, so their
-- state lives in shared memory, and every timer chain carries the bot's generation, bumped at each login and logout.
-- Chat goes through Phase 2's mailbox (LivingTalk in living_cities/talk.lua); a bot's reply carries an action on its
-- fourth line. Without the language model the jobs still work by keyword ("buff", "wound").
--
-- Console (output in the pod log):
--   runLuaFunction BotJobs:list                 every bot, online or not, and what its job is doing
--   runLuaFunction BotJobs:login:<first>        force a bot in (logout: out) until the online rule next changes
--   runLuaFunction BotJobs:devHuman:on          pretend a human is online (off: stop); the local server has no client
--   runLuaFunction BotJobs:devBuffs:<first>     a bot's buffs, wounds, battle fatigue and HAM
--   runLuaFunction BotJobs:restart              start every online bot's job afresh (after reloadscreenplays)
-- Development, bot on bot (there is no game client on the local server):
--   runLuaFunction BotJobs:devSay:<first>:<from>:<text>   bot <from> says <text> to bot <first> (devTell: by tell);
--                                                         "_" in the text is a space
--   runLuaFunction BotJobs:devBring:<first>:<to>[:<m>]    teleport a bot next to another, or <m> metres east of it
--                                                         (devHome:<first>: back to its station)
--   runLuaFunction BotJobs:devWound:<first>:<amount>      wounds on its six health and action pools
--   runLuaFunction BotJobs:devFatigue:<first>:<amount>    battle fatigue
--   runLuaFunction BotJobs:devWatch:<first>:<dancer>      /watch a dancer (devStopWatch:<first>: stop watching)
--   runLuaFunction BotJobs:devTip:<first>:<to>:<credits>  a real /tip from one bot to another

-- Job modules. Each file defines a screenplay table and registers it in BotJobModules under its job name(s):
--   BotJobModules = BotJobModules or {}; BotJobModules.doctor = BotDoctor
-- A module provides start(pBot, oid), clear(oid), tick(pBot, oid, now), state(pBot, oid) -> string,
-- intent(text) -> an intent or nil (keywords, used without the brain), isAction(intent) -> bool,
-- allowed(action) -> the action or nil (checks the brain's line 4), act(pBot, pPlayer, action, channel, brainLine),
-- and optionally onSpoken(pBot, oid, pSpeaker, channel, text) -> true when the job answered it itself (nothing goes
-- to the brain), onSaid(pBot, oid, playerOid, channel, line) (what it just said, for a record),
-- groupAddressed(pBot, pSpeaker, text) -> bool,
-- and the fields kit and place (what the brain knows the job as). Missing functions are skipped.
-- BotFight (fight.lua) isn't a job: it runs for every bot (provoked fights, duels).
includeFile("../custom_scripts/screenplays/bots/lines.lua")
includeFile("../custom_scripts/screenplays/bots/doctor.lua")
includeFile("../custom_scripts/screenplays/bots/dancer.lua")
includeFile("../custom_scripts/screenplays/bots/musician.lua")
includeFile("../custom_scripts/screenplays/bots/smuggler.lua")
includeFile("../custom_scripts/screenplays/bots/crew.lua")
includeFile("../custom_scripts/screenplays/bots/fight.lua")
includeFile("../custom_scripts/screenplays/bots/mayor.lua")
includeFile("../custom_scripts/screenplays/bots/citizen.lua")
-- Phase 11 (built with 9b): buff time left, the group's window and the 15-minute warning
includeFile("../custom_scripts/screenplays/bots/buffs.lua")

BotJobs = ScreenPlay:new {
	screenplayName = "BotJobs",

	-- Each bot's job ticks this often (idle emotes, sitting, flourishes, dance changes, tips)
	tickMs = 5000,

	-- roster.lua settings, when it doesn't set them
	defaults = {enhancePower = 700, enhanceDuration = 10800, woundPower = 250, packStock = 20},

	-- What the talk bridge knows each job as (Phase 2's kits and places)
	kits = {doctor = "medic", dancer = "entertainer"},
	places = {doctor = "medical", dancer = "cantina"},

	-- A tip from the latest patient within this many seconds gets a thank-you by name
	thankWindow = 1800,
	-- Within this range a thank-you is said out loud; further away it's a tell
	sayRange = 40,
	-- Lines shown in the log are cut to this length
	logChars = 120,
	-- Seconds to wait for the brain: bots may talk at any length, so longer than the crowd's 12 (the bridge's
	-- TALK_BOT_DEADLINE must match)
	deadline = 40,
	-- A long reply's next chat line follows this long after the last (ms), like someone typing
	moreLineMs = 2500,
}

registerScreenPlay("BotJobs", true)

-- The module for a job (see the top of this file), or nil
function BotJobs:module(job)
	return BotJobModules ~= nil and job ~= nil and BotJobModules[job] or nil
end

-- Helpers

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

-- "a:b:c" for event arguments, and back (no empty fields: they would vanish)
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

local function firstOf(name)
	return tostring(name or ""):match("^(%S+)") or ""
end

local function short(text, n)
	text = tostring(text or "")

	if #text > n then
		return text:sub(1, n - 3) .. "..."
	end

	return text
end

local function botsBuilt()
	return botList ~= nil
end

function BotJobs:start()
	local count = BotRoster ~= nil and BotRoster.bots ~= nil and #BotRoster.bots or 0

	print("BotJobs: started, " .. count .. " bots in the roster" .. (botsBuilt() and "" or "; this build has no bot players"))
end

-- The roster

function BotJobs:setting(name)
	local settings = BotRoster ~= nil and BotRoster.settings or nil

	if settings ~= nil and settings[name] ~= nil then
		return settings[name]
	end

	return self.defaults[name]
end

-- A roster entry by first name (case doesn't matter), or nil
function BotJobs:entry(firstName)
	if BotRoster == nil or BotRoster.bots == nil then
		return nil
	end

	local want = tostring(firstName or ""):lower()

	for _, entry in ipairs(BotRoster.bots) do
		if firstOf(entry.name):lower() == want then
			return entry
		end
	end

	return nil
end

-- An online bot's job, city and names, as onLogin stored them
function BotJobs:job(oid)
	return readStringData(key(oid, "job"))
end

function BotJobs:city(oid)
	return readStringData(key(oid, "city"))
end

function BotJobs:name(oid)
	return readStringData(key(oid, "name"))
end

function BotJobs:online(oid)
	return readData(key(oid, "online")) == 1
end

-- Is this chain (started in generation gen) still the bot's current one, and the bot in the world?
function BotJobs:current(pBot, gen)
	if pBot == nil then
		return false
	end

	local oid = SceneObject(pBot):getObjectID()

	return tonumber(gen) == readData(key(oid, "gen")) and self:online(oid) and SceneObject(pBot):getZoneName() ~= ""
end

-- Metres from a bot to someone, or nil when they aren't in the same zone (another planet, or not in the world)
function BotJobs:distance(pBot, pOther)
	if pBot == nil or pOther == nil then
		return nil
	end

	local zone = SceneObject(pBot):getZoneName()

	if zone == "" or SceneObject(pOther):getZoneName() ~= zone then
		return nil
	end

	return SceneObject(pBot):getDistanceTo(pOther)
end

function BotJobs:cash(pBot)
	return math.floor(CreatureObject(pBot):getCashCredits() + CreatureObject(pBot):getBankCredits())
end

-- Events from the C++ body

function BotJobs:onLogin(pBot)
	if pBot == nil then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local first = CreatureObject(pBot):getFirstName()
	local entry = self:entry(first)
	local name, job, city = nil, nil, nil

	if entry ~= nil then
		name, job, city = entry.name, entry.job, entry.city
	elseif botList ~= nil then
		for _, bot in ipairs(botList() or {}) do
			if tostring(bot.firstName):lower() == first:lower() then
				name, job, city = bot.name, bot.job, bot.city
			end
		end
	end

	local module = self:module(job)

	if module == nil then
		print("BotJobs: " .. first .. " logged in with no job module for '" .. tostring(job) .. "'")
		return
	end

	local gen = readData(key(oid, "gen")) + 1

	writeData(key(oid, "gen"), gen)
	writeData(key(oid, "online"), 1)
	writeData(key(oid, "since"), os.time())
	writeStringData(key(oid, "first"), first)
	writeStringData(key(oid, "name"), name or first)
	writeStringData(key(oid, "job"), job)
	writeStringData(key(oid, "city"), city or "")
	writeData(key(oid, "cash"), self:cash(pBot))

	if module.start ~= nil then
		module:start(pBot, oid)
	end

	print("BotJobs: " .. (name or first) .. " logged in, " .. job .. " in " .. (city or "?") .. ", generation " .. gen)

	createEvent(self.tickMs, "BotJobs", "tick", pBot, tostring(gen))
end

function BotJobs:onLogout(pBot)
	if pBot == nil then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	writeData(key(oid, "gen"), readData(key(oid, "gen")) + 1)
	writeData(key(oid, "online"), 0)

	local module = self:module(self:job(oid))

	if module ~= nil and module.clear ~= nil then
		module:clear(oid)
	end

	if BotFight ~= nil and BotFight.clear ~= nil then
		BotFight:clear(oid)
	end

	-- The bridge forgets its conversations
	if LivingTalk ~= nil then
		LivingTalk:npcGone(oid)
	end

	print("BotJobs: " .. self:name(oid) .. " logged out")
end

-- What the C++ parts tell the jobs (Phases 4-6): name is e.g. "trade", "duel", "groupInvite", "fightEnded",
-- "cloned"; pOther may be nil; detail is a string. Goes to the bot's job module and to BotFight.
function BotJobs:onEvent(pBot, name, pOther, detail)
	if pBot == nil then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local module = self:module(self:job(oid))

	if module ~= nil and module.onEvent ~= nil then
		module:onEvent(pBot, oid, name, pOther, detail or "")
	end

	if BotFight ~= nil and BotFight.onEvent ~= nil then
		BotFight:onEvent(pBot, oid, name, pOther, detail or "")
	end
end

function BotJobs:onHeard(pBot, pSpeaker, text, channel)
	-- Only people (the C++ never passes bots, but a bot must never answer a bot)
	if pSpeaker == nil or (isBot ~= nil and isBot(pSpeaker)) then
		return
	end

	self:heard(pBot, pSpeaker, text, channel, false)
end

-- The job's heartbeat: tips, then the doctor's idling or the dancer's flourishes
function BotJobs:tick(pBot, gen)
	if not self:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local now = os.time()

	self:checkTips(pBot, oid)

	local module = self:module(self:job(oid))

	if module ~= nil and module.tick ~= nil then
		module:tick(pBot, oid, now)
	end

	if BotFight ~= nil and BotFight.tick ~= nil then
		BotFight:tick(pBot, oid, now)
	end

	-- Phase 11: each human online has a chain that warns them when their mind buffs run low
	if BotBuffs ~= nil then
		BotBuffs:keep(now)
	end

	createEvent(self.tickMs, "BotJobs", "tick", pBot, gen)
end

-- Tips: /tip adds to the bot's cash (or its bank). When the total goes up, it thanks its latest patient.
function BotJobs:checkTips(pBot, oid)
	local total = self:cash(pBot)
	local before = readData(key(oid, "cash"))

	if total == before then
		return
	end

	writeData(key(oid, "cash"), total)

	if total < before then
		return
	end

	local job, city = self:job(oid), self:city(oid)
	local patientOid = readData(key(oid, "lastPatient"))
	local pPatient = nil

	if patientOid ~= 0 and os.time() - readData(key(oid, "lastPatientAt")) <= self.thankWindow then
		pPatient = getSceneObject(patientOid)
	end

	print("BotJobs: " .. self:name(oid) .. " got " .. (total - before) .. " credits, now " .. total)

	local dist = self:distance(pBot, pPatient)

	if pPatient == nil or dist == nil then
		botEmote(pBot, "thank", 0)
		self:reply(pBot, 0, "spatial", BotLines:pick(job, "thanksAnon", nil, city), "happy")
		return
	end

	local patientName = CreatureObject(pPatient):getFirstName()
	local line = BotLines:pick(job, "thanks", patientName, city)

	if dist <= self.sayRange then
		botEmote(pBot, "thank", patientOid)
		self:reply(pBot, patientOid, "spatial", line, "happy")
	else
		self:reply(pBot, patientOid, "tell", line)
	end
end

-- Talking

-- Did the speaker mean this bot? Like the crowd: they target it, or say its first name (unless they target another
-- bot or a crowd NPC)
function BotJobs:addressed(pBot, pSpeaker, text)
	local oid = SceneObject(pBot):getObjectID()
	local target = CreatureObject(pSpeaker):getTargetID()

	if target == oid then
		return true
	end

	if target ~= 0 then
		if readStringData("lc:npc:" .. target .. ":city") ~= "" then
			return false
		end

		local pTarget = getSceneObject(target)

		if pTarget ~= nil and isBot ~= nil and isBot(pTarget) then
			return false
		end
	end

	local first = (readStringData(key(oid, "first")):lower():gsub("[^%a]", " "))

	if first:match("^%s*$") then
		return false
	end

	local words = " " .. (text:lower():gsub("[^%a]", " ")) .. " "

	return string.find(words, " " .. first .. " ", 1, true) ~= nil
end

-- Is the bot's first name a word in the text?
function BotJobs:namedIn(pBot, text)
	local first = (readStringData(key(SceneObject(pBot):getObjectID(), "first")):lower():gsub("[^%a]", " "))

	if first:match("^%s*$") then
		return false
	end

	local words = " " .. (tostring(text or ""):lower():gsub("[^%a]", " ")) .. " "

	return string.find(words, " " .. first .. " ", 1, true) ~= nil
end

-- What the words ask for, without the language model: an action, a hint (e.g. a line pointing to another job), or
-- nil. Each job module decides.
function BotJobs:intent(job, text)
	local module = self:module(job)

	if module == nil or module.intent == nil then
		return nil
	end

	return module:intent(text)
end

function BotJobs:isAction(job, intent)
	local module = self:module(job)

	return intent ~= nil and module ~= nil and module.isAction ~= nil and module:isAction(intent) == true
end

-- The brain's action (reply line 4), checked against the job; nil for none
function BotJobs:allowed(job, action)
	local module = self:module(job)

	action = tostring(action or ""):lower():gsub("%s", "")

	if action == "" or module == nil or module.allowed == nil then
		return nil
	end

	return module:allowed(action)
end

-- Someone spoke to the bot. dev: a pretend human (another bot) from the console, which skips the addressing check.
function BotJobs:heard(pBot, pSpeaker, text, channel, dev)
	if pBot == nil or pSpeaker == nil or text == nil or text == "" then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if not self:online(oid) then
		return
	end

	if channel ~= "tell" and channel ~= "group" then
		channel = "spatial"
	end

	local job = self:job(oid)
	local module = self:module(job)

	if channel == "spatial" and not dev and not self:addressed(pBot, pSpeaker, text) then
		-- A crew bot on a hunt hears its group's humans out loud, nearby, without being named: it's group talk then
		if module ~= nil and module.spatialGroup ~= nil and module:spatialGroup(pBot, pSpeaker, text) then
			channel = "group"
		elseif module ~= nil and module.spatialHandover ~= nil and module:spatialHandover(pBot, pSpeaker, text) then
			-- (a bot with goods to hand over hears the player it is handing over to, named or not)
		else
			return
		end
	end

	-- Group chat: answered when the bot is named, or when its job says so (one crew member speaks for the group)
	if channel == "group" and not dev and not self:namedIn(pBot, text) and
		not (module ~= nil and module.groupAddressed ~= nil and module:groupAddressed(pBot, pSpeaker, text)) then
		return
	end
	local intent = self:intent(job, text)
	local playerOid = SceneObject(pSpeaker):getObjectID()
	local playerName = CreatureObject(pSpeaker):getFirstName()

	print("BotJobs: " .. self:name(oid) .. " hears " .. playerName .. " (" .. channel .. "): " .. short(text, self.logChars))

	-- The job may react to being spoken to (the doctor turns to whoever talks to it in the room)
	if module ~= nil and module.onSpoken ~= nil and module:onSpoken(pBot, oid, pSpeaker, channel, text) == true then
		return
	end

	local result = self:ask(pBot, oid, playerOid, playerName, text, channel, intent)

	if result == "sent" then
		return
	end

	if self:isAction(job, intent) then
		-- No model to answer (or not now): the job by keyword
		self:act(pBot, playerOid, intent, channel, nil)
	elseif result == "nobrain" then
		-- No model at all: one canned line, then the quiet minute (as the crowd)
		self:canned(pBot, playerOid, channel, intent)
		self:startQuiet()
	end

	-- "busy" (their last question is still waiting) or "quiet" (the minute after a fallback): nothing to say
end

function BotJobs:startQuiet()
	if LivingTalk ~= nil then
		LivingTalk:startQuiet()
	end
end

-- Send what the player said to the talk bridge: "sent", "busy", "quiet" or "nobrain"
function BotJobs:ask(pBot, oid, playerOid, playerName, text, channel, intent)
	if LivingTalk == nil then
		return "nobrain"
	end

	if LivingTalk:isQuiet() then
		return "quiet"
	end

	if not LivingTalk:canAsk(playerOid) then
		return "busy"
	end

	local job, city = self:job(oid), self:city(oid)
	local entry = self:entry(readStringData(key(oid, "first"))) or {}
	local id = LivingTalk:newId(oid)
	local hour = LivingCities ~= nil and LivingCities:hour() or tonumber(os.date("*t").hour)

	local module = self:module(job) or {}
	local request = {
		type = "say", id = id, at = os.time(),
		bot = 1, job = job, channel = channel,
		npc = oid, name = self:name(oid), first = readStringData(key(oid, "first")),
		species = entry.species or "human", sex = entry.sex or "male",
		kit = module.kit or self.kits[job] or "traveller", city = city,
		place = module.place or self.places[job] or "plaza", hour = hour,
		player = playerOid, playerName = playerName, text = text,
	}

	-- The job's own fields (a musician's instrument, a smuggler's prices, grouped, a city's news); they win
	if module.requestFields ~= nil then
		for field, value in pairs(module:requestFields(pBot, oid, playerOid) or {}) do
			request[field] = value
		end
	end

	local sent = LivingTalk:send(id, request)

	if not sent then
		return "nobrain"
	end

	LivingTalk:asked(playerOid)

	createEvent(1000, "BotJobs", "poll", pBot, packArgs(readData(key(oid, "gen")), id, playerOid, 1, channel, intent or "-"))

	return "sent"
end

-- Wait for the bridge's reply (an event on the bot once a second, like the crowd's)
function BotJobs:poll(pBot, args)
	local a = unpackArgs(args)
	local gen, id, playerOid, tries, channel, intent = a[1], a[2], tonumber(a[3]), tonumber(a[4]), a[5], a[6]
	local alive = self:current(pBot, gen)
	local status, mood, line, action, flags, orders, teach = LivingTalk:readReply(id)

	if intent == "-" then
		intent = nil
	end

	if status ~= nil then
		LivingTalk:answered(playerOid)

		if not alive then
			return
		end

		local oid = SceneObject(pBot):getObjectID()
		local job = self:job(oid)

		if status == "ok" and line ~= "" then
			self:reply(pBot, playerOid, channel, line, mood)

			-- The model's action stands (the bridge checks it against the job and the words)
			local todo = self:allowed(job, action)

			if todo ~= nil then
				self:act(pBot, playerOid, todo, channel, line)
			end

			-- Reply line 5: flags about the player's words (e.g. "insult"), for provoked fights
			if BotFight ~= nil and BotFight.onReply ~= nil then
				BotFight:onReply(pBot, playerOid, flags or "", channel)
			end

			-- Reply lines 6 and 7 (the crew, Phase 9b): orders for the tactics table the bridge checked against the player's
			-- words, and the result of a lesson it wrote ("added quillan")
			local module = self:module(job)

			if module ~= nil and module.tacticOrders ~= nil then
				if orders ~= nil and orders ~= "" then
					module:tacticOrders(pBot, oid, playerOid, channel, orders)
				end

				if teach ~= nil and teach ~= "" then
					module:teachResult(pBot, oid, teach)
				end
			end
		else
			-- The bridge couldn't get an answer: the job by keyword, or one canned line; then the quiet minute
			self:startQuiet()
			self:fallback(pBot, playerOid, channel, intent)
		end

		return
	end

	if not alive then
		LivingTalk:answered(playerOid)
		return
	end

	if tries >= self.deadline then
		-- No answer in time
		LivingTalk:answered(playerOid)
		self:startQuiet()
		self:fallback(pBot, playerOid, channel, intent)
		return
	end

	createEvent(1000, "BotJobs", "poll", pBot, packArgs(gen, id, playerOid, tries + 1, channel, intent or "-"))
end

function BotJobs:fallback(pBot, playerOid, channel, intent)
	local job = self:job(SceneObject(pBot):getObjectID())

	if self:isAction(job, intent) then
		self:act(pBot, playerOid, intent, channel, nil)
	else
		self:canned(pBot, playerOid, channel, intent)
	end
end

-- One canned line: a hint at the other job if they asked about it, else the job's fallback
function BotJobs:canned(pBot, playerOid, channel, intent)
	local oid = SceneObject(pBot):getObjectID()
	local job, city = self:job(oid), self:city(oid)
	local pPlayer = getSceneObject(playerOid)
	local name = pPlayer ~= nil and CreatureObject(pPlayer):getFirstName() or nil
	local line = nil

	if intent == "notMine" or intent == "watchHint" then
		line = BotLines:pick(job, intent, name, city)
	elseif intent == "tactics" then
		-- (the crew, Phase 9b: an order or a lesson that the model isn't there to read)
		line = BotLines:pick("crew", "orderNoBrain", name, city)
	end

	line = line or BotLines:pick(job, "fallback", name, city)

	if line == nil and LivingCitiesLines ~= nil and LivingCitiesLines.fallback ~= nil and #LivingCitiesLines.fallback > 0 then
		line = LivingCitiesLines.fallback[getRandomNumber(1, #LivingCitiesLines.fallback)]
	end

	self:reply(pBot, playerOid, channel, line)
end

-- Do what was asked. brainLine: what the language model answered (the job then adds no line of its own to start, or
-- to send them over), nil if it didn't answer
function BotJobs:act(pBot, playerOid, action, channel, brainLine)
	local oid = SceneObject(pBot):getObjectID()
	local job = self:job(oid)
	local pPlayer = getSceneObject(playerOid)

	if pPlayer == nil then
		return
	end

	local module = self:module(job)

	if module ~= nil and module.act ~= nil then
		module:act(pBot, pPlayer, action, channel, brainLine)
	end
end

-- Say a line, or tell it to the player when the talk was by tell. playerOid 0 with "spatial" just says it.
-- A long reply in chat-sized lines (at most size characters), cut at sentence ends where possible
local function chatLines(text, size)
	local out = {}

	while #text > size do
		local cut = 0

		for i = size, 40, -1 do
			local c = text:sub(i, i)

			if c == "." or c == "!" or c == "?" then
				cut = i
				break
			end
		end

		if cut == 0 then
			cut = text:sub(1, size):match("^.*() ") or size
		end

		table.insert(out, (text:sub(1, cut):gsub("^%s+", ""):gsub("%s+$", "")))
		text = text:sub(cut + 1):gsub("^%s+", "")
	end

	if text ~= "" then
		table.insert(out, text)
	end

	return out
end

-- Say a line, or tell it to the player when the talk was by tell. playerOid 0 with "spatial" just says it. A reply
-- longer than a chat line goes out as several lines a moment apart, like a player typing.
function BotJobs:reply(pBot, playerOid, channel, line, mood)
	if line == nil or line == "" then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local size = LivingTalk ~= nil and LivingTalk.maxChars or 200
	local lines = chatLines((tostring(line):gsub("[%c]", " ")), size)

	if #lines == 0 then
		return
	end

	-- The job may keep a record of what it said (the crew's hunt log)
	local module = self:module(self:job(oid))

	if module ~= nil and module.onSaid ~= nil then
		module:onSaid(pBot, oid, playerOid, channel, table.concat(lines, " "))
	end

	if #lines > 1 then
		writeStringData(key(oid, "more"), table.concat(lines, "\n", 2))
		createEvent(self.moreLineMs, "BotJobs", "replyMore", pBot, packArgs(readData(key(oid, "gen")), playerOid, channel))
	end

	self:sendLine(pBot, playerOid, channel, lines[1], mood)
end

-- The next line of a long reply
function BotJobs:replyMore(pBot, args)
	local a = unpackArgs(args)

	if not self:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local rest = readStringData(key(oid, "more"))

	if rest == "" then
		return
	end

	local first, others = rest:match("^([^\n]*)\n?(.*)$")

	if others ~= nil and others ~= "" then
		writeStringData(key(oid, "more"), others)
		createEvent(self.moreLineMs, "BotJobs", "replyMore", pBot, args)
	else
		deleteStringData(key(oid, "more"))
	end

	self:sendLine(pBot, tonumber(a[2]), a[3], first, "")
end

function BotJobs:sendLine(pBot, playerOid, channel, line, mood)
	if line == nil or line == "" then
		return
	end

	local name = self:name(SceneObject(pBot):getObjectID())

	if channel == "group" then
		botEnqueue(pBot, "groupchat", 0, line)
		print("BotJobs: " .. name .. " (group): " .. line)
	elseif channel == "tell" then
		local pPlayer = getSceneObject(playerOid)
		local to = pPlayer ~= nil and CreatureObject(pPlayer):getFirstName() or ""

		if to == "" then
			return
		end

		botTell(pBot, to, line)
		print("BotJobs: " .. name .. " tells " .. to .. ": " .. line)
	else
		botSay(pBot, line, mood or "")
		print("BotJobs: " .. name .. " says: " .. line)
	end
end

-- Console

function BotJobs:list()
	if not botsBuilt() then
		print("BotJobs: this build has no bot players")
		return
	end

	local bots = botList() or {}
	local brain = LivingTalk ~= nil and LivingTalk:bridgeAlive()

	print("BotJobs: " .. #bots .. " bots; talk bridge " .. (brain and "running" or "not running") ..
		(LivingTalk ~= nil and LivingTalk:isQuiet() and " (quiet minute)" or ""))

	for _, bot in ipairs(bots) do
		local oid = tonumber(bot.oid) or 0
		local state = tostring(bot.state or (bot.online and "online" or "offline")) .. (bot.forced and " (forced)" or "")

		if bot.online then
			local pBot = botGetCreature(bot.firstName)
			local job = self:job(oid)

			local module = self:module(job)

			if module ~= nil and module.state ~= nil then
				state = state .. ", " .. module:state(pBot, oid)
			else
				state = state .. ", no job"
			end

			if pBot ~= nil then
				state = state .. ", " .. self:cash(pBot) .. " cr"
			end
		end

		print(string.format("BotJobs:   %-24s %-6s %-10s oid %-12s %s", tostring(bot.name), tostring(bot.job),
			tostring(bot.city), tostring(bot.oid), state))
	end
end

function BotJobs:status()
	self:list()
end

function BotJobs:login(first)
	if not botsBuilt() then
		print("BotJobs: this build has no bot players")
		return
	end

	print("BotJobs: login " .. tostring(first) .. ": " .. tostring(botLogin(first or "")))
end

function BotJobs:logout(first)
	if not botsBuilt() then
		print("BotJobs: this build has no bot players")
		return
	end

	print("BotJobs: logout " .. tostring(first) .. ": " .. tostring(botLogout(first or "")))
end

function BotJobs:devHuman(on)
	if not botsBuilt() then
		print("BotJobs: this build has no bot players")
		return
	end

	local value = on == "on" or on == "1" or on == "true"

	botSetDevHuman(value)
	print("BotJobs: pretend human online: " .. tostring(value))
end

-- Start every online bot's job afresh (a new generation), e.g. after reloadscreenplays
function BotJobs:restart()
	if not botsBuilt() then
		print("BotJobs: this build has no bot players")
		return
	end

	for _, bot in ipairs(botList() or {}) do
		local pBot = bot.online and botGetCreature(bot.firstName) or nil

		if pBot ~= nil then
			createEvent(10, "BotJobs", "onLogin", pBot, "")
		end
	end

	print("BotJobs: restarting the online bots' jobs")
end

local poolNames = {"health", "strength", "constitution", "action", "quickness", "stamina", "mind", "focus", "willpower"}

-- A bot's buffs, wounds, battle fatigue and HAM (current/max, base): a buff shows as max above base
function BotJobs:devBuffs(first)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: no online bot called " .. tostring(first))
		return
	end

	local creature = CreatureObject(pBot)
	local buffs = botGetBuffs(pBot) or {}

	print("BotJobs: " .. creature:getFirstName() .. ": " .. #buffs .. " buffs, battle fatigue " .. botGetShockWounds(pBot))

	for _, buff in ipairs(buffs) do
		print(string.format("BotJobs:   buff %-36s %6d s left (%d min)%s", tostring(buff.name), tonumber(buff.secondsLeft) or 0,
			math.floor((tonumber(buff.secondsLeft) or 0) / 60), buff.value ~= nil and (", value " .. tostring(buff.value)) or ""))
	end

	for pool = 0, 8 do
		print(string.format("BotJobs:   %-12s %5d / %5d, base %5d, wounds %4d", poolNames[pool + 1], creature:getHAM(pool),
			creature:getMaxHAM(pool), creature:getBaseHAM(pool), botGetWounds(pBot, pool)))
	end
end

-- Development: run a bot's event on another bot's speech from the console (in an event on the bot, holding its lock)
function BotJobs:devSay(first, from, text)
	self:devSpeak(first, from, text, "spatial")
end

function BotJobs:devTell(first, from, text)
	self:devSpeak(first, from, text, "tell")
end

function BotJobs:devSpeak(first, from, text, channel)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil
	local pFrom = botsBuilt() and botGetCreature(from or "") or nil

	if pBot == nil or pFrom == nil or text == nil or text == "" then
		print("BotJobs: usage devSay:<bot>:<from bot>:<text>, both online")
		return
	end

	text = text:gsub("_", " ")
	createEvent(10, "BotJobs", "devHeard", pBot, packArgs(SceneObject(pFrom):getObjectID(), channel, text))
end

function BotJobs:devHeard(pBot, args)
	local a = unpackArgs(args)
	local pFrom = getSceneObject(tonumber(a[1]))

	self:heard(pBot, pFrom, a[3], a[2], true)
end

-- Teleport a bot next to another (both on one planet), or metres east of it, for bot-on-bot tests
function BotJobs:devBring(first, to, metres)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil
	local pTo = botsBuilt() and botGetCreature(to or "") or nil

	if pBot == nil or pTo == nil or SceneObject(pBot):getZoneName() ~= SceneObject(pTo):getZoneName() then
		print("BotJobs: usage devBring:<bot>:<to bot>, both online on one planet")
		return
	end

	local x, z, y = SceneObject(pTo):getPositionX(), SceneObject(pTo):getPositionZ(), SceneObject(pTo):getPositionY()

	local dx = tonumber(metres or "") or 1.5

	createEvent(10, "BotJobs", "devTeleport", pBot, packArgs(x + dx, z, y + (metres == nil and 1.0 or 0), SceneObject(pTo):getParentID()))
end

-- Back to its roster station
function BotJobs:devHome(first)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil
	local entry = self:entry(first)

	if pBot == nil or entry == nil or entry.station == nil then
		print("BotJobs: no online roster bot called " .. tostring(first))
		return
	end

	local s = entry.station

	createEvent(10, "BotJobs", "devTeleport", pBot, packArgs(s.x, s.z, s.y, s.cell or 0))
end

function BotJobs:devTeleport(pBot, args)
	local a = unpackArgs(args)

	SceneObject(pBot):teleport(tonumber(a[1]), tonumber(a[2]), tonumber(a[3]), tonumber(a[4]))
	print("BotJobs: " .. CreatureObject(pBot):getFirstName() .. " teleported to " .. args)
end

-- Wounds on the six health and action pools, or battle fatigue, set by hand
function BotJobs:devWound(first, amount)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: no online bot called " .. tostring(first))
		return
	end

	createEvent(10, "BotJobs", "devSetWounds", pBot, tostring(tonumber(amount) or 300))
end

function BotJobs:devSetWounds(pBot, amount)
	for pool = 0, 5 do
		CreatureObject(pBot):setWounds(pool, tonumber(amount))
	end

	print("BotJobs: " .. CreatureObject(pBot):getFirstName() .. " has " .. amount .. " wounds on each health and action pool")
end

function BotJobs:devFatigue(first, amount)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: no online bot called " .. tostring(first))
		return
	end

	createEvent(10, "BotJobs", "devSetFatigue", pBot, tostring(tonumber(amount) or 500))
end

function BotJobs:devSetFatigue(pBot, amount)
	CreatureObject(pBot):setShockWounds(tonumber(amount))
	print("BotJobs: " .. CreatureObject(pBot):getFirstName() .. " has " .. amount .. " battle fatigue")
end

function BotJobs:devWatch(first, dancer)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil
	local pDancer = botsBuilt() and botGetCreature(dancer or "") or nil

	if pBot == nil or pDancer == nil then
		print("BotJobs: usage devWatch:<bot>:<dancer bot>, both online")
		return
	end

	print("BotJobs: " .. tostring(first) .. " watches " .. tostring(dancer) .. ": " ..
		tostring(botEnqueue(pBot, "watch", SceneObject(pDancer):getObjectID(), "")))
end

-- A real /tip from one bot to another (the tipper gets the cash first)
function BotJobs:devTip(first, to, amount)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil
	local pTo = botsBuilt() and botGetCreature(to or "") or nil

	if pBot == nil or pTo == nil then
		print("BotJobs: usage devTip:<bot>:<to bot>:<credits>, both online")
		return
	end

	createEvent(10, "BotJobs", "devTipNow", pBot, packArgs(SceneObject(pTo):getObjectID(), tonumber(amount) or 100))
end

function BotJobs:devTipNow(pBot, args)
	local a = unpackArgs(args)
	local amount = tonumber(a[2])
	local cash = CreatureObject(pBot):getCashCredits()

	if cash < amount then
		CreatureObject(pBot):addCashCredits(amount - cash, true)
	end

	print("BotJobs: " .. CreatureObject(pBot):getFirstName() .. " tips " .. a[1] .. " " .. amount .. " credits: " ..
		tostring(botEnqueue(pBot, "tip", tonumber(a[1]), tostring(amount))))
end

function BotJobs:devStopWatch(first)
	local pBot = botsBuilt() and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotJobs: no online bot called " .. tostring(first))
		return
	end

	print("BotJobs: " .. tostring(first) .. " stops watching: " .. tostring(botEnqueue(pBot, "stopwatching", 0, "")))
end
