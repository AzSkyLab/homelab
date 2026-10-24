-- Bot players (Phase 5): the hunting crew. Four bots wait in the Mos Eisley cantina like players looking for a group:
-- a tank (Teras Kasi), a rifleman, a medic (combat medic and doctor) and a ranger. Invite one (or ask "wanna hunt?")
-- and it joins, follows its leader's trail (BotMover), fights what the leader fights or whatever attacks the group,
-- heals, revives, camps and tracks, and goes home when dismissed. It never leads: a group it ends up leading is handed
-- to the player. Spec: ~/github/swgemu/specs/2026-10-23-bot-group-mates/ (the contract is
-- specs/2026-10-23-bot-players/interfaces.md, "Phases 4-6").
--
-- A job module (the interface is at the top of bot_jobs.lua), registered as tank, rifleman, medic and ranger. While a
-- crew bot is grouped, fighting or dead it runs its own loop of events on itself (every 1.5 s in a fight, 2.5 s out of
-- one); at home BotJobs' 5 s tick idles it. Lua state is per thread, so its state lives in shared memory under
-- bot:<oid>:crew:*, and every chain carries the bot's generation and its loop number. Other creatures are only read
-- with lock-free getters; what a player is fighting is read in an event on that player (scanHuman).
--
-- The medic's buffs in a camp reuse BotDoctor's treatment chain (doctor.lua): a camp counts as a medical site, as a
-- hospital does.
--
-- Console (output in the pod log), for bot-on-bot tests on the local server (no game client):
--   runLuaFunction BotCrew:devLead:<first>[:off]               treat a bot as a human leader (crew bots group with it)
--   runLuaFunction BotCrew:devInvite:<leader>:<crew>           the leader bot invites a crew bot
--   runLuaFunction BotCrew:devGroupSay:<leader>:<text>         the leader says <text> in group chat ("_" is a space)
--   runLuaFunction BotCrew:devAttack:<leader>:<oid>            the leader attacks an object (devPeace:<leader>: peace)
--   runLuaFunction BotCrew:devSpawn:<near>:<template>[:<m>]    spawn a creature <m> metres (default 25) north of a bot
--   runLuaFunction BotCrew:devWalk:<first>:<x>:<y>             a bot walks to a world point (outdoors)
--   runLuaFunction BotCrew:devState:<first>                    a crew bot's state

includeFile("../custom_scripts/screenplays/bots/crew_lines.lua")

-- CreatureAttribute, CreaturePosture, CreatureState
local HEALTH, ACTION, MIND = 0, 3, 6
local SITTING = 8
local CROUCHED = 1
local STATES = {0x1000, 0x2000, 0x4000, 0x8000} -- stunned, blinded, dizzy, intimidated: what healstate cures
local POISONED, DISEASED = 0x800000, 0x2000000

local CREW = {tank = true, rifleman = true, medic = true, ranger = true}
local MED = "object/tangible/medicine/crafted/"

