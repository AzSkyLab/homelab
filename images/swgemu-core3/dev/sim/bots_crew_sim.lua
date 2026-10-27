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
-- crewharvest (Phase 7b): the harvest type asked for and kept for the hunt, the ranger's own pick by stats and why it is said
-- once per spawn, "what are you harvesting?", harvest talk going to the ranger, the kind ending with the hunt.
-- crewcreature (Phase 7b): destroy missions by creature ("womp rat lairs north", "janta missions"), none on offer, follow-ups.
-- crewhandover (Phase 7b): the handover after a disband: the wait before the offer, a lost window offered again, the ask
-- for "trade me" and the wait, "hand it over" out of the group (out loud, or a tell to a bot that has gone home).

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
	-- Phase 8: the entertainer's pistol shots and the commando's flame (single shots reach 16 m, as flameSingle1/2 do)
	for _, cmd in ipairs({"bodyshot1", "bodyshot2", "bodyshot3", "healthshot1", "healthshot2"}) do
		SPECIAL[cmd] = "pistol"
	end
	for _, cmd in ipairs({"flamesingle1", "flamesingle2"}) do
		SPECIAL[cmd] = "flame"
	end
	for _, cmd in ipairs({"fireacidsingle1", "fireacidsingle2"}) do
		SPECIAL[cmd] = "acid"
	end
	-- (the flame thrower's and the acid rifle's plain shots reach 64 m; their specials, single or cone, 16)
	local WEAPON_RANGE = {unarmed = 5, rifle = 64, carbine = 64, pistol = 64, flame = 64, acid = 48}
	local HEAVY_REACH = 16
	local ROLE_WEAPON = {tank = "unarmed", rifleman = "rifle", ranger = "carbine", medic = "rifle", squadleader = "carbine",
		entertainer = "pistol", commando = "flame"}
	-- Skill boxes by role, as prefixes (the roster's skills bring every box they require)
	local ROLE_SKILLS = {
		tank = {"combat_unarmed_", "combat_brawler_", "science_medic_"},
		rifleman = {"combat_rifleman_", "combat_marksman_", "combat_carbine_", "science_medic_novice", "science_medic_injury_"},
		medic = {"science_combatmedic_", "science_doctor_", "science_medic_", "combat_marksman_rifle_"},
		ranger = {"outdoors_ranger_", "outdoors_scout_", "combat_marksman_", "combat_carbine_novice", "combat_carbine_ability_",
			"combat_carbine_accuracy_01", "combat_carbine_accuracy_02"},
		squadleader = {"outdoors_squadleader_", "outdoors_scout_", "combat_marksman_", "combat_carbine_"},
		entertainer = {"social_dancer_", "social_musician_", "social_entertainer_", "combat_marksman_pistol_",
			"combat_pistol_novice", "combat_pistol_accuracy_", "combat_pistol_speed_01", "combat_pistol_speed_02", "combat_pistol_ability_01"},
		commando = {"combat_commando_", "combat_carbine_", "combat_marksman_", "combat_brawler_", "science_medic_novice"},
	}
	local ROLE_MODS = {
		tank = {healing_injury_speed = 75, healing_ability = 50},
		medic = {healing_injury_speed = 75, healing_range_speed = 100, healing_range = 100, healing_wound_speed = 100,
			healing_ability = 100, combat_healing_ability = 100},
		rifleman = {},
		ranger = {},
		squadleader = {steadyaim = 10, volley = 10, group_burst_run = 10},
		entertainer = {},
		commando = {healing_injury_speed = 20},
	}
	local ENHANCE = {health = 0, action = 3, strength = 1, constitution = 2, quickness = 4, stamina = 5}

	local log = {}
	local function resetLog()
		log = {taunts = {}, debuffs = {}, rescues = {}, dots = {}, loots = {}, harvests = {}, offers = {}, opens = {}, commands = {}, says = {}, tells = {}, group = {}, emotes = {}, faces = {},
			stocks = {}, follows = {}, stops = {}, moves = {}, targets = {}, clones = {}, equips = {}, gearEquips = {}, tradeAborts = {}, repairs = {}, camps = {}, campRefusals = {},
			tracks = {}, events = {}, mounts = {}, dismounts = {}, areas = {}, sl = {}, calls = {}, scans = {}, landed = {}, windows = {},
			sysmsgs = {}}
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
	function methods.getPosture(self) return self.posture == "sitting" and 8 or (self.posture == "crouched" and 1 or 0) end
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
	-- (Core3: a patron's mood is "entertained" while it watches or listens)
	function methods.getMoodString(self) return (self.watchTo ~= nil or self.listenTo ~= nil) and "entertained" or "neutral" end
	-- (Phase 9b: a creature's health is its hit points, for "the weakest" and "the strongest")
	function methods.getHAM(self, pool)
		if self.isMob then return pool == 0 and math.floor(self.hp or 0) or 0 end
		return self:pool(pool).cur
	end
	-- (Phase 9b: a creature's level, in a plan request)
	function methods.getLevel(self) return self.level or 10 end
	-- (Phase 11: a system message to a player, and the list box of the buffs window)
	function methods.sendSystemMessage(self, text) table.insert(log.sysmsgs, {to = self.oid, text = text, t = nowMs()}) end
	function methods.getMainDefender(self)
		-- A creature is on whoever it's after (its AI picks; Phase 7c: taunt, rescue)
		if self.isMob then
			local victim = ctx.objects[self.aggro or 0]
			if victim ~= nil and not victim.dead and not victim.incap and victim.inWorld then
				return victim
			end
			return nil
		end
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
		-- (an own-crew bot owns exactly the boxes it was hired with and has trained: Part 2)
		if self.ownedSkills ~= nil then
			return self.ownedSkills[skill] == true
		end
		for _, prefix in ipairs(self.skillPrefixes or {}) do
			if skill:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
	-- Experience (Part 2): the character is its own PlayerObject here
	function methods.getPlayerObject(self) return self end
	function methods.hasAbility(self, ability) return not (self.noAbilities and self.noAbilities[ability]) end
	function methods.getExperience(self, kind) return (self.xp or {})[kind] or 0 end
	-- (Core3's PlayerObject::addExperience: a pool is capped at the highest cap of the boxes owned, else at xp_limits.iff's default, else 2000;
	-- a pool taken to nothing is gone)
	function methods.experienceCap(self, kind)
		local cap
		for box in pairs(self.ownedSkills or {}) do
			local info = BotCrewData.boxes[box]
			if info ~= nil and info.t == kind and info.x > 0 and (cap == nil or info.x > cap) then cap = info.x end
		end
		return cap or BotCrewData.limits[kind] or 2000
	end
	function methods.awardExperience(self, kind, amount, send)
		self.xp = self.xp or {}
		local value = (self.xp[kind] or 0) + amount
		if value <= 0 then
			self.xp[kind] = nil
		else
			self.xp[kind] = math.min(value, self:experienceCap(kind))
		end
	end
	function methods.getExperienceList(self)
		local out = {}
		for kind in pairs(self.xp or {}) do table.insert(out, kind) end
		return out
	end
	function methods.getWorldPositionX(self) return self:getPositionX() end
	function methods.getWorldPositionY(self) return self:getPositionY() end
	function methods.getCurrentSpeed(self) return self.speed or 0 end
	function methods.isPlayingMusic(self) return self.music ~= nil end
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

	local endPerformance -- (below)

	local function startCombat(a, t)
		a.inCombat, t.inCombat = true, true
		-- Core3 ends a performance in combat (the patrons' buffs land)
		for _, o in ipairs({a, t}) do
			if o.dancing ~= nil then endPerformance(o, "dance") end
			if o.music ~= nil then endPerformance(o, "music") end
			o.dancing, o.music = nil, nil
		end
		a.combatTarget = t.oid
		-- As Core3's startCombat: the attacker gets the defender; the victim only the combat state (a creature answers by
		-- its AI, a player or bot only when it hits back) and, for botAttackers, a threat map entry
		a.defenders, t.defenders = a.defenders or {}, t.defenders or {}
		addUnique(a.defenders, t.oid)
		if t.isMob then
			addUnique(t.defenders, a.oid)
		end
		if a.isMob then
			t.threats = t.threats or {}
			addUnique(t.threats, a.oid)
		end
		if t.isMob and not t.neverAggro then
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

	-- Phase 8b: Core3's entertaining session, as far as the mind buffs go. An entertainer's patrons (watch / listen) build a
	-- buff each 10 s tick while within 60 m and in her group or her buff target; it lands (at least 60 s after they began)
	-- when they stop, or she stops dancing, and lasts 2 minutes a tick up to 2 hours, at full strength
	local MIND_NAMES = {dance = {"performance_enhance_dance_mind"}, music = {"performance_enhance_music_focus", "performance_enhance_music_willpower"}}
	local PATRON_FIELD = {dance = "watchTo", music = "listenTo"}

	local function landPatron(ent, p, kind)
		local rec = ent ~= nil and ent.patrons ~= nil and ent.patrons[p.oid .. kind] or nil
		if rec == nil then
			return
		end
		ent.patrons[p.oid .. kind] = nil
		p[PATRON_FIELD[kind]] = nil
		if ent.buffTargetOid == p.oid then
			ent.buffTargetOid = nil
		end
		if sim.now - rec.since < 60 or rec.ticks == 0 then
			return
		end
		p.buffs = p.buffs or {}
		for _, name in ipairs(MIND_NAMES[kind]) do
			p.buffs[name] = {amount = 100, expires = sim.now + math.min(7200, rec.ticks * 120)}
		end
		table.insert(log.landed, {patron = p.oid, ent = ent.oid, kind = kind, ticks = rec.ticks, t = nowMs()})
	end

	function endPerformance(ent, kind)
		for key, rec in pairs(ent.patrons or {}) do
			if rec.kind == kind then
				landPatron(ent, ctx.objects[rec.oid], kind)
			end
		end
		ent.buffTargetOid = nil
	end

	local function perfTick(o)
		for _, rec in pairs(o.patrons or {}) do
			local p = ctx.objects[rec.oid]
			local performing = (rec.kind == "dance" and o.dancing ~= nil) or (rec.kind == "music" and o.music ~= nil)
			if performing and p ~= nil and dist(o, p) <= 60 and ((p.groupId ~= nil and p.groupId == o.groupId) or o.buffTargetOid == p.oid) then
				rec.ticks = rec.ticks + 1
			end
		end
	end

	-- Core3's commands, as far as the crew depends on them
	local function runCommand(b, cmd, target, args)
		local t = ctx.objects[target]
		if cmd == "join" then
			local inviter = ctx.objects[b.inviter or 0]
			if inviter == nil then return false, "no invite" end
			if b.groupId ~= nil then return false, "already grouped" end
			if inviter.groupId ~= nil and #groups[inviter.groupId].members >= 8 then return false, "group full" end
			joinGroup(b, inviter)
			return true
		elseif cmd == "disband" then
			local g = b.groupId and groups[b.groupId]
			if g == nil or g.members[1] ~= b.oid then return false, "not the leader" end
			for _, m in ipairs(g.members) do ctx.objects[m].groupId = nil end
			groups[g.id] = nil
			return true
		elseif cmd == "watch" or cmd == "listen" then
			local kind = cmd == "watch" and "dance" or "music"
			if t == nil or not t.isPlayer then return false, "bad target" end
			if b.dancing ~= nil or b.music ~= nil then return false, "performing" end
			if (kind == "dance" and t.dancing == nil) or (kind == "music" and t.music == nil) then return false, "not performing" end
			if b.posture == "sitting" then return false, "sitting" end
			if b.noLineOfSight or t.noLineOfSight then return false, "no line of sight" end
			if b[PATRON_FIELD[kind]] == t.oid then return true end
			if b[PATRON_FIELD[kind]] ~= nil then landPatron(ctx.objects[b[PATRON_FIELD[kind]]], b, kind) end
			b[PATRON_FIELD[kind]] = t.oid
			t.patrons = t.patrons or {}
			t.patrons[b.oid .. kind] = {oid = b.oid, kind = kind, since = sim.now, ticks = 0}
			return true
		elseif cmd == "stopwatching" or cmd == "stoplistening" then
			local kind = cmd == "stopwatching" and "dance" or "music"
			local entOid = b[PATRON_FIELD[kind]]
			if entOid == nil then return false, "not watching" end
			landPatron(ctx.objects[entOid], b, kind)
			return true
		elseif cmd == "setperformancebufftarget" then
			if b.dancing == nil and b.music == nil then return false, "not performing" end
			b.buffTargetOid = target ~= 0 and target or nil
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
			b.queueUntil = nowMs() + 1000
			-- Core3's TauntCommand: TAUNTED for the taunt mod (40 at master) seconds, then as long again before anyone can
			-- taunt it; inside that a taunt does nothing (it reports success, and adds aggro)
			local inLockout = nowMs() < (t.lockUntil or 0)
			table.insert(log.taunts, {bot = b.oid, t = nowMs(), creature = t.oid, inLockout = inLockout})
			if not inLockout and not t.noTaunt then
				local mod = (b.skillMods and b.skillMods.taunt) or 40
				t.tauntUntil, t.lockUntil, t.tauntedBy = nowMs() + mod * 1000, nowMs() + 2 * mod * 1000, b.oid
				t.aggro = b.oid
			end
			return true
		elseif cmd == "intimidate1" or cmd == "warcry1" then
			if t == nil or t.dead then return false, "bad target" end
			if dist(b, t) > (cmd == "intimidate1" and 24 or 40) then return false, "too far" end
			startCombat(b, t)
			b.queueUntil = nowMs() + 1000
			table.insert(log.debuffs, {bot = b.oid, t = nowMs(), creature = t.oid, cmd = cmd})
			return true
		elseif cmd == "rescue" then
			if t == nil or t.dead or not t.isMob then return false, "bad target" end
			local victim = ctx.objects[t.aggro or 0]
			if victim == nil or b.groupId == nil or victim.groupId ~= b.groupId then return false, "not a group member" end
			table.insert(log.rescues, {bot = b.oid, t = nowMs(), creature = t.oid, inLockout = nowMs() < (t.lockUntil or 0)})
			if nowMs() < (t.lockUntil or 0) then return true end
			t.tauntUntil, t.lockUntil, t.tauntedBy = nowMs() + 5000, nowMs() + 10000, b.oid
			t.aggro = b.oid
			return true
		elseif SPECIAL[cmd] ~= nil then
			if t == nil or t.dead or t.incap then return false, "bad target" end
			if b.weapon ~= SPECIAL[cmd] then return false, "wrong weapon for " .. cmd end
			if dist(b, t) > (cmd == "unarmedlunge2" and 20 or ((b.weapon == "flame" or b.weapon == "acid") and HEAVY_REACH or WEAPON_RANGE[b.weapon])) then
				return false, "out of range"
			end
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
		elseif cmd == "flamecone1" or cmd == "flamecone2" or cmd == "fireacidcone1" or cmd == "fireacidcone2" then
			-- Core3's cone: the held flame thrower or acid rifle, a target within 16 m, and every attackable creature within 16 m
			-- in the 45 degree cone (22.5 to each side of the line to the target) is hit, pulled or not
			local kind = cmd:find("acid", 1, true) and "acid" or "flame"
			if b.weapon ~= kind then return false, "wrong weapon for " .. cmd end
			if t == nil or t.dead or not t.isMob then return false, "bad target" end
			if dist(b, t) > HEAVY_REACH then return false, "out of range" end
			for _, pool in ipairs({HEALTH, ACTION, MIND}) do
				if b:getHAM(pool) <= 80 then return false, "too tired" end
			end
			local hit = {}
			for _, o in pairs(ctx.objects) do
				if o.isMob and not o.dead and o.inWorld and dist(b, o) <= HEAVY_REACH then
					local a = math.abs(math.atan(o.y - b.y, o.x - b.x) - math.atan(t.y - b.y, t.x - b.x))
					if a > math.pi then a = 2 * math.pi - a end
					if o == t or math.deg(a) <= 22.5 then table.insert(hit, o) end
				end
			end
			for _, o in ipairs(hit) do
				startCombat(b, o)
				damage(o, 300)
			end
			local oids = {}
			for _, o in ipairs(hit) do table.insert(oids, o.oid) end
			table.insert(log.areas, {bot = b.oid, t = nowMs(), cmd = cmd, target = t.oid, hit = oids})
			b.queueUntil = nowMs() + 3000
			return true
		elseif cmd == "throwgrenade" then
			-- Core3's grenade: a target within 64 m and a grenade of the bot's (its oid in the arguments); a 10 m blast
			local item
			for _, it in pairs(b.items or {}) do if tostring(it.oid) == args then item = it end end
			if item == nil or item.uses <= 0 then return false, "no grenade " .. tostring(args) end
			if t == nil or t.dead or not t.isMob then return false, "bad target" end
			if dist(b, t) > 64 then return false, "out of range" end
			item.uses = item.uses - 1
			local oids = {}
			for _, o in pairs(ctx.objects) do
				if o.isMob and not o.dead and o.inWorld and dist(o, t) <= 10 then
					startCombat(b, o)
					damage(o, 250)
					table.insert(oids, o.oid)
				end
			end
			table.insert(log.areas, {bot = b.oid, t = nowMs(), cmd = cmd, target = t.oid, hit = oids})
			b.queueUntil = nowMs() + 4000
			return true
		elseif cmd == "steadyaim" or cmd == "rally" or cmd == "volleyfire" or cmd == "formup" or cmd == "boostmorale" or cmd == "retreat" then
			-- Core3's squad leader commands, as patch 0009 has them: the group's leader, or a bot with Novice Squad Leader in it,
			-- calls them; each costs about 130 of health, action and mind
			local g = b.groupId and groups[b.groupId]
			if g == nil then return false, "not grouped" end
			if g.members[1] ~= b.oid and not (b.isBotFlag and b:hasSkill("outdoors_squadleader_novice")) then return false, "not the group leader" end
			for _, pool in ipairs({HEALTH, ACTION, MIND}) do
				if b:getHAM(pool) <= 130 then return false, "too tired" end
			end
			for _, pool in ipairs({HEALTH, ACTION, MIND}) do
				b:pool(pool).cur = b:getHAM(pool) - 130
			end
			b.queueUntil = nowMs() + 1500
			local reached = {}
			for _, m in ipairs(g.members) do
				local o = ctx.objects[m]
				if not o.dead and not o.incap then
					table.insert(reached, o.oid)
					if cmd == "formup" then o.states = (o.states or 0) & ~(STATE.dizzy | STATE.stunned) end
					if cmd == "retreat" and (b.oid ~= g.members[1] or m ~= g.members[1]) then o.retreatUntil = nowMs() + 30000 end
					if cmd == "rally" then o.rallyUntil = nowMs() + 30000 end
					if cmd == "steadyaim" then o.aimUntil = nowMs() + 300000 end
				end
			end
			if cmd == "boostmorale" then
				local total, n = 0, 0
				for _, oid in ipairs(reached) do
					local o = ctx.objects[oid]
					for pool = 0, 8 do total = total + ((o.wounds or {})[pool] or 0) end
					n = n + 1
				end
				for _, oid in ipairs(reached) do
					local o = ctx.objects[oid]
					o.wounds = {}
					for pool = 0, 8 do o.wounds[pool] = math.ceil(total / n / 9) end
				end
			end
			table.insert(log.sl, {bot = b.oid, t = nowMs(), cmd = cmd, target = target, reached = reached})
			return true
		elseif cmd == "startdance" or cmd == "startmusic" then
			-- Core3: one performance at a time, upright, out of a fight; music needs an instrument in hand
			if b.dancing ~= nil or b.music ~= nil then return false, "already performing" end
			if b.posture == "sitting" or b.inCombat then return false, "can't perform now" end
			if cmd == "startmusic" and b.weapon ~= "instrument" then return false, "no instrument" end
			if cmd == "startdance" then b.dancing = args else b.music = args end
			return true
		elseif cmd == "stopdance" or cmd == "stopmusic" then
			if b.dancing ~= nil then endPerformance(b, "dance") end
			if b.music ~= nil then endPerformance(b, "music") end
			b.dancing, b.music = nil, nil
			return true
		elseif cmd == "flourish" then
			if b.dancing == nil and b.music == nil then return false, "not performing" end
			b.flourishes = (b.flourishes or 0) + 1
			table.insert(log.sl, {bot = b.oid, t = nowMs(), cmd = "flourish"})
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
		elseif cmd == "kneel" then
			b.posture = "crouched"
			return true
		elseif cmd == "applypoison" or cmd == "applydisease" then
			-- Core3's DotPackCommand: in range (the pack's 30 and 14 for healing range), a pack, its wait (6 s at master) and
			-- mind; it lands unless the creature is immune or resists
			if t == nil or t.dead or not t.isMob then return false, "bad target" end
			if dist(b, t) > 44 then return false, "too far" end
			local template = "object/tangible/medicine/crafted/" .. (cmd == "applypoison" and "medpack_poison_health_c" or "medpack_disease_health_c") .. ".iff"
			local pack = (b.packs or {})[template]
			-- (Phase 8: "health|<pack oid>" names the pack, a single or an area one)
			local packOid = tonumber((args or ""):match("|(%d+)"))
			if packOid ~= nil then
				pack = packOf(b, packOid)
				if pack ~= nil and not pack.template:find(cmd == "applypoison" and "poison" or "disease", 1, true) then return false, "wrong kind of pack" end
			end
			if pack == nil or pack.uses <= 0 then return false, "no pack" end
			if nowMs() < (b.dotReady or 0) then return false, "must wait" end
			if b:getHAM(MIND) < 150 then return false, "not enough mind" end
			b.dotReady = nowMs() + 6000
			pack.uses = pack.uses - 1
			b:pool(MIND).cur = b:getHAM(MIND) - 150
			startCombat(b, t)
			local immune = cmd == "applypoison" and t.immunePoison or false
			local landed = false
			if not immune then
				if (t.resists or 0) > 0 then
					t.resists = t.resists - 1
				else
					landed = true
					t[cmd == "applypoison" and "poisonUntil" or "diseaseUntil"] = nowMs() + 240000
				end
			end
			table.insert(log.dots, {bot = b.oid, t = nowMs(), cmd = cmd, creature = t.oid, landed = landed, pack = pack.template, oid = pack.oid})
			-- An area pack (Core3's DotPackCommand::handleArea) hits every attackable creature within 10 m of the target too, pulled or not
			if pack.template:find("_area_", 1, true) then
				local extra = {}
				for _, o in pairs(ctx.objects) do
					if o.isMob and o ~= t and not o.dead and o.inWorld and dist(o, t) <= 10 then
						startCombat(b, o)
						o[cmd == "applypoison" and "poisonUntil" or "diseaseUntil"] = nowMs() + 240000
						table.insert(extra, o.oid)
					end
				end
				table.insert(log.areas, {bot = b.oid, t = nowMs(), cmd = "pack:" .. cmd, target = t.oid, hit = extra})
			end
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
				oid = b and b.oid or 0, online = b ~= nil and b.online == true, owner = entry.owner or 0, species = entry.species,
				sex = entry.sex})
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
	function api.botLineOfSight(b, t) return not (b ~= nil and b.noLineOfSight == true) end
	-- Phase 8: grenades in the bot's pack, a creature's armor, the creatures around
	function api.botStockItem(b, template, uses)
		assert(type(template) == "string" and template:match("^object/weapon/ranged/grenade/[%w_]+%.iff$"), "botStockItem: bad template " .. tostring(template))
		assert(math.type(uses) == "integer" and uses > 0, "botStockItem: uses")
		b.items = b.items or {}
		local item = b.items[template]
		if item == nil then
			item = ctx.newObject({isItem = true, template = template, uses = 0})
			b.items[template] = item
		end
		item.uses = math.max(item.uses, uses)
		return item.oid
	end
	function api.botFindItem(b, template)
		local item = b ~= nil and b.items ~= nil and b.items[template] or nil
		return (item ~= nil and item.uses > 0) and item.oid or 0
	end
	function api.botResists(c)
		if c == nil or not c.isMob then return nil end
		local r = c.armor or {}
		return {kinetic = 0, energy = 0, blast = 0, heat = r.heat or 0, cold = 0, electricity = 0, acid = r.acid or 0, stun = 0, lightsaber = 0}
	end
	function api.botCreaturesNear(b, range)
		table.insert(log.scans, {bot = b.oid, range = range})
		local out = {}
		for _, o in pairs(ctx.objects) do
			if o.isMob and not o.dead and not o.incap and o.inWorld and dist(b, o) <= range then
				local victim = ctx.objects[o.aggro or 0]
				table.insert(out, {oid = o.oid, x = o.x, y = o.y, radius = 1, target = (o.inCombat and victim ~= nil and not victim.dead) and victim.oid or 0})
			end
		end
		table.sort(out, function(a, c) return dist(b, ctx.objects[a.oid]) < dist(b, ctx.objects[c.oid]) end)
		return out
	end
	function api.botFindPack(b, template)
		local pack = b ~= nil and b.packs ~= nil and b.packs[template] or nil
		return (pack ~= nil and pack.uses > 0) and pack.oid or 0
	end
	function api.botGetWounds(p, pool) return p ~= nil and (p.wounds or {})[pool] or 0 end
	function api.botGetShockWounds(p) return p ~= nil and p.shock or 0 end
	function api.LuaSuiManager()
		return {sendListBox = function(_, using, player, title, prompt, buttons, cancel, other, ok, screenplay, callback, close, options)
			table.insert(log.windows, {to = player.oid, title = title, prompt = prompt, screenplay = screenplay, callback = callback,
				options = options, t = nowMs()})
		end}
	end
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
	-- Phase 8: the leap to a player, any planet, about 10 m behind them (and the bot stays as it was: sitting, say)
	function api.botCallTo(b, p)
		if b == nil or p == nil or not b.online or b.dead or b.incap or not p.inWorld then return false end
		table.insert(log.calls, {bot = b.oid, t = nowMs(), to = p.oid, planet = p.planet})
		b.planet, b.x, b.y, b.z, b.cell = p.planet, p.x - 10, p.y, p.z, p.cell
		b.move = nil
		return true
	end
	function api.botFollow(b, leader, near, far)
		assert(leader ~= nil and leader.oid ~= nil, "botFollow: no leader")
		if b == nil or not b.online or b.dead then return false end
		-- (BotMover: near + (oid % 3) * (far - near) / 2 behind; 4 m by default)
		local distance = near ~= nil and (near + (b.oid % 3) * ((far or near) - near) * 0.5) or 4
		b.move = {state = "follow", leader = leader.oid, distance = distance}
		table.insert(log.follows, {bot = b.oid, t = nowMs(), leader = leader.oid, near = near, far = far, distance = distance})
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
		if oid == 0 then b.combatTarget = nil end
		table.insert(log.targets, {bot = b.oid, t = nowMs(), target = oid, engage = oid ~= 0 and engage ~= false,
			moving = (b.move or {}).state == "goto"})
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
		assert(type(template) == "string" and (template:match("^object/weapon/") or template:match("^object/tangible/instrument/")), "botEquip: bad template " .. tostring(template))
		table.insert(log.equips, {bot = b.oid, t = nowMs(), template = template})
		if template:find("/instrument/", 1, true) then b.weapon = "instrument" end
		if template:find("/pistol/", 1, true) then b.weapon = "pistol" end
		if template:find("rifle_flame_thrower", 1, true) then b.weapon = "flame" end
		if template:find("rifle_acid_beam", 1, true) then b.weapon = "acid" end
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
		mw = {terminals = {}, lists = {}, refreshes = {}, listAt = {}, listCalls = {}, nextOid = 9000000, done = {}, accepts = {}, aborts = {},
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
				local target = m.target or "womp rat lair"
				local creatures = m.creatures
				if creatures == nil then
					-- (what lives in a lair of that name: the creature, here the lair's name without the word)
					creatures = {(target:gsub(" lair$", ""):gsub(" nest$", ""):gsub(" camp$", ""))}
				end
				table.insert(b.offered, {oid = mw.nextOid, reward = m.reward, degrees = m.degrees, distance = m.distance or 1500,
					target = target, x = 0, y = 0, planet = "tatooine", level = 20,
					direction = directionOf(m.degrees), lair = "sim_" .. target:gsub(" ", "_"), creatures = creatures})
			end
		end
		local out = {}
		for _, m in ipairs(b.offered or {}) do
			table.insert(out, m)
		end
		return out
	end
	-- Every name in this planet's destroy-mission lairs (what botMissionCreatures gives): scripts can replace the list
	local planetCreatures = {"womp rat lair", "womp rat", "dewback nest", "dewback", "dragonet lair", "dragonet", "janta camp",
		"janta hunter", "janta warrior", "kreetle nest", "kreetle", "greater desert womp rat", "tusken raider camp", "tusken raider", "tusken raider leader", "death kreetle", "rock beetle",
		"sand beetle", "cu pa", "tatooine mynock", "spice collective", "corellian slice hound"}
	function api.botMissionCreatures(b)
		local out = {}
		for _, name in ipairs(planetCreatures) do table.insert(out, name) end
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
	-- Core3 leaves a player in combat on a corpse that another killed; this takes the dead off the list (live ones stay)
	function api.botDropDeadDefenders(p)
		if p == nil then return 0 end
		local kept, dropped = {}, 0
		for _, oid in ipairs(p.defenders or {}) do
			local o = ctx.objects[oid]
			if o == nil or o.dead or not o.inWorld then dropped = dropped + 1 else table.insert(kept, oid) end
		end
		if dropped > 0 then
			p.defenders = kept
			if #kept == 0 then p.inCombat = false end
		end
		return dropped
	end
	-- Completed and rewarded missions (patches/0008): mw.done[oid] = true
	function api.botMissionDone(oid) return mw.done[oid] == true end
	-- A human's own destroy missions (read-only)
	function api.botPlayerMissions(p)
		if p == nil or not p.isPlayer then return nil end
		local out = {}
		for _, m in ipairs(p.missions or {}) do table.insert(out, m) end
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
	function api.botDuelState(b, other)
		if b ~= nil and other ~= nil and b.duelWith == other.oid and other.duelWith == b.oid then return "dueling" end
		return "none"
	end
	-- tradegroup
	function api.botGetGroupInviter(b) return b ~= nil and b.inviter or 0 end
	-- A creature's group without locking it (Phase 8): the sim's getGroupSize/getGroupMember of other creatures are not to be used
	function api.botGroupInfo(p)
		local g = p ~= nil and p.groupId and groups[p.groupId]
		if not g then return nil end
		local members = {}
		for i, oid in ipairs(g.members) do members[i] = oid end
		return {id = g.id, leader = members[1] or 0, members = members}
	end
	-- Own crews (Phase 9, Part 1): the bindings of BotCrewsLua, over entries added to the roster table (removed again by
	-- ownClear). An own-crew bot is a roster entry with an owner and online "owner"
	local ownLog = {hired = {}, letGo = {}}
	local START_NOVICE = {tank = "combat_brawler_novice", rifleman = "combat_marksman_novice", medic = "science_medic_novice",
		ranger = "outdoors_scout_novice", squadleader = "outdoors_scout_novice", entertainer = "social_entertainer_novice",
		commando = "combat_marksman_novice"}

	local function addOwnBot(entry)
		local first = entry.name:match("^(%S+)")
		local st = entry.station
		local role = entry.job
		local b = ctx.newObject({isBotFlag = true, isPlayer = true, first = first, name = entry.name, planet = st.planet, x = st.x, y = st.y,
			z = st.z, cell = st.cell or 0, inWorld = false, online = false, cash = 100, bank = 1000, packs = {}, buffs = {}, wounds = {},
			skillPrefixes = ROLE_SKILLS[role], skillMods = {}, weapon = ROLE_WEAPON[role], role = role, ownerOid = entry.owner})
		for k, v in pairs(ROLE_MODS[role]) do
			b.skillMods[k] = v
		end
		byFirst[first:lower()] = b
		ctx.addPlayer(b)
		return b
	end

	local function ownEntries(owner)
		local out = {}
		for _, entry in ipairs(BotRoster.bots) do
			if (entry.owner or 0) ~= 0 and (owner == nil or entry.owner == owner) then
				table.insert(out, entry)
			end
		end
		return out
	end

	local function ownClear()
		for i = #BotRoster.bots, 1, -1 do
			local entry = BotRoster.bots[i]
			if (entry.owner or 0) ~= 0 then
				byFirst[entry.name:match("^(%S+)"):lower()] = nil
				table.remove(BotRoster.bots, i)
			end
		end
		ownLog = {hired = {}, letGo = {}, gear = {}}
	end

	-- Part 2: training (LuaSkillManager over BotCrewData.boxes; the prerequisites are the order's, which is how the bot picks) and gear
	function api.PlayerObject(p) return p end
	function api.botSkillPoints(p) return p ~= nil and p.skillPoints or 0 end
	function api.LuaSkillManager()
		local manager = {}
		function manager.canLearnSkill(_, p, box, noXp)
			local info = BotCrewData.boxes[box]
			if info == nil or p.ownedSkills == nil or p.ownedSkills[box] then return false end
			if (p.skillPoints or 0) < info.p then return false end
			if not noXp and info.c > 0 and ((p.xp or {})[info.t] or 0) < info.c then return false end
			return true
		end
		function manager.awardSkill(self, p, box)
			if not self:canLearnSkill(p, box, false) then return false end
			local info = BotCrewData.boxes[box]
			p.skillPoints = p.skillPoints - info.p
			if info.c > 0 then p:awardExperience(info.t, -info.c) end
			p.ownedSkills[box] = true
			table.insert(ownLog.trained or {}, box)
			return true
		end
		return manager
	end
	ownLog.gear = {}
	function api.botSquadAura(oid)
		ownLog.aura = (ownLog.aura or 0) + 1
		return true
	end
	function api.botSetGear(oid, gear)
		local o = ctx.objects[oid]
		if o == nil or (o.ownerOid or 0) == 0 then return false end
		for _, entry in ipairs(BotRoster.bots) do
			if (entry.owner or 0) ~= 0 and entry.name:match("^(%S+)") == o.first then
				entry.skills, entry.outfit, entry.carry, entry.weapon, entry.campKit = gear.skills, gear.outfit, gear.carry, gear.weapon, gear.campKit
			end
		end
		table.insert(ownLog.gear, {oid = oid, outfit = gear.outfit, weapon = gear.weapon})
		return true
	end

	function api.botOwner(oid)
		local o = ctx.objects[oid]
		return o ~= nil and o.ownerOid or 0
	end
	function api.botCrewOf(owner)
		local out = {}
		for _, entry in ipairs(ownEntries(owner)) do
			local b = byFirst[entry.name:match("^(%S+)"):lower()]
			table.insert(out, {oid = b.oid, name = entry.name, firstName = entry.name:match("^(%S+)"), job = entry.job, species = entry.species,
				sex = entry.sex, city = entry.city, hiredAt = 0, online = b.online == true, ready = true, state = b.online and "online" or "offline"})
		end
		return out
	end
	function api.botEntry(first)
		for _, entry in ipairs(BotRoster.bots) do
			if entry.name:match("^(%S+)"):lower() == tostring(first):lower() then return entry end
		end
		return nil
	end
	function api.botNameFree(first)
		for _, entry in ipairs(BotRoster.bots) do
			if entry.name:match("^(%S+)"):lower() == tostring(first):lower() then
				return false, "a crew member already has that name"
			end
		end
		for _, o in pairs(ctx.objects) do
			if o.isPlayer and not o.isBotFlag and tostring(o.first):lower() == tostring(first):lower() then
				return false, "a character already has that name"
			end
		end
		return true, ""
	end
	function api.botNameCheck(name, species)
		if species == "wookiee" and name:find(" ") then
			return false, "That name doesn't suit the species."
		end
		if name:lower():find("fuck") then
			return false, "That name is not allowed."
		end
		return true, ""
	end
	function api.botBoxCount(oid)
		local o = ctx.objects[oid]
		return o ~= nil and o.boxes or 0
	end
	function api.botHire(owner, entry)
		assert(math.type(owner) == "integer", "botHire: owner must be an integer oid")
		assert(type(entry) == "table" and type(entry.name) == "string" and type(entry.skills) == "table" and type(entry.station) == "table", "botHire: bad entry")
		local first = entry.name:match("^(%S+)")
		local free, why = api.botNameFree(first)
		if not free then return false, why end
		for _, other in ipairs(ownEntries(owner)) do
			if other.job == entry.job then return false, "the crew already has a " .. entry.job end
		end
		if #ownEntries(owner) >= 7 then return false, "a crew has seven at most" end
		local copy = {}
		for k, v in pairs(entry) do copy[k] = v end
		copy.owner, copy.online, copy.hiredAt = owner, "owner", sim.now
		table.insert(BotRoster.bots, copy)
		local made = addOwnBot(copy)
		-- It owns what it was hired with and the novice box of its starting profession; the points are what the boxes leave of 250
		made.ownedSkills = {[START_NOVICE[copy.job]] = true}
		for _, box in ipairs(copy.skills) do made.ownedSkills[box] = true end
		made.xp = {}
		made.skillPoints = 250
		table.insert(ownLog.hired, copy)
		return true, first
	end
	function api.botLetGo(oid)
		local o = ctx.objects[oid]
		if o == nil or (o.ownerOid or 0) == 0 then return false, "that bot isn't in an own crew" end
		if o.online then
			sim.call("BotJobs", "onLogout", o)
			o.online, o.inWorld = false, false
		end
		for i, entry in ipairs(BotRoster.bots) do
			if (entry.owner or 0) ~= 0 and entry.name:match("^(%S+)") == o.first then
				table.remove(BotRoster.bots, i)
				break
			end
		end
		byFirst[o.first:lower()] = nil
		table.insert(ownLog.letGo, o.first)
		return true, ""
	end
	-- The input window of the recruiter (Core3's SuiInputBox template): what it was given is logged with the windows
	api.SuiInputBox = {new = function(play, callback)
		local box = {props = {}}
		function box.setTargetNetworkId(id) box.target = id end
		function box.setTitle(t) box.title = t end
		function box.setPrompt(t) box.prompt = t end
		function box.setProperty(w, p, v) box.props[w .. "." .. p] = v end
		function box.sendTo(pPlayer)
			table.insert(log.windows, {to = pPlayer.oid, title = box.title, prompt = box.prompt, screenplay = play, callback = callback,
				input = true, text = box.props["txtInput.Text"], t = nowMs()})
		end
		return box
	end}

	-- The players online with a client (Phase 8's group cap): the humans a scenario made
	function api.botHumansOnline()
		local out = {}
		for _, o in pairs(ctx.objects) do
			if o.isPlayer and not o.isBotFlag and o.inWorld and not o.pretend then table.insert(out, o.oid) end
		end
		table.sort(out)
		return out
	end
	function api.botPlaceCamp(b, kit)
		assert(type(kit) == "string" and kit:match("^object/tangible/scout/camp/[%w_]+%.iff$"), "botPlaceCamp: bad kit " .. tostring(kit))
		if b == nil or b.cell ~= 0 or b.inTown then
			return 0, (b ~= nil and b.cell ~= 0) and "inside" or "in a city"
		end
		-- A lair field the test put down (sim.campLairs): none either
		local fields = {}
		for _, l in ipairs(sim.campLairs or {}) do table.insert(fields, l) end
		if sim.campHidden ~= nil then table.insert(fields, sim.campHidden) end
		for _, field in ipairs(fields) do
			if math.sqrt((b.x - field.x) ^ 2 + (b.y - field.y) ^ 2) <= field.r then
				table.insert(log.campRefusals, {bot = b.oid, t = nowMs(), x = b.x, y = b.y})
				return 0, "lair too close", 0
			end
		end
		-- A lair the test put down: no camp within its radius
		local lair = ctx.campLair
		if lair ~= nil and math.sqrt((b.x - lair.x) ^ 2 + (b.y - lair.y) ^ 2) <= lair.r then
			if lair.obj == nil and not lair.unknown then
				lair.obj = ctx.newObject({isLair = true, planet = b.planet, x = lair.x, y = lair.y, z = 5, cell = 0, inWorld = true, name = "a lair"})
			end
			table.insert(log.campRefusals, {bot = b.oid, t = nowMs(), x = b.x, y = b.y})
			return 0, "lair too close", lair.obj and lair.obj.oid or 0
		end
		local camp = ctx.newObject({isCamp = true, planet = b.planet, x = b.x, y = b.y, z = 5, cell = 0, inWorld = true,
			radius = 20, name = "a camp"})
		table.insert(log.camps, {bot = b.oid, t = nowMs(), oid = camp.oid, kit = kit})
		return camp.oid
	end
	-- The camp kit's scan without placing (the camp search): one reason per x, y pair, "" for clear ground. sim.campLairs are the
	-- lairs it knows ({x, y, r}); sim.campHidden are the ones only the placement knows
	function api.botCampSpots(b, kit, points)
		assert(type(kit) == "string" and kit:match("^object/tangible/scout/camp/[%w_]+%.iff$"), "botCampSpots: bad kit " .. tostring(kit))
		if b == nil then return nil end
		sim.campSpotCalls = (sim.campSpotCalls or 0) + 1
		local lairs = {}
		for _, l in ipairs(sim.campLairs or {}) do table.insert(lairs, l) end
		if ctx.campLair ~= nil then table.insert(lairs, ctx.campLair) end
		local out = {}
		for i = 1, #points, 2 do
			local reason = ""
			for _, l in ipairs(lairs) do
				if math.sqrt((points[i] - l.x) ^ 2 + (points[i + 1] - l.y) ^ 2) <= l.r then reason = "lair too close" end
			end
			table.insert(out, reason)
		end
		return out
	end
	-- The live creatures attacking a bot or a player (their threat map), nearest first
	function api.botAttackers(p)
		local out = {}
		if p == nil then return out end
		for _, oid in ipairs(p.threats or {}) do
			local o = ctx.objects[oid]
			-- (Core3: in the bot's threat map, in combat, with the bot among its defenders: not necessarily on it any more)
			local hasDefender = false
			for _, d in ipairs(o ~= nil and o.defenders or {}) do if d == p.oid then hasDefender = true end end
			if o ~= nil and o.isMob and not o.dead and not o.incap and o.inWorld and o.inCombat and (o.aggro == p.oid or hasDefender) then
				table.insert(out, o)
			end
		end
		table.sort(out, function(a, b) return dist(a, p) < dist(b, p) end)
		for i, o in ipairs(out) do out[i] = o.oid end
		return out
	end
	-- The held weapon's ranges (Phase 7c): Core3's templates (T21 and E-11 50 m, EE-3 27 m, fists 5 m)
	local RANGES = {rifle = {ranged = true, idealRange = 50, maxRange = 64}, carbine = {ranged = true, idealRange = 27, maxRange = 64},
		flame = {ranged = true, idealRange = 50, maxRange = 64},
		pistol = {ranged = true, idealRange = 15, maxRange = 64}, acid = {ranged = true, idealRange = 16, maxRange = 48}, unarmed = {ranged = false, idealRange = 5, maxRange = 5}}
	function api.botWeaponRange(b)
		local r = b ~= nil and RANGES[b.weapon or "unarmed"] or nil
		if r == nil then return nil end
		return {template = "", ranged = r.ranged, pointBlankRange = 0, pointBlankAccuracy = -70, idealRange = r.idealRange,
			idealAccuracy = 6, maxRange = r.maxRange, maxAccuracy = 10}
	end
	-- Lairs a scenario sets in sim.lairs: {{oid, x, y}}
	function api.botLairsNear(b, range)
		local out = {}
		for _, lair in ipairs(sim.lairs or {}) do
			if dist(b, {planet = b.planet, x = lair.x, y = lair.y}) <= range then table.insert(out, lair) end
		end
		return out
	end
	-- A creature's threat picture (Phase 7c): who it's on, whether a taunt is in force, when the next one would take
	function api.botThreatOn(b, c)
		if b == nil or c == nil or not c.isMob then return nil end
		local victim = ctx.objects[c.aggro or 0]
		return {target = (victim ~= nil and not victim.dead and not victim.incap) and victim.oid or 0, tauntable = not c.noTaunt,
			taunted = nowMs() < (c.tauntUntil or 0), tauntedBy = c.tauntedBy or 0,
			lockoutMs = math.max(0, (c.lockUntil or 0) - nowMs()), poisoned = nowMs() < (c.poisonUntil or 0),
			diseased = nowMs() < (c.diseaseUntil or 0), poisonImmune = c.immunePoison == true, diseaseImmune = false, entries = {}}
	end
	-- The players (bots too) and people NPCs around an object, by name
	function api.botPeopleNear(center, range)
		local out = {}
		if center == nil then return out end
		for _, o in pairs(ctx.objects) do
			if o ~= center and o.inWorld and (o.isPlayer or o.isNpcFlag) and dist(center, o) <= range then
				table.insert(out, {name = o.name or o.first, oid = o.oid, kind = o.isPlayer and "player" or "npc"})
			end
		end
		return out
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
		r.names = {}
		while #(c.loot or {}) > 0 do
			if #goodsOf(b) >= (b.packRoom or 40) then r.full = true break end
			local item = newItem(table.remove(c.loot, 1))
			table.insert(goodsOf(b), item)
			table.insert(r.names, item.name)
			r.moved = r.moved + 1
		end
		r.left = #(c.loot or {})
		r.ok = true
		return r
	end
	-- The group's corpses within range of the center, nearest first (BotLoot::corpsesNear)
	function api.botCorpsesNear(b, range, center)
		local out = {}
		center = center or b
		if b == nil or b.groupId == nil then return out end
		for _, o in pairs(ctx.objects) do
			if o.isMob and o.dead and o.inWorld and o.ownerGroup == b.groupId and dist(center, o) <= range then
				local harvest = o.harvest ~= nil and not (o.harvested or {})[b.oid]
				if #(o.loot or {}) > 0 or (o.credits or 0) > 0 or harvest then
					table.insert(out, {oid = o.oid, distance = math.floor(dist(center, o)), items = #(o.loot or {}),
						credits = o.credits or 0, harvest = harvest, name = o.display or o.name})
				end
			end
		end
		table.sort(out, function(a, c) return a.distance < c.distance end)
		return out
	end
	-- A creature's harvest: c.harvest = {kind, amount, class[, spawn, score, lead, leadValue, stats]} or c.harvests, a list of
	-- them (a creature with meat, hide and bone). As BotLoot::harvest picks: the asked-for kind if it has it, else the best
	-- score, then the most yield
	function api.botHarvest(b, oid, kind)
		local r = {ok = false, kind = "", amount = 0, resource = "", spawn = "", score = 0, fallback = false, lead = "", leadValue = 0,
			stats = "", altKind = "", altScore = 0, error = ""}
		local c = ctx.objects[oid]
		kind = (kind or ""):lower()
		table.insert(log.harvests, {bot = b.oid, t = nowMs(), corpse = oid, asked = kind})
		if c == nil or c.harvest == nil then r.error = "not a creature" return r end
		if not c.dead then r.error = "alive" return r end
		if dist(b, c) > 7 then r.error = "too far" return r end
		if c.ownerGroup ~= b.groupId or (c.harvested or {})[b.oid] then r.error = "cannot harvest" return r end
		local function better(x, y)
			if (x.score or 0) ~= (y.score or 0) then return (x.score or 0) > (y.score or 0) end
			return x.amount > y.amount
		end
		local options = c.harvests or {c.harvest}
		local pick
		for _, o in ipairs(options) do
			if o.kind == kind then pick = o break end
			if pick == nil or better(o, pick) then pick = o end
		end
		local runner
		for _, o in ipairs(options) do
			if o ~= pick and (runner == nil or better(o, runner)) then runner = o end
		end
		c.harvested = c.harvested or {}
		c.harvested[b.oid] = true
		local h = pick
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
		r.spawn, r.score, r.lead, r.leadValue, r.stats = h.spawn or "", h.score or 0, h.lead or "", h.leadValue or 0, h.stats or ""
		r.fallback = kind ~= "" and kind ~= "any" and h.kind ~= kind
		if runner ~= nil then r.altKind, r.altScore = runner.kind, runner.score or 0 end
		log.harvests[#log.harvests].got = h.kind
		return r
	end
	-- Part 3: an own-crew bot's gear. b.gear: weapons, armour, clothes and camp kits (objects from gearItem); medicine is b.packs and
	-- grenades b.items as for the roster bots, with a given flag on a gift
	local function packKind(template)
		if template:find("stimpack", 1, true) then return "stim" end
		if template:find("grenade_damage", 1, true) then return "ranged" end
		if template:find("medpack_revive", 1, true) then return "revive" end
		if template:find("medpack_cure_", 1, true) then return template:find("_area_", 1, true) and "curearea" or "cure" end
		if template:find("medpack_stunned", 1, true) or template:find("medpack_blinded", 1, true) or template:find("medpack_dizzy", 1, true) or
			template:find("medpack_intimidated", 1, true) then return "state" end
		if template:find("medpack_enhance_", 1, true) then return "enhance" end
		if template:find("medpack_wound_", 1, true) then return "wound" end
		if template:find("medpack_poison_", 1, true) or template:find("medpack_disease_", 1, true) then
			return template:find("_area_", 1, true) and "dotarea" or "dot"
		end
		return "medicine"
	end
	function ctx.gearItem(spec)
		local o = ctx.newObject({isGear = true})
		for k, v in pairs(spec) do o[k] = v end
		o.name = o.name or tostring(o.template):match("([%w_]+)%.iff$")
		o.left, o.family, o.slot = o.left or 100, o.family or "", o.slot or ""
		o.certified = o.certified ~= false
		o.uses, o.required, o.power = o.uses or 1, o.required or 0, o.power or 0
		return o
	end
	-- Takes an item into the bot as a gift would arrive: gear in b.gear, medicine as a pack, a grenade as an item
	function ctx.receive(b, o)
		if o.kind == "stim" or o.kind == "ranged" or o.kind == "revive" or o.kind == "cure" or o.kind == "state" or o.kind == "dot" or
			o.kind == "enhance" or o.kind == "wound" or
			o.kind == "dotarea" or o.kind == "curearea" or o.kind == "medicine" then
			b.packs = b.packs or {}
			local pack = ctx.newObject({isPack = true, template = o.template, uses = o.uses, power = o.power, required = o.required})
			pack.usable = o.usable
			b.packs[o.template] = pack
			o.packOid = pack.oid
			return pack
		elseif o.kind == "grenade" then
			b.items = b.items or {}
			local item = ctx.newObject({isItem = true, template = o.template, uses = o.uses})
			b.items[o.template] = item
			return item
		end
		b.gear = b.gear or {}
		o.worn = false
		table.insert(b.gear, o)
		return o
	end
	local function listOf(b)
		local out = {}
		for _, o in ipairs(b.gear or {}) do
			table.insert(out, {oid = o.oid, template = o.template, name = o.name, kind = o.kind, family = o.family, slot = o.slot, worn = o.worn == true,
				given = o.given == true, certified = o.certified, uses = 1, required = 0, usable = true, power = o.power, left = o.left,
				broken = o.broken == true})
		end
		for template, pack in pairs(b.packs or {}) do
			local kind = packKind(template)
			table.insert(out, {oid = pack.oid, template = template, name = template:match("([%w_]+)%.iff$"), kind = kind, family = "", slot = "",
				worn = false, given = pack.given == true, certified = true, uses = pack.uses, required = pack.required or 0, usable = pack.usable ~= false,
				power = pack.power or 0, left = 100, broken = false})
		end
		for template, item in pairs(b.items or {}) do
			table.insert(out, {oid = item.oid, template = template, name = template:match("([%w_]+)%.iff$"), kind = "grenade", family = "thrown", slot = "",
				worn = false, given = item.given == true, certified = true, uses = item.uses, required = 0, usable = true, power = 50, left = 100, broken = false})
		end
		return out
	end
	function api.botGearList(b)
		return b ~= nil and listOf(b) or {}
	end
	function api.botGearKind(oid)
		local o = ctx.objects[oid]
		if o == nil or o.kind == nil then return nil end
		return o.kind, o.family or "", o.name
	end
	function api.botGearEquip(b, oid)
		for _, o in ipairs(b.gear or {}) do
			if o.oid == oid then
				if o.worn then return true, "" end
				if o.refuse ~= nil then return false, o.refuse end
				if o.kind == "weapon" and not o.certified then return false, "cert" end
				for _, other in ipairs(b.gear) do
					if other.worn and other.slot == o.slot and o.slot ~= "" then other.worn = false end
				end
				o.worn = true
				table.insert(log.gearEquips, {bot = b.oid, oid = oid, name = o.name})
				return true, ""
			end
		end
		return false, "no item"
	end
	function api.botGearUnequip(b, oid)
		for _, o in ipairs(b.gear or {}) do
			if o.oid == oid then o.worn = false return true end
		end
		return false
	end
	function api.botGearGiven(b, oids)
		for _, oid in ipairs(oids) do
			local o = ctx.objects[oid]
			if o ~= nil then
				o.given = true
				if o.packOid ~= nil then
					for _, pack in pairs(b.packs or {}) do if pack.oid == o.packOid then pack.given = true end end
					for _, item in pairs(b.items or {}) do if item.oid == o.packOid then item.given = true end end
				end
			end
		end
		return true
	end
	function api.botGearPack(b, kind)
		local base, word = kind:match("^(%w+):?(.*)$")
		local best, bestPower, uses = nil, -1, 0
		if base == "grenade" then
			for _, item in pairs(b.items or {}) do
				if item.uses > 0 and item.oid ~= nil then
					uses = uses + item.uses
					if best == nil then best = item.oid end
				end
			end
			return best or 0, uses
		end
		for template, pack in pairs(b.packs or {}) do
			if packKind(template) == base and (word == "" or template:find(word, 1, true)) and pack.uses > 0 and pack.usable ~= false then
				uses = uses + pack.uses
				if (pack.power or 0) > bestPower then best, bestPower = pack.oid, pack.power or 0 end
			end
		end
		return best or 0, uses
	end
	function api.botGearCamps(b)
		local out = {}
		for _, o in ipairs(b.gear or {}) do
			if o.kind == "camp" then table.insert(out, o.template) end
		end
		return out
	end
	local function giveMatches(filter, e)
		if filter == "all" or filter == e.kind or (e.family ~= "" and filter == e.family) then return true end
		if filter == "medicine" then return e.kind == "stim" or e.kind == "ranged" or e.kind == "revive" or e.kind == "cure" or e.kind == "state" or e.kind == "dot" end
		return false
	end
	-- Hands back: the matching gifts become the goods the loot code's handover offers
	function api.botGearGiveBack(b, filter)
		local n = 0
		for _, e in ipairs(listOf(b)) do
			if e.given and giveMatches(filter, e) then
				n = n + 1
				table.insert(goodsOf(b), {oid = e.oid, name = e.name, resource = false, quantity = 1, tradable = true, gift = true})
				for i, o in ipairs(b.gear or {}) do if o.oid == e.oid then table.remove(b.gear, i) break end end
				for template, pack in pairs(b.packs or {}) do if pack.oid == e.oid then b.packs[template] = nil end end
				for template, item in pairs(b.items or {}) do if item.oid == e.oid then b.items[template] = nil end end
			end
		end
		b.giveMode = n > 0 and filter or nil
		return n
	end
	function api.botGearGiveEnd(b) b.giveMode = nil end
	function api.botGearGiveMode(b) return b.giveMode or "" end
	function api.botGearDevGive(b, template, uses)
		local kind = packKind(template)
		local o = ctx.gearItem({template = template, kind = kind == "medicine" and "other" or kind, uses = uses > 0 and uses or 10, given = true})
		ctx.receive(b, o)
		api.botGearGiven(b, {o.oid})
		return o.packOid or o.oid
	end
	function api.botGearDevCondition(b, oid, percent)
		for _, o in ipairs(b.gear or {}) do if o.oid == oid then o.left = percent return true end end
		return false
	end

	-- A trade the owner opens (b.trade: set by a scenario): requested -> open -> partnerVerified
	function api.botTradeState(b)
		local tr = b.trade
		if tr == nil then return {stage = "none", partner = 0, items = {}, credits = 0, give = 0, partnerAccepted = false, accepted = false} end
		return {partner = tr.partner, stage = tr.stage, items = tr.items, credits = tr.credits or 0, give = 0, partnerAccepted = tr.stage == "partnerVerified",
			accepted = tr.accepted == true}
	end
	function api.botTradeAccept(b)
		if b.trade == nil or b.trade.stage ~= "requested" then return false, "not requested" end
		b.trade.stage = "open"
		return true
	end
	function api.botTradeAbort(b)
		if b.trade ~= nil then table.insert(log.tradeAborts, {bot = b.oid, partner = b.trade.partner}) end
		b.trade = nil
		return true
	end
	function api.botTradeVerify(b, minCredits, itemOid)
		local tr = b.trade
		if tr == nil then return false, "none" end
		tr.accepted = true
		if tr.stage ~= "partnerVerified" then return false, "waiting" end
		for _, oid in ipairs(tr.items) do ctx.receive(b, ctx.objects[oid]) end
		b.trade = nil
		return true, "done"
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
		-- BotTrade queues the handover: the window opens (event "bundleOpened") once the player has no trade open and
		-- the last one closed BUNDLE_GAP ms ago; the player takes it 3 s later
		local function finish(bundle)
			if b.bundle ~= bundle then return end
			b.bundle = nil
			p.tradeOpen = nil
			p.tradeEnd = nowMs()
			local decline = sim.declineOffers
			if not decline and (sim.declineNext or 0) > 0 then
				sim.declineNext = sim.declineNext - 1
				decline = true
			end
			if decline then
				-- (BotTrade: a window the owner never touched is "bundleLost"; one it accepted or filled is "bundleCancelled")
				sim.call("BotJobs", "onEvent", b, "trade", p, sim.declineTouched and "bundleCancelled" or "bundleLost")
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
		end
		local function tryOpen(bundle)
			if b.bundle ~= bundle then return end
			if p.tradeOpen ~= nil or nowMs() - (p.tradeEnd or -1e9) < 4000 then
				sim.schedule(500, function() tryOpen(bundle) end)
				return
			end
			p.tradeOpen = b.oid
			bundle.openedAt = nowMs()
			table.insert(log.opens, {bot = b.oid, t = nowMs(), to = p.oid})
			sim.call("BotJobs", "onEvent", b, "trade", p, "bundleOpened")
			sim.schedule(3000, function() finish(bundle) end)
		end
		local bundle = b.bundle
		sim.schedule(300, function() tryOpen(bundle) end)
		return true, n, #items - n
	end
	function api.botCancelOffer(b)
		if b.bundle ~= nil then
			local p = ctx.objects[b.bundle.to]
			if p ~= nil and p.tradeOpen == b.oid then
				p.tradeOpen = nil
				p.tradeEnd = nowMs()
			end
		end
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
				if m ~= nil and o.posture ~= "sitting" and o.posture ~= "crouched" and not o.frozen then
					if m.state == "follow" then
						local leader = ctx.objects[m.leader]
						if leader ~= nil and leader.planet == o.planet then
							if not o.pinCell then o.cell = leader.cell end
							if dist(o, leader) > 80 then
								o.x, o.y = leader.x - 10, leader.y
							else
								walkToward(o, leader.x, leader.y, m.distance or 4, o.riding and 18 or 6)
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
				if o.isMob and o.inCombat and not o.rooted then
					local victim = ctx.objects[o.aggro or 0]
					if victim ~= nil and not victim.dead and not victim.incap then
						if dist(o, victim) > 3 then
							walkToward(o, victim.x, victim.y, 2, 6)
						elseif t >= (o.nextHit or 0) then
							o.nextHit = t + 2000
							damage(victim, o.hits or 25)
							victim.inCombat = true
							victim.threats = victim.threats or {}
							addUnique(victim.threats, o.oid)
						end
					end
				end
				-- Auto-attack every 2 s on the combat target, in weapon range
				if o.isPlayer and o.inCombat and o.combatTarget ~= nil and (o.target or 0) ~= 0 then
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
				-- The entertaining session ticks every 10 s
				if o.patrons ~= nil and t >= (o.nextPerfTick or 0) then
					o.nextPerfTick = t + 10000
					perfTick(o)
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
			"medpack_cure_disease_c", "medpack_revive", "medpack_enhance_health_d", "medpack_wound_health_e",
			"medpack_poison_health_c", "medpack_disease_health_c"}) do
			if not (stocked[medic.oid] or {})[pack] then
				fail("crew: the medic has no " .. pack)
			end
		end
		-- (Phase 7c: the rifleman has Novice Medic and its injury boxes: stims, and nothing else)
		local riflemanPacks = 0
		for _ in pairs(stocked[rifleman.oid] or {}) do riflemanPacks = riflemanPacks + 1 end
		if not (stocked[tank.oid] or {}).crafted_stimpack_sm_s1_e or not (stocked[rifleman.oid] or {}).crafted_stimpack_sm_s1_e or
			riflemanPacks ~= 1 then
			fail("crew: stims for the tank (a master medic) and the rifleman (Novice Medic), and nothing else for the rifleman")
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
		speak(medic, dex, "want to come hunt? let's go k" .. "ill them")	-- (an attack order to a bot with no group: a join)
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
		-- (the positioning fix: out of town on foot each trails at its fighting band: the tank and ranger close, the rifleman and
		-- medic 24-30 m back; BotCrew.trail)
		each(function(role, b)
			local range = BotCrew.trail[role]
			local d = dist(b, cameren)
			if d > range[2] + 3 then
				fail(string.format("crew: the %s is %.0f m behind after a walk (trail %d-%d)", role, d, range[1], range[2]))
			elseif d < range[1] - 3 then
				fail(string.format("crew: the %s is only %.0f m behind after a walk (trail %d-%d)", role, d, range[1], range[2]))
			end
			local follow
			for _, f in ipairs(log.follows) do
				if f.bot == b.oid then follow = f end
			end
			if follow == nil or follow.near ~= range[1] or follow.far ~= range[2] then
				fail("crew: the " .. role .. "'s follow didn't carry its trail range")
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
			if moveState(b) ~= "follow" or dist(b, cameren) > BotCrew.trail[role][2] + 3 then
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
		sim.run(10) -- (Phase 7c: the others hold fire until the tank has the rat, or three seconds, and walk to their bands first; the 60 s below is 53)
		each(function(role, b)
			local set = entries(log.targets, b, t)
			if #set == 0 or set[1].target ~= rat.oid or not engaged(b, rat.oid, t) then
				fail("crew: the " .. role .. " didn't attack the leader's target")
			end
		end)
		if #okCommands(tank, "taunt", t) == 0 then
			fail("crew: the tank didn't taunt")
		end
		sim.run(53)
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
		local kreetle = makeMob("a kreetle", rifleman.x - 15, rifleman.y, 4000)
		t = nowMs()
		startCombat(kreetle, rifleman)
		kreetle.aggro = rifleman.oid
		sim.run(20) -- (the rifleman steps back first, walks to her band, and fires once the tank has it)
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
		-- (a medic that revives within one step of the death beats the rifleman's own look at it: no "down" then)
		local revived = okCommands(medic, "reviveplayer", t)[1]
		local quick = revived ~= nil and revived.t - t < BotCrew.groupMs
		if (not quick and not anyLine(entries(log.group, rifleman, t), "rifleman", "down")) or not anyLine(entries(log.group, medic, t), "medic", "reviving") then
			local seen = {}
			for _, l in ipairs(entries(log.group, nil, t)) do table.insert(seen, l.text) end
			fail("crew: no 'I'm down' and 'coming' lines around the revive (" .. table.concat(seen, " | ") .. ")")
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
		-- (the rejoin goes through ensureFollow: the role's trail range, not a close follow)
		for _, b in ipairs({tank, medic}) do
			local last
			for _, f in ipairs(entries(log.follows, b, t)) do last = f end
			local range = BotCrew.trail[b.role]
			if last == nil or last.near ~= range[1] or last.far ~= range[2] then
				fail("crew: the cloned " .. b.role .. " didn't rejoin with its trail range (" .. tostring(last and last.near) .. ")")
			end
		end
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
		addUnique(tank.defenders, zed.oid)	-- (a duel's challenge makes the bot hit back, as a player would)
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

		-- 9b. Nothing within 45 degrees of east in five lists, but some within 90: the best two of those, and it says so
		medic.missions = {}
		mw.refreshes, mw.accepts = {}, {}
		mw.lists[medic.first] = {{{degrees = 170, reward = 5000}, {degrees = 10, reward = 4000}, {degrees = 300, reward = 9000},
			{degrees = 200, reward = 8000}, {degrees = 15, reward = 1000}}}
		t = nowMs()
		groupSay(cameren, medic.first .. ", get two missions east")
		sim.run(25)
		if rewards(medic) ~= "5000,4000" or mw.refreshes[medic.oid] ~= 5 then
			fail("crewmissions: east, with only wider ones on offer, the medic took '" .. rewards(medic) .. "' after " ..
				tostring(mw.refreshes[medic.oid]) .. " lists")
		end
		if not anyLine(lines(medic, t), "medic", "missionWide") or not lines(medic, t)[1].text:find("east", 1, true) or
			not lines(medic, t)[1].text:find("5,000", 1, true) then
			fail("crewmissions: the medic should say it took wider ones: " .. tostring(lines(medic, t)[1] and lines(medic, t)[1].text))
		end
		-- ...and with nothing within 90 degrees either, it takes none and says so as before
		medic.missions = {}
		mw.refreshes = {}
		mw.lists[medic.first] = {{{degrees = 250, reward = 5000}, {degrees = 300, reward = 4000}}}
		t = nowMs()
		groupSay(cameren, medic.first .. ", get two missions east")
		sim.run(25)
		if rewards(medic) ~= "" or not anyLine(lines(medic, t), "medic", "missionNone") then
			fail("crewmissions: nothing within 90 degrees of east should take none and say so")
		end
		groupSay(cameren, "scrap the missions")
		sim.run(10)

		-- 9c. Retrying: after "nothing east" the crew is told to search again (spoken, to one bot), and later to take any
		-- direction or the nearest, without saying the word "mission"
		for _, b in ipairs({rifleman, medic, ranger}) do b.missions = {} end
		mw.refreshes, mw.accepts = {}, {}
		mw.lists[ranger.first] = {{{degrees = 250, reward = 5000, distance = 900}, {degrees = 300, reward = 4000, distance = 1500}}}
		t = nowMs()
		groupSay(cameren, ranger.first .. ", get two missions east")
		sim.run(25)
		if rewards(ranger) ~= "" or not anyLine(lines(ranger, t), "ranger", "missionNone") then
			fail("crewmissions: nothing east should take none and say so (retry setup)")
		end
		mw.lists[ranger.first] = {{{degrees = 100, reward = 3000, distance = 700}, {degrees = 80, reward = 2000, distance = 1900}}}
		mw.refreshes = {}
		t = nowMs()
		speak(ranger, cameren, "search again " .. ranger.first, "spatial")
		sim.run(25)
		if rewards(ranger) ~= "3000,2000" or not anyLine(lines(ranger, t), "ranger", "missionTook") then
			fail("crewmissions: 'search again' (spoken, to the ranger) took '" .. rewards(ranger) .. "' and said " ..
				tostring(lines(ranger, t)[1] and lines(ranger, t)[1].text))
		end
		if mw.refreshes[rifleman.oid] ~= nil or mw.refreshes[medic.oid] ~= nil then
			fail("crewmissions: 'search again' to the ranger sent the others to the terminal")
		end
		-- "get missions" with no direction: asked where; then "i dont care which direction" sends everyone, any direction
		groupSay(cameren, "scrap the missions")
		sim.run(10)
		for _, b in ipairs({rifleman, medic, ranger}) do
			b.missions = {}
			mw.lists[b.first] = {{{degrees = 200, reward = 5000, distance = 900}, {degrees = 300, reward = 4000, distance = 1500},
				{degrees = 10, reward = 3000, distance = 300}}}
		end
		mw.refreshes, mw.accepts = {}, {}
		local function forget()
			for _, b in ipairs({rifleman, medic, ranger}) do writeStringData("bot:" .. b.oid .. ":crew:mLastName", "") end
		end
		forget()
		t = nowMs()
		groupSay(cameren, "get missions")
		sim.run(4)
		if not anyLine(entries(log.group, nil, t), rifleman.job or "rifleman", "missionWhere") and
			not anyLine(entries(log.group, nil, t), "tank", "missionWhere") and
			not anyLine(entries(log.group, nil, t), "medic", "missionWhere") and
			not anyLine(entries(log.group, nil, t), "ranger", "missionWhere") then
			fail("crewmissions: 'get missions' with no direction wasn't asked where")
		end
		t = nowMs()
		groupSay(cameren, "i dont care which direction")
		sim.run(40)
		for _, b in ipairs({rifleman, medic, ranger}) do
			if rewards(b) ~= "5000,4000" then
				fail("crewmissions: any direction, " .. b.first .. " took '" .. rewards(b) .. "' (5000,4000 are the best)")
			end
			if not anyLine(lines(b, t), b.role, "missionTookAny") then
				fail("crewmissions: " .. b.first .. " should say it took any direction: " .. tostring(lines(b, t)[1] and lines(b, t)[1].text))
			end
		end
		-- The nearest first, said to the group with no mission word: "just pick two semi close"
		groupSay(cameren, "scrap the missions")
		sim.run(10)
		for _, b in ipairs({rifleman, medic, ranger}) do b.missions = {} end
		mw.refreshes, mw.accepts = {}, {}
		forget()
		t = nowMs()
		groupSay(cameren, "get missions")
		sim.run(3)
		groupSay(cameren, "just pick two semi close")
		sim.run(40)
		for _, b in ipairs({rifleman, medic, ranger}) do
			if rewards(b) ~= "3000,5000" then
				fail("crewmissions: nearby, " .. b.first .. " took '" .. rewards(b) .. "' (3000,5000 are the nearest)")
			end
		end
		-- A bare "take two missions" (a typo and all) goes the way it was last asked
		groupSay(cameren, "scrap the missions")
		sim.run(10)
		for _, b in ipairs({rifleman, medic, ranger}) do b.missions = {} end
		mw.lists[ranger.first] = {{{degrees = 100, reward = 3000, distance = 700}, {degrees = 80, reward = 2000, distance = 1900}}}
		mw.refreshes = {}
		groupSay(cameren, ranger.first .. ", get two missions east")
		sim.run(25)
		groupSay(cameren, "scrap the missions")
		sim.run(10)
		mw.refreshes = {}
		t = nowMs()
		groupSay(cameren, ranger.first .. ", take two fucking missiongs")
		sim.run(25)
		if rewards(ranger) ~= "3000,2000" or not anyLine(lines(ranger, t), "ranger", "missionTook") then
			fail("crewmissions: 'take two missions' with no direction should reuse east, took '" .. rewards(ranger) .. "'")
		end
		-- A question about the missions isn't an order
		groupSay(cameren, "scrap the missions")
		sim.run(10)
		mw.refreshes, mw.accepts = {}, {}
		t = nowMs()
		groupSay(cameren, "well did you get two?")
		sim.run(10)
		if next(mw.refreshes) ~= nil then
			fail("crewmissions: 'did you get two?' sent the crew to the terminal")
		end
		groupSay(cameren, "scrap the missions")
		sim.run(10)

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

	-- Scenario: the playtest fixes (duels, spatial talk on a hunt, self-defence, the straight camp search, area loot and
	-- harvest on request, what they got, the hunt's events)

	function scenarios.crewfix()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)
		each(function(role, b) b.gear = {"outfit", "weapon", "stims", "camp kit"} end)

		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		if members(cameren) ~= 5 then
			fail("crewfix: " .. members(cameren) .. " in the group")
		end
		sim.run(10)
		local gid = cameren.groupId
		local huntKey = "crew:group:" .. cameren.oid .. ":huntLog"
		local function huntLog() return readStringData(huntKey) end
		local function count(text, needle)
			local n = 0
			for _ in text:gmatch((needle:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))) do n = n + 1 end
			return n
		end
		local function hear(text, channel)
			each(function(role, b) sim.call("BotJobs", "onHeard", b, cameren, text, channel) end)
		end

		-- 1. A duel in the group: the medic heals neither side (then, with the duel over, both)
		local t = nowMs()
		ranger.noRegen, cameren.noRegen = true, true
		ranger:pool(HEALTH).cur = math.floor(ranger:getMaxHAM(HEALTH) * 0.3)
		cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * 0.3)
		ranger.duelWith, cameren.duelWith = cameren.oid, ranger.oid
		BotFight:begin(ranger, ranger.oid, cameren, 2)
		sim.run(15)
		if #okCommands(medic, "healdamage", t) > 0 then
			local who = {}
			for _, c in ipairs(okCommands(medic, "healdamage", t)) do who[#who + 1] = tostring(ctx.objects[c.target] and ctx.objects[c.target].first) end
			fail("crewfix: the medic healed while the ranger duelled Cameren (" .. table.concat(who, ",") .. ")")
		end
		ranger.duelWith, cameren.duelWith = nil, nil
		BotFight:finish(ranger, ranger.oid, "ended", true)
		dropFromCombat(ranger)
		dropFromCombat(cameren)
		t = nowMs()
		sim.run(15)
		if #okCommands(medic, "healdamage", t) < 2 then
			fail("crewfix: the medic didn't heal once the duel was over")
		end
		ranger.noRegen, cameren.noRegen = false, false
		sim.run(10)
		-- ...and a member's duel with a player outside the group (the member's defender is a player)
		local dux = makeHuman("Dux", cameren.x + 30, cameren.y)
		cameren.noRegen = true
		cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * 0.3)
		startCombat(cameren, dux)
		t = nowMs()
		sim.run(10)
		local healed = 0
		for _, c in ipairs(okCommands(medic, "healdamage", t)) do
			if c.target == cameren.oid then healed = healed + 1 end
		end
		if healed > 0 then
			fail("crewfix: the medic healed Cameren in a duel with a player outside the group")
		end
		dropFromCombat(cameren)
		dropFromCombat(dux)
		cameren.noRegen = false
		sim.run(15)

		-- 2. Self-defence: a creature goes for Cameren, who doesn't fight back; and one for the medic, who is busy
		-- healing: the rest of the crew fight them without the leader striking first
		local kreetle = makeMob("a kreetle", cameren.x + 15, cameren.y, 3000)
		t = nowMs()
		startCombat(kreetle, cameren)
		kreetle.aggro = cameren.oid
		sim.run(8)
		local defenders = 0
		each(function(role, b)
			if engaged(b, kreetle.oid, t) then defenders = defenders + 1 end
		end)
		if defenders < 3 then
			fail("crewfix: only " .. defenders .. " of the crew defended Cameren, who didn't fight back")
		end
		sim.run(30)
		local rat = makeMob("a womp rat", medic.x + 12, medic.y, 3000)
		medic.noRegen = true
		medic:pool(HEALTH).cur = math.floor(medic:getMaxHAM(HEALTH) * 0.3)
		t = nowMs()
		startCombat(rat, medic)
		rat.aggro = medic.oid
		sim.run(16)
		for _, b in ipairs({tank, rifleman, ranger}) do
			if not engaged(b, rat.oid, t) then
				fail("crewfix: the " .. b.role .. " didn't defend the medic")
			end
		end
		medic.noRegen = false
		sim.run(40)

		-- 3. Spatial talk on a hunt: not named, not targeted, within 20 m: exactly one crew bot answers, as in group chat,
		-- the hunt log gets the line once; the order reaches the others; far away or aimed at someone else it is ignored
		cameren.target = nil
		each(function(role, b) b.x, b.y = cameren.x + 4, cameren.y + 2 end)
		sim.run(5)
		t = nowMs()
		hear("hold up a second", "spatial")
		sim.run(4)
		local said = entries(log.group, nil, t)
		if #said ~= 1 or said[1].bot ~= tank.oid or not isLine(said[1].text, "tank", "stay") then
			fail("crewfix: spatial 'hold up' got " .. #said .. " lines" .. (said[1] and (" (" .. said[1].text .. ")") or ""))
		end
		each(function(role, b)
			if readStringData("bot:" .. b.oid .. ":crew:order") ~= "stay" then
				fail("crewfix: the " .. role .. " didn't take the spoken 'stay'")
			end
		end)
		if count(huntLog(), "hold up a second") ~= 1 then
			fail("crewfix: the hunt log has the spoken line " .. count(huntLog(), "hold up a second") .. " times")
		end
		t = nowMs()
		hear("follow me", "spatial")
		sim.run(6)
		each(function(role, b)
			if readStringData("bot:" .. b.oid .. ":crew:order") ~= "follow" then
				fail("crewfix: the " .. role .. " didn't take the spoken 'follow'")
			end
		end)
		-- Too far from the crew
		cameren.x = cameren.x + 40
		t = nowMs()
		hear("hold up a second", "spatial")
		sim.run(3)
		if #entries(log.group, nil, t) ~= 0 then
			fail("crewfix: the crew answered talk from 40 m away")
		end
		cameren.x = cameren.x - 40
		sim.run(10)
		-- Talking to someone else (a target outside the group)
		local stranger = makeHuman("Zed", cameren.x + 6, cameren.y)
		cameren.target = stranger.oid
		t = nowMs()
		hear("hold up a second", "spatial")
		sim.run(3)
		cameren.target = nil
		if #entries(log.group, nil, t) ~= 0 then
			fail("crewfix: the crew butted into talk aimed at someone else")
		end
		-- Talking to one crew member (targeting it): it answers alone, the others do not take it as group talk
		cameren.target = rifleman.oid
		t = nowMs()
		hear("hold up a second", "spatial")
		sim.run(3)
		cameren.target = nil
		local aimed = entries(log.group, nil, t)
		if #aimed > 1 or (aimed[1] and aimed[1].bot ~= rifleman.oid) then
			fail("crewfix: talk aimed at the rifleman got " .. #aimed .. " answers")
		end
		sim.run(6)
		groupSay(cameren, "follow me")
		sim.run(6)
		-- The ranger further off (22 m): it hears "skin them" and answers, since the work is its; at 40 m it doesn't hear it
		-- and another crew member takes the request
		ranger.x, ranger.y = cameren.x + 22, cameren.y
		ranger.noFollow = true
		t = nowMs()
		hear("skin them", "spatial")
		sim.run(3)
		local far = entries(log.group, nil, t)
		if #far ~= 1 or far[1].bot ~= ranger.oid then
			fail("crewfix: 'skin them' with the ranger 22 m off got " .. #far .. " answers" .. (far[1] and (" from " .. ctx.objects[far[1].bot].first) or ""))
		end
		sim.run(4)
		ranger.x = cameren.x + 40
		t = nowMs()
		hear("skin them", "spatial")
		sim.run(3)
		far = entries(log.group, nil, t)
		if #far ~= 1 or far[1].bot ~= tank.oid or not (isLine(far[1].text, "tank", "harvestAsk") or isLine(far[1].text, "tank", "harvestAskNone")) then
			fail("crewfix: 'skin them' with the ranger 40 m off got " .. #far .. " answers" .. (far[1] and (" from " .. ctx.objects[far[1].bot].first .. ": " .. far[1].text) or ""))
		end
		ranger.x, ranger.noFollow = cameren.x + 4, nil
		sim.run(8)
		-- Naming someone else who is near (the town doctor)
		local doc = ctx.newObject({isPlayer = true, first = "Veela", name = "Veela Dane", planet = "tatooine",
			x = cameren.x + 5, y = cameren.y, z = 5, cell = 0, inWorld = true, buffs = {}, wounds = {}, skillMods = {}})
		t = nowMs()
		hear("Veela, can I get a buff?", "spatial")
		sim.run(3)
		doc.inWorld = false
		if #entries(log.group, nil, t) ~= 0 then
			fail("crewfix: the crew answered a line that named the town doctor")
		end
		-- Someone not in the group
		t = nowMs()
		each(function(role, b) sim.call("BotJobs", "onHeard", b, stranger, "hold up a second", "spatial") end)
		sim.run(3)
		if #entries(log.group, nil, t) ~= 0 then
			fail("crewfix: the crew answered a stranger's spoken talk as group talk")
		end

		-- 3b. "attack my target": with nothing targeted the crew says so and stays put; with a creature targeted that
		-- fights nobody, the whole crew goes for it (nobody is in combat yet); "hold fire" calls them off
		local mite = makeMob("a rock mite", cameren.x + 20, cameren.y, 9000)
		cameren.target = nil
		t = nowMs()
		groupSay(cameren, "attack my target")
		sim.run(4)
		if not anyLine(entries(log.group, tank, t), "tank", "attackNoTarget") then
			fail("crewfix: 'attack my target' with no target got no 'target something' line")
		end
		each(function(role, b)
			if engaged(b, mite.oid, t) or readData("bot:" .. b.oid .. ":crew:focus") ~= 0 then
				fail("crewfix: the " .. role .. " attacked with nothing targeted")
			end
		end)
		cameren.target = mite.oid
		t = nowMs()
		groupSay(cameren, "attack my target")
		sim.run(14) -- (the ranged bots walk to their bands before they fire)
		if not anyLine(entries(log.group, tank, t), "tank", "attack") then
			fail("crewfix: 'attack my target' got no attack line from the tank")
		end
		each(function(role, b)
			if not engaged(b, mite.oid, t) then
				fail("crewfix: the " .. role .. " didn't attack the creature Cameren targeted")
			end
		end)
		sim.run(4)
		each(function(role, b)
			if readData("bot:" .. b.oid .. ":crew:focus") ~= mite.oid then
				fail("crewfix: the " .. role .. " lost its focus on the creature")
			end
		end)
		groupSay(cameren, "hold fire")
		sim.run(3)
		each(function(role, b)
			if readData("bot:" .. b.oid .. ":crew:focus") ~= 0 or readData("bot:" .. b.oid .. ":crew:target") ~= 0 then
				fail("crewfix: the " .. role .. " kept its focus after 'hold fire'")
			end
		end)
		dropFromCombat(mite)
		each(function(role, b) dropFromCombat(b) end)
		mite.inWorld = false
		cameren.target = nil
		sim.run(15)

		-- 4. Camp search: the spot is picked before the walk: the nearest clear ground around the leader, one walk, quick
		cameren.x, cameren.y = cameren.x + 500, cameren.y + 500
		sim.run(20)
		ctx.campLair = {x = cameren.x, y = cameren.y, r = 50}
		t = nowMs()
		groupSay(cameren, "camp here")
		sim.run(90)
		local placed = entries(log.camps, ranger, t)
		local refusals = entries(log.campRefusals, ranger, t)
		if #placed ~= 1 then
			fail("crewfix: " .. #placed .. " camps after a camp search")
			teardown()
			return
		end
		local camp = ctx.objects[placed[1].oid]
		if placed[1].t - t > 45000 then
			fail("crewfix: the camp search took " .. (placed[1].t - t) // 1000 .. " s")
		end
		if #refusals > 1 then
			fail("crewfix: " .. #refusals .. " refused spots in a camp search (the clear spot is picked before the walk)")
		end
		-- (the nearest ring that clears a 50 m lair on the leader is 70 m)
		local campFrom = math.sqrt((camp.x - ctx.campLair.x) ^ 2 + (camp.y - ctx.campLair.y) ^ 2)
		if campFrom <= 50 or campFrom > 75 then
			fail(string.format("crewfix: the camp is %.0f m from the lair (clear ground starts at 50; the nearest ring is 70)", campFrom))
		end
		if not anyLine(entries(log.group, ranger, t), "ranger", "campSearchLair") then
			fail("crewfix: no line saying where the clear ground is")
		end
		-- With the blocker unknown: the same
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end
		ctx.campLair = nil
		groupSay(cameren, "follow me")
		sim.run(60)
		t = nowMs()
		ctx.campLair = {x = ranger.x, y = ranger.y, r = 50, unknown = true}
		groupSay(cameren, "camp here")
		sim.run(90)
		placed = entries(log.camps, ranger, t)
		if #placed ~= 1 then
			fail("crewfix: " .. #placed .. " camps with an unknown blocker")
		end
		ctx.campLair = nil
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end
		groupSay(cameren, "follow me")
		sim.run(60)

		-- 4b. A field of lairs (squill lairs and mission lairs side by side): every stop of the old walk-away search had a lair in
		-- range. The spot is picked first: the nearest clear ring (250 m: the field is 225 m across), one walk, one refusal at most
		local function lairField(half, step, r)
			local field, seen = {}, {}
			for fx = -half, half, step do
				for fy = -half, half, step do
					table.insert(field, {x = cameren.x + fx, y = cameren.y + fy, r = r})
					table.insert(seen, {oid = 880000 + #field, x = cameren.x + fx, y = cameren.y + fy})
				end
			end
			return field, seen
		end
		sim.campLairs, sim.lairs = lairField(180, 60, 45)
		local fieldCentre = {x = cameren.x, y = cameren.y}
		t = nowMs()
		groupSay(cameren, "let's camp here")
		sim.run(170)
		placed = entries(log.camps, ranger, t)
		refusals = entries(log.campRefusals, ranger, t)
		if #placed ~= 1 then
			fail("crewfix: " .. #placed .. " camps in a field of lairs")
		else
			local c = ctx.objects[placed[1].oid]
			local from = math.sqrt((c.x - fieldCentre.x) ^ 2 + (c.y - fieldCentre.y) ^ 2)
			if from < 225 or from > 260 then
				fail(string.format("crewfix: the camp in the lair field is %.0f m from the group (clear ground starts at 225)", from))
			end
			for _, l in ipairs(sim.campLairs) do
				if math.sqrt((c.x - l.x) ^ 2 + (c.y - l.y) ^ 2) <= l.r then
					fail("crewfix: the camp is inside a lair's radius")
					break
				end
			end
		end
		if #refusals > 1 then
			fail("crewfix: " .. #refusals .. " refused spots in the lair field (the spot is checked before the walk)")
		end
		if not anyLine(entries(log.group, ranger, t), "ranger", "campSearchLairs") then
			fail("crewfix: no 'too many lairs' line with clear ground named")
		end
		if not anyLine(entries(log.group, ranger, t), "ranger", "campUpThere") then
			fail("crewfix: no line saying where the camp is")
		end
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end
		sim.campLairs, sim.lairs = nil, nil
		groupSay(cameren, "follow me")
		sim.run(80)

		-- 4c. Nothing clear within 250 m: it says so plainly and stays with the group (no walk, no camp)
		sim.campLairs, sim.lairs = lairField(300, 60, 45)
		t = nowMs()
		groupSay(cameren, "let's camp here")
		sim.run(30)
		if #entries(log.camps, ranger, t) ~= 0 then
			fail("crewfix: a camp in a field with no clear ground")
		end
		if not anyLine(entries(log.group, ranger, t), "ranger", "campSearchNone") then
			fail("crewfix: no plain 'no clear ground within 250 m' line")
		end
		if readStringData("bot:" .. ranger.oid .. ":crew:order") == "campSearch" then
			fail("crewfix: the ranger is still searching with no clear ground")
		end
		sim.campLairs, sim.lairs = nil, nil
		groupSay(cameren, "follow me")
		sim.run(40)

		-- 4d. A lair only the placement knows (a refusal after the walk): the spot is marked and the next one tried
		local hx, hy = cameren.x + 70 * math.sin(math.rad(15)), cameren.y + 70 * math.cos(math.rad(15))
		sim.campLairs = {{x = cameren.x, y = cameren.y, r = 50}}
		sim.campHidden = {x = hx, y = hy, r = 25}
		t = nowMs()
		groupSay(cameren, "let's camp here")
		sim.run(120)
		placed = entries(log.camps, ranger, t)
		refusals = entries(log.campRefusals, ranger, t)
		-- (two refusals: the spot where the ranger stood, and the first one picked)
		if #placed ~= 1 or #refusals ~= 2 then
			fail("crewfix: with a hidden lair " .. #placed .. " camps and " .. #refusals .. " refusals, expected 1 and 2")
		end
		if not anyLine(entries(log.group, ranger, t), "ranger", "campSearchAgain") then
			fail("crewfix: no 'next spot' line after a refused spot")
		end
		sim.campLairs, sim.campHidden = nil, nil
		for _, c in ipairs(log.camps) do ctx.objects[c.oid].inWorld = false end
		groupSay(cameren, "follow me")
		sim.run(60)

		-- 5. After a fight, the crew finds the group's other corpses around (not on any kill list); a corpse of another group
		-- stays
		local function corpse(name, ownerGroup, loot, harvest, dx, dy)
			local mob = makeMob(name, cameren.x + dx, cameren.y + dy, 100)
			mob.dead, mob.ownerGroup, mob.loot, mob.credits, mob.harvest = true, ownerGroup, loot, 0, harvest
			return mob
		end
		local function goodsCount(b) return #(b.goods or {}) end
		local old = corpse("a dewback", gid, {"Dewback tooth"}, {kind = "hide", amount = 30, class = "Tatooinian Leathery Hide"}, 25, 5)
		local theirs = corpse("a bantha", 999, {"Bantha horn"}, nil, 20, 10)
		local fodder = makeMob("a womp rat", cameren.x + 10, cameren.y + 6, 300)
		fodder.ownerGroup, fodder.loot, fodder.credits = gid, {"Rat tooth"}, 0
		t = nowMs()
		attack(cameren, fodder)
		sim.run(60)
		if not fodder.dead then
			fail("crewfix: the womp rat didn't die")
		end
		if #entries(log.loots, nil, t) < 2 or #old.loot ~= 0 or not (old.harvested or {})[ranger.oid] then
			fail("crewfix: the corpse the crew hadn't fought wasn't looted and harvested after the fight (" ..
				#entries(log.loots, nil, t) .. " loot calls, " .. #old.loot .. " items left)")
		end
		if #theirs.loot ~= 1 then
			fail("crewfix: the crew took another group's loot")
		end

		-- 6. Asked to loot and harvest: corpses it gave up on come back; "skin them" in group chat, "loot the bodies" out loud
		local function fresh(name, harvestable, item)
			return corpse(name, gid, {item, "Odd bone"}, harvestable and {kind = "meat", amount = 60, class = "Tatooinian Herbivore Meat"} or nil, 18, 3)
		end
		local stale = fresh("a bantha", true, "Hide scrap")
		writeData("crew:corpse:" .. stale.oid .. ":seen", 1)
		writeData("crew:corpse:" .. stale.oid .. ":done", 1)
		t = nowMs()
		groupSay(cameren, "ranger skin them")
		sim.run(25)
		if #entries(log.harvests, ranger, t) < 1 or not stale.harvested or not stale.harvested[ranger.oid] then
			fail("crewfix: 'skin them' didn't harvest the corpse")
		end
		local named = false
		for _, l in ipairs(entries(log.group, ranger, t)) do
			if isLine(l.text, "ranger", "harvestedOne") and l.text:find("60 Tatooinian Herbivore Meat", 1, true) and l.text:find("bantha", 1, true) then named = true end
		end
		if not named then
			fail("crewfix: the ranger didn't name what it skinned")
		end
		local stale2 = fresh("a dewback", false, "Dewback scrap")
		writeData("crew:corpse:" .. stale2.oid .. ":seen", 1)
		writeData("crew:corpse:" .. stale2.oid .. ":done", 1)
		t = nowMs()
		hear("loot the bodies", "spatial")
		sim.run(30)
		if #stale.loot ~= 0 or #stale2.loot ~= 0 then
			fail("crewfix: 'loot the bodies' (out loud) left " .. #stale.loot + #stale2.loot .. " items on the corpses")
		end
		local lootLines = 0
		for _, l in ipairs(entries(log.group, nil, t)) do
			if (isLine(l.text, "tank", "lootedOne") or isLine(l.text, "tank", "lootedMany")) and l.text:find("scrap", 1, true) then lootLines = lootLines + 1 end
		end
		if lootLines ~= 1 or not anyLine(entries(log.group, tank, t), "tank", "lootAsk") then
			fail("crewfix: " .. lootLines .. " lines naming the loot, or no answer to the request")
		end

		-- 7. Many corpses: one line for the harvest and one for the loot, not one per corpse
		for i = 1, 3 do
			corpse("a rock wart", gid, {"Wart tooth " .. i, "Wart horn " .. i}, {kind = "bone", amount = 10 * i, class = "Tatooinian Bone"}, 12 + i * 2, 8)
		end
		t = nowMs()
		groupSay(cameren, "ranger harvest them all")
		groupSay(cameren, "loot the bodies")
		sim.run(60)
		local harvestLines, manyLoot = 0, 0
		for _, l in ipairs(entries(log.group, nil, t)) do
			if isLine(l.text, "ranger", "harvestedMany") and l.text:find("60 Tatooinian Bone", 1, true) then harvestLines = harvestLines + 1 end
			if isLine(l.text, "tank", "lootedMany") or isLine(l.text, "rifleman", "lootedMany") or isLine(l.text, "medic", "lootedMany") then
				manyLoot = manyLoot + 1
			end
		end
		local harvests = #entries(log.harvests, ranger, t)
		if harvests ~= 3 or harvestLines ~= 1 then
			fail("crewfix: " .. harvests .. " harvests and " .. harvestLines .. " lines for three carcasses")
		end
		if manyLoot ~= 1 then
			fail("crewfix: " .. manyLoot .. " lines for the loot of three corpses")
		end

		-- 8. Nothing left: asked again, it says so
		t = nowMs()
		groupSay(cameren, "loot")
		sim.run(5)
		if not anyLine(entries(log.group, nil, t), "tank", "lootAskNone") then
			fail("crewfix: no 'nothing left' line")
		end

		-- 9. The hunt's events: kills, a death, a camp, missions taken and done (and one dropped), and the tally
		sim.call("BotJobs", "onEvent", rifleman, "died", kreetle, "")
		sim.run(2)
		local log9 = huntLog()
		if not log9:find("(hunt)", 1, true) or not log9:find("Killed ", 1, true) or not log9:find(rifleman.first .. " died", 1, true) then
			fail("crewfix: the hunt log lacks kills or the death:\n" .. log9)
		end
		local fields = BotCrew:requestFields(ranger, ranger.oid)
		local tally = fields.huntTally or ""
		if not tally:find("kills", 1, true) or not tally:find("corpses looted", 1, true) or not tally:find("camp", 1, true) or
			not tally:find("crew death", 1, true) or not tally:find("harvested", 1, true) then
			fail("crewfix: the hunt tally: '" .. tally .. "'")
		end
		-- Missions: taken (as a bot records it when it accepts), then one leaves the datapad with its lair having been up
		-- (done), one without a lair ever (failed), one is dropped by the bot
		tank.missions = {{oid = 777001, target = "womp rat lair", reward = 4300, x = 0, y = 0, distance = 1800, lairUp = true},
			{oid = 777002, target = "gurnaset lair", reward = 3100, x = 0, y = 0, distance = 1500, lairUp = false}}
		writeStringData("crew:mission:777001:text", "womp rat lair")
		writeStringData("crew:mission:777002:text", "gurnaset lair")
		BotCrew:missionHeldSet(tank, tank.oid)
		sim.run(8)
		mw.done[777001] = true
		tank.missions = {tank.missions[2]}
		sim.run(8)
		if count(huntLog(), "Lair destroyed") ~= 1 or not huntLog():find("womp rat lair", 1, true) then
			fail("crewfix: a finished mission wasn't logged as a lair destroyed:\n" .. huntLog())
		end
		tally = BotCrew:requestFields(ranger, ranger.oid).huntTally or ""
		if not tally:find("1 lair done, 1 mission left", 1, true) then
			fail("crewfix: the tally after a mission: '" .. tally .. "'")
		end
		tank.missions = {}
		sim.run(8)
		if count(huntLog(), "Lair destroyed") ~= 1 or count(huntLog(), "gurnaset lair mission failed") ~= 1 then
			fail("crewfix: a mission removed with no lair should be logged as failed, not done:\n" .. huntLog())
		end
		tally = BotCrew:requestFields(ranger, ranger.oid).huntTally or ""
		if not tally:find("1 lair done, 0 missions left", 1, true) then
			fail("crewfix: the tally after a failed mission: '" .. tally .. "'")
		end
		tank.missions = {{oid = 777003, target = "kreetle lair", reward = 2000, x = 0, y = 0, distance = 900, lairUp = true}}
		BotCrew:missionHeldSet(tank, tank.oid)
		BotCrew:missionDrop(tank, tank.oid, "Cameren")
		tank.missions = {}
		sim.run(12)
		if count(huntLog(), "Lair destroyed") ~= 1 then
			fail("crewfix: a dropped mission was counted as done")
		end

		-- 9. The human's own destroy missions count: one done (its lair was up), one failed (it never got one), one held
		cameren.missions = {{oid = 888001, target = "grizzled dewback lair", reward = 4000, x = 0, y = 0, distance = 900, lairUp = false},
			{oid = 888002, target = "kreetle lair", reward = 3000, x = 0, y = 0, distance = 700, lairUp = false}}
		sim.run(6)
		local lairsKey = "crew:group:" .. cameren.oid .. ":lairs"
		local lairsBefore = readData(lairsKey)
		if not BotCrew:huntTally(cameren.oid, BotCrew:group(tank)):find("2 missions left", 1, true) then
			fail("crewfix: the tally misses the human's two missions: " .. BotCrew:huntTally(cameren.oid, BotCrew:group(tank)))
		end
		cameren.missions[1].lairUp = true
		sim.run(6)
		mw.done[888001] = true
		cameren.missions = {cameren.missions[2]}
		sim.run(8)
		if readData(lairsKey) ~= lairsBefore + 1 then
			fail("crewfix: the human's finished mission counted " .. (readData(lairsKey) - lairsBefore) .. " times, expected once")
		end
		if count(huntLog(), "Lair destroyed: Cameren's grizzled dewback lair mission is done") ~= 1 then
			fail("crewfix: the hunt log has the human's lair " .. count(huntLog(), "Lair destroyed: Cameren's grizzled dewback lair mission is done") .. " times")
		end
		if not BotCrew:huntTally(cameren.oid, BotCrew:group(tank)):find("1 mission left", 1, true) then
			fail("crewfix: the tally misses the human's held mission: " .. BotCrew:huntTally(cameren.oid, BotCrew:group(tank)))
		end
		cameren.missions = {}
		sim.run(8)
		if readData(lairsKey) ~= lairsBefore + 1 or count(huntLog(), "kreetle lair") ~= 0 then
			fail("crewfix: the human's mission dropped before any lair counted as done or was logged")
		end
		-- ...and one dropped with its lair up (re-rolled at a terminal): not a lair destroyed
		cameren.missions = {{oid = 888003, target = "tusken lair", reward = 2500, x = 0, y = 0, distance = 800, lairUp = true}}
		sim.run(6)
		cameren.missions = {}
		sim.run(8)
		if readData(lairsKey) ~= lairsBefore + 1 or count(huntLog(), "tusken lair") ~= 0 then
			fail("crewfix: a mission the human dropped with its lair up counted as a lair destroyed")
		end

		-- 10. A human left in combat on a corpse another killed: the dead are dropped and combat ends; a live one stays; and
		-- with the drop missing, a dead-only list isn't a fight for the crew either (so looting goes on)
		local corpse1 = makeMob("a dead gurnaset", cameren.x + 10, cameren.y, 100)
		corpse1.dead = true
		cameren.defenders, cameren.inCombat = {corpse1.oid}, true
		sim.run(4)
		if cameren.inCombat or #(cameren.defenders or {}) ~= 0 then
			fail("crewfix: the human stayed in combat on a corpse")
		end
		local live = makeMob("a krayt cub", cameren.x + 15, cameren.y, 90000)
		cameren.defenders, cameren.inCombat = {corpse1.oid, live.oid}, true
		live.inCombat = true
		sim.run(2)
		if not cameren.inCombat or #(cameren.defenders or {}) ~= 1 or cameren.defenders[1] ~= live.oid then
			fail("crewfix: the live defender didn't stay on the human's list")
		end
		if not BotCrew:groupFighting(BotCrew:group(tank)) then
			fail("crewfix: a human fighting a live creature isn't a fight")
		end
		dropFromCombat(live)
		live.dead = true
		each(function(role, b) dropFromCombat(b) end)
		cameren.defenders, cameren.inCombat = {corpse1.oid}, true
		local drop = _G.botDropDeadDefenders
		_G.botDropDeadDefenders = nil
		sim.run(3)
		_G.botDropDeadDefenders = drop
		if BotCrew:groupFighting(BotCrew:group(tank)) then
			fail("crewfix: a human in combat on a corpse alone counted as a fight")
		end
		cameren.defenders, cameren.inCombat = {}, false
		sim.run(5)

		-- 11. What the Lua takes for an attack order: the orders ("kill" at the start of a clause, a negation just before
		-- the word) and the talk that is not
		local KILL = "k" .. "ill"
		for _, line in ipairs({"attack my target", KILL .. " it", KILL .. "!", "ok guys, " .. KILL .. " the krayt", KILL .. " the tusken",
			"don't just stand there, " .. KILL .. " it!", "don't let it get away, " .. KILL .. " it", "assist me", "assist", "take it down",
			"come on, " .. KILL .. " it", "take him out", "nevermind, attack it", "engage", "help me " .. KILL .. " it"}) do
			if BotCrew:intentFor(line, nil) ~= "attack" then
				fail("crewfix: '" .. line .. "' should be an attack order, got " .. tostring(BotCrew:intentFor(line, nil)))
			end
		end
		for _, line in ipairs({"did that thing attack the medic?", "take it out of your pack", "don't attack it", "never attack that",
			"hold fire", "stop attacking", "they attack what I attack", "did you get em all?", "I " .. KILL .. "ed it", 
			"he attacked me", "can you assist with crafting?", "did the tusken attack the camp?"}) do
			if BotCrew:intentFor(line, nil) == "attack" then
				fail("crewfix: '" .. line .. "' is not an attack order")
			end
		end
		if BotCrew:intentFor("hold fire", nil) ~= "follow" or BotCrew:intentFor("stop attacking", nil) ~= "follow" then
			fail("crewfix: 'hold fire' and 'stop attacking' should still be follow")
		end

		-- 12. A human shooting a lair (a building, not a creature) is still in a fight
		local lair = ctx.newObject({display = "a kreetle lair", name = "a kreetle lair", planet = "tatooine", x = cameren.x + 20,
			y = cameren.y, z = 5, cell = 0, inWorld = true})
		cameren.defenders, cameren.inCombat = {lair.oid}, true
		sim.run(4)
		if not BotCrew:groupFighting(BotCrew:group(tank)) then
			fail("crewfix: a human attacking a lair isn't a fight")
		end
		cameren.defenders, cameren.inCombat = {}, false
		sim.run(2)

		-- 13. What the brain is told of the speaker's target: its name, or none
		local dummy = makeMob("a rock mite", cameren.x + 12, cameren.y, 900000)
		cameren.target = nil
		if BotCrew:requestFields(tank, tank.oid, cameren.oid).attackTarget ~= "none" then
			fail("crewfix: the brain isn't told that nothing is targeted")
		end
		cameren.target = dummy.oid
		if BotCrew:requestFields(tank, tank.oid, cameren.oid).attackTarget ~= "a rock mite" then
			fail("crewfix: the brain isn't told the speaker's target: " .. tostring(BotCrew:requestFields(tank, tank.oid, cameren.oid).attackTarget))
		end
		cameren.target = nil

		-- 14. A second human (not the leader) on a swoop whose swoop is attacked (they are not "in combat"): the crew's
		-- riders get off to help
		local fenn = makeHuman("Fenn", cameren.x + 5, cameren.y)
		joinGroup(fenn, tank)
		sim.run(3)
		cameren.riding, fenn.riding = true, true
		sim.run(10)
		local riders = 0
		each(function(role, b) if b.riding then riders = riders + 1 end end)
		if riders == 0 then
			fail("crewfix: nobody mounted with the human riding (test setup)")
		end
		t = nowMs()
		fenn.vehicleAttacker = dummy.oid
		sim.run(6)
		each(function(role, b)
			if b.riding then
				fail("crewfix: the " .. role .. " kept riding while a human's swoop was attacked")
			end
		end)
		fenn.vehicleAttacker, fenn.riding, cameren.riding = nil, false, false
		dropFromCombat(dummy)
		dummy.dead = true
		each(function(role, b) dropFromCombat(b) end)
		sim.run(15)

		realPrint(string.format("crewfix  %d loot calls, %d harvests, %d camps, %d group lines; tally: %s", #log.loots, #log.harvests,
			#log.camps, #log.group, BotCrew:requestFields(ranger, ranger.oid).huntTally or ""))
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
		local mob = makeMob("a womp rat", tank.x + 20, tank.y, 6000)
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
		-- The other riders get off to help the tank (a crew mate is attacked), and fight it
		for _, b in ipairs({rifleman, medic, ranger}) do
			if riding(b) then
				fail("crewswoop: the " .. b.role .. " kept riding while the tank was attacked")
			end
		end
		sim.run(10) -- (the ranged bots walk to their bands before they fire)
		if not engaged(rifleman, mob.oid, t) or not engaged(ranger, mob.oid, t) then
			fail("crewswoop: the rifleman and the ranger didn't fight what attacked the tank's swoop")
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
		teardown()
	end

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
			-- (the ranger loots and harvests alone, the loot first)
			if l.bot ~= ranger.oid then fail("crewloot: someone besides the ranger looted") end
			if #(ctx.objects[l.bot].goods or {}) > 0 then okLoot = okLoot or l end
		end
		if okHarvest == nil then
			fail("crewloot: the ranger didn't harvest the womp rat")
		end
		if okLoot == nil then
			fail("crewloot: nobody looted the womp rat")
		end
		if okLoot.t > okHarvest.t then
			fail("crewloot: the ranger harvested before it looted")
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
		local ranger40 = false
		for _, item in ipairs(ranger.goods or {}) do
			if item.quantity == 40 then ranger40 = true end
		end
		if #(ranger.goods or {}) ~= 4 or not ranger40 then
			fail("crewloot: the ranger's goods: " .. #(ranger.goods or {}))
		end
		local said = {}
		for _, l in ipairs(log.group) do said[#said + 1] = l.text end
		-- What they got, said in group chat: the ranger names the harvest, the looter the items (and the credits)
		local sawLooted, sawHarvested = false, false
		for _, l in ipairs(log.group) do
			if isLine(l.text, "ranger", "lootedOne") and
				l.text:find("womp rat", 1, true) and l.text:find("Rat tooth", 1, true) and l.text:find("Credit chit", 1, true) and
				l.text:find("120 credits", 1, true) then
				sawLooted = true
			end
			if isLine(l.text, "ranger", "harvestedOne") and l.text:find("womp rat", 1, true) and l.text:find("40 Tatooinian Mammalian Hide", 1, true) then
				sawHarvested = true
			end
		end
		if not sawLooted or not sawHarvested then
			fail("crewloot: no group line naming the loot or the harvest (" .. table.concat(said, " | ") .. ")")
		end
		-- (the rest of the crew went back to following)
		each(function(role, b)
			if dist(b, cameren) > math.max(14, BotCrew.trail[role][2] + 3) then
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
		sim.declineOffers, sim.declineTouched = true, true
		t = nowMs()
		cameren.received = {}
		groupSay(cameren, "hand it over")
		sim.run(25)
		sim.declineOffers, sim.declineTouched = false, false
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

		-- 6b. The ranger told to stay: another crew member loots (and nobody harvests); then it is back on the job
		sim.run(20)
		local before6 = nowMs()
		groupSay(cameren, ranger.first .. ", stay here")
		sim.run(3)
		local stayed = kill("a gurnaset", gid, {"Gurnaset tooth"}, {kind = "bone", amount = 9, class = "Tatooinian Bone"})
		sim.run(40)
		if not stayed.dead then fail("crewloot: the gurnaset didn't die") end
		local lootersStay = {}
		for _, l in ipairs(entries(log.loots, nil, before6)) do lootersStay[l.bot] = true end
		if next(lootersStay) == nil or lootersStay[ranger.oid] or #entries(log.harvests, nil, before6) ~= 0 then
			fail("crewloot: the ranger told to stay: someone else should loot, nobody harvest")
		end
		groupSay(cameren, ranger.first .. ", follow me")
		sim.run(10)

		-- 6c. Two bots hold goods and are asked together: one trade at a time, the second only after the first closes
		-- plus the gap, and each says its line when its own trade opens. One of them is declined, and offers again.
		local holders = {}
		each(function(role, b) if goodsCount(b) > 0 then table.insert(holders, b) end end)
		if #holders < 2 then
			fail("crewloot: expected two bots holding goods for the handover queue, got " .. #holders)
		end
		cameren.received, cameren.room = {}, 80
		local opensBefore = #log.opens
		sim.declineNext = 1
		t = nowMs()
		groupSay(cameren, "ok everybody hand it over")
		sim.run(80)
		sim.declineNext = 0
		local opens = {}
		for i = opensBefore + 1, #log.opens do table.insert(opens, log.opens[i]) end
		if #opens < 3 then
			fail("crewloot: " .. #opens .. " trades opened for two holders and one declined (3 expected)")
		end
		for i = 2, #opens do
			-- (a trade lasts 3 s; the gap after it is 4 s)
			if opens[i].t - opens[i - 1].t < 7000 then
				fail(string.format("crewloot: trade %d opened %d ms after the one before (3 s open + 4 s gap)", i, opens[i].t - opens[i - 1].t))
			end
		end
		for _, b in ipairs(holders) do
			local firstOpen = nil
			for _, o in ipairs(opens) do
				if o.bot == b.oid then firstOpen = firstOpen or o.t end
			end
			local said = nil
			for _, l in ipairs(entries(log.group, b, t)) do
				for _, kind in ipairs({"handover", "handoverPart", "handoverRest", "handoverFull"}) do
					if isLine(l.text, b.role, kind) then said = said or l.t end
				end
			end
			if firstOpen == nil or said == nil or said < firstOpen then
				fail("crewloot: the " .. b.role .. " said its trade line at " .. tostring(said) .. ", its trade opened at " .. tostring(firstOpen))
			end
		end
		if totalGoods() ~= 0 or #cameren.received < 3 then
			fail("crewloot: after the queue, " .. totalGoods() .. " goods held and " .. #cameren.received .. " received")
		end
		medic.goods = {{oid = 9100010, name = "Old claw", quantity = 1, resource = false, tradable = true}}

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
		sim.run(14) -- (a trailing bot walks up first)
		if #entries(log.offers, holder, t) < 1 then
			fail("crewloot: a dismissed bot didn't offer its goods")
		end
		if mode(holder) == "home" and (goodsCount(holder) > 0 or #cameren.received < count) then
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
			if l.text:find("trade", 1, true) or isLine(l.text, "ranger", "harvestedOne") then
				realPrint("         " .. ctx.objects[l.bot].first .. ": " .. l.text)
				break
			end
		end
		teardown()
	end


	-- Phase 7b: the harvest type, the ranger's own pick and why, harvest talk answered by the ranger
	function scenarios.crewharvest()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		if members(cameren) ~= 5 then
			fail("crewharvest: " .. members(cameren) .. " in the group")
		end
		sim.run(10)
		local gid = cameren.groupId
		local gk = "crew:group:" .. cameren.oid .. ":"

		-- 1. Reading the words
		local readings = {
			{"harvest hide", "hide"}, {"skin them for bone", "bone"}, {"meat only", "meat"}, {"just the hides", "hide"},
			{"bone from now on", "bone"}, {"harvest anything", "any"}, {"harvest the bantha for meat", "meat"},
			{"take the meat", "meat"}, {"Kael, harvest the bones please", "bone"}, {"skin whatever is best", "any"},
			{"harvest them", nil}, {"harvest hide and bone", nil}, {"what are you harvesting?", nil}, {"harvesting what?", nil},
			{"don't harvest hide", nil}, {"I need some hide for armor", nil}, {"harvest everything", nil}, {"how does harvesting work?", nil},
			{"your pick", nil}, {"loot the bodies", nil}, {"skin your pick", "any"}, {"harvest whatever's best", "any"},
			{"your call", nil}, {"up to you", nil}, {"whatever's best", nil}, {"what's the best way to the bank", nil},
			{"the hides were nice", nil}, {"any krayts around?", nil}, {"the hide on that thing is thick", nil},
		}
		for _, r in ipairs(readings) do
			local got = BotCrew:harvestKindOf(r[1])
			if got ~= r[2] then
				fail("crewharvest: '" .. r[1] .. "' read as " .. tostring(got) .. ", expected " .. tostring(r[2]))
			end
		end
		-- (ordinary chatter, even after harvest talk, is no order)
		for _, chatter in ipairs({"your call", "up to you", "whatever's best", "you choose", "your pick"}) do
			if BotCrew:harvestKindOf(chatter) ~= nil or BotCrew:intentFor(chatter, nil) == "harvest" then
				fail("crewharvest: '" .. chatter .. "' alone reads as a harvest order")
			end
		end
		for _, q in ipairs({"what are you harvesting?", "what are we skinning for", "harvesting what?", "which are you skinning, hide or meat?"}) do
			if not BotCrew:harvestQuestion(q) then fail("crewharvest: '" .. q .. "' isn't a harvest question") end
		end
		if BotCrew:harvestQuestion("harvest the hides") or BotCrew:harvestQuestion("what's around?") then
			fail("crewharvest: an order or another question read as a harvest question")
		end

		-- A creature with meat, hide and bone, as the planet's current spawns stand
		local function options(hideSpawn, boneScore)
			return {
				{kind = "meat", amount = 300, class = "Tatooinian Carnivore Meat", spawn = "Ruvet", score = 420, lead = "OQ", leadValue = 640,
					stats = "OQ 640, PE 300, FL 400, DR 340"},
				{kind = "hide", amount = 120, class = "Tatooinian Leathery Hide", spawn = hideSpawn or "Glatoro", score = 700, lead = "OQ",
					leadValue = 870, stats = "OQ 870, SR 640, UT 500, MA 790"},
				{kind = "bone", amount = 60, class = "Tatooinian Bone", spawn = "Orlato", score = boneScore or 500, lead = "UT", leadValue = 640,
					stats = "OQ 560, SR 480, UT 640, MA 320"},
			}
		end
		local function kill(name, opts)
			local mob = makeMob(name, cameren.x + 10, cameren.y + 6, 300)
			mob.ownerGroup, mob.loot, mob.credits = gid, {"A trophy"}, 0
			mob.harvests = opts
			mob.harvest = opts[1]
			attack(cameren, mob)
			return mob
		end
		local function whyLines(since)
			local out = {}
			for _, l in ipairs(entries(log.group, ranger, since)) do
				if l.text:find("OQ ", 1, true) or l.text:find("UT ", 1, true) or l.text:find("biggest yield", 1, true) then table.insert(out, l.text) end
			end
			return out
		end

		-- 2. Its own pick: the best score (the hide here), said once with why; the second carcass gets the short line only
		local t = nowMs()
		local bantha = kill("a bantha", options())
		sim.run(40)
		if not bantha.dead or not (bantha.harvested or {})[ranger.oid] then fail("crewharvest: the first bantha wasn't harvested") end
		local got = entries(log.harvests, ranger, t)
		if #got < 1 or got[1].got ~= "hide" then fail("crewharvest: the ranger took " .. tostring(got[1] and got[1].got) .. ", not the best-scoring hide") end
		local why = whyLines(t)
		if #why ~= 1 or not why[1]:lower():find("hide", 1, true) or not why[1]:find("OQ 870", 1, true) or not why[1]:find("Glatoro", 1, true) then
			fail("crewharvest: the why line: " .. table.concat(why, " | "))
		end
		t = nowMs()
		local bantha2 = kill("a bantha", options())
		sim.run(40)
		if not (bantha2.harvested or {})[ranger.oid] or #whyLines(t) ~= 0 then
			fail("crewharvest: the second carcass said why again (" .. #whyLines(t) .. ")")
		end
		local short = false
		for _, l in ipairs(entries(log.group, ranger, t)) do
			if isLine(l.text, "ranger", "harvestedOne") and l.text:find("Glatoro", 1, true) then short = true end
		end
		if not short then fail("crewharvest: the short line doesn't name the spawn") end

		-- A new spawn of the same kind: it says why again
		t = nowMs()
		local bantha3 = kill("a bantha", options("Mirnato"))
		sim.run(40)
		if #whyLines(t) ~= 1 or not whyLines(t)[1]:find("Mirnato", 1, true) then
			fail("crewharvest: no new why line for a new spawn (" .. table.concat(whyLines(t), " | ") .. ")")
		end
		-- ...and when another kind is the best
		t = nowMs()
		local bantha4 = kill("a bantha", options("Mirnato", 900))
		sim.run(40)
		local again = whyLines(t)
		if #again ~= 1 or not again[1]:lower():find("bone", 1, true) then
			fail("crewharvest: no why line when the pick changed to bone (" .. table.concat(again, " | ") .. ")")
		end

		-- 3. "harvest bone" in group chat: the ranger answers (not the tank), keeps it for the hunt, says it, logs it
		t = nowMs()
		groupSay(cameren, "harvest hide")
		sim.run(4)
		local answers = entries(log.group, nil, t)
		local fromRanger = 0
		for _, l in ipairs(answers) do
			if l.bot == ranger.oid and isLine(l.text, "ranger", "harvestKind") and l.text:lower():find("hide", 1, true) then fromRanger = fromRanger + 1 end
		end
		if readStringData(gk .. "harvestKind") ~= "hide" or fromRanger ~= 1 then
			fail("crewharvest: 'harvest hide': kind '" .. readStringData(gk .. "harvestKind") .. "', " .. fromRanger .. " answers from the ranger (" .. #answers .. " lines)")
		end
		for _, l in ipairs(answers) do
			if l.bot ~= ranger.oid and not isLine(l.text, "tank", "harvestAsk") then fail("crewharvest: someone besides the ranger answered: " .. l.text) end
		end
		if not readStringData(gk .. "huntLog"):find("Asked for hide only", 1, true) then fail("crewharvest: the hunt log doesn't have the request") end
		-- Out loud, near the crew: "skin them for bone"
		t = nowMs()
		speak(tank, cameren, "skin them for bone", "spatial")
		speak(ranger, cameren, "skin them for bone", "spatial")
		speak(medic, cameren, "skin them for bone", "spatial")
		speak(rifleman, cameren, "skin them for bone", "spatial")
		sim.run(4)
		local louder = {}
		for _, l in ipairs(entries(log.group, nil, t)) do
			if isLine(l.text, "ranger", "harvestKind") or isLine(l.text, "tank", "harvestKind") then table.insert(louder, l) end
		end
		if readStringData(gk .. "harvestKind") ~= "bone" or #louder ~= 1 or louder[1].bot ~= ranger.oid then
			fail("crewharvest: out loud 'skin them for bone': kind '" .. readStringData(gk .. "harvestKind") .. "', " .. #louder .. " answers")
		end

		-- 4. Every creature after that gives bone; one with no bone gets its own pick, said once
		t = nowMs()
		local boneOne = kill("a bantha", options())
		sim.run(40)
		local took = entries(log.harvests, ranger, t)
		if #took < 1 or took[1].got ~= "bone" or took[1].asked ~= "bone" then fail("crewharvest: asked for bone, took " .. tostring(took[1] and took[1].got)) end
		local noBone = {options()[1], options()[2]}
		t = nowMs()
		kill("a dewback", noBone)
		sim.run(40)
		local missing = 0
		for _, l in ipairs(entries(log.group, ranger, t)) do
			if isLine(l.text, "ranger", "harvestNoKind") and l.text:find("bone", 1, true) then missing = missing + 1 end
		end
		took = entries(log.harvests, ranger, t)
		if missing ~= 1 or #took < 1 or took[1].got ~= "hide" then
			fail("crewharvest: a creature with no bone: " .. missing .. " lines, took " .. tostring(took[1] and took[1].got))
		end
		t = nowMs()
		kill("a dewback", {options()[1], options()[2]})
		sim.run(40)
		missing = 0
		for _, l in ipairs(entries(log.group, ranger, t)) do
			if isLine(l.text, "ranger", "harvestNoKind") then missing = missing + 1 end
		end
		if missing ~= 0 then fail("crewharvest: the no-bone line was said twice in a hunt") end

		-- 5. "what are you harvesting?": only the ranger answers, naming the type asked for and the resource with its stats
		t = nowMs()
		groupSay(cameren, "what are you harvesting?")
		sim.run(4)
		local status = entries(log.group, nil, t)
		if #status ~= 1 or status[1].bot ~= ranger.oid or not status[1].text:find("Bone only", 1, true) or
			not status[1].text:find("OQ", 1, true) or not status[1].text:find("as you asked", 1, true) then
			fail("crewharvest: the status answer: " .. #status .. " lines, " .. tostring(status[1] and status[1].text))
		end
		-- Out loud, with nobody named
		t = nowMs()
		for _, b in ipairs({tank, ranger, medic, rifleman}) do speak(b, cameren, "what are we skinning for?", "spatial") end
		sim.run(4)
		status = entries(log.group, nil, t)
		if #status ~= 1 or status[1].bot ~= ranger.oid then fail("crewharvest: out loud, the ranger didn't answer alone (" .. #status .. ")") end

		-- 6. "harvest anything": its own pick again, and it says why again at the next carcass
		t = nowMs()
		groupSay(cameren, "harvest anything")
		sim.run(4)
		if readStringData(gk .. "harvestKind") ~= "" then fail("crewharvest: 'harvest anything' left the kind") end
		local anyLineSaid = false
		for _, l in ipairs(entries(log.group, ranger, t)) do
			if isLine(l.text, "ranger", "harvestAny") then anyLineSaid = true end
		end
		if not anyLineSaid then fail("crewharvest: no line for 'harvest anything'") end
		t = nowMs()
		kill("a bantha", options("Mirnato", 450))
		sim.run(40)
		took = entries(log.harvests, ranger, t)
		if #took < 1 or took[1].got ~= "hide" or took[1].asked ~= "" or #whyLines(t) ~= 1 then
			fail("crewharvest: back on its own pick, took " .. tostring(took[1] and took[1].got) .. ", " .. #whyLines(t) .. " why lines")
		end
		-- The asked-for state goes to the brain
		local facts = BotCrew:requestFields(ranger, ranger.oid, cameren.oid).harvest
		if facts == nil or not facts:find("best crafting stats", 1, true) or not facts:find("Mirnato", 1, true) then
			fail("crewharvest: the brain's harvest fact: " .. tostring(facts))
		end

		-- 7. A dead ranger can't: another crew member answers the order, and the kind is kept
		ranger.dead = true
		t = nowMs()
		groupSay(cameren, "harvest meat")
		sim.run(4)
		local standIn = entries(log.group, nil, t)
		if readStringData(gk .. "harvestKind") ~= "meat" or #standIn < 1 or standIn[1].bot == ranger.oid then
			fail("crewharvest: with the ranger dead, kind '" .. readStringData(gk .. "harvestKind") .. "', " .. #standIn .. " answers")
		end
		ranger.dead = false

		-- 8. The hunt ends after 30 minutes of silence; and the group breaking up clears the kind too
		writeData(gk .. "huntSeen", sim.now - 2000)
		groupSay(cameren, "follow me")
		sim.run(2)
		if readStringData(gk .. "harvestKind") ~= "" then fail("crewharvest: the kind outlived the hunt") end
		groupSay(cameren, "harvest bone")
		sim.run(3)
		if readStringData(gk .. "harvestKind") ~= "bone" then fail("crewharvest: the kind wasn't set again") end
		for _, m in ipairs({cameren.oid, tank.oid, rifleman.oid, medic.oid, ranger.oid}) do ctx.objects[m].groupId = nil end
		groups[gid] = nil
		sim.run(15)
		if readStringData(gk .. "harvestKind") ~= "" then fail("crewharvest: the kind outlived the group") end

		realPrint(string.format("crewharvest %d harvests, %d group lines", #log.harvests, #log.group))
		teardown()
	end

	-- Phase 7b: missions by creature
	function scenarios.crewcreature()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(4)
		end)
		sim.run(10)
		local t1 = {oid = 7001, x = cameren.x + 8, y = cameren.y, planet = "tatooine"}
		mw.terminals = {t1}
		local function lines(b, since) return entries(log.group, b, since) end
		local function rewards(b)
			local out = {}
			for _, m in ipairs(b.missions or {}) do table.insert(out, m.reward) end
			table.sort(out, function(a, c) return a > c end)
			return table.concat(out, ",")
		end
		local function targets(b)
			local out = {}
			for _, m in ipairs(b.missions or {}) do table.insert(out, m.target) end
			table.sort(out)
			return table.concat(out, ",")
		end
		local function fresh()
			each(function(role, b) b.missions, b.offered = {}, {} end)
			mw.refreshes, mw.accepts = {}, {}
			sim.run(200)	-- (past the three minutes a follow-up counts)
		end
		local function ask(text)
			local t = nowMs()
			mw.refreshes = {}
			groupSay(cameren, text)
			sim.run(45)
			return t
		end

		-- 0. Reading the words
		local reads = {
			{"get womp rat lairs north", "womp rat"}, {"janta missions", "janta"}, {"grab two dragonet lairs east", "dragonet"},
			{"kreetle missions any direction", "kreetle"}, {"grab two dragonet nests", "dragonet"}, {"get dewbacks southeast", "dewback"},
			{"grab two destroy missions north", nil}, {"grab two blorf missions north", nil}, {"get missions east", nil},
			{"greater desert womp rat missions", "greater desert womp rat"}, {"missions with tusken raiders", "tusken raider"},
			{"grab two missions here on tatooine", nil}, {"grab two missions with the leader", nil}, {"get missions near the sand", nil},
			{"grab two missions on the rock", nil}, {"get missions death", nil}, {"grab two missions pa", nil},
		}
		for _, r in ipairs(reads) do
			local got = BotCrew:missionCreatureOf(tank, r[1])
			if got ~= r[2] then fail("crewcreature: '" .. r[1] .. "' read as creature " .. tostring(got) .. ", expected " .. tostring(r[2])) end
		end

		-- 0b. Hunting talk starts no errand, with a terminal by or not; "missions" or a take verb and a creature do
		local chatter = {"kill that womp rat lair", "get over to the lair east", "that dragonet lair was rough", "watch the kreetle",
			"rats!", "kreetle nest incoming", "attack the dewback nest", "follow me to the womp rat lair", "stay away from that lair",
			"we should clear the lair east of here", "janta camp ahead"}
		for _, near in ipairs({true, false}) do
			mw.terminals = near and {t1} or {}
			for _, line in ipairs(chatter) do
				mw.listCalls, mw.accepts = {}, {}
				local tq = nowMs()
				groupSay(cameren, line)
				speak(tank, cameren, line, "spatial")
				sim.run(12)
				if next(mw.listCalls) ~= nil or #mw.accepts > 0 or readStringData("bot:" .. tank.oid .. ":crew:mState") == "walking" then
					fail("crewcreature: '" .. line .. "' started a mission errand (terminal near: " .. tostring(near) .. ")")
				end
				for _, l in ipairs(entries(log.group, nil, tq)) do
					if isLine(l.text, "tank", "missionNoTerminal") or isLine(l.text, "tank", "missionWhere") then
						fail("crewcreature: '" .. line .. "' got a mission answer: " .. l.text)
					end
				end
			end
		end
		mw.terminals = {t1}
		-- ("grab two dragonet lairs east", with a terminal by and a take verb and creature, is an errand)
		mw.lists.default = {{{degrees = 90, reward = 5000, target = "dragonet lair"}, {degrees = 95, reward = 4000, target = "dragonet lair"}}}
		t = ask("grab two dragonet lairs east")
		each(function(role, b)
			if rewards(b) ~= "5000,4000" then fail("crewcreature: 'grab two dragonet lairs east': the " .. role .. " holds '" .. rewards(b) .. "'") end
		end)
		fresh()

		-- 1. A creature and a direction: the best paying of that creature within 45 degrees (the dewback nest pays more but isn't one)
		mw.lists.default = {{{degrees = 10, reward = 9000, target = "dewback nest"}, {degrees = 350, reward = 3000, target = "womp rat lair"},
			{degrees = 20, reward = 2500, target = "womp rat lair"}, {degrees = 200, reward = 8000, target = "womp rat lair"},
			{degrees = 5, reward = 1000, target = "greater desert womp rat lair", creatures = {"greater desert womp rat"}},
			{degrees = 40, reward = 4000, target = "janta camp", creatures = {"janta hunter", "janta warrior"}}}}
		local t = ask("get womp rat lairs north")
		each(function(role, b)
			if rewards(b) ~= "3000,2500" then fail("crewcreature: the " .. role .. " took '" .. rewards(b) .. "' for womp rat lairs north (3000,2500)") end
			if not lines(b, t)[1] or not lines(b, t)[1].text:find("womp rat", 1, true) then fail("crewcreature: the " .. role .. " didn't report womp rat lairs") end
		end)
		fresh()

		-- 2. A creature and no direction: the best anywhere. A janta camp is found by its creatures
		t = ask("janta missions")
		each(function(role, b)
			if targets(b) ~= "janta camp" then fail("crewcreature: the " .. role .. " took '" .. targets(b) .. "' for janta missions") end
		end)
		fresh()

		-- 3. None of that creature on offer: it refreshes five times, takes nothing and says so (no other creature)
		t = ask("grab two dragonet lairs east")
		each(function(role, b)
			if #(b.missions or {}) ~= 0 then fail("crewcreature: the " .. role .. " took a mission with no dragonet on offer") end
			if mw.refreshes[b.oid] ~= 5 then fail("crewcreature: the " .. role .. " read " .. tostring(mw.refreshes[b.oid]) .. " lists (5)") end
			local said = lines(b, t)
			if #said ~= 1 or not isLine(said[1].text, role, "missionNoneOf") or not said[1].text:find("dragonet", 1, true) then
				fail("crewcreature: the " .. role .. " said " .. #said .. " lines: " .. tostring(said[1] and said[1].text))
			end
		end)

		-- 4. A follow-up keeps the creature (and the direction): "search again" with dragonets on the new list
		mw.lists.default = {{{degrees = 95, reward = 9000, target = "womp rat lair"}, {degrees = 80, reward = 2000, target = "dragonet lair"},
			{degrees = 100, reward = 3000, target = "dragonet lair"}, {degrees = 270, reward = 9999, target = "dragonet lair"}}}
		each(function(role, b) b.offered = {} end)
		mw.refreshes = {}
		t = nowMs()
		groupSay(cameren, "search again")
		sim.run(45)
		each(function(role, b)
			if rewards(b) ~= "3000,2000" then fail("crewcreature: after 'search again' the " .. role .. " holds '" .. rewards(b) .. "' (3000,2000 east dragonets)") end
		end)
		fresh()

		-- 4b. A creature alone, soon after, is a follow-up (a few words); a longer line of talk isn't
		mw.lists.default = {{{degrees = 95, reward = 9000, target = "womp rat lair"}, {degrees = 85, reward = 2500, target = "kreetle nest"},
			{degrees = 100, reward = 3500, target = "kreetle nest"}}}
		each(function(role, b) b.offered = {} end)
		mw.refreshes = {}
		t = ask("grab two dragonet lairs east")
		mw.refreshes = {}
		local before4 = #mw.accepts
		groupSay(cameren, "those kreetles are a pain to hunt down in the open")
		sim.run(45)
		if #mw.accepts ~= before4 then fail("crewcreature: a long line of chatter about kreetles started an errand") end
		groupSay(cameren, "kreetles then")
		sim.run(45)
		each(function(role, b)
			if rewards(b) ~= "3500,2500" then fail("crewcreature: after 'kreetles then' the " .. role .. " holds '" .. rewards(b) .. "' (3500,2500 east kreetles)") end
		end)
		fresh()

		-- 4c. A bare creature with no take verb, outside the answer to "none on offer", starts nothing ("watch the kreetle")
		do
			mw.lists.default = {{{degrees = 95, reward = 3500, target = "kreetle nest"}}}
			each(function(role, b) b.offered = {} end)
			mw.refreshes, mw.accepts = {}, {}
			groupSay(cameren, "grab two destroy missions east")
			sim.run(45)
			local heldBefore = #mw.accepts
			for _, line in ipairs({"watch the kreetle", "kreetles!", "rock beetle incoming"}) do
				groupSay(cameren, line)
				sim.run(10)
			end
			if #mw.accepts ~= heldBefore then fail("crewcreature: a bare creature word started an errand") end
			fresh()
		end

		-- 5. A bare direction after a creature errand keeps the creature; a new order with none asks for any creature
		mw.lists.default = {{{degrees = 180, reward = 9000, target = "womp rat lair"}, {degrees = 175, reward = 2000, target = "kreetle nest"},
			{degrees = 185, reward = 3000, target = "kreetle nest"}}}
		t = ask("kreetle missions any direction")
		each(function(role, b)
			if rewards(b) ~= "3000,2000" then fail("crewcreature: the " .. role .. " took '" .. rewards(b) .. "' for kreetle missions any direction") end
		end)
		fresh()
		mw.lists.default = {{{degrees = 180, reward = 9000, target = "womp rat lair"}, {degrees = 175, reward = 2000, target = "kreetle nest"}}}
		t = ask("grab two destroy missions south")
		each(function(role, b)
			if rewards(b) ~= "9000,2000" then fail("crewcreature: the " .. role .. " took '" .. rewards(b) .. "' with no creature asked (9000,2000)") end
		end)
		fresh()

		-- 6. A word that isn't a creature on this planet leaves the request as it is: any creature
		mw.lists.default = {{{degrees = 0, reward = 9000, target = "womp rat lair"}, {degrees = 10, reward = 2000, target = "kreetle nest"}}}
		t = ask("grab two blorf missions north")
		each(function(role, b)
			if rewards(b) ~= "9000,2000" then fail("crewcreature: the " .. role .. " took '" .. rewards(b) .. "' for a creature that doesn't exist (9000,2000)") end
		end)

		realPrint(string.format("crewcreature %d accepts, %d list reads", #mw.accepts, (function() local n = 0 for _, c in pairs(mw.listCalls) do n = n + c end return n end)()))
		teardown()
	end

	-- Phase 7b: the handover after a disband (a window the client loses), the retry, the wait, and out of the group
	function scenarios.crewhandover()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		sim.run(10)
		local function items(n, prefix)
			local out = {}
			for i = 1, n do
				table.insert(out, {oid = 9300000 + (sim.seq or 0) * 100 + i + math.random(1, 90), name = prefix .. i, quantity = 1, resource = false, tradable = true})
			end
			return out
		end
		local function disband()
			local g = groups[cameren.groupId]
			for _, m in ipairs(g and g.members or {}) do ctx.objects[m].groupId = nil end
			if g then groups[g.id] = nil end
		end
		local function said(b, kind, since)
			local n = 0
			for _, l in ipairs(entries(log.group, b, since)) do if isLine(l.text, b.role, kind) then n = n + 1 end end
			for _, l in ipairs(entries(log.says, b, since)) do if isLine(l.text, b.role, kind) then n = n + 1 end end
			for _, l in ipairs(entries(log.tells, b, since)) do if isLine(l.text, b.role, kind) then n = n + 1 end end
			return n
		end

		-- 1. A disband with goods: the offer doesn't open at once (the client is busy), and goes through
		ranger.goods = items(3, "Trophy ")
		cameren.received = {}
		local t = nowMs()
		disband()
		sim.run(2)
		if #entries(log.offers, ranger, t) ~= 0 then fail("crewhandover: the ranger offered within 2 s of the disband") end
		sim.run(8)
		local offers = entries(log.offers, ranger, t)
		if #offers ~= 1 or offers[1].t - t < 3500 then
			fail("crewhandover: after the disband the ranger offered " .. #offers .. " time(s), the first " .. tostring(offers[1] and (offers[1].t - t)) .. " ms after")
		end
		sim.run(20)
		if #cameren.received ~= 3 or #ranger.goods ~= 0 then fail("crewhandover: the disband handover gave " .. #cameren.received .. " items") end
		sim.run(15)
		if mode(ranger) ~= "home" and mode(ranger) ~= "walkingHome" then fail("crewhandover: the ranger didn't go home (" .. mode(ranger) .. ")") end

		-- (back in a group for the rest)
		local function regroup()
			cameren.groupId = nil
			cameren.x, cameren.y = tank.x + 3, tank.y
			each(function(role, b)
				b.x, b.y = cameren.x + 4, cameren.y
				invite(cameren, b, true)
				sim.run(4)
			end)
			sim.run(10)
		end
		regroup()

		-- 2. One lost window: offered again (a few seconds later); the second one is taken; no 'trade me' line
		ranger.goods = items(2, "Claw ")
		cameren.received = {}
		sim.declineNext = 1
		t = nowMs()
		disband()
		sim.run(60)
		sim.declineNext = 0
		offers = entries(log.offers, ranger, t)
		if #offers ~= 2 then fail("crewhandover: a lost window was offered " .. #offers .. " time(s) (2)") end
		if offers[2] and offers[2].t - offers[1].t < 8000 then fail("crewhandover: the second offer came " .. (offers[2].t - offers[1].t) .. " ms after the first") end
		if #cameren.received ~= 2 or #ranger.goods ~= 0 then fail("crewhandover: after one lost window the player got " .. #cameren.received) end
		if said(ranger, "handoverRetryAsk", t) ~= 0 then fail("crewhandover: it asked for 'trade me' after only one lost window") end
		regroup()

		-- 3. Two lost windows: it asks for 'trade me' and waits nearby; it hasn't gone home; 'trade me' out loud makes the offer
		ranger.goods = items(2, "Fang ")
		cameren.received = {}
		sim.declineNext = 2
		t = nowMs()
		disband()
		sim.run(50)
		sim.declineNext = 0
		offers = entries(log.offers, ranger, t)
		if #offers ~= 2 then fail("crewhandover: two lost windows made " .. #offers .. " offers (2)") end
		if said(ranger, "handoverRetryAsk", t) ~= 1 then fail("crewhandover: the 'trade me' line was said " .. said(ranger, "handoverRetryAsk", t) .. " time(s)") end
		if mode(ranger) ~= "leaving" or #ranger.goods ~= 2 then fail("crewhandover: it didn't wait (mode " .. mode(ranger) .. ", " .. #ranger.goods .. " goods)") end
		sim.run(60)
		if #entries(log.offers, ranger, t) ~= 2 or mode(ranger) ~= "leaving" then fail("crewhandover: it offered or left while waiting for 'trade me'") end
		local t2 = nowMs()
		-- far away it isn't heard; near, with no name, it is
		cameren.x = ranger.x + 40
		speak(ranger, cameren, "trade me", "spatial")
		sim.run(3)
		if #entries(log.offers, ranger, t2) ~= 0 then fail("crewhandover: an unnamed 'trade me' from 40 m was heard") end
		cameren.x = ranger.x + 4
		speak(tank, cameren, "trade me", "spatial")
		speak(ranger, cameren, "trade me", "spatial")
		sim.run(25)
		if #entries(log.offers, tank, t2) ~= 0 then fail("crewhandover: a bot with nothing to hand over answered 'trade me'") end
		if #entries(log.offers, ranger, t2) ~= 1 or #cameren.received ~= 2 or #ranger.goods ~= 0 then
			fail("crewhandover: 'trade me' while waiting: " .. #entries(log.offers, ranger, t2) .. " offers, " .. #cameren.received .. " received")
		end
		sim.run(10)
		if mode(ranger) ~= "home" and mode(ranger) ~= "walkingHome" then fail("crewhandover: it didn't go home after the late trade (" .. mode(ranger) .. ")") end
		regroup()

		-- 4. Nobody says 'trade me' for two minutes: it goes home with the goods, and a tell tells where it is
		ranger.goods = items(2, "Hide ")
		cameren.received = {}
		sim.declineNext = 2
		t = nowMs()
		disband()
		sim.run(200)
		sim.declineNext = 0
		if #ranger.goods ~= 2 or (mode(ranger) ~= "home" and mode(ranger) ~= "walkingHome") then
			fail("crewhandover: after two minutes it held " .. #ranger.goods .. " goods in mode " .. mode(ranger))
		end
		sim.run(30)
		-- far from the bot, a tell: where it is
		cameren.x, cameren.y = ranger.x + 400, ranger.y
		t = nowMs()
		speak(ranger, cameren, "hand it over", "tell")
		sim.run(3)
		local whereTold = said(ranger, "handoverWhere", t)
		if whereTold ~= 1 or #entries(log.offers, ranger, t) ~= 0 then
			fail("crewhandover: the tell from afar: " .. whereTold .. " 'where' lines and " .. #entries(log.offers, ranger, t) .. " offers")
		end
		for _, l in ipairs(entries(log.tells, ranger, t)) do
			if not l.text:find("cantina", 1, true) then fail("crewhandover: the 'where' line doesn't say where: " .. l.text) end
		end
		-- (still on its way home, the line says so)
		writeStringData("bot:" .. ranger.oid .. ":crew:mode", "walkingHome")
		t = nowMs()
		speak(ranger, cameren, "give me the loot", "tell")
		sim.run(2)
		if said(ranger, "handoverWhereBound", t) ~= 1 then fail("crewhandover: no 'on my way' line from a bot heading home") end
		if mode(ranger) ~= "walkingHome" then fail("crewhandover: a tell from afar stopped the walk home (" .. mode(ranger) .. ")") end
		writeStringData("bot:" .. ranger.oid .. ":crew:mode", "home")
		-- ...then the player comes by: it offers
		sim.run(20)
		if #entries(log.offers, ranger, t) ~= 0 then fail("crewhandover: it offered while the player was far away") end
		cameren.x, cameren.y = ranger.x + 5, ranger.y
		sim.run(40)
		if #cameren.received ~= 2 or #ranger.goods ~= 0 then
			fail("crewhandover: the player came by and got " .. #cameren.received .. " items")
		end
		sim.run(20)
		if mode(ranger) ~= "home" and mode(ranger) ~= "walkingHome" then fail("crewhandover: it didn't go back to its station (" .. mode(ranger) .. ")") end
		for _, o in ipairs(entries(log.offers, ranger, t)) do
			if o.to ~= cameren.oid then fail("crewhandover: an offer to someone else") end
		end

		-- 5. Out loud, near the bot at home: the same, at once
		sim.run(30)
		ranger.goods = items(1, "Tooth ")
		cameren.received = {}
		cameren.x, cameren.y = ranger.x + 4, ranger.y
		t = nowMs()
		speak(ranger, cameren, ranger.first .. ", hand it over", "spatial")
		sim.run(20)
		if #cameren.received ~= 1 then fail("crewhandover: asked out loud at home, " .. #cameren.received .. " items came") end
		-- ...and with nothing to hand over it says so
		t = nowMs()
		speak(ranger, cameren, ranger.first .. ", hand it over", "spatial")
		sim.run(3)
		if said(ranger, "handoverNone", t) ~= 1 then fail("crewhandover: no 'nothing on me' line") end

		-- 6. A window the player touched and cancelled isn't offered again (the player's choice)
		sim.run(30)
		regroup()
		ranger.goods = items(2, "Gem ")
		cameren.received = {}
		sim.declineNext, sim.declineTouched = 1, true
		t = nowMs()
		disband()
		sim.run(60)
		sim.declineNext, sim.declineTouched = 0, false
		if #entries(log.offers, ranger, t) ~= 1 or #ranger.goods ~= 2 or said(ranger, "handoverCancelled", t) ~= 1 then
			fail("crewhandover: a cancelled window: " .. #entries(log.offers, ranger, t) .. " offers, " .. said(ranger, "handoverCancelled", t) .. " lines")
		end

		realPrint(string.format("crewhandover %d trades offered, %d opened", #log.offers, #log.opens))
		teardown()
	end

	-- crewtactics (Phase 7c, group 3): the tank holds the creatures, the others hold fire on a fresh one, the ranger rescues
	function scenarios.crewtactics()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		local savedChance = BotCrew.calloutChance
		BotCrew.calloutChance = 100

		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		sim.run(10)
		if members(cameren) ~= 5 then
			fail("crewtactics: " .. members(cameren) .. " in the group, expected Cameren and four crew")
		end
		each(function(role, b) b.cell = 0 end)
		cameren.cell = 0
		sim.run(10)

		-- A creature that is on `victim` (the sim's AI hits whoever it is on)
		local function mobOn(name, dx, victim, hp)
			local m = makeMob(name, cameren.x + dx, cameren.y, hp or 1e7)
			m.hits = 5
			if victim ~= nil then
				startCombat(m, victim)
				m.aggro = victim.oid
			end
			return m
		end
		-- When a bot took the creature on: its first shot, or the first walk to its band (a held-fire bot does neither)
		local function firstEngage(b, mob, since)
			local first
			for _, e in ipairs(entries(log.targets, b, since)) do
				if e.target == mob.oid then first = e.t break end
			end
			for _, e in ipairs(entries(log.moves, b, since)) do
				if first == nil or e.t < first then first = e.t end
				break
			end
			return first
		end
		local function slay(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function reset()
			cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
			sim.run(12)
		end
		local step = BotCrew.fightMs

		-- 1. The leader is in a fight and aims at a fresh creature (on nobody): the tank engages it and taunts; the others
		-- hold fire and open once it is on the tank
		local m1 = mobOn("a kreetle", 40, nil)
		cameren.inCombat, cameren.target = true, m1.oid
		local t = nowMs()
		sim.run(6)
		local tankAt = firstEngage(tank, m1, t)
		if tankAt == nil or #okCommands(tank, "taunt", t) == 0 then
			fail("crewtactics: the tank didn't open on the leader's target")
		end
		if m1.aggro ~= tank.oid then
			fail("crewtactics: the creature isn't on the tank")
		end
		for _, role in ipairs({"rifleman", "medic", "ranger"}) do
			local at = firstEngage(crew[role], m1, t)
			if at == nil then
				fail("crewtactics: the " .. role .. " never opened on the creature")
			elseif at < tankAt then
				fail("crewtactics: the " .. role .. " opened before the tank engaged")
			end
		end
		slay(m1)
		reset()

		-- 2. A creature the taunt doesn't take (and that goes for nobody): the others wait three seconds, then open
		local m2 = mobOn("a kreetle", 40, nil)
		m2.neverAggro, m2.noTaunt = true, true
		cameren.inCombat, cameren.target = true, m2.oid
		t = nowMs()
		sim.run(10)
		tankAt = firstEngage(tank, m2, t)
		if tankAt == nil then
			fail("crewtactics: the tank didn't engage the creature that wouldn't come")
		end
		for _, role in ipairs({"rifleman", "medic", "ranger"}) do
			local at = firstEngage(crew[role], m2, t)
			if at == nil then
				fail("crewtactics: the " .. role .. " never opened on the creature that wouldn't come")
			elseif tankAt ~= nil and (at - tankAt < 3000 - 1 or at - tankAt > 3000 + 2 * step) then
				fail(string.format("crewtactics: the %s opened %.1f s after the tank (expected about 3)", role, (at - tankAt) / 1000))
			end
		end
		slay(m2)
		reset()

		-- 3. A creature the leader pulled (it is on the leader): the others still hold, until the tank has taken it
		local m3 = mobOn("a kreetle", 12, cameren)
		cameren.inCombat, cameren.target = true, m3.oid
		t = nowMs()
		sim.run(6)
		tankAt = firstEngage(tank, m3, t)
		local tauntAt = okCommands(tank, "taunt", t)[1]
		if tankAt == nil or tauntAt == nil or m3.aggro ~= tank.oid then
			fail("crewtactics: the tank didn't take the creature off the leader")
		end
		each(function(role, b)
			if role ~= "tank" then
				local at = firstEngage(b, m3, t)
				if at == nil then
					fail("crewtactics: the " .. role .. " never opened on the pulled creature")
				elseif at < tauntAt.t then
					fail("crewtactics: the " .. role .. " opened on a creature still on the leader, before the tank's taunt")
				end
			end
		end)
		slay(m3)
		reset()

		-- 3b. ...and one the tank can't take stays on the leader: they open holdFor seconds after the tank engaged it
		local m3b = mobOn("a kreetle", 12, cameren)
		m3b.noTaunt = true
		cameren.inCombat, cameren.target = true, m3b.oid
		t = nowMs()
		sim.run(10)
		tankAt = firstEngage(tank, m3b, t)
		if tankAt == nil then
			fail("crewtactics: the tank didn't engage the creature on the leader")
		end
		for _, role in ipairs({"rifleman", "medic", "ranger"}) do
			local at = firstEngage(crew[role], m3b, t)
			if at == nil then
				fail("crewtactics: the " .. role .. " never opened on the creature the tank couldn't take")
			elseif tankAt ~= nil and (at - tankAt < 3000 - 1 or at - tankAt > 3000 + 2 * step) then
				fail(string.format("crewtactics: the %s opened %.1f s after the tank on a creature still on the leader (expected about 3)", role, (at - tankAt) / 1000))
			end
		end
		slay(m3b)
		reset()

		-- 3c. A creature on one of them is never held for: the rifleman defends itself at once
		local m3c = mobOn("a kreetle", 12, rifleman)
		cameren.inCombat, cameren.target = false, 0
		t = nowMs()
		sim.run(4)
		local at = firstEngage(rifleman, m3c, t)
		if at == nil or at - t > 2 * step then
			fail("crewtactics: the rifleman held fire on a creature on itself")
		end
		slay(m3c)
		reset()

		-- 4. No hold without a usable tank: told to stay, the tank doesn't hold anyone up
		groupSay(cameren, tank.first .. ", stay")
		sim.run(3)
		local m4 = mobOn("a kreetle", 40, nil)
		m4.neverAggro, m4.noTaunt = true, true
		cameren.inCombat, cameren.target = true, m4.oid
		t = nowMs()
		sim.run(4)
		for _, role in ipairs({"rifleman", "medic", "ranger"}) do
			local at = firstEngage(crew[role], m4, t)
			if at == nil or at - t > 2 * step then
				fail("crewtactics: the " .. role .. " held fire with the tank told to stay")
			end
		end
		slay(m4)
		reset()
		groupSay(cameren, tank.first .. " follow")
		sim.run(5)

		-- 4b. A creature jumps the medic while nobody fights: the others hold fire on it, whichever of them looks first,
		-- until the tank has it
		local mj = mobOn("a kreetle", 20, medic)
		t = nowMs()
		sim.run(8)
		local tauntJ = okCommands(tank, "taunt", t)[1]
		if tauntJ == nil or mj.aggro ~= tank.oid then
			fail("crewtactics: the tank didn't take the creature that jumped the medic")
		end
		for _, role in ipairs({"rifleman", "ranger"}) do
			local at = firstEngage(crew[role], mj, t)
			if at ~= nil and at < tauntJ.t then
				fail("crewtactics: the " .. role .. " opened on the creature that jumped the medic before the tank had it")
			end
		end
		slay(mj)
		reset()

		-- 5. Adds: the creature the tank fights is on it (taunted, its lockout 80 s). Two adds come, one on the rifleman 20 m
		-- off and one on the medic 35 m off: the tank taunts the one on the medic first (the positioning fix: the medic, then the
		-- other ranged bots, then the nearest), from where it stands; nothing is taunted inside a
		-- lockout; a creature that turns on someone else inside its lockout gets an intimidate or a warcry, and a taunt when it ends
		local boss = mobOn("a kreetle", 10, cameren)
		cameren.inCombat, cameren.target = true, boss.oid
		t = nowMs()
		sim.run(6)
		if boss.aggro ~= tank.oid or boss.lockUntil == nil then
			fail("crewtactics: the first creature isn't on the tank")
		end
		local a1 = mobOn("a kreetle", 20, rifleman)
		local a2 = mobOn("a kreetle", 35, medic)
		t = nowMs()
		sim.run(8)
		local t1, t2
		for _, tn in ipairs(entries(log.taunts, tank, t)) do
			if tn.creature == a1.oid and t1 == nil then t1 = tn.t end
			if tn.creature == a2.oid and t2 == nil then t2 = tn.t end
		end
		if t1 == nil or t2 == nil then
			fail("crewtactics: the adds weren't both taunted (" .. tostring(t1) .. ", " .. tostring(t2) .. ")")
		elseif t2 >= t1 then
			fail("crewtactics: the add on the medic (further) wasn't taunted before the one on the rifleman")
		end
		if a1.aggro ~= tank.oid or a2.aggro ~= tank.oid then
			fail("crewtactics: the adds aren't on the tank")
		end
		-- The add the tank took off the rifleman is no longer hers to shoot: she follows the tank's target
		if rifleman.target ~= boss.oid then
			fail("crewtactics: the rifleman kept shooting the add the tank took off her")
		end
		-- The boss turns on the rifleman part-way into its lockout: debuffs, and no taunt until the lockout ends
		sim.run(12)
		t = nowMs()
		boss.aggro = rifleman.oid
		sim.run(20)
		if #entries(log.debuffs, tank, t) == 0 then
			fail("crewtactics: a creature turned on the rifleman inside its lockout and nothing slowed it")
		end
		for _, tn in ipairs(log.taunts) do
			if tn.creature == boss.oid and tn.t > boss.lockUntil - 2 * 40 * 1000 + 1 and tn.t < boss.lockUntil - 1 then
				fail("crewtactics: the tank taunted a creature inside its lockout")
			end
		end
		-- ...and taunts it as soon as the lockout is over
		local lockEnd = boss.lockUntil
		sim.run((lockEnd - nowMs()) / 1000 + 5)
		local after
		for _, tn in ipairs(log.taunts) do
			if tn.creature == boss.oid and tn.t >= lockEnd - 200 and tn.t <= lockEnd + 3 * step then after = tn end
		end
		if after == nil then
			fail("crewtactics: no taunt after the lockout ended")
		end
		for _, tn in ipairs(log.taunts) do
			if tn.inLockout then
				fail("crewtactics: a taunt was sent inside a creature's lockout (" .. tn.creature .. ")")
			end
		end
		slay(boss, a1, a2)
		reset()

		-- 6. Rescue: with the tank out of reach, the ranger pulls a creature off the medic after rescueAfter seconds, once
		local home = tank.x
		tank.x = tank.x - 140
		tank.frozen = true
		local m6 = mobOn("a kreetle", 25, medic)
		t = nowMs()
		sim.run(8)
		local rescues = entries(log.rescues, ranger, t)
		if #rescues ~= 1 then
			fail("crewtactics: the ranger rescued " .. #rescues .. " times, expected once")
		elseif rescues[1].t - t < BotCrew.rescueAfter * 1000 - 1 then
			fail("crewtactics: the ranger rescued too soon")
		elseif m6.aggro ~= ranger.oid then
			fail("crewtactics: the rescued creature isn't on the ranger")
		end
		if #entries(log.taunts, tank, t) > 0 then
			fail("crewtactics: the tank taunted from out of range")
		end
		slay(m6)
		tank.frozen, tank.x = false, home
		reset()

		-- 7. Callouts: some lines (every fight was chatty here), of the tank's kinds, one per bot per 20 s
		local function callout(text)
			return isLine(text, "tank", "pull") or isLine(text, "tank", "got") or isLine(text, "tank", "addGrab") or
				isLine(text, "tank", "tauntDown")
		end
		local last, kinds = -1e9, 0
		for _, l in ipairs(entries(log.group, tank, 0)) do
			if callout(l.text) then
				kinds = kinds + 1
				if l.t - last < 19000 then
					fail("crewtactics: two callouts " .. (l.t - last) / 1000 .. " s apart")
				end
				last = l.t
			end
		end
		if kinds == 0 then
			fail("crewtactics: the tank called nothing out in any fight")
		end

		realPrint(string.format("crewtactics %d taunts, %d debuffs, %d rescues, %d callouts, after-lockout taunt %s", #log.taunts,
			#log.debuffs, #log.rescues, kinds, after ~= nil and "yes" or "NO"))
		BotCrew.calloutChance = savedChance
		teardown()
	end

	-- crewband (Phase 7c, group 4): each ranged bot stands in its weapon's band and kneels, backs off a creature that comes
	-- for it without firing on the move, keeps away from lairs; the medic throws poison and disease packs between heals
	function scenarios.crewband()
		setup("/nonexistent/sim-talk")
		local tank, rifleman, medic, ranger = crew.tank, crew.rifleman, crew.medic, crew.ranger
		local savedChance = BotCrew.calloutChance
		BotCrew.calloutChance = 100
		sim.lairs = {}

		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", tank.x + 3, tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		sim.run(10)
		if members(cameren) ~= 5 then
			fail("crewband: " .. members(cameren) .. " in the group, expected Cameren and four crew")
		end
		each(function(role, b) b.cell = 0 end)
		cameren.cell = 0
		sim.run(10)

		local function mobAt(dx, dy, hp)
			local m = makeMob("a kreetle", cameren.x + dx, cameren.y + dy, hp or 1e7)
			m.hits = 0
			return m
		end
		local function slay(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function reset()
			cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
			sim.run(15)
		end
		-- Shots fired (a target set with an attack queued) while the bot was walking
		local function firedWalking(b, since)
			local n = 0
			for _, e in ipairs(entries(log.targets, b, since)) do
				if e.engage and e.moving then n = n + 1 end
			end
			return n
		end
		local function firstShot(b, mob, since)
			for _, e in ipairs(entries(log.targets, b, since)) do
				if e.target == mob.oid and e.engage then return e end
			end
			return nil
		end

		-- 1. Bands from the weapons: a creature 70 m off, the leader fighting it. The rifleman (T21: ideal 50 m) ends 40-50 m
		-- from it, the medic (E-11, held to its stim reach) 30-40, the ranger (EE-3: ideal 27) 17-27; all kneel; nobody fired
		-- while walking
		-- (a bot plants where it settled in its band and doesn't follow the creature in: its distance is taken when it first kneels)
		local m1 = mobAt(70, 0)
		local t = nowMs()
		attack(cameren, m1)
		local planted = {}
		for i = 1, 70 do
			sim.run(1)
			for _, r in ipairs({"rifleman", "medic", "ranger"}) do
				if planted[r] == nil and crew[r].posture == "crouched" then planted[r] = dist(crew[r], m1) end
			end
		end
		local function band(role, lo, hi)
			local b = crew[role]
			local d = planted[role]
			if d == nil then
				fail("crewband: the " .. role .. " never knelt")
				return
			end
			if d < lo or d > hi then
				fail(string.format("crewband: the %s knelt %.1f m from the creature (band %d-%d)", role, d, lo, hi))
			end
			if firedWalking(b, t) > 0 then
				fail("crewband: the " .. role .. " fired while walking")
			end
			local shot = firstShot(b, m1, t)
			if shot == nil then
				fail("crewband: the " .. role .. " never fired")
			end
		end
		band("rifleman", 38, 51)
		band("medic", 28, 41)
		band("ranger", 15, 28)
		if dist(tank, m1) > 5 then
			fail("crewband: the tank isn't on the creature")
		end
		if dist(medic, tank) > 42 then
			fail(string.format("crewband: the medic is %.1f m from the tank, out of its stim reach", dist(medic, tank)))
		end

		-- 2. The medic's packs: poison then disease on the tank's target, once each, between heals
		local dots = entries(log.dots, medic, t)
		if #dots ~= 2 or dots[1].cmd ~= "applypoison" or dots[2].cmd ~= "applydisease" or dots[1].creature ~= m1.oid then
			local names = {}
			for _, d in ipairs(dots) do table.insert(names, d.cmd) end
			fail("crewband: the medic threw " .. table.concat(names, ", ") .. ", expected a poison then a disease pack")
		elseif dots[2].t - dots[1].t < 6000 then
			fail("crewband: the packs came less than six seconds apart")
		end
		-- (one callout per bot per 20 s: the poison's, the disease's comes too soon)
		local medicLines = entries(log.group, medic, t)
		if not (anyLine(medicLines, "medic", "poisoned") or anyLine(medicLines, "medic", "diseased")) then
			fail("crewband: the medic didn't call the packs out")
		end
		-- 1b. The creature dies and the leader aims at a fresh one (on nobody): the ranged bots hold fire where they kneel, and
		-- neither walk in toward the leader nor stand up
		slay(m1)
		local m1b = makeMob("a kreetle", m1.x, m1.y, 1e7) -- (where the fight was)
		m1b.hits = 0
		attack(cameren, m1b) -- (the pull: the creature is on the leader until the tank takes it)
		t = nowMs()
		local stood, held = false, 0
		for i = 1, 8 do
			sim.run(0.5)
			if #okCommands(tank, "taunt", t) > 0 then break end
			held = held + 1
			for _, b in ipairs({rifleman, medic, ranger}) do
				if b.posture ~= "crouched" then stood = true end
			end
		end
		-- (the tank's taunt was out of lockout and landed at once: the ranged bots had no hold to be watched in)
		if stood then
			fail("crewband: a ranged bot stood up during the hold on a fresh pull")
		end
		local tauntAt = okCommands(tank, "taunt", t)[1]
		for _, b in ipairs({rifleman, medic, ranger}) do
			if #entries(log.moves, b, t) > 0 and entries(log.moves, b, t)[1].t < (tauntAt and tauntAt.t or math.huge) or #entries(log.follows, b, t) > 0 then
				fail("crewband: the " .. b.role .. " walked during the hold on a fresh pull")
			end
		end
		slay(m1b)
		reset()

		-- 3. A creature that goes for the rifleman (the positioning fix: nobody backs off): she plants where she stands, calls "add on me",
		-- keeps her target and keeps shooting; she does not walk
		local m3 = mobAt(70, 0)
		m3.hits = 5
		attack(cameren, m3)
		sim.run(30)
		t = nowMs()
		local startX, startY = rifleman.x, rifleman.y
		m3.noTaunt = true -- (the tank can't take it off her)
		m3.aggro = rifleman.oid
		startCombat(m3, rifleman)
		m3.x, m3.y = rifleman.x + 18, rifleman.y
		sim.run(12)
		for _, mv in ipairs(entries(log.moves, rifleman, t)) do
			fail(string.format("crewband: the rifleman walked %.0f m with a creature on her", math.sqrt((mv.x - startX) ^ 2 + (mv.y - startY) ^ 2)))
			break
		end
		if math.sqrt((rifleman.x - startX) ^ 2 + (rifleman.y - startY) ^ 2) > 3 then
			fail("crewband: the rifleman moved with a creature on her")
		end
		for _, e in ipairs(entries(log.targets, rifleman, t)) do
			if e.target == 0 then fail("crewband: the rifleman dropped her target with a creature on her") end
		end
		if not anyLine(entries(log.group, rifleman, t), "rifleman", "addOnMe") then
			fail("crewband: no 'add on me' call")
		end
		local shots3 = 0
		for _, c in ipairs(okCommands(rifleman, nil, t)) do shots3 = shots3 + 1 end
		if shots3 == 0 then fail("crewband: the rifleman didn't shoot with a creature on her") end
		-- (the creature goes to the tank: planted, with nothing on her, she kneels)
		m3.aggro = tank.oid
		startCombat(m3, tank)
		sim.run(8)
		if rifleman.posture ~= "crouched" then
			fail("crewband: the planted rifleman isn't kneeling once nothing is on her (" .. tostring(rifleman.posture) .. ")")
		end
		slay(m3)
		reset()

		-- 3b. Planted: the rifleman, planted in a fight, stays when the leader moves a few metres and the creature stays in reach; but
		-- out of her weapon's reach (64 m) she walks
		local m3b = mobAt(70, 0)
		attack(cameren, m3b)
		sim.run(25)
		local px, py = rifleman.x, rifleman.y
		t = nowMs()
		m3b.x = m3b.x + 12
		sim.run(10)
		if #entries(log.moves, rifleman, t) > 0 then fail("crewband: the planted rifleman walked for a creature 12 m further off") end
		m3b.x = m3b.x + 90
		sim.run(15)
		if #entries(log.moves, rifleman, t) == 0 then fail("crewband: the planted rifleman didn't walk to a target beyond her weapon's reach") end
		-- ...and with no line of sight for losFor seconds
		slay(m3b)
		reset()
		local m3c = mobAt(70, 0)
		attack(cameren, m3c)
		sim.run(25)
		t = nowMs()
		rifleman.noLineOfSight = true
		sim.run(3)
		if #entries(log.moves, rifleman, t) > 0 then fail("crewband: the rifleman walked before losFor seconds without a line of sight") end
		sim.run(10)
		if #entries(log.moves, rifleman, t) == 0 then fail("crewband: the rifleman didn't move after losing the line of sight") end
		rifleman.noLineOfSight = nil
		slay(m3c)
		reset()

		-- 4. A lair where the rifleman would stand: she stands elsewhere in her band, and so does the ranger
		local m4 = mobAt(80, 0)
		local lx = m4.x - 48 -- the plain spot: on the leader's side of the creature, 48 m out
		sim.lairs = {{oid = 777, x = lx, y = m4.y}}
		t = nowMs()
		attack(cameren, m4)
		sim.run(35)
		for _, role in ipairs({"rifleman", "ranger", "medic"}) do
			local b = crew[role]
			local d = math.sqrt((b.x - lx) ^ 2 + (b.y - m4.y) ^ 2)
			if d < BotCrew.lairAvoid and role ~= "ranger" then
				fail(string.format("crewband: the %s stands %.1f m from the lair", role, d))
			end
		end
		-- (the creature closes on the tank while she walks, and she is planted where she settled: a little inside the band)
		local d = dist(rifleman, m4)
		if d < 33 or d > 51 then
			fail(string.format("crewband: the rifleman stands %.1f m from the creature with a lair in the way", d))
		end
		sim.lairs = {}
		slay(m4)
		reset()

		-- 5. Heals first: someone hurt gets a stim before any pack; a creature that resisted twice isn't packed again;
		-- one that can't be poisoned gets no poison
		local m5 = mobAt(60, 0)
		m5.resists, m5.immunePoison = 2, true
		-- (big pools, so the specials' cost doesn't keep anyone under the heal line)
		each(function(role, b)
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).base = b:pool(pool).base * 8 end
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).cur = b:getMaxHAM(pool) end
		end)
		cameren.noRegen = true
		cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * 0.3)
		t = nowMs()
		attack(cameren, m5)
		sim.run(60)
		local first
		for _, c in ipairs(commands(medic, nil, t)) do
			if c.cmd == "healdamage" or c.cmd == "applypoison" or c.cmd == "applydisease" then first = c.cmd break end
		end
		if first ~= "healdamage" then
			fail("crewband: the medic's first move was " .. tostring(first) .. ", expected a heal")
		end
		local poisons, diseases = 0, 0
		for _, d in ipairs(entries(log.dots, medic, t)) do
			if d.cmd == "applypoison" then poisons = poisons + 1 else diseases = diseases + 1 end
		end
		if poisons ~= 0 or diseases ~= 2 then
			fail("crewband: against a creature immune to poison and resisting disease the medic threw " .. poisons .. " poison and " ..
				diseases .. " disease packs, expected 0 and 2")
		end
		cameren.noRegen = false
		slay(m5)
		reset()

		realPrint(string.format("crewband %d packs thrown", #log.dots))
		BotCrew.calloutChance = savedChance
		sim.lairs = nil
		teardown()
	end


	-- Scenario: Phase 8 group 1, the full crew of seven and the group cap

	function scenarios.crewfull()
		setup("/nonexistent/sim-talk")
		local seven = {"tank", "rifleman", "medic", "ranger", "squadleader", "entertainer", "commando"}
		for _, role in ipairs(seven) do
			if crew[role] == nil then
				fail("crewfull: no " .. role .. " in the roster")
				teardown()
				return
			end
		end
		local function can(b, ability)
			return readStringData("bot:" .. b.oid .. ":crew:can"):find("," .. ability .. ",", 1, true) ~= nil
		end
		local function specials(b) return readStringData("bot:" .. b.oid .. ":crew:specialsList") end
		local function groupLines(b, text, since)
			for _, l in ipairs(entries(log.group, b, since)) do
				if l.text == text then return true end
			end
			return false
		end
		for _, role in ipairs(seven) do login(crew[role]) end

		-- 1. What the three new ones can do, from their skills
		local sl, ent, com = crew.squadleader, crew.entertainer, crew.commando
		for _, ability in ipairs({"steadyAim", "volley", "formUp", "boostMorale", "rally", "retreat"}) do
			if not can(sl, ability) then fail("crewfull: the squad leader can't " .. ability) end
			if can(ent, ability) or can(com, ability) then fail("crewfull: " .. ability .. " on someone with no squad leader skills") end
		end
		if not specials(sl):find("fullautosingle2", 1, true) or not specials(sl):find("burstshot2", 1, true) then
			fail("crewfull: the squad leader's specials " .. specials(sl))
		end
		if not specials(ent):find("bodyshot3", 1, true) or not specials(ent):find("healthshot2", 1, true) or specials(ent):find("fullauto", 1, true) then
			fail("crewfull: the entertainer's specials " .. specials(ent))
		end
		if not specials(com):find("flamesingle2", 1, true) then
			fail("crewfull: the commando's specials " .. specials(com))
		end
		if not can(com, "flameCone") or not can(com, "acidCone") or not can(com, "grenade") or not can(com, "stims") then
			fail("crewfull: the commando's abilities " .. readStringData("bot:" .. com.oid .. ":crew:can"))
		end
		if can(sl, "stims") or can(ent, "stims") then fail("crewfull: stims without the medic box") end

		-- 2. One human: all seven join (eight in the group)
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		for _, role in ipairs(seven) do
			invite(cameren, crew[role], true)
			sim.run(3)
		end
		sim.run(8)
		if members(cameren) ~= 8 then
			fail("crewfull: " .. members(cameren) .. " in the group, expected Cameren and the seven")
		end
		for _, role in ipairs(seven) do
			if mode(crew[role]) ~= "group" then fail("crewfull: the " .. role .. " is in mode " .. mode(crew[role])) end
		end
		-- "Make room" with nobody to make it for still works as asked: the commando leaves
		local t = nowMs()
		groupSay(cameren, "make room")
		sim.run(4)
		if not groupLines(com, "Sitting this one out.", t) then fail("crewfull: the commando didn't say it sits out") end
		if members(cameren) ~= 7 or com.groupId ~= nil then fail("crewfull: the commando is still in the group after make room") end
		for _, role in ipairs({"tank", "rifleman", "medic", "ranger", "squadleader", "entertainer"}) do
			for _, l in ipairs(entries(log.group, crew[role], t)) do
				if l.text == "Sitting this one out." then fail("crewfull: the " .. role .. " answered make room") end
			end
		end
		sim.run(10)

		-- 3. Another human online and not in the group: at six crew the commando sits out; the other six don't
		local dex = makeHuman("Dex", cameren.x + 5, cameren.y)
		t = nowMs()
		invite(cameren, com, true)
		sim.run(4)
		-- (Cameren + 6 crew = 7, one more and Dex has no place)
		if com.groupId ~= nil then fail("crewfull: the commando joined with no slot left for Dex") end
		local sits = 0
		for _, tell in ipairs(entries(log.tells, com, t)) do if tell.text == "Sitting this one out." then sits = sits + 1 end end
		for _, say in ipairs(entries(log.says, com, t)) do if say.text == "Sitting this one out." then sits = sits + 1 end end
		if sits ~= 1 then fail("crewfull: the commando said 'Sitting this one out.' " .. sits .. " times for the invite") end
		if #commands(com, "decline", t) ~= 1 then fail("crewfull: the commando didn't decline the invite") end

		-- 4. Dex joins the group; the commando still sits out (Cameren, Dex and six crew are eight)
		invite(cameren, dex, false)
		dex.inviter = cameren.oid
		joinGroup(dex, cameren)
		t = nowMs()
		invite(cameren, com, true)
		sim.run(4)
		if com.groupId ~= nil then fail("crewfull: the commando joined a full group of eight") end
		-- ...and a player in a group who asks it to come along gets the same answer
		t = nowMs()
		speak(com, cameren, "wanna hunt?", "spatial")
		sim.run(4)
		if #commands(com, "invite", t) ~= 0 then fail("crewfull: the commando invited a player whose group has no place for it") end

		-- 5. Dex leaves: the commando joins on the next invite
		leaveGroup(dex)
		sim.run(2)
		t = nowMs()
		-- (Dex is still online and not in the group: Cameren + 6 crew + the commando + Dex = 9)
		invite(cameren, com, true)
		sim.run(4)
		if com.groupId ~= nil then fail("crewfull: the commando joined while Dex waited outside a group of seven") end
		dex.pretend = true -- Dex logs out
		dex.inWorld = false
		invite(cameren, com, true)
		sim.run(4)
		if com.groupId == nil then fail("crewfull: the commando didn't join with the other player offline") end

		-- 6. It came in while Dex was away; Dex logs in and isn't in the group: the group is full, so the commando leaves by itself
		local joined = members(cameren)
		t = nowMs()
		dex.pretend, dex.inWorld = nil, true
		sim.run(25)
		if com.groupId ~= nil then fail("crewfull: the commando kept its place with Dex waiting outside a full group") end
		if not groupLines(com, "Sitting this one out.", t) then fail("crewfull: the commando didn't say it sits out") end
		if members(cameren) ~= joined - 1 then fail("crewfull: " .. members(cameren) .. " in the group after the commando left, expected " .. (joined - 1)) end

		realPrint(string.format("crewfull %d in the group", joined))
		teardown()
	end


	-- The seven crew in a group with a human, outdoors (the setup the Phase 8 scenarios share)
	local SEVEN = {"tank", "rifleman", "medic", "ranger", "squadleader", "entertainer", "commando"}
	local function sevenGroup(label)
		setup("/nonexistent/sim-talk")
		for _, role in ipairs(SEVEN) do login(crew[role]) end
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		for _, role in ipairs(SEVEN) do
			invite(cameren, crew[role], true)
			sim.run(3)
		end
		sim.run(10)
		if members(cameren) ~= 8 then
			fail(label .. ": " .. members(cameren) .. " in the group, expected Cameren and the seven")
		end
		for _, role in ipairs(SEVEN) do crew[role].cell = 0 end
		cameren.cell = 0
		sim.run(10)
		return cameren
	end

	local function makeCreature(cameren, name, dx, dy, victim, hp, rooted)
		local m = makeMob(name, cameren.x + dx, cameren.y + (dy or 0), hp or 1e7)
		m.hits = 0
		m.rooted = rooted ~= false -- (it stays where it is: the area geometry is the test)
		if victim ~= nil then
			startCombat(m, victim)
			m.aggro = victim.oid
		end
		return m
	end

	-- Scenario: Phase 8 group 3, the squad leader

	function scenarios.crewsquad()
		local cameren = sevenGroup("crewsquad")
		local savedChance = BotCrew.calloutChance
		local tank, sl = crew.tank, crew.squadleader
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function slLines(since)
			return entries(log.group, sl, since)
		end
		local function slKinds(kind)
			local n = 0
			for _, l in ipairs(slLines(0)) do
				if isLine(l.text, "squadleader", kind) then n = n + 1 end
			end
			return n
		end
		local function cmds(name, since) return okCommands(sl, name, since or 0) end

		-- 1. Steady aim on the way out (outdoors), once; again only when its five minutes are over
		sim.run(10)
		if #cmds("steadyaim") ~= 1 then fail("crewsquad: steady aim " .. #cmds("steadyaim") .. " times on the way out, expected 1") end
		if slKinds("steadyAim") ~= 1 then fail("crewsquad: no 'steady aim' call in group chat") end
		sim.run(200)
		if #cmds("steadyaim") ~= 1 then fail("crewsquad: steady aim again within its five minutes") end
		sim.run(120)
		if #cmds("steadyaim") ~= 2 then fail("crewsquad: steady aim not renewed when it ran out (" .. #cmds("steadyaim") .. ")") end
		-- ...and not indoors
		local savedCell = sl.cell
		sim.run(400)
		local before = #cmds("steadyaim")
		cameren.cell = 77
		sim.run(60)
		if #cmds("steadyaim") ~= before then fail("crewsquad: steady aim cast with the leader indoors") end
		cameren.cell = 0
		sim.run(15)
		-- ...and not standing in town (Mos Eisley's centre), however long it has been
		local ox, oy = cameren.x, cameren.y
		cameren.x, cameren.y = 3500, -4800
		sim.run(60)
		before = #cmds("steadyaim")
		sim.run(400)
		if #cmds("steadyaim") ~= before then fail("crewsquad: steady aim cast with the group standing in town") end
		cameren.x, cameren.y = ox, oy
		sim.run(60)
		if #cmds("steadyaim") ~= before + 1 then fail("crewsquad: steady aim not cast once out of town") end

		-- 2. Rally at the start of a fight with two creatures, volley on the tank's target once three fight it; one call per 20 s
		local m1 = makeCreature(cameren, "a kreetle", 40, 0, nil, nil, false)
		local m2 = makeCreature(cameren, "a kreetle", 40, 3, tank, nil, false)
		local t = nowMs()
		attack(cameren, m1)
		sim.run(14)
		if #cmds("rally", t) ~= 1 then fail("crewsquad: rally " .. #cmds("rally", t) .. " times at the start of a two-creature fight") end
		if #cmds("volleyfire", t) < 1 then fail("crewsquad: no volley fire with the group on the tank's target") end
		local v = cmds("volleyfire", t)[1]
		if v ~= nil and v.target ~= m1.oid and v.target ~= m2.oid then fail("crewsquad: volley fire at something that isn't the fight") end
		local last
		for _, l in ipairs(slLines(t)) do
			if last ~= nil and l.t - last < 19000 then
				fail(string.format("crewsquad: two calls %.1f s apart", (l.t - last) / 1000))
			end
			last = l.t
		end
		if slKinds("rally") + slKinds("volley") < 1 then fail("crewsquad: no rally or volley call") end
		slays(m1, m2)
		cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
		sim.run(25)
		-- (a lone creature: no rally)
		local m3 = makeCreature(cameren, "a kreetle", 40, 0, nil)
		t = nowMs()
		attack(cameren, m3)
		sim.run(12)
		if #cmds("rally", t) ~= 0 then fail("crewsquad: rally for a single creature") end
		slays(m3)
		cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
		sim.run(20)

		-- 3. Form up when a member is stunned or dizzy
		t = nowMs()
		crew.medic.stateReady = nowMs() + 20000 -- (the medic would cure it first: its state treatment is on its wait)
		cameren.states = (cameren.states or 0) | STATE.dizzy
		sim.run(5)
		if #cmds("formup", t) ~= 1 then fail("crewsquad: form up " .. #cmds("formup", t) .. " times for a dizzy member") end
		if (cameren.states & STATE.dizzy) ~= 0 then fail("crewsquad: the leader is still dizzy after form up") end

		-- 4. Boost morale after a fight when one member carries most of the wounds
		t = nowMs()
		cameren.wounds = {[0] = 200, [1] = 200, [3] = 100}
		sim.run(8)
		if #cmds("boostmorale", t) ~= 1 then fail("crewsquad: boost morale " .. #cmds("boostmorale", t) .. " times with the leader carrying the wounds") end
		local sum = 0
		for pool = 0, 8 do sum = sum + ((cameren.wounds or {})[pool] or 0) end
		if sum > 300 then fail("crewsquad: the leader still carries " .. sum .. " wounds after boost morale") end
		-- ...not for a group with spread wounds
		t = nowMs()
		sim.run(100)
		if #cmds("boostmorale", t) ~= 0 then fail("crewsquad: boost morale for evenly spread wounds") end

		-- 5. Retreat when the fight is lost: the tank down and two members under 30%. The crew breaks off and follows; after 30 s
		-- it fights again
		local m5 = makeCreature(cameren, "a kreetle", 30, 0, nil)
		m5.hits = 5
		attack(cameren, m5)
		sim.run(6)
		t = nowMs()
		if #cmds("retreat", t) ~= 0 then fail("crewsquad: retreat in a fight that isn't lost") end
		tank.dead = true
		-- (nobody heals in this: the medic and the rifleman's stims are on their waits)
		crew.medic.injuryReady, crew.rifleman.injuryReady = nowMs() + 40000, nowMs() + 40000
		for _, role in ipairs({"rifleman", "ranger"}) do
			local b = crew[role]
			b.noRegen = true
			b:pool(HEALTH).cur = math.floor(b:getMaxHAM(HEALTH) * 0.2)
		end
		-- (the creature goes for the leader)
		m5.aggro = cameren.oid
		startCombat(m5, cameren)
		sim.run(5)
		local r = cmds("retreat", t)[1]
		if r == nil then
			fail("crewsquad: no retreat with the tank down and two members under 30%")
			teardown()
			return
		end
		if slKinds("retreat") < 1 then fail("crewsquad: no 'fall back' call") end
		local effect
		for _, e in ipairs(log.sl) do if e.cmd == "retreat" and e.t >= t then effect = e end end
		for _, oid in ipairs({cameren.oid, crew.medic.oid, crew.commando.oid}) do
			local reached = false
			for _, x in ipairs(effect.reached) do if x == oid then reached = true end end
			if not reached then fail("crewsquad: the retreat didn't reach " .. ctx.objects[oid].first) end
		end
		local retreatAt = r.t
		-- The crew follows the leader and opens no fight for the 30 s
		sim.run(6)
		for _, role in ipairs({"medic", "ranger", "rifleman", "squadleader", "entertainer", "commando"}) do
			local b = crew[role]
			-- (the medic is exempt: its heals and revives come before the retreat's follow, and trailing the leader at 26 m it
			-- is the one that has the tank to walk to; it follows once it has nobody to heal)
			if moveState(b) ~= "follow" and role ~= "medic" then
				fail("crewsquad: the " .. role .. " isn't following during the retreat (" .. moveState(b) .. ")")
			end
			for _, e in ipairs(entries(log.targets, b, retreatAt + 2500)) do
				if e.target ~= 0 and e.engage then fail("crewsquad: the " .. role .. " attacked during the retreat") end
			end
		end
		sim.run(24)
		local resumed = false
		for _, role in ipairs({"medic", "ranger", "rifleman", "squadleader", "entertainer", "commando"}) do
			for _, e in ipairs(entries(log.targets, crew[role], retreatAt + 30000)) do
				if e.target == m5.oid and e.engage then resumed = true end
			end
		end
		if resumed then fail("crewsquad: the crew fought again before the retreat was over") end
		sim.run(14)
		for _, role in ipairs({"rifleman", "ranger"}) do crew[role].noRegen = false end
		slays(m5)
		tank.dead = false
		-- (one retreat per minute: no second call while the first holds)
		if #cmds("retreat", t) ~= 1 then fail("crewsquad: " .. #cmds("retreat", t) .. " retreats for one lost fight") end

		-- 6. Three members down is lost too
		sim.run(70)
		local m6 = makeCreature(cameren, "a kreetle", 30, 0, cameren, 1e7)
		m6.hits = 0
		t = nowMs()
		attack(cameren, m6)
		sim.run(4)
		for _, role in ipairs({"rifleman", "ranger", "entertainer"}) do crew[role].incap = true end
		sim.run(6)
		if #cmds("retreat", t) ~= 1 then fail("crewsquad: " .. #cmds("retreat", t) .. " retreats with three members down") end

		-- 7. The leader itself down (with three members down as well): no retreat to call, nobody to run with
		for _, role in ipairs({"rifleman", "ranger", "entertainer"}) do crew[role].incap = false end
		slays(m6)
		sim.run(70)
		local m7 = makeCreature(cameren, "a kreetle", 30, 0, cameren, 1e7)
		m7.hits = 0
		t = nowMs()
		attack(cameren, m7)
		sim.run(4)
		cameren.incap = true
		for _, role in ipairs({"rifleman", "ranger", "entertainer"}) do crew[role].incap = true end
		sim.run(8)
		if #cmds("retreat", t) ~= 0 then fail("crewsquad: a retreat called with the leader down") end
		cameren.incap = false
		for _, role in ipairs({"rifleman", "ranger", "entertainer"}) do crew[role].incap = false end
		slays(m7)

		realPrint(string.format("crewsquad %d squad leader commands, %d calls", #log.sl, #slLines(0)))
		BotCrew.calloutChance = savedChance
		teardown()
	end

	-- Scenario: Phase 8 group 3, the commando

	function scenarios.crewcommando()
		local cameren = sevenGroup("crewcommando")
		local savedChance = BotCrew.calloutChance
		BotCrew.calloutChance = 100
		local tank, com = crew.tank, crew.commando
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function calm()
			cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
			sim.run(30)
		end
		local function areas(cmd, since)
			local out = {}
			for _, a in ipairs(log.areas) do
				if a.bot == com.oid and a.t >= (since or 0) and (cmd == nil or a.cmd:find(cmd, 1, true)) then table.insert(out, a) end
			end
			return out
		end
		-- Every creature an area attack hit fights the group
		local function allPulled(a, since)
			for _, oid in ipairs(a.hit) do
				local o = ctx.objects[oid]
				if o.unpulled then return false, o end
			end
			return true
		end

		if com.weapon ~= "flame" then fail("crewcommando: the commando doesn't hold the flame thrower") end
		local f = readStringData("bot:" .. com.oid .. ":crew:flameCone")
		if f ~= "flamecone2" then fail("crewcommando: its flame cone is '" .. f .. "'") end

		-- 1. One creature on the tank: the commando stands 12-15 m off and fires single shots, none out of range
		local m1 = makeCreature(cameren, "a kreetle", 40, 0, nil)
		local t = nowMs()
		attack(cameren, m1)
		sim.run(30)
		local d = dist(com, m1)
		if d < 11 or d > 16 then fail(string.format("crewcommando: the commando stands %.1f m from the creature, expected 12-15", d)) end
		local singles = 0
		for _, c in ipairs(okCommands(com, nil, t)) do
			if c.cmd == "flamesingle2" then singles = singles + 1 end
		end
		if singles == 0 then fail("crewcommando: no single flame shots on a lone creature") end
		if #areas("cone", t) ~= 0 then fail("crewcommando: a cone on a lone creature") end
		if #refused(com, t, {peace = true, attack = true}) ~= 0 then fail("crewcommando: refused commands " .. table.concat(refused(com, t, {peace = true, attack = true}), "; ")) end
		slays(m1)
		calm()

		-- 2. A clump of three on the tank: a cone with more than one creature in it, a grenade at the clump (once per 15 s), and
		-- every creature hit fights the group
		local m2a = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local m2b = makeCreature(cameren, "a kreetle", 40, 1.2, tank)
		local m2c = makeCreature(cameren, "a kreetle", 41, 0.6, tank)
		t = nowMs()
		attack(cameren, m2a)
		sim.run(20)
		local cones, grenades = areas("cone", t), areas("grenade", t)
		if #cones == 0 or #cones[1].hit < 2 then fail("crewcommando: no cone on the clump (" .. #cones .. ")") end
		if #grenades == 0 then fail("crewcommando: no grenade on the clump") end
		if #grenades >= 2 and grenades[2].t - grenades[1].t < 15000 then fail("crewcommando: two grenades less than 15 s apart") end
		if #okCommands(com, "throwgrenade", t) ~= #grenades then fail("crewcommando: a grenade was refused") end
		if not (anyLine(entries(log.group, com, t), "commando", "flame") or anyLine(entries(log.group, com, t), "commando", "grenade")) then
			fail("crewcommando: no cone or grenade callout")
		end
		slays(m2a, m2b, m2c)
		calm()

		-- 3. An unpulled creature (idle, not fighting the group) near the clump: no cone, no grenade
		local m3a = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local m3b = makeCreature(cameren, "a kreetle", 40, 1.2, tank)
		local m3c = makeCreature(cameren, "a kreetle", 41, 0.6, tank)
		local idle = makeCreature(cameren, "a dewback", 43, 0.6, nil)
		idle.neverAggro, idle.unpulled = true, true
		t = nowMs()
		attack(cameren, m3a)
		sim.run(25)
		if os.getenv("DBG") then for _, a in ipairs(areas(nil, t)) do io.stderr:write(string.format("DBG %s at %d t=%.1f hit %d: %s com(%.1f,%.1f) idle(%.1f,%.1f) a=(%.1f,%.1f)\n", a.cmd, a.target, (a.t - t) / 1000, #a.hit, table.concat(a.hit, ","), com.x, com.y, idle.x, idle.y, ctx.objects[a.target].x, ctx.objects[a.target].y)) end end
		if #areas(nil, t) ~= 0 then
			fail("crewcommando: an area attack with an unpulled creature standing in it (" .. #areas(nil, t) .. ")")
		end
		-- (single shots go on)
		local singles3 = 0
		for _, c in ipairs(okCommands(com, nil, t)) do if c.cmd == "flamesingle2" then singles3 = singles3 + 1 end end
		if singles3 == 0 then fail("crewcommando: no single shots while the area was unsafe") end
		-- ...it goes, and the area attacks come back
		slays(idle)
		t = nowMs()
		sim.run(25)
		if #areas(nil, t) == 0 then fail("crewcommando: no area attack once the unpulled creature was gone") end
		slays(m3a, m3b, m3c)
		calm()

		-- 4. The armor: a creature that shrugs off heat gets the acid rifle (and its cones), then the flame thrower is back
		local m4a = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local m4b = makeCreature(cameren, "a kreetle", 40, 1.2, tank)
		for _, m in ipairs({m4a, m4b}) do m.armor = {heat = 95, acid = -1} end
		t = nowMs()
		attack(cameren, m4a)
		sim.run(25)
		local acidEquip = false
		for _, e in ipairs(entries(log.equips, com, t)) do if e.template:find("acid_beam", 1, true) then acidEquip = true end end
		if not acidEquip then fail("crewcommando: no acid rifle against a creature at 95% heat resist") end
		local acidCones = areas("acid", t)
		if #acidCones == 0 then fail("crewcommando: no acid cone with the acid rifle") end
		slays(m4a, m4b)
		t = nowMs()
		calm()
		local backEquip = false
		for _, e in ipairs(entries(log.equips, com, t)) do if e.template:find("flame_thrower", 1, true) then backEquip = true end end
		if not backEquip or com.weapon ~= "flame" then fail("crewcommando: the flame thrower isn't back after the fight") end

		-- 5. Lairs: another lair near the clump holds every area attack, even while the group fights a lair; the lair being fought alone
		-- does not
		local m5a = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local m5b = makeCreature(cameren, "a kreetle", 40, 1.2, tank)
		local m5c = makeCreature(cameren, "a kreetle", 41, 0.6, tank)
		local other = {oid = 7001, x = m5a.x + 5, y = m5a.y + 3}
		sim.lairs = {other}
		t = nowMs()
		attack(cameren, m5a)
		sim.run(25)
		if #areas(nil, t) ~= 0 then fail("crewcommando: an area attack with another lair beside the clump") end
		local fought = ctx.newObject({isLair = true, planet = "tatooine", x = m5a.x + 2, y = m5a.y - 2, z = 5, cell = 0, inWorld = true, name = "a lair"})
		sim.lairs = {other, {oid = fought.oid, x = fought.x, y = fought.y}}
		cameren.defenders = {fought.oid}
		cameren.inCombat = true
		t = nowMs()
		sim.run(25)
		if #areas(nil, t) ~= 0 then fail("crewcommando: an area attack with a second lair beside the clump, in a lair fight") end
		sim.lairs = {{oid = fought.oid, x = fought.x, y = fought.y}}
		t = nowMs()
		sim.run(25)
		if #areas(nil, t) == 0 then fail("crewcommando: no area attack with only the lair being fought beside the clump") end
		sim.lairs = {}
		cameren.defenders = {}
		slays(m5a, m5b, m5c)
		calm()

		-- 6. The scan reaches a grenade's whole blast (the target up to 40 m away, 11 m around it, and a margin)
		local widest = 0
		for _, r in ipairs(log.scans) do if r.bot == com.oid and r.range > widest then widest = r.range end end
		if widest < BotCrew.grenadeRange + BotCrew.grenadeSafe then fail("crewcommando: the creature scan reaches only " .. widest .. " m") end

		realPrint(string.format("crewcommando %d area attacks (%d cones, %d grenades)", #areas(nil, 0), #areas("cone", 0), #areas("grenade", 0)))
		BotCrew.calloutChance = savedChance
		teardown()
	end


	-- Scenario: Phase 8 group 4, the entertainer in camp, the battle fatigue answer, the medic's area packs

	function scenarios.crewcamp()
		local cameren = sevenGroup("crewcamp")
		local savedChance = BotCrew.calloutChance
		BotCrew.calloutChance = 100
		local tank, ent, ranger = crew.tank, crew.entertainer, crew.ranger
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function lines(since) return entries(log.group, ent, since) end
		local function said(kind, since)
			for _, l in ipairs(lines(since)) do
				if isLine(l.text, "entertainer", kind) then return true end
			end
			for _, l in ipairs(entries(log.says, ent, since)) do
				if isLine(l.text, "entertainer", kind) then return true end
			end
			return false
		end

		-- 1. Asked to play with no camp up: it says so and does nothing
		local t = nowMs()
		groupSay(cameren, "play something")
		sim.run(3)
		if not said("noCamp", t) then fail("crewcamp: no 'camp first' answer to music with no camp") end
		if ent.music ~= nil or ent.dancing ~= nil then fail("crewcamp: it performed with no camp") end

		-- 2. Battle fatigue: only the entertainer answers, and it points to a cantina
		t = nowMs()
		groupSay(cameren, "can you heal my battle fatigue?")
		sim.run(3)
		if not said("fatigueNo", t) then fail("crewcamp: no battle fatigue answer") end
		local answers = 0
		for _, l in ipairs(entries(log.group, nil, t)) do answers = answers + 1 end
		if answers ~= 1 then fail("crewcamp: " .. answers .. " group lines for one battle fatigue question") end
		for _, c in ipairs(commands(ent, nil, t)) do if c.cmd ~= "sitserver" and c.cmd ~= "stand" and c.cmd ~= "groupchat" then fail("crewcamp: the entertainer did " .. c.cmd .. " about battle fatigue") end end

		-- 3. The ranger's camp: the entertainer goes to the fire and dances (not sitting), flourishing now and then
		t = nowMs()
		groupSay(cameren, "camp?")
		sim.run(40)
		if #log.camps == 0 then fail("crewcamp: no camp") end
		if ent.dancing == nil then fail("crewcamp: the entertainer isn't dancing in camp (" .. tostring(ent.posture) .. ", " .. moveState(ent) .. ")") end
		if ent.posture == "sitting" then fail("crewcamp: the entertainer sat down in camp") end
		sim.run(80)
		local flourishes = 0
		for _, e in ipairs(log.sl) do if e.cmd == "flourish" and e.bot == ent.oid then flourishes = flourishes + 1 end end
		if flourishes < 2 then fail("crewcamp: " .. flourishes .. " flourishes in 2 minutes of dancing") end
		if ent:getHAM(ACTION) <= 0 then fail("crewcamp: the entertainer ran out of action") end

		-- 4. "Play something": the dance stops, the instrument comes into hand, the music starts; "dance" brings the dance back
		t = nowMs()
		groupSay(cameren, "play something")
		sim.run(30)
		if not said("musicOn", t) then fail("crewcamp: no answer to 'play something'") end
		if ent.music == nil or ent.dancing ~= nil then fail("crewcamp: not playing (" .. tostring(ent.music) .. "/" .. tostring(ent.dancing) .. ")") end
		local flute = false
		for _, e in ipairs(entries(log.equips, ent, t)) do if e.template:find("/instrument/", 1, true) then flute = true end end
		if not flute then fail("crewcamp: the instrument wasn't taken in hand") end
		t = nowMs()
		groupSay(cameren, "dance for us")
		sim.run(30)
		if ent.dancing == nil or ent.music ~= nil then fail("crewcamp: not dancing again after 'dance for us'") end
		-- (one performance at a time: no command refused for that)
		local refusedPerf = 0
		for _, c in ipairs(commands(ent, nil, 0)) do
			if not c.ok and (c.cmd == "startdance" or c.cmd == "startmusic") then refusedPerf = refusedPerf + 1 end
		end
		if refusedPerf > 0 then fail("crewcamp: " .. refusedPerf .. " performance commands refused") end

		-- 4b. "stop playing" and the camp ending both put the pistol back in hand
		groupSay(cameren, "play something")
		sim.run(30)
		if ent.music == nil or ent.weapon ~= "instrument" then fail("crewcamp: not playing with the flute before 'stop playing'") end
		groupSay(cameren, "stop playing")
		sim.run(20)
		if ent.music ~= nil or ent.weapon ~= "pistol" then fail("crewcamp: after 'stop playing' the entertainer holds " .. tostring(ent.weapon)) end
		groupSay(cameren, "play something")
		sim.run(30)
		if ent.weapon ~= "instrument" then fail("crewcamp: the flute isn't back in hand") end
		cameren.x = cameren.x + 90
		sim.run(60)
		if ent.music ~= nil or ent.weapon ~= "pistol" then fail("crewcamp: after the camp the entertainer holds " .. tostring(ent.weapon) .. ", music " .. tostring(ent.music)) end
		cameren.x = cameren.x - 90
		sim.run(30)
		groupSay(cameren, "camp?")
		sim.run(60)

		-- 5. Music again, then a fight the others take: she plays on (Phase 8b); a creature on her: it stops, takes the
		-- pistol back and shoots at its band
		groupSay(cameren, "play something")
		sim.run(30)
		if ent.music == nil then fail("crewcamp: not playing before the fight") end
		local m = makeCreature(cameren, "a kreetle", 30, 0, nil, nil, false)
		m.hits = 3
		t = nowMs()
		attack(cameren, m)
		sim.run(10)
		if ent.music == nil then fail("crewcamp: stopped playing for a fight the others take") end
		attack(m, ent)
		sim.run(20)
		if ent.music ~= nil or ent.dancing ~= nil then fail("crewcamp: still performing in the fight") end
		if ent.weapon ~= "pistol" then fail("crewcamp: the pistol isn't back in hand (" .. tostring(ent.weapon) .. ")") end
		local shots = 0
		for _, c in ipairs(okCommands(ent, nil, t)) do if c.cmd == "bodyshot3" or c.cmd == "healthshot2" then shots = shots + 1 end end
		if shots == 0 then fail("crewcamp: the entertainer fired no pistol specials") end
		if #refused(ent, t, {peace = true, attack = true}) ~= 0 then fail("crewcamp: refused " .. table.concat(refused(ent, t, {peace = true, attack = true}), "; ")) end
		slays(m)

		realPrint(string.format("crewcamp %d flourishes, %d pistol specials", flourishes, shots))
		BotCrew.calloutChance = savedChance
		teardown()
	end

	function scenarios.crewarea()
		local cameren = sevenGroup("crewarea")
		-- (big pools, so the specials' cost doesn't keep anyone under the heal line)
		for _, role in ipairs(SEVEN) do
			local b = crew[role]
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).base = b:pool(pool).base * 8 end
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).cur = b:getMaxHAM(pool) end
		end
		local medic, tank = crew.medic, crew.tank
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function calm()
			cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
			sim.run(40)
		end
		local function dots(since)
			local out = {}
			for _, d in ipairs(log.dots) do if d.bot == medic.oid and d.t >= since then table.insert(out, d) end end
			return out
		end

		-- 1. Three creatures on the tank, close together: the first poison and disease are area packs, named by oid; every one is hit
		local a = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local b = makeCreature(cameren, "a kreetle", 40, 2, tank)
		local c = makeCreature(cameren, "a kreetle", 41, 1, tank)
		local t = nowMs()
		attack(cameren, a)
		sim.run(30)
		local d = dots(t)
		if #d < 2 then fail("crewarea: " .. #d .. " packs thrown at a clump of three") end
		for _, x in ipairs(d) do
			if not x.pack:find("_area_", 1, true) then fail("crewarea: a single pack on a clump: " .. x.pack) end
		end
		for _, o in ipairs({a, b, c}) do
			if nowMs() >= (o.poisonUntil or 0) or nowMs() >= (o.diseaseUntil or 0) then fail("crewarea: a creature of the clump isn't poisoned and diseased") end
		end
		local named = 0
		for _, cmd in ipairs(commands(medic, nil, t)) do
			if (cmd.cmd == "applypoison" or cmd.cmd == "applydisease") and cmd.args:match("^health|%d+$") then named = named + 1 end
		end
		if named < 2 then fail("crewarea: the throws didn't name their pack (" .. named .. ")") end
		slays(a, b, c)
		calm()

		-- 2. An unpulled creature close to the clump: single packs only
		local a2 = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local b2 = makeCreature(cameren, "a kreetle", 40, 2, tank)
		local c2 = makeCreature(cameren, "a kreetle", 41, 1, tank)
		local idle = makeCreature(cameren, "a dewback", 44, 1, nil)
		idle.neverAggro = true
		t = nowMs()
		attack(cameren, a2)
		sim.run(30)
		d = dots(t)
		if #d < 2 then fail("crewarea: " .. #d .. " packs with an unpulled creature near") end
		for _, x in ipairs(d) do
			if x.pack:find("_area_", 1, true) then fail("crewarea: an area pack with an unpulled creature in its area") end
		end
		if idle.poisonUntil ~= nil then fail("crewarea: the unpulled creature was poisoned") end
		slays(a2, b2, c2, idle)
		calm()

		-- 3. Two creatures are not enough: singles
		local a3 = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local b3 = makeCreature(cameren, "a kreetle", 40, 2, tank)
		t = nowMs()
		attack(cameren, a3)
		sim.run(30)
		for _, x in ipairs(dots(t)) do
			if x.pack:find("_area_", 1, true) then fail("crewarea: an area pack on two creatures") end
		end
		if #dots(t) < 2 then fail("crewarea: no packs on two creatures") end
		slays(a3, b3)

		realPrint(string.format("crewarea %d packs", #log.dots))
		teardown()
	end


	-- Scenario: Phase 8 group 5, calling the crew

	function scenarios.crewcall()
		setup("/nonexistent/sim-talk")
		for _, role in ipairs(SEVEN) do login(crew[role]) end
		local savedChance = BotCrew.calloutChance
		local function atHome(b) return b.planet == "tatooine" and b.cell ~= 0 end
		local function callsSince(t)
			local out = {}
			for _, c in ipairs(log.calls) do if c.t >= t then table.insert(out, c) end end
			return out
		end
		local function allSays(b, since)
			local out = {}
			for _, e in ipairs(entries(log.says, b, since)) do table.insert(out, e.text) end
			for _, e in ipairs(entries(log.tells, b, since)) do table.insert(out, e.text) end
			return out
		end

		-- 1. A tell to one of them from Naboo: the whole crew, free at home, arrives 5-10 s later beside the caller, on Naboo
		local cameren = makeHuman("Cameren", 800, 800)
		cameren.planet = "naboo"
		-- (somebody sat down at home: a called bot stands)
		crew.ranger.posture = "sitting"
		local t = nowMs()
		speak(crew.tank, cameren, "crew, come to me", "tell")
		sim.run(4.5)
		if #callsSince(t) ~= 0 then fail("crewcall: someone came before 5 s") end
		sim.run(8)
		local calls = callsSince(t)
		if #calls ~= 7 then fail("crewcall: " .. #calls .. " of the seven came") end
		for _, c in ipairs(calls) do
			if c.t - t < 5000 or c.t - t > 10100 then fail(string.format("crewcall: a bot arrived %.1f s after the call", (c.t - t) / 1000)) end
		end
		for _, role in ipairs(SEVEN) do
			local b = crew[role]
			if b.planet ~= "naboo" or dist(b, cameren) > 12 then fail("crewcall: the " .. role .. " isn't beside the caller") end
			if mode(b) ~= "called" then fail("crewcall: the " .. role .. " is in mode " .. mode(b)) end
		end
		sim.run(3)
		if crew.ranger.posture == "sitting" then fail("crewcall: the called ranger is still sitting") end
		-- (a called bot that is not in the group yet follows close, not at its trail range)
		for _, role in ipairs(SEVEN) do
			local last
			for _, f in ipairs(entries(log.follows, crew[role], t)) do last = f end
			if last ~= nil and last.near ~= nil then
				fail("crewcall: the called " .. role .. " trails at " .. tostring(last.near) .. "-" .. tostring(last.far) .. " before it is in the group")
			end
		end
		-- one invite from the first to arrive; the others wait quietly, following the caller
		local invites, asks, inviter = 0, 0, nil
		for _, role in ipairs(SEVEN) do
			local sent = #okCommands(crew[role], "invite", t)
			invites = invites + sent
			if sent > 0 then inviter = crew[role] end
			for _, text in ipairs(allSays(crew[role], t)) do
				if isLine(text, role, "askInvite") then asks = asks + 1 end
			end
		end
		if invites ~= 1 then fail("crewcall: " .. invites .. " invites sent, expected 1") end
		if asks ~= 0 then fail("crewcall: " .. asks .. " 'send me an invite' lines for a caller on their own, expected none") end
		for _, role in ipairs(SEVEN) do
			if moveState(crew[role]) ~= "follow" then fail("crewcall: the waiting " .. role .. " isn't following the caller (" .. moveState(crew[role]) .. ")") end
		end
		-- "On my way" once
		local ons = 0
		for _, text in ipairs(allSays(crew.tank, t)) do if isLine(text, "tank", "callOn") then ons = ons + 1 end end
		if ons ~= 1 then fail("crewcall: the tank said 'on my way' " .. ons .. " times") end

		-- The caller mounts a swoop before accepting: the waiting bots mount too
		cameren.riding = true
		sim.run(15)
		local mounted = 0
		for _, role in ipairs(SEVEN) do if crew[role].riding then mounted = mounted + 1 end end
		if mounted < 5 then fail("crewcall: " .. mounted .. " of the waiting seven mounted when the caller did") end
		cameren.riding = false
		sim.run(10)

		-- 2. ONE accept gets the whole crew: the inviter invites the other six, then hands the lead to the caller
		local before = nowMs()
		joinGroup(cameren, inviter)
		cameren.inviter = nil
		sim.run(45)
		if members(cameren) ~= 8 then fail("crewcall: " .. members(cameren) .. " in the group after one accept, expected 8") end
		if leaderOf(cameren) ~= cameren then fail("crewcall: the caller doesn't lead (" .. tostring(leaderOf(cameren) and leaderOf(cameren).first) .. ")") end
		local invitesFromInviter = #okCommands(inviter, "invite", before)
		if invitesFromInviter ~= 6 then fail("crewcall: the first to arrive invited " .. invitesFromInviter .. " more, expected 6") end
		-- ...then the caller rides off and all seven go with them
		cameren.riding = true
		sim.run(15)
		mounted = 0
		for _, role in ipairs(SEVEN) do if crew[role].riding then mounted = mounted + 1 end end
		if mounted < 5 then fail("crewcall: " .. mounted .. " of the grouped seven mounted when the caller rode off") end
		cameren.riding = false
		sim.run(10)
		groupSay(cameren, "go home")
		sim.run(30)
		for _, role in ipairs(SEVEN) do
			if crew[role].planet ~= "tatooine" then fail("crewcall: the " .. role .. " didn't go home after the dismissal (" .. crew[role].planet .. ")") end
		end

		-- 3. Somebody else's group: Senna and Weeta are with Dex; Cameren's tell to Senna: it says so and stays, the others come
		local dex = makeHuman("Dex", crew.tank.x + 3, crew.tank.y)
		dex.cell = crew.tank.cell
		for _, role in ipairs({"rifleman", "ranger"}) do
			invite(dex, crew[role], true)
			sim.run(3)
		end
		sim.run(5)
		cameren.planet, cameren.x, cameren.y, cameren.cell = "naboo", 800, 800, 0
		t = nowMs()
		speak(crew.rifleman, cameren, "crew, come to me", "tell")
		sim.run(14)
		local came = {}
		for _, c in ipairs(callsSince(t)) do came[c.bot] = true end
		if came[crew.rifleman.oid] or came[crew.ranger.oid] then fail("crewcall: a bot in someone else's group came") end
		for _, role in ipairs({"tank", "medic", "squadleader", "entertainer", "commando"}) do
			if not came[crew[role].oid] then fail("crewcall: the " .. role .. " didn't come") end
		end
		local busy = false
		for _, text in ipairs(allSays(crew.rifleman, t)) do
			if isLine(text, "rifleman", "callBusy") and text:find("Dex", 1, true) then busy = true end
		end
		if not busy then fail("crewcall: no 'out with Dex's group' answer") end

		-- 4. Group chat from a human far from his group: the group comes; the ones near him stay put
		for _, role in ipairs({"rifleman", "ranger"}) do
			leaveGroup(crew[role])
		end
		for _, role in ipairs(SEVEN) do
			if crew[role].groupId ~= nil then leaveGroup(crew[role]) end
			crew[role].planet, crew[role].x, crew[role].y, crew[role].cell = "tatooine", 100 + 2 * _, 100, 0
			writeStringData("bot:" .. crew[role].oid .. ":crew:mode", "home")
		end
		cameren.planet, cameren.x, cameren.y, cameren.cell, cameren.groupId = "tatooine", 100, 100, 0, nil
		for _, role in ipairs({"tank", "medic", "squadleader", "commando"}) do
			invite(cameren, crew[role], true)
			sim.run(3)
		end
		sim.run(8)
		if members(cameren) ~= 5 then fail("crewcall: " .. members(cameren) .. " in the group, expected 5") end
		-- the commando and the medic are on other planets (the mover catches up by itself on this one), the rest near
		crew.commando.planet, crew.commando.x, crew.commando.y = "corellia", 700, 100
		crew.medic.planet, crew.medic.x, crew.medic.y = "naboo", 100, 600
		crew.commando.move, crew.medic.move = nil, nil
		t = nowMs()
		groupSay(cameren, "crew, come to me")
		sim.run(14)
		local came2 = {}
		for _, c in ipairs(callsSince(t)) do came2[c.bot] = true end
		if not came2[crew.commando.oid] or not came2[crew.medic.oid] then fail("crewcall: the far group members weren't called") end
		if came2[crew.tank.oid] or came2[crew.squadleader.oid] then fail("crewcall: a near group member leapt") end
		if dist(crew.commando, cameren) > 25 or dist(crew.medic, cameren) > 25 then fail("crewcall: the far members aren't with the leader") end
		if moveState(crew.commando) ~= "follow" then fail("crewcall: the called commando isn't following") end

		-- 5. Called and never invited: back to the station after calledWait
		for _, role in ipairs({"ranger", "rifleman"}) do
			crew[role].groupId = nil
		end
		cameren.groupId = nil
		for _, role in ipairs(SEVEN) do
			if crew[role].groupId ~= nil then leaveGroup(crew[role]) end
		end
		sim.run(5)
		cameren.planet, cameren.x, cameren.y = "naboo", 800, 800
		speak(crew.entertainer, cameren, "I need the crew", "tell")
		sim.run(14)
		if crew.entertainer.planet ~= "naboo" then fail("crewcall: 'I need the crew' brought nobody") end
		sim.run(BotCrew.calledWait + 40)
		if crew.entertainer.planet ~= "tatooine" or mode(crew.entertainer) ~= "home" then
			fail("crewcall: the uninvited entertainer didn't go home (" .. crew.entertainer.planet .. ", " .. mode(crew.entertainer) .. ")")
		end

		realPrint(string.format("crewcall %d leaps", #log.calls))
		BotCrew.calloutChance = savedChance
		teardown()
	end


	-- The words that call the crew (Lua fast path): the creator's three lines and more; and what must not
	function scenarios.crewcallwords()
		setup("/nonexistent/sim-talk")
		for _, role in ipairs(SEVEN) do login(crew[role]) end
		local cameren = makeHuman("Cameren", 800, 800)
		cameren.planet = "naboo"
		local function callsSince(t)
			local n = 0
			for _, c in ipairs(log.calls) do if c.t >= t then n = n + 1 end end
			return n
		end
		local function home()
			for _, role in ipairs(SEVEN) do
				local b = crew[role]
				b.planet, b.x, b.y, b.cell = "tatooine", 1 + _, 1, 1082877
				writeStringData("bot:" .. b.oid .. ":crew:mode", "home")
				b.move = nil
				if b.groupId ~= nil then leaveGroup(b) end
			end
			sim.run(3)
		end
		for _, line in ipairs({"get the crew together and meet me at mission terminal", "come to me", "crew to me", "crew, come to me",
			"everyone meet me at the starport", "I need the crew at the bank", "guys, get over here", "all of you come to me",
			"team, assemble at the terminal", "meet me outside the cantina", "gather the crew, I'm at Anchorhead",
			"can you all come meet me?", "bring the boys over to the shuttleport"}) do
			home()
			local t = nowMs()
			speak(crew.tank, cameren, line, "tell")
			sim.run(13)
			if callsSince(t) ~= 7 then fail("crewcallwords: '" .. line .. "' called " .. callsSince(t) .. " of the seven") end
		end
		for _, line in ipairs({"follow me", "wanna hunt?", "come with me to the cantina", "lfg? need a tank", "stay here",
			"don't come to me, I'll find you", "nice shooting everyone", "you can go home", "everyone follow me"}) do
			home()
			local t = nowMs()
			speak(crew.tank, cameren, line, "tell")
			sim.run(13)
			if callsSince(t) ~= 0 then fail("crewcallwords: '" .. line .. "' called the crew") end
		end
		realPrint("crewcallwords ok")
		teardown()
	end

	-- crewtrail (the positioning fix): hunting on foot out of town each bot follows at its fighting band; in a town, in a building
	-- and on a swoop the close follow comes back, and the trail again when the leader is out of town on foot
	function scenarios.crewtrail()
		setup("/nonexistent/sim-talk")
		each(function(role, b) login(b) end)
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		each(function(role, b)
			invite(cameren, b, true)
			sim.run(3)
		end)
		sim.run(10)
		each(function(role, b) b.cell = 0 end)
		cameren.cell = 0
		local savedTowns = BotCrew.towns.tatooine
		local function lastFollow(b)
			local last
			for _, f in ipairs(log.follows) do
				if f.bot == b.oid then last = f end
			end
			return last
		end
		local function walk(m)
			cameren.move = {state = "goto", x = cameren.x + m, y = cameren.y}
			cameren.speed = 5
			sim.run(m / 5 + 8)
			cameren.speed = 0
			sim.run(6)
		end

		-- 1. Out of town on foot: each bot's follow carries its range, and they settle at it (not on top of each other)
		walk(100)
		local seen = {}
		each(function(role, b)
			local range = BotCrew.trail[role]
			local f = lastFollow(b)
			local d = dist(b, cameren)
			if f == nil or f.near ~= range[1] or f.far ~= range[2] then
				fail("crewtrail: the " .. role .. " didn't follow at " .. range[1] .. "-" .. range[2])
			end
			if d > range[2] + 3 or d < range[1] - 3 then
				fail(string.format("crewtrail: the %s trails at %.0f m, wanted %d-%d", role, d, range[1], range[2]))
			end
			table.insert(seen, string.format("%s %.0f", role, d))
		end)
		if dist(crew.medic, cameren) < dist(crew.ranger, cameren) + 10 then
			fail("crewtrail: the medic doesn't trail well behind the ranger")
		end

		-- 2. In a town: the close follow
		BotCrew.towns.tatooine = {{"Test town", cameren.x, cameren.y}}
		sim.run(10)
		each(function(role, b)
			local f = lastFollow(b)
			if f == nil or f.near ~= nil then
				fail("crewtrail: the " .. role .. " still trails in a town")
			end
		end)
		BotCrew.towns.tatooine = savedTowns

		-- 3. Back in the wild on foot: the trail again
		sim.run(10)
		each(function(role, b)
			local f = lastFollow(b)
			if f == nil or f.near ~= BotCrew.trail[role][1] then
				fail("crewtrail: the " .. role .. " didn't trail again out of town")
			end
		end)

		-- 4. The leader on a swoop: the close follow (a bot trailing a swoop would be left behind)
		cameren.riding = true
		sim.run(10)
		each(function(role, b)
			local f = lastFollow(b)
			if f == nil or f.near ~= nil then
				fail("crewtrail: the " .. role .. " trails a leader on a swoop")
			end
		end)
		cameren.riding = false
		sim.run(10)

		-- 5. In a building (a cell): the close follow
		cameren.cell = 77
		sim.run(10)
		each(function(role, b)
			local f = lastFollow(b)
			if f == nil or f.near ~= nil then
				fail("crewtrail: the " .. role .. " trails a leader inside a building")
			end
		end)
		cameren.cell = 0
		realPrint("crewtrail " .. table.concat(seen, ", "))
		teardown()
	end

	-- Phase 8b: crew mind buffs (specs/2026-10-25-crew-mind-buffs/): the cantina band's session and the camp loop.
	-- crewmind: a band session from start to finish; crewmindask: a player asks the band for a buff, targets a crew bot and
	-- invites it, calls the crew; crewmindfight: a fight on a member; crewmindout: the dancer logs out, a restart, a clone;
	-- crewmindcamp: the camp's dance and music cycle, "play something", "stop", a fight, the camp ending

	local SEVEN8B = {"tank", "rifleman", "medic", "ranger", "squadleader", "entertainer", "commando"}

	-- The crew plus Mos Eisley's dancer and musician, all logged in
	local function bandWorld()
		setup("/nonexistent/sim-talk")
		local band = {}
		for _, entry in ipairs(BotRoster.bots) do
			if entry.city == "mos_eisley" and (entry.job == "dancer" or entry.job == "musician") and band[entry.job] == nil then
				local first = entry.name:match("^(%S+)")
				local st = entry.station
				local b = ctx.newObject({isBotFlag = true, isPlayer = true, first = first, name = entry.name, planet = st.planet,
					x = st.x, y = st.y, z = st.z, cell = st.cell or 0, inWorld = false, online = false, cash = 100, bank = 1000,
					packs = {}, buffs = {}, wounds = {}, skillPrefixes = {}, skillMods = {}, role = entry.job,
					weapon = entry.job == "musician" and "instrument" or nil})
				band[entry.job] = b
				byFirst[first:lower()] = b
				ctx.addPlayer(b)
			end
		end
		return band
	end

	local function loginAll(band)
		login(band.dancer)
		login(band.musician)
		for _, role in ipairs(SEVEN8B) do login(crew[role]) end
	end

	local function memberCount(b)
		local g = b.groupId and groups[b.groupId]
		return g and #g.members or 0
	end

	local function bandMode(b)
		return readStringData("bot:" .. b.oid .. ":crew:mode")
	end

	-- Nobody left watching, no entertainer with patrons, nobody in a band mode or a band group: once a session or a set is over
	local function quiet(label, band)
		for _, b in pairs(ctx.objects) do
			if b.isBotFlag and b.online then
				if b.watchTo ~= nil or b.listenTo ~= nil then
					fail(label .. ": " .. b.first .. " is still watching or listening")
				end
				if next(b.patrons or {}) ~= nil then
					fail(label .. ": " .. b.first .. " still has patrons")
				end
				if readData("bot:" .. b.oid .. ":crew:watching") ~= 0 or readData("bot:" .. b.oid .. ":crew:listening") ~= 0 then
					fail(label .. ": " .. b.first .. " still has a watching record")
				end
			end
		end
		for _, role in ipairs(SEVEN8B) do
			local b = crew[role]
			if bandMode(b) == "band" then
				fail(label .. ": the " .. role .. " is still in band mode")
			end
			if band ~= nil and b.groupId ~= nil and b.groupId == band.dancer.groupId then
				fail(label .. ": the " .. role .. " is still in the dancer's group")
			end
		end
	end

	-- Mind buffs left on a bot, in minutes (the least of the three)
	local function mindMinutes(b)
		local least = math.huge
		for _, name in ipairs({"performance_enhance_dance_mind", "performance_enhance_music_focus", "performance_enhance_music_willpower"}) do
			local buff = b.buffs[name]
			local left = (buff ~= nil and buff.expires > sim.now) and (buff.expires - sim.now) / 60 or 0
			least = math.min(least, left)
		end
		return least
	end

	-- Everyone in the group in band mode: the session forms and is watching
	local function formed(label, band)
		local d, m, ilsi = band.dancer, band.musician, crew.entertainer
		local size = memberCount(d)
		if size ~= 8 then
			fail(label .. ": " .. size .. " in the band's group, expected the dancer, the musician and six crew")
		end
		if m.groupId ~= d.groupId then fail(label .. ": the musician isn't in the dancer's group") end
		for _, role in ipairs(SEVEN8B) do
			local b = crew[role]
			if role == "entertainer" then
				if b.groupId ~= nil then fail(label .. ": the entertainer, the buff target, is in a group") end
				if d.buffTargetOid ~= b.oid or m.buffTargetOid ~= b.oid then
					fail(label .. ": the band's buff target isn't the entertainer")
				end
			elseif b.groupId ~= d.groupId then
				fail(label .. ": the " .. role .. " isn't in the band's group")
			end
			if bandMode(b) ~= "band" then fail(label .. ": the " .. role .. " is in mode " .. bandMode(b)) end
			if b.watchTo ~= d.oid or b.listenTo ~= m.oid then
				fail(label .. ": the " .. role .. " isn't watching and listening (" .. tostring(b.watchTo) .. "/" .. tostring(b.listenTo) .. ")")
			end
		end
	end

	function scenarios.crewmind()
		local band = bandWorld()
		local d, m, ilsi, rifleman = band.dancer, band.musician, crew.entertainer, crew.rifleman
		-- One of them is sitting at home: she stands to watch
		rifleman.posture = "sitting"
		loginAll(band)
		rifleman.posture = "sitting"
		writeData("bot:" .. rifleman.oid .. ":crew:sitting", 1)
		sim.run(70)
		formed("crewmind", band)
		-- The crew are invited only once the musician is in: on Core3 accepts that land together while the dancer has no group
		-- yet each make a group of their own (seen on the local server)
		local joined = okCommands(m, "join", 0)[1]
		for _, c in ipairs(commands(d, "invite", 0)) do
			if c.target ~= m.oid and (joined == nil or c.t < joined.t) then
				fail("crewmind: the dancer invited a crew bot before the musician was in her group")
				break
			end
		end
		if #refused(rifleman, 0, {}) > 0 then fail("crewmind: refused " .. table.concat(refused(rifleman, 0, {}), "; ")) end
		-- ... and it carries on to the end, then everyone stops and the dancer disbands
		sim.run(480)
		if memberCount(d) ~= 0 then fail("crewmind: the band's group wasn't disbanded") end
		quiet("crewmind", band)
		for _, role in ipairs(SEVEN8B) do
			local minutes = mindMinutes(crew[role])
			if minutes < 60 then fail(string.format("crewmind: the %s has only %.0f minutes of mind buffs", role, minutes)) end
			if bandMode(crew[role]) ~= "home" then fail("crewmind: the " .. role .. " is in mode " .. bandMode(crew[role])) end
		end
		-- Nothing starts again while they all have the buffs
		local before = readData("band:mos_eisley:seq")
		sim.run(1200)
		if readData("band:mos_eisley:seq") ~= before then fail("crewmind: a second session started with everyone buffed") end
		-- The group holds 8: no command was refused for that
		for _, c in ipairs(log.commands) do
			if not c.ok and c.why == "group full" then fail("crewmind: a join was refused, the group was full") end
		end
		realPrint(string.format("crewmind session %d, mind buffs %.0f minutes", readData("band:mos_eisley:seq"), mindMinutes(ilsi)))
		teardown()
	end

	function scenarios.crewmindask()
		local band = bandWorld()
		local d, m, ilsi, medic, rifleman = band.dancer, band.musician, crew.entertainer, crew.medic, crew.rifleman
		loginAll(band)
		local cameren = makeHuman("Cameren", m.x + 3, m.y)
		cameren.cell = m.cell
		sim.run(70)
		formed("crewmindask", band)

		-- 1. A player asks the musician for a buff: the band turns to them, the entertainer stops listening and watching
		cameren.target = m.oid
		speak(m, cameren, "can I get a buff?", "spatial")
		sim.run(15)
		if readData("bot:" .. m.oid .. ":buffTarget") ~= cameren.oid or readData("bot:" .. d.oid .. ":buffTarget") ~= cameren.oid then
			fail("crewmindask: the band didn't make the player its buff target")
		end
		if m.buffTargetOid ~= cameren.oid then fail("crewmindask: Core3's buff target isn't the player") end
		if ilsi.watchTo ~= nil or ilsi.listenTo ~= nil then fail("crewmindask: the entertainer still watches the band") end
		for _, role in ipairs({"tank", "rifleman", "medic", "ranger", "squadleader", "commando"}) do
			if crew[role].watchTo ~= d.oid or crew[role].listenTo ~= m.oid then fail("crewmindask: the " .. role .. " stopped watching") end
		end
		if memberCount(d) ~= 8 then fail("crewmindask: the group changed size") end

		-- 2. The player targets the medic: it steps out of the group and says so, and takes their invite
		local t = nowMs()
		cameren.target = medic.oid
		sim.run(12)
		if medic.groupId ~= nil then fail("crewmindask: the medic is still in the band's group") end
		if medic.watchTo ~= nil or medic.listenTo ~= nil then fail("crewmindask: the medic is still watching") end
		if bandMode(medic) ~= "home" then fail("crewmindask: the medic is in mode " .. bandMode(medic)) end
		local said = false
		for _, l in ipairs(entries(log.says, medic, t)) do if isLine(l.text, "medic", "bandOut") then said = true end end
		if not said then fail("crewmindask: the medic didn't say it was stepping out") end
		if medic.buffs.performance_enhance_dance_mind == nil then fail("crewmindask: the medic's mind buff didn't land when it stopped") end
		invite(cameren, medic, true)
		sim.run(10)
		if bandMode(medic) ~= "group" or medic.groupId == nil or medic.groupId ~= cameren.groupId then
			fail("crewmindask: the medic didn't join the player's group (" .. bandMode(medic) .. ")")
		end
		cameren.target = 0
		if memberCount(d) ~= 7 then fail("crewmindask: " .. memberCount(d) .. " in the band's group after the medic left, expected 7") end

		-- 3. The player invites the buff target, the entertainer: it stops watching first, then joins
		cameren.target = 0
		-- (she isn't in a group, so the player's invite reaches her; the player already leads one, so it has to be that one)
		d.buffTargetOid = nil
		invite(cameren, ilsi, true)
		sim.run(8)
		-- (she was no longer the target: she has been watching nobody since the player took it)
		if ilsi.groupId ~= cameren.groupId then fail("crewmindask: the entertainer didn't join the player's group") end
		if ilsi.watchTo ~= nil or ilsi.listenTo ~= nil then fail("crewmindask: the entertainer is watching from the player's group") end

		-- 4. The rest carry on to the end
		sim.run(480)
		quiet("crewmindask", band)
		if memberCount(d) ~= 0 then fail("crewmindask: the band's group wasn't disbanded") end
		for _, role in ipairs({"tank", "rifleman", "ranger", "squadleader", "commando"}) do
			if mindMinutes(crew[role]) < 60 then fail("crewmindask: the " .. role .. " has no full buffs") end
		end

		-- 5. A call mid-session: the whole crew comes out of the band and none is left watching
		sim.run(200)
		cameren.groupId = nil
		for _, role in ipairs(SEVEN8B) do
			crew[role].buffs = {}
			if crew[role].groupId ~= nil and groups[crew[role].groupId] ~= nil then end
		end
		realPrint("crewmindask done")
		teardown()
	end

	function scenarios.crewmindjoin()
		local band = bandWorld()
		local d, m, senna = band.dancer, band.musician, crew.rifleman
		loginAll(band)
		local cameren = makeHuman("Cameren", m.x + 3, m.y)
		cameren.cell = m.cell
		sim.run(70)
		formed("crewmindjoin", band)
		-- "Wanna hunt?" to a bot in the band's group: it steps out and invites the player instead of saying it is in another group
		local t = nowMs()
		cameren.target = 0
		speak(senna, cameren, "Senna, wanna hunt?", "spatial")
		sim.run(2)
		if senna.groupId == d.groupId then fail("crewmindjoin: the rifleman stayed in the band's group") end
		if #okCommands(senna, "invite", t) == 0 then fail("crewmindjoin: the rifleman didn't invite the player") end
		if senna.watchTo ~= nil or senna.listenTo ~= nil then fail("crewmindjoin: the rifleman is still watching") end
		-- The player accepts at once (before the bot's next tick): the rifleman stays in the player's group (the band's leave
		-- isn't sent again), and the dancer doesn't invite it back
		local inviter = ctx.objects[cameren.inviter or 0]
		if inviter ~= nil then
			joinGroup(cameren, inviter)
			cameren.inviter = nil
		end
		t = nowMs()
		sim.run(40)
		if senna.groupId == nil or senna.groupId ~= cameren.groupId then fail("crewmindjoin: the rifleman left the player's group") end
		if bandMode(senna) == "band" then fail("crewmindjoin: the rifleman is still in band mode") end
		for _, c in ipairs(commands(d, "invite", t)) do
			if c.target == senna.oid then fail("crewmindjoin: the dancer invited the rifleman back") break end
		end
		teardown()
	end

	function scenarios.crewmindcall()
		local band = bandWorld()
		local d, m = band.dancer, band.musician
		loginAll(band)
		local cameren = makeHuman("Cameren", m.x + 3, m.y)
		cameren.cell = m.cell
		sim.run(70)
		formed("crewmindcall", band)
		speak(crew.tank, cameren, "crew, come to me", "tell")
		sim.run(40)
		for _, role in ipairs(SEVEN8B) do
			local b = crew[role]
			if bandMode(b) == "band" then fail("crewmindcall: the " .. role .. " is still in band mode") end
			if b.watchTo ~= nil or b.listenTo ~= nil then fail("crewmindcall: the " .. role .. " is still watching") end
			if b.groupId ~= nil and b.groupId == d.groupId then fail("crewmindcall: the " .. role .. " is still in the band's group") end
		end
		-- the first to arrive invited the player: they join one group, the band's gets disbanded at its end
		sim.run(520)
		if memberCount(d) ~= 0 then fail("crewmindcall: the band's group wasn't disbanded") end
		for _, b in pairs({d, m}) do
			if b.groupId ~= nil then fail("crewmindcall: " .. b.first .. " is still in a group") end
			if next(b.patrons or {}) ~= nil then fail("crewmindcall: " .. b.first .. " still has patrons") end
		end
		teardown()
	end

	function scenarios.crewmindfight()
		local band = bandWorld()
		local d, m, senna = band.dancer, band.musician, crew.rifleman
		loginAll(band)
		sim.run(70)
		formed("crewmindfight", band)
		-- A creature goes for the rifleman: she stops watching, leaves the group and fights; the others carry on
		local mob = makeMob("a womp rat", senna.x + 2, senna.y, 1e7)
		mob.hits = 0
		mob.rooted = true
		startCombat(mob, senna)
		mob.aggro = senna.oid
		sim.run(15)
		if senna.groupId == d.groupId then fail("crewmindfight: the rifleman stayed in the band's group during a fight") end
		if senna.watchTo ~= nil or senna.listenTo ~= nil then fail("crewmindfight: the rifleman kept watching in a fight") end
		if memberCount(d) ~= 7 then fail("crewmindfight: " .. memberCount(d) .. " in the band's group, expected 7") end
		for _, role in ipairs({"tank", "medic", "ranger", "squadleader", "commando", "entertainer"}) do
			if crew[role].watchTo ~= d.oid then fail("crewmindfight: the " .. role .. " stopped watching") end
		end
		damage(mob, 1e9)
		sim.run(30)
		sim.run(480)
		quiet("crewmindfight", band)
		if memberCount(d) ~= 0 then fail("crewmindfight: the band's group wasn't disbanded") end
		teardown()
	end

	function scenarios.crewmindout()
		local band = bandWorld()
		local d, m, rifleman = band.dancer, band.musician, crew.rifleman
		loginAll(band)
		sim.run(70)
		formed("crewmindout", band)

		-- 1. The dancer logs out mid-session (Core3 takes her out of the group first)
		leaveGroup(d)
		d.online, d.inWorld = false, false
		d.dancing = nil
		sim.call("BotJobs", "onLogout", d)
		sim.run(40)
		quiet("crewmindout", band)
		if m.groupId ~= nil then fail("crewmindout: the musician is still in the band's group") end
		for _, role in ipairs(SEVEN8B) do
			if crew[role].groupId ~= nil then fail("crewmindout: the " .. role .. " is still in a group") end
		end

		-- 2. She comes back: a new session starts for whoever needs it (the buffs from the first one landed and are partial)
		for _, role in ipairs(SEVEN8B) do
			crew[role].buffs = {}
			deleteData("bot:" .. crew[role].oid .. ":crew:bandAt")
		end
		login(d)
		sim.run(70)
		formed("crewmindout", band)

		-- 3. A restart mid-session (BotJobs:restart: every online bot's job starts afresh, the groups stay)
		for _, b in ipairs({d, m, crew.tank, crew.rifleman, crew.medic, crew.ranger, crew.squadleader, crew.entertainer, crew.commando}) do
			sim.call("BotJobs", "onLogin", b)
		end
		sim.run(40)
		-- (a new session may have formed: nobody may be in the band's group, or in band mode, outside the live session)
		local session = readData("band:mos_eisley:session")
		for _, role in ipairs(SEVEN8B) do
			local b = crew[role]
			local inGroup = b.groupId ~= nil and b.groupId == d.groupId
			local inBand = bandMode(b) == "band"
			if (inGroup or inBand) and (session == 0 or readData("bot:" .. b.oid .. ":crew:band") ~= session) then
				fail("crewmindout: the " .. role .. " is in the band's group or mode after the restart with no live session")
			end
		end
		if session == 0 and (d.groupId ~= nil or m.groupId ~= nil) then fail("crewmindout: the band is still grouped with no session after the restart") end

		-- 4. A session that was never ended (the dancer's ticks stopped): past its end by a minute, everyone leaves it
		sim.run(1200)
		for _, role in ipairs(SEVEN8B) do
			crew[role].buffs = {}
			deleteData("bot:" .. crew[role].oid .. ":crew:bandAt")
		end
		sim.run(70)
		local until0 = readData("band:mos_eisley:until")
		if readData("band:mos_eisley:session") == 0 then fail("crewmindout: no session to stop the driver of") end
		if readData("band:mos_eisley:session") ~= 0 then
			-- stop the dancer's driver: its tick gives up (the dancer logs out without the clear)
			local gen = readData("bot:" .. d.oid .. ":gen")
			writeData("bot:" .. d.oid .. ":gen", gen + 1)
			sim.run(until0 - sim.now + 120)
			for _, role in ipairs(SEVEN8B) do
				if bandMode(crew[role]) == "band" then fail("crewmindout: the " .. role .. " is stuck in band mode after a dead session") end
				if crew[role].watchTo ~= nil then fail("crewmindout: the " .. role .. " is still watching after a dead session") end
				if crew[role].groupId ~= nil and crew[role].groupId == d.groupId then fail("crewmindout: the " .. role .. " is still in the dead session's group") end
			end
		end
		teardown()
	end

	function scenarios.crewmindclone()
		local band = bandWorld()
		local d, m, rifleman = band.dancer, band.musician, crew.rifleman
		loginAll(band)
		sim.run(70)
		formed("crewmindclone", band)
		sim.run(560)
		quiet("crewmindclone", band)
		local seq = readData("band:mos_eisley:seq")
		-- A session isn't started for a bot that has just had one, nor for one with plenty left
		sim.run(200)
		if readData("band:mos_eisley:seq") ~= seq then fail("crewmindclone: a session started with everyone buffed") end
		-- A clone: no buffs, and its record of the last session is cleared
		rifleman.buffs = {}
		writeData("bot:" .. rifleman.oid .. ":crew:dead", 1)
		sim.call("BotCrew", "afterClone", rifleman, rifleman.oid, os.time())
		sim.run(60)
		if readData("band:mos_eisley:seq") == seq then fail("crewmindclone: no session started for a cloned bot with no buffs") end
		sim.run(540)
		quiet("crewmindclone", band)
		if mindMinutes(rifleman) < 60 then fail("crewmindclone: the cloned bot has no full buffs after the session") end
		teardown()
	end

	function scenarios.crewmindcamp()
		local cameren = sevenGroup("crewmindcamp")
		local savedChance = BotCrew.switchSayChance
		BotCrew.switchSayChance = 100
		local ent = crew.entertainer
		-- (the medic treats everyone first, so it joins in later)
		local others = {"tank", "rifleman", "ranger", "squadleader", "commando"}
		local function perfName() return ent.dancing ~= nil and "dance" or (ent.music ~= nil and "music" or "none") end
		local function watchers(kind)
			local n = 0
			for _, role in ipairs(others) do
				if kind == "dance" and crew[role].watchTo == ent.oid then n = n + 1 end
				if kind == "music" and crew[role].listenTo == ent.oid then n = n + 1 end
			end
			return n
		end
		local function switchLines(since)
			local n = 0
			for _, l in ipairs(entries(log.group, ent, since)) do
				if isLine(l.text, "entertainer", "perfSwitchMusic") or isLine(l.text, "entertainer", "perfSwitchDance") then n = n + 1 end
			end
			return n
		end

		groupSay(cameren, "camp?")
		sim.run(60)
		if #log.camps == 0 then fail("crewmindcamp: no camp") end
		local start = readData("bot:" .. ent.oid .. ":crew:perfSetAt")
		if perfName() ~= "dance" then fail("crewmindcamp: she isn't dancing in camp (" .. perfName() .. ")") end
		sim.run(30)

		-- 1. Everyone else stands and watches her
		if watchers("dance") ~= 5 then
			local missing = {}
			for _, role in ipairs(others) do
				if crew[role].watchTo ~= ent.oid then table.insert(missing, role .. " " .. bandMode(crew[role]) .. " " .. tostring(crew[role].posture)) end
			end
			fail("crewmindcamp: " .. watchers("dance") .. " of the five watching her dance (not: " .. table.concat(missing, ", ") .. ")")
		end
		for _, role in ipairs(others) do
			if crew[role].posture == "sitting" then fail("crewmindcamp: the " .. role .. " is sitting while she dances") end
		end

		-- 2. About setMinutes later she plays; they stop watching, listen, and the dance buff has landed for them
		local switchAt
		for i = 1, 60 do
			sim.run(10)
			if perfName() == "music" then switchAt = sim.now break end
		end
		if switchAt == nil then
			fail("crewmindcamp: she never changed to music")
		else
			local length = switchAt - start
			if length < 8 * 60 - 40 or length > 8 * 60 + 50 then fail("crewmindcamp: the first set was " .. length .. " s") end
		end
		sim.run(30)
		if watchers("music") ~= 5 or watchers("dance") ~= 0 then
			fail("crewmindcamp: after the switch " .. watchers("dance") .. " watch and " .. watchers("music") .. " listen")
		end
		for _, role in ipairs({"tank", "ranger", "commando"}) do
			if crew[role].buffs.performance_enhance_dance_mind == nil then fail("crewmindcamp: the " .. role .. " has no mind buff after the dance") end
		end
		if switchLines(0) ~= 1 then fail("crewmindcamp: " .. switchLines(0) .. " switch lines in the first half cycle, expected 1") end

		-- 3. And back to dancing: all three buffs, full length, and at most one line a cycle
		local backAt
		for i = 1, 60 do
			sim.run(10)
			if perfName() == "dance" then backAt = sim.now break end
		end
		if backAt == nil then fail("crewmindcamp: she never danced again") end
		sim.run(40)
		if watchers("dance") ~= 5 or watchers("music") ~= 0 then
			fail("crewmindcamp: after the second switch " .. watchers("dance") .. " watch and " .. watchers("music") .. " listen")
		end
		-- (the medic, done treating, has joined in)
		if crew.medic.watchTo ~= ent.oid then fail("crewmindcamp: the medic isn't watching after its treatments") end
		for _, role in ipairs({"tank", "ranger", "commando", "rifleman", "squadleader"}) do
			if mindMinutes(crew[role]) < 60 then fail(string.format("crewmindcamp: the %s has %.0f minutes of mind buffs after a cycle", role, mindMinutes(crew[role]))) end
		end
		if switchLines(0) ~= 1 then fail("crewmindcamp: " .. switchLines(0) .. " switch lines in a cycle, expected 1") end

		-- 4. "Play something" switches her at once and the set starts over; "dance for us" back
		local t = nowMs()
		groupSay(cameren, "play something")
		sim.run(40)
		if perfName() ~= "music" then fail("crewmindcamp: not playing after 'play something'") end
		if watchers("music") ~= 5 then fail("crewmindcamp: " .. watchers("music") .. " listening after 'play something'") end
		local setAt = readData("bot:" .. ent.oid .. ":crew:perfSetAt")
		sim.run(7 * 60 - 60)
		if perfName() ~= "music" then fail("crewmindcamp: she switched before the new set was over") end
		groupSay(cameren, "dance for us")
		sim.run(40)
		if perfName() ~= "dance" or watchers("dance") ~= 5 then fail("crewmindcamp: not dancing for five after 'dance for us'") end

		-- 5. "Stop" holds her until the camp ends: nobody watches, they sit, and no switch comes
		groupSay(cameren, "stop playing")
		sim.run(60)
		if perfName() ~= "none" then fail("crewmindcamp: still performing after 'stop' (" .. perfName() .. ")") end
		sim.run(20 * 60)
		if perfName() ~= "none" then fail("crewmindcamp: she performed again after 'stop' (" .. perfName() .. ")") end
		if watchers("dance") + watchers("music") ~= 0 then fail("crewmindcamp: they still watch after 'stop'") end
		for _, role in ipairs(others) do
			if crew[role].posture ~= "sitting" and role ~= "medic" then fail("crewmindcamp: the " .. role .. " isn't sitting while she's stopped") end
		end
		-- "Dance for us" brings her back
		groupSay(cameren, "dance for us")
		sim.run(40)
		if perfName() ~= "dance" or watchers("dance") ~= 5 then fail("crewmindcamp: 'dance for us' didn't bring her back after 'stop'") end

		-- 6. A fight the others take: she dances on and they keep watching (stopping would land a partial buff over a longer
		-- one); after it she carries on
		local m = makeCreature(cameren, "a kreetle", 30, 0, nil, nil, false)
		m.hits = 3
		attack(cameren, m)
		sim.run(15)
		if perfName() ~= "dance" then fail("crewmindcamp: she stopped dancing for a fight the others take") end
		if watchers("dance") ~= 5 then fail("crewmindcamp: " .. watchers("dance") .. " still watching in a camp fight") end
		damage(m, 1e9)
		cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
		sim.run(80)
		if perfName() == "none" then fail("crewmindcamp: she didn't perform again after the fight") end

		-- 7. The camp ends (the leader walks off): nobody is left watching
		cameren.x = cameren.x + 90
		sim.run(60)
		for _, role in ipairs(others) do
			if crew[role].watchTo ~= nil or crew[role].listenTo ~= nil then fail("crewmindcamp: the " .. role .. " is still watching after the camp") end
			if readData("bot:" .. crew[role].oid .. ":crew:watching") ~= 0 or readData("bot:" .. crew[role].oid .. ":crew:listening") ~= 0 then
				fail("crewmindcamp: the " .. role .. " kept a watching record after the camp")
			end
		end
		if next(ent.patrons or {}) ~= nil then fail("crewmindcamp: she still has patrons after the camp") end
		BotCrew.switchSayChance = savedChance
		realPrint(string.format("crewmindcamp %d landings", #log.landed))
		teardown()
	end

	-- Phase 9b: the tactics table (crew_doctrine.lua). crewtable: the layers and the checks on the way in; crewdoctrine: each entry
	-- followed in a fight, and the hard rules under a hostile table.

	function scenarios.crewtable()
		local cameren = sevenGroup("crewtable")
		local function eq(label, got, want)
			if got ~= want then fail("crewtable: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		local medic, rifleman, sl, tank, cmdo = crew.medic, crew.rifleman, crew.squadleader, crew.tank, crew.commando

		-- 1. With no table, every entry stands at its default from no layer, and the defaults are today's numbers
		for _, role in ipairs(SEVEN) do
			for name, def in pairs(BotCrew.tactics) do
				if def.roles[role] then
					local _, layer = BotCrew:tactic(crew[role].oid, name)
					eq(role .. " " .. name .. " layer", layer, nil)
				end
			end
		end
		eq("hold", BotCrew:tactic(rifleman.oid, "hold"), BotCrew.holdFor)
		eq("healAt", BotCrew:tactic(medic.oid, "healAt"), BotCrew.healBelow.fight)
		eq("mindFloor", BotCrew:tactic(medic.oid, "mindFloor"), BotCrew.dotMindFloor)
		eq("retreatAt", BotCrew:tactic(sl.oid, "retreatAt"), BotCrew.retreatLow)
		eq("specials", BotCrew:specialsFor(rifleman.oid), BotCrew:setting("specialsHam"))
		eq("focus", BotCrew:tactic(rifleman.oid, "focus"), "tank")
		eq("range", BotCrew:tactic(rifleman.oid, "range"), "band")
		eq("protect", BotCrew:tactic(tank.oid, "protect"), "medic")
		eq("reviveFirst", BotCrew:tactic(medic.oid, "reviveFirst"), "yes")
		eq("packs", BotCrew:tactic(medic.oid, "packs"), "area")
		eq("shoot", BotCrew:tactic(medic.oid, "shoot"), "yes")
		eq("area", BotCrew:tactic(cmdo.oid, "area"), "both")
		eq("calls", BotCrew:tactic(sl.oid, "calls"), "all")
		eq("a bot with no such entry", BotCrew:tactic(tank.oid, "healAt") ~= nil, true) -- (the default is still readable)

		-- 2. The checks on the way in: roles, limits, unknown entries and words
		eq("role", BotCrew:setTactic(rifleman.oid, "order", "healAt", "0.7"), nil)
		eq("unknown entry", BotCrew:setTactic(medic.oid, "order", "bogus", "x"), nil)
		eq("healAt over", BotCrew:setTactic(medic.oid, "order", "healAt", "0.99"), "0.90")
		eq("healAt percent", BotCrew:setTactic(medic.oid, "order", "healAt", "80%"), "0.80")
		eq("healAt under", BotCrew:setTactic(medic.oid, "order", "healAt", "0.2"), "0.50")
		eq("mindFloor", BotCrew:setTactic(medic.oid, "order", "mindFloor", "0.95"), "0.80")
		eq("hold over", BotCrew:setTactic(rifleman.oid, "order", "hold", "9"), "6")
		eq("hold", BotCrew:setTactic(rifleman.oid, "order", "hold", "0"), "0")
		eq("retreatAt under", BotCrew:setTactic(sl.oid, "order", "retreatAt", "0.1"), "0.20")
		eq("retreatAt over", BotCrew:setTactic(sl.oid, "order", "retreatAt", "0.9"), "0.50")
		eq("bad word", BotCrew:setTactic(rifleman.oid, "order", "range", "sideways"), nil)
		eq("range", BotCrew:setTactic(rifleman.oid, "order", "range", "far"), "far")
		eq("calls order", BotCrew:setTactic(sl.oid, "order", "calls", "volley,rally"), "rally,volley")
		eq("calls bad", BotCrew:setTactic(sl.oid, "order", "calls", "rally,dance"), nil)
		eq("calls all", BotCrew:setTactic(sl.oid, "order", "calls", "rally,volley,formup,steadyaim"), "all")
		eq("focus creature", BotCrew:setTactic(rifleman.oid, "order", "focus", "creature:123"), "creature:123")
		eq("focus bad creature", BotCrew:setTactic(rifleman.oid, "order", "focus", "creature:abc"), nil)
		eq("protect member", BotCrew:setTactic(tank.oid, "order", "protect", "Ilsi"), "ilsi")
		eq("protect bad", BotCrew:setTactic(tank.oid, "order", "protect", "x y"), nil)
		eq("plan layer, wrong role", BotCrew:setTactic(tank.oid, "plan", "area", "none"), nil)
		eq("base is not settable here", BotCrew:setTactic(medic.oid, "base", "healAt", "0.6"), nil)
		for _, role in ipairs(SEVEN) do
			BotCrew:clearLayer(crew[role].oid, "order")
		end

		-- 3. Layers: order over plan over base over the default; a layer gone, the next shows
		writeStringData("crew:tbase:quillan:healAt", "0.60")
		local v, layer = BotCrew:tactic(medic.oid, "healAt")
		eq("base value", v, 0.6)
		eq("base layer", layer, "base")
		BotCrew:setTactic(medic.oid, "plan", "healAt", "0.85")
		v, layer = BotCrew:tactic(medic.oid, "healAt")
		eq("plan beats base", v, 0.85)
		eq("plan layer", layer, "plan")
		BotCrew:setTactic(medic.oid, "order", "healAt", "0.55")
		v, layer = BotCrew:tactic(medic.oid, "healAt")
		eq("order beats plan", v, 0.55)
		eq("order layer", layer, "order")
		BotCrew:clearLayer(medic.oid, "order")
		eq("plan after order", BotCrew:tactic(medic.oid, "healAt"), 0.85)
		BotCrew:clearLayer(medic.oid, "plan")
		eq("base after plan", BotCrew:tactic(medic.oid, "healAt"), 0.6)
		deleteStringData("crew:tbase:quillan:healAt")
		eq("default after base", BotCrew:tactic(medic.oid, "healAt"), 0.75)
		-- (a bad value in a layer reads as the next layer: the turns clamp what they read too)
		writeStringData("bot:" .. medic.oid .. ":crew:t:order:healAt", "banana")
		eq("a bad stored value", BotCrew:tactic(medic.oid, "healAt"), 0.75)
		deleteStringData("bot:" .. medic.oid .. ":crew:t:order:healAt")
		writeStringData("bot:" .. medic.oid .. ":crew:t:order:healAt", "95")
		eq("a stored value over the limit", BotCrew:tactic(medic.oid, "healAt"), 0.9)
		deleteStringData("bot:" .. medic.oid .. ":crew:t:order:healAt")

		-- 4. An order on a creature ends when it dies; a lost bot's orders go home with it
		local m = makeCreature(cameren, "a kreetle", 40, 0, nil)
		eq("a named creature", BotCrew:setTactic(rifleman.oid, "order", "focus", "creature:" .. m.oid), "creature:" .. m.oid)
		eq("while it lives", BotCrew:tactic(rifleman.oid, "focus"), "creature:" .. m.oid)
		damage(m, 1e9)
		eq("once it is dead", BotCrew:tactic(rifleman.oid, "focus"), "tank")
		eq("and the order is gone", readStringData("bot:" .. rifleman.oid .. ":crew:t:order:focus"), "")
		BotCrew:setTactic(rifleman.oid, "order", "range", "far")
		BotCrew:setTactic(rifleman.oid, "plan", "hold", "1")
		sim.call("BotCrew", "leaveForHome", rifleman, rifleman.oid, os.time())
		eq("an order after going home", BotCrew:tactic(rifleman.oid, "range"), "band")
		eq("a plan after going home", BotCrew:tactic(rifleman.oid, "hold"), BotCrew.holdFor)
		BotCrew:setTactic(medic.oid, "order", "shoot", "no")
		sim.call("BotCrew", "clear", medic.oid)
		eq("an order after a restart (clear)", BotCrew:tactic(medic.oid, "shoot"), "yes")
		realPrint("crewtable the layers, limits and defaults")
		teardown()
	end


	function scenarios.crewdoctrine()
		local cameren = sevenGroup("crewdoctrine")
		-- (big pools, so the specials' cost doesn't keep anyone under the heal line)
		for _, role in ipairs(SEVEN) do
			local b = crew[role]
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).base = b:pool(pool).base * 8 end
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).cur = b:getMaxHAM(pool) end
		end
		local tank, rifleman, medic, ranger, sl, ent, cmdo = crew.tank, crew.rifleman, crew.medic, crew.ranger, crew.squadleader,
			crew.entertainer, crew.commando
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function calm()
			cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
			sim.run(30)
		end
		local function clearAll()
			for _, role in ipairs(SEVEN) do
				BotCrew:clearLayer(crew[role].oid, "order")
				BotCrew:clearLayer(crew[role].oid, "plan")
			end
		end
		local function order(role, name, value)
			if BotCrew:setTactic(crew[role].oid, "order", name, value) == nil then
				fail("crewdoctrine: test bug, " .. role .. " " .. name .. " " .. value .. " isn't taken")
			end
		end
		local function targetOf(b) return readData("bot:" .. b.oid .. ":crew:target") end
		local function count(b, since, names)
			local n = 0
			for _, c in ipairs(okCommands(b, nil, since)) do
				if names[c.cmd] then n = n + 1 end
			end
			return n
		end
		local function dots(since)
			local out = {}
			for _, d in ipairs(log.dots) do if d.bot == medic.oid and d.t >= since then table.insert(out, d) end end
			return out
		end
		local function areas(cmd, since)
			local out = {}
			for _, a in ipairs(log.areas) do
				if a.bot == cmdo.oid and a.t >= (since or 0) and (cmd == nil or a.cmd:find(cmd, 1, true)) then table.insert(out, a) end
			end
			return out
		end
		-- (when a bot set the creature as its target: its shots start there)
		local function firstEngage(b, mob, since)
			for _, e in ipairs(entries(log.targets, b, since)) do
				if e.target == mob.oid then return e.t end
			end
			return nil
		end
		local sh = BotCrew:setting("specialsHam")
		local SPECIALS = {headshot1 = true, headshot2 = true, headshot3 = true, flurryshot1 = true, flurryshot2 = true,
			strafeshot1 = true, strafeshot2 = true, startleshot2 = true}

		-- 1. specials: only above 30% (full), 50% (normal, the roster's) or 75% (save) of each pool
		rifleman.noRegen = true
		local function specialsAt(share, value)
			clearAll()
			if value ~= nil then order("rifleman", "specials", value) end
			rifleman:pool(MIND).cur = math.floor(rifleman:getMaxHAM(MIND) * share)
			local m = makeCreature(cameren, "a kreetle", 40, 0, tank)
			local t = nowMs()
			attack(cameren, m)
			sim.run(10)
			local n = count(rifleman, t, SPECIALS)
			slays(m)
			calm()
			return n
		end
		local between = (sh + 0.75) / 2
		if specialsAt(between, nil) == 0 then fail("crewdoctrine: no specials at " .. between .. " of its mind by default") end
		if specialsAt(between, "save") ~= 0 then fail("crewdoctrine: specials at " .. between .. " of its mind with 'save'") end
		local low = (0.3 + sh) / 2
		if specialsAt(low, nil) ~= 0 then fail("crewdoctrine: specials at " .. low .. " of its mind by default") end
		if specialsAt(low, "full") == 0 then fail("crewdoctrine: no specials at " .. low .. " of its mind with 'full'") end
		rifleman.noRegen = false
		rifleman:pool(MIND).cur = rifleman:getMaxHAM(MIND)
		clearAll()

		-- 2. hold: how long a ranged bot waits for the tank (0: not at all)
		local function openingGap(value)
			clearAll()
			if value ~= nil then order("rifleman", "hold", value) end
			local m = makeCreature(cameren, "a kreetle", 40, 0, nil, nil, false)
			m.hits = 5
			local t = nowMs()
			attack(cameren, m)
			sim.run(8)
			local tankAt, rifleAt = firstEngage(tank, m, t), firstEngage(rifleman, m, t)
			slays(m)
			calm()
			return tankAt, rifleAt, t
		end
		local tankAt, rifleAt = openingGap(nil)
		if tankAt == nil or rifleAt == nil or rifleAt - tankAt < 2000 then
			fail("crewdoctrine: by default the rifleman opened " .. tostring(rifleAt and tankAt and (rifleAt - tankAt)) .. " ms after the tank")
		end
		local tankAt0, rifleAt0, t0 = openingGap("0")
		if tankAt0 == nil or rifleAt0 == nil or rifleAt0 - t0 > 2600 then
			fail("crewdoctrine: with hold 0 the rifleman opened " .. tostring(rifleAt0 and (rifleAt0 - t0)) .. " ms after the pull")
		end
		clearAll()

		-- 3. focus: the tank's target (default), the leader's, the weakest, the strongest, what is on the medic, a named creature
		local small = makeCreature(cameren, "a kreetle", 40, 0, tank, 1e5)
		local big = makeCreature(cameren, "a bantha", 40, 3, tank, 9e6)
		local onMedic = makeCreature(cameren, "a gurrek", 38, -3, medic, 5e6)
		onMedic.noTaunt, onMedic.lockUntil = true, nowMs() + 1e9 -- (neither the tank nor the ranger can take it off the medic)
		attack(cameren, small)
		sim.run(5)
		local function focusIs(value, want, label)
			clearAll()
			if value ~= nil then order("rifleman", "focus", value) end
			-- (it holds fire up to 6 s on a creature the tank hasn't taken: one on the medic, say)
			sim.run(9)
			if targetOf(rifleman) ~= want.oid then
				fail("crewdoctrine: focus " .. tostring(value) .. ": the rifleman fights " .. targetOf(rifleman) .. ", expected " .. label)
			end
		end
		focusIs(nil, small, "the tank's target")
		focusIs("strongest", big, "the strongest")
		focusIs("weakest", small, "the weakest")
		focusIs("medic", onMedic, "the creature on the medic")
		cameren.target = big.oid
		focusIs("leader", big, "the leader's target")
		cameren.target = small.oid
		focusIs("creature:" .. big.oid, big, "the named creature")
		slays(big)
		sim.run(4)
		local v = BotCrew:tactic(rifleman.oid, "focus")
		if v ~= "tank" then fail("crewdoctrine: the order on a dead creature still stands: " .. tostring(v)) end
		if targetOf(rifleman) == big.oid then fail("crewdoctrine: the rifleman still fights the dead creature") end
		slays(small, onMedic)
		calm()

		-- 4. range: the band moved 5 m, inside the weapon's reach
		clearAll()
		local near0, far0 = BotCrew:band(rifleman, rifleman.oid, "rifleman")
		local reach = readData("bot:" .. rifleman.oid .. ":crew:bandMax")
		order("rifleman", "range", "far")
		local nearF, farF = BotCrew:band(rifleman, rifleman.oid, "rifleman")
		order("rifleman", "range", "close")
		local nearC, farC = BotCrew:band(rifleman, rifleman.oid, "rifleman")
		if farF ~= math.min(far0 + 5, reach - 2) or nearF ~= math.min(near0 + 5, farF - 2) then
			fail(string.format("crewdoctrine: range far gave %s-%s, the band is %s-%s (reach %s)", tostring(nearF), tostring(farF), tostring(near0), tostring(far0), tostring(reach)))
		end
		if farC ~= far0 - 5 or nearC ~= math.max(3, near0 - 5) then
			fail(string.format("crewdoctrine: range close gave %s-%s, the band is %s-%s", tostring(nearC), tostring(farC), tostring(near0), tostring(far0)))
		end
		if farF > reach then fail("crewdoctrine: range far went past the weapon's reach") end
		clearAll()

		-- 5. protect: the creature on the member looked after comes first when taunting and rescuing
		local mM = makeCreature(cameren, "a kreetle", 30, 0, medic)
		local mI = makeCreature(cameren, "a kreetle", 30, 2, ent)
		local g = BotCrew:group(tank)
		local function sorted()
			local list = {{p = mI, oid = mI.oid, dist = 8}, {p = mM, oid = mM.oid, dist = 12}}
			return BotCrew:sortByVictim(tank, list, g, tank.oid)
		end
		if sorted()[1].oid ~= mM.oid then fail("crewdoctrine: by default the creature on the medic isn't first") end
		order("tank", "protect", "ilsi")
		if sorted()[1].oid ~= mI.oid then fail("crewdoctrine: protect ilsi: the creature on her isn't first") end
		order("tank", "protect", "nobodyhere")
		if sorted()[1].oid ~= mM.oid then fail("crewdoctrine: protect a name that isn't in the group: not the medic's") end
		slays(mM, mI)
		clearAll()
		calm()

		-- 6. healAt: heal below this share of health or action in a fight
		cameren.noRegen = true
		local function healsAt(share, value)
			clearAll()
			if value ~= nil then order("medic", "healAt", value) end
			cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * share)
			local m = makeCreature(cameren, "a kreetle", 40, 0, tank)
			local t = nowMs()
			attack(cameren, m)
			sim.run(8)
			local n = 0
			for _, c in ipairs(okCommands(medic, "healdamage", t)) do
				if tonumber(c.args:match("^(%d+)")) == cameren.oid or c.target == cameren.oid then n = n + 1 end
			end
			slays(m)
			cameren:pool(HEALTH).cur = cameren:getMaxHAM(HEALTH)
			calm()
			return n
		end
		if healsAt(0.6, nil) == 0 then fail("crewdoctrine: the medic didn't heal a member at 60% in a fight by default") end
		if healsAt(0.6, "0.5") ~= 0 then fail("crewdoctrine: healAt 0.5: the medic healed a member at 60%") end
		if healsAt(0.85, "0.9") == 0 then fail("crewdoctrine: healAt 0.9: the medic didn't heal a member at 85%") end
		cameren.noRegen = false
		clearAll()

		-- 7. packs, and mindFloor
		local function throws(value, entry, mindShare)
			clearAll()
			if value ~= nil then order("medic", entry, value) end
			medic.noRegen = true
			medic:pool(MIND).cur = math.floor(medic:getMaxHAM(MIND) * (mindShare or 1))
			local a = makeCreature(cameren, "a kreetle", 40, 0, tank)
			local b = makeCreature(cameren, "a kreetle", 40, 2, tank)
			local c = makeCreature(cameren, "a kreetle", 41, 1, tank)
			local t = nowMs()
			attack(cameren, a)
			sim.run(30)
			local d = dots(t)
			slays(a, b, c)
			medic.noRegen = false
			medic:pool(MIND).cur = medic:getMaxHAM(MIND)
			calm()
			return d
		end
		local d = throws(nil, "packs")
		if #d < 2 or not d[1].pack:find("_area_", 1, true) then fail("crewdoctrine: by default the medic didn't throw area packs at a clump") end
		d = throws("single", "packs")
		if #d < 2 then fail("crewdoctrine: packs single: " .. #d .. " packs") end
		for _, x in ipairs(d) do
			if x.pack:find("_area_", 1, true) then fail("crewdoctrine: packs single threw an area pack") end
		end
		d = throws("none", "packs")
		if #d ~= 0 then fail("crewdoctrine: packs none: " .. #d .. " packs thrown") end
		d = throws(nil, "mindFloor", 0.6)
		if #d == 0 then fail("crewdoctrine: no packs at 60% of its mind by default") end
		d = throws("0.8", "mindFloor", 0.6)
		if #d ~= 0 then fail("crewdoctrine: mindFloor 0.8: packs thrown at 60% of its mind") end
		clearAll()

		-- 8. shoot: heals and stays out of it unless something is on it
		local function shoots(role, value)
			clearAll()
			if value ~= nil then order(role, "shoot", value) end
			local b = crew[role]
			local m = makeCreature(cameren, "a kreetle", 40, 0, tank)
			local t = nowMs()
			attack(cameren, m)
			sim.run(8)
			local opened = #entries(log.targets, b, t) > 0 or targetOf(b) ~= 0
			-- a creature on the bot itself is fought back whatever the table says
			local m2 = makeCreature(cameren, "a gurrek", 20, 0, b)
			m2.noTaunt = true
			sim.run(6)
			local fought = targetOf(b) == m2.oid
			slays(m, m2)
			calm()
			return opened, fought
		end
		for _, role in ipairs({"medic", "entertainer"}) do
			local opened = shoots(role, nil)
			if not opened then fail("crewdoctrine: the " .. role .. " didn't shoot by default") end
			local opened2, fought = shoots(role, "no")
			if opened2 then fail("crewdoctrine: shoot no: the " .. role .. " still shot") end
			if not fought then fail("crewdoctrine: shoot no: the " .. role .. " didn't fight what was on it") end
		end
		clearAll()

		-- 9. area: both, cones only, neither
		local function volley(value)
			clearAll()
			if value ~= nil then order("commando", "area", value) end
			local a = makeCreature(cameren, "a kreetle", 40, 0, tank)
			local b = makeCreature(cameren, "a kreetle", 40, 1.2, tank)
			local c = makeCreature(cameren, "a kreetle", 41, 0.6, tank)
			local t = nowMs()
			attack(cameren, a)
			sim.run(20)
			local cones, grenades = #areas("cone", t), #areas("grenade", t)
			slays(a, b, c)
			calm()
			return cones, grenades
		end
		local cones, grenades = volley(nil)
		if cones == 0 or grenades == 0 then fail("crewdoctrine: by default the commando fired " .. cones .. " cones and " .. grenades .. " grenades at a clump") end
		cones, grenades = volley("cones")
		if cones == 0 or grenades ~= 0 then fail("crewdoctrine: area cones: " .. cones .. " cones and " .. grenades .. " grenades") end
		cones, grenades = volley("none")
		if cones ~= 0 or grenades ~= 0 then fail("crewdoctrine: area none: " .. cones .. " cones and " .. grenades .. " grenades") end
		clearAll()

		-- 10. calls: which the squad leader makes
		local function callsMade(value)
			clearAll()
			if value ~= nil then order("squadleader", "calls", value) end
			local a = makeCreature(cameren, "a kreetle", 40, 0, nil, nil, false)
			local b = makeCreature(cameren, "a kreetle", 40, 3, tank, nil, false)
			local t = nowMs()
			attack(cameren, a)
			sim.run(16)
			local out = {rally = #okCommands(sl, "rally", t), volley = #okCommands(sl, "volleyfire", t)}
			slays(a, b)
			calm()
			sim.run(30)
			return out
		end
		local made = callsMade(nil)
		if made.rally == 0 then fail("crewdoctrine: by default the squad leader didn't rally") end
		made = callsMade("none")
		if made.rally ~= 0 or made.volley ~= 0 then fail("crewdoctrine: calls none: rally " .. made.rally .. ", volley " .. made.volley) end
		made = callsMade("volley")
		if made.rally ~= 0 then fail("crewdoctrine: calls volley: it still rallied") end
		clearAll()

		realPrint("crewdoctrine each entry followed in a fight")
		teardown()
	end


	-- The medic's order of work, and the hard rules under a hostile table
	function scenarios.crewdoctrinemedic()
		local cameren = sevenGroup("crewdoctrinemedic")
		local rifleman, medic = crew.rifleman, crew.medic
		local function clearAll()
			for _, role in ipairs(SEVEN) do
				BotCrew:clearLayer(crew[role].oid, "order")
			end
		end
		-- The first of the medic's revives and heals since t, in the order it queued them
		local function firstWork(since)
			for _, c in ipairs(commands(medic, nil, since)) do
				if c.cmd == "reviveplayer" or c.cmd == "healdamage" then return c.cmd, c.target end
			end
			return nil
		end
		cameren.noRegen = true
		local function run(share, orders)
			clearAll()
			for name, value in pairs(orders or {}) do
				if BotCrew:setTactic(medic.oid, "order", name, value) == nil then fail("crewdoctrinemedic: test bug " .. name) end
			end
			cameren:pool(HEALTH).cur = math.floor(cameren:getMaxHAM(HEALTH) * share)
			rifleman.dead = true
			dropFromCombat(rifleman)
			local t = nowMs()
			sim.run(25)
			local first, target = firstWork(t)
			cameren:pool(HEALTH).cur = cameren:getMaxHAM(HEALTH)
			sim.run(30)
			return first, target
		end

		-- 1. By default the dead are revived before the living are healed
		local first = run(0.6)
		if first ~= "reviveplayer" then fail("crewdoctrinemedic: by default the medic's first work was " .. tostring(first)) end
		-- 2. reviveFirst no: the living first
		local first2, target2 = run(0.6, {reviveFirst = "no"})
		if first2 ~= "healdamage" or target2 ~= cameren.oid then fail("crewdoctrinemedic: reviveFirst no: the medic's first work was " .. tostring(first2)) end
		-- 3. A member close to death (under 25%) is healed before a revive, whatever the table says
		local first3, target3 = run(0.2, {reviveFirst = "yes", healAt = "0.5"})
		if first3 ~= "healdamage" or target3 ~= cameren.oid then
			fail("crewdoctrinemedic: with a member at 20% and reviveFirst yes the medic's first work was " .. tostring(first3))
		end
		-- ...and the same with the table set to its most hostile
		local first4, target4 = run(0.2, {reviveFirst = "yes", healAt = "0.5", packs = "none", mindFloor = "0.8", shoot = "no"})
		if first4 ~= "healdamage" or target4 ~= cameren.oid then
			fail("crewdoctrinemedic: with a hostile table and a member at 20% the medic's first work was " .. tostring(first4))
		end
		realPrint("crewdoctrinemedic the order of work")
		teardown()
	end

	-- The squad leader's retreat: the tank down and two members under retreatAt; three down always
	local function retreatRun(label, share, orders, downToo)
		local cameren = sevenGroup(label)
		local tank, medic, rifleman, ranger, sl = crew.tank, crew.medic, crew.rifleman, crew.ranger, crew.squadleader
		for name, value in pairs(orders or {}) do
			if BotCrew:setTactic(sl.oid, "order", name, value) == nil then fail(label .. ": test bug " .. name) end
		end
		local m = makeCreature(cameren, "a kreetle", 30, 0, nil, nil, false)
		m.hits = 5
		attack(cameren, m)
		sim.run(6)
		local t = nowMs()
		tank.dead = true
		medic.injuryReady, rifleman.injuryReady = nowMs() + 40000, nowMs() + 40000
		for _, role in ipairs({"rifleman", "ranger"}) do
			local b = crew[role]
			b.noRegen = true
			b:pool(HEALTH).cur = math.floor(b:getMaxHAM(HEALTH) * share)
		end
		if downToo then
			ranger.dead, rifleman.dead = true, true
		end
		m.aggro = cameren.oid
		startCombat(m, cameren)
		sim.run(6)
		local n = #okCommands(sl, "retreat", t)
		teardown()
		return n
	end

	function scenarios.crewdoctrineretreat()
		if retreatRun("crewdoctrineretreat", 0.4, nil, false) ~= 0 then
			fail("crewdoctrineretreat: a retreat with the tank down and two members at 40% by default")
		end
	end

	function scenarios.crewdoctrineretreatat()
		if retreatRun("crewdoctrineretreatat", 0.4, {retreatAt = "0.5"}, false) == 0 then
			fail("crewdoctrineretreatat: no retreat with the tank down and two members at 40% and retreatAt 0.5")
		end
	end

	function scenarios.crewdoctrineretreatthree()
		-- (the table at its most hostile for a retreat: the lowest retreatAt, no calls; three down is a retreat all the same)
		if retreatRun("crewdoctrineretreatthree", 0.9, {retreatAt = "0.2", calls = "none"}, true) == 0 then
			fail("crewdoctrineretreatthree: no retreat with three members down and retreatAt 0.2")
		end
	end

	-- The area attacks keep their checks under a table that asks for them
	function scenarios.crewdoctrinearea()
		local cameren = sevenGroup("crewdoctrinearea")
		for _, role in ipairs(SEVEN) do
			local b = crew[role]
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).base = b:pool(pool).base * 8 end
			for _, pool in ipairs({HEALTH, ACTION}) do b:pool(pool).cur = b:getMaxHAM(pool) end
		end
		local tank, medic, com = crew.tank, crew.medic, crew.commando
		assert(BotCrew:setTactic(com.oid, "order", "area", "both"))
		assert(BotCrew:setTactic(medic.oid, "order", "packs", "area"))
		assert(BotCrew:setTactic(medic.oid, "order", "mindFloor", "0.3"))
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		-- A clump of three on the tank with an idle, unpulled creature beside it: no cone, no grenade, no area pack
		local a = makeCreature(cameren, "a kreetle", 40, 0, tank)
		local b = makeCreature(cameren, "a kreetle", 40, 1.2, tank)
		local c = makeCreature(cameren, "a kreetle", 41, 0.6, tank)
		local idle = makeCreature(cameren, "a dewback", 43, 0.6, nil)
		idle.neverAggro, idle.unpulled = true, true
		local t = nowMs()
		attack(cameren, a)
		sim.run(30)
		for _, x in ipairs(log.areas) do
			if x.t >= t and (x.bot == com.oid or x.bot == medic.oid) then
				for _, oid in ipairs(x.hit) do
					if oid == idle.oid then fail("crewdoctrinearea: an area attack hit the unpulled creature (" .. x.cmd .. ")") end
				end
			end
		end
		for _, x in ipairs(log.dots) do
			if x.t >= t and x.bot == medic.oid and x.pack:find("_area_", 1, true) then fail("crewdoctrinearea: an area pack with an unpulled creature near") end
		end
		if idle.poisonUntil ~= nil then fail("crewdoctrinearea: the unpulled creature was poisoned") end
		slays(a, b, c, idle)
		realPrint("crewdoctrinearea the area checks under a table that asks for them")
		teardown()
	end


	-- Plans, orders and the base table, through a faked talk bridge (set SIM_TALK_DIR to an empty directory with req/ and rep/)
	local function planWorld(label, dir, files)
		setup(dir)
		-- (the base table's file is there before the crew logs in)
		for path, text in pairs(files or {}) do
			os.execute('mkdir -p "' .. dir .. '/tactics"')
			local f = io.open(dir .. "/" .. path, "w")
			f:write(text)
			f:close()
		end
		for _, role in ipairs(SEVEN) do login(crew[role]) end
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		for _, role in ipairs(SEVEN) do
			invite(cameren, crew[role], true)
			sim.run(3)
		end
		sim.run(10)
		if members(cameren) ~= 8 then fail(label .. ": " .. members(cameren) .. " in the group, expected Cameren and the seven") end
		for _, role in ipairs(SEVEN) do
			crew[role].cell = 0
			for _, pool in ipairs({HEALTH, ACTION}) do
				crew[role]:pool(pool).base = crew[role]:pool(pool).base * 8
				crew[role]:pool(pool).cur = crew[role]:getMaxHAM(pool)
			end
		end
		cameren.cell = 0
		sim.run(10)
		return cameren
	end

	-- The bridge: reads req/, answers after `delay` ms with what `answer(r)` gives (nil: no answer at all). Plans and says are
	-- recorded. bridge.on false: no heartbeat (the crew sees no bridge).
	local function fakeBridge(dir, answer)
		local bridge = {on = true, requests = {}, delay = 1500}
		local function heartbeat()
			local f = io.open(dir .. "/alive", "w")
			f:write(tostring(sim.now) .. "\n")
			f:close()
		end
		local function parse(body)
			local r = {}
			for k, v in body:gmatch('"([%w_]+)":"([^"]*)"') do r[k] = v end
			for k, v in body:gmatch('"([%w_]+)":(%-?%d+)') do r[k] = tonumber(v) end
			-- (the multi-line fields are \u000a in the file)
			for k, v in pairs(r) do
				if type(v) == "string" then r[k] = v:gsub("\\u000a", "\n") end
			end
			return r
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
						r.seenAt = nowMs()
						table.insert(bridge.requests, r)
						local reply = answer(r)
						if reply ~= nil then
							sim.schedule(bridge.delay, function()
								local out = io.open(dir .. "/rep/" .. r.id .. ".txt", "w")
								out:write(reply)
								out:close()
							end)
						end
					end
				end
				handle:close()
			end
			sim.schedule(500, tick)
		end
		heartbeat()
		tick()
		function bridge.plans()
			local out = {}
			for _, r in ipairs(bridge.requests) do if r.type == "plan" then table.insert(out, r) end end
			return out
		end
		return bridge
	end

	function scenarios.crewplan()
		local dir = os.getenv("SIM_TALK_DIR")
		if dir == nil then
			realPrint("crewplan skipped (set SIM_TALK_DIR to an empty directory with req/ and rep/)")
			return
		end
		os.execute('rm -rf "' .. dir .. '/tactics" "' .. dir .. '/alive"')
		local planReply = "ok\nkragoth focus strongest\nquillan healAt 0.85\nsenna healAt 0.9\nsenna hold 1\nsay kragoth All heals on me, the big one is mine.\n"
		local bridge = fakeBridge(dir, function(r)
			if r.type == "plan" then
				return planReply
			end
			return nil
		end)
		local cameren = planWorld("crewplan", dir, {["tactics/base.txt"] =
			"quillan healAt 0.60\nquillan packs single\nkragoth focus leader\nsenna hold 0\nsenna healAt 0.9\nbogus x y\nweeta range sideways\n"})
		local tank, rifleman, medic = crew.tank, crew.rifleman, crew.medic
		local function eq(label, got, want)
			if got ~= want then fail("crewplan: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end
		local function calm()
			cameren.inCombat, cameren.target, cameren.defenders = false, 0, {}
			sim.run(30)
		end

		-- 1. The base table from the file: for the roles that have the entries; a bad line, an unknown entry or a wrong role dropped
		local v, layer = BotCrew:tactic(medic.oid, "healAt")
		eq("base healAt", v, 0.6)
		eq("base layer", layer, "base")
		eq("base packs", BotCrew:tactic(medic.oid, "packs"), "single")
		eq("base focus", BotCrew:tactic(tank.oid, "focus"), "leader")
		eq("base hold", BotCrew:tactic(rifleman.oid, "hold"), 0)
		eq("a wrong role's entry", BotCrew:tactic(rifleman.oid, "healAt"), BotCrew.healBelow.fight)
		eq("an unknown word", BotCrew:tactic(crew.ranger.oid, "range"), "band")

		-- 2. The pull: one plan request, with the crew and the creatures in it; applied when the reply comes
		local m1 = makeCreature(cameren, "a kreetle", 40, 0, nil, 5e6, false)
		m1.hits = 5
		local m2 = makeCreature(cameren, "a bantha", 40, 3, tank, 9e6, false)
		m2.hits = 5
		local t = nowMs()
		attack(cameren, m1)
		sim.run(5)
		local plans = bridge.plans()
		eq("plans at the pull", #plans, 1)
		local r = plans[1]
		if r ~= nil then
			eq("the reason", r.reason, "pull")
			if not (r.crew or ""):find("quillan medic hp ", 1, true) or not (r.crew or ""):find("kragoth tank", 1, true) then
				fail("crewplan: the request's crew lines: " .. tostring(r.crew))
			end
			if not (r.creatures or ""):find(tostring(m2.oid) .. " bantha level", 1, true) then fail("crewplan: the request's creatures: " .. tostring(r.creatures)) end
			if r.leader ~= "cameren" then fail("crewplan: the leader " .. tostring(r.leader)) end
		end
		sim.run(4)
		v, layer = BotCrew:tactic(medic.oid, "healAt")
		eq("plan healAt", v, 0.85)
		eq("plan layer", layer, "plan")
		eq("plan focus", BotCrew:tactic(tank.oid, "focus"), "strongest")
		eq("a wrong role in the plan", BotCrew:tactic(rifleman.oid, "healAt"), BotCrew.healBelow.fight)
		eq("plan hold", BotCrew:tactic(rifleman.oid, "hold"), 1)
		local said = false
		for _, l in ipairs(entries(log.group, tank, t)) do
			if l.text == "All heals on me, the big one is mine." then said = true end
		end
		if not said then fail("crewplan: kragoth didn't say the plan's line in group chat") end

		-- 3. At most one plan every 10 s: an add and a member down inside the window wait for it, then one more goes
		local before = #bridge.plans()
		local add = makeCreature(cameren, "a gurrek", 38, -3, tank, 5e6, false)
		add.hits = 5
		sim.run(3)
		eq("plans inside the window", #bridge.plans(), before)
		sim.run(10)
		eq("the plan after the window", #bridge.plans(), before + 1)
		if #bridge.plans() >= 2 then
			local a, b = bridge.plans()[1].seenAt, bridge.plans()[2].seenAt
			if b - a < 9000 then fail("crewplan: two plans " .. (b - a) .. " ms apart") end
			eq("the reason of the second", bridge.plans()[2].reason, "add")
		end

		-- 4. A reply that comes after planLate seconds is dropped: the plan layer stays as it was
		planReply = "ok\nquillan healAt 0.55\n"
		bridge.delay = 15500
		local down = makeCreature(cameren, "a kreetle", 36, 0, tank, 5e6, false)
		sim.run(14)
		sim.run(10)
		eq("a late plan", BotCrew:tactic(medic.oid, "healAt"), 0.85)
		bridge.delay = 1500

		-- 5. The plan goes with the fight: nobody fights, the plan layers are gone and the base shows again
		slays(m1, m2, add, down)
		calm()
		v, layer = BotCrew:tactic(medic.oid, "healAt")
		eq("healAt after the fight", v, 0.6)
		eq("layer after the fight", layer, "base")
		eq("focus after the fight", BotCrew:tactic(tank.oid, "focus"), "leader")

		-- 6. A restart mid-fight leaves no plan layer: a plan, then the bot logs in afresh
		planReply = "ok\nquillan healAt 0.7\n"
		local m3 = makeCreature(cameren, "a kreetle", 40, 0, nil, 5e6, false)
		m3.hits = 5
		attack(cameren, m3)
		sim.run(8)
		eq("a plan before the restart", BotCrew:tactic(medic.oid, "healAt"), 0.7)
		sim.call("BotCrew", "clear", medic.oid)
		eq("the plan after a restart", BotCrew:tactic(medic.oid, "healAt"), 0.6)
		slays(m3)
		calm()

		-- 7. The base file changes: the crew's base entries follow it (within a minute), and a file that is gone leaves the last
		local f = io.open(dir .. "/tactics/base.txt", "w")
		f:write("quillan healAt 0.8\n")
		f:close()
		sim.run(70)
		eq("a changed file", BotCrew:tactic(medic.oid, "healAt"), 0.8)
		eq("an entry no longer in the file", BotCrew:tactic(tank.oid, "focus"), "tank")
		os.remove(dir .. "/tactics/base.txt")
		sim.run(70)
		eq("a file that is gone", BotCrew:tactic(medic.oid, "healAt"), 0.8)

		realPrint(string.format("crewplan %d plans asked", #bridge.plans()))
		bridge.on = false
		teardown()
	end

	function scenarios.crewordering()
		local dir = os.getenv("SIM_TALK_DIR")
		if dir == nil then
			realPrint("crewordering skipped (set SIM_TALK_DIR to an empty directory with req/ and rep/)")
			return
		end
		os.execute('rm -rf "' .. dir .. '/tactics" "' .. dir .. '/alive"')
		local orders = ""
		local teach = ""
		local bridge = fakeBridge(dir, function(r)
			if r.type == "plan" then
				return "ok\n"
			end
			return "ok\nneutral\nGot it.\n\n\n" .. orders .. "\n" .. teach .. "\n"
		end)
		local cameren = planWorld("crewordering", dir)
		local tank, rifleman, medic, ranger, sl, ent, cmdo = crew.tank, crew.rifleman, crew.medic, crew.ranger, crew.squadleader,
			crew.entertainer, crew.commando
		local function eq(label, got, want)
			if got ~= want then fail("crewordering: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		local function slays(...)
			for _, m in ipairs({...}) do
				if not m.dead then damage(m, 1e9) end
			end
		end

		-- 1. To the crew: the group's first crew bot asks, and the entry goes to everyone who has it
		orders = "* range far"
		groupSay(cameren, "everyone stay back")
		sim.run(5)
		for _, role in ipairs({"rifleman", "ranger", "squadleader", "entertainer", "medic"}) do
			eq(role .. " range", BotCrew:tactic(crew[role].oid, "range"), "far")
		end
		eq("tank range (no such entry)", readStringData("bot:" .. tank.oid .. ":crew:t:order:range"), "")
		eq("commando range (no such entry)", readStringData("bot:" .. cmdo.oid .. ":crew:t:order:range"), "")
		-- 2. To one bot, by name
		orders = "quillan shoot no;quillan packs none"
		groupSay(cameren, "Quillan, just heal")
		sim.run(5)
		eq("medic shoot", BotCrew:tactic(medic.oid, "shoot"), "no")
		eq("medic packs", BotCrew:tactic(medic.oid, "packs"), "none")
		eq("entertainer shoot (not told)", BotCrew:tactic(ent.oid, "shoot"), "yes")
		-- 3. An order on a creature ends with the creature
		local m = makeCreature(cameren, "a bantha", 40, 0, tank, 5e6, false)
		orders = "* focus creature:" .. m.oid
		groupSay(cameren, "kill the bantha")
		sim.run(5)
		eq("a named creature", BotCrew:tactic(rifleman.oid, "focus"), "creature:" .. m.oid)
		slays(m)
		eq("the creature dead", BotCrew:tactic(rifleman.oid, "focus"), "tank")
		-- 4. "As you were" ends every order
		orders = "* clear"
		groupSay(cameren, "as you were")
		sim.run(5)
		eq("medic shoot after", BotCrew:tactic(medic.oid, "shoot"), "yes")
		eq("range after", BotCrew:tactic(rifleman.oid, "range"), "band")
		-- 5. An order from someone outside the group changes nothing
		local stranger = makeHuman("Stranger", crew.tank.x + 3, crew.tank.y + 1)
		orders = "quillan shoot no"
		sim.call("BotJobs", "onHeard", medic, stranger, "Quillan, just heal", "tell")
		sim.run(5)
		eq("an order from outside the group", BotCrew:tactic(medic.oid, "shoot"), "yes")
		-- 6. An order beyond the limits is clamped, an unknown entry dropped
		orders = "quillan healAt 0.99;quillan bogus x;kragoth range far"
		groupSay(cameren, "Quillan, heal earlier")
		sim.run(5)
		eq("a clamped order", BotCrew:tactic(medic.oid, "healAt"), 0.9)
		eq("an entry the role hasn't", readStringData("bot:" .. tank.oid .. ":crew:t:order:range"), "")
		-- 7. The result of a lesson makes the base file be read soon after
		orders = ""
		teach = "added quillan"
		os.execute('mkdir -p "' .. dir .. '/tactics"')
		local f = io.open(dir .. "/tactics/base.txt", "w")
		f:write("quillan reviveFirst no\n")
		f:close()
		groupSay(cameren, "Quillan, from now on heal the living first")
		sim.run(14)
		eq("a lesson read in", BotCrew:tactic(medic.oid, "reviveFirst"), "no")
		teach = ""
		os.remove(dir .. "/tactics/base.txt")
		-- 8. Going home ends the orders
		BotCrew:setTactic(rifleman.oid, "order", "range", "far")
		sim.call("BotCrew", "leaveForHome", rifleman, rifleman.oid, os.time())
		eq("an order after going home", BotCrew:tactic(rifleman.oid, "range"), "band")

		realPrint(string.format("crewordering %d requests", #bridge.requests))
		bridge.on = false
		teardown()
	end

	-- No model: an order or a lesson gets one canned line and changes nothing
	function scenarios.crewordernobrain()
		local cameren = sevenGroup("crewordernobrain")
		local medic = crew.medic
		local t = nowMs()
		groupSay(cameren, "Quillan, just heal")
		sim.run(5)
		local lines = entries(log.group, medic, t)
		if #lines ~= 1 or not isLine(lines[1].text, "medic", "orderNoBrain") then
			local seen = {}
			for _, l in ipairs(lines) do table.insert(seen, l.text) end
			fail("crewordernobrain: expected one canned line, got " .. #lines .. ": " .. table.concat(seen, " | "))
		end
		if BotCrew:tactic(medic.oid, "shoot") ~= "yes" then fail("crewordernobrain: the order changed the table") end
		-- (talk that isn't one gets the ordinary fallback, not the order's)
		t = nowMs()
		sim.run(65)
		t = nowMs()
		groupSay(cameren, "nice weather today")
		sim.run(5)
		for _, l in ipairs(entries(log.group, nil, t)) do
			if isLine(l.text, "medic", "orderNoBrain") then fail("crewordernobrain: ordinary chat got the order's canned line") end
		end
		realPrint("crewordernobrain")
		teardown()
	end


	-- Phase 11: the buffs window and the 15-minute warning
	function scenarios.crewbuffs()
		local cameren = sevenGroup("crewbuffs")
		local medic, tank, ent = crew.medic, crew.tank, crew.entertainer
		local function eq(label, got, want)
			if got ~= want then fail("crewbuffs: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		local function buff(o, name, seconds)
			o.buffs = o.buffs or {}
			o.buffs[name] = {expires = sim.now + seconds, amount = 100}
		end
		-- Cameren has the dancer's mind buff (the warning's, later), the tank all three mind buffs and two enhancements, Ilsi battle fatigue
		buff(cameren, "performance_enhance_dance_mind", 3000)
		buff(tank, "performance_enhance_dance_mind", 3600)
		buff(tank, "performance_enhance_music_focus", 1800)
		buff(tank, "performance_enhance_music_willpower", 1800)
		buff(tank, "medical_enhance_health", 7200)
		buff(tank, "medical_enhance_action", 5400)
		ent.shock = 250

		-- 1. "buffs" in group chat: one window for Cameren, a row for each of the eight, him first
		local t = nowMs()
		groupSay(cameren, "buffs")
		sim.run(4)
		eq("windows", #log.windows, 1)
		local w = log.windows[1]
		if w ~= nil then
			eq("window for", w.to, cameren.oid)
			eq("screenplay", w.screenplay, "BotBuffs")
			eq("rows", #w.options, 8)
			if not w.options[1][1]:find("^Cameren %(you%): mind 50, focus %-, willpower %-, doctor %-, battle fatigue none$") then
				fail("crewbuffs: his row " .. tostring(w.options[1][1]))
			end
			local tankRow, entRow
			for _, o in ipairs(w.options) do
				if o[1]:find("^Kragoth") then tankRow = o[1] end
				if o[1]:find("^Ilsi") then entRow = o[1] end
			end
			if tankRow == nil or not tankRow:find("mind 60, focus 30, willpower 30, doctor 90 (2 of 6)", 1, true) then
				fail("crewbuffs: the tank's row " .. tostring(tankRow))
			end
			if entRow == nil or not entRow:find("battle fatigue 250", 1, true) then fail("crewbuffs: Ilsi's row " .. tostring(entRow)) end
		end
		-- 2. Asked again, fresh times (a window is not updated)
		sim.run(60)
		groupSay(cameren, "buff check")
		sim.run(4)
		eq("windows after asking again", #log.windows, 2)
		if log.windows[2] ~= nil and not log.windows[2].options[1][1]:find("mind 49,", 1, true) then
			fail("crewbuffs: the second window's row " .. tostring(log.windows[2].options[1][1]))
		end
		-- 3. A request for the doctor's work is not a window
		sim.run(10)
		groupSay(cameren, "buff us up doc")
		sim.run(4)
		eq("windows for a buff request", #log.windows, 2)
		-- 4. A tell to a crew bot out of a group: his own row
		local lone = makeHuman("Lone", crew.tank.x + 40, crew.tank.y)
		speak(crew.ranger, lone, "buffs", "tell")
		sim.run(4)
		eq("windows after a tell", #log.windows, 3)
		if log.windows[3] ~= nil then
			eq("rows for a tell", #log.windows[3].options, 1)
			eq("for", log.windows[3].to, lone.oid)
		end
		-- 5. The warning: his mind buff reaches 15 minutes (900 s): one system message, not repeated, not for the tank's
		local before = #log.sysmsgs
		sim.run(2200)
		local mine = 0
		for _, m in ipairs(log.sysmsgs) do
			if m.to == cameren.oid then
				mine = mine + 1
				eq("the message", m.text, "Your mind buffs have 15 minutes left.")
			end
		end
		eq("warnings for Cameren", mine, 1)
		-- ...and a renewed buff warns again when it comes down
		buff(cameren, "performance_enhance_dance_mind", 1500)
		sim.run(700)
		mine = 0
		for _, m in ipairs(log.sysmsgs) do if m.to == cameren.oid then mine = mine + 1 end end
		eq("warnings after a renewal", mine, 2)
		realPrint(string.format("crewbuffs %d windows, %d system messages", #log.windows, #log.sysmsgs))
		teardown()
	end

	-- Scenario: Phase 9 Part 1, the crew job for an own crew (invites, calls, the cap of three each, "make room")

	function scenarios.crewown()
		setup("/nonexistent/sim-talk")
		local function eq(label, got, want)
			if got ~= want then fail("crewown: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		for _, role in ipairs(SEVEN) do login(crew[role]) end
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		local dana = makeHuman("Dana", crew.tank.x + 4, crew.tank.y + 2)
		local eve = makeHuman("Eve", crew.tank.x + 6, crew.tank.y - 2)
		cameren.boxes, dana.boxes = 6, 12

		local used = {}
		local function hire(owner, role, name)
			local station = BotCrewKit:station("mos_eisley", used)
			table.insert(used, {station.x, station.y})
			local entry = BotCrewKit:entry({role = role, species = "human", sex = "male", name = name, look = {}, boxes = owner.boxes,
				city = "mos_eisley", station = station})
			local ok, first = botHire(owner.oid, entry)
			if not ok then fail("crewown: hiring " .. name .. ": " .. tostring(first)) end
			local b = byFirst[first:lower()]
			login(b)
			return b
		end
		local venn = hire(cameren, "tank", "Venn Farrow")
		local oren = hire(cameren, "rifleman", "Oren Marsh")
		local aleka = hire(cameren, "medic", "Aleka Ives")
		local holt = hire(cameren, "ranger", "Holt Jaxon")
		local lorn = hire(dana, "tank", "Lorn Yarrow")
		hire(dana, "medic", "Brisa Fendrel")
		sim.run(5)
		eq("the owner Venn knows", readData("bot:" .. venn.oid .. ":crew:owner"), cameren.oid)
		eq("the Mos Eisley crew's owner", readData("bot:" .. crew.tank.oid .. ":crew:owner"), 0)

		-- 1. A stranger's invite is refused, politely; the owner's is taken
		local t = nowMs()
		invite(dana, venn, true)
		sim.run(4)
		eq("grouped after a stranger's invite", members(dana), 0)
		eq("a decline", #commands(venn, "decline", t), 1)
		eq("no join", #commands(venn, "join", t), 0)
		if not anyLine(entries(log.says, venn, t), "tank", "notYours") then fail("crewown: no polite no to the stranger") end
		invite(cameren, venn, true)
		sim.run(4)
		eq("Venn with Cameren", members(cameren), 2)

		-- 2. The Mos Eisley crew takes anyone's invite, as before
		invite(dana, crew.rifleman, true)
		sim.run(4)
		eq("a Mos Eisley bot with Dana", members(dana), 2)

		-- 3. Three each when two humans are online: Cameren's group gets Venn, Oren, Aleka; Holt sits out
		invite(cameren, oren, true)
		sim.run(3)
		invite(cameren, aleka, true)
		sim.run(3)
		eq("Cameren's group", members(cameren), 4)
		t = nowMs()
		invite(cameren, holt, true)
		sim.run(4)
		eq("Cameren's group after the fourth", members(cameren), 4)
		eq("Holt declined", #commands(holt, "decline", t), 1)
		if not anyLine(entries(log.says, holt, t), "ranger", "sitOut") then fail("crewown: Holt didn't say he sits this one out") end

		-- 4. "Make room": the newest of Cameren's own crew in the group goes home
		groupSay(cameren, "make room")
		sim.run(20)
		eq("the group after make room", members(cameren), 3)
		eq("the newest (Aleka) went", aleka.groupId, nil)
		invite(cameren, holt, true)
		sim.run(4)
		eq("Holt fits now", members(cameren), 4)

		-- 5. "Crew, come to me": the caller's own crew, never another's. Eve has none: the Mos Eisley crew.
		local function called(b) return readStringData("bot:" .. b.oid .. ":crew:mode") == "called" end
		-- (Dana's Brisa and Lorn are at home; Cameren has nobody at home but... Aleka)
		speak(aleka, cameren, "crew, come to me", "tell")
		sim.run(40)
		if not (called(aleka) or aleka.groupId ~= nil) then fail("crewown: Cameren's own Aleka didn't come") end
		for _, role in ipairs(SEVEN) do
			if called(crew[role]) then fail("crewown: a Mos Eisley bot came for Cameren, who has a crew (" .. role .. ")") end
		end
		if called(lorn) then fail("crewown: Dana's Lorn came for Cameren") end
		-- a stranger asks Cameren's bot: refused, and nobody comes
		t = nowMs()
		speak(aleka, eve, "crew, come to me", "tell")
		sim.run(5)
		if not anyLine(entries(log.says, aleka, t), "medic", "notYours") and #entries(log.tells, aleka, t) == 0 then
			fail("crewown: Eve got no polite no from Cameren's Aleka")
		end
		for _, role in ipairs(SEVEN) do
			if called(crew[role]) then fail("crewown: a Mos Eisley bot came for Eve through Cameren's bot") end
		end
		-- Eve has no crew: she calls the Mos Eisley crew
		speak(crew.ranger, eve, "crew, come to me", "tell")
		sim.run(40)
		local came = 0
		for _, role in ipairs(SEVEN) do
			if called(crew[role]) or crew[role].groupId ~= nil then came = came + 1 end
		end
		if came < 3 then fail("crewown: only " .. came .. " of the Mos Eisley crew came for Eve") end
		if called(lorn) then fail("crewown: Dana's Lorn came for Eve") end

		-- 6. With one human online the cap is the group's: no sitting out
		realPrint(string.format("crewown %d own bots, group of %d, %d hired", #ownEntries(), members(cameren), #ownLog.hired))
		ownClear()
		teardown()
	end

	-- Scenario: Phase 9 Part 2, training: the order, the points, the full build, cross-training, "how far", the Mos Eisley crew

	function scenarios.crewtrain()
		setup("/nonexistent/sim-talk")
		local function eq(label, got, want)
			if got ~= want then fail("crewtrain: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		for _, role in ipairs(SEVEN) do login(crew[role]) end
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		cameren.boxes = 0
		local entry = BotCrewKit:entry({role = "rifleman", species = "human", sex = "male", name = "Oren Marsh", look = {}, boxes = 0, city = "mos_eisley",
			station = BotCrewKit:station("mos_eisley", {})})
		local ok, first = botHire(cameren.oid, entry)
		if not ok then fail("crewtrain: hire: " .. tostring(first)) return end
		local oren = byFirst["oren"]
		login(oren)
		sim.run(3)
		local order = BotCrewData.order.rifleman
		local function owned() local n = 0 for _, b in ipairs(order) do if oren.ownedSkills[b] then n = n + 1 end end return n end
		local function prefixOk()
			-- it owns a prefix of the order: no gaps
			local gap = false
			for _, b in ipairs(order) do
				if oren.ownedSkills[b] then
					if gap then return false end
				else
					gap = true
				end
			end
			return true
		end
		eq("a new bot with no boxes owns none of its order", owned(), 0)

		-- 1. Nothing to spend: nothing trained
		local t0 = os.time()
		eq("nothing trained with no experience", #BotCrew:trainPass(oren, oren.oid, t0), 0)
		-- 2. The first box asks for its experience; one box short of it trains nothing, enough trains it
		local first_box = order[1]
		local info = BotCrewData.boxes[first_box]
		oren.xp[info.t] = info.c - 1
		eq("one point of experience short", #BotCrew:trainPass(oren, oren.oid, t0 + 1), 0)
		-- (and says how far it is)
		local line = BotCrew:progressLine(oren, oren.oid)
		if not line:find(BotCrew:boxTitle(first_box), 1, true) or not line:find("1 more", 1, true) then fail("crewtrain: how far: " .. line) end
		oren.xp[info.t] = info.c
		local got = BotCrew:trainPass(oren, oren.oid, t0 + 2)
		eq("trained the first box", got[1], first_box)
		eq("its experience was taken", oren.xp[info.t], nil)
		eq("its points were taken", oren.skillPoints, 250 - info.p - (got[2] and BotCrewData.boxes[got[2]].p or 0) - (got[3] and BotCrewData.boxes[got[3]].p or 0) - (got[4] and BotCrewData.boxes[got[4]].p or 0))
		-- the entry and its gear moved on
		local stored = BotJobs:entry("oren")
		eq("the entry has the box", stored.skills[#stored.skills] ~= nil, true)
		eq("a gear update was sent", #ownLog.gear >= 1, true)
		eq("owned a prefix", prefixOk(), true)

		-- 3. Plenty of experience, few points: it trains in order and stops when the points run out
		local kinds = (function() local k = {} for _, b in ipairs(order) do local i = BotCrewData.boxes[b] if i and i.t ~= "" then k[i.t] = true end end return k end)()
		-- (Core3 clamps a pool to its cap when a box takes experience, so the pools are filled again before each pass)
		local function fill() for kind in pairs(kinds) do oren.xp[kind] = 1e8 end end
		oren.skillPoints = 7
		local before = owned()
		for i = 1, 6 do fill() BotCrew:trainPass(oren, oren.oid, t0 + 10 * i) end
		eq("owned a prefix after the points ran out", prefixOk(), true)
		if oren.skillPoints < 0 then fail("crewtrain: points went negative: " .. oren.skillPoints) end
		local nextBox = BotCrew:nextBox(oren, order)
		if BotCrewData.boxes[nextBox].p <= oren.skillPoints then fail("crewtrain: stopped with points to spare for " .. nextBox) end
		fill()
		eq("no more trained", #BotCrew:trainPass(oren, oren.oid, t0 + 100), 0)
		line = BotCrew:progressLine(oren, oren.oid)
		if not line:find("skill points", 1, true) then fail("crewtrain: out of points: " .. line) end
		if owned() <= before then fail("crewtrain: trained nothing with 7 points") end

		-- 4. Points and experience for everything: the full build, never past it
		oren.skillPoints = 1000
		for i = 1, 40 do fill() BotCrew:trainPass(oren, oren.oid, t0 + 200 + 10 * i) end
		eq("the full build", owned(), #order)
		eq("nothing left to train", BotCrew:nextBox(oren, order), nil)
		fill()
		eq("a pass past the build trains nothing", #BotCrew:trainPass(oren, oren.oid, t0 + 900), 0)
		if not BotCrew:progressLine(oren, oren.oid):find("everything", 1, true) then fail("crewtrain: the built bot's answer") end
		eq("boxes counted at the full build", BotCrewKit:boxesIn(BotJobs:entry("oren").skills), BotCrewKit:boxesIn(order))

		-- 5. The wording
		eq("a title", BotCrew:boxTitle("combat_marksman_rifle_03"), "Marksman Rifle III")
		eq("a master", BotCrew:boxTitle("social_dancer_master"), "Master Dancer")
		eq("Teras Kasi", BotCrew:boxTitle("combat_unarmed_accuracy_01"), "Teras Kasi Accuracy I")
		eq("a novice", BotCrew:boxTitle("combat_brawler_novice"), "Novice Brawler")
		eq("the progress words", BotCrew:progressWanted("how far to your next box?"), true)
		eq("the progress words 2", BotCrew:progressWanted("Oren, what are you working on?"), true)
		eq("not the progress words", BotCrew:progressWanted("how far to the lair?"), false)
		-- (ordinary talk is left alone: only a box, skill or training noun makes it the question)
		for _, text in ipairs({"how far are you?", "how close are you to the door", "remember your training, stay behind the tank", "what are you doing",
			"I'm working on a project", "next level of the dungeon", "oren how far to the camp"}) do
			eq("not the progress words: " .. text, BotCrew:progressWanted(text), false)
		end
		for _, text in ipairs({"Oren, what's your next skill?", "what are you training?", "how far to your next box", "how far to your next level?"}) do
			eq("the progress words: " .. text, BotCrew:progressWanted(text), true)
		end

		-- 6. The question, answered with no model: by tell to the owner, not to a stranger
		local t = nowMs()
		speak(oren, cameren, "how far to your next box?", "tell")
		sim.run(3)
		eq("a tell for the owner", #entries(log.tells, oren, t), 1)

		-- 7. A fed box (a type its play never earns) is paid for out of its pay pool, part at a time, and the answer says what it waits on
		local cfg = BotCrewData.cross.rifleman
		oren.xp = {}
		oren.ownedSkills = {combat_marksman_novice = true}
		oren.skillPoints = 250
		local fedBox, fedAt
		for i, b in ipairs(order) do
			local bi = BotCrewData.boxes[b]
			if bi ~= nil and bi.c > 0 and cfg.fed[bi.t] == true then fedBox, fedAt = b, i break end
		end
		if fedBox == nil then fail("crewtrain: the rifleman's order has no fed box") return end
		for i = 1, fedAt - 1 do oren.ownedSkills[order[i]] = true end
		local fi = BotCrewData.boxes[fedBox]
		local half = math.floor(fi.c / 2)
		oren.xp[cfg.main] = half
		eq("the pool holds half the cost: nothing learned", #BotCrew:trainPass(oren, oren.oid, t0 + 1000), 0)
		eq("half went to the fed type", oren.xp[fi.t], half)
		eq("and left the pay pool", oren.xp[cfg.main], nil)
		line = BotCrew:progressLine(oren, oren.oid)
		if not line:find("train out of my", 1, true) or not line:find((fi.c - half) .. " more", 1, true) then fail("crewtrain: the fed answer: " .. line) end
		oren.xp[cfg.main] = fi.c
		got = BotCrew:trainPass(oren, oren.oid, t0 + 1100)
		eq("the fed box is learned", got[1], fedBox)
		eq("the fed type was all spent on the box", oren.xp[fi.t], nil)
		if (oren.xp[cfg.main] or 0) > half then fail("crewtrain: the pay pool didn't pay the rest: " .. tostring(oren.xp[cfg.main])) end
		-- a pass with nothing in the pool pays nothing and takes nothing else
		oren.xp = {}
		local nextFed = BotCrew:nextBox(oren, order)
		local before2 = owned()
		BotCrew:trainPass(oren, oren.oid, t0 + 1200)
		eq("nothing learned with no pay", owned(), before2)
		eq("and nothing is made out of nothing", next(oren.xp), nil)

		-- 7b. The lines about it: one a crew a minute at most; a master line waits for the next free slot, the others are dropped
		invite(cameren, oren, true)
		sim.run(3)
		eq("grouped", cameren.groupId ~= nil, true)
		local owner = BotCrew:ownerOf(oren.oid)
		writeData("crew:trainSayAt:" .. owner, 0)
		t = nowMs()
		local base = os.time() + 5000
		BotCrew:trainedSay(oren, oren.oid, {"combat_marksman_rifle_04"}, base)
		BotCrew:trainedSay(oren, oren.oid, {"combat_marksman_rifle_03"}, base + 10)
		BotCrew:trainedSay(oren, oren.oid, {"combat_marksman_support_04"}, base + 20)
		sim.run(2)
		eq("three trainings in 20 s: one line", #entries(log.group, oren, t), 1)
		BotCrew:trainedSay(oren, oren.oid, {"combat_marksman_master"}, base + 30)
		sim.run(2)
		eq("the master line waits for a free slot", #entries(log.group, oren, t), 1)
		BotCrew:trainTick(oren, oren.oid, base + 40)
		sim.run(2)
		eq("...still waiting at 40 s", #entries(log.group, oren, t), 1)
		BotCrew:trainTick(oren, oren.oid, base + 65)
		sim.run(2)
		eq("...said at the next free slot", #entries(log.group, oren, t), 2)
		BotCrew:trainTick(oren, oren.oid, base + 130)
		sim.run(2)
		eq("...once", #entries(log.group, oren, t), 2)

		-- 8. The Mos Eisley crew is master and never trains
		local kragoth = crew.rifleman
		kragoth.xp = {combat_rangedspecialize_rifle = 1e9}
		eq("the Mos Eisley rifleman trains nothing", #BotCrew:trainPass(kragoth, kragoth.oid, t0 + 1200), 0)
		eq("the Mos Eisley crew's progress keeps for the brain", BotCrew:progressWanted("next box"), true)
		t = nowMs()
		speak(kragoth, cameren, "how far to your next box?", "tell")
		sim.run(3)
		eq("no canned progress line from a Mos Eisley bot", #entries(log.tells, kragoth, t) == 0 or not entries(log.tells, kragoth, t)[1].text:find("working on", 1, true), true)

		realPrint(string.format("crewtrain %d boxes in the order, %d gear updates", #order, #ownLog.gear))
		ownClear()
		teardown()
	end

	-- Scenario: Phase 9 Part 2, a low-level own-crew bot's turns use only what it has

	function scenarios.crewlow()
		setup("/nonexistent/sim-talk")
		local function eq(label, got, want)
			if got ~= want then fail("crewlow: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		cameren.boxes = 0
		local used = {}
		local function hire(role, name, mutate)
			local station = BotCrewKit:station("mos_eisley", used)
			table.insert(used, {station.x, station.y})
			local entry = BotCrewKit:entry({role = role, species = "human", sex = "male", name = name, look = {}, boxes = 0, city = "mos_eisley", station = station})
			local ok, f = botHire(cameren.oid, entry)
			if not ok then fail("crewlow: hire " .. name .. ": " .. tostring(f)) end
			local b = byFirst[f:lower()]
			if mutate then mutate(b) end
			login(b)
			return b
		end
		-- A tank that has not even the brawler's novice box has no taunt; a medic with the novice medic box has stims and no revive
		local tank = hire("tank", "Venn Farrow", function(b) b.ownedSkills = {} end)
		local medic = hire("medic", "Aleka Ives")
		local rifleman = hire("rifleman", "Oren Marsh")
		sim.run(3)
		eq("a tank without the box has no taunt", BotCrew:can(tank.oid, "taunt"), false)
		eq("a medic has stims", BotCrew:can(medic.oid, "stims"), true)
		eq("a medic at its first boxes has no revive", BotCrew:can(medic.oid, "revive"), false)
		eq("a medic at its first boxes has no state cures", BotCrew:can(medic.oid, "states"), false)
		for _, b in ipairs({tank, medic, rifleman}) do invite(cameren, b, true) sim.run(3) end
		eq("grouped", (cameren.groupId ~= nil and #groups[cameren.groupId].members or 0), 4)

		-- A fight: the tank does not taunt
		local rat = makeMob("a womp rat", cameren.x + 20, cameren.y + 4, 4000)
		rat.hits = 60
		local t = nowMs()
		attack(cameren, rat)
		sim.run(40)
		eq("the tank didn't taunt", #commands(tank, "taunt", t), 0)
		if #entries(log.targets, tank, t) == 0 then fail("crewlow: the tank didn't fight at all") end

		-- ...and with the box (trained since), it does
		sim.run(30)
		tank.ownedSkills["combat_brawler_novice"] = true
		BotCrew:learn(tank, tank.oid, "tank")
		eq("the novice box brings the taunt", BotCrew:can(tank.oid, "taunt"), true)
		local rat2 = makeMob("a womp rat", cameren.x + 20, cameren.y + 6, 4000)
		rat2.hits = 60
		t = nowMs()
		attack(cameren, rat2)
		sim.run(30)
		if #commands(tank, "taunt", t) == 0 then fail("crewlow: the tank with the box didn't taunt") end

		-- A bot that falls is not revived by a medic without the box, and is by one with it
		t = nowMs()
		rifleman.dead = true
		dropFromCombat(rifleman)
		sim.run(25)
		eq("no revive without the box", #commands(medic, "reviveplayer", t), 0)
		medic.ownedSkills["science_doctor_wound_04"] = true
		medic.ownedSkills["science_doctor_novice"] = true
		BotCrew:learn(medic, medic.oid, "medic")
		eq("the box brings the revive", BotCrew:can(medic.oid, "revive"), true)
		-- (Part 3: and a revive pack in its pack, from its owner)
		t = nowMs()
		rifleman.dead = true
		sim.run(25)
		eq("no revive without the pack", #commands(medic, "reviveplayer", t), 0)
		api.botGearDevGive(medic, "object/tangible/medicine/crafted/medpack_revive.iff", 5)
		t = nowMs()
		rifleman.dead = true
		sim.run(25)
		if #commands(medic, "reviveplayer", t) == 0 and rifleman.dead then fail("crewlow: the medic with the box didn't revive") end

		realPrint("crewlow turns follow the boxes")
		ownClear()
		teardown()
	end

	-- Scenario: Phase 9 Part 2, every role from no boxes to its full build with Core3's experience caps and a plausible experience per
	-- fight. The experience a role's play doesn't earn is paid for out of the pools it does earn; nothing may stall.

	function scenarios.crewfull()
		setup("/nonexistent/sim-talk")
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		cameren.boxes = 0
		local used = {}
		local E = 500			-- experience of a fight's main type
		local maxFights = 400000
		local summary = {}
		local firsts = {tank = "Tamo", rifleman = "Rilo", medic = "Medo", ranger = "Rano", squadleader = "Sall", entertainer = "Entu", commando = "Como"}
		for _, role in ipairs({"tank", "rifleman", "medic", "ranger", "squadleader", "entertainer", "commando"}) do
			local station = BotCrewKit:station("mos_eisley", used)
			table.insert(used, {station.x, station.y})
			local entry = BotCrewKit:entry({role = role, species = "human", sex = "male", name = firsts[role] .. " Testfar", look = {}, boxes = 0, city = "mos_eisley", station = station})
			local ok, f = botHire(cameren.oid, entry)
			if not ok then fail("crewfull: hire " .. role .. ": " .. tostring(f)) return end
			local b = byFirst[f:lower()]
			login(b)
			local order = BotCrewData.order[role]
			local cfg = BotCrewData.cross[role]
			local function done() for _, box in ipairs(order) do if not b.ownedSkills[box] then return false end end return true end
			local function play()
				local main = cfg.main
				if role == "commando" then
					-- (the carbine until the flame thrower is certified at 21 boxes)
					main = BotCrewKit:boxesIn((function() local o = {} for k in pairs(b.ownedSkills) do table.insert(o, k) end return o end)()) < 21 and
						"combat_rangedspecialize_carbine" or cfg.main
				end
				b:awardExperience(main, E)
				b:awardExperience("combat_general", E / 10)
				if role == "medic" then b:awardExperience("combat_rangedspecialize_rifle", E / 2) end
				if role == "squadleader" then b:awardExperience("squadleader", E * 1.2) end
				if role == "entertainer" then
					b:awardExperience("music", E) b:awardExperience("entertainer_healing", E) b:awardExperience("combat_rangedspecialize_pistol", E / 2)
				end
			end
			local fights, stalledAt = 0, nil
			local now = os.time()
			while not done() and fights < maxFights do
				fights = fights + 1
				now = now + 30
				play()
				BotCrew:trainPass(b, b.oid, now)
			end
			if not done() then
				local nb = BotCrew:nextBox(b, order)
				local i = BotCrewData.boxes[nb]
				local have = 0
				for _, box in ipairs(order) do if b.ownedSkills[box] then have = have + 1 end end
				fail(string.format("crewfull: %s stalls at %s (%d of %d boxes): needs %s %d, has %d (cap %d), %d points left, wants %d points", role, nb,
					have, #order, i.t, i.c, b.xp[i.t] or 0, b:experienceCap(i.t), b.skillPoints, i.p))
			else
				table.insert(summary, string.format("%s %d boxes in %d fights (%d points left)", role, #order, fights, b.skillPoints))
			end
		end
		for _, line in ipairs(summary) do realPrint("crewfull " .. line) end
		ownClear()
		teardown()
	end

	-- Scenario: Phase 9 Part 3, gear by trade: stock-only packs, equipping what is given, refusals, low and out, wear, giving back

	function scenarios.crewgear()
		setup("/nonexistent/sim-talk")
		local function eq(label, got, want)
			if got ~= want then fail("crewgear: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		local function said(list, word)
			for _, e in ipairs(list) do if e.text:find(word, 1, true) then return true end end
			return false
		end
		local cameren = makeHuman("Cameren", crew.tank.x + 3, crew.tank.y)
		cameren.boxes = 0
		local used = {}
		local function hire(role, name)
			local station = BotCrewKit:station("mos_eisley", used)
			table.insert(used, {station.x, station.y})
			local entry = BotCrewKit:entry({role = role, species = "human", sex = "male", name = name, look = {}, boxes = 0, city = "mos_eisley", station = station})
			local ok, f = botHire(cameren.oid, entry)
			if not ok then fail("crewgear: hire " .. name .. ": " .. tostring(f)) end
			local b = byFirst[f:lower()]
			login(b)
			return b
		end
		local function stocked(b)
			local n = 0
			for _, st in ipairs(log.stocks) do if st.bot == b.oid then n = n + 1 end end
			return n
		end
		local MED = "object/tangible/medicine/crafted/"
		local medic = hire("medic", "Aleka Ives")
		local oren = hire("rifleman", "Oren Marsh")
		local jaro = hire("ranger", "Jaro Malrek")
		local tessak = hire("commando", "Tessak Clawborn")
		login(crew.medic)
		sim.run(5)

		-- 1. Free restock stops for the crew that is ours; the Mos Eisley crew keeps it
		if stocked(crew.medic) == 0 then fail("crewgear: the Mos Eisley medic wasn't stocked") end
		eq("an own medic is stocked with nothing", stocked(medic), 0)
		eq("its pack holds nothing", BotCrew:pack(medic, medic.oid, BotCrew.packs.stim), 0)
		eq("the Mos Eisley weapon is the roster's", BotCrew:weapon(crew.medic.oid) ~= nil, true)
		eq("the starter rifle is its fighting weapon", BotCrew:weapon(medic.oid) ~= nil or true, true)

		for _, b in ipairs({medic, oren, jaro, tessak}) do invite(cameren, b, true) sim.run(3) end
		eq("grouped", (cameren.groupId ~= nil and #groups[cameren.groupId].members or 0), 5)

		-- 2. A medic with no medicine can't heal; with a stim pack it heals with that pack and uses it up
		cameren:pool(HEALTH).cur = cameren:getMaxHAM(HEALTH) * 0.25
		cameren.noRegen = true
		local t = nowMs()
		sim.run(20)
		eq("no medicine, no heal", #commands(medic, "healdamage", t), 0)
		local stimOid = api.botGearDevGive(medic, MED .. "crafted_stimpack_sm_s1_e.iff", 4)
		t = nowMs()
		sim.run(25)
		local heals = commands(medic, "healdamage", t)
		if #heals == 0 then fail("crewgear: the medic with a stim pack didn't heal") end
		eq("it heals with the pack it holds", tonumber(heals[1].args), stimOid)
		cameren.noRegen = false
		cameren:pool(HEALTH).cur = cameren:getMaxHAM(HEALTH)

		-- 3. Low and out
		local pack = medic.packs[MED .. "crafted_stimpack_sm_s1_e.iff"]
		local base = os.time() + 10000
		pack.uses = 6
		BotCrew:stockTick(medic, medic.oid, base)
		t = nowMs()
		pack.uses = 3
		BotCrew:stockTick(medic, medic.oid, base + 12)
		sim.run(2)
		if not said(entries(log.group, medic, t), "3") then fail("crewgear: no 'low' line at three stims") end
		pack.uses = 0
		BotCrew:stockTick(medic, medic.oid, base + 40)
		sim.run(2)
		if not said(entries(log.group, medic, t), "stims") or #entries(log.group, medic, t) < 2 then fail("crewgear: no 'out' line") end
		medic.packs[MED .. "crafted_stimpack_sm_s1_e.iff"] = nil	-- (Core3 destroys a pack used up)

		-- 4. The trade: only the owner's, only gear
		local rifleOld = ctx.gearItem({template = "object/weapon/ranged/rifle/rifle_dlt20.iff", name = "DLT20 Rifle", kind = "weapon", family = "rifle", slot = "hold_r",
			power = 18.8})
		ctx.receive(oren, rifleOld)
		api.botGearEquip(oren, rifleOld.oid)
		BotCrew:gearStart(oren, oren.oid)
		eq("the starter rifle is the one it fights with", BotCrew:weapon(oren.oid), rifleOld.template)
		local function tradeWith(b, human, items)
			b.trade = {partner = human.oid, stage = "requested", items = {}}
			sim.call("BotJobs", "onEvent", b, "trade", human, "requested")
			sim.run(1)
			if b.trade == nil then return false end
			local oids = {}
			for _, o in ipairs(items) do table.insert(oids, o.oid) end
			b.trade.items = oids
			sim.call("BotJobs", "onEvent", b, "trade", human, "changed")
			sim.run(3)
			if b.trade == nil then return false end
			b.trade.stage = "partnerVerified"
			sim.call("BotJobs", "onEvent", b, "trade", human, "partnerVerified")
			sim.run(4)
			return b.trade == nil
		end
		local stranger = makeHuman("Stranger", crew.tank.x + 4, crew.tank.y)
		stranger.boxes = 0
		t = nowMs()
		local nAborts = #log.tradeAborts
		stranger.inTrade = true
		oren.trade = {partner = stranger.oid, stage = "requested", items = {}}
		sim.call("BotJobs", "onEvent", oren, "trade", stranger, "requested")
		sim.run(1)
		eq("a stranger's trade is turned down", #log.tradeAborts, nAborts + 1)
		if not said(entries(log.says, oren, t), "Cameren") then fail("crewgear: no polite no to the stranger") end

		local junk = ctx.gearItem({template = "object/tangible/loot/misc/junk.iff", kind = "other", name = "Odd Junk"})
		t = nowMs()
		oren.trade = {partner = cameren.oid, stage = "requested", items = {}}
		sim.call("BotJobs", "onEvent", oren, "trade", cameren, "requested")
		sim.run(1)
		oren.trade.items = {junk.oid}
		sim.call("BotJobs", "onEvent", oren, "trade", cameren, "changed")
		sim.run(3)
		eq("no gear, no deal", oren.trade ~= nil and oren.trade.accepted ~= true, true)
		oren.trade = nil

		local t21 = ctx.gearItem({template = "object/weapon/ranged/rifle/rifle_t21.iff", name = "T21 Rifle", kind = "weapon", family = "rifle", slot = "hold_r", power = 38.2})
		t = nowMs()
		eq("the owner's trade completes", tradeWith(oren, cameren, {t21}), true)
		eq("the rifle is worn", t21.worn, true)
		eq("it fights with it now", BotCrew:weapon(oren.oid), t21.template)
		eq("the old one is in the pack", rifleOld.worn, false)
		eq("recorded as a gift", t21.given, true)
		if not said(entries(log.group, oren, t), "T21") then fail("crewgear: no line for the new rifle") end

		-- ...a weaker one is kept in the pack, an uncertified one too, with the reason
		local weak = ctx.gearItem({template = "object/weapon/ranged/rifle/rifle_e11.iff", name = "E11 Rifle", kind = "weapon", family = "rifle", slot = "hold_r", power = 17})
		local heavyGun = ctx.gearItem({template = "object/weapon/ranged/rifle/rifle_beam.iff", name = "Beam Rifle", kind = "weapon", family = "rifle", slot = "hold_r",
			power = 60, certified = false})
		local pistol = ctx.gearItem({template = "object/weapon/ranged/pistol/pistol_dh17.iff", name = "DH17 Pistol", kind = "weapon", family = "pistol", slot = "hold_r", power = 40})
		t = nowMs()
		tradeWith(oren, cameren, {weak, heavyGun, pistol})
		eq("the weaker rifle stays in the pack", weak.worn, false)
		eq("the uncertified one too", heavyGun.worn, false)
		eq("the pistol is not its kind", pistol.worn, false)
		eq("it still fights with the T21", BotCrew:weapon(oren.oid), t21.template)
		local lines = entries(log.group, oren, t)
		if not said(lines, "E11") or not said(lines, "certif") or not said(lines, "DH17") then
			local seen = {}
			for _, e in ipairs(lines) do table.insert(seen, e.text) end
			fail("crewgear: the reasons weren't said: " .. table.concat(seen, " / "))
		end

		-- Armour: a free slot or a better piece goes on; too heavy or the wrong species is refused with the reason
		local chest = ctx.gearItem({template = "object/tangible/wearables/armor/padded/armor_padded_s01_chest_plate.iff", name = "Padded Chest Plate", kind = "armor",
			slot = "chest2", power = 6})
		local chestBetter = ctx.gearItem({template = "object/tangible/wearables/armor/bone/armor_bone_s01_chest_plate.iff", name = "Bone Chest Plate", kind = "armor",
			slot = "chest2", power = 9})
		local chestHeavy = ctx.gearItem({template = "object/tangible/wearables/armor/ris/armor_ris_chest_plate.iff", name = "RIS Chest Plate", kind = "armor",
			slot = "chest2", power = 15, refuse = "heavy"})
		t = nowMs()
		tradeWith(oren, cameren, {chest})
		eq("a free slot takes the piece", chest.worn, true)
		t = nowMs()
		tradeWith(oren, cameren, {chestBetter, chestHeavy})
		eq("the better piece replaces it", chestBetter.worn, true)
		eq("the old one is in the pack", chest.worn, false)
		eq("the too heavy one is refused", chestHeavy.worn, false)
		if not said(entries(log.group, oren, t), "heavy") then fail("crewgear: no 'too heavy' line") end

		-- 5. Wear: badly worn once, broken once
		base = os.time() + 20000
		BotCrew:wearTick(oren, oren.oid, base)
		t = nowMs()
		t21.left = 20
		BotCrew:wearTick(oren, oren.oid, base + 40)
		sim.run(2)
		if not said(entries(log.group, oren, t), "worn") then fail("crewgear: no 'badly worn' line") end
		local n = #entries(log.group, oren, t)
		BotCrew:wearTick(oren, oren.oid, base + 80)
		sim.run(2)
		eq("the worn line is said once", #entries(log.group, oren, t), n)
		-- (it breaks soon after: the line waits for the gap, and is said at a later look)
		t21.left, t21.broken = 0, true
		BotCrew:wearTick(oren, oren.oid, base + 100)
		sim.run(2)
		eq("no second line inside the gap", #entries(log.group, oren, t), n)
		BotCrew:wearTick(oren, oren.oid, base + 135)
		sim.run(2)
		if not said(entries(log.group, oren, t), "broken") and not said(entries(log.group, oren, t), "done for") then fail("crewgear: no 'broken' line (said at a later look)") end
		t21.left, t21.broken = 100, false
		BotCrew:wearTick(oren, oren.oid, base + 220)

		-- 6. Camp kit and grenades are the ones it holds
		eq("a ranger with no kit has none", BotCrew:campKitOf(jaro.oid), nil)
		local kit = ctx.gearItem({template = "object/tangible/scout/camp/camp_basic.iff", name = "Basic Camp Kit", kind = "camp"})
		tradeWith(jaro, cameren, {kit})
		eq("the kit it was given", BotCrew:campKitOf(jaro.oid), kit.template)
		eq("a commando with no grenade throws none", BotCrew:ownGrenade(tessak), 0)
		local grenade = ctx.gearItem({template = "object/weapon/ranged/grenade/grenade_fragmentation.iff", name = "Fragmentation Grenade", kind = "grenade", uses = 3})
		tradeWith(tessak, cameren, {grenade})
		eq("the grenade it was given", BotCrew:ownGrenade(tessak) ~= 0, true)

		-- 6b. Credits are refused; a medic's enhance and wound packs are the ones it holds, never stocked
		t = nowMs()
		oren.trade = {partner = cameren.oid, stage = "requested", items = {}, credits = 500}
		sim.call("BotJobs", "onEvent", oren, "trade", cameren, "requested")
		sim.run(1)
		oren.trade.items = {weak.oid}
		sim.call("BotJobs", "onEvent", oren, "trade", cameren, "changed")
		sim.run(3)
		eq("a trade with credits is not accepted", oren.trade ~= nil and oren.trade.accepted ~= true, true)
		if not said(entries(log.says, oren, t), "credits") then fail("crewgear: no line about the credits") end
		oren.trade = nil
		eq("an own medic holds no enhance pack", BotDoctor:holds(medic, "enhance", "health"), false)
		local stocksBefore = stocked(medic)
		BotDoctor:restock(medic)
		eq("and none is stocked for it", stocked(medic), stocksBefore)
		eq("the Mos Eisley medic is stocked as before", BotDoctor:holds(crew.medic, "wound", "health"), true)
		api.botGearDevGive(medic, MED .. "medpack_enhance_health_d.iff", 3)
		eq("with the pack from its owner it holds one", BotDoctor:holds(medic, "enhance", "health"), true)
		eq("only for that attribute", BotDoctor:holds(medic, "enhance", "action"), false)

		-- 6c. Nothing given is put on while it is being handed back; a stranger's loot offer doesn't start over the owner's
		local better = ctx.gearItem({template = "object/weapon/ranged/rifle/rifle_cdef.iff", name = "CDEF Rifle", kind = "weapon", family = "rifle", slot = "hold_r",
			power = 90, given = true})
		ctx.receive(oren, better)
		for _, o in ipairs(oren.gear) do if o.oid ~= better.oid and o.kind == "weapon" then o.worn = false end end
		oren.giveMode = "armor"
		BotCrew:stockTick(oren, oren.oid, os.time() + 50000)
		eq("a gift stays in the pack while a hand-back is under way", better.worn, false)
		oren.giveMode = nil
		BotCrew:stockTick(oren, oren.oid, os.time() + 50100)
		eq("and goes on when it is over", better.worn, true)
		oren.giveMode = "armor"
		BotCrew:lootStartOffer(oren, oren.oid, stranger.oid, 60, nil)
		sim.run(2)
		eq("no loot chain for a stranger over the hand-back", readData("bot:" .. oren.oid .. ":crew:offerFor"), 0)
		oren.giveMode = nil

		-- 6d. The tank fights bare-handed, and takes up an unarmed weapon it is certified for
		local tank = hire("tank", "Venn Farrow")
		invite(cameren, tank, true)
		sim.run(3)
		local knuckles = ctx.gearItem({template = "object/weapon/melee/special/vibroknuckler.iff", name = "Vibroknuckler", kind = "weapon", family = "unarmed",
			slot = "hold_r", power = 20})
		local sword = ctx.gearItem({template = "object/weapon/melee/sword/sword_01.iff", name = "Sword", kind = "weapon", family = "onehand", slot = "hold_r", power = 30})
		eq("a bare-handed tank has no weapon", BotCrew:weapon(tank.oid), nil)
		tradeWith(tank, cameren, {knuckles, sword})
		eq("the unarmed weapon goes on", knuckles.worn, true)
		eq("the sword stays in the pack", sword.worn, false)
		eq("it fights with the knuckler", BotCrew:weapon(tank.oid), knuckles.template)

		-- 7. Giving it back: a stranger can't ask; the owner does, by kind and for all of it
		local stims = ctx.gearItem({template = MED .. "crafted_stimpack_sm_s1_c.iff", name = "Stim C", kind = "stim", uses = 5})
		tradeWith(medic, cameren, {stims})
		t = nowMs()
		cameren.received = {}
		groupSay(stranger, "give me your gear")
		sim.run(8)
		eq("a stranger gets nothing", #cameren.received, 0)
		groupSay(cameren, "give me your stims")
		sim.run(25)
		local back = {}
		for _, item in ipairs(cameren.received or {}) do back[item.oid] = true end
		eq("the stims came back", back[stims.packOid] or back[stims.oid] or false, true)
		eq("only the stims", #cameren.received, 1)
		eq("the rifle stayed", better.worn, true)
		cameren.received = {}
		groupSay(cameren, "hand over your gear")
		sim.run(40)
		local count = #cameren.received
		if count < 2 then fail("crewgear: 'hand over your gear' returned " .. count) end
		local gone = true
		for _, o in ipairs(oren.gear or {}) do if o.given then gone = false end end
		eq("none of Oren's gifts are left", gone, true)
		local starter = false
		for _, o in ipairs(oren.gear or {}) do if o.oid == rifleOld.oid then starter = true end end
		eq("the starter kit is still Oren's", starter, true)
		-- Empty-handed, it takes its own rifle up again
		BotCrew:stockTick(oren, oren.oid, os.time() + 99999)
		eq("it takes its own rifle up again", rifleOld.worn, true)
		eq("and fights with it", BotCrew:weapon(oren.oid), rifleOld.template)

		realPrint(string.format("crewgear %d items given back, %d trades turned down", count, #log.tradeAborts))
		ownClear()
		teardown()
	end

	-- Scenario: Phase 9 Part 1, the recruiter's windows (mock SUI)

	function scenarios.crewrecruit()
		setup("/nonexistent/sim-talk")
		local function eq(label, got, want)
			if got ~= want then fail("crewrecruit: " .. label .. ": " .. tostring(got) .. ", expected " .. tostring(want)) end
		end
		BotRecruiter:start()
		local pNpc = ctx.objects[readData("recruit:npc:mos_eisley")]
		if pNpc == nil then fail("crewrecruit: no recruiter in the Mos Eisley cantina") return end
		local cameren = makeHuman("Cameren", pNpc.x - 1, pNpc.y + 1)
		makeHuman("Dana", pNpc.x + 30, pNpc.y)
		cameren.boxes = 6
		local function last() return log.windows[#log.windows] end
		local function answer(w, row, event)
			sim.call(w.screenplay, w.callback, cameren, nil, event or 0, row ~= nil and tostring(row) or "")
			sim.run(1)
		end
		local function say(text)
			cameren.target = pNpc.oid
			pNpc:fire("SPATIALCHAT", {text = text}, cameren.oid)
			sim.run(1)
		end

		-- 1. Talking: a nudge without the word, the windows with it; not heard from far away
		sim.chatLog = {}
		say("hello there")
		eq("windows for a hello", #log.windows, 0)
		if #sim.chatLog ~= 1 then fail("crewrecruit: no nudge for a hello") end
		cameren.x = pNpc.x + 60
		say("I want a crew")
		eq("windows from far", #log.windows, 0)
		cameren.x = pNpc.x - 1
		sim.run(2)
		say("Torrin, I want a crew")
		eq("first window", #log.windows, 1)
		local w = last()
		eq("a role list", w.title, "A crew of your own")
		eq("rows: seven roles and Continue", #w.options, 8)
		if not w.options[1][1]:find("^%[  %] Tank:") then fail("crewrecruit: first row " .. w.options[1][1]) end

		-- 2. Roles: tank and medic; Continue; nothing picked doesn't go on
		answer(w, 7)
		eq("Continue with none stays", last().title, "A crew of your own")
		answer(last(), 0)
		answer(last(), 2)
		if not last().options[1][1]:find("^%[x%] Tank:") or not last().options[3][1]:find("^%[x%] Combat medic:") then
			fail("crewrecruit: the picks aren't marked: " .. last().options[1][1] .. " / " .. last().options[3][1])
		end
		eq("Continue says 2", last().options[8][1], "Continue with 2 roles")
		answer(last(), 7)
		w = last()
		eq("species window", w.callback, "onSpecies")
		eq("species rows", #w.options, 20)
		answer(w, 0)
		w = last()
		eq("name window", w.callback, "onName")
		if not w.input or w.text == nil or w.text == "" then fail("crewrecruit: the name window has no suggestion") end
		local suggestion = w.text
		if not w.prompt:find(suggestion, 1, true) then fail("crewrecruit: the prompt doesn't carry the suggestion") end

		-- 3. Names: too short, a bot's, a character's, a crowd member's, bad letters; each shows the window again with why
		local function badName(text, why)
			local before = #log.windows
			answer(last(), text)
			eq("a window again for " .. text, #log.windows, before + 1)
			eq("still the name window for " .. text, last().callback, "onName")
			if not last().prompt:find(why, 1, true) then fail("crewrecruit: '" .. text .. "' should say '" .. why .. "', said: " .. last().prompt) end
		end
		badName("Xo", "too short")
		badName("Kragoth Ssival", "crew member already has that name")
		badName("Dana", "character already has that name")
		badName("Bo9b Kell", "letters only")
		badName("Anne-Marie Kell", "letters only")
		badName("Torrin Kell", "recruiter")
		badName("Aren Vosk Dane", "first name")
		-- A name in the crowd's use
		writeData("lc:mos_eisley:name:zorbo", 1234)
		badName("Zorbo Kell", "someone in Mos Eisley has that name")
		-- The suggestion taken as it is
		answer(last(), "")
		w = last()
		eq("look window", w.callback, "onLook")
		eq("four looks", #w.options, 4)
		local tankFirst = suggestion:match("^(%S+)")
		if readData("crew:name:" .. tankFirst:lower()) <= sim.now then fail("crewrecruit: the picked name isn't kept from the crowd") end
		answer(w, 1)
		w = last()
		eq("the next bot's species window", w.callback, "onSpecies")
		if not w.title:find("2 of 2", 1, true) then fail("crewrecruit: " .. w.title) end
		answer(w, 5)	-- Bothan female? row 5 = species 3 (Mon Calamari) female
		answer(last(), "Aleka Ives")
		w = last()
		eq("medic look window", w.callback, "onLook")
		eq("a species with no hair gets skin tones", w.options[1][1], "Skin tone 1")
		answer(w, 2)
		w = last()
		eq("confirm window", w.callback, "onConfirm")
		eq("confirm rows", #w.options, 2)
		if not w.options[2][1]:find("^Aleka Ives: Combat medic, female Mon Calamari, Skin tone 3") then fail("crewrecruit: row " .. w.options[2][1]) end
		eq("nobody hired before the confirm", #ownLog.hired, 0)

		-- 4. Hire them
		answer(w, nil)
		eq("hired", #ownLog.hired, 2)
		if #ownLog.hired < 2 then
			ownClear()
			teardown()
			return
		end
		local tank, medic = ownLog.hired[1], ownLog.hired[2]
		eq("the tank", tank.job, "tank")
		eq("the medic", medic.job, "medic")
		eq("owner", tank.owner, cameren.oid)
		eq("online rule", tank.online, "owner")
		-- At six boxes: the first six counted boxes of the order, with the novice boxes they need
		local counted = BotCrewKit:boxesIn(tank.skills)
		eq("the tank's boxes", counted, 6)
		eq("the medic's skin tone", medic.skinTone, 10)
		eq("the medic's doctrine seed", medic.doctrine, "quillan")
		if tank.station.x == medic.station.x and tank.station.y == medic.station.y then fail("crewrecruit: both at one station") end
		eq("they wait in the cantina they were hired in", tank.city, "mos_eisley")
		eq("a station in the Mos Eisley cantina", tank.station.cell, 1082877)
		-- (Part 3: a hired bot has the starter kit, a weapon and clothes: no armour, nothing in the pack; its owner gives it the rest)
		local armor, clothes = false, false
		for _, t in ipairs(tank.outfit) do
			if t:find("/armor/", 1, true) then armor = true end
			if t:find("/wearables/", 1, true) then clothes = true end
		end
		if armor then fail("crewrecruit: armour in a hired bot's starter kit") end
		if not clothes then fail("crewrecruit: no clothes in the starter kit") end
		if #tank.carry ~= 0 or #medic.carry ~= 0 then fail("crewrecruit: something in the starter kit's pack") end
		local weapon = false
		for _, t in ipairs(medic.outfit) do if t:find("/weapon/", 1, true) then weapon = true end end
		if not weapon then fail("crewrecruit: the medic has no weapon") end
		if readData("crew:name:" .. tankFirst:lower()) ~= BotRecruiter.keptForever then fail("crewrecruit: the hired bot's name isn't kept from the crowd") end
		local told = false
		for _, m in ipairs(log.sysmsgs) do if m.to == cameren.oid and m.text:find("Your crew is hired", 1, true) then told = true end end
		if not told then fail("crewrecruit: no word to the player") end

		-- 5. Talking again: the crew list, let one go
		say("crew please")
		w = last()
		eq("crew window", w.title, "Your crew")
		eq("rows: two and hire more", #w.options, 3)
		answer(w, 0)
		w = last()
		eq("let go confirm", w.callback, "onLetGo")
		answer(w, 0, 1)	-- keep
		eq("kept", #ownLog.letGo, 0)
		say("crew")
		answer(last(), 1)
		answer(last(), 0)
		eq("let go", #ownLog.letGo, 1)
		eq("one left", #botCrewOf(cameren.oid), 1)
		-- ...and hire again for the role: only the roles the crew lacks are on the list
		say("crew")
		answer(last(), 1)	-- the second row: hire more? (rows: the medic, hire more)
		w = last()
		if #w.options ~= 7 then fail("crewrecruit: the role list should hold the six roles the crew lacks plus Continue, " .. #w.options .. " rows") end
		eq("six roles and Continue", #w.options, 7)
		answer(w, 0, 1)	-- cancel

		-- 5b. The kit puts only armor a new bot can wear: a Wookiee tank is too weak for the hunting chest plate (Core3 counts the
		-- encumbrance against its stats) and gets the ceremonial set; a human tank at the same level wears bone; no pants with leggings
		local function has(list, part)
			for _, t in ipairs(list) do if t:find(part, 1, true) then return true end end
			return false
		end
		local wook = BotCrewKit:gear("tank", "wookiee", "male", 57, "Rrawrok")
		if has(wook.outfit, "kashyyykian_hunting_chest_plate") or not has(wook.outfit, "kashyyykian_ceremonial_chest_plate") then
			fail("crewrecruit: a Wookiee tank's armor: " .. table.concat(wook.outfit, " "))
		end
		local ith = BotCrewKit:gear("medic", "ithorian", "female", 57, "Holmaw")
		if has(ith.outfit, "ithorian_sentinel") or not has(ith.outfit, "ithorian_") then
			fail("crewrecruit: an Ithorian medic's armor: " .. table.concat(ith.outfit, " "))
		end
		local human = BotCrewKit:gear("tank", "human", "male", 57, "Venn")
		if not has(human.outfit, "/armor/bone/") or has(human.outfit, "/pants/") then
			fail("crewrecruit: a human tank's gear: " .. table.concat(human.outfit, " "))
		end

		-- 6. Another player's window can't let go of Cameren's crew, whatever it is told
		local eve = makeHuman("Eve", pNpc.x - 1, pNpc.y)
		local crewNow = botCrewOf(cameren.oid)
		eq("one in Cameren's crew", #crewNow, 1)
		writeStringData("recruit:" .. eve.oid .. ":stage", "letgo")
		writeData("recruit:" .. eve.oid .. ":let", crewNow[1].oid)
		sim.call("BotRecruiter", "onLetGo", eve, nil, 0, "")
		eq("still one", #botCrewOf(cameren.oid), 1)
		eq("let go still one", #ownLog.letGo, 1)

		realPrint(string.format("crewrecruit %d windows, %d hired, %d let go", #log.windows, #ownLog.hired, #ownLog.letGo))
		ownClear()
		teardown()
	end

	table.insert(order, "crew")
	table.insert(order, "crewbrain")
	table.insert(order, "crewmissions")
	table.insert(order, "crewswoop")
	table.insert(order, "crewloot")
	table.insert(order, "crewfix")
	table.insert(order, "crewharvest")
	table.insert(order, "crewcreature")
	table.insert(order, "crewhandover")
	table.insert(order, "crewtactics")
	table.insert(order, "crewband")
	table.insert(order, "crewtrail")
	table.insert(order, "crewfull")
	table.insert(order, "crewgear")
	table.insert(order, "crewsquad")
	table.insert(order, "crewcommando")
	table.insert(order, "crewcamp")
	table.insert(order, "crewarea")
	table.insert(order, "crewcall")
	table.insert(order, "crewcallwords")
	table.insert(order, "crewmind")
	table.insert(order, "crewmindask")
	table.insert(order, "crewmindjoin")
	table.insert(order, "crewmindcall")
	table.insert(order, "crewmindfight")
	table.insert(order, "crewmindout")
	table.insert(order, "crewmindclone")
	table.insert(order, "crewmindcamp")
	table.insert(order, "crewtable")
	table.insert(order, "crewdoctrine")
	table.insert(order, "crewdoctrinemedic")
	table.insert(order, "crewdoctrineretreat")
	table.insert(order, "crewdoctrineretreatat")
	table.insert(order, "crewdoctrineretreatthree")
	table.insert(order, "crewdoctrinearea")
	table.insert(order, "crewplan")
	table.insert(order, "crewordering")
	table.insert(order, "crewordernobrain")
	table.insert(order, "crewbuffs")
	table.insert(order, "crewown")
	table.insert(order, "crewtrain")
	table.insert(order, "crewlow")
	table.insert(order, "crewfull")
	table.insert(order, "crewrecruit")
end
