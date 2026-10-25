-- Bot players simulator (Phase 3): a mock of the Lua API that the C++ body gives the jobs (patches/bots/BotLua.cpp;
-- the contract is ~/github/swgemu/specs/2026-10-23-bot-players/interfaces.md), a few Core3 commands acted out
-- (healenhance and healwound with their 12 s wait, the dance commands), and scenarios that drive the jobs in
-- custom_scripts/screenplays/bots/. living_cities_sim.lua loads this file and lends it its clock, shared memory and
-- world:
--
--   lua living_cities_sim.lua ../../custom_scripts bots                             # brain off
--   SIM_TALK_DIR=$(mktemp -d) lua living_cities_sim.lua ../../custom_scripts botbrain   # the talk bridge faked
--
-- bots: log in, the doctor's buffs (order, waits, range, queue), wounds, tips, idling; the dancer's dances,
-- flourishes and buff target; keywords and the quiet minute with no brain; tells; logout; crowd names.
-- botbrain: replies with actions, chat without one, tells, fallbacks, timeouts, three-line replies, the crowd
-- ignoring bots, and the bridge told when a bot leaves.

return function(ctx)
	local sim, Obj, fail, realPrint = ctx.sim, ctx.Obj, ctx.fail, ctx.realPrint
	local scenarios, order = ctx.scenarios, ctx.order

	local function nowMs()
		return sim.now * 1000 + (sim.subMs or 0)
	end

	-- Core3's pools (CreatureAttribute) and what the mock needs of the commands
	local POOLS = {health = 0, strength = 1, constitution = 2, action = 3, quickness = 4, stamina = 5, mind = 6, focus = 7,
		willpower = 8}
	local ENHANCEABLE = {health = true, action = true, strength = true, constitution = true, quickness = true, stamina = true}
	local MASTER_DANCES = {}
	for _, d in ipairs({"basic", "basic2", "rhythmic", "rhythmic2", "footloose", "formal", "popular", "popular2", "poplock",
		"poplock2", "lyrical", "lyrical2", "exotic", "exotic2", "exotic3", "exotic4", "breakdance", "breakdance2", "tumble",
		"tumble2"}) do
		MASTER_DANCES[d] = true
	end
	local SOCIALS = {}
	for _, e in ipairs({"stretch", "yawn", "ponder", "scratch", "fidget", "sigh", "adjust", "tap", "contemplate", "nod", "thank",
		"wave", "bow"}) do
		SOCIALS[e] = true
	end

	-- Globals the screenplays read at call time
	MIND, ACTION, HEALTH = 6, 3, 0
	POSTURESITTING, UPRIGHT = 8, 0

	-- Creature parts of the world objects (players, bots)

	function Obj:pool(pool, field)
		self.ham = self.ham or {}
		self.ham[pool] = self.ham[pool] or {cur = 1000, base = 1000}
		return self.ham[pool]
	end
	-- An enhancement raises the pool's maximum by its amount (Core3 also fills health and action)
	function Obj:buffBonus(pool)
		local bonus = 0
		for name, b in pairs(self.buffs or {}) do
			if POOLS[name:match("^medical_enhance_(%a+)$") or ""] == pool and sim.now < b.expires then
				bonus = bonus + b.amount
			end
		end
		return bonus
	end
	function Obj:getHAM(pool) return self:pool(pool).cur end
	function Obj:setHAM(pool, v)
		assert(math.type(v) == "integer" or v == math.floor(v), "setHAM with a fraction")
		assert(v <= self:getMaxHAM(pool), "setHAM above the maximum")
		self:pool(pool).cur = v
		self.hamSets = (self.hamSets or 0) + 1
	end
	function Obj:getBaseHAM(pool) return self:pool(pool).base end
	function Obj:getMaxHAM(pool) return self:pool(pool).base + self:buffBonus(pool) end
	function Obj:getCashCredits() return self.cash or 0 end
	function Obj:getBankCredits() return self.bank or 0 end
	function Obj:getSkillMod(name) return (self.skillMods or {})[name] or 0 end
	-- A bot has its roster skills (and everything they require, which the mock doesn't model: any box counts)
	function Obj:hasSkill(name)
		if self.skills ~= nil then
			return self.skills[name] == true
		end
		return self.isBotFlag == true
	end
	function Obj:isDancing() return self.dancing ~= nil end
	function Obj:getPosture() return self.posture == "sitting" and POSTURESITTING or UPRIGHT end
	function Obj:isInCombat() return false end
	function Obj:setWounds(pool, v) self.wounds = self.wounds or {}; self.wounds[pool] = v end
	function Obj:setShockWounds(v) self.shock = v end
	function Obj:getLastName() return self.last or "" end
	-- What the crew (crew.lua) reads of any creature, at rest: no group, no fight, alive, nothing queued. Its own
	-- scenarios (bots_crew_sim.lua) act groups and fights out.
	function Obj:isGrouped() return self.groupId ~= nil end
	function Obj:getGroupSize() return 0 end
	function Obj:getGroupMember(i) return nil end
	function Obj:getGroupID() return self.groupId or 0 end
	function Obj:isDead() return self.dead == true end
	function Obj:isIncapacitated() return self.incap == true end
	function Obj:getMainDefender() return nil end
	function Obj:hasState(state) return 0 end
	function Obj:getQueueSize() return 0 end
	function Obj:getCurrentSpeed() return 0 end
	function Obj:isCreatureObject() return self.isPlayer == true end
	function Obj:getDisplayedName() return self.name or self.first or "someone" end
	function Obj:isAttackableBy(other) return false end
	function Obj:getWorldPositionX() return self:getPositionX() end
	function Obj:getWorldPositionY() return self:getPositionY() end
	function Obj:switchZone(planet, x, z, y, cell) self.planet, self.x, self.z, self.y, self.cell = planet, x, z, y, cell end

	-- The mock bot API (interfaces.md "Lua API")

	local log = {}
	local bots = {} -- by lowercase first name

	local function resetLog()
		log = {commands = {}, says = {}, tells = {}, emotes = {}, faces = {}, stocks = {}}
	end
	resetLog()

	local function firstOf(name)
		return (tostring(name):match("^(%S+)"))
	end

	local function distance(a, b)
		if a == nil or b == nil or a.planet ~= b.planet then
			return math.huge
		end
		return a:getDistanceTo(b)
	end

	local function treatmentDelayMs(doctor)
		local delay = math.floor(doctor:getSkillMod("healing_wound_speed") * -(2 / 25) + 20 + 0.5)
		return math.max(delay, 3) * 1000
	end

	-- Core3's healenhance and healwound, as far as the jobs depend on them
	local function treat(bot, command, target, args)
		local patient = ctx.objects[target]
		if patient == nil then
			return false, "no target"
		end
		if nowMs() < (bot.treatmentReady or 0) then
			return false, "must wait"
		end
		local range = command == "healenhance" and 7 or 6
		if distance(bot, patient) > range then
			return false, "too far"
		end
		local cost = command == "healenhance" and 150 or 50
		if bot:getHAM(POOLS.mind) < cost then
			return false, "not enough mind"
		end
		local attr = args:match("^(%a+)")
		if command == "healenhance" then
			if not ENHANCEABLE[attr or ""] then
				return false, "bad attribute " .. tostring(args)
			end
			local pack = bot.packs["object/tangible/medicine/crafted/medpack_enhance_" .. attr .. "_d.iff"]
			if pack == nil or pack.uses <= 0 then
				return false, "no valid medicine"
			end
			pack.uses = pack.uses - 1
			-- Power doubled by master doctor (healing_wound_treatment 100) in a hospital (rating 100)
			patient.buffs = patient.buffs or {}
			patient.buffs["medical_enhance_" .. attr] = {amount = pack.power * 2, expires = sim.now + pack.duration}
		else
			local pool = POOLS[attr or ""]
			if pool == nil or pool > 5 then
				return false, "bad pool " .. tostring(args)
			end
			local pack = bot.packs["object/tangible/medicine/crafted/medpack_wound_" .. attr .. "_e.iff"]
			if pack == nil or pack.uses <= 0 then
				return false, "no valid medicine"
			end
			local wounds = (patient.wounds or {})[pool] or 0
			if wounds == 0 then
				return false, "no wounds of that type"
			end
			pack.uses = pack.uses - 1
			patient.wounds[pool] = math.max(0, wounds - pack.power * 4)
		end
		bot:pool(POOLS.mind).cur = bot:getHAM(POOLS.mind) - cost
		bot.treatmentReady = nowMs() + treatmentDelayMs(bot)
		return true
	end

	local function runCommand(bot, command, target, args)
		if command == "healenhance" or command == "healwound" then
			return treat(bot, command, target, args)
		elseif command == "startdance" then
			if bot.dancing ~= nil then
				return false, "already performing"
			end
			if not MASTER_DANCES[args] then
				return false, "unknown dance " .. args
			end
			bot.dancing = args
			return true
		elseif command == "changedance" then
			if bot.dancing == nil then
				return false, "not dancing"
			end
			if not MASTER_DANCES[args] then
				return false, "unknown dance " .. args
			end
			bot.dancing = args
			return true
		elseif command == "stopdance" then
			bot.dancing, bot.buffTarget = nil, nil
			return true
		elseif command == "flourish" then
			local n = tonumber(args)
			if bot.dancing == nil then
				return false, "not performing"
			end
			if n == nil or n < 1 or n > 8 or math.type(n) ~= "integer" then
				return false, "bad flourish " .. args
			end
			bot.flourishes = (bot.flourishes or 0) + 1
			return true
		elseif command == "setperformancebufftarget" then
			local patient = ctx.objects[target]
			if patient == nil or patient == bot or not patient.isPlayer then
				return false, "invalid target"
			end
			bot.buffTarget = target
			return true
		elseif command == "sitserver" then
			bot.posture = "sitting"
			return true
		elseif command == "stand" then
			bot.posture = "upright"
			return true
		elseif command == "watch" or command == "stopwatching" then
			return true
		end
		return false, "unknown command " .. command
	end

	function botList()
		local out = {}
		for _, entry in ipairs(BotRoster.bots) do
			local b = bots[firstOf(entry.name):lower()]
			table.insert(out, {name = entry.name, firstName = firstOf(entry.name), job = entry.job, city = entry.city,
				oid = b and b.oid or 0, online = b ~= nil and b.online == true})
		end
		return out
	end

	function botGetCreature(first)
		local b = bots[tostring(first):lower()]
		if b ~= nil and b.online then
			return b
		end
		return nil
	end

	function isBot(p)
		return p ~= nil and p.isBotFlag == true
	end

	function botSetDevHuman(on)
		log.devHuman = on
	end

	function botEnqueue(bot, command, target, args)
		assert(type(command) == "string" and command == command:lower(), "botEnqueue: command must be a lowercase name")
		assert(math.type(target) == "integer", "botEnqueue: target must be an integer oid, got " .. tostring(target))
		assert(type(args) == "string", "botEnqueue: args must be a string")
		if bot == nil or not bot.isBotFlag or not bot.online then
			return false
		end
		local ok, why = runCommand(bot, command, target, args)
		table.insert(log.commands, {bot = bot.oid, t = nowMs(), cmd = command, target = target, args = args, ok = ok, why = why})
		return true
	end

	function botSay(bot, text, mood)
		assert(type(text) == "string" and #text > 0 and not text:find("[%c]"), "botSay: bad line " .. tostring(text))
		assert(not text:find("{name}") and not text:find("{city}"), "unfilled placeholder: " .. text)
		assert(type(mood) == "string", "botSay: mood must be a string")
		table.insert(log.says, {bot = bot.oid, t = nowMs(), text = text, mood = mood})
		if sim.chatLog then
			table.insert(sim.chatLog, bot.name .. ": " .. text)
		end
	end

	function botTell(bot, to, text)
		assert(type(to) == "string" and #to > 0, "botTell: no name")
		assert(type(text) == "string" and #text > 0 and not text:find("[%c]"), "botTell: bad line")
		assert(not text:find("{name}") and not text:find("{city}"), "unfilled placeholder: " .. text)
		table.insert(log.tells, {bot = bot.oid, t = nowMs(), to = to, text = text})
		return true
	end

	function botEmote(bot, emote, target)
		-- The real server checks names against the client's social_types table (an unknown one returns false); the
		-- mock only insists on a plausible name
		assert(SOCIALS[emote] or tostring(emote):match("^%l+$"), "botEmote: unknown social " .. tostring(emote))
		assert(math.type(target) == "integer", "botEmote: target must be an integer oid")
		table.insert(log.emotes, {bot = bot.oid, t = nowMs(), emote = emote, target = target})
	end

	function botFace(bot, target)
		assert(target ~= nil, "botFace: no target")
		bot.facing = target.oid
		table.insert(log.faces, {bot = bot.oid, t = nowMs(), target = target.oid})
	end

	function botStockPack(bot, template, uses, power, duration)
		-- Phase 3's enhance and wound packs; Phase 5's stims, ranged stims, state, cure and revive packs (any crafted
		-- medicine template, as BotItems::stockPack takes)
		assert(type(template) == "string" and template:match("^object/tangible/medicine/[%w_/]+%.iff$"),
			"botStockPack: bad template " .. tostring(template))
		bot.packs = bot.packs or {}
		local pack = bot.packs[template]
		if pack == nil or pack.uses < uses or pack.power ~= power or pack.duration ~= duration then
			bot.packs[template] = {uses = math.max(uses, pack and pack.uses or 0), power = power, duration = duration}
		end
		table.insert(log.stocks, {bot = bot.oid, template = template, uses = uses, power = power, duration = duration})
		return true
	end

	function botGetWounds(p, pool)
		return p ~= nil and (p.wounds or {})[pool] or 0
	end

	function botGetShockWounds(p)
		return p ~= nil and p.shock or 0
	end

	function botGetBuffs(p)
		local out = {}
		for name, b in pairs(p ~= nil and p.buffs or {}) do
			if sim.now < b.expires then
				table.insert(out, {name = name, crc = 0, secondsLeft = b.expires - sim.now})
			end
		end
		return out
	end

	-- The roster: the real one if it's there
	local function ensureRoster()
		if BotRoster ~= nil then
			return "custom_scripts/bots/roster.lua"
		end
		BotRoster = {
			settings = {loginDelay = 60, logoutDelay = 600, enhancePower = 700, enhanceDuration = 10800, woundPower = 250,
				packStock = 20},
			bots = {
				{name = "Tessa Vruun", species = "twilek", sex = "female", job = "doctor", city = "mos_eisley",
					station = {planet = "tatooine", x = 0, z = 0, y = 0, cell = 0, heading = 0}},
				{name = "Kirra Solenne", species = "human", sex = "female", job = "dancer", city = "mos_eisley",
					station = {planet = "tatooine", x = 0, z = 0, y = 0, cell = 0, heading = 0}},
				{name = "Haldor Venmark", species = "human", sex = "male", job = "doctor", city = "coronet",
					station = {planet = "corellia", x = 0, z = 0, y = 0, cell = 0, heading = 0}},
				{name = "Nyssa Okaru", species = "zabrak", sex = "female", job = "dancer", city = "coronet",
					station = {planet = "corellia", x = 0, z = 0, y = 0, cell = 0, heading = 0}},
				{name = "Obrin Talvez", species = "bothan", sex = "male", job = "doctor", city = "theed",
					station = {planet = "naboo", x = 0, z = 0, y = 0, cell = 0, heading = 0}},
				{name = "Liessa Marrow", species = "twilek", sex = "female", job = "dancer", city = "theed",
					station = {planet = "naboo", x = 0, z = 0, y = 0, cell = 0, heading = 0}},
			},
		}
		return "a test roster (custom_scripts/bots/roster.lua not written yet)"
	end

	-- The roster has what the jobs read
	local function checkRoster(label)
		local seen, jobs = {}, {}
		local knownJobs = {doctor = true, dancer = true, musician = true, smuggler = true, tank = true, rifleman = true,
			medic = true, ranger = true, squadleader = true, entertainer = true, commando = true, mayor = true, citizen = true}
		-- The player city (Phase 6) isn't a Living Cities city
		local extraCities = {varenhal = "naboo"}
		if #BotRoster.bots < 6 then
			fail(label .. ": " .. #BotRoster.bots .. " bots in the roster, expected at least 6")
		end
		for _, e in ipairs(BotRoster.bots) do
			local first = firstOf(e.name or "")
			local oneWord = e.species == "wookiee" and e.name:match("^%S+$")
			if first == nil or not (e.name:match("^%S+ %S+$") or oneWord) then
				fail(label .. ": roster name " .. tostring(e.name) .. " isn't Firstname Lastname")
			elseif seen[first:lower()] then
				fail(label .. ": first name " .. first .. " twice in the roster")
			end
			seen[(first or ""):lower()] = true
			if not knownJobs[e.job or ""] then
				fail(label .. ": " .. tostring(e.name) .. " has job " .. tostring(e.job))
			end
			local planet = extraCities[e.city or ""] or (LivingCitiesData[e.city or ""] or {}).planet
			if planet == nil then
				fail(label .. ": " .. tostring(e.name) .. " in unknown city " .. tostring(e.city))
			elseif e.station == nil or e.station.planet ~= planet then
				fail(label .. ": " .. tostring(e.name) .. "'s station isn't on its city's planet")
			end
			if type(e.species) ~= "string" or (e.sex ~= "male" and e.sex ~= "female") then
				fail(label .. ": " .. tostring(e.name) .. " species/sex")
			end
			jobs[(e.city or "") .. ":" .. (e.job or "")] = true
		end
		for _, city in ipairs({"mos_eisley", "coronet", "theed"}) do
			if not (jobs[city .. ":doctor"] and jobs[city .. ":dancer"]) then
				fail(label .. ": " .. city .. " lacks a doctor or a dancer")
			end
		end
		for _, k in ipairs({"enhancePower", "enhanceDuration", "woundPower", "packStock"}) do
			if type((BotRoster.settings or {})[k]) ~= "number" then
				fail(label .. ": roster setting " .. k .. " missing")
			end
		end
	end

	-- The bots and players of a scenario: each city's doctor at (1000, 1000) on its planet, its dancer 300 m east
	local function makeBots()
		bots = {}
		for _, entry in ipairs(BotRoster.bots) do
			local first = firstOf(entry.name)
			local b = ctx.newObject({
				isBotFlag = true, isPlayer = true, first = first, last = entry.name:match("%S+$"), name = entry.name,
				planet = (LivingCitiesData[entry.city] or {}).planet or (entry.station or {}).planet or "naboo", x = entry.job == "doctor" and 1000 or 1300, y = 1000, z = 5,
				cell = 0, inWorld = false, online = false, cash = 120, bank = 5000, packs = {}, buffs = {},
				skillMods = entry.job == "doctor" and {healing_wound_speed = 100, healing_ability = 100} or {},
			})
			bots[first:lower()] = b
			ctx.addPlayer(b)
		end
	end

	-- Like the C++ body: a bot in the world, scene-ready, then its event
	function botLogin(first)
		local b = bots[tostring(first):lower()]
		if b == nil then
			return false
		end
		b.online, b.inWorld = true, true
		sim.call("BotJobs", "onLogin", b)
		return true
	end

	function botLogout(first)
		local b = bots[tostring(first):lower()]
		if b == nil or not b.online then
			return false
		end
		sim.call("BotJobs", "onLogout", b)
		b.online, b.inWorld, b.dancing = false, false, nil
		return true
	end

	local function makePlayer(first, planet, x, y)
		local p = ctx.newObject({isPlayer = true, first = first, planet = planet, x = x, y = y, z = 5, cell = 0, inWorld = true,
			buffs = {}, wounds = {}})
		ctx.addPlayer(p)
		return p
	end

	-- A human speaks to a bot (the C++ calls onHeard in a task with the bot locked)
	local function speak(bot, player, text, channel)
		sim.call("BotJobs", "onHeard", bot, player, text, channel or "spatial")
	end

	local function commands(bot, name, since)
		local out = {}
		for _, c in ipairs(log.commands) do
			if c.bot == bot.oid and (name == nil or c.cmd == name) and c.t >= (since or 0) then
				table.insert(out, c)
			end
		end
		return out
	end

	local function linesOf(bot, since, list)
		local out = {}
		for _, s in ipairs(list or log.says) do
			if s.bot == bot.oid and s.t >= (since or 0) then
				table.insert(out, s)
			end
		end
		return out
	end

	-- Is the line one of these canned ones (with any {name}/{city})?
	local function isLine(text, job, kind)
		for _, pattern in ipairs(BotLines[job][kind] or {}) do
			local p = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("{name}", ".-"):gsub("{city}", ".-") .. "$"
			if text:match(p) then
				return true
			end
		end
		return false
	end

	local function anyLine(lines, job, kind)
		for _, l in ipairs(lines) do
			if isLine(l.text, job, kind) then
				return true
			end
		end
		return false
	end

	local function failedCommands(bot, since)
		local out = {}
		for _, c in ipairs(commands(bot, nil, since)) do
			if not c.ok then
				table.insert(out, c.cmd .. " " .. c.args .. ": " .. tostring(c.why))
			end
		end
		return out
	end

	-- The six enhancements in order, each after Core3's wait, all applied
	local function checkBuffs(label, doctor, patient, since)
		local enh = commands(doctor, "healenhance", since)
		local want = {"health", "action", "strength", "constitution", "quickness", "stamina"}
		if #enh ~= 6 then
			fail(label .. ": " .. #enh .. " healenhance commands, expected 6")
			return
		end
		for i, c in ipairs(enh) do
			if c.args ~= want[i] then
				fail(label .. ": enhancement " .. i .. " is " .. c.args .. ", expected " .. want[i])
			end
			if c.target ~= patient.oid then
				fail(label .. ": enhancement " .. i .. " at " .. c.target .. ", not the patient")
			end
			if not c.ok then
				fail(label .. ": enhancement " .. i .. " failed: " .. tostring(c.why))
			end
			if i > 1 then
				local gap = c.t - enh[i - 1].t
				if gap < 12000 or gap > 16000 then
					fail(label .. ": " .. gap .. " ms between enhancements " .. (i - 1) .. " and " .. i .. " (Core3 waits 12 s)")
				end
			end
		end
		for _, attr in ipairs(want) do
			local b = patient.buffs["medical_enhance_" .. attr]
			if b == nil or b.amount ~= 1400 or b.expires - sim.now < 10000 then
				fail(label .. ": " .. attr .. " buff missing or not +1400 for 3 h")
			end
		end
	end

	local saved = {}
	local tickCount, realTick = {}, nil

	local function setup(talkDir)
		saved = {dir = LivingTalk.dir, chatterEvery = LivingCities.chatterEvery, greetChance = LivingCities.greetChance}
		LivingTalk.dir = talkDir
		LivingCities.chatterEvery, LivingCities.greetChance = 1e12, 0
		ctx.setHour(20)
		for _, key in ipairs(LivingCities.cities) do
			ctx.addPlayer(ctx.newObject({planet = LivingCitiesData[key].planet, x = 0, y = 0, z = 0, cell = 0, inWorld = true,
				isPlayer = true, everywhere = true}))
		end
		LivingCities:start()
		BotJobs:start()
		resetLog()
		makeBots()
		sim.chatLog = {}
		-- Live tick chains per bot (a tick of the bot's current generation)
		tickCount = {}
		if realTick == nil then
			realTick = BotJobs.tick
		end
		BotJobs.tick = function(self, pBot, gen)
			if self:current(pBot, gen) then
				tickCount[pBot.oid] = (tickCount[pBot.oid] or 0) + 1
			end
			return realTick(self, pBot, gen)
		end
	end

	local function teardown()
		LivingTalk.dir, LivingCities.chatterEvery, LivingCities.greetChance = saved.dir, saved.chatterEvery, saved.greetChance
		BotJobs.tick = realTick
		sim.chatLog = nil
	end

	-- Scenario: brain off

	function scenarios.bots()
		local rosterFrom = ensureRoster()
		realPrint("bots     roster: " .. rosterFrom)
		checkRoster("bots roster")
		setup("/nonexistent/sim-talk")

		-- Log in
		for _, entry in ipairs(BotRoster.bots) do
			if not botLogin(firstOf(entry.name)) then
				fail("bots: " .. entry.name .. " didn't log in")
			end
		end
		local online = 0
		for _, b in ipairs(botList()) do
			online = online + (b.online and 1 or 0)
		end
		-- botLogin forces every bot in, whatever its online rule
		if online ~= #BotRoster.bots then
			fail("bots: " .. online .. " of " .. #BotRoster.bots .. " online")
		end

		local doctor, dancer = nil, nil
		for _, entry in ipairs(BotRoster.bots) do
			if entry.city == "mos_eisley" then
				if entry.job == "doctor" then doctor = bots[firstOf(entry.name):lower()] end
				if entry.job == "dancer" then dancer = bots[firstOf(entry.name):lower()] end
			end
		end

		-- Packs at the roster's settings
		local s = BotRoster.settings
		local stocked = 0
		for _, st in ipairs(log.stocks) do
			if st.bot == doctor.oid then
				stocked = stocked + 1
				local enhance = st.template:find("enhance", 1, true) ~= nil
				if st.uses ~= s.packStock or st.power ~= (enhance and s.enhancePower or s.woundPower) or
					(enhance and st.duration ~= s.enhanceDuration) then
					fail("bots: pack " .. st.template .. " stocked at " .. st.uses .. "/" .. st.power .. "/" .. st.duration)
				end
			end
		end
		if stocked ~= 12 then
			fail("bots: the doctor stocked " .. stocked .. " packs at login, expected 12 (6 enhance, 6 wound)")
		end

		local player = makePlayer("Cameren", doctor.planet, doctor.x + 3, doctor.y)
		local docFirst = doctor.first

		-- 1. A buff by keyword, targeted
		player.target = doctor.oid
		local t = nowMs()
		speak(doctor, player, "can I get a buff?")
		sim.run(100)
		checkBuffs("bots keyword buff", doctor, player, t)
		if doctor.facing ~= player.oid then
			fail("bots: the doctor didn't turn to the patient")
		end
		if not anyLine(linesOf(doctor, t), "doctor", "buffStart") then
			fail("bots: no start line for a keyword buff")
		end
		local fails = failedCommands(doctor, 0)
		if #fails > 0 then
			fail("bots: failed doctor commands: " .. table.concat(fails, "; "))
		end

		-- 2. A tip: thanked by name, with an emote at the tipper
		t = nowMs()
		doctor.cash = doctor.cash + 500
		sim.run(6)
		local thanked = false
		for _, e in ipairs(log.emotes) do
			if e.bot == doctor.oid and e.t >= t and e.emote == "thank" and e.target == player.oid then
				thanked = true
			end
		end
		local said = linesOf(doctor, t)
		if not thanked or #said ~= 1 or not said[1].text:find("Cameren", 1, true) then
			fail("bots: a tip wasn't thanked by name (" .. #said .. " lines)")
		end

		-- 3. Out of reach: "come closer", nothing until they do, then the buff
		player.target = 0
		player.x = doctor.x + 12
		t = nowMs()
		speak(doctor, player, "hey " .. docFirst:lower() .. ", buff me please")
		sim.run(5)
		if not anyLine(linesOf(doctor, t), "doctor", "closer") then
			fail("bots: no 'come closer' at 12 m")
		end
		if #commands(doctor, "healenhance", t) > 0 then
			fail("bots: buffing from 12 m")
		end
		player.x = doctor.x + 4
		sim.run(100)
		checkBuffs("bots after coming closer", doctor, player, t)

		-- 4. Wounds: two treatments on health (1500, one pack heals 1000 in a hospital), one on action
		player.wounds = {[0] = 1500, [3] = 300}
		player.target = doctor.oid
		t = nowMs()
		speak(doctor, player, "can you heal my wounds?")
		sim.run(60)
		local wounds = commands(doctor, "healwound", t)
		local got = {}
		for i, c in ipairs(wounds) do
			table.insert(got, c.args)
			if not c.ok then
				fail("bots: healwound " .. c.args .. " failed: " .. tostring(c.why))
			end
			if i > 1 and c.t - wounds[i - 1].t < 12000 then
				fail("bots: healwound " .. i .. " came before Core3's wait was over")
			end
		end
		if table.concat(got, ",") ~= "health,health,action" then
			fail("bots: wound treatments " .. table.concat(got, ",") .. ", expected health,health,action")
		end
		if botGetWounds(player, 0) ~= 0 or botGetWounds(player, 3) ~= 0 then
			fail("bots: wounds left after healing")
		end
		if not anyLine(linesOf(doctor, t), "doctor", "woundsDone") then
			fail("bots: no line after healing wounds")
		end
		t = nowMs()
		speak(doctor, player, "heal my wounds again")
		sim.run(10)
		if #commands(doctor, "healwound", t) > 0 or not anyLine(linesOf(doctor, t), "doctor", "noWounds") then
			fail("bots: wound request with no wounds")
		end

		-- 5. Not addressed: no target, no name
		player.target = 0
		t = nowMs()
		sim.run(4)
		speak(doctor, player, "buff please")
		sim.run(20)
		if #commands(doctor, "healenhance", t) > 0 or #linesOf(doctor, t) > 0 then
			fail("bots: answered a line not meant for it")
		end

		-- 6. No brain: chit-chat gets one canned line, then a quiet minute; a buff still works in it
		player.target = doctor.oid
		sim.run(65)
		t = nowMs()
		speak(doctor, player, "how's business?")
		sim.run(4)
		local lines = linesOf(doctor, t)
		if #lines ~= 1 or not anyLine(lines, "doctor", "fallback") then
			fail("bots: no brain, chit-chat got " .. #lines .. " lines, expected one canned line")
		end
		t = nowMs()
		speak(doctor, player, "you there?")
		sim.run(4)
		if #linesOf(doctor, t) ~= 0 then
			fail("bots: spoke in the quiet minute")
		end
		player.buffs = {}
		t = nowMs()
		speak(doctor, player, "buff plz")
		sim.run(100)
		checkBuffs("bots buff in the quiet minute", doctor, player, t)

		-- 7. A tell from another planet: directions by tell, no treatment
		local far = makePlayer("Dex", "naboo", 1000, 1000)
		t = nowMs()
		sim.run(65)
		speak(doctor, far, "any chance of a buff?", "tell")
		sim.run(10)
		local tells = linesOf(doctor, t, log.tells)
		if #tells ~= 1 or tells[1].to ~= "Dex" or not anyLine(tells, "doctor", "far") then
			fail("bots: a far tell got " .. #tells .. " tells")
		end
		if #commands(doctor, "healenhance", t) > 0 then
			fail("bots: buffing someone on another planet")
		end
		-- ...and when they arrive within two minutes, the buff starts by itself
		sim.run(50)
		far.planet, far.x, far.y = doctor.planet, doctor.x + 2, doctor.y - 2
		t = nowMs()
		sim.run(100)
		checkBuffs("bots buff on arrival", doctor, far, t)
		if #linesOf(doctor, t, log.tells) ~= 0 or not anyLine(linesOf(doctor, t), "doctor", "buffStart") then
			fail("bots: on arrival the doctor should speak out loud, starting with a start line")
		end
		-- A request from afar lapses after two minutes
		far.planet, far.buffs = "naboo", {}
		sim.run(65)
		t = nowMs()
		speak(doctor, far, "buff when I get there?", "tell")
		sim.run(BotDoctor.pendingSeconds + 10)
		far.planet = doctor.planet
		sim.run(60)
		if #commands(doctor, "healenhance", t) > 0 then
			fail("bots: buffed on an arrival after the request lapsed")
		end

		-- 7b. A buff heals wounds too, after the six enhancements
		player.buffs, player.wounds = {}, {[2] = 500, [5] = 100}
		sim.run(65)
		t = nowMs()
		speak(doctor, player, "buff please")
		sim.run(130)
		checkBuffs("bots buff with wounds", doctor, player, t)
		local after = commands(doctor, "healwound", t)
		if #after ~= 2 or after[1].args ~= "constitution" or after[2].args ~= "stamina" or
			after[1].t < commands(doctor, "healenhance", t)[6].t then
			fail("bots: a buff didn't heal the wounds after the enhancements")
		end
		if botGetWounds(player, 2) ~= 0 or botGetWounds(player, 5) ~= 0 then
			fail("bots: wounds left after a buff")
		end

		-- 8. Two patients: the second waits its turn, both get the full set, no treatment too early
		local second = makePlayer("Mara", doctor.planet, doctor.x - 2, doctor.y + 1)
		player.buffs, second.buffs = {}, {}
		second.target = doctor.oid
		t = nowMs()
		speak(doctor, player, "buff please")
		sim.run(4)
		speak(doctor, second, "me too, buff please")
		sim.run(4)
		if not anyLine(linesOf(doctor, t), "doctor", "busy") then
			fail("bots: the second patient wasn't told to wait")
		end
		sim.run(200)
		local enh = commands(doctor, "healenhance", t)
		if #enh ~= 12 then
			fail("bots: two patients got " .. #enh .. " enhancements, expected 12")
		else
			local firsts, seconds = {}, {}
			for _, c in ipairs(enh) do
				table.insert(c.target == player.oid and firsts or seconds, c)
			end
			if #firsts ~= 6 or #seconds ~= 6 or firsts[6].t > seconds[1].t then
				fail("bots: two patients weren't treated one after the other")
			end
		end
		fails = failedCommands(doctor, t)
		if #fails > 0 then
			fail("bots: failed commands with two patients: " .. table.concat(fails, "; "))
		end

		-- 9. Idle half an hour: emotes, sits and stands up again, mind full between patients
		t = nowMs()
		doctor:pool(POOLS.mind).cur = 100
		sim.run(1800)
		local emotes, sits, stands = 0, #commands(doctor, "sitserver", t), #commands(doctor, "stand", t)
		for _, e in ipairs(log.emotes) do
			if e.bot == doctor.oid and e.t >= t then
				emotes = emotes + 1
			end
		end
		if emotes + sits < 5 or emotes + sits > 25 then
			fail("bots: " .. emotes .. " emotes and " .. sits .. " sits in 30 idle minutes")
		end
		if sits - stands > 1 or stands > sits then
			fail("bots: " .. sits .. " sits but " .. stands .. " stands")
		end
		if doctor:getHAM(POOLS.mind) ~= doctor:getMaxHAM(POOLS.mind) then
			fail("bots: the idle doctor's mind wasn't topped up")
		end
		-- A patient while it sits: it stands up first
		doctor.posture = "sitting"
		writeData("bot:" .. doctor.oid .. ":sitting", 1)
		writeData("bot:" .. doctor.oid .. ":sitUntil", sim.now + 600)
		player.buffs = {}
		t = nowMs()
		speak(doctor, player, "buff?")
		sim.run(100)
		local stood = commands(doctor, "stand", t)
		local firstEnhance = commands(doctor, "healenhance", t)[1]
		checkBuffs("bots buff from sitting", doctor, player, t)
		if #stood ~= 1 or firstEnhance == nil or stood[1].t > firstEnhance.t then
			fail("bots: didn't stand up before buffing")
		end

		-- 10. The dancer: dancing since login, a flourish every 20-40 s, a new dance every 10-20 minutes
		local all = commands(dancer, nil, 0)
		if #all == 0 or all[1].cmd ~= "startdance" or not all[1].ok then
			fail("bots: the dancer didn't start dancing at login")
		end
		local flourishes, changes = commands(dancer, "flourish", 0), commands(dancer, "changedance", 0)
		local minutes = (nowMs() - all[1].t) / 60000
		for i = 2, #flourishes do
			local gap = flourishes[i].t - flourishes[i - 1].t
			if gap < 20000 or gap > 50000 then
				fail("bots: " .. gap .. " ms between flourishes")
				break
			end
		end
		if #flourishes < minutes * 60 / 45 or #flourishes > minutes * 60 / 20 then
			fail(string.format("bots: %d flourishes in %.0f minutes", #flourishes, minutes))
		end
		for i, c in ipairs(changes) do
			local prev = i > 1 and changes[i - 1].t or all[1].t
			if c.t - prev < 600000 or c.t - prev > 1210000 then
				fail("bots: " .. (c.t - prev) .. " ms between dances")
			end
		end
		if #changes < math.floor(minutes / 20) or #changes > math.ceil(minutes / 10) then
			fail(string.format("bots: %d dance changes in %.0f minutes", #changes, minutes))
		end
		fails = failedCommands(dancer, 0)
		if #fails > 0 then
			fail("bots: failed dancer commands: " .. table.concat(fails, "; "))
		end
		realPrint(string.format("bots     dancer: %.0f min, %d flourishes, %d dance changes, now %s", minutes, #flourishes,
			#changes, tostring(dancer.dancing)))

		-- 11. The dancer's buff: the player becomes its buff target and is told to watch
		local watcher = makePlayer("Lio", dancer.planet, dancer.x + 5, dancer.y)
		watcher.target = dancer.oid
		t = nowMs()
		speak(dancer, watcher, "could I get a buff?")
		sim.run(5)
		local set = commands(dancer, "setperformancebufftarget", t)
		if #set ~= 1 or set[1].target ~= watcher.oid or dancer.buffTarget ~= watcher.oid then
			fail("bots: no buff target after a buff request")
		end
		if not anyLine(linesOf(dancer, t), "dancer", "watch") then
			fail("bots: the dancer didn't say to watch")
		end

		-- 12. The dance stops (too tired, say): it starts again and sets the buff target again
		dancer.dancing, dancer.buffTarget = nil, nil
		t = nowMs()
		sim.run(30)
		if #commands(dancer, "startdance", t) ~= 1 or dancer.dancing == nil then
			fail("bots: the dance didn't start again")
		end
		if dancer.buffTarget ~= watcher.oid then
			fail("bots: the buff target wasn't set again after the restart")
		end

		-- 13. A buff asked by tell from far: directions, no target
		t = nowMs()
		speak(dancer, far, "buff me?", "tell")
		sim.run(5)
		if #commands(dancer, "setperformancebufftarget", t) > 0 or not anyLine(linesOf(dancer, t, log.tells), "dancer", "far") then
			fail("bots: the dancer's far tell")
		end

		-- 14. A doctor heard about battle fatigue, with no brain: points to the cantina (after the quiet minute)
		sim.run(65)
		t = nowMs()
		speak(doctor, player, "my battle fatigue is awful")
		sim.run(4)
		if not anyLine(linesOf(doctor, t), "doctor", "notMine") then
			fail("bots: no hint at the dancers for battle fatigue")
		end

		-- 15. A second login (BotJobs:restart) leaves one tick chain, not two
		sim.run(65)
		sim.call("BotJobs", "onLogin", dancer)
		t = nowMs()
		tickCount[dancer.oid] = 0
		sim.run(1200)
		local n = #commands(dancer, "flourish", t)
		if n > 1200 / 20 + 2 then
			fail("bots: " .. n .. " flourishes in 20 minutes after a second login (two chains?)")
		end
		if tickCount[dancer.oid] > 1200 / 5 + 2 then
			fail("bots: " .. tickCount[dancer.oid] .. " live ticks in 20 minutes after a second login: two chains")
		end

		-- 16. Logout: chains stop, speech is ignored
		botLogout(doctor.first)
		-- (from the next millisecond: a tick at the very end of the last run came before the logout)
		t = nowMs() + 1
		sim.run(1)
		speak(doctor, player, "buff please")
		sim.run(300)
		if #commands(doctor, nil, t) > 0 or #linesOf(doctor, t) > 0 then
			for _, l in ipairs(linesOf(doctor, t)) do realPrint("         after logout: " .. l.text) end
			for _, c in ipairs(commands(doctor, nil, t)) do realPrint("         after logout: " .. c.cmd .. " " .. c.args .. " at " .. (c.t - t)) end
			fail("bots: a logged-out doctor still works")
		end
		botLogin(doctor.first)
		player.buffs = {}
		t = nowMs()
		sim.run(65)
		speak(doctor, player, "buff please")
		sim.run(100)
		checkBuffs("bots after logging in again", doctor, player, t)

		-- 17. The crowd never takes a bot's first name
		local botFirsts = {}
		for _, entry in ipairs(BotRoster.bots) do
			botFirsts[firstOf(entry.name):lower()] = entry.name
		end
		local clashes = {}
		for _, key in ipairs(LivingCities.cities) do
			for _, species in ipairs({"human", "twilek", "rodian", "zabrak", "wookiee", "trandoshan", "ithorian"}) do
				for i = 1, 300 do
					local first = LivingCities:makeName(key, species)
					if first ~= nil and botFirsts[first:lower()] then
						clashes[first] = true
					end
				end
			end
		end
		for name in pairs(clashes) do
			fail("bots: the crowd can be named " .. name .. ", a bot's first name (reserve it in names.lua)")
		end

		ctx.checkAll("bots")
		local cmdCount = 0
		for _, b in pairs(bots) do
			cmdCount = cmdCount + #commands(b, nil, 0)
		end
		realPrint(string.format("bots     %d commands, %d lines, %d tells, %d emotes; doctor: %d enhancements, %d wound treatments",
			cmdCount, #log.says, #log.tells, #log.emotes, #commands(doctor, "healenhance", 0), #commands(doctor, "healwound", 0)))
		for i = 1, math.min(#sim.chatLog, 6) do
			realPrint("         " .. sim.chatLog[i])
		end
		teardown()
	end

	-- Scenario: the talk bridge faked

	function scenarios.botbrain()
		local dir = os.getenv("SIM_TALK_DIR")
		if dir == nil then
			realPrint("botbrain skipped (set SIM_TALK_DIR to an empty directory with req/ and rep/)")
			return
		end
		ensureRoster()
		setup(dir)
		for _, entry in ipairs(BotRoster.bots) do
			botLogin(firstOf(entry.name))
		end
		local doctor, dancer = nil, nil
		for _, entry in ipairs(BotRoster.bots) do
			if entry.city == "mos_eisley" then
				if entry.job == "doctor" then doctor = bots[firstOf(entry.name):lower()] end
				if entry.job == "dancer" then dancer = bots[firstOf(entry.name):lower()] end
			end
		end

		-- The fake bridge: a heartbeat, and each request answered after 2 s the way `mode` says
		local bridge = {on = true, mode = "answer", requests = {}}
		local function heartbeat()
			local f = io.open(dir .. "/alive", "w")
			f:write(tostring(sim.now) .. "\n")
			f:close()
		end
		local function parse(body)
			local r = {}
			for k, v in body:gmatch('"([%w_]+)":"([^"]*)"') do r[k] = v end
			for k, v in body:gmatch('"([%w_]+)":(%-?%d+)') do r[k] = tonumber(v) end
			return r
		end
		local function answer(r)
			local text = (r.text or ""):lower()
			if bridge.mode == "silent" then
				return nil
			elseif bridge.mode == "fallback" then
				return "fallback\n\n\n\n"
			end
			local action = ""
			if text:find("tip test") then
				return "ok\nhappy\nSure thing. Tips appreciated!\nbuff\n"
			elseif text:find("invite") then
				return "ok\nhappy\nCome over here and I'll buff you.\nbuff\n"
			elseif text:find("hold still") then
				return "ok\nhappy\nHold still, coming right up.\nbuff\n"
			elseif text:find("terrible") then
				action = ""
			elseif r.job == "doctor" and text:find("patch me up") then
				action = "wounds"
			elseif r.job == "doctor" and text:find("the works") then
				action = "buff"
			elseif r.job == "doctor" and text:find("wound") then
				action = "wounds"
			elseif r.job == "doctor" and (text:find("buff") or text:find("enhance")) then
				action = "buff"
			elseif r.job == "dancer" and text:find("buff") then
				action = "bufftarget"
			end
			local line = action ~= "" and ("Sure thing, " .. (r.playerName or "friend") .. ".") or "Quiet day, mostly."
			return "ok\nhappy\n" .. line .. "\n" .. action .. "\n"
		end
		local function tick()
			if bridge.on then
				heartbeat()
				local handle = io.popen('ls "' .. dir .. '/req" 2>/dev/null')
				for name in handle:lines() do
					if name:match("%.json$") then
						local path = dir .. "/req/" .. name
						local f = io.open(path)
						local body = f:read("a")
						f:close()
						os.remove(path)
						local r = parse(body)
						table.insert(bridge.requests, r)
						if r.type == "say" then
							local reply = answer(r)
							if reply ~= nil then
								sim.schedule(2000, function()
									local out = io.open(dir .. "/rep/" .. r.id .. ".txt", "w")
									out:write(reply)
									out:close()
								end)
							end
						end
					end
				end
				handle:close()
			end
			sim.schedule(1000, tick)
		end
		heartbeat()
		tick()

		local player = makePlayer("Cameren", doctor.planet, doctor.x + 3, doctor.y)
		player.target = doctor.oid

		-- 1. A buff through the brain: its line, no canned start line, the six enhancements; the request's fields
		local t = nowMs()
		speak(doctor, player, "hook me up with some enhances")
		sim.run(100)
		local r = nil
		for _, q in ipairs(bridge.requests) do
			if q.type == "say" then
				r = q
			end
		end
		if r == nil or r.type ~= "say" or r.bot ~= 1 or r.job ~= "doctor" or r.channel ~= "spatial" or r.npc ~= doctor.oid or
			r.player ~= player.oid or r.playerName ~= "Cameren" or r.text ~= "hook me up with some enhances" or
			r.name ~= doctor.name or r.city ~= "mos_eisley" or r.place ~= "medical" or r.species == nil or r.sex == nil then
			fail("botbrain: the request is missing fields")
		end
		local said = linesOf(doctor, t)
		if #said < 1 or said[1].text ~= "Sure thing, Cameren." or said[1].mood ~= "happy" then
			fail("botbrain: the brain's line wasn't said first, with its mood")
		end
		if anyLine(said, "doctor", "buffStart") then
			fail("botbrain: a canned start line on top of the brain's")
		end
		checkBuffs("botbrain buff", doctor, player, t)

		-- 1b. The brain's action stands, whatever the keywords say: "the works" gets a buff (no keyword), "your buffs
		-- are terrible" gets none (a keyword); wounds by the brain's word alone
		player.buffs = {}
		sim.run(5)
		t = nowMs()
		speak(doctor, player, "hit me with the works")
		sim.run(100)
		checkBuffs("botbrain buff by the brain's action", doctor, player, t)
		t = nowMs()
		speak(doctor, player, "your buffs are terrible")
		sim.run(20)
		if #commands(doctor, nil, t) > 0 then
			fail("botbrain: buffed when the brain gave no action")
		end
		player.wounds = {[1] = 200}
		t = nowMs()
		speak(doctor, player, "patch me up?")
		sim.run(30)
		if #commands(doctor, "healwound", t) ~= 1 or botGetWounds(player, 1) ~= 0 then
			fail("botbrain: no wound treatment on the brain's action")
		end

		-- 2. Chat with no action
		t = nowMs()
		speak(doctor, player, "how's the day been?")
		sim.run(10)
		said = linesOf(doctor, t)
		if #said ~= 1 or said[1].text ~= "Quiet day, mostly." or #commands(doctor, nil, t) > 0 then
			fail("botbrain: chit-chat got " .. #said .. " lines and " .. #commands(doctor, nil, t) .. " commands")
		end

		-- 3. A tell to the dancer: answered by tell, and the buff target set
		local watcher = makePlayer("Lio", dancer.planet, dancer.x + 4, dancer.y)
		t = nowMs()
		speak(dancer, watcher, "could I get a mind buff?", "tell")
		sim.run(10)
		local tells = linesOf(dancer, t, log.tells)
		if #tells ~= 1 or tells[1].to ~= "Lio" or tells[1].text ~= "Sure thing, Lio." then
			fail("botbrain: the dancer's tell reply")
		end
		if dancer.buffTarget ~= watcher.oid or anyLine(tells, "dancer", "watch") or #linesOf(dancer, t) > 0 then
			fail("botbrain: the dancer's buff target by tell")
		end
		local lastSay = nil
		for _, q in ipairs(bridge.requests) do
			if q.type == "say" then
				lastSay = q
			end
		end
		if lastSay.channel ~= "tell" or lastSay.job ~= "dancer" then
			fail("botbrain: the tell's request")
		end

		-- 4. A fallback reply: the buff by keyword, then the quiet minute for everyone
		player.buffs = {}
		bridge.mode = "fallback"
		t = nowMs()
		speak(doctor, player, "buff please")
		sim.run(5)
		if not LivingTalk:isQuiet() then
			fail("botbrain: no quiet minute after a fallback")
		end
		sim.run(95)
		checkBuffs("botbrain buff after a fallback", doctor, player, t)
		if not anyLine(linesOf(doctor, t), "doctor", "buffStart") then
			fail("botbrain: no canned start line when the brain fell back")
		end

		-- 5. No reply at all: after the deadline the keyword still works; chit-chat gets one canned line
		sim.run(65)
		bridge.mode = "silent"
		player.buffs = {}
		t = nowMs()
		speak(doctor, player, "buff please")
		sim.run(BotJobs.deadline + 2)
		if #commands(doctor, "healenhance", t) == 0 then
			fail("botbrain: no buff after a timeout")
		end
		sim.run(100)
		sim.run(65)
		t = nowMs()
		speak(doctor, player, "nice hat")
		sim.run(BotJobs.deadline + 3)
		said = linesOf(doctor, t)
		if #said ~= 1 or not anyLine(said, "doctor", "fallback") then
			fail("botbrain: a timed-out chat got " .. #said .. " lines, expected one canned")
		end

		-- 6. A tell from across town: the brain's answer only (no directions of the doctor's), then the buff on arrival
		sim.run(65)
		bridge.mode = "answer"
		player.buffs = {}
		player.x = doctor.x + 80
		t = nowMs()
		speak(doctor, player, "buff me when I get there?", "tell")
		sim.run(10)
		local told = linesOf(doctor, t, log.tells)
		if #told ~= 1 or told[1].text ~= "Sure thing, Cameren." then
			fail("botbrain: a tell from afar got " .. #told .. " tells, expected only the brain's")
		end
		player.x = doctor.x + 3
		sim.run(100)
		checkBuffs("botbrain buff on arrival", doctor, player, t)
		if anyLine(linesOf(doctor, t, log.tells), "doctor", "buffStart") or anyLine(linesOf(doctor, t), "doctor", "buffStart") then
			fail("botbrain: a start line on arrival after the brain answered")
		end

		-- 6b. Out of reach in the room: the brain's "come over" stands alone; a brain line that doesn't ask them over
		-- gets the doctor's "come closer"
		player.buffs = {}
		player.x = doctor.x + 12
		t = nowMs()
		speak(doctor, player, "invite me")
		sim.run(8)
		if anyLine(linesOf(doctor, t), "doctor", "closer") then
			fail("botbrain: 'come closer' on top of the brain's come-over")
		end
		player.x = doctor.x + 3
		sim.run(100)
		checkBuffs("botbrain buff after come-over", doctor, player, t)
		player.buffs = {}
		player.x = doctor.x + 12
		t = nowMs()
		speak(doctor, player, "hold still please")
		sim.run(8)
		if not anyLine(linesOf(doctor, t), "doctor", "closer") then
			fail("botbrain: no 'come closer' when the brain didn't ask them over")
		end
		player.x = doctor.x + 3
		sim.run(100)

		-- 6c. Tips: no tip line of its own when the brain's answer mentioned tips (forced on here to see it)
		local savedTip, savedDone = BotDoctor.tipChance, BotDoctor.doneChance
		BotDoctor.tipChance, BotDoctor.doneChance = 100, 0
		player.buffs = {}
		t = nowMs()
		speak(doctor, player, "tip test")
		sim.run(100)
		if anyLine(linesOf(doctor, t), "doctor", "tip") then
			fail("botbrain: a tip line after the brain already asked for tips")
		end
		player.buffs = {}
		t = nowMs()
		speak(doctor, player, "buff please")
		sim.run(100)
		if not anyLine(linesOf(doctor, t), "doctor", "tip") then
			fail("botbrain: no tip line when forced on")
		end
		BotDoctor.tipChance, BotDoctor.doneChance = savedTip, savedDone

		-- 6d. The dancer, asked by tell from afar: the brain's answer, then the buff target when they come in
		local remote = makePlayer("Vos", dancer.planet, dancer.x + 90, dancer.y)
		t = nowMs()
		speak(dancer, remote, "could you buff me when I get there?", "tell")
		sim.run(10)
		if #commands(dancer, "setperformancebufftarget", t) > 0 or #linesOf(dancer, t, log.tells) ~= 1 then
			fail("botbrain: the dancer's tell from afar")
		end
		remote.x = dancer.x + 6
		sim.run(10)
		local targeted = commands(dancer, "setperformancebufftarget", t)
		if #targeted ~= 1 or targeted[1].target ~= remote.oid or anyLine(linesOf(dancer, t), "dancer", "watch") then
			fail("botbrain: the dancer didn't set the buff target on arrival (or added a line)")
		end

		-- 7. The crowd doesn't answer a bot, nor a player who targets one
		bridge.mode = "answer"
		local members = LivingCities:members("mos_eisley")
		local npc = members[1]
		local npcFirst = readStringData("lc:npc:" .. npc:getObjectID() .. ":first")
		local before = #bridge.requests
		local chatBefore = #sim.chatLog
		doctor.target = npc:getObjectID()
		npc:fire("SPATIALCHAT", {text = "hey " .. npcFirst:lower() .. ", how are you?"}, doctor:getObjectID())
		sim.run(5)
		player.target = doctor.oid
		npc:fire("SPATIALCHAT", {text = npcFirst .. " is a good name"}, player:getObjectID())
		sim.run(15)
		for i = before + 1, #bridge.requests do
			if bridge.requests[i].npc == npc:getObjectID() then
				fail("botbrain: the crowd answered a bot or a player targeting one")
			end
		end
		-- (the doctor never heard that line: the C++ only passes lines addressed near it, and onHeard wasn't called)
		if #sim.chatLog ~= chatBefore then
			fail("botbrain: " .. (#sim.chatLog - chatBefore) .. " lines after crowd-directed chat")
		end
		-- ...but a player who targets the crowd NPC still gets an answer
		sim.run(5)
		player.target = npc:getObjectID()
		npc:fire("SPATIALCHAT", {text = "hello there"}, player:getObjectID())
		sim.run(10)
		local answered = false
		for i = before + 1, #bridge.requests do
			if bridge.requests[i].npc == npc:getObjectID() and bridge.requests[i].bot == nil then
				answered = true
			end
		end
		if not answered then
			fail("botbrain: the crowd stopped answering players")
		end

		-- 8. Logout tells the bridge to forget the bot's conversations
		before = #bridge.requests
		botLogout(doctor.first)
		sim.run(3)
		local gone = false
		for i = before + 1, #bridge.requests do
			if bridge.requests[i].type == "gone" and bridge.requests[i].npc == doctor.oid then
				gone = true
			end
		end
		if not gone then
			fail("botbrain: no 'gone' request when the doctor logged out")
		end

		bridge.on = false
		os.remove(dir .. "/alive")
		ctx.checkAll("botbrain")
		realPrint(string.format("botbrain %d requests to the bridge, %d lines, %d tells", #bridge.requests, #log.says, #log.tells))
		for i = 1, math.min(#sim.chatLog, 6) do
			realPrint("         " .. sim.chatLog[i])
		end
		teardown()
	end

	table.insert(order, "bots")
	table.insert(order, "botbrain")
end