BotCrew = ScreenPlay:new {
	screenplayName = "BotCrew",

	-- The loop (ms): in a fight, grouped out of one, dead or down
	fightMs = 1500,
	groupMs = 2500,
	deadMs = 3000,
	-- A loop that hasn't run for this long (s) while it should is started again by the job tick
	loopStale = 8,

	-- roster.lua settings, when it doesn't set them
	defaults = {specialsHam = 0.5, stimPower = 800, rangedStimPower = 800, curePower = 300, packStock = 20},

	-- Fighting
	engageRange = 80,     -- a target further than this is left alone
	meleeReach = 4,       -- unarmed reach, inside Core3's 5 m
	closeTo = 2,          -- the tank walks to this far from its target
	lungeRange = {6, 18}, -- unarmedlunge2 reaches 20 m
	tauntEvery = 12,      -- seconds between taunts while the target is on someone else
	ranges = {rifleman = 55, ranger = 50, medic = 40}, -- the ranged roles shoot within this (Core3's guns reach 64)
	leaderSpread = 30,    -- a ranged bot standing to shoot follows again when its leader is further than this
	holdFire = 10,        -- seconds without picking a fight after "back off"
	moveEvery = 3,        -- seconds between walks after a moving target
	attackerFresh = 5,    -- seconds an attacker seen on a group member counts
	pullChance = 30,      -- percent: the tank calls its pull in group chat

	-- Specials by role: the first a bot has of each family is used, picked by weight. Taunt and lunge are the
	-- tank's own (below); the medic heals instead.
	specials = {
		tank = {
			{cmd = "unarmedhit3", skill = "combat_unarmed_master", weight = 4, family = "hit"},
			{cmd = "unarmedhit2", skill = "combat_unarmed_novice", weight = 4, family = "hit"},
			{cmd = "unarmedhit1", skill = "combat_brawler_unarmed_01", weight = 4, family = "hit"},
			{cmd = "unarmedcombo2", skill = "combat_unarmed_ability_04", weight = 3, family = "combo"},
			{cmd = "unarmedcombo1", skill = "combat_unarmed_ability_02", weight = 3, family = "combo"},
			{cmd = "unarmedspinattack2", skill = "combat_unarmed_ability_03", weight = 2, family = "spin"},
			{cmd = "unarmedspinattack1", skill = "combat_brawler_unarmed_04", weight = 2, family = "spin"},
			{cmd = "unarmedknockdown2", skill = "combat_unarmed_speed_04", weight = 1, family = "knockdown"},
			{cmd = "unarmedknockdown1", skill = "combat_unarmed_speed_01", weight = 1, family = "knockdown"},
			{cmd = "unarmeddizzy1", skill = "combat_unarmed_ability_01", weight = 1, family = "dizzy"},
		},
		rifleman = {
			{cmd = "headshot3", skill = "combat_rifleman_accuracy_02", weight = 4, family = "head"},
			{cmd = "headshot2", skill = "combat_marksman_rifle_03", weight = 4, family = "head"},
			{cmd = "headshot1", skill = "combat_marksman_rifle_01", weight = 4, family = "head"},
			{cmd = "flurryshot2", skill = "combat_rifleman_support_03", weight = 3, family = "flurry"},
			{cmd = "flurryshot1", skill = "combat_rifleman_support_01", weight = 3, family = "flurry"},
			{cmd = "strafeshot2", skill = "combat_rifleman_master", weight = 2, family = "strafe"},
			{cmd = "strafeshot1", skill = "combat_rifleman_novice", weight = 2, family = "strafe"},
			{cmd = "startleshot2", skill = "combat_rifleman_ability_04", weight = 1, family = "startle"},
		},
		ranger = {
			{cmd = "fullautosingle2", skill = "combat_carbine_novice", weight = 3, family = "fullauto"},
			{cmd = "fullautosingle1", skill = "combat_marksman_carbine_02", weight = 3, family = "fullauto"},
			{cmd = "actionshot2", skill = "combat_carbine_novice", weight = 2, family = "action"},
			{cmd = "actionshot1", skill = "combat_marksman_carbine_04", weight = 2, family = "action"},
			{cmd = "burstshot2", skill = "combat_carbine_ability_03", weight = 2, family = "burst"},
			{cmd = "burstshot1", skill = "combat_carbine_ability_01", weight = 2, family = "burst"},
			{cmd = "scattershot2", skill = "combat_carbine_accuracy_03", weight = 2, family = "scatter"},
			{cmd = "scattershot1", skill = "combat_carbine_accuracy_01", weight = 2, family = "scatter"},
			{cmd = "legshot2", skill = "combat_marksman_carbine_03", weight = 1, family = "leg"},
			{cmd = "legshot1", skill = "combat_marksman_carbine_01", weight = 1, family = "leg"},
		},
		medic = {},
	},
	-- What a bot can do besides specials, by the skill box that grants it (Core3's skills.iff)
	abilities = {
		taunt = "combat_brawler_novice",
		lunge = "combat_brawler_master",
		stims = "science_medic_novice",
		rangedStims = "science_combatmedic_novice",
		states = "science_doctor_novice",
		curePoison = "science_doctor_wound_speed_02",
		cureDisease = "science_doctor_wound_speed_04",
		enhance = "science_doctor_wound_02",
		revive = "science_doctor_wound_04",
	},

	-- Healing. Reaches are half a metre inside Core3's (stims 7 m, ranged stims 30 m + healing_range 14 m, healstate
	-- 6 m, cures 7 m, reviveplayer 7 m), so a command we start isn't refused for range.
	reach = {stim = 6.5, ranged = 42, state = 5.5, cure = 6.5, revive = 6.5},
	-- Heal a group member below this share of health or action: in a fight, out of one; the medic itself first below
	-- self; anyone else with stims heals itself below selfOther
	healBelow = {fight = 0.75, rest = 0.9, self = 0.5, selfOther = 0.4},
	-- Core3's waits (20 s less a fifth of the speed mod, at least 4 s), plus a margin
	treatmentMarginMs = 600,
	mindCost = {healdamage = 50, healstate = 20, cure = 100, revive = 200},
	-- A revive is tried this many times for one death
	reviveTries = 4,
	-- Packs (botStockPack)
	packs = {
		stim = MED .. "crafted_stimpack_sm_s1_e.iff",
		ranged = MED .. "medpack_grenade_damage_e.iff",
		states = {MED .. "medpack_stunned_b.iff", MED .. "medpack_blinded_b.iff", MED .. "medpack_dizzy_b.iff",
			MED .. "medpack_intimidated_b.iff"},
		poison = MED .. "medpack_cure_poison_c.iff",
		disease = MED .. "medpack_cure_disease_c.iff",
		revive = MED .. "medpack_revive.iff",
	},
	restockEvery = 300,

	-- Death: wait this long (s) for our medic's revive before cloning (without a medic, cloneAlone); ask again if no
	-- clone happened after cloneRetry
	reviveWait = 60,
	cloneAlone = 10,
	cloneRetry = 90,

	-- Going home: after this long (ms); walk when within walkHomeRange metres of the station, else teleport there (a
	-- walk that takes over walkHomeTimeout seconds ends with a teleport too)
	homeDelayMs = 4000,
	walkHomeRange = 150,
	walkHomeTimeout = 120,

	-- The ranger's camp
	campKit = "object/tangible/scout/camp/camp_luxury.iff", -- a master camp (scout_camp_s5: medical rating 100)
	campRange = 25,          -- the camp stands while the leader is within this of it
	campSpot = 3.5,          -- the crew sit this far from the fire; the medic stands by it
	campRetry = 120,         -- someone who walked off mid-buff is taken on again after this long (s)
	campOfferEvery = 900,    -- seconds between the ranger's offers
	campOfferAfterFight = 20,
	campOfferWindow = 90,    -- a "yes" this soon after the offer places the camp
	woundedAt = 100,         -- wounds (all pools) or battle fatigue on someone that make the ranger offer a camp

	-- Tracking: the report follows the request after this long (ms), with at most this many kinds of creature
	trackDelayMs = 3000,
	trackShown = 4,

	-- At home in the cantina: an emote or a sit every idleEvery seconds (a sit lasts sitFor); now and then a
	-- looking-for-group line when a player is within lfgRange
	idleEvery = {90, 240},
	sitChance = 25,
	sitFor = {120, 300},
	lfgEvery = {1200, 2400},
	lfgRange = 20,

	-- The words (intent): checked in this order; matched anywhere in the lowercased text
	words = {
		home = {"go home", "head home", "you can go", "dismissed", "call it a day", "go back to the cantina", "leave the group",
			"drop group", "go away", "you're done", "youre done", "that's all for today", "thats all for today"},
		follow = {"follow", "stay with me", "stay close", "on me", "with me", "come on", "let's go", "lets go", "move out",
			"back off", "disengage", "fall back", "come here", "regroup", "keep up", "this way", "let's move",
			"lets move", "hold fire", "stop fighting", "peace"},
		stay = {"stay", "wait here", "hold here", "hold up", "hold position", "wait for me", "stop here", "hang back",
			"wait up", "sit tight"},
		join = {"hunt", "join", "invite", "group up", "come along", "come with", "tag along", "team up", "lfg", "wanna go",
			"want to go", "need a hand", "you in", "grp", " inv ", "inv me", "wanna group", "want to group",
			"up for a"},
		camp = {"camp", "let's rest", "lets rest", "need a rest", "take a rest", "take a break", "rest up", "make a fire",
			"set up a fire", "build a fire"},
		track = {"track", "what's around", "whats around", "anything around", "find me", "find us", "find some",
			"where are the", "look for", "any sign", "what's out there", "whats out there", "scout ahead"},
		buff = {"buff", "enhanc"},
		wounds = {"wound"},
	},
	-- Work that is one crew member's: in group chat, that member answers it
	owners = {camp = "ranger", track = "ranger", buff = "medic", wounds = "medic"},
	affirmative = {"yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "do it", "go ahead", "sounds good",
		"good idea", "why not", "camp", "aye", "ya", "y", "absolutely", "definitely"},
	-- Not creature names, when the ranger looks for one in what was said
	notCreatures = {"find", "track", "around", "here", "there", "where", "what", "whats", "anything", "some", "sign",
		"look", "near", "nearby", "close", "please", "ranger", "buddy", "friend", "mate", "kind", "type", "sort", "good",
		"hunt", "hunting", "creatures", "creature", "animals", "animal", "stuff", "things", "thing", "else", "about",
		"area", "outside", "with", "them", "they", "this", "that", "those", "these", "have", "want", "need", "should",
		"could", "would", "scout", "ahead", "tell", "show", "spot", "know", "your", "there's", "theres", "worth",
		"killing", "kill", "anybody", "anyone", "something"},

	kit = "fighter",
	place = "cantina",
}

-- Helpers

-- The Phases 4-6 bindings (BotMover, BotCombat, BotGroup) are called through here: a build without one of them still
-- runs the rest (the call gives nil)
local function bot(name, ...)
	local fn = _G[name]

	if fn == nil then
		return nil
	end

	return fn(...)
end

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function ckey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

-- Group-wide state lives under the leader
local function gkey(leaderOid, field)
	return "crew:group:" .. leaderOid .. ":" .. field
end

-- Shared memory keeps integers (lua_tointeger turns a fraction into 0)
local function put(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
end

-- writeStringData runs string.format on its value, so no "%"
local function putString(k, v)
	writeStringData(k, (tostring(v or ""):gsub("%%", "")))
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

local function hasAny(text, list)
	for _, words in ipairs(list) do
		if text:find(words, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- " words like this " (lowercase letters, digits and apostrophes)
local function wordsOf(text)
	return " " .. (tostring(text or ""):lower():gsub("[^%w']", " "):gsub("%s+", " ")) .. " "
end

-- hasState gives a number (0 or 1) through LuaCreatureObject
local function hasState(pCreature, state)
	local v = CreatureObject(pCreature):hasState(state)

	return v == true or v == 1
end

local function worldDistance(pObject, x, y)
	local dx, dy = SceneObject(pObject):getWorldPositionX() - x, SceneObject(pObject):getWorldPositionY() - y

	return math.sqrt(dx * dx + dy * dy)
end

-- The roster settings, with this module's defaults
function BotCrew:setting(name)
	local value = BotJobs:setting(name)

	if value == nil then
		value = self.defaults[name]
	end

	return value
end

function BotCrew:role(oid)
	return BotJobs:job(oid)
end

function BotCrew:name(oid)
	return BotJobs:name(oid)
end

function BotCrew:can(oid, ability)
	return readStringData(ckey(oid, "can")):find("," .. ability .. ",", 1, true) ~= nil
end

-- A human player, or a bot standing in for one in bot-on-bot tests (devLead)
function BotCrew:human(pCreature)
	if pCreature == nil or not SceneObject(pCreature):isPlayerCreature() then
		return false
	end

	if isBot == nil or not isBot(pCreature) then
		return true
	end

	return readData("crew:pretend:" .. SceneObject(pCreature):getObjectID()) == 1
end

-- Lines: the role's kind, else the crew's. fill: more {placeholders} to fill in.
function BotCrew:line(oid, kind, name, fill)
	local city = BotJobs:city(oid)
	local line = BotLines:pick(self:role(oid), kind, name, city) or BotLines:pick("crew", kind, name, city)

	if line ~= nil and fill ~= nil then
		for field, value in pairs(fill) do
			line = line:gsub("{" .. field .. "}", function() return value end)
		end
	end

	return line
end

function BotCrew:say(pBot, oid, playerOid, channel, kind, name, fill)
	local line = self:line(oid, kind, name, fill)

	if line ~= nil then
		BotJobs:reply(pBot, playerOid or 0, channel or "spatial", line)
	end
end

function BotCrew:groupSay(pBot, oid, kind, name, fill)
	self:say(pBot, oid, 0, "group", kind, name, fill)
end

function BotCrew:firstName(pCreature)
	return pCreature ~= nil and CreatureObject(pCreature):getFirstName() or nil
end

-- The group as this bot sees it: members in group order (the leader first), the humans, the crew, by oid. nil if
-- it isn't grouped. (getGroupSize and getGroupMember lock the bot and its group only.)
function BotCrew:group(pBot)
	local creature = CreatureObject(pBot)

	if not creature:isGrouped() then
		return nil
	end

	local size = creature:getGroupSize() or 0
	local g = {members = {}, humans = {}, crew = {}, byOid = {}, leader = nil}

	for i = 0, size - 1 do
		local pMember = creature:getGroupMember(i)

		if pMember ~= nil and SceneObject(pMember):isCreatureObject() then
			local memberOid = SceneObject(pMember):getObjectID()
			local human = self:human(pMember)
			local job = human and "" or BotJobs:job(memberOid)
			local member = {p = pMember, oid = memberOid, human = human, job = job, crew = CREW[job] == true,
				player = SceneObject(pMember):isPlayerCreature()}

			table.insert(g.members, member)
			g.byOid[memberOid] = member

			if g.leader == nil then
				g.leader = member
			end

			if human then
				table.insert(g.humans, member)
			elseif member.crew then
				table.insert(g.crew, member)
			end
		end
	end

	if #g.members == 0 then
		return nil
	end

	return g
end

function BotCrew:groupFighting(g)
	for _, m in ipairs(g.members) do
		if CreatureObject(m.p):isInCombat() then
			return true
		end
	end

	return false
end

-- The group's leader, a player. A bot never leads: one that finds itself leading hands the lead to a player, and
-- leaves a group with no player in it. nil when it's leaving.
function BotCrew:leaderOf(pBot, oid, g, now)
	if g.leader.human then
		return g.leader.p
	end

	local human = g.humans[1]

	if human == nil then
		if now - readData(ckey(oid, "leftAt")) > 10 then
			put(ckey(oid, "leftAt"), now)
			put(ckey(oid, "saidBye"), 1)
			print("BotJobs: " .. self:name(oid) .. " leaves a group with no player in it")
			botEnqueue(pBot, "leavegroup", 0, "")
		end

		return nil
	end

	if g.leader.oid == oid and now - readData(ckey(oid, "handedAt")) > 5 then
		put(ckey(oid, "handedAt"), now)
		print("BotJobs: " .. self:name(oid) .. " hands the group's lead to " .. self:firstName(human.p))
		-- Master looter first, while it's still the leader: Core3 gave it that with the lead, and a bot never loots
		botEnqueue(pBot, "makemasterlooter", human.oid, "")
		botEnqueue(pBot, "makeleader", human.oid, "")
	end

	return human.p
end

-- Lifecycle (the job module interface)

function BotCrew:start(pBot, oid)
	self:clear(oid)

	local now = os.time()
	local role = self:role(oid)

	self:learn(pBot, oid, role)
	self:restock(pBot, oid)
	self:equip(pBot, oid)

	-- Home is the station it logs in at (after BotJobs:restart it may be elsewhere: the last one is kept)
	local entry = BotJobs:entry(readStringData(key(oid, "first")))
	local station = entry ~= nil and entry.station or nil

	if station ~= nil and SceneObject(pBot):getParentID() == (station.cell or 0) and SceneObject(pBot):getZoneName() == station.planet then
		put(ckey(oid, "homeX"), SceneObject(pBot):getWorldPositionX())
		put(ckey(oid, "homeY"), SceneObject(pBot):getWorldPositionY())
		putString(ckey(oid, "homeZone"), station.planet)
	end

	put(ckey(oid, "nextIdle"), now + between(self.idleEvery))
	put(ckey(oid, "nextLfg"), now + between(self.lfgEvery))
	putString(ckey(oid, "order"), "follow")

	if CreatureObject(pBot):isGrouped() then
		putString(ckey(oid, "mode"), "group")
		self:startLoop(pBot, oid, 1000)
	elseif CreatureObject(pBot):isDead() then
		-- Logged in dead with no death event: the loop sees to the cloning
		putString(ckey(oid, "mode"), "home")
		self:startLoop(pBot, oid, 1000)
	else
		putString(ckey(oid, "mode"), "home")
	end
end

function BotCrew:clear(oid)
	-- Old loop chains end (they also carry the generation)
	put(ckey(oid, "loopSeq"), readData(ckey(oid, "loopSeq")) + 1)

	for _, field in ipairs({"loopAt", "target", "targetAt", "defender", "defenderAt", "holdUntil", "dead", "deadAt",
		"cloneAsked", "cloneAt", "sitting", "sitUntil", "inCamp", "campAsked", "goX", "goY", "goAt", "followAt",
		"tauntAt", "lungeAt", "injuryReady", "stateReady", "cureReady", "rezAt", "rezFor", "rezTries", "rezSaid",
		"offerAt", "peaceAt", "leftAt", "handedAt", "saidBye", "leavingAt", "homeAt", "inviteSeen", "inviteSeenAt",
		"invited", "invitedAt", "specialCount", "forGroup", "leader", "groupedAt"}) do
		deleteData(ckey(oid, field))
	end

	for _, field in ipairs({"mode", "order", "heard", "campTried"}) do
		deleteStringData(ckey(oid, field))
	end

	self:missionClear(oid)

	if BotDoctor ~= nil then
		BotDoctor:clear(oid)
	end
end

-- Its specials and abilities, from its skills
function BotCrew:learn(pBot, oid, role)
	local creature = CreatureObject(pBot)
	local list, seen = {}, {}

	for _, special in ipairs(self.specials[role] or {}) do
		if not seen[special.family] and creature:hasSkill(special.skill) then
			seen[special.family] = true
			table.insert(list, special.cmd .. "/" .. special.weight)
		end
	end

	local can = {}

	for ability, skill in pairs(self.abilities) do
		if creature:hasSkill(skill) then
			table.insert(can, ability)
		end
	end

	table.sort(can)
	putString(ckey(oid, "specialsList"), table.concat(list, ","))
	putString(ckey(oid, "can"), "," .. table.concat(can, ",") .. ",")
end

-- Packs for what it can do (stims, ranged stims, state, cure and revive packs; a doctor's enhance and wound packs)
function BotCrew:restock(pBot, oid)
	local uses = self:setting("packStock")

	if self:can(oid, "stims") then
		botStockPack(pBot, self.packs.stim, uses, self:setting("stimPower"), 0)
	end

	if self:can(oid, "rangedStims") then
		botStockPack(pBot, self.packs.ranged, uses, self:setting("rangedStimPower"), 0)
	end

	if self:can(oid, "states") then
		for _, template in ipairs(self.packs.states) do
			botStockPack(pBot, template, uses, 0, 0)
		end
	end

	if self:can(oid, "curePoison") then
		botStockPack(pBot, self.packs.poison, uses, self:setting("curePower"), 0)
	end

	if self:can(oid, "cureDisease") then
		botStockPack(pBot, self.packs.disease, uses, self:setting("curePower"), 0)
	end

	if self:can(oid, "revive") then
		botStockPack(pBot, self.packs.revive, uses, 0, 0)
	end

	if self:can(oid, "enhance") and BotDoctor ~= nil then
		BotDoctor:restock(pBot)
	end

	put(ckey(oid, "restockAt"), os.time())
end

-- Its weapon in hand (roster: a weapon field, or the first weapon in the outfit), repaired
function BotCrew:weapon(oid)
	local entry = BotJobs:entry(readStringData(key(oid, "first")))

	if entry == nil then
		return nil
	end

	if entry.weapon ~= nil and entry.weapon ~= "" then
		return entry.weapon
	end

	for _, template in ipairs(entry.outfit or {}) do
		if template:find("/weapon/", 1, true) ~= nil then
			return template
		end
	end

	return nil
end

function BotCrew:equip(pBot, oid)
	local template = self:weapon(oid)

	if template ~= nil then
		bot("botEquip", pBot, template)
	end
end

-- The ranger's camp kit: the roster's (campKit, or a camp kit it carries), else a master camp
function BotCrew:campKitOf(oid)
	local entry = BotJobs:entry(readStringData(key(oid, "first"))) or {}

	if entry.campKit ~= nil and entry.campKit ~= "" then
		return entry.campKit
	end

	for _, list in ipairs({entry.carry or {}, entry.outfit or {}}) do
		for _, template in ipairs(list) do
			if template:find("/scout/camp/", 1, true) ~= nil then
				return template
			end
		end
	end

	return self.campKit
end

-- From BotJobs:tick every 5 s: keep the loop running while it should, take invites, restock, idle at home
function BotCrew:tick(pBot, oid, now)
	local creature = CreatureObject(pBot)
	local mode = readStringData(ckey(oid, "mode"))

	local fighting = BotFight ~= nil and BotFight.fighting ~= nil and BotFight:fighting(oid) ~= 0

	if (creature:isGrouped() or creature:isInCombat() or creature:isDead() or fighting or mode == "group") and
		now - readData(ckey(oid, "loopAt")) > self.loopStale then
		self:startLoop(pBot, oid, 100)
	end

	if not creature:isGrouped() then
		local inviter = bot("botGetGroupInviter", pBot) or 0

		if inviter ~= 0 then
			self:invited(pBot, oid, getSceneObject(inviter), now)
		end
	end

	if now - readData(ckey(oid, "restockAt")) >= self.restockEvery and not creature:isInCombat() then
		self:restock(pBot, oid)
	end

	if mode == "leaving" and now - readData(ckey(oid, "leavingAt")) > 30 then
		self:goHome(pBot, tostring(readData(key(oid, "gen"))))
	elseif mode == "walkingHome" and now - readData(ckey(oid, "homeAt")) > self.walkHomeTimeout then
		self:teleportHome(pBot, oid)
	elseif mode == "home" and not creature:isGrouped() and not creature:isInCombat() then
		self:idle(pBot, oid, now)
	end
end

-- At home: sit a while, stand, emote; now and then ask around for a group
function BotCrew:idle(pBot, oid, now)
	if now >= readData(ckey(oid, "nextLfg")) then
		put(ckey(oid, "nextLfg"), now + between(self.lfgEvery))

		if self:humanNear(pBot, self.lfgRange) and percent(50) then
			self:say(pBot, oid, 0, "spatial", "lfg")
		end
	end

	if readData(ckey(oid, "sitting")) == 1 then
		if now >= readData(ckey(oid, "sitUntil")) then
			self:standUp(pBot, oid)
			put(ckey(oid, "nextIdle"), now + between(self.idleEvery))
		end

		return
	end

	if now < readData(ckey(oid, "nextIdle")) then
		return
	end

	put(ckey(oid, "nextIdle"), now + between(self.idleEvery))

	if percent(self.sitChance) then
		botEnqueue(pBot, "sitserver", 0, "")
		put(ckey(oid, "sitting"), 1)
		put(ckey(oid, "sitUntil"), now + between(self.sitFor))
	elseif BotLines.doctorIdle ~= nil and #BotLines.doctorIdle > 0 then
		botEmote(pBot, BotLines.doctorIdle[getRandomNumber(1, #BotLines.doctorIdle)], 0)
	end
end

function BotCrew:humanNear(pBot, range)
	for _, pPlayer in ipairs(SceneObject(pBot):getPlayersInRange(range) or {}) do
		if self:human(pPlayer) then
			return true
		end
	end

	return false
end

function BotCrew:standUp(pBot, oid)
	-- Sitting, or crouched (a fight or a heal can leave it so, and BotMover doesn't walk a bot that isn't upright)
	local posture = CreatureObject(pBot):getPosture()

	if posture == SITTING or posture == CROUCHED then
		botEnqueue(pBot, "stand", 0, "")
	end

	deleteData(ckey(oid, "sitting"))
end

-- For BotJobs:list
function BotCrew:state(pBot, oid)
	local mode = readStringData(ckey(oid, "mode"))
	local state = mode ~= "" and mode or "?"

	if mode == "group" then
		local pLeader = getSceneObject(readData(ckey(oid, "leader")))

		state = "with " .. (self:firstName(pLeader) or "?") .. ", " .. readStringData(ckey(oid, "order"))
	end

	local target = getSceneObject(readData(ckey(oid, "target")))

	if target ~= nil then
		local dist = BotJobs:distance(pBot, target)

		state = state .. ", fighting " .. SceneObject(target):getDisplayedName() ..
			(dist ~= nil and (" at " .. math.floor(dist) .. " m") or "")
	end

	if readData(ckey(oid, "dead")) == 1 then
		state = state .. ", dead" .. (readData(ckey(oid, "cloneAsked")) == 1 and " (cloning)" or "")
	end

	if readData(ckey(oid, "inCamp")) == 1 then
		state = state .. ", in camp"
	end

	if readData(ckey(oid, "sitting")) == 1 then
		state = state .. ", sitting"
	end

	if pBot ~= nil then
		local move = bot("botMoveState", pBot)

		if move ~= nil and move.state ~= nil and move.state ~= "idle" then
			state = state .. ", " .. tostring(move.state)
		end
	end

	state = state .. ", " .. readData(ckey(oid, "specialCount")) .. " specials"

	if pBot ~= nil then
		local creature = CreatureObject(pBot)

		state = state .. string.format(", HAM %d/%d/%d", creature:getHAM(HEALTH), creature:getHAM(ACTION), creature:getHAM(MIND))
	end

	return state
end

-- The loop: one chain per bot (its loop number), while it's grouped, fighting or dead

function BotCrew:startLoop(pBot, oid, delay)
	local seq = readData(ckey(oid, "loopSeq")) + 1

	put(ckey(oid, "loopSeq"), seq)
	put(ckey(oid, "loopAt"), os.time())
	createEvent(delay or 1000, "BotCrew", "loop", pBot, packArgs(readData(key(oid, "gen")), seq))
end

function BotCrew:loop(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if num(a[2]) ~= readData(ckey(oid, "loopSeq")) then
		return
	end

	local now = os.time()

	put(ckey(oid, "loopAt"), now)

	local delay = self:step(pBot, oid, now)

	if delay ~= nil then
		createEvent(delay, "BotCrew", "loop", pBot, args)
	end
end

-- One step; the next one after the delay it returns, or none (nil: not grouped, not fighting)
function BotCrew:step(pBot, oid, now)
	local creature = CreatureObject(pBot)

	if creature:isDead() then
		return self:whileDead(pBot, oid, now)
	end

	if readData(ckey(oid, "dead")) == 1 then
		self:backFromDead(pBot, oid, now)
	end

	if creature:isIncapacitated() then
		deleteData(ckey(oid, "target"))
		return self.deadMs
	end

	self:noteDefender(pBot, oid, now)

	local g = self:group(pBot)
	local pLeader = nil
	local mode = readStringData(ckey(oid, "mode"))

	if g ~= nil then
		-- Just told to go home: the group lets go of it in a moment
		if mode == "leaving" and now - readData(ckey(oid, "leavingAt")) < 15 then
			return self.groupMs
		end

		pLeader = self:leaderOf(pBot, oid, g, now)

		if pLeader == nil then
			return self.groupMs
		end

		if mode ~= "group" then
			self:enterGroup(pBot, oid, g, pLeader, now)
		end

		put(ckey(oid, "leader"), SceneObject(pLeader):getObjectID())
		self:scanHumans(g, oid)
	end

	local role = self:role(oid)

	-- Healing first: the medic looks after the group; anyone with stims keeps itself alive. A medic in a provoked
	-- fight or duel of its own fights it and only heals itself.
	local ownFight = BotFight ~= nil and BotFight.fighting ~= nil and BotFight:fighting(oid) or 0

	if g ~= nil and role == "medic" and ownFight == 0 then
		if self:medicTurn(pBot, oid, g, now) then
			return self.fightMs
		end
	elseif self:selfHeal(pBot, oid) then
		return self.fightMs
	end

	local pTarget = self:pickTarget(pBot, oid, g, pLeader, now)

	if pTarget ~= nil then
		self:fight(pBot, oid, pTarget, pLeader, g, now)
		return self.fightMs
	end

	-- A provoked fight or a duel belongs to BotFight (it ends it at the first incap): no peace of ours while it's on
	if BotFight ~= nil and BotFight.fighting ~= nil and BotFight:fighting(oid) ~= 0 then
		return self.fightMs
	end

	if readData(ckey(oid, "target")) ~= 0 then
		self:endFight(pBot, oid, now)
	end

	if g == nil then
		if mode == "group" then
			self:leftGroup(pBot, oid, now)
		end

		return creature:isInCombat() and self.fightMs or nil
	end

	self:outOfCombat(pBot, oid, g, pLeader, now)

	return self.groupMs
end

-- Grouping

-- An invite (the "groupInvite" event, or the inviter seen by the tick): join a player's group
function BotCrew:invited(pBot, oid, pInviter, now)
	if pInviter == nil then
		return
	end

	local inviterOid = SceneObject(pInviter):getObjectID()

	if readData(ckey(oid, "inviteSeen")) == inviterOid and now - readData(ckey(oid, "inviteSeenAt")) < 20 then
		return
	end

	put(ckey(oid, "inviteSeen"), inviterOid)
	put(ckey(oid, "inviteSeenAt"), now)

	local creature = CreatureObject(pBot)

	if creature:isGrouped() or creature:isDead() or not self:human(pInviter) then
		print("BotJobs: " .. self:name(oid) .. " declines " .. tostring(self:firstName(pInviter)) .. "'s invite")
		botEnqueue(pBot, "decline", 0, "")
		return
	end

	self:standUp(pBot, oid)
	botEnqueue(pBot, "join", 0, "")
	print("BotJobs: " .. self:name(oid) .. " accepts " .. self:firstName(pInviter) .. "'s invite")
	self:startLoop(pBot, oid, 1000)
end

function BotCrew:enterGroup(pBot, oid, g, pLeader, now)
	putString(ckey(oid, "mode"), "group")
	putString(ckey(oid, "order"), "follow")
	put(ckey(oid, "groupedAt"), now)
	deleteData(ckey(oid, "holdUntil"))
	deleteData(ckey(oid, "followAt"))
	self:standUp(pBot, oid)
	print("BotJobs: " .. self:name(oid) .. " is in " .. self:firstName(pLeader) .. "'s group (" .. #g.members .. ")")
	self:groupSay(pBot, oid, "joined", self:firstName(pLeader))
end

-- Out of the group (dismissed, disbanded, or it left): say bye if the leader is near, and go home
function BotCrew:leftGroup(pBot, oid, now)
	print("BotJobs: " .. self:name(oid) .. " is out of the group")
	self:stopMoving(pBot)
	self:standUp(pBot, oid)

	if self:role(oid) == "medic" and BotDoctor ~= nil then
		BotDoctor:clear(oid)
	end

	if readData(ckey(oid, "saidBye")) ~= 1 then
		local pLeader = getSceneObject(readData(ckey(oid, "leader")))
		local dist = BotJobs:distance(pBot, pLeader)

		if dist ~= nil and dist <= 40 then
			self:say(pBot, oid, 0, "spatial", "bye", self:firstName(pLeader))
		end
	end

	deleteData(ckey(oid, "saidBye"))
	self:leaveForHome(pBot, oid, now)
end

function BotCrew:leaveForHome(pBot, oid, now)
	self:missionLeft(pBot, oid)
	putString(ckey(oid, "mode"), "leaving")
	put(ckey(oid, "leavingAt"), now)

	if readData(ckey(oid, "inCamp")) == 1 and self:role(oid) == "ranger" then
		bot("botRemoveCamp", pBot)
	end

	deleteData(ckey(oid, "inCamp"))
	createEvent(self.homeDelayMs, "BotCrew", "goHome", pBot, tostring(readData(key(oid, "gen"))))
end

-- Back to the station: a walk when it's near, else a jump (as a player taking the shuttle home would vanish)
function BotCrew:goHome(pBot, gen)
	if not BotJobs:current(pBot, gen) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	if CreatureObject(pBot):isGrouped() or readStringData(ckey(oid, "mode")) ~= "leaving" then
		return
	end

	if CreatureObject(pBot):isDead() then
		-- Clones first (the tick and the loop see to it)
		put(ckey(oid, "leavingAt"), os.time())
		return
	end

	local station = self:station(oid)

	if station == nil then
		putString(ckey(oid, "mode"), "home")
		return
	end

	local zone = SceneObject(pBot):getZoneName()
	local cell = SceneObject(pBot):getParentID()
	local near = false

	if zone == station.planet then
		if cell ~= 0 and cell == (station.cell or 0) then
			near = true
		elseif readStringData(ckey(oid, "homeZone")) == zone then
			near = worldDistance(pBot, readData(ckey(oid, "homeX")), readData(ckey(oid, "homeY"))) <= self.walkHomeRange
		end
	end

	self:standUp(pBot, oid)

	if near and bot("botMoveTo", pBot, station.x, station.z, station.y, station.cell or 0) then
		putString(ckey(oid, "mode"), "walkingHome")
		put(ckey(oid, "homeAt"), os.time())
		print("BotJobs: " .. self:name(oid) .. " walks back to its station")
		return
	end

	self:teleportHome(pBot, oid)
end

function BotCrew:station(oid)
	local entry = BotJobs:entry(readStringData(key(oid, "first")))

	return entry ~= nil and entry.station or nil
end

function BotCrew:teleportHome(pBot, oid)
	local station = self:station(oid)

	if station == nil then
		putString(ckey(oid, "mode"), "home")
		return
	end

	bot("botStop", pBot)

	if SceneObject(pBot):getZoneName() ~= station.planet then
		SceneObject(pBot):switchZone(station.planet, station.x, station.z, station.y, station.cell or 0)
	else
		SceneObject(pBot):teleport(station.x, station.z, station.y, station.cell or 0)
	end

	print("BotJobs: " .. self:name(oid) .. " goes back to its station")
	self:atHome(pBot, oid)
end

function BotCrew:atHome(pBot, oid)
	local station = self:station(oid)

	putString(ckey(oid, "mode"), "home")
	putString(ckey(oid, "order"), "follow")
	put(ckey(oid, "nextIdle"), os.time() + between(self.idleEvery))

	if station ~= nil and station.heading ~= nil then
		SceneObject(pBot):updateDirection(math.rad(station.heading))
	end
end

-- Following

function BotCrew:stopMoving(pBot)
	local move = bot("botMoveState", pBot)

	if move ~= nil and move.state ~= nil and move.state ~= "idle" then
		bot("botStop", pBot)
	end
end

-- Following the leader's trail (BotMover does doors, buildings, catching up and zone changes)
function BotCrew:ensureFollow(pBot, oid, pLeader, now)
	local move = bot("botMoveState", pBot) or {}
	local leaderOid = SceneObject(pLeader):getObjectID()

	if move.state == "zoning" then
		return
	end

	if move.state == "follow" and (move.leader == nil or move.leader == 0 or tonumber(move.leader) == leaderOid) then
		return
	end

	if now - readData(ckey(oid, "followAt")) < 3 then
		return
	end

	put(ckey(oid, "followAt"), now)
	self:standUp(pBot, oid)
	bot("botFollow", pBot, pLeader)
end

-- Walk to someone (or a point short of them, in the same cell), again only when they've moved or now and then
function BotCrew:walkNear(pBot, oid, pTarget, dist, now, short)
	local tx, tz, ty = SceneObject(pTarget):getPositionX(), SceneObject(pTarget):getPositionZ(), SceneObject(pTarget):getPositionY()
	local cell = SceneObject(pTarget):getParentID()

	if now - readData(ckey(oid, "goAt")) < self.moveEvery and
		math.abs(tx - readData(ckey(oid, "goX"))) + math.abs(ty - readData(ckey(oid, "goY"))) < 3 then
		return
	end

	put(ckey(oid, "goX"), tx)
	put(ckey(oid, "goY"), ty)
	put(ckey(oid, "goAt"), now)

	local x, y = tx, ty

	if short > 0 and dist ~= nil and dist > short and cell == SceneObject(pBot):getParentID() then
		local bx, by = SceneObject(pBot):getPositionX(), SceneObject(pBot):getPositionY()
		local k = short / dist

		x, y = tx + (bx - tx) * k, ty + (by - ty) * k
	end

	self:standUp(pBot, oid)
	bot("botMoveTo", pBot, x, tz, y, cell)
end

-- Fighting

-- What this bot is fighting, for its crew mates
function BotCrew:noteDefender(pBot, oid, now)
	local creature = CreatureObject(pBot)
	local defender = 0

	if creature:isInCombat() then
		local pDefender = creature:getMainDefender()

		if pDefender ~= nil then
			defender = SceneObject(pDefender):getObjectID()
		end
	end

	put(ckey(oid, "defender"), defender)
	put(ckey(oid, "defenderAt"), now)
end

-- The first crew member in the group reads what the players in it are fighting, in an event on each of them
function BotCrew:scanHumans(g, oid)
	if g.crew[1] == nil or g.crew[1].oid ~= oid then
		return
	end

	for _, m in ipairs(g.humans) do
		if CreatureObject(m.p):isInCombat() then
			createEvent(1, "BotCrew", "scanHuman", m.p, "")
		elseif readData("crew:human:" .. m.oid .. ":defender") ~= 0 then
			put("crew:human:" .. m.oid .. ":defender", 0)
		end
	end
end

-- An event on the player (so only the player is locked): who they're fighting
function BotCrew:scanHuman(pHuman, args)
	if pHuman == nil then
		return
	end

	local humanOid = SceneObject(pHuman):getObjectID()
	local defender = 0

	if CreatureObject(pHuman):isInCombat() then
		local pDefender = CreatureObject(pHuman):getMainDefender()

		if pDefender ~= nil then
			defender = SceneObject(pDefender):getObjectID()
		end
	end

	put("crew:human:" .. humanOid .. ":defender", defender)
	put("crew:human:" .. humanOid .. ":at", os.time())
end

-- A creature this bot may attack, or nil: alive and standing (never a death blow), near, attackable, not in the
-- group. Players only when allowPlayer (a duel or a provoked fight with this bot); allowPlayer "opponent" is that
-- fight's opponent, who may be in the group.
function BotCrew:validTarget(pBot, pTarget, g, allowPlayer)
	if pTarget == nil or not SceneObject(pTarget):isCreatureObject() then
		return nil
	end

	local targetOid = SceneObject(pTarget):getObjectID()

	if targetOid == SceneObject(pBot):getObjectID() or (g ~= nil and g.byOid[targetOid] ~= nil and allowPlayer ~= "opponent") then
		return nil
	end

	if SceneObject(pTarget):isPlayerCreature() and not allowPlayer then
		return nil
	end

	local target = CreatureObject(pTarget)

	if target:isDead() or target:isIncapacitated() then
		return nil
	end

	local dist = BotJobs:distance(pBot, pTarget)

	if dist == nil or dist > self.engageRange then
		return nil
	end

	if not target:isAttackableBy(pBot) then
		return nil
	end

	return pTarget
end

-- What to fight: its own provoked fight or duel; the leader's target while the leader fights; else the current one
-- while still fighting it; else whatever attacks this bot, a crew mate or a player in the group. Ungrouped, only its
-- own fight.
function BotCrew:pickTarget(pBot, oid, g, pLeader, now)
	-- A provoked fight or a duel of its own (fight.lua) comes first: the crew fights those properly
	local opponent = BotFight ~= nil and BotFight.fighting ~= nil and BotFight:fighting(oid) or 0

	if opponent ~= 0 then
		local pOpponent = self:validTarget(pBot, getSceneObject(opponent), g, "opponent")

		if pOpponent ~= nil then
			return pOpponent
		end
	end

	if now < readData(ckey(oid, "holdUntil")) then
		return nil
	end

	local own = readData(ckey(oid, "defender"))
	local pOwn = own ~= 0 and self:validTarget(pBot, getSceneObject(own), g, true) or nil

	if g == nil then
		return pOwn
	end

	if pLeader ~= nil and CreatureObject(pLeader):isInCombat() then
		local pTarget = self:validTarget(pBot, getSceneObject(CreatureObject(pLeader):getTargetID()), g, false)

		if pTarget ~= nil then
			return pTarget
		end
	end

	local pCurrent = self:validTarget(pBot, getSceneObject(readData(ckey(oid, "target"))), g, false)

	if pCurrent ~= nil and CreatureObject(pBot):isInCombat() then
		return pCurrent
	end

	if pOwn ~= nil and not SceneObject(pOwn):isPlayerCreature() then
		return pOwn
	end

	for _, m in ipairs(g.crew) do
		if m.oid ~= oid and now - readData(ckey(m.oid, "defenderAt")) <= self.attackerFresh then
			local pTarget = self:validTarget(pBot, getSceneObject(readData(ckey(m.oid, "defender"))), g, false)

			if pTarget ~= nil then
				return pTarget
			end
		end
	end

	for _, m in ipairs(g.humans) do
		if now - readData("crew:human:" .. m.oid .. ":at") <= self.attackerFresh then
			local pTarget = self:validTarget(pBot, getSceneObject(readData("crew:human:" .. m.oid .. ":defender")), g, false)

			if pTarget ~= nil then
				return pTarget
			end
		end
	end

	return pOwn
end

-- Specials only while health, action and mind are all above specialsHam of their maximum; else auto-attack
function BotCrew:hamOk(pBot)
	local share = self:setting("specialsHam")
	local creature = CreatureObject(pBot)

	for _, pool in ipairs({HEALTH, ACTION, MIND}) do
		local max = creature:getMaxHAM(pool)

		if max > 0 and creature:getHAM(pool) < max * share then
			return false
		end
	end

	return true
end

function BotCrew:pickSpecial(oid)
	local list, total = {}, 0

	for cmd, weight in string.gmatch(readStringData(ckey(oid, "specialsList")), "(%w+)/(%d+)") do
		table.insert(list, {cmd, tonumber(weight)})
		total = total + tonumber(weight)
	end

	if total == 0 then
		return nil
	end

	local roll = getRandomNumber(1, total)

	for _, special in ipairs(list) do
		roll = roll - special[2]

		if roll <= 0 then
			return special[1]
		end
	end

	return list[#list][1]
end

-- One fight step: a new target is set and attacked (the tank taunts it), the bot moves to its range, and with its command
-- queue empty it uses a special (the tank taunts again when the target turns on someone else)
function BotCrew:fight(pBot, oid, pTarget, pLeader, g, now)
	local role = self:role(oid)
	local targetOid = SceneObject(pTarget):getObjectID()
	local previous = readData(ckey(oid, "target"))

	if previous ~= targetOid then
		put(ckey(oid, "target"), targetOid)
		put(ckey(oid, "targetAt"), now)
		self:standUp(pBot, oid)
		-- (botSetTarget queues a real attack, so auto-attack runs)
		bot("botSetTarget", pBot, targetOid)
		print("BotJobs: " .. self:name(oid) .. " (" .. role .. ") attacks " .. SceneObject(pTarget):getDisplayedName())

		if role == "tank" and self:can(oid, "taunt") then
			botEnqueue(pBot, "taunt", targetOid, "")
			put(ckey(oid, "tauntAt"), now)

			if previous == 0 and g ~= nil and percent(self.pullChance) then
				self:groupSay(pBot, oid, "pull")
			end
		end
	end

	local dist = BotJobs:distance(pBot, pTarget) or 999

	if role == "tank" then
		self:closeIn(pBot, oid, pTarget, dist, now)
	else
		self:holdRange(pBot, oid, pTarget, pLeader, dist, role, now)
	end

	if CreatureObject(pBot):getQueueSize() > 0 then
		return
	end

	if role == "tank" then
		if self:can(oid, "taunt") and CreatureObject(pTarget):getTargetID() ~= oid and
			now - readData(ckey(oid, "tauntAt")) >= self.tauntEvery then
			botEnqueue(pBot, "taunt", targetOid, "")
			put(ckey(oid, "tauntAt"), now)
			return
		end

		if dist > self.meleeReach then
			if self:can(oid, "lunge") and dist >= self.lungeRange[1] and dist <= self.lungeRange[2] and self:hamOk(pBot) and
				now - readData(ckey(oid, "lungeAt")) >= 4 then
				botEnqueue(pBot, "unarmedlunge2", targetOid, "")
				put(ckey(oid, "lungeAt"), now)
				put(ckey(oid, "specialCount"), readData(ckey(oid, "specialCount")) + 1)
			end

			return
		end
	elseif dist > (self.ranges[role] or 50) then
		return
	end

	if not self:hamOk(pBot) then
		return
	end

	local cmd = self:pickSpecial(oid)

	if cmd ~= nil then
		botEnqueue(pBot, cmd, targetOid, "")
		put(ckey(oid, "specialCount"), readData(ckey(oid, "specialCount")) + 1)
	end
end

-- The tank closes in (not while told to stay)
function BotCrew:closeIn(pBot, oid, pTarget, dist, now)
	if readStringData(ckey(oid, "order")) == "stay" then
		return
	end

	if dist <= self.meleeReach - 0.5 then
		local move = bot("botMoveState", pBot)

		if move ~= nil and move.state == "goto" then
			bot("botStop", pBot)
		end

		return
	end

	self:walkNear(pBot, oid, pTarget, dist, now, self.closeTo)
end

-- The ranged roles stand and shoot within their range while the leader is near; out of range they stay with the
-- leader (who is usually by the fight) or walk up to it
function BotCrew:holdRange(pBot, oid, pTarget, pLeader, dist, role, now)
	local range = self.ranges[role] or 50

	if readStringData(ckey(oid, "order")) == "stay" or pLeader == nil then
		return
	end

	if dist > range then
		local leaderToTarget = BotJobs:distance(pLeader, pTarget)

		if leaderToTarget ~= nil and leaderToTarget < range - 5 then
			self:ensureFollow(pBot, oid, pLeader, now)
		else
			self:walkNear(pBot, oid, pTarget, dist, now, range - 15)
		end

		return
	end

	local leaderDist = BotJobs:distance(pBot, pLeader)

	if leaderDist == nil or leaderDist > self.leaderSpread then
		self:ensureFollow(pBot, oid, pLeader, now)
		return
	end

	self:stopMoving(pBot)
end

-- The fight is over: peace, packs refilled; the follow starts again on the next step
function BotCrew:endFight(pBot, oid, now)
	deleteData(ckey(oid, "target"))
	put(ckey(oid, "peaceAt"), now)
	bot("botSetTarget", pBot, 0)
	botEnqueue(pBot, "peace", 0, "")

	local move = bot("botMoveState", pBot)

	if move ~= nil and move.state == "goto" then
		bot("botStop", pBot)
	end

	print("BotJobs: " .. self:name(oid) .. " makes peace (" .. readData(ckey(oid, "specialCount")) .. " specials so far)")
	self:restock(pBot, oid)
end

-- Healing

-- The share of a pool's reachable maximum (its maximum less wounds) that is left
function BotCrew:ratio(pCreature, pool)
	local creature = CreatureObject(pCreature)
	local max = creature:getMaxHAM(pool) - botGetWounds(pCreature, pool)

	if max <= 0 then
		return 1
	end

	return creature:getHAM(pool) / max
end

function BotCrew:ready(oid, what)
	return getTimestampMilli() >= readData(ckey(oid, what .. "Ready"))
end

-- Core3's wait after a treatment: 20 s less a fifth of the speed skill mod, at least 4 s
function BotCrew:waitMs(pBot, mod)
	local delay = math.floor(20 - (CreatureObject(pBot):getSkillMod(mod) or 0) / 5 + 0.5)

	if delay < 4 then
		delay = 4
	end

	return delay * 1000 + self.treatmentMarginMs
end

-- A pack's oid, restocking once if it's gone
function BotCrew:pack(pBot, oid, template)
	local packOid = bot("botFindPack", pBot, template) or 0

	if packOid == 0 then
		self:restock(pBot, oid)
		packOid = bot("botFindPack", pBot, template) or 0
	end

	return packOid
end

-- healdamage: a stim within reach, else a ranged stim. false if it can't now (waiting, no mind, out of reach).
function BotCrew:stim(pBot, oid, pPatient, dist)
	if not self:ready(oid, "injury") or CreatureObject(pBot):getHAM(MIND) < self.mindCost.healdamage then
		return false
	end

	local template, mod = nil, "healing_injury_speed"

	if dist <= self.reach.stim and self:can(oid, "stims") then
		template = self.packs.stim
	elseif dist <= self.reach.ranged and self:can(oid, "rangedStims") then
		template, mod = self.packs.ranged, "healing_range_speed"
	else
		return false
	end

	local packOid = self:pack(pBot, oid, template)

	if packOid == 0 then
		return false
	end

	local patientOid = SceneObject(pPatient):getObjectID()

	botEnqueue(pBot, "healdamage", patientOid, tostring(packOid))
	put(ckey(oid, "injuryReady"), getTimestampMilli() + self:waitMs(pBot, mod))

	return true
end

-- Anyone with stims (the tank has Master Medic) keeps itself alive
function BotCrew:selfHeal(pBot, oid)
	if not self:can(oid, "stims") then
		return false
	end

	if self:ratio(pBot, HEALTH) >= self.healBelow.selfOther and self:ratio(pBot, ACTION) >= self.healBelow.selfOther then
		return false
	end

	return self:stim(pBot, oid, pBot, 0)
end

-- The medic's turn, before any fighting: revive the dead, heal damage (itself first when low, then whoever is
-- lowest), cure states, then poison and disease. true if it did something (or walked to do it).
function BotCrew:medicTurn(pBot, oid, g, now)
	local fighting = CreatureObject(pBot):isInCombat() or self:groupFighting(g)

	-- Buffing in a camp (BotDoctor's chain): carry on, unless a fight broke out
	if readData(key(oid, "busy")) == 1 then
		if not fighting then
			return true
		end

		BotDoctor:clear(oid)
	end

	-- Never heal someone a crew mate is fighting (a provoked fight or a duel with a group member)
	local opponents = {}

	if BotFight ~= nil and BotFight.fighting ~= nil then
		for _, m in ipairs(g.members) do
			local opponent = BotFight:fighting(m.oid)

			if opponent ~= nil and opponent ~= 0 then
				opponents[opponent] = true
			end
		end
	end

	local patients = {}

	for _, m in ipairs(g.members) do
		if m.player and not opponents[m.oid] then
			local dist = m.oid == oid and 0 or BotJobs:distance(pBot, m.p)

			if dist ~= nil and dist <= 64 then
				table.insert(patients, {m = m, dist = dist})
			end
		end
	end

	if self:can(oid, "revive") then
		for _, patient in ipairs(patients) do
			if patient.m.oid ~= oid and CreatureObject(patient.m.p):isDead() and self:revive(pBot, oid, patient.m, patient.dist, now) then
				return true
			end
		end
	end

	local worst, worstShare = nil, 2

	for _, patient in ipairs(patients) do
		local creature = CreatureObject(patient.m.p)

		if not creature:isDead() and not creature:isIncapacitated() then
			local share = math.min(self:ratio(patient.m.p, HEALTH), self:ratio(patient.m.p, ACTION))

			if patient.m.oid == oid and share < self.healBelow.self then
				share = share - 1
			end

			if share < worstShare then
				worst, worstShare = patient, share
			end
		end
	end

	if worst ~= nil and worstShare < (fighting and self.healBelow.fight or self.healBelow.rest) and self:ready(oid, "injury") then
		if self:stim(pBot, oid, worst.m.p, worst.dist) then
			return true
		end

		local reach = self:can(oid, "rangedStims") and self.reach.ranged or self.reach.stim

		if worst.dist > reach then
			self:walkNear(pBot, oid, worst.m.p, worst.dist, now, reach - 4)
			return true
		end
	end

	if self:can(oid, "states") and self:ready(oid, "state") then
		for _, patient in ipairs(patients) do
			if not CreatureObject(patient.m.p):isDead() then
				for _, state in ipairs(STATES) do
					if hasState(patient.m.p, state) then
						return self:treat(pBot, oid, patient, "healstate", "state", self.reach.state, self.mindCost.healstate, now)
					end
				end
			end
		end
	end

	if self:ready(oid, "cure") then
		for _, patient in ipairs(patients) do
			if not CreatureObject(patient.m.p):isDead() then
				if self:can(oid, "curePoison") and hasState(patient.m.p, POISONED) then
					return self:treat(pBot, oid, patient, "curepoison", "cure", self.reach.cure, self.mindCost.cure, now)
				elseif self:can(oid, "cureDisease") and hasState(patient.m.p, DISEASED) then
					return self:treat(pBot, oid, patient, "curedisease", "cure", self.reach.cure, self.mindCost.cure, now)
				end
			end
		end
	end

	return false
end

-- A state or cure treatment within reach (Core3 finds the pack), else a walk to the patient
function BotCrew:treat(pBot, oid, patient, command, timer, reach, mind, now)
	if patient.dist > reach then
		self:walkNear(pBot, oid, patient.m.p, patient.dist, now, reach - 1.5)
		return true
	end

	if CreatureObject(pBot):getHAM(MIND) < mind then
		return false
	end

	botEnqueue(pBot, command, patient.m.oid, "")
	put(ckey(oid, timer .. "Ready"), getTimestampMilli() + self:waitMs(pBot, "healing_injury_speed"))
	print("BotJobs: " .. self:name(oid) .. " " .. command .. " on " .. self:firstName(patient.m.p))

	return true
end

-- Revive a dead group member: walk to them, then reviveplayer (a few tries per death)
function BotCrew:revive(pBot, oid, m, dist, now)
	if readData(ckey(oid, "rezFor")) ~= m.oid then
		put(ckey(oid, "rezFor"), m.oid)
		put(ckey(oid, "rezTries"), 0)
	end

	if readData(ckey(oid, "rezTries")) >= self.reviveTries then
		return false
	end

	if readData(ckey(oid, "rezSaid")) ~= m.oid then
		put(ckey(oid, "rezSaid"), m.oid)
		self:groupSay(pBot, oid, "reviving", self:firstName(m.p))
	end

	if dist > self.reach.revive then
		self:walkNear(pBot, oid, m.p, dist, now, 1.5)
		return true
	end

	if now - readData(ckey(oid, "rezAt")) < 5 then
		return true
	end

	if CreatureObject(pBot):getHAM(MIND) < self.mindCost.revive then
		return false
	end

	put(ckey(oid, "rezAt"), now)
	put(ckey(oid, "rezTries"), readData(ckey(oid, "rezTries")) + 1)
	self:stopMoving(pBot)

	local packOid = self:pack(pBot, oid, self.packs.revive)

	botEnqueue(pBot, "reviveplayer", m.oid, packOid ~= 0 and tostring(packOid) or "")
	print("BotJobs: " .. self:name(oid) .. " revives " .. self:firstName(m.p))

	return true
end

-- Death: wait for the medic's revive (a while), else clone at the nearest cloner, then rejoin the leader

function BotCrew:medicNear(pBot, oid, g)
	if g == nil then
		return nil
	end

	for _, m in ipairs(g.crew) do
		if m.oid ~= oid and m.job == "medic" and not CreatureObject(m.p):isDead() then
			local dist = BotJobs:distance(pBot, m.p)

			if dist ~= nil and dist <= 100 then
				return m
			end
		end
	end

	return nil
end

function BotCrew:whileDead(pBot, oid, now)
	local g = self:group(pBot)

	if readData(ckey(oid, "dead")) ~= 1 then
		put(ckey(oid, "dead"), 1)
		put(ckey(oid, "deadAt"), now)
		deleteData(ckey(oid, "cloneAsked"))
		deleteData(ckey(oid, "target"))
		bot("botStop", pBot)
		print("BotJobs: " .. self:name(oid) .. " is dead")

		if g ~= nil then
			self:groupSay(pBot, oid, "down")
		end
	end

	local deadFor = now - readData(ckey(oid, "deadAt"))

	if readData(ckey(oid, "cloneAsked")) ~= 1 then
		local wait = self:medicNear(pBot, oid, g) ~= nil and self.reviveWait or self.cloneAlone

		if deadFor >= wait then
			put(ckey(oid, "cloneAsked"), 1)
			put(ckey(oid, "cloneAt"), now)
			print("BotJobs: " .. self:name(oid) .. " clones after " .. deadFor .. " s dead")
			bot("botClone", pBot)
		end
	elseif now - readData(ckey(oid, "cloneAt")) >= self.cloneRetry then
		put(ckey(oid, "cloneAt"), now)
		print("BotJobs: " .. self:name(oid) .. " still dead, cloning again")
		bot("botClone", pBot)
	end

	return self.deadMs
end

-- Alive again: revived where it fell, or cloned (if the "cloned" event didn't come first)
function BotCrew:backFromDead(pBot, oid, now)
	if readData(ckey(oid, "cloneAsked")) == 1 then
		self:afterClone(pBot, oid, now)
		return
	end

	deleteData(ckey(oid, "dead"))
	print("BotJobs: " .. self:name(oid) .. " was revived")

	if CreatureObject(pBot):isGrouped() then
		self:groupSay(pBot, oid, "revived")
	end
end

-- Out of the cloner: gear repaired and in hand, packs refilled, back to the leader
function BotCrew:afterClone(pBot, oid, now)
	if readData(ckey(oid, "dead")) ~= 1 then
		return
	end

	deleteData(ckey(oid, "dead"))
	deleteData(ckey(oid, "cloneAsked"))
	deleteData(ckey(oid, "target"))

	local repaired = bot("botRepairGear", pBot) or 0

	self:equip(pBot, oid)
	self:restock(pBot, oid)
	print("BotJobs: " .. self:name(oid) .. " cloned (" .. repaired .. " items repaired)")

	local g = self:group(pBot)

	if g == nil then
		if readStringData(ckey(oid, "mode")) == "group" then
			self:leftGroup(pBot, oid, now)
		end

		return
	end

	self:groupSay(pBot, oid, "cloned")

	local pLeader = g.leader.human and g.leader.p or (g.humans[1] ~= nil and g.humans[1].p or nil)

	if pLeader ~= nil then
		self:rejoin(pBot, oid, pLeader, now)
	end

	self:startLoop(pBot, oid, 2000)
end

-- Back to the leader: on another planet it travels there; then it follows (BotMover catches up from afar)
function BotCrew:rejoin(pBot, oid, pLeader, now)
	local zone = SceneObject(pLeader):getZoneName()

	if zone ~= "" and zone ~= SceneObject(pBot):getZoneName() then
		print("BotJobs: " .. self:name(oid) .. " travels to " .. zone .. " to rejoin " .. self:firstName(pLeader))
		SceneObject(pBot):switchZone(zone, SceneObject(pLeader):getWorldPositionX() + 3, 0,
			SceneObject(pLeader):getWorldPositionY() + 3, 0)
		return
	end

	put(ckey(oid, "followAt"), now)
	bot("botFollow", pBot, pLeader)
end

-- Out of a fight: in camp, or following (or staying put); the ranger offers a camp when the group is hurt

function BotCrew:outOfCombat(pBot, oid, g, pLeader, now)
	local role = self:role(oid)

	-- On a mission errand (it walks to a terminal itself), and the leader's mission waypoints (crew_missions.lua)
	if self:missionTick(pBot, oid, pLeader, now) then
		return
	end

	if role == "medic" and BotDoctor ~= nil then
		BotDoctor:topUpMind(pBot)
	end

	local camp = self:activeCamp(g, pLeader)

	if camp ~= nil then
		self:inCamp(pBot, oid, g, pLeader, camp, now)
		return
	end

	if readData(ckey(oid, "inCamp")) == 1 then
		deleteData(ckey(oid, "inCamp"))
		deleteStringData(ckey(oid, "campTried"))
		self:standUp(pBot, oid)

		if role == "medic" and BotDoctor ~= nil then
			BotDoctor:clear(oid)
		elseif role == "ranger" then
			-- Its camp goes when the group moves on (Core3 would abandon it a while later anyway)
			bot("botRemoveCamp", pBot)
		end
	end

	if readStringData(ckey(oid, "order")) ~= "stay" then
		self:ensureFollow(pBot, oid, pLeader, now)
	end

	if role == "ranger" then
		self:maybeOfferCamp(pBot, oid, g, pLeader, now)
	end
end

-- The group's camp while it stands and the leader is by it; it's forgotten once the group moves on (Core3 takes an
-- abandoned camp down by itself)
function BotCrew:activeCamp(g, pLeader)
	if pLeader == nil then
		return nil
	end

	local leaderOid = SceneObject(pLeader):getObjectID()
	local campOid = readData(gkey(leaderOid, "camp"))

	if campOid == 0 then
		return nil
	end

	local pCamp = getSceneObject(campOid)
	local dist = pCamp ~= nil and BotJobs:distance(pLeader, pCamp) or nil

	if dist == nil or dist > self.campRange then
		deleteData(gkey(leaderOid, "camp"))
		print("BotJobs: the camp of " .. self:firstName(pLeader) .. "'s group is over")
		return nil
	end

	return {oid = campOid, p = pCamp, x = SceneObject(pCamp):getWorldPositionX(), y = SceneObject(pCamp):getWorldPositionY(),
		z = SceneObject(pCamp):getPositionZ()}
end

-- In camp: the crew sit around the fire; the medic stands by it and buffs everyone
function BotCrew:inCamp(pBot, oid, g, pLeader, camp, now)
	put(ckey(oid, "inCamp"), 1)

	if self:role(oid) == "medic" then
		self:medicCamp(pBot, oid, g, pLeader, camp, now)
		return
	end

	local index, count = 1, 1

	for i, m in ipairs(g.crew) do
		if m.oid == oid then
			index = i
		end

		count = i
	end

	local angle = math.rad(index * 360 / (count + 1))
	local x, y = camp.x + math.sin(angle) * self.campSpot, camp.y + math.cos(angle) * self.campSpot

	if worldDistance(pBot, x, y) > 1.5 then
		if now - readData(ckey(oid, "goAt")) >= self.moveEvery then
			put(ckey(oid, "goAt"), now)
			self:standUp(pBot, oid)
			bot("botMoveTo", pBot, x, camp.z, y, 0)
		end

		return
	end

	if readData(ckey(oid, "sitting")) ~= 1 then
		self:stopMoving(pBot)
		botEnqueue(pBot, "sitserver", 0, "")
		put(ckey(oid, "sitting"), 1)
		put(ckey(oid, "sitUntil"), now + 3600)
	end
end

-- When the medic last took each member on at this camp: "<camp>;oid=time,oid=time"
function BotCrew:campTried(oid, campOid)
	local saved = readStringData(ckey(oid, "campTried"))
	local forCamp, list = saved:match("^(%d+);(.*)$")
	local tried = {}

	if tonumber(forCamp) ~= campOid then
		return tried
	end

	for memberOid, at in string.gmatch(list, "(%d+)=(%d+)") do
		tried[tonumber(memberOid)] = tonumber(at)
	end

	return tried
end

function BotCrew:markTried(oid, campOid, memberOid, now)
	local tried = self:campTried(oid, campOid)
	local parts = {}

	tried[memberOid] = now

	for member, at in pairs(tried) do
		table.insert(parts, member .. "=" .. at)
	end

	putString(ckey(oid, "campTried"), campOid .. ";" .. table.concat(parts, ","))
end

-- What a member needs from the medic: "buff" while one of the six pools has no enhancement on it (its maximum isn't
-- above its base), "wounds" when only wounds are left, else nil. (Lock-free getters, and botGetWounds as the doctor
-- uses it.)
function BotCrew:needs(pPatient)
	local creature = CreatureObject(pPatient)

	for pool = 0, 5 do
		if creature:getMaxHAM(pool) <= creature:getBaseHAM(pool) then
			return "buff"
		end
	end

	for pool = 0, 5 do
		if botGetWounds(pPatient, pool) > 0 then
			return "wounds"
		end
	end

	return nil
end

-- The medic at the fire (inside the camp, so its medical rating counts): the six enhancements and any wounds for
-- each member who lacks them, in turn (BotDoctor's chain), the leader first, then the crew, then itself. It asks the
-- leader over once if they're too far; someone who walked off mid-buff is taken on again after campRetry.
function BotCrew:medicCamp(pBot, oid, g, pLeader, camp, now)
	if BotDoctor == nil or not self:can(oid, "enhance") or readData(key(oid, "busy")) == 1 then
		return
	end

	if worldDistance(pBot, camp.x, camp.y) > 2.5 then
		if now - readData(ckey(oid, "goAt")) >= self.moveEvery then
			put(ckey(oid, "goAt"), now)
			self:standUp(pBot, oid)
			bot("botMoveTo", pBot, camp.x + 1, camp.z, camp.y, 0)
		end

		return
	end

	self:stopMoving(pBot)

	-- Buffs asked for by chat from out of reach, now within it
	BotDoctor:checkPending(pBot, oid, now)

	if readData(key(oid, "busy")) == 1 then
		return
	end

	local tried = self:campTried(oid, camp.oid)
	local order = {}

	for _, m in ipairs(g.humans) do
		table.insert(order, m)
	end

	for _, m in ipairs(g.crew) do
		if m.oid ~= oid then
			table.insert(order, m)
		end
	end

	table.insert(order, g.byOid[oid])

	for _, m in ipairs(order) do
		local need = (m ~= nil and m.player and not CreatureObject(m.p):isDead()) and self:needs(m.p) or nil

		if need ~= nil and now - (tried[m.oid] or 0) >= self.campRetry then
			local dist = m.oid == oid and 0 or BotJobs:distance(pBot, m.p)
			local name = self:firstName(m.p)

			if dist ~= nil and dist <= BotDoctor.enhanceRange then
				self:markTried(oid, camp.oid, m.oid, now)

				if not BotDoctor:waiting(oid, m.oid, need) then
					self:standUp(pBot, oid)
					print("BotJobs: " .. self:name(oid) .. " treats " .. name .. " in camp (" .. need .. ")")
					BotDoctor:enqueue(pBot, {oid = m.oid, kind = need, channel = m.human and "group" or "spatial", spoke = "1",
						tipped = "1", untilTime = 0}, name)
				end

				return
			end

			if m.human and readData(ckey(oid, "campAsked")) ~= m.oid then
				put(ckey(oid, "campAsked"), m.oid)
				self:groupSay(pBot, oid, "campCome", name)
			end
		end
	end
end

-- The ranger offers a camp when someone in the group is wounded or fatigued, out of a fight, outdoors, standing still
function BotCrew:maybeOfferCamp(pBot, oid, g, pLeader, now)
	if SceneObject(pBot):getParentID() ~= 0 or now - readData(ckey(oid, "offerAt")) < self.campOfferEvery or
		now - readData(ckey(oid, "peaceAt")) < self.campOfferAfterFight or self:groupFighting(g) then
		return
	end

	if (CreatureObject(pLeader):getCurrentSpeed() or 0) > 0.5 then
		return
	end

	for _, m in ipairs(g.members) do
		if m.player and not CreatureObject(m.p):isDead() then
			local wounds = 0

			for pool = 0, 8 do
				wounds = wounds + botGetWounds(m.p, pool)
			end

			if wounds >= self.woundedAt or botGetShockWounds(m.p) >= self.woundedAt then
				put(ckey(oid, "offerAt"), now)
				print("BotJobs: " .. self:name(oid) .. " offers a camp (" .. self:firstName(m.p) .. " is hurt)")
				self:groupSay(pBot, oid, "campOffer", self:firstName(pLeader))
				return
			end
		end
	end
end

-- The ranger places a camp next to the group (Core3's own camp kit and campsite)
function BotCrew:tryCamp(pBot, oid, pPlayer, channel, brainLine)
	local now = os.time()
	local playerOid = SceneObject(pPlayer):getObjectID()
	local name = self:firstName(pPlayer)
	local g = self:group(pBot)

	if g == nil or g.byOid[playerOid] == nil then
		if brainLine == nil then
			self:say(pBot, oid, playerOid, channel, "notWith", name)
		end

		return
	end

	local pLeader = self:leaderOf(pBot, oid, g, now) or pPlayer
	local kind = nil

	if self:activeCamp(g, pLeader) ~= nil then
		kind = "campAlready"
	elseif self:groupFighting(g) then
		kind = "campCombat"
	elseif SceneObject(pBot):getParentID() ~= 0 then
		kind = "campIndoors"
	end

	if kind ~= nil then
		self:say(pBot, oid, playerOid, channel, kind, name)
		return
	end

	self:stopMoving(pBot)

	local campOid, why = bot("botPlaceCamp", pBot, self:campKitOf(oid))

	campOid = campOid or 0

	if campOid == 0 then
		print("BotJobs: " .. self:name(oid) .. " couldn't place a camp here (" .. tostring(why) .. ")")
		local why = tostring(why or "")
		local kind = "campFail"

		if why == "in water" then
			kind = "campWater"
		elseif why == "in a city" then
			kind = "campCity"
		elseif why == "lair too close" then
			kind = "campLair"
		elseif why == "camp too close" or why == "building too close" or why == "in another camp" then
			kind = "campCrowded"
		elseif why == "skill" or why == "in combat" or why == "inside" then
			kind = why == "in combat" and "campCombat" or (why == "inside" and "campIndoors" or "campFail")
		end

		self:say(pBot, oid, playerOid, channel, kind, name)
		return
	end

	put(gkey(SceneObject(pLeader):getObjectID(), "camp"), campOid)
	put(ckey(oid, "offerAt"), now)
	print("BotJobs: " .. self:name(oid) .. " placed a camp (" .. campOid .. ")")

	if brainLine == nil then
		self:say(pBot, oid, playerOid, channel, "campUp", name)
	end
end

-- Tracking: what the ranger finds (botTrack), told a moment later, filtered by any creature they named

function BotCrew:doTrack(pBot, oid, pPlayer, channel, brainLine)
	print("BotJobs: " .. self:name(oid) .. " tracks for " .. self:firstName(pPlayer))
	createEvent(self.trackDelayMs, "BotCrew", "trackReport", pBot,
		packArgs(readData(key(oid, "gen")), SceneObject(pPlayer):getObjectID(), channel))
end

local COMPASS = {"north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"}

local function direction(bearing)
	local degrees = tonumber(bearing)

	if degrees == nil then
		return tostring(bearing or "")
	end

	return COMPASS[math.floor(((degrees % 360) + 22.5) / 45) % 8 + 1]
end

-- "a womp rat" -> "womp rat"; plural "womp rats"
local function bareName(name)
	local bare = tostring(name or "something"):lower():gsub("^an? ", ""):gsub("^the ", "")

	return bare
end

local function plural(name)
	if name:match("s$") then
		return name
	end

	return name .. "s"
end

local function article(name)
	return (name:match("^[aeiou]") and "an " or "a ") .. name
end

-- A creature word from what they said that matches what was found, else the word they asked for (nil if none)
function BotCrew:trackWanted(text, found)
	local skip = {}

	for _, word in ipairs(self.notCreatures) do
		skip[word] = true
	end

	-- (not a bot's own first name: "Weeta, find me krayts")
	for _, entry in ipairs(botList ~= nil and botList() or {}) do
		skip[tostring(entry.firstName or ""):lower()] = true
	end

	local asked = nil

	for word in wordsOf(text):gsub("'", ""):gmatch("(%a+)") do
		if #word >= 4 and not skip[word] then
			local stem = word:gsub("ies$", "y"):gsub("es$", ""):gsub("s$", "")

			for _, entry in ipairs(found) do
				local name = bareName(entry.name)

				if name:find(stem, 1, true) ~= nil then
					return stem, true
				end
			end

			asked = asked or word
		end
	end

	return asked, false
end

-- Kinds of creature found, nearest first: "3 womp rats 120 m north-east, a krayt dragon 600 m south"
function BotCrew:describeTracks(found, stem)
	local kinds, order = {}, {}

	for _, entry in ipairs(found) do
		local name = bareName(entry.name)

		if stem == nil or name:find(stem, 1, true) ~= nil then
			local dist = tonumber(entry.distance) or 0
			local kind = kinds[name]

			if kind == nil then
				kind = {name = name, count = 0, dist = dist, bearing = entry.degrees or entry.bearing}
				kinds[name] = kind
				table.insert(order, kind)
			end

			kind.count = kind.count + 1

			if dist < kind.dist then
				kind.dist, kind.bearing = dist, entry.degrees or entry.bearing
			end
		end
	end

	table.sort(order, function(a, b) return a.dist < b.dist end)

	local parts = {}

	for i = 1, math.min(#order, self.trackShown) do
		local kind = order[i]
		local metres = math.max(10, math.floor(kind.dist / 10 + 0.5) * 10)
		local what = kind.count == 1 and article(kind.name) or (kind.count .. " " .. plural(kind.name))
		local where = direction(kind.bearing)

		table.insert(parts, what .. " " .. metres .. " m" .. (where ~= "" and (" " .. where) or ""))
	end

	return table.concat(parts, ", ")
end

function BotCrew:trackReport(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local playerOid, channel = num(a[2]) or 0, a[3] or "group"
	local found = bot("botTrack", pBot) or {}
	local stem, matched = self:trackWanted(readStringData(ckey(oid, "heard")), found)
	local pPlayer = getSceneObject(playerOid)
	local name = self:firstName(pPlayer)

	print("BotJobs: " .. self:name(oid) .. " tracked " .. #found .. " creatures" .. (stem ~= nil and (" (asked: " .. stem .. ")") or ""))

	if #found == 0 then
		self:say(pBot, oid, playerOid, channel, "trackNone", name)
	elseif stem ~= nil and matched then
		self:say(pBot, oid, playerOid, channel, "trackFound", name, {tracks = self:describeTracks(found, stem)})
	elseif stem ~= nil then
		self:say(pBot, oid, playerOid, channel, "trackNoMatch", name, {what = plural(stem), tracks = self:describeTracks(found, nil)})
	else
		self:say(pBot, oid, playerOid, channel, "trackFound", name, {tracks = self:describeTracks(found, nil)})
	end
end

-- Talking: keywords (without the language model), the brain's actions, what to do

-- The text intent() last saw, and whether groupAddressed() took it for the whole group: BotJobs:heard calls
-- groupAddressed, intent and onSpoken one after another on one thread, so onSpoken stores them for act()
local lastHeard, lastForGroup = nil, false

-- The intent in the words for a role (nil: any role)
function BotCrew:intentFor(text, role)
	local t = wordsOf(text)

	for _, intent in ipairs({"home", "follow", "stay", "join", "camp", "track", "buff", "wounds"}) do
		if hasAny(t, self.words[intent]) then
			local owner = self.owners[intent]

			if owner == nil or role == nil or owner == role then
				return intent
			end
		end
	end

	return nil
end

function BotCrew:intent(text)
	lastHeard = text

	return self:intentFor(text, self.crewRole)
end

local ORDERS = {join = true, follow = true, stay = true, home = true}

function BotCrew:isAction(intent)
	return intent ~= nil and (ORDERS[intent] == true or self.owners[intent] ~= nil)
end

-- The brain's action (reply line 4), for this role
function BotCrew:allowed(action)
	if action == "backoff" or action == "peace" then
		action = "follow"
	elseif action == "wound" then
		action = "wounds"
	end

	if ORDERS[action] then
		return action
	end

	local owner = self.owners[action]

	if owner ~= nil and (self.crewRole == nil or owner == self.crewRole) then
		return action
	end

	return nil
end

function BotCrew:act(pBot, pPlayer, action, channel, brainLine)
	local oid = SceneObject(pBot):getObjectID()

	if action == "join" then
		self:join(pBot, oid, pPlayer, channel, brainLine)
	elseif ORDERS[action] then
		self:order(pBot, oid, pPlayer, action, channel, brainLine)
	elseif action == "camp" and self:role(oid) == "ranger" then
		self:tryCamp(pBot, oid, pPlayer, channel, brainLine)
	elseif action == "track" and self:role(oid) == "ranger" then
		self:doTrack(pBot, oid, pPlayer, channel, brainLine)
	elseif (action == "buff" or action == "wounds") and self:role(oid) == "medic" then
		self:medicBuff(pBot, oid, pPlayer, action, channel, brainLine)
	end
end

-- Extra fields for the brain's request (BotJobs:ask): grouped is 1 while this bot is in a player's group
function BotCrew:requestFields(pBot, oid)
	return {grouped = (pBot ~= nil and CreatureObject(pBot):isGrouped()) and 1 or 0}
end

function BotCrew:onSpoken(pBot, oid, pSpeaker, channel, text)
	putString(ckey(oid, "heard"), lastHeard or "")
	put(ckey(oid, "forGroup"), lastForGroup and 1 or 0)
	lastHeard, lastForGroup = nil, false

	-- Missions (crew_missions.lua) are the crew's own business: the language model isn't asked
	if channel == "group" and self:missionHeard(pBot, oid, pSpeaker, channel, text) then
		return true
	end

	-- At home it turns to whoever talks to it
	if channel == "spatial" and not CreatureObject(pBot):isGrouped() then
		botFace(pBot, pSpeaker)
	end
end

-- Is a crew mate's first name a word in the text?
function BotCrew:named(mateOid, text)
	local first = (readStringData(key(mateOid, "first")):lower():gsub("[^%a]", " "))

	if first:match("^%s*$") then
		return false
	end

	return string.find(" " .. (tostring(text or ""):lower():gsub("[^%a]", " ")) .. " ", " " .. first .. " ", 1, true) ~= nil
end

function BotCrew:affirmed(text)
	local t = wordsOf(text)

	for _, word in ipairs(self.affirmative) do
		if t:find(" " .. word .. " ", 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- Group chat that names nobody (BotJobs:heard asks): a camp the ranger offered, accepted, is placed at once; work
-- that's one member's goes to that member; anything else, the first crew member in the group answers for everyone
-- (and its orders go to the others too)
function BotCrew:groupAddressed(pBot, pSpeaker, text)
	lastForGroup = false

	local oid = SceneObject(pBot):getObjectID()
	local g = self:group(pBot)

	if g == nil then
		return false
	end

	for _, m in ipairs(g.crew) do
		if m.oid ~= oid and self:named(m.oid, text) then
			return false
		end
	end

	local role = self:role(oid)
	local intent = self:intentFor(text, nil)

	if role == "ranger" and os.time() - readData(ckey(oid, "offerAt")) <= self.campOfferWindow and
		readData(ckey(oid, "offerAt")) ~= 0 and intent ~= "home" and self:affirmed(text) then
		put(ckey(oid, "offerAt"), os.time() - self.campOfferWindow - 1)
		self:tryCamp(pBot, oid, pSpeaker, "group", nil)
		return false
	end

	local owner = self.owners[intent or ""]

	if owner ~= nil then
		for _, m in ipairs(g.crew) do
			if m.job == owner then
				return m.oid == oid
			end
		end
	end

	if g.crew[1] ~= nil and g.crew[1].oid == oid then
		lastForGroup = true
		return true
	end

	return false
end

-- "Wanna hunt?": a player in a group is asked for an invite; one on their own gets the bot's invite, and the lead
-- once they accept (the bot never leads)
function BotCrew:join(pBot, oid, pPlayer, channel, brainLine)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local name = self:firstName(pPlayer)
	local g = self:group(pBot)
	local kind = nil

	if g ~= nil then
		kind = g.byOid[playerOid] ~= nil and "alreadyWith" or "otherGroup"
	elseif CreatureObject(pPlayer):isGrouped() then
		kind = "askInvite"
	else
		botEnqueue(pBot, "invite", playerOid, "")
		put(ckey(oid, "invited"), playerOid)
		put(ckey(oid, "invitedAt"), os.time())
		print("BotJobs: " .. self:name(oid) .. " invites " .. name)
		kind = "inviteSent"
	end

	if brainLine == nil then
		self:say(pBot, oid, playerOid, channel, kind, name)
	end
end

-- follow, stay, home from a group member; from someone else, "follow" is a join and the rest a shrug
function BotCrew:order(pBot, oid, pPlayer, action, channel, brainLine)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local name = self:firstName(pPlayer)
	local g = self:group(pBot)

	if g == nil or g.byOid[playerOid] == nil then
		if action == "follow" then
			self:join(pBot, oid, pPlayer, channel, brainLine)
		elseif brainLine == nil then
			self:say(pBot, oid, playerOid, channel, "notWith", name)
		end

		return
	end

	local fighting = readData(ckey(oid, "target")) ~= 0

	if brainLine == nil then
		self:say(pBot, oid, playerOid, channel, (action == "follow" and fighting) and "backOff" or action, name)
	end

	self:applyOrder(pBot, oid, action, os.time())

	-- Said to the whole group (this bot answered for it): the other crew members do it too, quietly
	if channel == "group" and readData(ckey(oid, "forGroup")) == 1 then
		put(ckey(oid, "forGroup"), 0)

		for i, m in ipairs(g.crew) do
			if m.oid ~= oid then
				createEvent(300 * i, "BotCrew", "groupOrder", m.p, packArgs(readData(key(m.oid, "gen")), action))
			end
		end
	end
end

function BotCrew:groupOrder(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) or not CreatureObject(pBot):isGrouped() then
		return
	end

	self:applyOrder(pBot, SceneObject(pBot):getObjectID(), a[2], os.time())
end

function BotCrew:applyOrder(pBot, oid, action, now)
	print("BotJobs: " .. self:name(oid) .. " " .. action .. "s")

	if action == "stay" then
		putString(ckey(oid, "order"), "stay")
		self:stopMoving(pBot)
	elseif action == "follow" then
		putString(ckey(oid, "order"), "follow")
		deleteData(ckey(oid, "followAt"))

		-- "Back off" in a fight: peace, and no new fight for a moment
		if readData(ckey(oid, "target")) ~= 0 then
			put(ckey(oid, "holdUntil"), now + self.holdFire)
			self:endFight(pBot, oid, now)
		end

		local pLeader = getSceneObject(readData(ckey(oid, "leader")))

		if pLeader ~= nil then
			self:ensureFollow(pBot, oid, pLeader, now)
		end
	elseif action == "home" then
		put(ckey(oid, "saidBye"), 1)

		if readData(ckey(oid, "target")) ~= 0 then
			self:endFight(pBot, oid, now)
		end

		botEnqueue(pBot, "leavegroup", 0, "")
		self:stopMoving(pBot)

		if self:role(oid) == "medic" and BotDoctor ~= nil then
			BotDoctor:clear(oid)
		end

		self:leaveForHome(pBot, oid, now)
	end
end

-- Buffs from the medic: only at a camp or in a medical centre, as for any doctor (BotDoctor's queue and lines)
function BotCrew:medicBuff(pBot, oid, pPlayer, kind, channel, brainLine)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local name = self:firstName(pPlayer)
	local g = self:group(pBot)
	local fighting = CreatureObject(pBot):isInCombat() or (g ~= nil and self:groupFighting(g))

	if fighting then
		self:say(pBot, oid, playerOid, channel, "inCombat", name)
		return
	end

	local camp = nil

	if g ~= nil then
		camp = self:activeCamp(g, self:leaderOf(pBot, oid, g, os.time()))
	end

	if camp == nil and (CreatureObject(pBot):getSkillMod("private_medical_rating") or 0) <= 0 then
		self:say(pBot, oid, playerOid, channel, "noSite", name)
		return
	end

	if camp ~= nil then
		-- This request is their treatment at this camp (asked again, they get a fresh set)
		self:markTried(oid, camp.oid, playerOid, os.time())
	end

	BotDoctor:request(pBot, pPlayer, kind, channel, brainLine)
end

-- Events from the C++ body (BotJobs:onEvent)
function BotCrew:onEvent(pBot, oid, name, pOther, detail)
	local now = os.time()
	local mode = readStringData(ckey(oid, "mode"))

	if name == "groupInvite" then
		if pOther == nil then
			pOther = getSceneObject(bot("botGetGroupInviter", pBot) or 0)
		end

		self:invited(pBot, oid, pOther, now)
	elseif name == "cloned" then
		self:afterClone(pBot, oid, now)
	elseif name == "died" or name == "incapacitated" or name == "duel" or name == "fightStarted" then
		self:startLoop(pBot, oid, 200)
	elseif name == "arrived" then
		if mode == "walkingHome" then
			self:atHome(pBot, oid)
			print("BotJobs: " .. self:name(oid) .. " is back at its station")
		end
	elseif name == "stuck" then
		if mode == "walkingHome" then
			self:teleportHome(pBot, oid)
		end
	elseif name == "leaderGone" then
		-- The leader logged out a while ago: leave the group and go home
		if CreatureObject(pBot):isGrouped() then
			print("BotJobs: " .. self:name(oid) .. "'s leader is gone, leaving the group")
			put(ckey(oid, "saidBye"), 1)
			botEnqueue(pBot, "leavegroup", 0, "")
		end
	end
end

-- Console: bot-on-bot development (the local server has no game client)

local function devBot(first)
	return botGetCreature ~= nil and botGetCreature(first or "") or nil
end

function BotCrew:devLead(first, off)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	local on = off ~= "off"

	put("crew:pretend:" .. SceneObject(pBot):getObjectID(), on and 1 or 0)
	print("BotCrew: " .. tostring(first) .. (on and " counts as a player leader" or " is a bot again"))
end

function BotCrew:devInvite(leader, crew)
	local pLeader, pCrew = devBot(leader), devBot(crew)

	if pLeader == nil or pCrew == nil then
		print("BotCrew: usage devInvite:<leader bot>:<crew bot>, both online")
		return
	end

	createEvent(10, "BotCrew", "devCommand", pLeader, packArgs("invite", SceneObject(pCrew):getObjectID()))
end

function BotCrew:devAttack(leader, targetOid)
	local pLeader = devBot(leader)

	if pLeader == nil or tonumber(targetOid or "") == nil then
		print("BotCrew: usage devAttack:<leader bot>:<target oid>")
		return
	end

	createEvent(10, "BotCrew", "devCommand", pLeader, packArgs("attack", targetOid))
end

function BotCrew:devPeace(leader)
	local pLeader = devBot(leader)

	if pLeader == nil then
		print("BotCrew: usage devPeace:<leader bot>")
		return
	end

	createEvent(10, "BotCrew", "devCommand", pLeader, packArgs("peace", 0))
end

-- In an event on the leader bot: a command (an attack also sets its target)
function BotCrew:devCommand(pBot, args)
	local a = unpackArgs(args)
	local target = math.floor(tonumber(a[2]) or 0)

	if a[1] == "attack" then
		bot("botSetTarget", pBot, target)
	end

	print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " " .. a[1] .. " " .. target .. ": " ..
		tostring(botEnqueue(pBot, a[1], target, "")))
end

-- The leader's words in group chat reach every crew bot in its group, as patch 0003 delivers a player's
function BotCrew:devGroupSay(leader, text)
	local pLeader = devBot(leader)

	if pLeader == nil or text == nil or text == "" then
		print("BotCrew: usage devGroupSay:<leader bot>:<text>")
		return
	end

	createEvent(10, "BotCrew", "devGroupHeard", pLeader, (text:gsub("_", " "):gsub(":", " ")))
end

function BotCrew:devGroupHeard(pLeader, text)
	local g = self:group(pLeader)

	if g == nil then
		print("BotCrew: " .. CreatureObject(pLeader):getFirstName() .. " isn't in a group")
		return
	end

	print("BotCrew: " .. CreatureObject(pLeader):getFirstName() .. " (group): " .. text)

	for _, m in ipairs(g.crew) do
		createEvent(10, "BotCrew", "devGroupHear", m.p, packArgs(SceneObject(pLeader):getObjectID(), text))
	end
end

function BotCrew:devGroupHear(pBot, args)
	local leaderOid, text = args:match("^(%d+):(.*)$")

	BotJobs:heard(pBot, getSceneObject(tonumber(leaderOid)), text, "group", false)
end

function BotCrew:devSpawn(near, template, metres)
	local pBot = devBot(near)

	if pBot == nil or template == nil or template == "" then
		print("BotCrew: usage devSpawn:<near bot>:<mobile template>[:<metres north>]")
		return
	end

	createEvent(10, "BotCrew", "devSpawnNow", pBot, packArgs(template, tonumber(metres or "") or 25))
end

function BotCrew:devSpawnNow(pBot, args)
	local a = unpackArgs(args)
	local x, y = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY() + tonumber(a[2])
	local z = SceneObject(pBot):getWorldPositionZ() -- (getWorldFloor can read a roof)
	local pMobile = spawnMobile(SceneObject(pBot):getZoneName(), a[1], 0, x, z, y, 0, 0)

	print("BotCrew: spawned " .. a[1] .. ": " .. (pMobile ~= nil and tostring(SceneObject(pMobile):getObjectID()) or "failed"))
end

function BotCrew:devWalk(first, x, y)
	local pBot = devBot(first)

	if pBot == nil or tonumber(x or "") == nil or tonumber(y or "") == nil then
		print("BotCrew: usage devWalk:<bot>:<x>:<y>")
		return
	end

	createEvent(10, "BotCrew", "devWalkNow", pBot, packArgs(x, y))
end

function BotCrew:devWalkNow(pBot, args)
	local a = unpackArgs(args)
	local x, y = tonumber(a[1]), tonumber(a[2])
	local z = SceneObject(pBot):getWorldPositionZ() -- (getWorldFloor can read a roof)

	print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " walks to " .. x .. " " .. y .. ": " ..
		tostring(bot("botMoveTo", pBot, x, z, y, 0)))
end

-- A bot attacks an object (botSetTarget) and, with a command, uses it on it: devFire:<first>:<oid>[:<command>]
function BotCrew:devFire(first, targetOid, cmd)
	local pBot = devBot(first)

	if pBot == nil or tonumber(targetOid or "") == nil then
		print("BotCrew: usage devFire:<bot>:<target oid>[:<command>]")
		return
	end

	createEvent(10, "BotCrew", "devFireNow", pBot, packArgs(targetOid, cmd or ""))
end

function BotCrew:devFireNow(pBot, args)
	local a = unpackArgs(args)
	local target = math.floor(tonumber(a[1]))
	local set = bot("botSetTarget", pBot, target)

	print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " botSetTarget " .. target .. ": " .. tostring(set) ..
		(a[2] ~= nil and (", " .. a[2] .. ": " .. tostring(botEnqueue(pBot, a[2], target, ""))) or ""))
end

-- Hurt a bot: devHurt:<first>[:<amount>] takes that much health (default: all and more, so it is incapacitated; a third
-- incap within ten minutes kills)
function BotCrew:devHurt(first, amount)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	createEvent(10, "BotCrew", "devHurtNow", pBot, tostring(tonumber(amount or "") or 0))
end

function BotCrew:devHurtNow(pBot, amount)
	local damage = tonumber(amount) or 0

	if damage <= 0 then
		damage = CreatureObject(pBot):getHAM(HEALTH) + 100
	end

	CreatureObject(pBot):inflictDamage(pBot, HEALTH, damage, 1)
	print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " takes " .. damage .. " damage, health " ..
		CreatureObject(pBot):getHAM(HEALTH) .. ", incap " .. tostring(CreatureObject(pBot):isIncapacitated()) .. ", dead " ..
		tostring(CreatureObject(pBot):isDead()))
end

-- A bot's combat state, and (with an oid) its view of that creature
function BotCrew:devProbe(first, targetOid)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	local c = CreatureObject(pBot)
	local line = "BotCrew: " .. tostring(first) .. " inCombat " .. tostring(c:isInCombat()) .. ", target " ..
		tostring(c:getTargetID()) .. ", incap " .. tostring(c:isIncapacitated()) .. ", dead " .. tostring(c:isDead())

	local states = ""

	for name, bit in pairs({stunned = 0x1000, blinded = 0x2000, dizzy = 0x4000, intimidated = 0x8000, poisoned = POISONED,
		diseased = DISEASED}) do
		if hasState(pBot, bit) then
			states = states .. " " .. name
		end
	end

	line = line .. ", states [" .. states .. " ]"

	local pHeld = SceneObject(pBot):getSlottedObject("hold_r")

	line = line .. ", holding " .. (pHeld ~= nil and SceneObject(pHeld):getTemplateObjectPath() or "nothing") ..
		", weapon type " .. tostring(c:getWeaponType()) .. ", queue " .. tostring(c:getQueueSize()) .. ", posture " ..
		tostring(c:getPosture()) .. ""

	local pTarget = getSceneObject(tonumber(targetOid or "") or 0)

	if pTarget ~= nil then
		local t = CreatureObject(pTarget)

		line = line .. "; target dead " .. tostring(t:isDead()) .. ", attackable " .. tostring(t:isAttackableBy(pBot)) ..
			", dist " .. tostring(BotJobs:distance(pBot, pTarget)) .. ", inCombat " .. tostring(t:isInCombat()) ..
			", HAM " .. t:getHAM(HEALTH) .. string.format(", z %.1f vs %.1f, 3d %.1f", SceneObject(pBot):getWorldPositionZ(),
			SceneObject(pTarget):getWorldPositionZ(), SceneObject(pBot):getDistanceTo3d(pTarget))
	end

	print(line)
end

function BotCrew:devState(first)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	local oid = SceneObject(pBot):getObjectID()

	print("BotCrew: " .. tostring(first) .. " (" .. self:role(oid) .. "): " .. self:state(pBot, oid) .. "; can " ..
		readStringData(ckey(oid, "can")) .. "; specials " .. readStringData(ckey(oid, "specialsList")))
end

-- Destroy missions in the leader's direction (Phase 7)
includeFile("../custom_scripts/screenplays/bots/crew_missions.lua")

-- The four roles share this module; each has its own table (for the role-aware keywords and the brain's actions)
BotJobModules = BotJobModules or {}

for role in pairs(CREW) do
	BotJobModules[role] = BotCrew:new {crewRole = role, kit = role == "medic" and "medic" or "fighter"}
end
