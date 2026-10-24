-- Bot players simulator, Phase 5: the hunting crew (custom_scripts/screenplays/bots/crew.lua) against a mock of the
-- Phases 4-6 bindings (mover, combat, tradegroup: interfaces.md, "Phases 4-6") and of the Core3 commands the crew
-- uses, acted out simply: groups and invites, attacks, taunts and specials (HAM costs, weapon ranges), stims and
-- ranged stims, states and cures, revives, cloning, camps (a medical rating inside), enhancements. living_cities_sim.lua
-- loads this file after bots_sim.lua and lends it its clock, shared memory and world:
--
--   lua living_cities_sim.lua ../../custom_scripts crew                                   # brain off
--   SIM_TALK_DIR=$(mktemp -d) lua living_cities_sim.lua ../../custom_scripts crewbrain    # the talk bridge faked
--
-- crew: logging in (specials, packs, weapon); invites by event, by polling and by chat (handing the lead back); following;
-- stay and follow for the whole group and by name; a fight with each role's rotation; specials only above the HAM
-- threshold; defending a crew mate; heal priority, states and poison; a revive; death, cloning and the way back; the
-- ranger's camp with the medic's six buffs for everyone, and the camp ending; the camp offer; tracking; going home; a
-- group with no player left; a duel at home that stops at the player's incap; restart; logout.
-- crewbrain: group chat through the brain: one request for the group, its order for every crew member; the brain's
-- camp and track actions; a named bot answering for itself.
-- crewswoop (Phase 7): the swoops (crew_swoop.lua) against a mock of botMount / botDismount / botMounted / botVehicleOut:
-- the crew mounts when the leader does and rides at swoop speed, gets off and stores when the leader does, gets off
-- when attacked or when the leader fights, doesn't mount indoors or when told to stay, and gets off when it leaves
-- the group.

return function(ctx)
	local sim, Obj, fail, realPrint = ctx.sim, ctx.Obj, ctx.fail, ctx.realPrint
	local scenarios, order = ctx.scenarios, ctx.order

	local function nowMs()
		return sim.now * 1000 + (sim.subMs or 0)
	end

	local HEALTH, ACTION, MIND = 0, 3, 6
	local STATE = {stunned = 0x1000, blinded = 0x2000, dizzy = 0x4000, intimidated = 0x8000, poisoned = 0x800000,
		diseased = 0x2000000}
	local HEALABLE = {STATE.stunned, STATE.blinded, STATE.dizzy, STATE.intimidated}

	-- The specials each weapon allows (Core3's command scripts: weaponType)
	local SPECIAL = {}
	for _, cmd in ipairs({"unarmedhit1", "unarmedhit2", "unarmedhit3", "unarmedcombo1", "unarmedcombo2", "unarmedspinattack1",
		"unarmedspinattack2", "unarmedknockdown1", "unarmedknockdown2", "unarmeddizzy1", "unarmedlunge2"}) do
		SPECIAL[cmd] = "unarmed"
	end
	for _, cmd in ipairs({"headshot1", "headshot2", "headshot3", "flurryshot1", "flurryshot2", "strafeshot1", "strafeshot2",
		"startleshot2"}) do
		SPECIAL[cmd] = "rifle"
	end
	for _, cmd in ipairs({"fullautosingle1", "fullautosingle2", "actionshot1", "actionshot2", "burstshot1", "burstshot2",
		"scattershot1", "scattershot2", "legshot1", "legshot2"}) do
		SPECIAL[cmd] = "carbine"
	end
	local WEAPON_RANGE = {unarmed = 5, rifle = 64, carbine = 64, pistol = 64}
	local ROLE_WEAPON = {tank = "unarmed", rifleman = "rifle", ranger = "carbine", medic = "pistol"}
	-- Skill boxes by role, as prefixes (the roster's skills bring every box they require)
	local ROLE_SKILLS = {
		tank = {"combat_unarmed_", "combat_brawler_", "science_medic_"},
		rifleman = {"combat_rifleman_", "combat_marksman_", "combat_carbine_"},
		medic = {"science_combatmedic_", "science_doctor_", "science_medic_"},
		ranger = {"outdoors_ranger_", "outdoors_scout_", "combat_marksman_", "combat_carbine_novice", "combat_carbine_ability_",
			"combat_carbine_accuracy_01", "combat_carbine_accuracy_02"},
	}
	local ROLE_MODS = {
		tank = {healing_injury_speed = 75, healing_ability = 50},
		medic = {healing_injury_speed = 75, healing_range_speed = 100, healing_range = 100, healing_wound_speed = 100,
			healing_ability = 100, combat_healing_ability = 100},
		rifleman = {},
		ranger = {},
	}
	local ENHANCE = {health = 0, action = 3, strength = 1, constitution = 2, quickness = 4, stamina = 5}

	local log = {}
	local function resetLog()
		log = {loots = {}, harvests = {}, offers = {}, commands = {}, says = {}, tells = {}, group = {}, emotes = {}, faces = {},
			stocks = {}, follows = {}, stops = {}, moves = {}, targets = {}, clones = {}, equips = {}, repairs = {}, camps = {},
			tracks = {}, events = {}, mounts = {}, dismounts = {}}
	end
	resetLog()

	local crew = {}       -- role -> bot
	local byFirst = {}    -- lowercase first name -> bot
	local groups, nextGroup = {}, 1
	local trackList = {}
	local saved = {}

	local function dist(a, b)
		if a == nil or b == nil or a.planet ~= b.planet then
			return math.huge
		end
		return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
	end

	-- Creature methods the crew reads (the world objects of living_cities_sim.lua)

	local methods = {}
	function methods.isGrouped(self) return self.groupId ~= nil end
	function methods.getGroupSize(self)
		local g = self.groupId and groups[self.groupId]
		return g and #g.members or 0
	end
	function methods.getGroupMember(self, i)
		local g = self.groupId and groups[self.groupId]
		assert(g ~= nil, "getGroupMember with no group")
		assert(i >= 0 and i < #g.members, "getGroupMember(" .. tostring(i) .. ") out of range")
		return ctx.objects[g.members[i + 1]]
	end
	function methods.getGroupID(self) return self.groupId or 0 end
	function methods.isDead(self) return self.dead == true end
	function methods.isIncapacitated(self) return self.incap == true end
	function methods.isInCombat(self) return self.inCombat == true end
	function methods.getMainDefender(self)
		for _, oid in ipairs(self.defenders or {}) do
			local o = ctx.objects[oid]
			if o ~= nil and not o.dead and not o.incap and o.inWorld then
				return o
			end
		end
		return nil
	end
	function methods.hasState(self, state) return ((self.states or 0) & state) ~= 0 and 1 or 0 end
	function methods.getQueueSize(self) return nowMs() < (self.queueUntil or 0) and 1 or 0 end
	function methods.hasSkill(self, skill)
		for _, prefix in ipairs(self.skillPrefixes or {}) do
			if skill:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
	function methods.getWorldPositionX(self) return self:getPositionX() end
	function methods.getWorldPositionY(self) return self:getPositionY() end
	function methods.getCurrentSpeed(self) return self.speed or 0 end
	function methods.isRidingMount(self) return self.riding == true end
	function methods.isCreatureObject(self) return self.isPlayer == true or self.isMob == true end
	-- A creature (as opposed to a humanoid) has something to harvest
	function methods.isCreature(self) return self.harvest ~= nil end
	function methods.getDisplayedName(self) return self.display or self.name or "something" end
	function methods.isAttackableBy(self, other)
		if self.dead or self.incap then
			return false
		end
		if self.isMob then
			return true
		end
		return self.duelWith ~= nil and self.duelWith == other.oid
	end
	function methods.switchZone(self, planet, x, z, y, cell)
		self.planet, self.x, self.z, self.y, self.cell = planet, x, z, y, cell
		self.zoned = (self.zoned or 0) + 1
	end
	function methods.updateDirection(self, a) self.heading = a end

	-- The other scenarios log the crew in too (bots, botbrain, ...): any getter still missing on their world objects
	-- (bots_sim.lua has the resting ones) comes from here
	for name, fn in pairs(methods) do
		if rawget(Obj, name) == nil then
			Obj[name] = fn
		end
	end

	-- Groups (GroupManager, as far as the crew needs it)

	local function joinGroup(o, leader)
		local g = leader.groupId and groups[leader.groupId]
		if g == nil then
			g = {id = nextGroup, members = {leader.oid}}
			groups[nextGroup] = g
			leader.groupId = nextGroup
			nextGroup = nextGroup + 1
		end
		table.insert(g.members, o.oid)
		o.groupId, o.inviter = g.id, nil
	end

	local function leaveGroup(o)
		local g = o.groupId and groups[o.groupId]
		if g == nil then
			return
		end
		for i, m in ipairs(g.members) do
			if m == o.oid then
				table.remove(g.members, i)
				break
			end
		end
		o.groupId = nil
		if #g.members <= 1 then
			for _, m in ipairs(g.members) do
				ctx.objects[m].groupId = nil
			end
			groups[g.id] = nil
		end
	end

	local function leaderOf(o)
		local g = o.groupId and groups[o.groupId]
		return g and ctx.objects[g.members[1]] or nil
	end

	-- Combat (defender lists both ways, as Core3's startCombat)

	local function addUnique(list, v)
		for _, x in ipairs(list) do
			if x == v then
				return
			end
		end
		table.insert(list, v)
	end

	local function startCombat(a, t)
		a.inCombat, t.inCombat = true, true
		a.combatTarget = t.oid
		a.defenders, t.defenders = a.defenders or {}, t.defenders or {}
		addUnique(a.defenders, t.oid)
		addUnique(t.defenders, a.oid)
		if t.isMob then
			local current = ctx.objects[t.aggro or 0]
			if current == nil or current.dead or current.incap then
				t.aggro = a.oid
			end
		end
	end

	local function dropFromCombat(o)
		for _, other in pairs(ctx.objects) do
			if other.defenders ~= nil then
				for i = #other.defenders, 1, -1 do
					if other.defenders[i] == o.oid then
						table.remove(other.defenders, i)
					end
				end
				if other.combatTarget == o.oid then
					other.combatTarget = nil
				end
				if other.isMob and other.aggro == o.oid then
					other.aggro = other.defenders[1]
				end
				if #other.defenders == 0 then
					other.inCombat = false
				end
			end
		end
		o.inCombat, o.defenders, o.combatTarget = false, {}, nil
	end

	local function damage(o, amount)
		if o.isMob then
			o.hp = o.hp - amount
			if o.hp <= 0 and not o.dead then
				o.dead = true
				dropFromCombat(o)
			end
		elseif not o.dead then
			local pool = o:pool(HEALTH)
			pool.cur = math.max(1, pool.cur - amount)
		end
	end

	local function packOf(b, oid)
		for _, pack in pairs(b.packs or {}) do
			if pack.oid == oid then
				return pack
			end
		end
		return nil
	end

	local function campRating(b)
		for _, o in pairs(ctx.objects) do
			if o.isCamp and o.inWorld and dist(b, o) <= o.radius then
				return 100
			end
		end
		return 0
	end

	-- Core3's commands, as far as the crew depends on them
	local function runCommand(b, cmd, target, args)
		local t = ctx.objects[target]
		if cmd == "join" then
			local inviter = ctx.objects[b.inviter or 0]
			if inviter == nil then return false, "no invite" end
			if b.groupId ~= nil then return false, "already grouped" end
			joinGroup(b, inviter)
			return true
		elseif cmd == "decline" then
			b.inviter = nil
			return true
		elseif cmd == "invite" then
			if t == nil or t.groupId ~= nil then return false, "target grouped" end
			if b.groupId ~= nil and leaderOf(b) ~= b then return false, "must be leader" end
			t.inviter = b.oid
			return true
		elseif cmd == "leavegroup" then
			if b.groupId == nil then return false, "not grouped" end
			leaveGroup(b)
			return true
		elseif cmd == "makeleader" then
			local g = b.groupId and groups[b.groupId]
			if g == nil or g.members[1] ~= b.oid then return false, "not the leader" end
			for i, m in ipairs(g.members) do
				if m == target then
					table.remove(g.members, i)
					table.insert(g.members, 1, target)
					return true
				end
			end
			return false, "not a member"
		elseif cmd == "groupchat" then
			if b.groupId == nil then return false, "not grouped" end
			assert(type(args) == "string" and #args > 0 and not args:find("[{}]"), "groupchat: bad line " .. tostring(args))
			table.insert(log.group, {bot = b.oid, t = nowMs(), text = args})
			if sim.chatLog then table.insert(sim.chatLog, b.name .. " (group): " .. args) end
			return true
		elseif cmd == "attack" then
			if t == nil or t.dead then return false, "bad target" end
			startCombat(b, t)
			return true
		elseif cmd == "taunt" then
			if t == nil or t.dead then return false, "bad target" end
			if dist(b, t) > 64 then return false, "too far" end
			startCombat(b, t)
			t.aggro = b.oid
			b.queueUntil = nowMs() + 1000
			return true
		elseif SPECIAL[cmd] ~= nil then
			if t == nil or t.dead or t.incap then return false, "bad target" end
			if b.weapon ~= SPECIAL[cmd] then return false, "wrong weapon for " .. cmd end
			if dist(b, t) > (cmd == "unarmedlunge2" and 20 or WEAPON_RANGE[b.weapon]) then return false, "out of range" end
			for _, pool in ipairs({HEALTH, ACTION, MIND}) do
				if b:getHAM(pool) <= 80 then return false, "too tired" end
			end
			for _, pool in ipairs({HEALTH, ACTION, MIND}) do
				b:pool(pool).cur = b:getHAM(pool) - 80
			end
			startCombat(b, t)
			damage(t, 150)
			b.queueUntil = nowMs() + 2000
			return true
		elseif cmd == "peace" then
			for _, oid in ipairs(b.defenders or {}) do
				local o = ctx.objects[oid]
				if o ~= nil and not o.dead and o.inCombat and (o.aggro == b.oid) then
					return false, "still attacked"
				end
			end
			b.inCombat, b.combatTarget, b.defenders = false, nil, {}
			return true
		elseif cmd == "healdamage" then
			local p = t or b
			if nowMs() < (b.injuryReady or 0) then return false, "must wait" end
			local pack = packOf(b, tonumber(args))
			if pack == nil or pack.uses <= 0 then return false, "no medicine " .. tostring(args) end
			local ranged = pack.template:find("grenade", 1, true) ~= nil
			if dist(b, p) > (ranged and 44 or 7) then return false, "too far" end
			if p.dead then return false, "dead" end
			if b:getHAM(MIND) < 50 then return false, "not enough mind" end
			for _, pool in ipairs({HEALTH, ACTION}) do
				local max = p:getMaxHAM(pool) - ((p.wounds or {})[pool] or 0)
				p:pool(pool).cur = math.min(max, p:getHAM(pool) + pack.power)
			end
			pack.uses = pack.uses - 1
			b:pool(MIND).cur = b:getHAM(MIND) - 50
			b.injuryReady = nowMs() + (ranged and 4000 or 5000)
			return true, nil, ranged and "ranged" or "stim"
		elseif cmd == "healstate" then
			local p = t or b
			if nowMs() < (b.stateReady or 0) then return false, "must wait" end
			if dist(b, p) > 6 then return false, "too far" end
			for _, state in ipairs(HEALABLE) do
				if ((p.states or 0) & state) ~= 0 then
					p.states = p.states & ~state
					b.stateReady = nowMs() + 5000
					return true
				end
			end
			return false, "no state"
		elseif cmd == "curepoison" or cmd == "curedisease" then
			local p = t or b
			local state = cmd == "curepoison" and STATE.poisoned or STATE.diseased
			if nowMs() < (b.cureReady or 0) then return false, "must wait" end
			if dist(b, p) > 7 then return false, "too far" end
			if ((p.states or 0) & state) == 0 then return false, "nothing to cure" end
			p.states = p.states & ~state
			b.cureReady = nowMs() + 5000
			return true
		elseif cmd == "reviveplayer" then
			if t == nil or not t.dead then return false, "not dead" end
			if dist(b, t) > 7 then return false, "too far" end
			if b.groupId == nil or b.groupId ~= t.groupId then return false, "not grouped" end
			t.dead = false
			t:pool(HEALTH).cur = 200
			return true
		elseif cmd == "healenhance" or cmd == "healwound" then
			local p = t or b
			if (b.skillMods.private_medical_rating or 0) <= 0 then return false, "not at a hospital or camp" end
			if b.inCombat or p.inCombat then return false, "in combat" end
			if b.posture == "sitting" then return false, "sitting" end
			if nowMs() < (b.treatmentReady or 0) then return false, "must wait" end
			if dist(b, p) > (cmd == "healenhance" and 7 or 6) then return false, "too far" end
			local attr = args:match("^(%a+)")
			if cmd == "healenhance" then
				local pack = b.packs["object/tangible/medicine/crafted/medpack_enhance_" .. tostring(attr) .. "_d.iff"]
				if ENHANCE[attr or ""] == nil or pack == nil or pack.uses <= 0 then return false, "no medicine" end
				pack.uses = pack.uses - 1
				p.buffs = p.buffs or {}
				p.buffs["medical_enhance_" .. attr] = {amount = pack.power * 2, expires = sim.now + pack.duration}
			else
				local pool = ENHANCE[attr or ""]
				local pack = b.packs["object/tangible/medicine/crafted/medpack_wound_" .. tostring(attr) .. "_e.iff"]
				if pool == nil or pack == nil or ((p.wounds or {})[pool] or 0) == 0 then return false, "no wounds" end
				p.wounds[pool] = math.max(0, p.wounds[pool] - pack.power * 4)
			end
			b.treatmentReady = nowMs() + 12000
			return true
		elseif cmd == "sitserver" then
			b.posture = "sitting"
			return true
		elseif cmd == "stand" then
			b.posture = "upright"
			return true
		end
		return false, "unknown command " .. cmd
	end

	-- The bot API, Phase 3 and Phases 4-6 (each safe with nil or an offline bot)

	local api = {}

	function api.botList()
		local out = {}
		for _, entry in ipairs(BotRoster.bots) do
			local b = byFirst[entry.name:match("^(%S+)"):lower()]
			table.insert(out, {name = entry.name, firstName = entry.name:match("^(%S+)"), job = entry.job, city = entry.city,
				oid = b and b.oid or 0, online = b ~= nil and b.online == true})
		end
		return out
	end
	function api.botGetCreature(first)
		local b = byFirst[tostring(first):lower()]
		return (b ~= nil and b.online) and b or nil
	end
	function api.isBot(p) return p ~= nil and p.isBotFlag == true end
	function api.botSetDevHuman(on) end
	function api.botEnqueue(b, cmd, target, args)
		assert(type(cmd) == "string" and cmd == cmd:lower(), "botEnqueue: command must be a lowercase name")
		assert(math.type(target) == "integer", "botEnqueue: target must be an integer oid, got " .. tostring(target))
		assert(type(args) == "string", "botEnqueue: args must be a string")
		if b == nil or not b.isBotFlag or not b.online then
			return false
		end
		local ok, why, kind = runCommand(b, cmd, target, args)
		table.insert(log.commands, {bot = b.oid, t = nowMs(), cmd = cmd, target = target, args = args, ok = ok, why = why, kind = kind})
		return true
	end
	function api.botSay(b, text, mood)
		assert(type(text) == "string" and #text > 0 and not text:find("[%c{}]"), "botSay: bad line " .. tostring(text))
		table.insert(log.says, {bot = b.oid, t = nowMs(), text = text})
		if sim.chatLog then table.insert(sim.chatLog, b.name .. ": " .. text) end
		return true
	end
	function api.botTell(b, to, text)
		assert(type(text) == "string" and #text > 0 and not text:find("[%c{}]"), "botTell: bad line " .. tostring(text))
		table.insert(log.tells, {bot = b.oid, t = nowMs(), to = to, text = text})
		return true
	end
	function api.botEmote(b, emote, target)
		assert(type(emote) == "string" and math.type(target) == "integer", "botEmote: bad arguments")
		table.insert(log.emotes, {bot = b.oid, t = nowMs(), emote = emote})
		return true
	end
	function api.botFace(b, target)
		assert(target ~= nil, "botFace: no target")
		table.insert(log.faces, {bot = b.oid, target = target.oid})
		return true
	end
	function api.botStockPack(b, template, uses, power, duration)
		assert(type(template) == "string" and template:match("^object/tangible/medicine/crafted/[%w_]+%.iff$"),
			"botStockPack: bad template " .. tostring(template))
		assert(math.type(uses) == "integer" and uses > 0, "botStockPack: uses")
		assert(type(power) == "number" and type(duration) == "number", "botStockPack: power and duration are numbers")
		b.packs = b.packs or {}
		local pack = b.packs[template]
		if pack == nil then
			pack = ctx.newObject({isPack = true, template = template, uses = 0})
			b.packs[template] = pack
		end
		pack.uses, pack.power, pack.duration = math.max(uses, pack.uses), power, duration
		table.insert(log.stocks, {bot = b.oid, template = template, uses = uses, power = power})
		return true
	end
	function api.botFindPack(b, template)
		local pack = b ~= nil and b.packs ~= nil and b.packs[template] or nil
		return (pack ~= nil and pack.uses > 0) and pack.oid or 0
	end
	function api.botGetWounds(p, pool) return p ~= nil and (p.wounds or {})[pool] or 0 end
	function api.botGetShockWounds(p) return p ~= nil and p.shock or 0 end
	function api.botGetBuffs(p)
		local out = {}
		for name, buff in pairs(p ~= nil and p.buffs or {}) do
			if sim.now < buff.expires then
				table.insert(out, {name = name, crc = 0, secondsLeft = buff.expires - sim.now, value = buff.amount})
			end
		end
		return out
	end
	-- mover
	function api.botFollow(b, leader)
		assert(leader ~= nil and leader.oid ~= nil, "botFollow: no leader")
		if b == nil or not b.online or b.dead then return false end
		b.move = {state = "follow", leader = leader.oid}
		table.insert(log.follows, {bot = b.oid, t = nowMs(), leader = leader.oid})
		return true
	end
	function api.botStop(b)
		if b == nil then return false end
		b.move = nil
		table.insert(log.stops, {bot = b.oid, t = nowMs()})
		return true
	end
	function api.botMoveTo(b, x, z, y, cell)
		assert(type(x) == "number" and type(z) == "number" and type(y) == "number" and math.type(cell) == "integer",
			"botMoveTo: bad point")
		if b == nil or not b.online or b.dead then return false end
		b.move = {state = "goto", x = x, y = y, cell = cell}
		table.insert(log.moves, {bot = b.oid, t = nowMs(), x = x, y = y, cell = cell})
		return true
	end
	function api.botMoveState(b)
		if b == nil then return nil end
		local m = b.move or {}
		local leader = ctx.objects[m.leader or 0]
		return {state = m.state or "idle", leader = m.leader or 0, distance = leader and dist(b, leader) or 0, stuck = false}
	end
	-- combat
	function api.botSetTarget(b, oid, engage)
		assert(math.type(oid) == "integer", "botSetTarget: oid must be an integer")
		if b == nil then return false end
		b.target = oid
		table.insert(log.targets, {bot = b.oid, t = nowMs(), target = oid})
		-- Unless engage is false, a target the bot may attack gets a real attack queued
		local t = ctx.objects[oid]
		if oid ~= 0 and engage ~= false and t ~= nil and not t.dead and t:isAttackableBy(b) then
			startCombat(b, t)
		end
		return true
	end
	function api.botClone(b)
		if b == nil or not b.dead then return false end
		table.insert(log.clones, {bot = b.oid, t = nowMs()})
		sim.schedule(3000, function()
			if not b.dead then return end
			b.dead = false
			b.x, b.y = b.x + 400, b.y
			b:pool(HEALTH).cur = 400
			b.wounds = {[0] = 150}
			b.shock = 60
			table.insert(log.events, {bot = b.oid, name = "cloned", t = nowMs()})
			sim.call("BotJobs", "onEvent", b, "cloned", nil, "")
		end)
		return true
	end
	function api.botEquip(b, template)
		assert(type(template) == "string" and template:match("^object/weapon/"), "botEquip: bad template " .. tostring(template))
		table.insert(log.equips, {bot = b.oid, t = nowMs(), template = template})
		return 1
	end
	function api.botRepairGear(b)
		table.insert(log.repairs, {bot = b.oid, t = nowMs()})
		return 3
	end
	-- missions (BotMission): a general terminal offers the bot six destroy missions that a scenario scripts, per bot and
	-- per refresh; the list refreshes at most every 1.4 s and only within 6 m; Core3's limit is two missions; the
	-- waypoints (botMissionSync) are kept in the leader's table
	local mw = {}
	local DIRECTION_NAMES = {"north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"}
	local function resetMissions()
		mw = {terminals = {}, lists = {}, refreshes = {}, listAt = {}, listCalls = {}, nextOid = 9000000, accepts = {}, aborts = {},
			syncs = {}}
	end
	resetMissions()
	local function directionOf(degrees)
		return DIRECTION_NAMES[(math.floor((degrees + 22.5) / 45) % 8) + 1]
	end
	local function missionTerminal(oid)
		for _, t in ipairs(mw.terminals) do
			if t.oid == oid then return t end
		end
		return nil
	end
	function api.botMissionTerminals(b, range)
		assert(b ~= nil and type(range) == "number", "botMissionTerminals: bad arguments")
		local out = {}
		for _, t in ipairs(mw.terminals) do
			local d = dist(b, t)
			if d <= range then
				table.insert(out, {oid = t.oid, distance = d, x = t.x, z = 5, y = t.y, cell = 0, planet = "tatooine"})
			end
		end
		table.sort(out, function(a, c) return a.distance < c.distance end)
		return out
	end
	function api.botMissionList(b, terminal, refresh)
		assert(b ~= nil and math.type(terminal) == "integer", "botMissionList: bad arguments")
		local t = missionTerminal(terminal)
		if t == nil then return nil, "terminal" end
		if dist(b, t) > 6 then return nil, "far" end
		mw.listCalls[b.oid] = (mw.listCalls[b.oid] or 0) + 1
		if refresh ~= false then
			if nowMs() < (mw.listAt[b.oid] or -1e9) + 1400 then return nil, "wait" end
			mw.listAt[b.oid] = nowMs()
			mw.refreshes[b.oid] = (mw.refreshes[b.oid] or 0) + 1
			local script = mw.lists[b.first] or mw.lists.default
			local list = script[math.min(mw.refreshes[b.oid], #script)]
			b.offered = {}
			for _, m in ipairs(list) do
				mw.nextOid = mw.nextOid + 1
				table.insert(b.offered, {oid = mw.nextOid, reward = m.reward, degrees = m.degrees, distance = m.distance or 1500,
					target = m.target or "womp rat lair", x = 0, y = 0, planet = "tatooine", level = 20,
					direction = directionOf(m.degrees)})
			end
		end
		local out = {}
		for _, m in ipairs(b.offered or {}) do
			table.insert(out, m)
		end
		return out
	end
	function api.botMissionAccept(b, terminal, missionOid)
		assert(b ~= nil and math.type(terminal) == "integer" and math.type(missionOid) == "integer", "botMissionAccept: bad arguments")
		local t = missionTerminal(terminal)
		if t == nil then return false, "terminal" end
		if dist(b, t) > 6 then return false, "far" end
		for i, m in ipairs(b.offered or {}) do
			if m.oid == missionOid then
				b.missions = b.missions or {}
				if #b.missions + (b.otherMissions or 0) >= 2 then return false, "full" end
				table.remove(b.offered, i)
				table.insert(b.missions, m)
				table.insert(mw.accepts, {bot = b.oid, mission = m, terminal = terminal, t = nowMs()})
				return true, ""
			end
		end
		return false, "gone"
	end
	function api.botMissionAbort(b)
		if b == nil then return 0, "" end
		if b.inCombat then return 0, "combat" end
		local n = #(b.missions or {})
		b.missions = {}
		table.insert(mw.aborts, {bot = b.oid, n = n, t = nowMs()})
		return n, ""
	end
	function api.botMissions(b)
		if b == nil then return nil end
		local out = {}
		for _, m in ipairs(b.missions or {}) do table.insert(out, m) end
		return out
	end
	function api.botMissionSync(b, leader)
		if b == nil then return 0 end
		table.insert(mw.syncs, {bot = b.oid, leader = leader and leader.oid or 0, t = nowMs()})
		for _, o in pairs(ctx.objects) do
			if o.waypoints ~= nil then
				for oid, w in pairs(o.waypoints) do
					local held = false
					for _, m in ipairs(b.missions or {}) do
						if m.oid == oid then held = true end
					end
					if w.bot == b.oid and (not held or leader ~= o) then
						o.waypoints[oid] = nil
					end
				end
			end
		end
		if leader ~= nil then
			leader.waypoints = leader.waypoints or {}
			for _, m in ipairs(b.missions or {}) do
				leader.waypoints[m.oid] = leader.waypoints[m.oid] or {bot = b.oid, name = b.first .. ": " .. m.target}
			end
		end
		return 0
	end
	-- swoops (BotVehicle): the real ones queue the work on the bot's task; here it takes half a second. A swoop is made
	-- on first use. Mounting fails indoors, in combat and when not upright, as Core3's mount does
	function api.botMount(b)
		if b == nil or not b.online or b.dead or b.riding then return false end
		table.insert(log.mounts, {bot = b.oid, t = nowMs()})
		sim.schedule(500, function()
			if b.dead or b.riding or b.cell ~= 0 or b.inCombat or b.posture == "sitting" then return end
			b.hasSwoop, b.swoopOut, b.riding = true, true, true
		end)
		return true
	end
	function api.botDismount(b)
		if b == nil or not b.online then return false end
		table.insert(log.dismounts, {bot = b.oid, t = nowMs()})
		sim.schedule(500, function()
			b.riding, b.vehicleAttacker = false, nil
			if not b.inCombat then b.swoopOut = false end	-- storing waits for the end of a fight
		end)
		return true
	end
	function api.botMounted(p) return p ~= nil and p.riding == true end
	-- Creatures attack a rider's swoop, not the rider: vehicleAttacker is the oid of whoever is attacking it
	function api.botMountAttacker(p) return (p ~= nil and p.riding and p.vehicleAttacker) or 0 end
	function api.botVehicleOut(b) return b ~= nil and b.swoopOut == true end
	function api.botHasSwoop(b) return b ~= nil and b.hasSwoop == true end
	-- tradegroup
	function api.botGetGroupInviter(b) return b ~= nil and b.inviter or 0 end
	function api.botPlaceCamp(b, kit)
		assert(type(kit) == "string" and kit:match("^object/tangible/scout/camp/[%w_]+%.iff$"), "botPlaceCamp: bad kit " .. tostring(kit))
		if b == nil or b.cell ~= 0 or b.inTown then
			return 0, (b ~= nil and b.cell ~= 0) and "inside" or "in a city"
		end
		-- A lair the test put down: no camp within its radius
		local lair = ctx.campLair
		if lair ~= nil and math.sqrt((b.x - lair.x) ^ 2 + (b.y - lair.y) ^ 2) <= lair.r then
			return 0, "lair too close"
		end
		local camp = ctx.newObject({isCamp = true, planet = b.planet, x = b.x, y = b.y, z = 5, cell = 0, inWorld = true,
			radius = 20, name = "a camp"})
		table.insert(log.camps, {bot = b.oid, t = nowMs(), oid = camp.oid, kit = kit})
		return camp.oid
	end
	function api.botTrack(b)
		table.insert(log.tracks, {bot = b.oid, t = nowMs()})
		return trackList
	end

	-- Phase 7 loot: looting, harvesting, goods and the handover (patches/bots/BotLoot*). A mob may carry
	-- loot = {names}, credits, ownerGroup (the group whose corpse it is), harvest = {kind, amount, class}
	local nextItem = 9000000
	local function newItem(name, resource, quantity)
		nextItem = nextItem + 1
		return {oid = nextItem, name = name, resource = resource == true, quantity = quantity or 1, tradable = true}
	end
	local function goodsOf(b)
		b.goods = b.goods or {}
		return b.goods
	end
	function api.botLootCorpse(b, oid)
		local r = {ok = false, moved = 0, left = 0, credits = 0, full = false, error = ""}
		local c = ctx.objects[oid]
		table.insert(log.loots, {bot = b.oid, t = nowMs(), corpse = oid})
		if c == nil or not c.isMob then r.error = "no corpse" return r end
		if not c.dead then r.error = "alive" return r end
		if b.groupId == nil then r.error = "not grouped" return r end
		if c.ownerGroup ~= b.groupId then r.error = "not the group's" return r end
		if dist(b, c) > 16 then r.error = "too far" return r end
		r.credits = c.credits or 0
		if r.credits > 0 then
			-- Core3's split: the humans in the group in range, none for the bots
			local human = {}
			for _, m in ipairs(groups[b.groupId].members) do
				local o = ctx.objects[m]
				if not o.isBotFlag and dist(o, c) <= 128 then table.insert(human, o) end
			end
			for _, o in ipairs(human) do o.cash = (o.cash or 0) + r.credits // #human end
			c.credits = 0
		end
		while #(c.loot or {}) > 0 do
			if #goodsOf(b) >= (b.packRoom or 40) then r.full = true break end
			local item = newItem(table.remove(c.loot, 1))
			table.insert(goodsOf(b), item)
			r.moved = r.moved + 1
		end
		r.left = #(c.loot or {})
		r.ok = true
		return r
	end
	function api.botHarvest(b, oid)
		local r = {ok = false, kind = "", amount = 0, resource = "", error = ""}
		local c = ctx.objects[oid]
		table.insert(log.harvests, {bot = b.oid, t = nowMs(), corpse = oid})
		if c == nil or c.harvest == nil then r.error = "not a creature" return r end
		if not c.dead then r.error = "alive" return r end
		if dist(b, c) > 7 then r.error = "too far" return r end
		if c.ownerGroup ~= b.groupId or (c.harvested or {})[b.oid] then r.error = "cannot harvest" return r end
		c.harvested = c.harvested or {}
		c.harvested[b.oid] = true
		local h = c.harvest
		local found = false
		for _, item in ipairs(goodsOf(b)) do
			if item.resource and item.name == h.class then
				item.quantity = item.quantity + h.amount
				found = true
			end
		end
		if not found then
			table.insert(goodsOf(b), newItem(h.class, true, h.amount))
		end
		r.ok, r.kind, r.amount, r.resource = true, h.kind, h.amount, h.class
		return r
	end
	function api.botGoods(b)
		local out = {}
		for _, item in ipairs(goodsOf(b)) do
			table.insert(out, {oid = item.oid, name = item.name, quantity = item.quantity, resource = item.resource, tradable = item.tradable})
		end
		return out
	end
	function api.botOfferGoods(b, playerOid)
		local p = ctx.objects[playerOid]
		if p == nil or not p.isPlayer then return false, "no player", 0 end
		if b.bundle ~= nil then return false, "busy", 0 end
		if dist(b, p) >= 13 then return false, "too far", 0 end
		local items = {}
		for _, item in ipairs(goodsOf(b)) do
			if item.tradable then table.insert(items, item) end
		end
		if #items == 0 then return false, "no goods", 0 end
		p.room = p.room or 80
		if p.room <= 0 then return false, "inventory full", 0 end
		local n = math.min(#items, 20, p.room)
		local chosen = {}
		for i = 1, n do table.insert(chosen, items[i]) end
		b.bundle = {to = p.oid, items = chosen}
		table.insert(log.offers, {bot = b.oid, t = nowMs(), to = p.oid, count = n, items = chosen})
		sim.schedule(3000, function()
			if b.bundle == nil then return end
			local bundle = b.bundle
			b.bundle = nil
			if sim.declineOffers then
				sim.call("BotJobs", "onEvent", b, "trade", p, "bundleCancelled")
				return
			end
			for _, item in ipairs(bundle.items) do
				for i, held in ipairs(goodsOf(b)) do
					if held.oid == item.oid then table.remove(goodsOf(b), i) break end
				end
				p.received = p.received or {}
				table.insert(p.received, item)
				sim.handedTotal = (sim.handedTotal or 0) + 1
				p.room = p.room - 1
			end
			sim.call("BotJobs", "onEvent", b, "trade", p, "bundleDone")
		end)
		return true, n, #items - n
	end
	function api.botCancelOffer(b)
		b.bundle = nil
	end

	-- The world: walking, creatures fighting, auto-attack, regeneration, the camp's medical rating (every 500 ms)

	local worldOn = false
	local function walkToward(o, x, y, stopAt, speed)
		local dx, dy = x - o.x, y - o.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d <= stopAt then
			return true
		end
		local step = math.min(d - stopAt, speed * 0.5)
		o.x, o.y = o.x + dx / d * step, o.y + dy / d * step
		return d - step <= stopAt + 0.01
	end

	local function worldTick()
		if not worldOn then
			return
		end
		local t = nowMs()
		for _, o in pairs(ctx.objects) do
			if o.inWorld and not o.dead and not o.incap then
				-- Walking (BotMover: never while sitting; catch-up snap at 80 m)
				local m = o.move
				if m ~= nil and o.posture ~= "sitting" then
					if m.state == "follow" then
						local leader = ctx.objects[m.leader]
						if leader ~= nil and leader.planet == o.planet then
							if not o.pinCell then o.cell = leader.cell end
							if dist(o, leader) > 80 then
								o.x, o.y = leader.x - 10, leader.y
							else
								walkToward(o, leader.x, leader.y, 4, o.riding and 18 or 6)
							end
						end
					elseif m.state == "goto" then
						if walkToward(o, m.x, m.y, 0.3, o.riding and 18 or 6) then
							o.x, o.y = m.x, m.y
							o.cell = m.cell or 0
							o.move = nil
							if o.isBotFlag then
								table.insert(log.events, {bot = o.oid, name = "arrived", t = t})
								sim.call("BotJobs", "onEvent", o, "arrived", nil, "")
							end
						end
					end
				end
				-- A creature closes on whoever it's after and hits every 2 s
				if o.isMob and o.inCombat then
					local victim = ctx.objects[o.aggro or 0]
					if victim ~= nil and not victim.dead and not victim.incap then
						if dist(o, victim) > 3 then
							walkToward(o, victim.x, victim.y, 2, 6)
						elseif t >= (o.nextHit or 0) then
							o.nextHit = t + 2000
							damage(victim, o.hits or 25)
							victim.inCombat = true
							victim.defenders = victim.defenders or {}
							addUnique(victim.defenders, o.oid)
						end
					end
				end
				-- Auto-attack every 2 s on the combat target, in weapon range
				if o.isPlayer and o.inCombat and o.combatTarget ~= nil then
					local target = ctx.objects[o.combatTarget]
					if target ~= nil and not target.dead and not target.incap and dist(o, target) <= WEAPON_RANGE[o.weapon or "pistol"] and
						t >= (o.nextAuto or 0) then
						o.nextAuto = t + 2000
						damage(target, o.isBotFlag and 40 or 30)
					end
				end
				-- Regeneration
				if o.isPlayer and not o.noRegen and o.ham ~= nil then
					for pool, p in pairs(o.ham) do
						local max = p.base + o:buffBonus(pool) - ((o.wounds or {})[pool] or 0)
						if p.cur < max then
							p.cur = math.min(max, p.cur + 5)
						end
					end
				end
				if o.isBotFlag then
					o.skillMods.private_medical_rating = campRating(o)
				end
			end
		end
		sim.schedule(500, worldTick)
	end

	-- Scenario setup

	local function crewRoster()
		local roles = {}
		for _, entry in ipairs((BotRoster or {}).bots or {}) do
			if ROLE_WEAPON[entry.job] ~= nil and roles[entry.job] == nil then
				roles[entry.job] = entry
			end
		end
		if roles.tank and roles.rifleman and roles.medic and roles.ranger then
			return "custom_scripts/bots/roster.lua", nil
		end
		local station = function(x) return {planet = "tatooine", x = x, z = 0, y = -11, cell = 1082877, heading = 90} end
		return "a test crew (no crew in custom_scripts/bots/roster.lua yet)", {
			settings = BotRoster ~= nil and BotRoster.settings or {packStock = 20},
			bots = {
				{name = "Kael Dorrin", species = "human", sex = "male", job = "tank", city = "mos_eisley", station = station(1),
					skills = {"combat_unarmed_master"}, outfit = {"object/tangible/wearables/armor/bone/armor_bone_s01_chest_plate.iff"}},
				{name = "Vos Tarrik", species = "zabrak", sex = "male", job = "rifleman", city = "mos_eisley", station = station(3),
					skills = {"combat_rifleman_master"}, outfit = {"object/weapon/ranged/rifle/rifle_t21.iff"}},
				{name = "Mira Selt", species = "twilek", sex = "female", job = "medic", city = "mos_eisley", station = station(5),
					skills = {"science_doctor_master"}, outfit = {"object/weapon/ranged/pistol/pistol_cdef.iff"}},
				{name = "Orrin Vael", species = "bothan", sex = "male", job = "ranger", city = "mos_eisley", station = station(7),
					skills = {"outdoors_ranger_master"}, outfit = {"object/weapon/ranged/carbine/carbine_e11.iff"}},
			},
		}
	end

	local function setup(talkDir)
		saved = {roster = BotRoster, dir = LivingTalk.dir, globals = {}, methods = {}}
		local from, roster = crewRoster()
		if roster ~= nil then
			BotRoster = roster
		end
		realPrint("crew     roster: " .. from)
		LivingTalk.dir = talkDir
		ctx.setHour(20)
		for name, fn in pairs(api) do
			saved.globals[name] = _G[name]
			_G[name] = fn
		end
		for name, fn in pairs(methods) do
			saved.methods[name] = rawget(Obj, name)
			Obj[name] = fn
		end
		resetLog()
		resetMissions()
		crew, byFirst, groups, nextGroup, trackList = {}, {}, {}, 1, {}
		sim.chatLog = {}
		-- The crew at the Mos Eisley cantina (world coordinates are the cell's here)
		for _, entry in ipairs(BotRoster.bots) do
			local role = entry.job
			if ROLE_WEAPON[role] ~= nil and crew[role] == nil then
				local first = entry.name:match("^(%S+)")
				local s = entry.station
				local b = ctx.newObject({isBotFlag = true, isPlayer = true, first = first, name = entry.name, planet = s.planet,
					x = s.x, y = s.y, z = s.z, cell = s.cell or 0, inWorld = false, online = false, cash = 100, bank = 1000, packs = {},
					buffs = {}, wounds = {}, skillPrefixes = ROLE_SKILLS[role], skillMods = {}, weapon = ROLE_WEAPON[role], role = role})
				for k, v in pairs(ROLE_MODS[role]) do
					b.skillMods[k] = v
				end
				crew[role] = b
				byFirst[first:lower()] = b
				ctx.addPlayer(b)
			end
		end
		worldOn = true
		sim.schedule(500, worldTick)
	end

	local function teardown()
		worldOn = false
		for name, fn in pairs(saved.globals) do
			_G[name] = fn
		end
		for name, fn in pairs(saved.methods) do
			Obj[name] = fn
		end
		BotRoster = saved.roster
		LivingTalk.dir = saved.dir
		sim.chatLog = nil
	end

	local function login(b)
		b.online, b.inWorld = true, true
		sim.call("BotJobs", "onLogin", b)
	end

	local function makeHuman(first, x, y)
		local h = ctx.newObject({isPlayer = true, first = first, name = first, planet = "tatooine", x = x, y = y, z = 5, cell = 0,
			inWorld = true, buffs = {}, wounds = {}, skillMods = {}, weapon = "rifle"})
		ctx.addPlayer(h)
		return h
	end

	local function makeMob(name, x, y, hp)
		return ctx.newObject({isMob = true, display = name, name = name, planet = "tatooine", x = x, y = y, z = 5, cell = 0,
			inWorld = true, hp = hp or 2000, hits = 25})
	end

	-- A player invites a bot (the event, as tradegroup's hook sends it; or only the inviter id, for the tick to see)
	local function invite(h, b, withEvent)
		if h.groupId ~= nil and leaderOf(h) ~= h then
			fail("crew: test bug, " .. h.first .. " isn't the leader")
		end
		b.inviter = h.oid
		if withEvent then
			sim.call("BotJobs", "onEvent", b, "groupInvite", h, "")
		end
	end

	local function attack(h, mob)
		h.target = mob.oid
		startCombat(h, mob)
	end

	-- A player's words: in group chat to every crew bot in their group (patch 0003), or to one bot
	local function groupSay(h, text)
		local g = h.groupId and groups[h.groupId]
		for _, oid in ipairs(g and g.members or {}) do
			local b = ctx.objects[oid]
			if b.isBotFlag then
				sim.call("BotJobs", "onHeard", b, h, text, "group")
			end
		end
	end

	local function speak(b, h, text, channel)
		sim.call("BotJobs", "onHeard", b, h, text, channel or "spatial")
	end

	local function commands(b, name, since)
		local out = {}
		for _, c in ipairs(log.commands) do
			if c.bot == b.oid and (name == nil or c.cmd == name) and c.t >= (since or 0) then
				table.insert(out, c)
			end
		end
		return out
	end

	local function okCommands(b, name, since)
		local out = {}
		for _, c in ipairs(commands(b, name, since)) do
			if c.ok then table.insert(out, c) end
		end
		return out
	end

	local function entries(list, b, since)
		local out = {}
		for _, e in ipairs(list) do
			if (b == nil or e.bot == b.oid) and e.t >= (since or 0) then
				table.insert(out, e)
			end
		end
		return out
	end

	-- Is the text one of the crew's canned lines of this kind (for the role, else the crew's)?
	local function isLine(text, role, kind)
		for _, list in ipairs({(BotLines[role] or {})[kind] or {}, BotLines.crew[kind] or {}}) do
			for _, pattern in ipairs(list) do
				local p = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("{%a+}", ".-") .. "$"
				if text:match(p) then
					return true
				end
			end
		end
		return false
	end

	local function anyLine(lines, role, kind)
		for _, l in ipairs(lines) do
			if isLine(l.text, role, kind) then
				return true
			end
		end
		return false
	end

	local function each(f)
		for _, role in ipairs({"tank", "rifleman", "medic", "ranger"}) do
			f(role, crew[role])
		end
	end

	-- Did the bot set this target (and so attack it) since t?
	local function engaged(b, oid, since)
		for _, e in ipairs(entries(log.targets, b, since)) do
			if e.target == oid then return true end
		end
		return false
	end

	local function moveState(b)
		return (b.move or {}).state or "idle"
	end

	local function mode(b)
		return readStringData("bot:" .. b.oid .. ":crew:mode")
	end

	-- Commands that Core3 refused (the crew's own mistakes), but not the ones a fight makes normal
	local function refused(b, since, allowed)
		local out = {}
		for _, c in ipairs(commands(b, nil, since)) do
			if not c.ok and not (allowed or {})[c.cmd] then
				table.insert(out, c.cmd .. " " .. c.args .. ": " .. tostring(c.why))
			end
		end
		return out
	end

	local function members(h)
		local g = h.groupId and groups[h.groupId]
		return g and #g.members or 0
	end

	-- Scenario: brain off

	function scenarios.crew()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		local s = BotRoster.settings or {}

		-- 1. Log in: specials from the skills, packs for what each can do, the weapon in hand
		each(function(role, b) login(b) end)
		local function specials(b) return readStringData("bot:" .. b.oid .. ":crew:specialsList") end
		if not specials(tank):find("unarmedhit3", 1, true) or specials(tank):find("unarmedhit2", 1, true) or
			not specials(tank):find("unarmedcombo2", 1, true) then
			fail("crew: the tank's specials " .. specials(tank))
		end
		if not specials(rifleman):find("headshot3", 1, true) or not specials(rifleman):find("flurryshot2", 1, true) or
			not specials(rifleman):find("strafeshot2", 1, true) then
			fail("crew: the rifleman's specials " .. specials(rifleman))
		end
		if not specials(ranger):find("fullautosingle2", 1, true) or not specials(ranger):find("burstshot2", 1, true) or
			specials(ranger):find("headshot", 1, true) then
			fail("crew: the ranger's specials " .. specials(ranger))
		end
		if specials(medic) ~= "" then
			fail("crew: the medic has specials " .. specials(medic))
		end
		local stocked = {}
		for _, st in ipairs(log.stocks) do
			stocked[st.bot] = stocked[st.bot] or {}
			stocked[st.bot][st.template:match("crafted/(.-)%.iff")] = true
		end
		for _, pack in ipairs({"crafted_stimpack_sm_s1_e", "medpack_grenade_damage_e", "medpack_stunned_b", "medpack_cure_poison_c",
			"medpack_cure_disease_c", "medpack_revive", "medpack_enhance_health_d", "medpack_wound_health_e"}) do
			if not (stocked[medic.oid] or {})[pack] then
				fail("crew: the medic has no " .. pack)
			end
		end
		if not (stocked[tank.oid] or {}).crafted_stimpack_sm_s1_e or stocked[rifleman.oid] ~= nil then
			fail("crew: stims for the tank (a master medic) and nothing for the rifleman")
		end
		if #entries(log.equips, rifleman) ~= 1 or not entries(log.equips, rifleman)[1].template:find("rifle", 1, true) then
			fail("crew: the rifleman's rifle wasn't equipped at login")
		end

		-- 2. An invite (the event): it joins, says hello in group chat, and follows
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		local t = nowMs()
		invite(cameren, tank, true)
		sim.run(5)
		if tank.groupId == nil or leaderOf(tank) ~= cameren then
			fail("crew: the tank didn't join on an invite")
		end
		if moveState(tank) ~= "follow" or #entries(log.follows, tank, t) == 0 or entries(log.follows, tank, t)[1].leader ~= cameren.oid then
			fail("crew: the tank isn't following its leader (" .. moveState(tank) .. ")")
		end
		if not anyLine(entries(log.group, tank, t), "tank", "joined") then
			fail("crew: no hello in group chat")
		end

		-- 3. An invite seen only by the tick (no event)
		invite(cameren, rifleman, false)
		sim.run(8)
		if rifleman.groupId ~= cameren.groupId then
			fail("crew: the rifleman didn't join on a polled invite")
		end

		-- 4. "Wanna hunt?" from a player in a group: asked for an invite, then joins on it
		cameren.target = ranger.oid
		t = nowMs()
		speak(ranger, cameren, "wanna hunt?")
		sim.run(2)
		if #commands(ranger, "invite", t) > 0 or not anyLine(entries(log.says, ranger, t), "ranger", "askInvite") then
			fail("crew: asked to hunt by a grouped player, the ranger should ask for an invite")
		end
		invite(cameren, ranger, true)
		sim.run(4)
		cameren.target = 0

		-- 5. "Wanna hunt?" from a player on their own: the bot invites them, and hands them the lead once they join
		local dex = makeHuman("Dex", medic.x - 2, medic.y)
		dex.target = medic.oid
		t = nowMs()
		sim.run(65)
		speak(medic, dex, "hey, want to come hunt with me?")
		sim.run(2)
		local invites = okCommands(medic, "invite", t)
		if #invites ~= 1 or invites[1].target ~= dex.oid or dex.inviter ~= medic.oid then
			fail("crew: the medic didn't invite a player on their own")
		end
		joinGroup(dex, medic)
		sim.run(8)
		if leaderOf(medic) ~= dex then
			fail("crew: the medic didn't hand the lead to the player")
		end
		-- Dex sends it home by tell; then Cameren invites it
		t = nowMs()
		sim.run(65)
		speak(medic, dex, "thanks, you can go home now", "tell")
		sim.run(10)
		if medic.groupId ~= nil or #okCommands(medic, "leavegroup", t) ~= 1 then
			fail("crew: told to go home, the medic didn't leave the group")
		end
		if #entries(log.tells, medic, t) ~= 1 or not anyLine(entries(log.tells, medic, t), "medic", "home") then
			fail("crew: no goodbye by tell")
		end
		sim.run(10)
		if mode(medic) ~= "home" and mode(medic) ~= "walkingHome" then
			fail("crew: the medic isn't going home (" .. mode(medic) .. ")")
		end
		invite(cameren, medic, true)
		sim.run(6)
		if members(cameren) ~= 5 then
			fail("crew: " .. members(cameren) .. " in the group, expected Cameren and four crew")
		end

		-- 6. Following: Cameren walks 100 m; the crew keep up
		cameren.move = {state = "goto", x = cameren.x + 100, y = cameren.y}
		cameren.speed = 5
		sim.run(30)
		cameren.speed = 0
		each(function(role, b)
			if dist(b, cameren) > 8 then
				fail(string.format("crew: the %s is %.0f m behind after a walk", role, dist(b, cameren)))
			end
		end)

		-- 7. "Stay here" for the whole group: one answer, everyone stops; then "follow me"
		t = nowMs()
		groupSay(cameren, "everyone stay here a sec")
		sim.run(3)
		local answers = entries(log.group, nil, t)
		if #answers ~= 1 or not anyLine(answers, "tank", "stay") then
			fail("crew: 'stay' got " .. #answers .. " answers in group chat, expected one")
		end
		each(function(role, b)
			if moveState(b) ~= "idle" or readStringData("bot:" .. b.oid .. ":crew:order") ~= "stay" then
				fail("crew: the " .. role .. " didn't stay (" .. moveState(b) .. ")")
			end
		end)
		cameren.x = cameren.x + 30
		sim.run(10)
		if dist(rifleman, cameren) < 25 then
			fail("crew: the rifleman followed while told to stay")
		end
		t = nowMs()
		groupSay(cameren, "ok follow me")
		sim.run(10)
		each(function(role, b)
			if moveState(b) ~= "follow" or dist(b, cameren) > 8 then
				fail("crew: the " .. role .. " didn't follow again")
			end
		end)
		-- By name: only that one
		t = nowMs()
		groupSay(cameren, tank.first .. ", stay")
		sim.run(3)
		if moveState(tank) ~= "idle" or moveState(rifleman) ~= "follow" or #entries(log.group, nil, t) ~= 1 or
			#entries(log.group, tank, t) ~= 1 then
			fail("crew: a named 'stay' wasn't for the tank alone")
		end
		groupSay(cameren, tank.first .. " follow")
		sim.run(5)

		-- 8. A fight: Cameren attacks; the tank taunts, closes in and uses Teras Kasi specials; the rifleman and the
		-- ranger shoot specials from range; the medic keeps Cameren up; peace when it's dead
		local rat = makeMob("a womp rat", cameren.x + 30, cameren.y + 5, 9000)
		rat.hits = 120
		t = nowMs()
		attack(cameren, rat)
		sim.run(3)
		each(function(role, b)
			local set = entries(log.targets, b, t)
			if #set == 0 or set[1].target ~= rat.oid or not engaged(b, rat.oid, t) then
				fail("crew: the " .. role .. " didn't attack the leader's target")
			end
		end)
		if #okCommands(tank, "taunt", t) == 0 then
			fail("crew: the tank didn't taunt")
		end
		sim.run(60)
		local tankSpecials, riflemanSpecials, rangerSpecials = {}, {}, {}
		for _, c in ipairs(okCommands(tank, nil, t)) do if SPECIAL[c.cmd] then tankSpecials[c.cmd] = (tankSpecials[c.cmd] or 0) + 1 end end
		for _, c in ipairs(okCommands(rifleman, nil, t)) do if SPECIAL[c.cmd] then riflemanSpecials[c.cmd] = (riflemanSpecials[c.cmd] or 0) + 1 end end
		for _, c in ipairs(okCommands(ranger, nil, t)) do if SPECIAL[c.cmd] then rangerSpecials[c.cmd] = (rangerSpecials[c.cmd] or 0) + 1 end end
		local function list(set)
			local out = {}
			for cmd, n in pairs(set) do table.insert(out, cmd .. " " .. n) end
			table.sort(out)
			return table.concat(out, ", ")
		end
		realPrint("crew     tank: " .. list(tankSpecials) .. "; rifleman: " .. list(riflemanSpecials) .. "; ranger: " .. list(rangerSpecials))
		for cmd in pairs(tankSpecials) do if SPECIAL[cmd] ~= "unarmed" then fail("crew: the tank used " .. cmd) end end
		for cmd in pairs(riflemanSpecials) do if SPECIAL[cmd] ~= "rifle" then fail("crew: the rifleman used " .. cmd) end end
		for cmd in pairs(rangerSpecials) do if SPECIAL[cmd] ~= "carbine" then fail("crew: the ranger used " .. cmd) end end
		-- (picked by weight at random: a rotation is several different specials, not any one of them)
		local function kinds(set) local n = 0 for _ in pairs(set) do n = n + 1 end return n end
		if kinds(tankSpecials) < 2 then
			fail("crew: the tank's rotation: " .. list(tankSpecials))
		end
		if kinds(riflemanSpecials) < 2 then
			fail("crew: the rifleman's rotation: " .. list(riflemanSpecials))
		end
		if next(rangerSpecials) == nil then
			fail("crew: the ranger used no carbine specials")
		end
		if #entries(log.moves, tank, t) == 0 then
			fail("crew: the tank didn't close in")
		end
		local heals = okCommands(medic, "healdamage", t)
		local healed = {}
		for _, c in ipairs(heals) do
			healed[c.target] = true
			if ctx.objects[c.target].groupId ~= cameren.groupId then
				fail("crew: the medic healed someone outside the group")
			end
		end
		if #heals == 0 or not (healed[cameren.oid] or healed[tank.oid]) then
			fail("crew: the medic didn't keep the fight's targets up (" .. #heals .. " heals)")
		end
		local failures = refused(tank, t, {peace = true, attack = true})
		for _, role in ipairs({"rifleman", "medic", "ranger"}) do
			for _, f in ipairs(refused(crew[role], t, {peace = true, attack = true})) do table.insert(failures, role .. ": " .. f) end
		end
		if #failures > 0 then
			fail("crew: refused commands in the fight: " .. table.concat(failures, "; "))
		end
		if not rat.dead then
			fail("crew: the womp rat (9000) is still alive after 60 s with the crew on it")
		end
		sim.run(10)
		each(function(role, b)
			if #okCommands(b, "peace", t) == 0 then
				fail("crew: the " .. role .. " made no peace after the fight")
			end
			if moveState(b) ~= "follow" then
				fail("crew: the " .. role .. " isn't following after the fight (" .. moveState(b) .. ")")
			end
		end)

		-- 9. Specials only above the HAM threshold: the tank with little mind only auto-attacks (stims don't heal mind)
		tank.noRegen = true
		tank:pool(MIND).cur = math.floor(tank:getMaxHAM(MIND) * ((s.specialsHam or 0.5) - 0.2))
		local rat2 = makeMob("a womp rat", cameren.x + 10, cameren.y, 1500)
		t = nowMs()
		attack(cameren, rat2)
		sim.run(20)
		local used = 0
		for _, c in ipairs(commands(tank, nil, t)) do if SPECIAL[c.cmd] then used = used + 1 end end
		if used > 0 then
			fail("crew: the tank used " .. used .. " specials with its mind under the threshold")
		end
		if not engaged(tank, rat2.oid, t) then
			fail("crew: the tired tank didn't attack at all")
		end
		tank.noRegen = false
		sim.run(60)

		-- 10. Defending: a creature goes for the rifleman while Cameren stands idle
		local kreetle = makeMob("a kreetle", rifleman.x - 15, rifleman.y, 800)
		t = nowMs()
		startCombat(kreetle, rifleman)
		kreetle.aggro = rifleman.oid
		sim.run(6)
		each(function(role, b)
			local defended = false
			for _, e in ipairs(entries(log.targets, b, t)) do
				defended = defended or e.target == kreetle.oid
			end
			if not defended then
				fail("crew: the " .. role .. " didn't defend the rifleman")
			end
		end)
		sim.run(40)

		-- 11. Heal priority out of a fight: Cameren at 30 % first, then the rifleman at 60 %; a stun, then poison
		sim.run(20)
		cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * 0.3)
		rifleman:pool(HEALTH).cur = math.floor(rifleman:getMaxHAM(HEALTH) * 0.6)
		cameren.noRegen, rifleman.noRegen = true, true
		t = nowMs()
		sim.run(15)
		heals = okCommands(medic, "healdamage", t)
		if #heals < 2 or heals[1].target ~= cameren.oid then
			fail("crew: heal order " .. (heals[1] and heals[1].target or "none") .. ", expected Cameren first")
		end
		cameren.states = STATE.stunned | STATE.poisoned
		t = nowMs()
		sim.run(15)
		if #okCommands(medic, "healstate", t) ~= 1 or #okCommands(medic, "curepoison", t) ~= 1 or cameren.states ~= 0 then
			fail("crew: the stun and poison weren't treated")
		end
		cameren.noRegen, rifleman.noRegen = false, false
		-- The medic itself first when it's low
		medic.noRegen = true
		medic:pool(HEALTH).cur = math.floor(medic:getMaxHAM(HEALTH) * 0.3)
		cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * 0.5)
		cameren.noRegen = true
		t = nowMs()
		sim.run(8)
		heals = okCommands(medic, "healdamage", t)
		if #heals == 0 or heals[1].target ~= medic.oid then
			fail("crew: a medic at 30 % should heal itself first")
		end
		medic.noRegen, cameren.noRegen = false, false
		sim.run(30)

		-- 12. A revive: the rifleman dies and the medic gets it up
		rifleman.dead = true
		dropFromCombat(rifleman)
		t = nowMs()
		sim.run(20)
		if rifleman.dead or #okCommands(medic, "reviveplayer", t) ~= 1 then
			fail("crew: the medic didn't revive the rifleman")
		end
		if #entries(log.clones, rifleman, t) > 0 then
			fail("crew: the rifleman cloned while the medic was there")
		end
		if not anyLine(entries(log.group, rifleman, t), "rifleman", "down") or not anyLine(entries(log.group, medic, t), "medic", "reviving") then
			fail("crew: no 'I'm down' and 'coming' lines around the revive")
		end
		sim.run(10)

		-- 13. Death with no medic: both clone, repair, take their weapons and come back to Cameren
		medic.dead, tank.dead = true, true
		dropFromCombat(medic)
		dropFromCombat(tank)
		t = nowMs()
		sim.run(40)
		for _, b in ipairs({tank, medic}) do
			if #entries(log.clones, b, t) ~= 1 or b.dead then
				fail("crew: the " .. b.role .. " didn't clone (" .. #entries(log.clones, b, t) .. " clone requests)")
			end
			if #entries(log.repairs, b, t) ~= 1 then
				fail("crew: the " .. b.role .. " didn't repair its gear after cloning")
			end
		end
		if #entries(log.equips, medic, t) ~= 1 then
			fail("crew: the medic didn't take its pistol after cloning")
		end
		sim.run(30)
		for _, b in ipairs({tank, medic}) do
			if dist(b, cameren) > 12 or moveState(b) ~= "follow" then
				fail(string.format("crew: the cloned %s isn't back with Cameren (%.0f m, %s)", b.role, dist(b, cameren), moveState(b)))
			end
		end
		if not anyLine(entries(log.group, tank, t), "tank", "cloned") then
			fail("crew: no line after cloning")
		end

		-- 14. The ranger's camp: asked in group chat; the crew sit by the fire; the medic gives everyone the six
		-- enhancements (Cameren first, once he comes over), then the camp ends when Cameren moves on
		sim.run(60)
		cameren.wounds = {}
		t = nowMs()
		groupSay(cameren, "let's camp here for a bit")
		-- (Cameren wanders off at once, so the medic asks him over)
		cameren.x, cameren.y = cameren.x + 15, cameren.y
		local campLog = entries(log.camps, ranger, t)
		if #campLog ~= 1 or not anyLine(entries(log.group, ranger, t), "ranger", "campUp") then
			fail("crew: asked for a camp, the ranger didn't place one")
		end
		local camp = campLog[1] and ctx.objects[campLog[1].oid] or {x = cameren.x, y = cameren.y}
		if #entries(log.group, ranger, t) ~= 1 then
			fail("crew: " .. #entries(log.group, ranger, t) .. " ranger lines on 'camp', expected one")
		end
		sim.run(20)
		if not anyLine(entries(log.group, medic, t), "medic", "campCome") then
			fail("crew: the medic didn't ask Cameren over to the fire")
		end
		cameren.x, cameren.y = camp.x + 2, camp.y - 1
		sim.run(600)
		local enhances = okCommands(medic, "healenhance", t)
		local per = {}
		for _, c in ipairs(enhances) do per[c.target] = (per[c.target] or 0) + 1 end
		for _, b in ipairs({cameren, tank, rifleman, ranger, medic}) do
			if per[b.oid] ~= 6 then
				fail("crew: " .. b.first .. " got " .. tostring(per[b.oid]) .. " enhancements in camp, expected 6")
			end
			if b ~= cameren and b ~= medic and b.posture ~= "sitting" then
				fail("crew: the " .. tostring(b.role) .. " isn't sitting by the fire")
			end
		end
		local buffFailures = refused(medic, t, {})
		if #buffFailures > 0 then
			fail("crew: the medic's refused commands in camp: " .. table.concat(buffFailures, "; "))
		end
		realPrint("crew     camp: " .. #enhances .. " enhancements, " .. #okCommands(medic, "healwound", t) .. " wound treatments")
		-- Moving on: the camp is over, everyone stands and follows
		cameren.x = cameren.x + 60
		sim.run(15)
		each(function(role, b)
			if b.posture == "sitting" or moveState(b) ~= "follow" then
				fail("crew: the " .. role .. " stayed at the camp after Cameren left")
			end
		end)
		camp.inWorld = false

		-- 15. The ranger offers a camp when the group is hurt; "sure" places it
		writeData("bot:" .. ranger.oid .. ":crew:offerAt", 0)
		local rat3 = makeMob("a womp rat", cameren.x + 8, cameren.y, 400)
		attack(cameren, rat3)
		sim.run(20)
		cameren.wounds = {[0] = 250}
		t = nowMs()
		sim.run(40)
		if not anyLine(entries(log.group, ranger, t), "ranger", "campOffer") then
			fail("crew: the ranger didn't offer a camp to a wounded group")
		end
		t = nowMs()
		groupSay(cameren, "sure")
		sim.run(3)
		if #entries(log.camps, ranger, t) ~= 1 then
			fail("crew: 'sure' after the offer didn't place a camp")
		end
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end
		cameren.wounds = {}
		cameren.x = cameren.x + 40
		sim.run(15)

		-- 15b. A lair too close: the ranger says so, walks out, places the camp clear of it, and says where
		ctx.campLair = {x = cameren.x, y = cameren.y, r = 50}
		t = nowMs()
		groupSay(cameren, "let's camp here")
		sim.run(240)
		local searched = entries(log.camps, ranger, t)
		if not anyLine(entries(log.group, ranger, t), "ranger", "campSearchLair") then
			fail("crew: a lair close by, and the ranger didn't say it would look for a spot")
		end
		if #searched ~= 1 or math.sqrt((ctx.objects[searched[1].oid].x - ctx.campLair.x) ^ 2 + (ctx.objects[searched[1].oid].y - ctx.campLair.y) ^ 2) <= 50 then
			fail("crew: the ranger didn't place a camp clear of the lair (" .. #searched .. " camps)")
		end
		if not anyLine(entries(log.group, ranger, t), "ranger", "campUpThere") then
			fail("crew: the ranger didn't say where the camp is")
		end
		ctx.campLair = nil
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end
		sim.run(200)
		if readStringData("bot:" .. ranger.oid .. ":crew:order") == "stay" or moveState(ranger) ~= "follow" then
			fail("crew: after the camp search the ranger didn't go back to following")
		end

		-- 16. Tracking: what's around, a creature by name, one that isn't there
		trackList = {
			{name = "a womp rat", distance = 120, bearing = 45}, {name = "a womp rat", distance = 180, bearing = 50},
			{name = "a krayt dragon", distance = 640, bearing = 180}, {name = "a bantha", distance = 300, bearing = 270},
		}
		t = nowMs()
		groupSay(cameren, "what's around here?")
		sim.run(6)
		local tracks = entries(log.group, ranger, t)
		if #entries(log.tracks, ranger, t) ~= 1 or #tracks ~= 1 or not tracks[1].text:find("2 womp rats 120 m north-east", 1, true) or
			not tracks[1].text:find("krayt dragon 640 m south", 1, true) then
			fail("crew: the track report: " .. (tracks[1] and tracks[1].text or "none"))
		end
		t = nowMs()
		groupSay(cameren, "find me some krayts")
		sim.run(6)
		tracks = entries(log.group, ranger, t)
		if #tracks ~= 1 or not tracks[1].text:find("krayt", 1, true) or tracks[1].text:find("womp", 1, true) then
			fail("crew: tracking krayts: " .. (tracks[1] and tracks[1].text or "none"))
		end
		t = nowMs()
		groupSay(cameren, "track rancors")
		sim.run(6)
		tracks = entries(log.group, ranger, t)
		if #tracks ~= 1 or not anyLine(tracks, "ranger", "trackNoMatch") or not tracks[1].text:find("rancor", 1, true) then
			fail("crew: tracking what isn't there: " .. (tracks[1] and tracks[1].text or "none"))
		end
		realPrint("crew     " .. (tracks[1] and tracks[1].text or ""))

		-- 17. Going home: the whole group is sent home; they leave the group and walk or jump back to their stations
		t = nowMs()
		groupSay(cameren, "thanks all, you can go home")
		sim.run(4)
		if #entries(log.group, nil, t) ~= 1 then
			fail("crew: 'go home' got " .. #entries(log.group, nil, t) .. " answers, expected one")
		end
		sim.run(20)
		each(function(role, b)
			if b.groupId ~= nil then
				fail("crew: the " .. role .. " is still in the group after 'go home'")
			end
		end)
		sim.run(150)
		each(function(role, b)
			local entry = BotJobs:entry(b.first)
			if mode(b) ~= "home" or b.x ~= entry.station.x or b.y ~= entry.station.y then
				fail(string.format("crew: the %s isn't home (%s at %.0f, %.0f)", role, mode(b), b.x, b.y))
			end
		end)
		if members(cameren) ~= 0 then
			fail("crew: Cameren is still in a group of " .. members(cameren))
		end

		-- 18. A group with no player left: Cameren invites the tank and the rifleman, then leaves; the bots leave too
		cameren.x, cameren.y = tank.x + 2, tank.y
		invite(cameren, tank, true)
		sim.run(4)
		invite(cameren, rifleman, true)
		sim.run(6)
		leaveGroup(cameren)
		t = nowMs()
		sim.run(20)
		if tank.groupId ~= nil or rifleman.groupId ~= nil then
			fail("crew: bots stayed in a group with no player")
		end
		if #okCommands(tank, "makeleader", t) > 0 or #okCommands(rifleman, "makeleader", t) > 0 then
			fail("crew: a bot tried to lead a group of bots")
		end
		sim.run(60)

		-- 19. A duel at home: the tank fights back, and stops at the player's incap (no death blow)
		local zed = makeHuman("Zed", tank.x + 2, tank.y)
		zed.duelWith, tank.duelWith = tank.oid, zed.oid
		t = nowMs()
		startCombat(zed, tank)
		sim.run(12)
		if not engaged(tank, zed.oid, t) or entries(log.targets, tank, t)[1] == nil or entries(log.targets, tank, t)[1].target ~= zed.oid then
			fail("crew: the tank didn't fight back in a duel")
		end
		zed.incap = true
		local after = nowMs() + 2000
		sim.run(10)
		local blows = 0
		for _, c in ipairs(commands(tank, nil, after)) do if SPECIAL[c.cmd] then blows = blows + 1 end end
		if blows > 0 then
			fail("crew: the tank kept attacking an incapacitated player (" .. blows .. ")")
		end
		zed.incap, zed.duelWith, tank.duelWith = false, nil, nil
		dropFromCombat(zed)
		sim.run(30)

		-- 20. Restart (BotJobs:restart while grouped) leaves one loop, not two
		invite(cameren, rifleman, true)
		sim.run(5)
		sim.call("BotJobs", "onLogin", rifleman)
		local loops = 0
		local realLoop = BotCrew.loop
		BotCrew.loop = function(self, pBot, args)
			local a = {}
			for part in string.gmatch(args, "[^:]+") do table.insert(a, part) end
			if pBot == rifleman and BotJobs:current(pBot, a[1]) and tonumber(a[2]) == readData("bot:" .. pBot.oid .. ":crew:loopSeq") then
				loops = loops + 1
			end
			return realLoop(self, pBot, args)
		end
		sim.run(60)
		BotCrew.loop = realLoop
		if loops > 60 / 2.5 + 3 or loops < 60 / 2.5 - 4 then
			fail("crew: " .. loops .. " loop steps in 60 s after a restart (one chain makes 24)")
		end

		-- 21. Logout: nothing more from it
		api.botEnqueue(rifleman, "leavegroup", 0, "")
		sim.call("BotJobs", "onLogout", rifleman)
		rifleman.online, rifleman.inWorld = false, false
		t = nowMs() + 1
		sim.run(30)
		if #commands(rifleman, nil, t) > 0 or #entries(log.follows, rifleman, t) > 0 then
			fail("crew: a logged-out rifleman still acts")
		end

		local total = 0
		each(function(role, b) total = total + #commands(b, nil, 0) end)
		realPrint(string.format("crew     %d commands, %d group lines, %d spoken, %d tells, %d follows, %d walks, %d clones, %d camps",
			total, #log.group, #log.says, #log.tells, #log.follows, #log.moves, #log.clones, #log.camps))
		for i = 1, math.min(#sim.chatLog, 8) do
			realPrint("         " .. sim.chatLog[i])
		end
		teardown()
	end

	-- Scenario: destroy missions in the leader's direction (crew_missions.lua)

	function scenarios.crewmissions()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)

		-- 1. What group chat asks for: eight directions in words and letters, a count, the drop, and what isn't a request
		local cases = {
			{"grab two destroy missions north", "take", 0}, {"missions NE", "take", 45}, {"get missions east", "take", 90},
			{"Missions south east please", "take", 135}, {"missions S", "take", 180}, {"missions SW", "take", 225},
			{"get me missions west", "take", 270}, {"missions north-west", "take", 315}, {"missions NW", "take", 315},
			{"take missions southwest", "take", 225}, {"mission e", "take", 90}, {"drop your missions", "drop"},
			{"abort missions", "drop"}, {"get missions", "take"}, {"what's the plan, kragoth?", nil},
			{"no missions here", nil}, {"north of the dune sea", nil},
		}
		for _, c in ipairs(cases) do
			local r = BotCrew:missionRequest(c[1])
			if (c[2] == nil) ~= (r == nil) or (r ~= nil and (r.kind ~= c[2] or r.dir ~= c[3])) then
				fail("crewmissions: '" .. c[1] .. "' read as " .. (r and (r.kind .. " " .. tostring(r.dir)) or "nothing"))
			end
		end
		if BotCrew:missionRequest("grab one mission south").count ~= 1 or BotCrew:missionRequest("grab two missions south").count ~= 2 then
			fail("crewmissions: the count in the request")
		end

		-- 2. The pick: within 45 degrees (the edge counts), best pay first, at most the count
		local picked = BotCrew:missionPick({{oid = 1, reward = 100, degrees = 315}, {oid = 2, reward = 9999, degrees = 46},
			{oid = 3, reward = 4000, degrees = 0}, {oid = 4, reward = 7000, degrees = 44}, {oid = 5, reward = 5000, degrees = 200}},
			0, 2, 45)
		if #picked ~= 2 or picked[1].oid ~= 4 or picked[2].oid ~= 3 then
			fail("crewmissions: the pick took " .. #picked .. " missions, first " .. tostring(picked[1] and picked[1].oid))
		end
		if #BotCrew:missionPick({{oid = 1, reward = 1, degrees = 350}}, 10, 2, 45) ~= 1 then
			fail("crewmissions: the pick should wrap around north")
		end

		-- 3. The crew joins the leader, who stands by a terminal
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		for _, b in ipairs({tank, rifleman, medic, ranger}) do
			invite(cameren, b, true)
			sim.run(4)
		end
		if members(cameren) ~= 5 then
			fail("crewmissions: the crew didn't all join (" .. members(cameren) .. ")")
		end
		sim.run(10)
		local t1 = {oid = 7001, x = cameren.x + 8, y = cameren.y, planet = "tatooine"}
		mw.terminals = {t1}
		mw.lists.default = {{{degrees = 180, reward = 5000}, {degrees = 190, reward = 4000}, {degrees = 0, reward = 9000},
			{degrees = 270, reward = 3500}, {degrees = 90, reward = 2500}}}
		local function waypointsOf(b)
			local n = 0
			for _, w in pairs(cameren.waypoints or {}) do
				if w.bot == b.oid then n = n + 1 end
			end
			return n
		end
		local function lines(b, since) return entries(log.group, b, since) end

		-- 4. "get missions" with no direction: one question from the crew, nobody leaves
		local t = nowMs()
		groupSay(cameren, "get missions")
		sim.run(4)
		if #entries(log.group, nil, t) ~= 1 or not anyLine(entries(log.group, nil, t), "tank", "missionWhere") or #mw.accepts > 0 or
			next(mw.listCalls) ~= nil then
			fail("crewmissions: 'get missions' with no direction: " .. #entries(log.group, nil, t) .. " lines")
		end

		-- 5. "grab two destroy missions north": each bot walks to the terminal, refreshes for its pick, takes what Core3
		-- allows, reports its own, and its waypoints are in the leader's datapad
		mw.lists[tank.first] = {
			{{degrees = 350, reward = 3000}, {degrees = 46, reward = 9999}, {degrees = 180, reward = 8000}},
			{{degrees = 0, reward = 4000, target = "dewback nest"}, {degrees = 44, reward = 7000, distance = 1800}, {degrees = 315, reward = 100},
				{degrees = 46, reward = 9999}, {degrees = 200, reward = 5000}},
		}
		mw.lists[rifleman.first] = {{{degrees = 10, reward = 5000}, {degrees = 20, reward = 6000}}}
		mw.lists[ranger.first] = {{{degrees = 180, reward = 3000}, {degrees = 135, reward = 2000}}}
		rifleman.missions = {{oid = 1, reward = 1111, degrees = 0, distance = 800, target = "old lair"}}
		medic.missions = {{oid = 2, reward = 2222, degrees = 0, distance = 900, target = "mountain dewback lair"},
			{oid = 3, reward = 3333, degrees = 90, distance = 1100, target = "krayt lair"}}
		t = nowMs()
		groupSay(cameren, "grab two destroy missions north")
		sim.run(45)

		local function rewards(b)
			local out = {}
			for _, m in ipairs(b.missions or {}) do table.insert(out, m.reward) end
			return table.concat(out, ",")
		end
		if rewards(tank) ~= "7000,4000" then
			fail("crewmissions: the tank took " .. rewards(tank) .. " (7000,4000 are the best within 45 degrees)")
		end
		if mw.refreshes[tank.oid] ~= 2 then
			fail("crewmissions: the tank refreshed " .. tostring(mw.refreshes[tank.oid]) .. " times (the first list had one)")
		end
		if rewards(rifleman) ~= "1111,6000" then
			fail("crewmissions: the rifleman, holding one, should fill up to two: " .. rewards(rifleman))
		end
		if rewards(medic) ~= "2222,3333" or mw.listCalls[medic.oid] ~= nil then
			fail("crewmissions: the medic holds two and shouldn't have gone to the terminal")
		end
		if rewards(ranger) ~= "" or mw.refreshes[ranger.oid] ~= 5 then
			fail("crewmissions: the ranger took '" .. rewards(ranger) .. "' after " .. tostring(mw.refreshes[ranger.oid]) .. " refreshes (5, nothing north)")
		end
		for _, b in ipairs({tank, rifleman, medic, ranger}) do
			if #lines(b, t) ~= 1 then
				fail("crewmissions: " .. b.first .. " said " .. #lines(b, t) .. " lines, one report expected")
			end
			if #(b.missions or {}) > 2 then fail("crewmissions: " .. b.first .. " holds more than Core3's two") end
			if moveState(b) ~= "follow" then fail("crewmissions: " .. b.first .. " isn't following again (" .. moveState(b) .. ")") end
		end
		local said = lines(tank, t)[1].text
		if not anyLine(lines(tank, t), "tank", "missionTook") or not said:find("7,000", 1, true) or not said:find("1.8 km", 1, true) or
			not said:find("dewback nest", 1, true) or not said:find("north", 1, true) then
			fail("crewmissions: the tank's report: " .. said)
		end
		if not said:find("4,000", 1, true) then fail("crewmissions: the tank's report misses a lair: " .. said) end
		if not anyLine(lines(rifleman, t), "rifleman", "missionTook") or not lines(rifleman, t)[1].text:find("6,000", 1, true) or
			lines(rifleman, t)[1].text:find("1,111", 1, true) then
			fail("crewmissions: the rifleman reports only what it took: " .. lines(rifleman, t)[1].text)
		end
		if not anyLine(lines(medic, t), "medic", "missionFull") then
			fail("crewmissions: the medic should say it's full: " .. lines(medic, t)[1].text)
		end
		if not anyLine(lines(ranger, t), "ranger", "missionNone") or not lines(ranger, t)[1].text:find("north", 1, true) then
			fail("crewmissions: the ranger's report: " .. lines(ranger, t)[1].text)
		end
		if waypointsOf(tank) ~= 2 or waypointsOf(rifleman) ~= 2 or waypointsOf(medic) ~= 2 or waypointsOf(ranger) ~= 0 then
			fail("crewmissions: waypoints in the leader's datapad: " .. waypointsOf(tank) .. waypointsOf(rifleman) ..
				waypointsOf(medic) .. waypointsOf(ranger))
		end

		-- 6. "Drop your missions": every bot aborts its own, the waypoints go, each says so
		t = nowMs()
		groupSay(cameren, "drop your missions")
		sim.run(10)
		for _, b in ipairs({tank, rifleman, medic, ranger}) do
			if #(b.missions or {}) ~= 0 or waypointsOf(b) ~= 0 then
				fail("crewmissions: " .. b.first .. " still holds missions or has waypoints after the drop")
			end
		end
		if #lines(tank, t) ~= 1 or not anyLine(lines(tank, t), "tank", "missionDropped") or
			not anyLine(lines(ranger, t), "ranger", "missionNoneHeld") then
			fail("crewmissions: the drop lines")
		end

		-- 7. A bot that is named does its own errand only, and takes the one it was asked for
		mw.refreshes = {}
		mw.lists = {default = mw.lists.default}
		t = nowMs()
		groupSay(cameren, ranger.first .. ", get one mission west")
		sim.run(25)
		if rewards(ranger) ~= "3500" or mw.refreshes[tank.oid] ~= nil or #mw.accepts ~= 4 then
			fail("crewmissions: named, the ranger took '" .. rewards(ranger) .. "', the tank refreshed " .. tostring(mw.refreshes[tank.oid]))
		end
		groupSay(cameren, "scrap the missions")
		sim.run(10)

		-- 8. Two terminals: the crew spreads over them
		local t2 = {oid = 7002, x = cameren.x - 8, y = cameren.y, planet = "tatooine"}
		mw.terminals = {t1, t2}
		mw.refreshes, mw.accepts = {}, {}
		groupSay(cameren, "get two missions south")
		sim.run(45)
		local used = {}
		for _, a in ipairs(mw.accepts) do used[a.terminal] = true end
		if not used[7001] or not used[7002] then
			fail("crewmissions: the crew should use both terminals")
		end
		if rewards(tank) ~= "5000,4000" then fail("crewmissions: south, the tank took " .. rewards(tank)) end

		-- 9. A mission that ends takes its waypoint with it; a bot that leaves the group takes its waypoints
		local before = waypointsOf(tank)
		tank.missions = {tank.missions[1]}
		sim.run(10)
		if waypointsOf(tank) ~= before - 1 then
			fail("crewmissions: a finished mission should lose its waypoint (" .. before .. " -> " .. waypointsOf(tank) .. ")")
		end
		t = nowMs()
		groupSay(cameren, "kragoth, you can go home")
		sim.run(15)
		if tank.groupId ~= nil or waypointsOf(tank) ~= 0 or waypointsOf(rifleman) == 0 then
			fail("crewmissions: the tank left with its waypoints? tank " .. waypointsOf(tank) .. ", rifleman " .. waypointsOf(rifleman))
		end

		-- 10. No terminal near
		mw.terminals = {}
		for _, b in ipairs({rifleman, medic, ranger}) do b.missions = {} end
		t = nowMs()
		groupSay(cameren, ranger.first .. ", missions north")
		sim.run(5)
		if not anyLine(lines(ranger, t), "ranger", "missionNoTerminal") then
			fail("crewmissions: no terminal, no line")
		end

		local calls = 0
		for _, n in pairs(mw.listCalls) do calls = calls + n end
		realPrint(string.format("crewmissions %d missions accepted (the last round), %d list reads, %d aborts, %d group lines",
			#mw.accepts, calls, #mw.aborts, #log.group))
		teardown()
	end

	-- Scenario: the talk bridge faked

	function scenarios.crewbrain()
		local dir = os.getenv("SIM_TALK_DIR")
		if dir == nil then
			realPrint("crewbrain skipped (set SIM_TALK_DIR to an empty directory with req/ and rep/)")
			return
		end
		setup(dir)
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)

		local bridge = {on = true, requests = {}}
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
			if text:find("hold up") then
				return "ok\nneutral\nHolding up, boss.\nstay\n"
			elseif text:find("fire") then
				return "ok\nhappy\nSure, give me a second to set up.\ncamp\n"
			elseif text:find("anything") then
				return "ok\nneutral\nLet me have a look.\ntrack\n"
			end
			return "ok\nhappy\nYeah, good hunting so far.\n\n"
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
							sim.schedule(2000, function()
								local out = io.open(dir .. "/rep/" .. r.id .. ".txt", "w")
								out:write(reply)
								out:close()
							end)
						end
					end
				end
				handle:close()
			end
			sim.schedule(1000, tick)
		end
		heartbeat()
		tick()

		local cameren = makeHuman("Cameren", tank.x + 2, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		if members(cameren) ~= 5 then
			fail("crewbrain: " .. members(cameren) .. " in the group")
		end
		-- Out of town for the camp
		cameren.x, cameren.y = cameren.x + 500, cameren.y + 500
		sim.run(10)

		-- 1. Group chat naming nobody: one request (the first crew member's), the brain's line, and its order for all
		local before = #bridge.requests
		local t = nowMs()
		groupSay(cameren, "everyone hold up a moment")
		sim.run(6)
		local asked = {}
		for i = before + 1, #bridge.requests do
			if bridge.requests[i].type == "say" then table.insert(asked, bridge.requests[i]) end
		end
		if #asked ~= 1 or asked[1].channel ~= "group" or asked[1].npc ~= tank.oid or asked[1].job ~= "tank" then
			fail("crewbrain: " .. #asked .. " requests for one group line (expected the tank's, channel group)")
		end
		local said = entries(log.group, nil, t)
		if #said ~= 1 or said[1].text ~= "Holding up, boss." then
			fail("crewbrain: the brain's group answer")
		end
		each(function(role, b)
			if moveState(b) ~= "idle" or readStringData("bot:" .. b.oid .. ":crew:order") ~= "stay" then
				fail("crewbrain: the " .. role .. " didn't take the brain's 'stay'")
			end
		end)
		groupSay(cameren, "follow me")
		sim.run(8)

		-- 2. The brain's camp (asked of the ranger by the words): placed, with the brain's line only
		t = nowMs()
		groupSay(cameren, "can we get a fire going? need a rest")
		sim.run(6)
		if #entries(log.camps, ranger, t) ~= 1 then
			fail("crewbrain: no camp on the brain's 'camp'")
		end
		said = entries(log.group, nil, t)
		if #said ~= 1 or said[1].bot ~= ranger.oid or anyLine(said, "ranger", "campUp") then
			fail("crewbrain: the camp should have the brain's line alone")
		end
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end

		-- 3. The brain's track, by name: the brain's line, then the report
		trackList = {{name = "a bantha", distance = 200, bearing = 90}}
		t = nowMs()
		groupSay(cameren, ranger.first .. ", anything worth hunting near here?")
		sim.run(8)
		said = entries(log.group, ranger, t)
		if #said ~= 2 or said[1].text ~= "Let me have a look." or not said[2].text:find("bantha 200 m east", 1, true) then
			fail("crewbrain: the ranger's track by the brain: " .. #said .. " lines")
		end

		bridge.on = false
		os.remove(dir .. "/alive")
		realPrint(string.format("crewbrain %d requests, %d group lines", #bridge.requests, #log.group))
		teardown()
	end

	-- Scenario: swoops

	function scenarios.crewswoop()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		local sayChance = BotCrewSwoop.sayChance
		BotCrewSwoop.sayChance = 100

		local function riding(b) return b.riding == true end
		local function ridersCount()
			local n = 0
			each(function(role, b) if riding(b) then n = n + 1 end end)
			return n
		end
		local function mountsSince(t)
			return #entries(log.mounts, nil, t)
		end

		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b) invite(cameren, b, true) end)
		sim.run(10)
		if members(cameren) ~= 5 then
			fail("crewswoop: " .. members(cameren) .. " in the group, expected Cameren and four crew")
		end
		-- Out in the open, a little way from the cantina
		each(function(role, b) b.cell = 0 end)
		cameren.cell = 0
		sim.run(15)

		-- 1. The leader on foot: nobody calls a swoop
		local t = nowMs()
		cameren.move = {state = "goto", x = cameren.x + 20, y = cameren.y}
		cameren.speed = 5
		sim.run(10)
		cameren.speed = 0
		if mountsSince(t) > 0 or ridersCount() > 0 then
			fail("crewswoop: the crew mounted with the leader on foot")
		end

		-- 2. The leader mounts: every crew bot within range mounts within a few seconds, and says so
		t = nowMs()
		cameren.riding = true
		sim.run(8)
		if ridersCount() ~= 4 then
			fail("crewswoop: " .. ridersCount() .. " of four mounted eight seconds after the leader")
		end
		each(function(role, b)
			if #entries(log.mounts, b, t) ~= 1 then
				fail("crewswoop: the " .. role .. " tried to mount " .. #entries(log.mounts, b, t) .. " times")
			end
			if not b.hasSwoop then
				fail("crewswoop: the " .. role .. " has no swoop")
			end
		end)
		local lines = entries(log.group, nil, t)
		if #lines ~= 4 or not anyLine(lines, "tank", "swoopMount") then
			fail("crewswoop: " .. #lines .. " group lines on mounting, expected four of the swoopMount kind")
		end

		-- 3. Riding: a long ride at swoop speed, and the crew keep up (on foot they would fall 80 m behind)
		cameren.move = {state = "goto", x = cameren.x + 300, y = cameren.y}
		cameren.speed = 18
		sim.run(10)
		each(function(role, b)
			if dist(b, cameren) > 14 then
				fail(string.format("crewswoop: the %s is %.0f m behind the leader's swoop", role, dist(b, cameren)))
			end
			if not riding(b) then
				fail("crewswoop: the " .. role .. " got off on the ride")
			end
		end)
		sim.run(10)
		cameren.speed = 0

		-- 4. The leader gets off: they get off and store their swoops
		t = nowMs()
		cameren.riding = false
		sim.run(8)
		if ridersCount() ~= 0 then
			fail("crewswoop: " .. ridersCount() .. " still riding after the leader got off")
		end
		each(function(role, b)
			if b.swoopOut then fail("crewswoop: the " .. role .. " left its swoop standing") end
		end)
		if #entries(log.dismounts, nil, t) ~= 4 then
			fail("crewswoop: " .. #entries(log.dismounts, nil, t) .. " dismounts, expected four")
		end
		if not anyLine(entries(log.group, nil, t), "tank", "swoopOff") then
			fail("crewswoop: no line on getting off")
		end

		-- 5. Mount again; a creature attacks the tank: it gets off at once and fights, the others keep riding
		cameren.riding = true
		sim.run(8)
		if ridersCount() ~= 4 then
			fail("crewswoop: only " .. ridersCount() .. " remounted")
		end
		local mob = makeMob("a womp rat", tank.x + 20, tank.y, 600)
		t = nowMs()
		tank.vehicleAttacker = mob.oid	-- it goes for the tank's swoop, and the tank isn't "in combat" itself
		sim.run(4)
		if riding(tank) then
			fail("crewswoop: the tank kept riding while its swoop was attacked")
		end
		if not anyLine(entries(log.group, tank, t), "tank", "swoopFight") then
			fail("crewswoop: no line from the tank on getting off to fight")
		end
		if not engaged(tank, mob.oid, t) then
			fail("crewswoop: the tank didn't fight what attacked its swoop")
		end
		-- And one attacked directly
		local mob2 = makeMob("a womp rat", rifleman.x + 20, rifleman.y, 600)
		startCombat(mob2, rifleman)
		mob2.aggro = rifleman.oid
		sim.run(4)
		if riding(rifleman) then
			fail("crewswoop: the rifleman kept riding while attacked")
		end
		sim.run(60)
		if not mob.dead or not mob2.dead then
			fail("crewswoop: the crew didn't defeat the womp rats")
		end
		-- The fight is over: the tank stores a swoop left standing or mounts again with the leader
		sim.run(15)
		if tank.inCombat then
			fail("crewswoop: the tank is still in combat")
		end
		if not riding(tank) then
			fail("crewswoop: the tank didn't mount again after the fight")
		end

		-- 6. Told to stay, the crew doesn't mount; the leader on foot again first
		cameren.riding = false
		sim.run(8)
		groupSay(cameren, "everyone stay here a sec")
		sim.run(4)
		t = nowMs()
		cameren.riding = true
		sim.run(8)
		if mountsSince(t) > 0 then
			fail("crewswoop: the crew mounted while told to stay")
		end
		groupSay(cameren, "follow me")
		sim.run(10)
		if ridersCount() ~= 4 then
			fail("crewswoop: only " .. ridersCount() .. " mounted after 'follow me'")
		end

		-- 7. Indoors: no mount (Core3 refuses; the crew doesn't try)
		cameren.riding = false
		sim.run(8)
		each(function(role, b) if b.swoopOut then fail("crewswoop: the " .. role .. " left its swoop standing") end end)
		t = nowMs()
		ranger.cell, ranger.pinCell = 1082877, true
		cameren.riding = true
		sim.run(8)
		if riding(ranger) or #entries(log.mounts, ranger, t) > 0 then
			fail("crewswoop: the ranger tried to mount indoors")
		end
		ranger.cell, ranger.pinCell = 0, nil
		sim.run(8)
		if not riding(ranger) then
			fail("crewswoop: the ranger didn't mount once outdoors")
		end

		-- 8. Dismissed while riding: it leaves the group, gets off and stores its swoop
		api.botEnqueue(medic, "leavegroup", 0, "")
		sim.run(6)
		if riding(medic) or medic.swoopOut then
			fail("crewswoop: the medic left the group still on its swoop")
		end

		each(function(role, b)
			local r = refused(b, 0, {unarmedlunge2 = true, taunt = true})
			if #r > 0 then fail("crewswoop: refused " .. r[1]) end
		end)
		realPrint(string.format("crewswoop %d mounts, %d dismounts, %d group lines", #log.mounts, #log.dismounts, #log.group))
		BotCrewSwoop.sayChance = sayChance

	-- Scenario: looting, harvesting and the handover (Phase 7: crew_loot.lua against the mocked BotLoot bindings)

	function scenarios.crewloot()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)

		-- Gear the bots own: never goods, never offered (the mock's goods are only what it looted and harvested)
		each(function(role, b) b.gear = {"outfit", "weapon", "stims", "camp kit"} end)

		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		if members(cameren) ~= 5 then
			fail("crewloot: " .. members(cameren) .. " in the group")
		end
		sim.run(10)
		local gid = cameren.groupId

		local function goodsCount(b)
			return #(b.goods or {})
		end
		local function totalGoods()
			local n = 0
			each(function(role, b) n = n + goodsCount(b) end)
			return n
		end

		-- A creature the group kills: 3 things on it, credits, a hide to harvest
		local function kill(name, ownerGroup, loot, harvest)
			local mob = makeMob(name, cameren.x + 10, cameren.y + 6, 300)
			mob.ownerGroup, mob.loot, mob.credits, mob.harvest = ownerGroup, loot, 120, harvest
			attack(cameren, mob)
			return mob
		end

		-- 1. A fight: after it the ranger harvests the corpse, then a crew member (not the ranger) loots it
		local before = nowMs()
		local rat = kill("a womp rat", gid, {"Rat tooth", "Rusty blaster", "Credit chit"}, {kind = "hide", amount = 40, class = "Tatooinian Mammalian Hide"})
		sim.run(40)
		if not rat.dead then
			fail("crewloot: the womp rat didn't die")
		end
		local harvested = entries(log.harvests, nil, before)
		local looted = entries(log.loots, nil, before)
		local okHarvest, okLoot = nil, nil
		for _, h in ipairs(harvested) do
			if h.bot ~= ranger.oid then fail("crewloot: someone besides the ranger harvested") end
			if rat.harvested ~= nil and rat.harvested[ranger.oid] then okHarvest = okHarvest or h end
		end
		for _, l in ipairs(looted) do
			if l.bot == ranger.oid then fail("crewloot: the ranger looted with other crew in the group") end
			if #(ctx.objects[l.bot].goods or {}) > 0 then okLoot = okLoot or l end
		end
		if okHarvest == nil then
			fail("crewloot: the ranger didn't harvest the womp rat")
		end
		if okLoot == nil then
			fail("crewloot: nobody looted the womp rat")
		end
		if okHarvest.t > okLoot.t then
			fail("crewloot: looting didn't wait for the harvest")
		end
		if (rat.credits or 0) ~= 0 or cameren.cash < 120 then
			fail("crewloot: the credits didn't go to the human (" .. tostring(cameren.cash) .. ")")
		end
		for _, role in ipairs({"tank", "rifleman", "medic", "ranger"}) do
			if crew[role].cash ~= 100 then fail("crewloot: a bot took credits") end
		end
		if #rat.loot ~= 0 then
			fail("crewloot: " .. #rat.loot .. " items left on the corpse")
		end
		if totalGoods() ~= 4 then
			fail("crewloot: " .. totalGoods() .. " goods after one kill (3 items and the hide)")
		end
		if #(ranger.goods or {}) ~= 1 or ranger.goods[1].quantity ~= 40 then
			fail("crewloot: the ranger's hide")
		end
		local said = {}
		for _, l in ipairs(log.group) do said[#said + 1] = l.text end
		local sawLooted, sawHarvested = false, false
		for _, l in ipairs(log.group) do
			if isLine(l.text, "tank", "looted") or isLine(l.text, "rifleman", "looted") or isLine(l.text, "medic", "looted") then sawLooted = true end
			if isLine(l.text, "ranger", "harvested") then sawHarvested = true end
		end
		if not sawLooted or not sawHarvested then
			fail("crewloot: no group line for the loot or the harvest")
		end
		-- (the rest of the crew went back to following)
		each(function(role, b)
			if dist(b, cameren) > 14 then
				fail(string.format("crewloot: the %s stayed %.0f m behind after looting", role, dist(b, cameren)))
			end
		end)

		-- 2. Another group's kill and a player's corpse are left alone
		local before2 = totalGoods()
		local other = kill("a dewback", 999, {"Dewback hide scrap"}, nil)
		sim.run(40)
		if not other.dead or #other.loot ~= 1 or totalGoods() ~= before2 then
			fail("crewloot: the crew took another group's loot")
		end

		-- 3. "Hand it over" in group chat: every bot with goods offers; the ranger's hide and the loot reach Cameren; no gear
		local t = nowMs()
		cameren.received = {}
		groupSay(cameren, "ok everybody hand it over")
		sim.run(20)
		local offers = entries(log.offers, nil, t)
		if #offers < 1 then
			fail("crewloot: nobody offered on 'hand it over'")
		end
		for _, o in ipairs(offers) do
			if o.to ~= cameren.oid then fail("crewloot: an offer to someone else") end
			for _, item in ipairs(o.items) do
				if item.oid < 9000000 then fail("crewloot: a non-goods item in an offer") end
			end
		end
		if #cameren.received < 4 or totalGoods() ~= 0 then
			fail("crewloot: Cameren got " .. #cameren.received .. " items, " .. totalGoods() .. " still held")
		end
		local hideInTrade = false
		for _, item in ipairs(cameren.received) do
			if item.resource and item.quantity == 40 then hideInTrade = true end
			if item.name == "outfit" or item.name == "weapon" or item.name == "stims" or item.name == "camp kit" then
				fail("crewloot: gear in the handover")
			end
		end
		if not hideInTrade then
			fail("crewloot: the harvested hide wasn't handed over")
		end
		local gotLine = false
		for _, l in ipairs(entries(log.group, nil, t)) do
			if l.text:find("Accept the trade", 1, true) or l.text:find("Trade's open", 1, true) or isLine(l.text, "tank", "handoverFull") then
				gotLine = true
			end
		end
		if not gotLine then
			fail("crewloot: no 'Accept the trade' line (" .. table.concat(said, " | ") .. ")")
		end

		-- 4. Nothing held: the first crew member says so
		t = nowMs()
		groupSay(cameren, "give me the loot")
		sim.run(8)
		local nones = 0
		for _, l in ipairs(entries(log.group, nil, t)) do
			if isLine(l.text, "tank", "handoverNone") then nones = nones + 1 end
		end
		if nones ~= 1 or #entries(log.offers, nil, t) ~= 0 then
			fail("crewloot: asked with nothing held, " .. nones .. " lines and " .. #entries(log.offers, nil, t) .. " offers")
		end

		-- 5. A trade that doesn't all fit: the rest in a second trade once there's room
		local mob3 = kill("a rock wart", gid, {"Wart tooth", "Wart horn", "Wart eye"}, nil)
		sim.run(40)
		if not mob3.dead then fail("crewloot: the rock wart didn't die") end
		local held = totalGoods()
		if held ~= 3 then
			fail("crewloot: " .. held .. " goods after the rock wart (3)")
		end
		cameren.received, cameren.room = {}, 2
		sim.schedule(8000, function() cameren.room = 5 end)
		t = nowMs()
		groupSay(cameren, "trade me")
		sim.run(30)
		if #cameren.received ~= 3 or totalGoods() ~= 0 then
			fail("crewloot: split handover gave " .. #cameren.received .. " items, " .. totalGoods() .. " still held")
		end
		local batches = #entries(log.offers, nil, t)
		if batches < 2 then
			fail("crewloot: the split handover took " .. batches .. " trade(s)")
		end

		-- 6. A cancelled trade: it keeps the goods and doesn't offer again by itself
		local mob4 = kill("a krayt tooth thief", gid, {"Tooth"}, {kind = "bone", amount = 12, class = "Tatooinian Bone"})
		sim.run(40)
		held = totalGoods()
		if held ~= 2 then fail("crewloot: " .. held .. " goods after the fourth kill (2)") end
		sim.declineOffers = true
		t = nowMs()
		cameren.received = {}
		groupSay(cameren, "hand it over")
		sim.run(25)
		sim.declineOffers = false
		if totalGoods() ~= held or #cameren.received ~= 0 then
			fail("crewloot: a cancelled trade lost goods")
		end
		local offersMade = #entries(log.offers, nil, t)
		sim.run(30)
		if #entries(log.offers, nil, t) ~= offersMade then
			fail("crewloot: it offered again after the player cancelled")
		end
		local cancelLine = false
		for _, l in ipairs(entries(log.group, nil, t)) do
			if isLine(l.text, "tank", "handoverCancelled") then cancelLine = true end
		end
		if not cancelLine then
			fail("crewloot: no line after a cancelled trade")
		end

		-- 7. Dismissed with goods: it offers them before heading home, and only then goes
		local holder = nil
		each(function(role, b)
			if goodsCount(b) > 0 and holder == nil and role ~= "ranger" then holder = b end
		end)
		if holder == nil then
			holder = ranger
		end
		if goodsCount(holder) == 0 then
			fail("crewloot: nobody holds goods to dismiss with")
		end
		t = nowMs()
		cameren.received = {}
		local count = goodsCount(holder)
		leaveGroup(holder)
		holder.dismissed = true
		sim.run(6)
		if #entries(log.offers, holder, t) < 1 then
			fail("crewloot: a dismissed bot didn't offer its goods")
		end
		if mode(holder) == "home" then
			fail("crewloot: the dismissed bot went home before the handover")
		end
		sim.run(40)
		if goodsCount(holder) ~= 0 or #cameren.received < count then
			fail("crewloot: the dismissed bot kept " .. goodsCount(holder) .. " items")
		end
		if mode(holder) ~= "home" and mode(holder) ~= "walkingHome" then
			fail("crewloot: the dismissed bot didn't head home after (" .. mode(holder) .. ")")
		end

		-- 8. Regrouped while still holding goods from before: it says so and offers them
		holder.goods = {{oid = 9100001, name = "Old trophy", quantity = 1, resource = false, tradable = true}}
		t = nowMs()
		cameren.received = {}
		invite(cameren, holder, true)
		sim.run(25)
		local holding = false
		for _, l in ipairs(entries(log.group, holder, t)) do
			if isLine(l.text, holder.role, "holding") then holding = true end
		end
		if not holding then
			fail("crewloot: no 'still holding' line on regrouping")
		end
		if #cameren.received ~= 1 or goodsCount(holder) ~= 0 then
			fail("crewloot: regrouped, the old goods weren't handed over")
		end

		-- 9. Sent home by the group: the same
		local rider = rifleman
		rider.goods = {{oid = 9100002, name = "Spare part", quantity = 1, resource = false, tradable = true}}
		sim.run(6)
		t = nowMs()
		cameren.received = {}
		groupSay(cameren, "everyone go home, that's all for today")
		sim.run(60)
		if #cameren.received < 1 then
			fail("crewloot: sent home, the rifleman didn't hand over its goods")
		end
		each(function(role, b)
			if mode(b) ~= "home" and mode(b) ~= "walkingHome" then
				fail("crewloot: the " .. role .. " isn't going home (" .. mode(b) .. ")")
			end
		end)

		local looted, harvests, offered = #log.loots, #log.harvests, #log.offers
		realPrint(string.format("crewloot %d loot calls, %d harvests, %d trades offered, %d items handed to the player", looted, harvests,
			offered, sim.handedTotal or 0))
		for _, l in ipairs(log.group) do
			if l.text:find("trade", 1, true) or isLine(l.text, "ranger", "harvested") then
				realPrint("         " .. ctx.objects[l.bot].first .. ": " .. l.text)
				break
			end
		end
		teardown()
	end

	table.insert(order, "crew")
	table.insert(order, "crewbrain")
	table.insert(order, "crewmissions")
	table.insert(order, "crewswoop")
	table.insert(order, "crewloot")
end
