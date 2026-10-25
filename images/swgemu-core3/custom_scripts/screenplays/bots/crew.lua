-- Bot players (Phase 5): the hunting crew. Seven bots wait in the Mos Eisley cantina like players looking for a group:
-- a tank (Teras Kasi), a rifleman, a medic (combat medic and doctor), a ranger, and (Phase 8) a squad leader, an
-- entertainer and a commando. Invite one (or ask "wanna hunt?")
-- and it joins, follows its leader's trail (BotMover), fights what the leader fights or whatever attacks the group,
-- heals, revives, camps and tracks, and goes home when dismissed. It never leads: a group it ends up leading is handed
-- to the player. Spec: ~/github/swgemu/specs/2026-10-23-bot-group-mates/ (the contract is
-- specs/2026-10-23-bot-players/interfaces.md, "Phases 4-6").
--
-- A job module (the interface is at the top of bot_jobs.lua), registered for each role in CREW. While a
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
--   runLuaFunction BotCrew:devSay:<leader>:<text>              the leader says <text> out loud (spatial chat)
--   runLuaFunction BotCrew:devHear:<speaker>:<first>:<text>[:spatial|tell]   the speaker says <text> to one bot, e.g. one that left the group
--   runLuaFunction BotCrew:devHunt:<first>                    a crew bot's hunt log and tally (what the brain gets)
--   runLuaFunction BotCrew:devAttack:<leader>:<oid>            the leader attacks an object (devPeace:<leader>: peace)
--   runLuaFunction BotCrew:devSpawn:<near>:<template>[:<m>]    spawn a creature <m> metres (default 25) north of a bot
--   runLuaFunction BotCrew:devWalk:<first>:<x>:<y>             a bot walks to a world point (outdoors)
--   runLuaFunction BotCrew:devToughen:<oid>[:<hp>]             a creature's HAM up, so a fight lasts
--   runLuaFunction BotCrew:devEquip:<first>:<template>         a bot holds a weapon (a leader bot needs a gun to open a fight)
--   runLuaFunction BotCombatDev:threat:<oid>                   a creature's threat map, target, taunt lockout, DoTs (C++)
--   runLuaFunction BotCrew:devState:<first>                    a crew bot's state
--   runLuaFunction BotCrew:devCall:<first>:<to>                a bot is called to another bot or player (botCallTo)
--   runLuaFunction BotCrew:devStock:<first>                    stock an area poison pack and a grenade, log their oids
--   runLuaFunction BotCrew:devResists:<oid>                    a creature's resistances (botResists)
--   runLuaFunction BotCrew:devSpawnBy:<bot>:<oid>:<template>   a creature 1.5 m from another creature
--   runLuaFunction BotCrew:devField:<first>                    the creatures around a grouped crew bot, pulled or not, as the area attacks see them
--   runLuaFunction BotCombatDev:gear:<first>                   what a bot wears, holds and carries (C++)

includeFile("../custom_scripts/screenplays/bots/crew_lines.lua")
includeFile("../custom_scripts/screenplays/bots/crew_swoop.lua")

-- CreatureAttribute, CreaturePosture, CreatureState
local HEALTH, ACTION, MIND = 0, 3, 6
local SITTING = 8
local CROUCHED = 1
local STATES = {0x1000, 0x2000, 0x4000, 0x8000} -- stunned, blinded, dizzy, intimidated: what healstate cures
local POISONED, DISEASED = 0x800000, 0x2000000

local CREW = {tank = true, rifleman = true, medic = true, ranger = true, squadleader = true, entertainer = true, commando = true}
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
	defaults = {specialsHam = 0.5, stimPower = 800, rangedStimPower = 800, curePower = 300, packStock = 20,
		-- The poison and disease packs, at what a master crafter makes (Core3's template limits): strength of the DoT,
		-- seconds, the chance to land (against resistance) and the throw range in metres (+14 at healing range 100)
		dotPower = 250, dotDuration = 240, dotPotency = 150, dotRange = 30},

	-- The group cap (Phase 8): the crew keeps a group to this many (Core3's own is 20). One of us takes all seven crew; with
	-- both, the commando joins only while there is a slot left for the other human
	groupCap = 8,
	capEvery = 10,

	-- Fighting
	engageRange = 80,     -- a target further than this is left alone
	meleeReach = 4,       -- unarmed reach, inside Core3's 5 m
	closeTo = 2,          -- the tank walks to this far from its target
	lungeRange = {6, 18}, -- unarmedlunge2 reaches 20 m
	-- The tank holds every creature (Phase 7c): it taunts what is on someone else when the creature's taunt lockout is
	-- over (Core3's, read with botThreatOn), at most once per creature per tauntGap seconds, within tauntRange (the
	-- taunt's reach). A creature it can't taunt yet is intimidated (within intimidateRange) or warcried, once per
	-- debuffGap seconds each.
	tauntRange = 64,
	tauntGap = 6,
	tauntLook = 5,        -- creatures it looks at in one step
	intimidateRange = 24,
	debuffGap = 12,
	-- The others hold fire on a creature that isn't on the tank (on nobody, or on the human who pulled it) until it is
	-- on the tank, or holdFor seconds after the tank engaged it (holdMax from when they first held, if the tank never
	-- does); never for a creature on themselves
	holdFor = 3,
	holdMax = 6,
	-- The ranger rescues a creature on a group member (not the tank) that the tank hasn't taken after this long (s)
	rescueAfter = 2.5,
	rescueRange = 40,
	-- Range bands (Phase 7c): a ranged bot stands between its weapon's ideal range less bandWidth and the ideal range
	-- (at least bandMin, at most bandMax metres; botWeaponRange). The medic's band is cut to its ranged-stim reach
	-- from the tank. It places itself bandIn metres inside the band's far edge, on the leader's side of the target,
	-- no closer than lairAvoid to a lair (scanned within lairScan every lairEvery seconds).
	bandWidth = 10,
	bandMin = 8,
	bandMax = 60,
	bandIn = 2,
	bandSettle = 2,       -- a walk to the band goes on until the bot is this far inside its edges
	lairAvoid = 25,
	lairScan = 120,
	lairEvery = 6,
	-- Backing off: a creature on the bot closer than the band's near edge (at least backOffRange) makes it step backOffStep
	-- metres away from the creature and toward the group, without firing, for at most backFor seconds (then it stands and
	-- fights, and doesn't back off again for backBlock). A placement walk that takes longer than moveFor seconds is
	-- given up for moveBlock seconds.
	backOffRange = 15,
	backOffStep = 10,
	backFor = 4,
	backBlock = 8,
	moveFor = 12,
	dotMindFloor = 0.4,   -- the medic throws packs only with this share of its mind
	dotResistAfter = 6,   -- a pack thrown this long ago with nothing on the creature was resisted (the throw waits in the queue)
	moveBlock = 6,
	stepGap = 1.5,        -- seconds between the walks of a band move
	leaderSpread = 60,    -- a ranged bot standing to shoot follows again when its leader is further than this
	holdFire = 10,        -- seconds without picking a fight after "back off"
	moveEvery = 3,        -- seconds between walks after a moving target
	attackerFresh = 5,    -- seconds an attacker seen on a group member counts
	-- Callouts, as players made them: a fight is chatty with this chance, and a bot says one line per calloutGap s at most
	calloutChance = 33,
	calloutGap = 20,

	-- The squad leader (Phase 8) calls the fight with Core3's squad leader commands, though we lead. It needs this share of
	-- each of its pools (a command costs about 130 of each); a call in group chat at most every slCallGap seconds. Rally at the
	-- start of a fight with slRallyCreatures or more creatures or a lair (at most every slRallyGap s); volley fire on the tank's
	-- target when slVolleyMembers or more of the group fight it (every slVolleyGap s); form up when a member is stunned or
	-- dizzy; steady aim outdoors again every slAimEvery s (its 300 s); boost morale after a fight when one member carries over
	-- slMoraleShare of at least slMoraleWounds wounds. Retreat when the fight is lost (the tank down and two members under
	-- retreatLow of their health, or three members down), at most every retreatBlock s: the crew breaks off and follows the
	-- leader for retreatFor s, or until nothing has chased for retreatMin s; then it holds fire retreatHold s
	slHamFloor = 0.45,
	slPay = 170,
	slCallGap = 20,
	slRallyCreatures = 2,
	slRallyGap = 45,
	slVolleyMembers = 3,
	slVolleyGap = 20,
	slFormUpGap = 8,
	slAimEvery = 295,
	townRadius = 450,
	slMoraleShare = 0.6,
	slMoraleWounds = 300,
	slMoraleGap = 90,
	retreatLow = 0.3,
	retreatBlock = 60,
	retreatFor = 30,
	retreatMin = 6,
	retreatHold = 4,

	-- Calling the crew (Phase 8): "crew, come to me" (a tell to any crew bot, or group chat). Each crew bot that is free (at home,
	-- or in the caller's group; not in someone else's) is put near the caller after callDelay seconds, about 10 m behind
	-- them, unless it is already within callNear metres. One that isn't grouped then waits calledWait seconds for an invite
	-- (the first to arrive sends one, as at the cantina; the others ask for one), and goes home if none comes
	callDelay = {5, 10},
	callNear = 40,
	calledWait = 600,
	callInviteWindow = 120,

	-- The medic's area packs (Phase 8): instead of a single pack when areaMin or more creatures of the group (on the tank, when
	-- there is one) stand within areaRadius of its target, and nothing that isn't fighting the group within areaSafe of it
	-- (the pack hits every attackable creature there, and makes the medic a defender of each)
	areaMin = 3,
	areaRadius = 10,
	areaSafe = 11,

	-- The entertainer (Phase 8): in a camp it dances (a flourish every perfFlourish seconds, a dance that stopped is started
	-- again after perfRestart), or plays when asked; its action is topped up below perfActionFloor percent, as the town
	-- dancer's is
	perfFlourish = {20, 40},
	perfRestart = 15,
	perfActionFloor = 30,

	-- The commando (Phase 8). Flame thrower and acid rifle specials reach 16 m (single shots too), so it stands 12-15 m from
	-- the fight (commandoBand), and fires a cone (45 degrees, so 22.5 to each side) when coneMin or more creatures of the
	-- group stand in it, else a single shot. A grenade (10 m blast) at a clump of grenadeMin or more creatures on the tank,
	-- within grenadeClump of each other and grenadeRange of the commando, at most every grenadeGap s. No cone or grenade
	-- when a creature that isn't fighting the group stands in its area, which is checked a little wider (coneSafeRange and
	-- coneSafeHalf, grenadeSafe). The weapon with the better expected damage against the target's armor is held (the flame
	-- thrower's 480-840 against the acid rifle's 60-160 on average, flameAvg and acidAvg), with a margin, and not swapped
	-- more often than every swapGap s.
	commandoBand = {12, 15},
	coneRange = 15.5,
	coneHalf = 22.5,
	coneMin = 2,
	coneSafeRange = 18,
	coneSafeHalf = 30,
	grenadeMin = 3,
	grenadeClump = 9,
	grenadeRange = 40,
	grenadeSafe = 11,
	grenadeGap = 15,
	grenadeStock = 5,
	flameAvg = 660,
	acidAvg = 110,
	swapMargin = 1.15,
	swapGap = 10,
	grenade = "object/weapon/ranged/grenade/grenade_fragmentation.iff",
	acidRifle = "object/weapon/ranged/rifle/rifle_acid_beam.iff",

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
		-- Phase 8. The squad leader fights with a carbine like the ranger (set below); the entertainer with a pistol; the
		-- commando with a flame thrower (single shots here, the cones are its own turn)
		entertainer = {
			{cmd = "bodyshot3", skill = "combat_pistol_accuracy_03", weight = 4, family = "body"},
			{cmd = "bodyshot2", skill = "combat_marksman_pistol_03", weight = 4, family = "body"},
			{cmd = "bodyshot1", skill = "combat_marksman_pistol_01", weight = 4, family = "body"},
			{cmd = "healthshot2", skill = "combat_pistol_novice", weight = 3, family = "health"},
			{cmd = "healthshot1", skill = "combat_marksman_pistol_04", weight = 3, family = "health"},
		},
		commando = {
			{cmd = "flamesingle2", skill = "combat_commando_thrownweapon_04", weight = 4, family = "single"},
			{cmd = "flamesingle1", skill = "combat_commando_thrownweapon_01", weight = 4, family = "single"},
		},
	},
	-- What a bot can do besides specials, by the skill box that grants it (Core3's skills.iff)
	abilities = {
		taunt = "combat_brawler_novice",
		intimidate = "combat_brawler_novice", -- intimidate1 (24 m: no block, dodge or counter)
		warcry = "combat_brawler_novice",     -- warcry1 (a cone: delays the next attack)
		lunge = "combat_brawler_master",
		rescue = "outdoors_ranger_support_01",
		poisonPack = "science_combatmedic_novice",         -- applyPoison
		diseasePack = "science_combatmedic_healing_range_02", -- applyDisease
		stims = "science_medic_novice",
		rangedStims = "science_combatmedic_novice",
		states = "science_doctor_novice",
		curePoison = "science_doctor_wound_speed_02",
		cureDisease = "science_doctor_wound_speed_04",
		enhance = "science_doctor_wound_02",
		revive = "science_doctor_wound_04",
		-- Phase 8: the squad leader's six commands (each from its own box) and the commando's cones and grenades
		steadyAim = "outdoors_squadleader_offense_01",
		volley = "outdoors_squadleader_offense_03",
		formUp = "outdoors_squadleader_defense_01",
		boostMorale = "outdoors_squadleader_defense_04",
		rally = "outdoors_squadleader_support_01",
		retreat = "outdoors_squadleader_support_03",
		flameCone = "combat_commando_thrownweapon_02",
		acidCone = "combat_commando_support_02",
		grenade = "combat_commando_novice",
	},

	-- Healing. Reaches are half a metre inside Core3's (stims 7 m, ranged stims 30 m + healing_range 14 m, healstate
	-- 6 m, cures 7 m, reviveplayer 7 m), so a command we start isn't refused for range.
	reach = {stim = 6.5, ranged = 42, state = 5.5, cure = 6.5, revive = 6.5, dot = 40},
	-- Heal a group member below this share of health or action: in a fight, out of one; the medic itself first below
	-- self; anyone else with stims heals itself below selfOther
	healBelow = {fight = 0.75, rest = 0.9, self = 0.5, selfOther = 0.4},
	-- Core3's waits (20 s less a fifth of the speed mod, at least 4 s), plus a margin
	treatmentMarginMs = 600,
	mindCost = {healdamage = 50, healstate = 20, cure = 100, revive = 200, dot = 150},
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
		-- What the combat medic throws (single-target, the best potency): poison then disease on the tank's target
		dotPoison = MED .. "medpack_poison_health_c.iff",
		dotDisease = MED .. "medpack_disease_health_c.iff",
		-- ...and the area versions (Phase 8)
		dotPoisonArea = MED .. "medpack_poison_area_health_c.iff",
		dotDiseaseArea = MED .. "medpack_disease_area_health_c.iff",
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
	spatialRange = 20,       -- a grouped crew bot takes a group human's spoken words (not named) as group talk within this
	spatialHear = 25,        -- ...and the crew member who does the work asked for (a camp, a track), within this
	-- Refused for a lair, camp or building nearby: the ranger walks straight away from it, campSearchStep metres at a
	-- time, and tries at each, up to campSearchSteps times; a camp placed out there waits this long (s) for the leader
	-- to come within campRange
	campSearchStep = 25,
	campSearchSteps = 6,
	campSearchWalk = 30,     -- s to reach a spot before trying it anyway
	campSearchPollMs = 1500, -- between looks at the walk
	campSearchGrace = 180,
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
		-- Phase 8: the entertainer's: music, dancing, stopping, and battle fatigue (which a camp can't heal)
		music = {"play something", "play some music", "play us something", "play a song", "play us a song", "some music",
			"play music", "play a tune", "play us a tune", "play for us", "play for me"},
		dance = {"dance for us", "dance for me", "start dancing", "back to dancing", "go back to dancing", "dance again", "dance please",
			"do a dance", "dance something"},
		call = {"crew come to me", "crew to me", "crew come here", "crew get over here", "i need the crew", "need the crew",
			"crew on me", "crew over here", "crew join me"},
		perfstop = {"stop playing", "stop dancing", "stop the music", "enough music", "stop the dance"},
		fatigue = {"battle fatigue", "fatigue", "shock wound"},
		-- Phase 8: the commando gives up its place for the other human
		makeroom = {"make room", "make some room", "make a slot", "free up a slot", "free a slot", "need a slot", "room for my friend",
			"room for him", "room for her", "room for another", "room for one more"},
		home = {"go home", "head home", "you can go", "dismissed", "call it a day", "go back to the cantina", "leave the group",
			"drop group", "go away", "you're done", "youre done", "that's all for today", "thats all for today"},
		follow = {"follow", "stay with me", "stay close", "on me", "with me", "come on", "let's go", "lets go", "move out",
			"back off", "disengage", "fall back", "come here", "regroup", "keep up", "this way", "let's move",
			"lets move", "hold fire", "cease fire", "stop fighting", "stop attacking", "peace"},
		stay = {"stay", "wait here", "hold here", "hold up", "hold position", "wait for me", "stop here", "hang back",
			"wait up", "sit tight"},
		-- Orders only ("attack my target", "kill it"), not talk about fights. These are matched anywhere, unless a
		-- negation sits right before them ("don't attack it"); a clause that starts with "attack", "kill", "assist",
		-- "get him" or "get em" counts too (attackOrder). Checked before follow ("come on, kill it").
		attack = {"attack my", "attack that", "attack it", "attack him", "attack her", "attack them", "attack this",
			"attack now", "attack please", "attack em", "attack at will", "kill it", "kill that", "kill him", "kill her",
			"kill them", "kill this", "kill my target", "kill the target", "kill em", "take it down", "take him down",
			"take them down", "take that down", "take him out", "take them out", " hit it", " hit him", " hit that",
			" hit my target", "assist me", "assist us", "help me kill", "help me fight", "help me attack", "on my target",
			" engage ", "open fire", "fire at will", "light it up", "light him up", "light them up", "focus my target",
			"focus fire"},
		-- ...a clause that starts with these is an attack order too
		attackStart = {"attack", "kill", "assist", "get him", "get em"},
		-- ...not an attack: calling them off ("hold fire", "stop attacking")
		notAttack = {"hold fire", "cease fire", "back off", "disengage", "fall back", "leave it", "leave him", "leave them",
			"stop attacking", "stop fighting", "peace"},
		join = {"hunt", "join", "invite", "group up", "come along", "come with", "tag along", "team up", "lfg", "wanna go",
			"want to go", "need a hand", "you in", "grp", " inv ", "inv me", "wanna group", "want to group",
			"up for a"},
		camp = {"camp", "let's rest", "lets rest", "need a rest", "take a rest", "take a break", "rest up", "make a fire",
			"set up a fire", "build a fire"},
		track = {"track", "what's around", "whats around", "anything around", "find me", "find us", "find some",
			"where are the", "look for", "any sign", "what's out there", "whats out there", "scout ahead"},
		buff = {"buff", "enhanc"},
		wounds = {"wound"},
		-- Orders only ("harvest them", "loot the bodies"), not talk about loot; a bare "loot" or "harvest" starting the
		-- line counts too (intentFor)
		harvest = {"harvest them", "harvest it", "harvest all", "harvest the", "harvest everything", "harvest those",
			"harvest these", "harvest that", "harvest up", "harvest please", "please harvest", "can you harvest",
			"go harvest", "skin them", "skin it", "skin the", "skin all", "skin everything", "skin those", "skin that",
			"skin these", "skin em", "harvest em", "go skin", "butcher them", "carve them", "harvest hide", "harvest meat",
			"harvest bone", "skin for", "harvest for", "harvest only", "harvest just", "harvest anything", "harvest any ",
			"harvest whatever", "skin anything", "skin whatever"},
		loot = {"loot them", "loot it", "loot all", "loot the", "loot everything", "loot those", "loot these", "loot that",
			"loot em", "loot up", "loot please", "please loot", "can you loot", "go loot", "search the bod",
			"search the corpse", "search them", "search the carcass", "loot bodies", "loot corpses"},
	},
	-- Work that is one crew member's: in group chat, that member answers it
	owners = {camp = "ranger", track = "ranger", buff = "medic", wounds = "medic", harvest = "ranger", makeroom = "commando",
		music = "entertainer", dance = "entertainer", perfstop = "entertainer", fatigue = "entertainer"},
	-- Work any crew member may answer (the first in earshot does)
	anyone = {loot = true, harvest = true, attack = true},
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

-- The squad leader fights with a carbine as the ranger does (Master Carbineer and Marksman: the same specials)
BotCrew.specials.squadleader = BotCrew.specials.ranger

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

-- "123,456" -> {123, 456} (writeStringData keeps only digits and commas safely)
local function oidList(text)
	local out = {}

	for digits in string.gmatch(text or "", "%d+") do
		table.insert(out, tonumber(digits))
	end

	return out
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

		-- (a field that came to nothing leaves its space behind)
		line = line:gsub("%s+$", "")
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

-- Is a human in combat with something alive (a creature, or a lair)? Core3 can leave a player in combat on a corpse
-- that another killed (scanHuman clears those); until then the flag alone doesn't make a fight. The scan's last look (a
-- second old at most) says who is on them; with no recent look, the flag stands.
function BotCrew:humanFighting(m, now)
	if not CreatureObject(m.p):isInCombat() then
		return false
	end

	local base = "crew:human:" .. m.oid

	if now - readData(base .. ":at") > 3 then
		return true
	end

	local foes = oidList(readStringData(base .. ":attackers"))

	table.insert(foes, 1, readData(base .. ":defender"))

	for _, foeOid in ipairs(foes) do
		local pFoe = foeOid ~= 0 and getSceneObject(foeOid) or nil

		-- (a lair is a foe too: only a dead creature isn't, and one out of the zone has no distance)
		if pFoe ~= nil and not (SceneObject(pFoe):isCreatureObject() and CreatureObject(pFoe):isDead()) then
			local dist = BotJobs:distance(m.p, pFoe)

			if dist ~= nil and dist <= self.engageRange then
				return true
			end
		end
	end

	return false
end

function BotCrew:groupFighting(g)
	local now = os.time()

	for _, m in ipairs(g.members) do
		if m.human and self:humanFighting(m, now) or (not m.human and CreatureObject(m.p):isInCombat()) then
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
		-- Master looter first, while it's still the leader: Core3 gave it that with the lead (the crew loots through
		-- botLootCorpse, which doesn't need the rule, but the human is the master looter)
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
	self:lootStart(pBot, oid)
	self:missionLogin(pBot, oid)

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
		"lungeAt", "injuryReady", "stateReady", "cureReady", "rezAt", "rezFor", "rezTries", "rezSaid",
		"offerAt", "peaceAt", "leftAt", "handedAt", "saidBye", "leavingAt", "homeAt", "inviteSeen", "inviteSeenAt",
		"invited", "invitedAt", "specialCount", "forGroup", "leader", "groupedAt", "focus", "chatty", "calloutAt",
		"holdOid", "holdAt", "offOid", "offSince", "rescueAt", "aimed", "moveSince", "moveBlock", "backSince", "backBlock",
		"stepAt", "kneelAt", "bandNear", "bandFar", "bandMax", "bandOk", "lairsAt", "dotReady", "dotOid", "pT", "dT", "pA", "dA",
		"pP", "dP", "pS", "dS", "slCallAt", "slRallyAt", "slVolleyAt", "slFormUpAt", "slAimAt", "slMoraleAt", "retreatSeen",
		"held", "swapAt", "grenadeAt", "coneAt", "perf", "perfAt", "perfNext", "perfStart", "instrument", "flourishes", "calledUntil", "capAt"}) do
		deleteData(ckey(oid, field))
	end

	self:tankDrop(oid)

	for _, field in ipairs({"mode", "order", "heard", "campTried", "lairs", "song", "dance", "flameCone", "flameSingle", "acidCone", "acidSingle"}) do
		deleteStringData(ckey(oid, field))
	end

	self:missionClear(oid)

	if BotDoctor ~= nil then
		BotDoctor:clear(oid)
	end

	self:lootClear(oid)
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

	-- The commando's cones and singles: the best the skills give, for each of its two weapons
	if role == "commando" then
		local function best(...)
			for _, option in ipairs({...}) do
				if creature:hasSkill(option[2]) then
					return option[1]
				end
			end

			return ""
		end

		putString(ckey(oid, "flameCone"), best({"flamecone2", "combat_commando_master"}, {"flamecone1", "combat_commando_thrownweapon_02"}))
		putString(ckey(oid, "flameSingle"), best({"flamesingle2", "combat_commando_thrownweapon_04"}, {"flamesingle1", "combat_commando_thrownweapon_01"}))
		putString(ckey(oid, "acidCone"), best({"fireacidcone2", "combat_commando_master"}, {"fireacidcone1", "combat_commando_support_02"}))
		putString(ckey(oid, "acidSingle"), best({"fireacidsingle2", "combat_commando_support_04"}, {"fireacidsingle1", "combat_commando_support_01"}))
	end

	table.sort(can)
	putString(ckey(oid, "specialsList"), table.concat(list, ","))
	putString(ckey(oid, "can"), "," .. table.concat(can, ",") .. ",")
end

-- Packs for what it can do (stims, ranged stims, state, cure and revive packs, the poison and disease packs it throws; a
-- doctor's enhance and wound packs)
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

	if self:can(oid, "poisonPack") then
		botStockPack(pBot, self.packs.dotPoison, uses, self:setting("dotPower"), self:setting("dotDuration"),
			self:setting("dotPotency"), self:setting("dotRange"))
	end

	if self:can(oid, "diseasePack") then
		botStockPack(pBot, self.packs.dotDisease, uses, self:setting("dotPower"), self:setting("dotDuration"),
			self:setting("dotPotency"), self:setting("dotRange"))
	end

	-- The area packs (the template's own area)
	if self:can(oid, "poisonPack") then
		botStockPack(pBot, self.packs.dotPoisonArea, uses, self:setting("dotPower"), self:setting("dotDuration"),
			self:setting("dotPotency"), self:setting("dotRange"))
	end

	if self:can(oid, "diseasePack") then
		botStockPack(pBot, self.packs.dotDiseaseArea, uses, self:setting("dotPower"), self:setting("dotDuration"),
			self:setting("dotPotency"), self:setting("dotRange"))
	end

	if self:can(oid, "enhance") and BotDoctor ~= nil then
		BotDoctor:restock(pBot)
	end

	-- The commando's grenades (a thrown one is used up)
	if self:role(oid) == "commando" and self:can(oid, "grenade") then
		bot("botStockItem", pBot, self.grenade, self.grenadeStock)
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

	deleteData(ckey(oid, "held"))
	self:readBand(pBot, oid)
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

	if self:role(oid) == "entertainer" and readData(ckey(oid, "inCamp")) ~= 1 then
		self:perfPistol(pBot, oid)
	end

	if mode == "leaving" and now - readData(ckey(oid, "leavingAt")) > 30 then
		self:goHome(pBot, tostring(readData(key(oid, "gen"))))
	elseif mode == "walkingHome" and now - readData(ckey(oid, "homeAt")) > self.walkHomeTimeout then
		self:teleportHome(pBot, oid)
	elseif mode == "home" and not creature:isGrouped() and not creature:isInCombat() then
		self:idle(pBot, oid, now)
	elseif mode == "called" and not creature:isGrouped() and not creature:isInCombat() and now > readData(ckey(oid, "calledUntil")) then
		-- Called and nobody invited it: back to the station
		print("BotJobs: " .. self:name(oid) .. " wasn't invited, going home")
		self:leaveForHome(pBot, oid, now)
	end

	-- Asked for its goods by tell, and the player has come near
	if not creature:isGrouped() and readData(ckey(oid, "wantBy")) ~= 0 then
		self:lootWantTick(pBot, oid, now)
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
	self:missionWatch(pBot, oid, now)

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

		-- The commando gives its place up when the group is full and another human is waiting outside it (however the group
		-- came to be: the invite check only sees the order they came in)
		if self:role(oid) == "commando" and self:overCap(pBot, oid, g, pLeader, now) then
			return self.groupMs
		end

		self:scanHumans(g, oid)
		self:missionWatchHumans(g)
		BotCrewSwoop:tick(pBot, oid, pLeader, now, g)
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

	-- The ranger's rescue is a command, not a shot: it can go while the ranger holds fire or walks
	if g ~= nil and role == "ranger" and ownFight == 0 and CreatureObject(pBot):getQueueSize() == 0 and
		self:can(oid, "rescue") and self:rescueTurn(pBot, oid, g, now) then
		return self.fightMs
	end

	-- The squad leader calls the fight (rally, volley, form up, steady aim, boost morale, retreat)
	if g ~= nil and pLeader ~= nil and role == "squadleader" and ownFight == 0 and self:slTurn(pBot, oid, g, pLeader, now) then
		return self.fightMs
	end

	-- A retreat in force: break off and follow the leader
	if g ~= nil and pLeader ~= nil and ownFight == 0 and self:retreatStep(pBot, oid, g, pLeader, now) then
		return self.fightMs
	end

	local pTarget, held = self:pickTarget(pBot, oid, g, pLeader, now)

	if pTarget == nil and held then
		-- Holding fire on a fresh creature: the bot stays where it is (kneeling), the fight isn't over
		return self.fightMs
	end

	if pTarget ~= nil then
		self:fight(pBot, oid, pTarget, pLeader, g, now)

		if pLeader ~= nil then
			-- When the fight ends the crew looks around for corpses (crew_loot.lua)
			put(gkey(SceneObject(pLeader):getObjectID(), "fightAt"), now)
		end

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

-- The humans online (oids): real players, and in the dev tests the bots standing in for one (devLead lists them)
function BotCrew:humansOnline()
	local out, seen = {}, {}

	for _, humanOid in ipairs(bot("botHumansOnline") or {}) do
		if not seen[humanOid] then
			seen[humanOid] = true
			table.insert(out, humanOid)
		end
	end

	for _, humanOid in ipairs(oidList(readStringData("crew:pretendList"))) do
		local pHuman = getSceneObject(humanOid)

		if not seen[humanOid] and pHuman ~= nil and SceneObject(pHuman):getZoneName() ~= "" then
			seen[humanOid] = true
			table.insert(out, humanOid)
		end
	end

	return out
end

-- The group cap (Phase 8): only the commando holds a place for someone. Would it, joining this human's group, leave no
-- slot for another human who is online and not in the group? (the second one to log in can always be invited)
function BotCrew:noRoom(oid, pInviter)
	if self:role(oid) ~= "commando" then
		return false
	end

	-- (the inviter's group through botGroupInfo: getGroupSize and getGroupMember would lock the inviter, a player, from this bot's event)
	local size, inGroup = 1, {[SceneObject(pInviter):getObjectID()] = true}
	local info = bot("botGroupInfo", pInviter)

	if info ~= nil then
		size = math.max(1, #info.members)

		for _, memberOid in ipairs(info.members) do
			inGroup[memberOid] = true
		end
	end

	local waiting = 0

	for _, humanOid in ipairs(self:humansOnline()) do
		if not inGroup[humanOid] then
			waiting = waiting + 1
		end
	end

	return size + 1 + waiting > self.groupCap
end

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

	if self:noRoom(oid, pInviter) then
		print("BotJobs: " .. self:name(oid) .. " sits out " .. self:firstName(pInviter) .. "'s group: no slot would be left for the other player")
		botEnqueue(pBot, "decline", 0, "")
		self:sitOut(pBot, oid, pInviter, "spatial")
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
	deleteData(ckey(oid, "focus"))
	deleteData(ckey(oid, "followAt"))
	self:standUp(pBot, oid)
	print("BotJobs: " .. self:name(oid) .. " is in " .. self:firstName(pLeader) .. "'s group (" .. #g.members .. ")")
	self:groupSay(pBot, oid, "joined", self:firstName(pLeader))
	self:lootRegrouped(pBot, oid, pLeader, now)
end

-- Out of the group (dismissed, disbanded, or it left): say bye if the leader is near, and go home
function BotCrew:leftGroup(pBot, oid, now)
	print("BotJobs: " .. self:name(oid) .. " is out of the group")
	self:stopMoving(pBot)
	self:standUp(pBot, oid)
	deleteData(ckey(oid, "focus"))

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

	-- The group broke up (its leader is on their own): the hunt's harvest choice goes with it
	local leaderOid = readData(ckey(oid, "leader"))
	local pGone = leaderOid ~= 0 and getSceneObject(leaderOid) or nil

	if leaderOid ~= 0 and (pGone == nil or not CreatureObject(pGone):isGrouped()) then
		self:harvestClear(leaderOid)
	end

	self:lootBeforeHome(pBot, oid, now)
	self:leaveForHome(pBot, oid, now)
end

function BotCrew:leaveForHome(pBot, oid, now)
	if self:role(oid) == "entertainer" then
		self:perfStop(pBot, oid, true)
		deleteData(ckey(oid, "perf"))
	end

	self:missionLeft(pBot, oid)
	BotCrewSwoop:release(pBot, oid)
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

	-- Handing the loot over first (its chain sends it home when it ends)
	if self:lootHolding(oid) then
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

-- What this bot is fighting, and what attacks it, for its crew mates. A creature that is attacked has no defender of
-- its own until it hits back (Core3's startCombat gives only the attacker one), so the main defender alone misses
-- what bites a medic who is busy healing: botAttackers reads the threat map for that.
function BotCrew:noteDefender(pBot, oid, now)
	local defender = 0
	local attackers = ""

	if CreatureObject(pBot):isInCombat() then
		local pDefender = CreatureObject(pBot):getMainDefender()

		if pDefender ~= nil then
			defender = SceneObject(pDefender):getObjectID()
		end

		attackers = table.concat(bot("botAttackers", pBot) or {}, ",")
	end

	put(ckey(oid, "defender"), defender)
	put(ckey(oid, "defenderAt"), now)
	writeStringData(ckey(oid, "attackers"), attackers)
end

-- The crew reads what the players in the group are fighting and what attacks them, in an event on each of them. Any
-- crew member may do it (the first one could be down or busy); a human is read once a second at most. A human on a
-- swoop is read through botMountAttacker.
function BotCrew:scanHumans(g, oid)
	local now = os.time()

	for _, m in ipairs(g.humans) do
		local base = "crew:human:" .. m.oid

		if now - readData(base .. ":scanAt") >= 1 then
			put(base .. ":scanAt", now)

			-- Riding: creatures attack the swoop, not the rider, who is never "in combat" (the crew's riders get off for it)
			local mountAttacker = bot("botMountAttacker", m.p) or 0

			if mountAttacker ~= 0 then
				put(base .. ":defender", mountAttacker)
				put(base .. ":pvp", 0)
				writeStringData(base .. ":attackers", tostring(mountAttacker))
				put(base .. ":at", now)
			elseif CreatureObject(m.p):isInCombat() then
				createEvent(1, "BotCrew", "scanHuman", m.p, "")
			elseif readData(base .. ":defender") ~= 0 or readStringData(base .. ":attackers") ~= "" then
				put(base .. ":defender", 0)
				writeStringData(base .. ":attackers", "")
			end
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
	local attackers = ""
	local pvp = 0

	-- Left in combat on corpses something else killed (Core3 clears them only from the killer's list): clear them
	local dropped = bot("botDropDeadDefenders", pHuman) or 0

	if dropped > 0 then
		print("BotJobs: " .. self:firstName(pHuman) .. " was left in combat on " .. dropped .. " dead creature(s): cleared")
	end

	if CreatureObject(pHuman):isInCombat() then
		local pDefender = CreatureObject(pHuman):getMainDefender()

		if pDefender ~= nil then
			defender = SceneObject(pDefender):getObjectID()
			pvp = SceneObject(pDefender):isPlayerCreature() and 1 or 0
		end

		attackers = table.concat(bot("botAttackers", pHuman) or {}, ",")
	end

	put("crew:human:" .. humanOid .. ":defender", defender)
	put("crew:human:" .. humanOid .. ":pvp", pvp)
	writeStringData("crew:human:" .. humanOid .. ":attackers", attackers)
	put("crew:human:" .. humanOid .. ":at", os.time())
	self:lootNoteHuman(humanOid, defender)
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

-- What to fight: its own provoked fight or duel; what it was told to attack; the leader's target while the leader
-- fights; else the current one while still fighting it; else whatever attacks this bot, a crew mate or a player in the
-- group. Ungrouped, only its own fight.
function BotCrew:pickTarget(pBot, oid, g, pLeader, now)
	local pPick, free = self:pickBase(pBot, oid, g, pLeader, now)

	-- With a tank that can hold creatures, whatever the pick is, the others hold fire on it until it is on the tank (second
	-- result "held": the fight goes on, the bot just doesn't open)
	if pPick == nil or free or g == nil then
		return pPick
	end

	local tank = self:tankFor(oid, g)

	if tank ~= nil and self:heldFire(pBot, oid, tank, pPick, g, now) then
		return nil, true
	end

	return pPick
end

-- The pick before the hold; its second result is true for a pick the hold never applies to (its own provoked fight or
-- duel, an order to attack)
function BotCrew:pickBase(pBot, oid, g, pLeader, now)
	-- A provoked fight or a duel of its own (fight.lua) comes first: the crew fights those properly
	local opponent = BotFight ~= nil and BotFight.fighting ~= nil and BotFight:fighting(oid) or 0

	if opponent ~= 0 then
		local pOpponent = self:validTarget(pBot, getSceneObject(opponent), g, "opponent")

		if pOpponent ~= nil then
			return pOpponent, true
		end
	end

	if now < readData(ckey(oid, "holdUntil")) then
		return nil
	end

	-- Just retreated: nobody picks the fight up again at once
	if pLeader ~= nil and now < readData(gkey(SceneObject(pLeader):getObjectID(), "retreatHold")) then
		return nil
	end

	-- Told to attack something ("attack my target"): that, until it's dead or gone
	local focus = readData(ckey(oid, "focus"))

	if focus ~= 0 then
		local pFocus = self:validTarget(pBot, getSceneObject(focus), g, false)

		if pFocus ~= nil then
			return pFocus, true
		end

		deleteData(ckey(oid, "focus"))
	end

	local own = readData(ckey(oid, "defender"))
	local pOwn = own ~= 0 and self:validTarget(pBot, getSceneObject(own), g, true) or nil
	-- Whatever attacks this bot, in its threat map, even when it isn't fighting back (a medic busy healing)
	local pOwnAttacker = self:nearestAttacker(pBot, g, readStringData(ckey(oid, "attackers")), 0)

	if g == nil then
		return pOwn or pOwnAttacker
	end

	-- With a tank that can hold creatures, the others fight what it fights (adds wait their turn), except a creature that
	-- is on this bot now, which is fought back at once
	local tank = self:tankFor(oid, g)

	if tank ~= nil then
		local pOnMe = self:creatureOnMe(pBot, oid, g)

		if pOnMe ~= nil then
			return pOnMe
		end

		local pTankTarget = self:validTarget(pBot, getSceneObject(readData(ckey(tank.oid, "target"))), g, false)

		if pTankTarget ~= nil then
			return pTankTarget
		end
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

	if pOwnAttacker ~= nil then
		return pOwnAttacker
	end

	-- A crew mate's or a player's attacker, seen in the last few seconds: the group defends its own, without waiting
	-- for the leader to strike first
	for _, m in ipairs(g.crew) do
		if m.oid ~= oid and now - readData(ckey(m.oid, "defenderAt")) <= self.attackerFresh then
			local pTarget = self:nearestAttacker(pBot, g, readStringData(ckey(m.oid, "attackers")), readData(ckey(m.oid, "defender")))

			if pTarget ~= nil then
				return pTarget
			end
		end
	end

	for _, m in ipairs(g.humans) do
		if now - readData("crew:human:" .. m.oid .. ":at") <= self.attackerFresh then
			local pTarget = self:nearestAttacker(pBot, g, readStringData("crew:human:" .. m.oid .. ":attackers"),
				readData("crew:human:" .. m.oid .. ":defender"))

			if pTarget ~= nil then
				return pTarget
			end
		end
	end

	return pOwn
end

-- Does the group need this bot's hand? A crew mate or a human of the group has something to fight (the signals
-- pickTarget reads), or it was told to attack something. A rider gets off for it (crew_swoop.lua).
function BotCrew:helpWanted(pBot, oid, g, now)
	if g == nil then
		return false
	end

	local focus = readData(ckey(oid, "focus"))

	if focus ~= 0 and self:validTarget(pBot, getSceneObject(focus), g, false) ~= nil then
		return true
	end

	for _, m in ipairs(g.crew) do
		if m.oid ~= oid and now - readData(ckey(m.oid, "defenderAt")) <= self.attackerFresh and
			self:nearestAttacker(pBot, g, readStringData(ckey(m.oid, "attackers")), readData(ckey(m.oid, "defender"))) ~= nil then
			return true
		end
	end

	for _, m in ipairs(g.humans) do
		if now - readData("crew:human:" .. m.oid .. ":at") <= self.attackerFresh and
			self:nearestAttacker(pBot, g, readStringData("crew:human:" .. m.oid .. ":attackers"),
				readData("crew:human:" .. m.oid .. ":defender")) ~= nil then
			return true
		end
	end

	return false
end

-- The nearest creature this bot may attack among an attackers list ("oid,oid") and one more oid (a main defender)
function BotCrew:nearestAttacker(pBot, g, text, extra)
	local best, bestDist = nil, nil
	local list = oidList(text)

	if extra ~= nil and extra ~= 0 then
		table.insert(list, 1, extra)
	end

	for _, attackerOid in ipairs(list) do
		local pTarget = self:validTarget(pBot, getSceneObject(attackerOid), g, false)

		if pTarget ~= nil then
			local dist = BotJobs:distance(pBot, pTarget) or 999

			if best == nil or dist < bestDist then
				best, bestDist = pTarget, dist
			end
		end
	end

	return best
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

-- Tactics (Phase 7c, specs/2026-10-24-crew-tactics/)

-- The tank's per-creature notes (under its key): E engaged (when it first took the creature as its target), T last
-- taunt, I last intimidate, W last warcry, G said "Got it". The creatures it keeps notes for are listed, so a fight's
-- end can drop them.
local function tkey(tankOid, coid, field)
	return ckey(tankOid, "t" .. field .. coid)
end

local TANK_NOTES = {"E", "T", "I", "W", "G"}
local TANK_LIST = 12

function BotCrew:tankNote(oid, coid)
	local list = oidList(readStringData(ckey(oid, "tcList")))

	for _, listed in ipairs(list) do
		if listed == coid then
			return
		end
	end

	table.insert(list, coid)

	while #list > TANK_LIST do
		self:tankDropCreature(oid, table.remove(list, 1))
	end

	putString(ckey(oid, "tcList"), table.concat(list, ","))
end

function BotCrew:tankDropCreature(oid, coid)
	for _, field in ipairs(TANK_NOTES) do
		deleteData(tkey(oid, coid, field))
	end
end

function BotCrew:tankDrop(oid)
	for _, coid in ipairs(oidList(readStringData(ckey(oid, "tcList")))) do
		self:tankDropCreature(oid, coid)
	end

	deleteStringData(ckey(oid, "tcList"))
end

-- The group member that can hold creatures: a tank (not this bot) in the group, standing, with taunt and not told to
-- stay. nil without one: then the crew fights as it did before the tactics.
function BotCrew:tankFor(oid, g)
	for _, m in ipairs(g.crew) do
		if m.job == "tank" and m.oid ~= oid then
			local c = CreatureObject(m.p)

			-- (not one in a duel or provoked fight of its own, nor away on a mission errand)
			if not c:isDead() and not c:isIncapacitated() and readStringData(ckey(m.oid, "order")) ~= "stay" and
				self:can(m.oid, "taunt") and (BotFight == nil or BotFight.fighting == nil or BotFight:fighting(m.oid) == 0) and
				not self:missionBusy(m.oid, os.time()) then
				return m
			end
		end
	end

	return nil
end

-- Hold fire on a creature that isn't on the tank (on nobody yet, or on the human who pulled it): until it is on the
-- tank, or holdFor seconds after the tank engaged it. If the tank never does, holdMax seconds after this bot first held
-- for it. Never for a creature on this bot (self-defence).
function BotCrew:heldFire(pBot, oid, tank, pCreature, g, now)
	local coid = SceneObject(pCreature):getObjectID()
	local pOn = CreatureObject(pCreature):getMainDefender()

	-- (a creature this bot has opened on already isn't held for again)
	if readData(ckey(oid, "target")) == coid then
		return false
	end

	if pOn ~= nil then
		local onOid = SceneObject(pOn):getObjectID()

		if onOid == tank.oid or onOid == oid then
			return false
		end
	end

	local tankDist = BotJobs:distance(tank.p, pCreature)

	if tankDist == nil or tankDist > self.engageRange then
		return false
	end

	if readData(ckey(oid, "holdOid")) ~= coid then
		put(ckey(oid, "holdOid"), coid)
		put(ckey(oid, "holdAt"), now)
		print("BotJobs: " .. self:name(oid) .. " holds fire on " .. SceneObject(pCreature):getDisplayedName() .. " until it is on " ..
			self:name(tank.oid))
	end

	local engaged = readData(tkey(tank.oid, coid, "E"))
	local releaseAt = engaged ~= 0 and engaged + self.holdFor or readData(ckey(oid, "holdAt")) + self.holdMax

	return now < releaseAt
end

-- Every creature attacking a member of the group, as the members' last looks recorded them (noteDefender, scanHuman),
-- with pFirst (the fight's target) too; nearest to this bot first
function BotCrew:groupCreatures(pBot, g, now, pFirst)
	local seen, list = {}, {}

	local function add(coid)
		if coid ~= 0 and not seen[coid] then
			local p = self:validTarget(pBot, getSceneObject(coid), g, false)

			if p ~= nil then
				seen[coid] = true
				table.insert(list, {p = p, oid = coid, dist = BotJobs:distance(pBot, p) or 999})
			end
		end
	end

	if pFirst ~= nil then
		add(SceneObject(pFirst):getObjectID())
	end

	-- (the creature a member fights counts too: one that took the shot is on that member before it has hit back, and
	-- the attackers lists only show it from then on)
	for _, m in ipairs(g.crew) do
		if now - readData(ckey(m.oid, "defenderAt")) <= self.attackerFresh then
			add(readData(ckey(m.oid, "defender")))

			for _, coid in ipairs(oidList(readStringData(ckey(m.oid, "attackers")))) do
				add(coid)
			end
		end
	end

	for _, m in ipairs(g.humans) do
		if now - readData("crew:human:" .. m.oid .. ":at") <= self.attackerFresh then
			add(readData("crew:human:" .. m.oid .. ":defender"))

			for _, coid in ipairs(oidList(readStringData("crew:human:" .. m.oid .. ":attackers"))) do
				add(coid)
			end
		end
	end

	table.sort(list, function(a, b) return a.dist < b.dist end)

	return list
end

-- A short group-chat line as a player calls one: only in a chatty fight (rolled when the fight starts), and a bot
-- says at most one every calloutGap seconds
function BotCrew:callout(pBot, oid, kind, name, now)
	if readData(ckey(oid, "chatty")) ~= 1 or now - readData(ckey(oid, "calloutAt")) < self.calloutGap then
		return false
	end

	put(ckey(oid, "calloutAt"), now)
	self:groupSay(pBot, oid, kind, name)

	return true
end

-- Command effect on a creature, once per `gap` seconds: true when it was queued
function BotCrew:tankCommand(pBot, oid, c, field, command, gap, now)
	if now - readData(tkey(oid, c.oid, field)) < gap then
		return false
	end

	botEnqueue(pBot, command, c.oid, "")
	self:tankNote(oid, c.oid)
	put(tkey(oid, c.oid, field), now)
	print("BotJobs: " .. self:name(oid) .. " (tank) " .. command .. " " .. SceneObject(c.p):getDisplayedName() .. " " .. c.oid ..
		", " .. string.format("%.0f", c.dist) .. " m")

	return true
end

-- The tank's turn with its queue empty: the creatures attacking the group, nearest first, within taunt range. One
-- that isn't on the tank is taunted when its lockout is over (Core3's, from its threat map: a taunt inside it does
-- nothing but add aggro), else slowed with an intimidate or a warcry. One command per step; true if it queued one.
function BotCrew:tankTurn(pBot, oid, pTarget, g, now)
	local targetOid = pTarget ~= nil and SceneObject(pTarget):getObjectID() or 0
	local list = self:groupCreatures(pBot, g, now, pTarget)

	for i = 1, math.min(#list, self.tauntLook) do
		local c = list[i]
		local th = bot("botThreatOn", pBot, c.p)

		if th ~= nil then
			if th.target == oid then
				if readData(tkey(oid, c.oid, "T")) ~= 0 and readData(tkey(oid, c.oid, "G")) == 0 then
					put(tkey(oid, c.oid, "G"), 1)
					self:callout(pBot, oid, "got", nil, now)
				end
			elseif c.dist <= self.tauntRange and (th.target ~= 0 or c.oid == targetOid) then
				if self:tankAct(pBot, oid, c, th, g, now) then
					return true
				end
			end
		end
	end

	return false
end

-- One creature that isn't on the tank (or is on nobody and is the fight's target)
function BotCrew:tankAct(pBot, oid, c, th, g, now)
	if th.tauntable and th.lockoutMs <= 0 and not th.taunted then
		if self:tankCommand(pBot, oid, c, "T", "taunt", self.tauntGap, now) then
			put(tkey(oid, c.oid, "G"), 0)

			local victim = th.target ~= 0 and g.byOid[th.target] or nil

			if victim ~= nil and victim.oid ~= oid then
				self:callout(pBot, oid, "addGrab", self:firstName(victim.p), now)
			end

			return true
		end

		return false
	end

	-- Not tauntable yet: its taunt is in force (the creature should come to the tank) or the lockout runs on
	if th.taunted and th.tauntable then
		return false
	end

	local victim = th.target ~= 0 and g.byOid[th.target] or nil

	if victim == nil or victim.oid == oid then
		return false
	end

	self:callout(pBot, oid, "tauntDown", nil, now)

	if self:can(oid, "intimidate") and c.dist <= self.intimidateRange and
		self:tankCommand(pBot, oid, c, "I", "intimidate1", self.debuffGap, now) then
		return true
	end

	if self:can(oid, "warcry") and c.dist <= self.intimidateRange and
		self:tankCommand(pBot, oid, c, "W", "warcry1", self.debuffGap, now) then
		return true
	end

	return false
end

-- The ranger's rescue (Core3's: the creature's main defender must be in the group, TAUNTED for 5 s; it shares the
-- taunt's lockout, so it works only where a taunt would). It takes a creature on a group member that the tank hasn't
-- taken after rescueAfter seconds, or any such creature when there is no tank to hold it.
function BotCrew:rescueTurn(pBot, oid, g, now)
	if now - readData(ckey(oid, "rescueAt")) < self.tauntGap then
		return false
	end

	local tank = self:tankFor(oid, g)

	for _, c in ipairs(self:groupCreatures(pBot, g, now, nil)) do
		if c.dist <= self.rescueRange then
			local th = bot("botThreatOn", pBot, c.p)

			if th ~= nil and th.target ~= 0 and th.target ~= oid and (tank == nil or th.target ~= tank.oid) and
				g.byOid[th.target] ~= nil and th.lockoutMs <= 0 and not th.taunted then
				if readData(ckey(oid, "offOid")) ~= c.oid then
					put(ckey(oid, "offOid"), c.oid)
					put(ckey(oid, "offSince"), now)
				end

				if tank == nil or now - readData(ckey(oid, "offSince")) >= self.rescueAfter then
					botEnqueue(pBot, "rescue", c.oid, "")
					print("BotJobs: " .. self:name(oid) .. " (ranger) rescue " .. SceneObject(c.p):getDisplayedName() .. " " .. c.oid ..
						", on " .. tostring(self:firstName(g.byOid[th.target].p)))
					put(ckey(oid, "rescueAt"), now)
					put(ckey(oid, "offSince"), now)

					return true
				end

				return false
			end
		end
	end

	return false
end


-- Calling the crew (Phase 8). The call comes in a tell to any crew bot, or in group chat; whichever bot heard it works out who
-- is free and sets each one's arrival. The leap itself is BotMover's callTo (any planet, from any distance).

function BotCrew:callWanted(text)
	return hasAny(wordsOf(text), self.words.call)
end

-- Is this crew bot free to come to the caller? "free" (at home, called, or on its way home), "with" (in the caller's group),
-- "busy" (in someone else's group, or fighting, or down) -- and the leader's name for "busy" when it has one
function BotCrew:callState(pBot, pCaller)
	local creature = CreatureObject(pBot)

	if creature:isDead() or creature:isIncapacitated() or creature:isInCombat() then
		return "busy", nil
	end

	if not creature:isGrouped() then
		return "free", nil
	end

	local callerGroup = CreatureObject(pCaller):getGroupID()

	if callerGroup ~= 0 and creature:getGroupID() == callerGroup then
		return "with", nil
	end

	local info = bot("botGroupInfo", pBot)
	local pLeader = info ~= nil and getSceneObject(info.leader) or nil

	return "busy", pLeader ~= nil and self:firstName(pLeader) or nil
end

function BotCrew:crewCall(pBot, oid, pCaller, channel)
	local callerOid = SceneObject(pCaller):getObjectID()
	local name = self:firstName(pCaller)
	local coming = 0

	for _, entry in ipairs(bot("botList") or {}) do
		if entry.online and CREW[entry.job] and entry.oid ~= 0 then
			local pOther = getSceneObject(entry.oid)

			if pOther ~= nil then
				local state, leaderName = self:callState(pOther, pCaller)

				if state == "busy" then
					-- (the bot that was asked says why; the rest keep quiet)
					if entry.oid == oid and leaderName ~= nil then
						self:say(pBot, oid, callerOid, channel == "group" and "group" or "tell", "callBusy", name, {leader = leaderName})
					end
				else
					local delay = between(self.callDelay) * 1000

					createEvent(delay, "BotCrew", "callArrive", pOther, packArgs(readData(key(entry.oid, "gen")), callerOid, state))
					coming = coming + 1
				end
			end
		end
	end

	print("BotJobs: " .. self:name(oid) .. " hears " .. name .. " call the crew: " .. coming .. " coming")

	if coming > 0 then
		self:say(pBot, oid, callerOid, channel == "group" and "group" or "tell", "callOn", name)
	end
end

function BotCrew:callArrive(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local pCaller = getSceneObject(num(a[2]) or 0)
	local now = os.time()

	-- (a minute later it may have gone off with someone else, or died)
	if pCaller == nil or SceneObject(pCaller):getZoneName() == "" or self:callState(pBot, pCaller) == "busy" then
		return
	end

	local state = self:callState(pBot, pCaller)
	local dist = BotJobs:distance(pBot, pCaller)

	self:standUp(pBot, oid)

	if dist == nil or dist > self.callNear then
		if not bot("botCallTo", pBot, pCaller) then
			print("BotJobs: " .. self:name(oid) .. " couldn't be called to " .. self:firstName(pCaller))
			return
		end

		print("BotJobs: " .. self:name(oid) .. " arrives beside " .. self:firstName(pCaller))
		-- (it may have been sitting where it stood)
		botEnqueue(pBot, "stand", 0, "")
	end

	if state == "with" then
		deleteData(ckey(oid, "followAt"))
		self:ensureFollow(pBot, oid, pCaller, now)
		return
	end

	-- Not grouped: it waits for an invite; the first to arrive sends one (a bot never leads), the rest ask for one
	putString(ckey(oid, "mode"), "called")
	putString(ckey(oid, "order"), "follow")
	put(ckey(oid, "calledUntil"), now + self.calledWait)
	self:stopMoving(pBot)

	local callerOid = SceneObject(pCaller):getObjectID()
	local marker = "crew:call:" .. callerOid

	if CreatureObject(pCaller):isGrouped() or (now < readData(marker .. ":until") and readData(marker .. ":bot") ~= oid) then
		local kind = (self:role(oid) == "commando" and self:noRoom(oid, pCaller)) and "sitOut" or "askInvite"

		self:say(pBot, oid, callerOid, "spatial", kind, self:firstName(pCaller))
	else
		put(marker .. ":until", now + self.callInviteWindow)
		put(marker .. ":bot", oid)
		self:join(pBot, oid, pCaller, "spatial", nil)
	end
end

-- The entertainer (Phase 8). In a camp it dances for the group (Core3 heals mind wounds of the patrons watching, and the
-- group gets the dancer's mind buff, which lands when they stop watching after a minute); "play something" has it play its
-- instrument instead (focus and willpower), "dance" brings the dance back. One performance at a time, as Core3 allows.
-- Battle fatigue isn't healed in a camp (Core3 needs a cantina or a theater for it).

-- The instrument it carries (roster carry)
function BotCrew:instrumentOf(oid)
	local entry = BotJobs:entry(readStringData(key(oid, "first"))) or {}

	for _, template in ipairs(entry.carry or {}) do
		if template:find("/instrument/", 1, true) ~= nil then
			return template
		end
	end

	return nil
end

-- Keeps its action up while it performs (a performance costs some every loop), as BotDancer does
function BotCrew:perfTopUp(pBot)
	local creature = CreatureObject(pBot)
	local full = creature:getMaxHAM(ACTION) - (botGetWounds(pBot, ACTION) or 0)

	if full > 0 and creature:getHAM(ACTION) * 100 < full * self.perfActionFloor then
		creature:setHAM(ACTION, full)
	end
end

-- 1 dance, 2 music: what it is asked for (dancing, until asked otherwise)
function BotCrew:perform(pBot, oid, now)
	local creature = CreatureObject(pBot)
	local want = readData(ckey(oid, "perf"))

	if want == 0 then
		want = 1
	end

	self:standUp(pBot, oid)
	self:perfTopUp(pBot)

	if now - readData(ckey(oid, "perfAt")) < 3 then
		return
	end

	if want == 1 then
		if creature:isPlayingMusic() then
			put(ckey(oid, "perfAt"), now)
			botEnqueue(pBot, "stopmusic", 0, "")
			return
		end

		if not creature:isDancing() then
			if now - readData(ckey(oid, "perfStart")) >= self.perfRestart then
				put(ckey(oid, "perfStart"), now)
				put(ckey(oid, "perfAt"), now)
				putString(ckey(oid, "dance"), BotDancer ~= nil and BotDancer:pickDance("") or "exotic4")
				botEnqueue(pBot, "startdance", 0, readStringData(ckey(oid, "dance")))
				print("BotJobs: " .. self:name(oid) .. " dances for the camp")
			end

			return
		end
	else
		if creature:isDancing() then
			put(ckey(oid, "perfAt"), now)
			botEnqueue(pBot, "stopdance", 0, "")
			return
		end

		-- The instrument in hand (the pistol goes to the pack), then the song
		if readData(ckey(oid, "instrument")) ~= 1 then
			local template = self:instrumentOf(oid)

			if template == nil then
				put(ckey(oid, "perf"), 1)
				return
			end

			put(ckey(oid, "instrument"), 1)
			put(ckey(oid, "perfAt"), now)
			bot("botEquip", pBot, template)
			return
		end

		if not creature:isPlayingMusic() then
			if now - readData(ckey(oid, "perfStart")) >= self.perfRestart then
				put(ckey(oid, "perfStart"), now)
				put(ckey(oid, "perfAt"), now)
				putString(ckey(oid, "song"), BotMusician ~= nil and BotMusician:pickSong("") or "virtuoso")
				botEnqueue(pBot, "startmusic", 0, readStringData(ckey(oid, "song")))
				print("BotJobs: " .. self:name(oid) .. " plays for the camp")
			end

			return
		end
	end

	-- Performing: a flourish now and then builds the group's buff
	if now >= readData(ckey(oid, "perfNext")) then
		if readData(ckey(oid, "perfNext")) ~= 0 then
			botEnqueue(pBot, "flourish", 0, tostring(getRandomNumber(1, 8)))
			put(ckey(oid, "flourishes"), readData(ckey(oid, "flourishes")) + 1)
		end

		put(ckey(oid, "perfNext"), now + between(self.perfFlourish))
	end
end

-- Stop performing; with `pistol`, and an instrument in hand, take the pistol back
function BotCrew:perfStop(pBot, oid, pistol)
	local creature = CreatureObject(pBot)

	if creature:isDancing() then
		botEnqueue(pBot, "stopdance", 0, "")
	end

	if creature:isPlayingMusic() then
		botEnqueue(pBot, "stopmusic", 0, "")
	end

	deleteData(ckey(oid, "perfNext"))
	deleteData(ckey(oid, "perfStart"))

	if pistol then
		self:perfPistol(pBot, oid)
	end
end

-- The pistol back in hand once the performance is over (a song has a 15 s outro in which Core3 still counts it as playing); until
-- then the flag stays, and the next steps and the tick ask again
function BotCrew:perfPistol(pBot, oid)
	if readData(ckey(oid, "instrument")) ~= 1 then
		return
	end

	local creature = CreatureObject(pBot)

	if creature:isDancing() or creature:isPlayingMusic() then
		return
	end

	deleteData(ckey(oid, "instrument"))
	self:equip(pBot, oid)
	print("BotJobs: " .. self:name(oid) .. " takes its pistol back")
end

-- The nearest town's name, for "the closest cantina"
function BotCrew:nearestTown(pBot)
	local x, y = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY()
	local best, bestDist

	for _, town in ipairs(self.towns[SceneObject(pBot):getZoneName()] or {}) do
		local d = math.sqrt((x - town[2]) ^ 2 + (y - town[3]) ^ 2)

		if bestDist == nil or d < bestDist then
			best, bestDist = town[1], d
		end
	end

	return best or "the nearest city"
end

-- What the entertainer was asked (spoken to it, by tell or in group chat), answered here without the model. true if it was
-- one of these.
function BotCrew:entertainerAsk(pBot, oid, pSpeaker, channel, text)
	local t = wordsOf(text)
	local name = self:firstName(pSpeaker)
	local speakerOid = SceneObject(pSpeaker):getObjectID()
	local g = self:group(pBot)
	local member = g ~= nil and g.byOid[speakerOid] or nil

	if hasAny(t, self.words.fatigue) then
		if (CreatureObject(pBot):getSkillMod("private_med_battle_fatigue") or 0) > 0 then
			self:say(pBot, oid, speakerOid, channel, "fatigueHere", name)
		else
			self:say(pBot, oid, speakerOid, channel, "fatigueNo", name, {town = self:nearestTown(pBot)})
		end

		return true
	end

	local kind = hasAny(t, self.words.perfstop) and "perfstop" or (hasAny(t, self.words.music) and "music") or
		((hasAny(t, self.words.dance) or t:find("^ dance ")) and "dance") or nil

	if kind == nil then
		return false
	end

	-- (a stranger asking in the cantina gets the model's chat)
	if member == nil or not member.human then
		return false
	end

	local camp = self:activeCamp(g, self:leaderOf(pBot, oid, g, os.time()))

	if kind == "perfstop" then
		put(ckey(oid, "perf"), 0)
		self:perfStop(pBot, oid, true)
		self:say(pBot, oid, speakerOid, channel, "perfStop", name)
	elseif camp == nil then
		self:say(pBot, oid, speakerOid, channel, "noCamp", name)
	else
		put(ckey(oid, "perf"), kind == "music" and 2 or 1)
		self:say(pBot, oid, speakerOid, channel, kind == "music" and "musicOn" or "danceOn", name)
	end

	return true
end

-- The squad leader (Phase 8, specs/2026-10-25-full-group/). It calls the six squad leader commands in a group we lead
-- (patches/0009 lets Core3 take them from a bot in the group), one per turn with its queue empty and its pools above
-- slHamFloor, and says each call in group chat as a player squad leader did.

local function creatureName(pCreature)
	return ((SceneObject(pCreature):getDisplayedName() or "it"):gsub("^[Aa]n? ", ""):gsub("^[Tt]he ", ""))
end

-- All three pools above this share of their maximum
function BotCrew:hamAbove(pBot, share)
	local creature = CreatureObject(pBot)

	for _, pool in ipairs({HEALTH, ACTION, MIND}) do
		local max = creature:getMaxHAM(pool)

		if max > 0 and creature:getHAM(pool) < max * share then
			return false
		end
	end

	return true
end

-- A call in group chat, at most one every slCallGap seconds whatever it is (the command goes either way); "Fall back!" is
-- always said
function BotCrew:slCall(pBot, oid, kind, fill, now)
	if now - readData(ckey(oid, "slCallAt")) < self.slCallGap and kind ~= "retreat" then
		return
	end

	put(ckey(oid, "slCallAt"), now)
	self:say(pBot, oid, 0, "group", kind, nil, fill)
end

function BotCrew:slCommand(pBot, oid, command, target, field, now)
	botEnqueue(pBot, command, target, "")
	put(ckey(oid, field), now)
	print("BotJobs: " .. self:name(oid) .. " (squad leader) " .. command .. (target ~= 0 and (" " .. target) or ""))
end

-- The creature the group fights: the tank's target, else the leader's
function BotCrew:slTarget(pBot, oid, g, pLeader)
	local tank = self:tankFor(oid, g)
	local pTarget = tank ~= nil and self:validTarget(pBot, getSceneObject(readData(ckey(tank.oid, "target"))), g, false) or nil

	if pTarget == nil and pLeader ~= nil and CreatureObject(pLeader):isInCombat() then
		pTarget = self:validTarget(pBot, getSceneObject(CreatureObject(pLeader):getTargetID()), g, false)
	end

	return pTarget
end

-- Is a human of the group fighting something that isn't a creature (a lair)?
function BotCrew:lairFight(g, now)
	for _, m in ipairs(g.humans) do
		local base = "crew:human:" .. m.oid
		local defender = now - readData(base .. ":at") <= self.attackerFresh and readData(base .. ":defender") or 0
		local pDefender = defender ~= 0 and getSceneObject(defender) or nil

		if pDefender ~= nil and not SceneObject(pDefender):isCreatureObject() then
			return true
		end
	end

	return false
end

-- The lairs we know of, less the one the group is fighting (a human's main defender that isn't a creature): a second lair nearby
-- is not part of the fight, and a cone, grenade or area pack that reached it would pull it
function BotCrew:lairsExcludingFight(pBot, oid, g, now)
	local lairs = self:lairsOf(pBot, oid, now)
	local fought = {}

	for _, m in ipairs(g.humans) do
		local base = "crew:human:" .. m.oid
		local defender = now - readData(base .. ":at") <= self.attackerFresh and readData(base .. ":defender") or 0
		local pDefender = defender ~= 0 and getSceneObject(defender) or nil

		if pDefender ~= nil and not SceneObject(pDefender):isCreatureObject() then
			table.insert(fought, {x = SceneObject(pDefender):getWorldPositionX(), y = SceneObject(pDefender):getWorldPositionY()})
		end
	end

	if #fought == 0 then
		return lairs
	end

	local out = {}

	for _, lair in ipairs(lairs) do
		local isFought = false

		-- (lairsOf keeps whole metres)
		for _, f in ipairs(fought) do
			if math.abs(lair.x - f.x) <= 2 and math.abs(lair.y - f.y) <= 2 then
				isFought = true
			end
		end

		if not isFought then
			table.insert(out, lair)
		end
	end

	return out
end

-- Is this creature in or by a town (within townRadius of the centre of the nearest main town)?
function BotCrew:inTown(pCreature)
	local x, y = SceneObject(pCreature):getWorldPositionX(), SceneObject(pCreature):getWorldPositionY()

	for _, town in ipairs(self.towns[SceneObject(pCreature):getZoneName()] or {}) do
		if math.sqrt((x - town[2]) ^ 2 + (y - town[3]) ^ 2) <= self.townRadius then
			return true
		end
	end

	return false
end

-- Is the fight lost? The tank down and two members under retreatLow of their health, or three members down.
function BotCrew:fightLost(g)
	local down, low, tankDown = 0, 0, false

	for _, m in ipairs(g.members) do
		if m.player then
			local c = CreatureObject(m.p)

			if c:isDead() or c:isIncapacitated() then
				down = down + 1

				if m.job == "tank" then
					tankDown = true
				end
			elseif self:ratio(m.p, HEALTH) < self.retreatLow then
				low = low + 1
			end
		end
	end

	return down >= 3 or (tankDown and low >= 2)
end

-- How many of the group fight this creature (it is their main defender, as last noted)
function BotCrew:fightingIt(g, coid, now)
	local n = 0

	for _, m in ipairs(g.crew) do
		if now - readData(ckey(m.oid, "defenderAt")) <= self.attackerFresh and readData(ckey(m.oid, "defender")) == coid then
			n = n + 1
		end
	end

	for _, m in ipairs(g.humans) do
		if now - readData("crew:human:" .. m.oid .. ":at") <= self.attackerFresh and readData("crew:human:" .. m.oid .. ":defender") == coid then
			n = n + 1
		end
	end

	return n
end

-- Wounds of the group: the total and the most one member carries
function BotCrew:groupWounds(g)
	local total, most, members = 0, 0, 0

	for _, m in ipairs(g.members) do
		if m.player and not CreatureObject(m.p):isDead() then
			local sum = 0

			for pool = 0, 8 do
				sum = sum + (botGetWounds(m.p, pool) or 0)
			end

			total = total + sum
			most = math.max(most, sum)
			members = members + 1
		end
	end

	return total, most, members
end

-- Does the bot have the points for a squad leader command (about 130 of each pool, in a group of eight)?
function BotCrew:slCanPay(pBot)
	local creature = CreatureObject(pBot)

	for _, pool in ipairs({HEALTH, ACTION, MIND}) do
		if creature:getHAM(pool) < self.slPay then
			return false
		end
	end

	return true
end

function BotCrew:slTurn(pBot, oid, g, pLeader, now)
	-- (a command costs about slPay of each pool; below that nothing goes. The share slHamFloor keeps the rest from draining it)
	if not self:slCanPay(pBot) then
		return false
	end

	-- (a retreat goes into the queue behind whatever it is shooting; the others wait for an empty queue)
	local queueEmpty = CreatureObject(pBot):getQueueSize() == 0
	local roomy = self:hamAbove(pBot, self.slHamFloor)
	local leaderOid = SceneObject(pLeader):getObjectID()
	local fighting = CreatureObject(pBot):isInCombat() or self:groupFighting(g)

	-- Retreat: the fight is lost (whatever the squad leader's pools, as long as it can pay). Not with the leader down: there is
	-- nobody to run with, and the crew would stand about it
	local leaderDown = CreatureObject(pLeader):isDead() or CreatureObject(pLeader):isIncapacitated()

	if fighting and not leaderDown and self:can(oid, "retreat") and now - readData(gkey(leaderOid, "retreatAt")) >= self.retreatBlock and self:fightLost(g) then
		put(gkey(leaderOid, "retreatAt"), now)
		put(gkey(leaderOid, "retreatUntil"), now + self.retreatFor)
		self:slCommand(pBot, oid, "retreat", 0, "slRetreatAt", now)
		self:slCall(pBot, oid, "retreat", nil, now)
		print("BotJobs: " .. self:name(oid) .. " calls the retreat")
		return true
	end

	if not roomy or not queueEmpty then
		return false
	end

	-- Form up: someone in the group is stunned or dizzy
	if self:can(oid, "formUp") and now - readData(ckey(oid, "slFormUpAt")) >= self.slFormUpGap then
		for _, m in ipairs(g.members) do
			if m.player and not CreatureObject(m.p):isDead() and (hasState(m.p, 0x1000) or hasState(m.p, 0x4000)) then
				self:slCommand(pBot, oid, "formup", 0, "slFormUpAt", now)
				self:slCall(pBot, oid, "formUp", nil, now)
				return true
			end
		end
	end

	local pTarget = fighting and self:slTarget(pBot, oid, g, pLeader) or nil

	-- Rally: a fight with two or more creatures, or a lair
	if fighting and self:can(oid, "rally") and now - readData(ckey(oid, "slRallyAt")) >= self.slRallyGap then
		local creatures = #self:groupCreatures(pBot, g, now, pTarget)

		if creatures >= self.slRallyCreatures or self:lairFight(g, now) then
			self:slCommand(pBot, oid, "rally", 0, "slRallyAt", now)
			self:slCall(pBot, oid, "rally", nil, now)
			return true
		end
	end

	-- Steady aim: only while hunting (in a fight, or out in the wild on the way out), again when its five minutes are over
	if self:can(oid, "steadyAim") and now >= readData(ckey(oid, "slAimAt")) and SceneObject(pLeader):getParentID() == 0 and
		SceneObject(pBot):getParentID() == 0 and (fighting or not self:inTown(pLeader)) then
		self:slCommand(pBot, oid, "steadyaim", 0, "slAimAt", now)
		put(ckey(oid, "slAimAt"), now + self.slAimEvery)
		self:slCall(pBot, oid, "steadyAim", nil, now)
		return true
	end

	-- Volley fire on the tank's target when three or more of the group are fighting it
	if pTarget ~= nil and self:can(oid, "volley") and now - readData(ckey(oid, "slVolleyAt")) >= self.slVolleyGap then
		local coid = SceneObject(pTarget):getObjectID()
		local dist = BotJobs:distance(pBot, pTarget)

		if dist ~= nil and dist <= self.engageRange and self:fightingIt(g, coid, now) >= self.slVolleyMembers then
			self:slCommand(pBot, oid, "volleyfire", coid, "slVolleyAt", now)
			self:slCall(pBot, oid, "volley", {creature = creatureName(pTarget)}, now)
			return true
		end
	end

	-- Boost morale after a fight: one member carries most of the group's wounds
	if not fighting and self:can(oid, "boostMorale") and now - readData(ckey(oid, "slMoraleAt")) >= self.slMoraleGap then
		local total, most, members = self:groupWounds(g)

		if members >= 2 and total >= self.slMoraleWounds and most >= total * self.slMoraleShare then
			self:slCommand(pBot, oid, "boostmorale", 0, "slMoraleAt", now)
			self:slCall(pBot, oid, "boostMorale", nil, now)
			return true
		end
	end

	return false
end

-- A retreat in force (the squad leader called it): the crew breaks off and follows the leader, until retreatFor seconds are
-- over or nothing has chased the group for retreatMin. True while this bot's turn is spent on it.
function BotCrew:retreatStep(pBot, oid, g, pLeader, now)
	local leaderOid = SceneObject(pLeader):getObjectID()
	local until_ = readData(gkey(leaderOid, "retreatUntil"))

	if until_ == 0 then
		return false
	end

	local started = readData(gkey(leaderOid, "retreatAt"))

	-- (the leader went down meanwhile: the retreat is over, the crew fights or heals as before)
	if now >= until_ or CreatureObject(pLeader):isDead() or CreatureObject(pLeader):isIncapacitated() or (now - started >= self.retreatMin and #self:groupCreatures(pBot, g, now, nil) == 0) then
		put(gkey(leaderOid, "retreatUntil"), 0)
		put(gkey(leaderOid, "retreatHold"), now + self.retreatHold)
		print("BotJobs: the retreat of " .. self:firstName(pLeader) .. "'s group is over")
		return false
	end

	if readData(ckey(oid, "retreatSeen")) ~= started then
		put(ckey(oid, "retreatSeen"), started)
		deleteData(ckey(oid, "focus"))
		putString(ckey(oid, "order"), "follow")
		deleteData(ckey(oid, "followAt"))

		if readData(ckey(oid, "target")) ~= 0 or CreatureObject(pBot):isInCombat() then
			self:endFight(pBot, oid, now)
		end

		print("BotJobs: " .. self:name(oid) .. " falls back")
	end

	-- (the medic's heals came before this; a ranged bot walking to a band stops)
	deleteData(ckey(oid, "moveSince"))
	deleteData(ckey(oid, "backSince"))
	self:ensureFollow(pBot, oid, pLeader, now)

	return true
end

-- The commando (Phase 8)

local function angleBetween(ax, ay, bx, by)
	local d = math.abs(math.atan(ay, ax) - math.atan(by, bx))

	if d > math.pi then
		d = 2 * math.pi - d
	end

	return math.deg(d)
end

-- The creatures around the commando, each marked pulled when it fights the group: it is in the group's threat picture or
-- its main defender is a member. {oid, x, y, r, pulled, target}
function BotCrew:creatureField(pBot, g, now, pFirst, range)
	local pulled = {}

	for _, c in ipairs(self:groupCreatures(pBot, g, now, pFirst)) do
		pulled[c.oid] = true
	end

	local out = {}

	for _, c in ipairs(bot("botCreaturesNear", pBot, range) or {}) do
		table.insert(out, {oid = c.oid, x = c.x, y = c.y, r = c.radius, target = c.target,
			pulled = pulled[c.oid] == true or (c.target ~= 0 and g.byOid[c.target] ~= nil)})
	end

	return out
end

-- Does a creature that isn't fighting the group (or a lair that isn't the fight) stand in this cone? Checked wider than Core3's
function BotCrew:coneUnsafe(bx, by, tx, ty, field, lairs)
	for _, e in ipairs(field) do
		if not e.pulled and math.sqrt((e.x - bx) ^ 2 + (e.y - by) ^ 2) - e.r <= self.coneSafeRange and
			angleBetween(e.x - bx, e.y - by, tx - bx, ty - by) <= self.coneSafeHalf then
			return true
		end
	end

	for _, lair in ipairs(lairs) do
		if math.sqrt((lair.x - bx) ^ 2 + (lair.y - by) ^ 2) <= self.coneSafeRange + 4 and
			angleBetween(lair.x - bx, lair.y - by, tx - bx, ty - by) <= self.coneSafeHalf then
			return true
		end
	end

	return false
end

-- Does a creature that isn't fighting the group (or a lair) stand within the blast of a grenade (or an area pack) at x, y?
function BotCrew:blastUnsafe(x, y, radius, field, lairs)
	for _, e in ipairs(field) do
		if not e.pulled and math.sqrt((e.x - x) ^ 2 + (e.y - y) ^ 2) - e.r <= radius then
			return true
		end
	end

	for _, lair in ipairs(lairs) do
		if math.sqrt((lair.x - x) ^ 2 + (lair.y - y) ^ 2) <= radius + 4 then
			return true
		end
	end

	return false
end

-- Hold the flame thrower (1) or the acid rifle (2)
function BotCrew:commandoHold(pBot, oid, which, now)
	put(ckey(oid, "held"), which)
	put(ckey(oid, "swapAt"), now)

	local template = which == 2 and self.acidRifle or self:weapon(oid)

	if template ~= nil then
		bot("botEquip", pBot, template)
	end

	self:readBand(pBot, oid)
	print("BotJobs: " .. self:name(oid) .. " (commando) holds the " .. (which == 2 and "acid rifle" or "flame thrower"))
end

-- The weapon that does more against this creature's armor (a margin keeps it from swapping back and forth). True if it swapped.
function BotCrew:commandoSwap(pBot, oid, pTarget, now)
	if not self:can(oid, "acidCone") or now - readData(ckey(oid, "swapAt")) < self.swapGap then
		return false
	end

	local resists = bot("botResists", pTarget)

	if resists == nil then
		return false
	end

	-- (-1 is vulnerable: no armor at all)
	local flame = self.flameAvg * (1 - math.max(resists.heat, 0) / 100)
	local acid = self.acidAvg * (1 - math.max(resists.acid, 0) / 100)
	local held = readData(ckey(oid, "held"))

	if held ~= 2 and acid > flame * self.swapMargin then
		self:commandoHold(pBot, oid, 2, now)
		return true
	elseif held == 2 and flame > acid / self.swapMargin then
		self:commandoHold(pBot, oid, 1, now)
		return true
	end

	return false
end

-- An area attack held back for a creature that isn't fighting the group (logged at most every 10 s)
function BotCrew:areaHeld(oid, what, now)
	if now - readData(ckey(oid, "coneAt")) >= 10 then
		put(ckey(oid, "coneAt"), now)
		print("BotJobs: " .. self:name(oid) .. " (commando) holds the " .. what .. ": a creature that isn't fighting the group stands in its area")
	end
end

function BotCrew:commandoTurn(pBot, oid, pTarget, g, dist, now)
	if self:commandoSwap(pBot, oid, pTarget, now) then
		return true
	end

	if not self:hamOk(pBot) then
		return false
	end

	local acid = readData(ckey(oid, "held")) == 2
	local bx, by = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY()
	local coneCmd = readStringData(ckey(oid, acid and "acidCone" or "flameCone"))
	local singleCmd = readStringData(ckey(oid, acid and "acidSingle" or "flameSingle"))
	local wantGrenade = self:can(oid, "grenade") and now - readData(ckey(oid, "grenadeAt")) >= self.grenadeGap
	local wantCone = coneCmd ~= "" and dist <= self.coneRange + 12

	if not (wantGrenade or wantCone) and singleCmd == "" then
		return false
	end

	-- The creatures around, once (a scan), and the lairs we know
	-- (a grenade may land grenadeRange away and blast grenadeSafe around that: the scan reaches that far; a full list may have left
	-- some out, and then no area attack)
	local field = self:creatureField(pBot, g, now, pTarget, self.grenadeRange + self.grenadeSafe + 4)
	local lairs = self:lairsExcludingFight(pBot, oid, g, now)
	local tank = self:tankFor(oid, g)

	if #field >= 40 then
		wantGrenade, wantCone = false, false
	end

	-- A grenade at a clump on the tank (else on any member of the group, without a tank)
	if wantGrenade then
		local best, bestN = nil, 0

		for _, e in ipairs(field) do
			if e.pulled and (tank == nil or e.target == tank.oid) and
				math.sqrt((e.x - bx) ^ 2 + (e.y - by) ^ 2) <= self.grenadeRange then
				local n = 0

				for _, other in ipairs(field) do
					if other.pulled and (tank == nil or other.target == tank.oid) and
						math.sqrt((other.x - e.x) ^ 2 + (other.y - e.y) ^ 2) <= self.grenadeClump then
						n = n + 1
					end
				end

				if n > bestN then
					best, bestN = e, n
				end
			end
		end

		if best ~= nil and bestN >= self.grenadeMin and self:blastUnsafe(best.x, best.y, self.grenadeSafe, field, lairs) then
			self:areaHeld(oid, "grenade", now)
		elseif best ~= nil and bestN >= self.grenadeMin then
			local item = bot("botStockItem", pBot, self.grenade, self.grenadeStock) or 0

			if item ~= 0 then
				botEnqueue(pBot, "throwgrenade", best.oid, tostring(item))
				put(ckey(oid, "grenadeAt"), now)
				put(ckey(oid, "specialCount"), readData(ckey(oid, "specialCount")) + 1)
				print("BotJobs: " .. self:name(oid) .. " (commando) throwgrenade at " .. best.oid .. ", " .. bestN .. " creatures within " ..
					self.grenadeClump .. " m")
				self:callout(pBot, oid, "grenade", nil, now)

				return true
			end
		end
	end

	-- A cone at the creature with most of the group's creatures in line with it, if nothing unpulled stands in the cone
	if wantCone then
		local best, bestN = nil, 0

		for _, e in ipairs(field) do
			if e.pulled and math.sqrt((e.x - bx) ^ 2 + (e.y - by) ^ 2) - e.r <= self.coneRange then
				local n = 0

				for _, other in ipairs(field) do
					if other.pulled and math.sqrt((other.x - bx) ^ 2 + (other.y - by) ^ 2) - other.r <= self.coneRange and
						angleBetween(other.x - bx, other.y - by, e.x - bx, e.y - by) <= self.coneHalf then
						n = n + 1
					end
				end

				if n > bestN then
					best, bestN = e, n
				end
			end
		end

		if best ~= nil and bestN >= self.coneMin and self:coneUnsafe(bx, by, best.x, best.y, field, lairs) then
			self:areaHeld(oid, "cone", now)
		elseif best ~= nil and bestN >= self.coneMin then
			botEnqueue(pBot, coneCmd, best.oid, "")
			put(ckey(oid, "specialCount"), readData(ckey(oid, "specialCount")) + 1)
			print("BotJobs: " .. self:name(oid) .. " (commando) " .. coneCmd .. " " .. best.oid .. ", " .. bestN .. " creatures in the cone")
			self:callout(pBot, oid, "flame", nil, now)

			return true
		end
	end

	-- Otherwise a single shot at the fight's target, within its reach
	if singleCmd ~= "" and dist <= self.coneRange then
		botEnqueue(pBot, singleCmd, SceneObject(pTarget):getObjectID(), "")
		put(ckey(oid, "specialCount"), readData(ckey(oid, "specialCount")) + 1)

		return true
	end

	return false
end

-- One fight step: a new target is set and attacked (the tank taunts it), the bot moves to its range, and with its command
-- queue empty it uses a special (the tank holds the creatures that aren't on it, see tankTurn)
function BotCrew:fight(pBot, oid, pTarget, pLeader, g, now)
	local role = self:role(oid)
	local targetOid = SceneObject(pTarget):getObjectID()
	local previous = readData(ckey(oid, "target"))

	if previous ~= targetOid then
		put(ckey(oid, "target"), targetOid)
		put(ckey(oid, "targetAt"), now)
		self:lootNote(oid, targetOid)
		self:standUp(pBot, oid)
		-- (botSetTarget queues a real attack, so auto-attack runs; a ranged bot aims once it stands where it should)
		put(ckey(oid, "aimed"), 0)

		if role == "tank" then
			bot("botSetTarget", pBot, targetOid)
		end
		print("BotJobs: " .. self:name(oid) .. " (" .. role .. ") attacks " .. SceneObject(pTarget):getDisplayedName())

		if previous == 0 then
			put(ckey(oid, "chatty"), percent(self.calloutChance) and 1 or 0)
		end

		if role == "tank" then
			-- The tank engages: when the others may open is counted from here
			self:tankNote(oid, targetOid)
			put(tkey(oid, targetOid, "E"), now)
			put(tkey(oid, targetOid, "G"), 0)

			if self:can(oid, "taunt") then
				-- (not inside the creature's lockout, nor while a taunt is in force: Core3 would do nothing but add aggro)
				local th = bot("botThreatOn", pBot, pTarget)

				if th == nil or (th.tauntable and th.lockoutMs <= 0 and not th.taunted) then
					botEnqueue(pBot, "taunt", targetOid, "")
					put(tkey(oid, targetOid, "T"), now)
					print("BotJobs: " .. self:name(oid) .. " (tank) taunt " .. SceneObject(pTarget):getDisplayedName() .. " " .. targetOid ..
						", opening")
				end

				if previous == 0 and g ~= nil then
					self:callout(pBot, oid, "pull", nil, now)
				end
			end
		end
	end

	local dist = BotJobs:distance(pBot, pTarget) or 999

	-- The entertainer stops its performance for a fight, and picks its pistol up again
	if role == "entertainer" then
		self:perfStop(pBot, oid, true)
	end

	if role == "tank" then
		self:closeIn(pBot, oid, pTarget, dist, now)
	elseif self:rangedStance(pBot, oid, pTarget, pLeader, g, dist, role, now) == "move" then
		return
	end

	if CreatureObject(pBot):getQueueSize() > 0 then
		return
	end

	-- The commando's cones, grenades and single shots are its own turn
	if role == "commando" then
		self:commandoTurn(pBot, oid, pTarget, g, dist, now)
		return
	end

	if role == "tank" then
		if g ~= nil and self:can(oid, "taunt") and self:tankTurn(pBot, oid, pTarget, g, now) then
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
	elseif dist > readData(ckey(oid, "bandMax")) then
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

-- Range bands (Phase 7c)

-- The held weapon's band, cached per bot (equip refreshes it): near and far edge and the furthest the weapon reaches. A
-- weapon that isn't ranged, or a build without botWeaponRange, gives the old stand-anywhere-in-reach.
function BotCrew:readBand(pBot, oid)
	local r = bot("botWeaponRange", pBot)

	-- The commando's heavy weapons do their specials within 16 m: it stands close
	if r ~= nil and self:role(oid) == "commando" then
		put(ckey(oid, "bandNear"), self.commandoBand[1])
		put(ckey(oid, "bandFar"), self.commandoBand[2])
		put(ckey(oid, "bandMax"), r.maxRange)
		return
	end

	if r == nil or not r.ranged then
		put(ckey(oid, "bandNear"), 0)
		put(ckey(oid, "bandFar"), 0)
		put(ckey(oid, "bandMax"), r ~= nil and r.maxRange or 64)
		return
	end

	local far = math.max(self.bandMin, math.min(self.bandMax, r.idealRange))

	put(ckey(oid, "bandNear"), math.max(self.bandMin, far - self.bandWidth))
	put(ckey(oid, "bandFar"), far)
	put(ckey(oid, "bandMax"), r.maxRange)
end

-- The edges of this bot's band (nil for a bot with none). The medic's is held to its ranged-stim reach from the tank
-- (who stands against the target)
function BotCrew:band(pBot, oid, role)
	if readData(ckey(oid, "bandMax")) == 0 then
		self:readBand(pBot, oid)
	end

	local near, far = readData(ckey(oid, "bandNear")), readData(ckey(oid, "bandFar"))

	if far == 0 then
		return nil
	end

	if role == "medic" and self:can(oid, "rangedStims") then
		far = math.min(far, math.floor(self.reach.ranged - 2))
		near = math.max(self.bandMin, far - self.bandWidth)
	end

	return near, far
end

-- Is the straight way from (x1, y1) to (x2, y2) within `avoid` metres of a lair?
local function lairOnWay(lairs, x1, y1, x2, y2, avoid)
	local dx, dy = x2 - x1, y2 - y1
	local len2 = dx * dx + dy * dy

	for _, lair in ipairs(lairs) do
		local k = len2 > 0 and math.max(0, math.min(1, ((lair.x - x1) * dx + (lair.y - y1) * dy) / len2)) or 0
		local px, py = x1 + k * dx, y1 + k * dy

		if math.sqrt((lair.x - px) ^ 2 + (lair.y - py) ^ 2) < avoid then
			return true
		end
	end

	return false
end

local function lairList(text)
	local out = {}

	for x, y in string.gmatch(text or "", "(-?%d+),(-?%d+)") do
		table.insert(out, {x = tonumber(x), y = tonumber(y)})
	end

	return out
end

-- The lairs near, scanned now and then (a scan is a look at everything around)
function BotCrew:lairsOf(pBot, oid, now)
	if now - readData(ckey(oid, "lairsAt")) >= self.lairEvery then
		put(ckey(oid, "lairsAt"), now)

		local parts = {}

		for _, lair in ipairs(bot("botLairsNear", pBot, self.lairScan) or {}) do
			table.insert(parts, string.format("%d,%d", math.floor(lair.x), math.floor(lair.y)))
		end

		putString(ckey(oid, "lairs"), table.concat(parts, ";"))
	end

	return lairList(readStringData(ckey(oid, "lairs")))
end

-- Where to stand to shoot: inside the band's far edge, on the leader's side of the target (the bot's own side when the
-- leader is on top of it), and not within lairAvoid of a lair, nor with a lair on the way: the spot is turned away from
-- one in 30 degree steps. nil when no turn is clear: the bot stays where it is.
function BotCrew:bandSpot(pBot, oid, pTarget, pLeader, far, now)
	local tx, ty = SceneObject(pTarget):getPositionX(), SceneObject(pTarget):getPositionY()
	local px, py = SceneObject(pBot):getPositionX(), SceneObject(pBot):getPositionY()
	local px0, py0 = px, py

	if pLeader ~= nil then
		local lx, ly = SceneObject(pLeader):getPositionX(), SceneObject(pLeader):getPositionY()

		if math.sqrt((lx - tx) ^ 2 + (ly - ty) ^ 2) >= 10 then
			px, py = lx, ly
		end
	end

	local dx, dy = px - tx, py - ty
	local len = math.sqrt(dx * dx + dy * dy)

	if len < 1 then
		dx, dy, len = 0, -1, 1
	end

	dx, dy = dx / len, dy / len

	local d = far - self.bandIn
	local lairs = self:lairsOf(pBot, oid, now)

	for _, degrees in ipairs({0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180}) do
		local a = math.rad(degrees)
		local ax, ay = dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)
		local sx, sy = tx + ax * d, ty + ay * d

		-- (neither the spot nor the way to it near a lair)
		if not lairOnWay(lairs, px0, py0, sx, sy, self.lairAvoid) then
			return sx, sy
		end
	end

	return nil
end

-- A walk of a band move, at most one per stepGap seconds (the mover keeps walking to the last point)
function BotCrew:bandStep(pBot, oid, x, y, z, cell, now)
	if now - readData(ckey(oid, "stepAt")) < self.stepGap then
		return
	end

	put(ckey(oid, "stepAt"), now)
	self:standUp(pBot, oid)
	bot("botMoveTo", pBot, x, z, y, cell)
end

-- Step away from a creature that is on this bot, toward the group
function BotCrew:backOff(pBot, oid, pCreature, pLeader, g, now)
	local bx, by = SceneObject(pBot):getPositionX(), SceneObject(pBot):getPositionY()
	local cx, cy = SceneObject(pCreature):getPositionX(), SceneObject(pCreature):getPositionY()
	local ax, ay = bx - cx, by - cy
	local alen = math.sqrt(ax * ax + ay * ay)

	if alen < 0.5 then
		ax, ay, alen = 0, -1, 1
	end

	ax, ay = ax / alen, ay / alen

	-- the group: the tank if it holds, else the leader
	local tank = self:tankFor(oid, g)
	local pGroup = tank ~= nil and tank.p or pLeader
	local vx, vy = ax, ay

	if pGroup ~= nil then
		local gx, gy = SceneObject(pGroup):getPositionX() - bx, SceneObject(pGroup):getPositionY() - by
		local glen = math.sqrt(gx * gx + gy * gy)

		if glen > 1 then
			vx, vy = ax + 0.5 * gx / glen, ay + 0.5 * gy / glen
		end
	end

	local vlen = math.sqrt(vx * vx + vy * vy)

	if vlen < 0.1 then
		vx, vy, vlen = ax, ay, 1
	end

	-- (not toward a lair: straight away from the creature, else no step)
	local lairs = self:lairsOf(pBot, oid, now)

	for _, dir in ipairs({{vx / vlen, vy / vlen}, {ax, ay}}) do
		local x, y = bx + dir[1] * self.backOffStep, by + dir[2] * self.backOffStep

		if not lairOnWay(lairs, bx, by, x, y, self.lairAvoid) then
			self:bandStep(pBot, oid, x, y, SceneObject(pBot):getPositionZ(), SceneObject(pBot):getParentID(), now)
			return true
		end
	end

	return false
end

-- The nearest creature that is on this bot now (its main defender is the bot: one in the bot's threat map that has
-- gone for the tank since doesn't count)
function BotCrew:creatureOnMe(pBot, oid, g)
	local best, bestDist = nil, nil

	for _, coid in ipairs(oidList(readStringData(ckey(oid, "attackers")))) do
		local pCreature = self:validTarget(pBot, getSceneObject(coid), g, false)
		local pOn = pCreature ~= nil and CreatureObject(pCreature):getMainDefender() or nil

		if pOn ~= nil and SceneObject(pOn):getObjectID() == oid then
			local dist = BotJobs:distance(pBot, pCreature) or 999

			if best == nil or dist < bestDist then
				best, bestDist = pCreature, dist
			end
		end
	end

	return best
end

-- Indoors: shoot within the band's far edge while the leader is near; out of range stay with the leader (who is usually by
-- the fight) or walk up to it
function BotCrew:cellRange(pBot, oid, pTarget, pLeader, dist, range, now)
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

-- A ranged bot's place in the fight, for this step: "move" (walking to its band or backing off: it holds fire, since
-- moving costs a rifle 100-150 accuracy) or "fire" (it stands in its band, kneels when nothing closes on it, and shoots)
function BotCrew:rangedStance(pBot, oid, pTarget, pLeader, g, dist, role, now)
	local near, far = self:band(pBot, oid, role)
	local move = bot("botMoveState", pBot) or {}
	local state = "fire"

	-- No band, no leader to stay with or told to stay: it shoots where it is
	if near == nil or pLeader == nil or readStringData(ckey(oid, "order")) == "stay" then
		state = "fire"
	elseif SceneObject(pTarget):getParentID() ~= 0 or SceneObject(pBot):getParentID() ~= 0 then
		-- Inside a building (a cell): no band, no kneeling, no back-off: it stays with the leader or walks up to range, as it did
		self:cellRange(pBot, oid, pTarget, pLeader, dist, far, now)
	else
		local pOnMe = self:creatureOnMe(pBot, oid, g)
		local onMeDist = pOnMe ~= nil and BotJobs:distance(pBot, pOnMe) or nil
		local leaderDist = BotJobs:distance(pBot, pLeader)

		if onMeDist ~= nil and onMeDist < math.max(self.backOffRange, near) and now >= readData(ckey(oid, "backBlock")) and
			role ~= "commando" then
			-- A creature has come for this bot: step back toward the group, and shoot once it can't be kept off
			if readData(ckey(oid, "backSince")) == 0 then
				put(ckey(oid, "backSince"), now)
				put(ckey(oid, "moveSince"), 0)
				self:callout(pBot, oid, "backUp", nil, now)
				print("BotJobs: " .. self:name(oid) .. " (" .. role .. ") backs off from " .. SceneObject(pOnMe):getDisplayedName() ..
					", " .. string.format("%.0f", onMeDist) .. " m")
			end

			if now - readData(ckey(oid, "backSince")) > self.backFor then
				put(ckey(oid, "backBlock"), now + self.backBlock)
				put(ckey(oid, "backSince"), 0)
			elseif self:backOff(pBot, oid, pOnMe, pLeader, g, now) then
				state = "move"
			end
		else
			put(ckey(oid, "backSince"), 0)

			if leaderDist == nil or leaderDist > self.leaderSpread then
				self:ensureFollow(pBot, oid, pLeader, now)
				state = "move"
			elseif (dist > far - (readData(ckey(oid, "moveSince")) ~= 0 and self.bandSettle or 0) or
				(dist < near + (readData(ckey(oid, "moveSince")) ~= 0 and self.bandSettle or 0) and pOnMe == nil)) and
				now >= readData(ckey(oid, "moveBlock")) then
				-- Not in the band: walk to a spot in it (it gives up on a walk that takes too long and fires from where it is)
				if readData(ckey(oid, "moveSince")) == 0 then
					put(ckey(oid, "moveSince"), now)
				end

				if now - readData(ckey(oid, "moveSince")) > self.moveFor then
					put(ckey(oid, "moveBlock"), now + self.moveBlock)
					put(ckey(oid, "moveSince"), 0)
				else
					local x, y = self:bandSpot(pBot, oid, pTarget, pLeader, far, now)

					-- (no clear spot: it stays where it is and shoots)
					if x ~= nil then
						self:bandStep(pBot, oid, x, y, SceneObject(pTarget):getPositionZ(), SceneObject(pTarget):getParentID(), now)
						state = "move"
					end
				end
			else
				put(ckey(oid, "moveSince"), 0)

				-- In the band: stop, and kneel to shoot unless something is coming
				if move.state == "goto" or move.state == "follow" then
					bot("botStop", pBot)
				end

				if pOnMe == nil and CreatureObject(pBot):getPosture() ~= CROUCHED and now - readData(ckey(oid, "kneelAt")) >= 3 then
					put(ckey(oid, "kneelAt"), now)
					botEnqueue(pBot, "kneel", 0, "")
				end
			end
		end
	end

	if state == "move" then
		-- (no target, no auto-attack)
		put(ckey(oid, "aimed"), 0)

		if CreatureObject(pBot):getTargetID() ~= 0 then
			bot("botSetTarget", pBot, 0)
		end
	elseif readData(ckey(oid, "aimed")) ~= 1 then
		put(ckey(oid, "aimed"), 1)
		bot("botSetTarget", pBot, SceneObject(pTarget):getObjectID())
	end

	return state
end

-- The fight is over: peace, packs refilled; the follow starts again on the next step
function BotCrew:endFight(pBot, oid, now)
	deleteData(ckey(oid, "target"))
	deleteData(ckey(oid, "holdOid"))
	deleteData(ckey(oid, "aimed"))
	deleteData(ckey(oid, "moveSince"))
	deleteData(ckey(oid, "backSince"))
	deleteData(ckey(oid, "dotOid"))
	self:tankDrop(oid)
	put(ckey(oid, "peaceAt"), now)
	bot("botSetTarget", pBot, 0)
	botEnqueue(pBot, "peace", 0, "")

	if self:role(oid) == "commando" and readData(ckey(oid, "held")) == 2 then
		self:commandoHold(pBot, oid, 1, now)
	end

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

	-- Never heal either side of a duel or a provoked fight that involves the group: the crew mate who is fighting and
	-- its opponent, and a human of the group who is fighting another member (read by scanHumans)
	local opponents = {}

	if BotFight ~= nil and BotFight.fighting ~= nil then
		for _, m in ipairs(g.members) do
			local opponent = BotFight:fighting(m.oid)

			if opponent ~= nil and opponent ~= 0 then
				opponents[opponent] = true
				opponents[m.oid] = true
			end
		end
	end

	for _, m in ipairs(g.humans) do
		local defender = readData("crew:human:" .. m.oid .. ":defender")

		if defender ~= 0 and now - readData("crew:human:" .. m.oid .. ":at") <= self.attackerFresh and
			(g.byOid[defender] ~= nil or readData("crew:human:" .. m.oid .. ":pvp") == 1) then
			-- A member fighting another member, or any player (a duel)
			opponents[m.oid] = true
			opponents[defender] = true
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

	-- Nothing needs the medic: a poison and a disease pack on the creature it fights
	if fighting then
		return self:dotTurn(pBot, oid, g, now)
	end

	return false
end

-- The combat medic's damage packs (Phase 7c): a poison pack, then a disease pack, on the creature it is fighting (the
-- tank's target), each once the last of its kind has run its course. Packs land by chance (potency against the
-- creature's resistance): a kind that missed twice, or a creature that can't be poisoned or diseased, is let be.
function BotCrew:dotTurn(pBot, oid, g, now)
	if not (self:can(oid, "poisonPack") or self:can(oid, "diseasePack")) or readData(ckey(oid, "aimed")) ~= 1 or
		not self:ready(oid, "dot") then
		return false
	end

	-- Mind is what heals and revives cost too: packs only above a floor (a revive and a pack, or two fifths of its mind)
	local creature = CreatureObject(pBot)

	if creature:getHAM(MIND) < math.max(self.mindCost.revive + self.mindCost.dot, creature:getMaxHAM(MIND) * self.dotMindFloor) then
		return false
	end

	-- ...and only while nobody needs a heal (a heal queued behind a pack waits out the pack's four seconds)
	for _, m in ipairs(g.members) do
		if m.player and not CreatureObject(m.p):isDead() and not CreatureObject(m.p):isIncapacitated() and
			math.min(self:ratio(m.p, HEALTH), self:ratio(m.p, ACTION)) < self.healBelow.fight + 0.1 then
			return false
		end
	end

	local coid = readData(ckey(oid, "target"))
	local pTarget = coid ~= 0 and self:validTarget(pBot, getSceneObject(coid), g, false) or nil
	local dist = pTarget ~= nil and BotJobs:distance(pBot, pTarget) or nil

	if pTarget == nil or dist == nil or dist > self.reach.dot then
		return false
	end

	local th = bot("botThreatOn", pBot, pTarget)

	if th == nil then
		return false
	end

	-- A new creature: count its resists afresh
	if readData(ckey(oid, "dotOid")) ~= coid then
		put(ckey(oid, "dotOid"), coid)

		for _, field in ipairs({"pT", "dT", "pA", "dA", "pP", "dP", "pS", "dS"}) do
			put(ckey(oid, field), 0)
		end
	end

	for _, kind in ipairs({
		{ability = "poisonPack", command = "applypoison", on = th.poisoned, immune = th.poisonImmune, tries = "pT", at = "pA",
			pending = "pP", said = "pS", line = "poisoned", name = "poison", single = self.packs.dotPoison, area = self.packs.dotPoisonArea},
		{ability = "diseasePack", command = "applydisease", on = th.diseased, immune = th.diseaseImmune, tries = "dT", at = "dA",
			pending = "dP", said = "dS", line = "diseased", name = "disease", single = self.packs.dotDisease, area = self.packs.dotDiseaseArea}}) do
		if self:can(oid, kind.ability) then
			if kind.on then
				-- It landed (and runs its course): say so once, forget the misses
				put(ckey(oid, kind.pending), 0)
				put(ckey(oid, kind.tries), 0)

				if readData(ckey(oid, kind.said)) == 0 then
					put(ckey(oid, kind.said), 1)
					self:callout(pBot, oid, kind.line, nil, now)
				end
			else
				-- A pack thrown a while ago and nothing on the creature: it resisted
				if readData(ckey(oid, kind.pending)) == 1 and now - readData(ckey(oid, kind.at)) >= self.dotResistAfter then
					put(ckey(oid, kind.pending), 0)
					put(ckey(oid, kind.tries), readData(ckey(oid, kind.tries)) + 1)
				end

				if not kind.immune and readData(ckey(oid, kind.tries)) < 2 and readData(ckey(oid, kind.pending)) == 0 then
					-- The pack's oid goes with the command: with both a single and an area pack of one kind in the pack Core3 takes
					-- the first of the kind otherwise ("health|<oid>": the pool, then the pack)
					local area = self:areaPack(pBot, oid, g, pTarget, kind, now)
					local template = area or kind.single
					local packOid = self:pack(pBot, oid, template)

					botEnqueue(pBot, kind.command, coid, packOid ~= 0 and ("health|" .. packOid) or "")
					put(ckey(oid, kind.at), now)
					put(ckey(oid, kind.pending), 1)
					put(ckey(oid, "dotReady"), getTimestampMilli() + self:waitDotMs(pBot))
					print("BotJobs: " .. self:name(oid) .. " " .. kind.command .. (area ~= nil and " (area)" or "") .. " " ..
						SceneObject(pTarget):getDisplayedName() .. " " .. coid .. ", " .. string.format("%.0f", dist) .. " m")

					return true
				end
			end
		end
	end

	return false
end

-- The area pack to throw at this target, or nil for the single one: areaMin or more creatures of the group (on the tank, with
-- one in the group) within areaRadius of the target, a pack in the bag, and no creature that isn't fighting the group (nor a
-- lair that isn't the fight) within areaSafe of the target
function BotCrew:areaPack(pBot, oid, g, pTarget, kind, now)
	if kind.area == nil or (bot("botFindPack", pBot, kind.area) or 0) == 0 then
		return nil
	end

	local field = self:creatureField(pBot, g, now, pTarget, 60)

	-- (a full scan may have left some out)
	if #field >= 40 then
		return nil
	end

	local tank = self:tankFor(oid, g)
	local tx, ty = SceneObject(pTarget):getWorldPositionX(), SceneObject(pTarget):getWorldPositionY()
	local n = 0

	for _, e in ipairs(field) do
		if e.pulled and (tank == nil or e.target == tank.oid) and math.sqrt((e.x - tx) ^ 2 + (e.y - ty) ^ 2) - e.r <= self.areaRadius then
			n = n + 1
		end
	end

	if n < self.areaMin then
		return nil
	end

	local lairs = self:lairsExcludingFight(pBot, oid, g, now)

	if self:blastUnsafe(tx, ty, self.areaSafe, field, lairs) then
		self:areaHeld(oid, "area pack", now)
		return nil
	end

	return kind.area
end

-- Core3's wait between pack throws: 12 s less up to 6 with healing range speed, at least 4, plus a margin
function BotCrew:waitDotMs(pBot)
	local delay = math.floor(12 - 6 * (CreatureObject(pBot):getSkillMod("healing_range_speed") or 0) / 100 + 0.5)

	return math.max(4, delay) * 1000 + self.treatmentMarginMs
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

	-- Harvesting and looting what the group killed (crew_loot.lua)
	if self:lootTurn(pBot, oid, g, pLeader, now) then
		return
	end

	local camp = self:activeCamp(g, pLeader)

	if readData(ckey(oid, "campWaitUntil")) ~= 0 and (camp ~= nil or now > readData(ckey(oid, "campWaitUntil"))) then
		deleteData(ckey(oid, "campWaitUntil"))

		if readStringData(ckey(oid, "order")) == "stay" then
			putString(ckey(oid, "order"), "follow")
		end
	end

	if camp ~= nil then
		self:inCamp(pBot, oid, g, pLeader, camp, now)
		return
	end

	if role == "entertainer" then
		self:perfPistol(pBot, oid)
	end

	if readData(ckey(oid, "inCamp")) == 1 then
		deleteData(ckey(oid, "inCamp"))
		deleteStringData(ckey(oid, "campTried"))
		self:standUp(pBot, oid)

		if role == "entertainer" then
			self:perfStop(pBot, oid, true)
		end

		if role == "medic" and BotDoctor ~= nil then
			BotDoctor:clear(oid)
		elseif role == "ranger" then
			-- Its camp goes when the group moves on (Core3 would abandon it a while later anyway)
			bot("botRemoveCamp", pBot)
		end
	end

	if readStringData(ckey(oid, "order")) ~= "stay" and readStringData(ckey(oid, "order")) ~= "campSearch" then
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

	if dist ~= nil and dist > self.campRange and os.time() < readData(gkey(leaderOid, "campGrace")) then
		-- Placed further out (a lair was too close here): it waits for the leader to walk over
		return nil
	end

	if dist == nil or dist > self.campRange then
		deleteData(gkey(leaderOid, "camp"))
		deleteData(gkey(leaderOid, "campGrace"))
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

	-- The entertainer performs for the camp instead of sitting at the fire
	if self:role(oid) == "entertainer" then
		self:stopMoving(pBot)
		self:perform(pBot, oid, now)
		return
	end

	if readData(ckey(oid, "sitting")) ~= 1 then
		self:stopMoving(pBot)
		botEnqueue(pBot, "sitserver", 0, "")
		put(ckey(oid, "sitting"), 1)
		put(ckey(oid, "sitUntil"), now + 3600)
	end
end

-- When the medic last took each member on at this camp, for each need (buffs and wounds apart, so the wounds don't
-- wait out campRetry behind the buffs): "<camp>;oidbuff=time,oidwounds=time"
function BotCrew:campTried(oid, campOid)
	local saved = readStringData(ckey(oid, "campTried"))
	local forCamp, list = saved:match("^(%d+);(.*)$")
	local tried = {}

	if tonumber(forCamp) ~= campOid then
		return tried
	end

	for memberNeed, at in string.gmatch(list, "(%d+%a*)=(%d+)") do
		tried[memberNeed] = tonumber(at)
	end

	return tried
end

function BotCrew:markTried(oid, campOid, memberOid, now, need)
	local tried = self:campTried(oid, campOid)
	local parts = {}

	-- (no need given: both)
	for _, kind in ipairs(need ~= nil and {need} or {"buff", "wounds"}) do
		tried[memberOid .. kind] = now
	end

	for member, at in pairs(tried) do
		table.insert(parts, member .. "=" .. at)
	end

	putString(ckey(oid, "campTried"), campOid .. ";" .. table.concat(parts, ","))
end

-- What a member needs from the medic: "buff" while one of the six pools has no enhancement on it (its maximum isn't
-- above its base), "wounds" when only wounds are left, else nil. (Lock-free getters, and botGetWounds as the doctor
-- uses it.)
-- Both needs, in order: {"buff", "wounds"}, either or neither
function BotCrew:needsAll(pPatient)
	local out = {}

	for pool = 0, 5 do
		if CreatureObject(pPatient):getMaxHAM(pool) <= CreatureObject(pPatient):getBaseHAM(pool) then
			table.insert(out, "buff")
			break
		end
	end

	for pool = 0, 5 do
		if botGetWounds(pPatient, pool) > 0 then
			table.insert(out, "wounds")
			break
		end
	end

	return out
end

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
		-- The first of its needs (buffs, then wounds) not tried lately: a buff that didn't take doesn't hold its wounds up
		local need = nil

		if m ~= nil and m.player and not CreatureObject(m.p):isDead() then
			for _, kind in ipairs(self:needsAll(m.p)) do
				if need == nil and now - (tried[m.oid .. kind] or 0) >= self.campRetry then
					need = kind
				end
			end
		end

		if need ~= nil then
			local dist = m.oid == oid and 0 or BotJobs:distance(pBot, m.p)
			local name = self:firstName(m.p)

			if dist ~= nil and dist <= BotDoctor.enhanceRange then
				self:markTried(oid, camp.oid, m.oid, now, need)

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

	local campOid, why, blocker = bot("botPlaceCamp", pBot, self:campKitOf(oid))

	campOid = campOid or 0

	if campOid == 0 then
		print("BotJobs: " .. self:name(oid) .. " couldn't place a camp here (" .. tostring(why) .. ")")
		local why = tostring(why or "")

		if why == "lair too close" or why == "camp too close" or why == "building too close" then
			self:startCampSearch(pBot, oid, pPlayer, channel, why, blocker)
			return
		end

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
	self:huntTallyAdd(pBot, "camps", 1)
	self:huntEvent(pBot, self:firstName(pBot) .. " set up a camp")

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

-- Camp search: the spot was refused for a lair (or a camp or building) nearby. The ranger walks straight away from
-- the thing in the way, campSearchStep metres at a time, and tries the camp at each stop, until one takes; then it
-- calls the group over. A fight, a new order or running out of steps ends the search.

function BotCrew:startCampSearch(pBot, oid, pPlayer, channel, why, blockerOid)
	local search = readData(ckey(oid, "campSearch")) + 1

	put(ckey(oid, "campSearch"), search)
	deleteData(ckey(oid, "campSearchDX"))
	deleteData(ckey(oid, "campSearchDY"))
	putString(ckey(oid, "campSearchOrder"), readStringData(ckey(oid, "order")))
	putString(ckey(oid, "order"), "campSearch")
	self:campSearchAim(pBot, oid, blockerOid, pPlayer)

	print("BotJobs: " .. self:name(oid) .. " looks for a clear spot to camp (" .. why .. ")")
	self:say(pBot, oid, SceneObject(pPlayer):getObjectID(), channel, why == "lair too close" and "campSearchLair" or "campSearch",
		self:firstName(pPlayer))
	self:campSearchNext(pBot, oid, SceneObject(pPlayer):getObjectID(), channel, search, 1)
end

-- Which way to walk: directly away from what blocked the camp (its position is known from botPlaceCamp's third
-- result); if that is unknown, away from the group's leader; else a random way. Kept as a unit vector in thousandths.
function BotCrew:campSearchAim(pBot, oid, blockerOid, pPlayer)
	local x, y = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY()
	local fromX, fromY = nil, nil
	local pBlocker = (blockerOid or 0) ~= 0 and getSceneObject(blockerOid) or nil

	if pBlocker ~= nil then
		fromX, fromY = SceneObject(pBlocker):getWorldPositionX(), SceneObject(pBlocker):getWorldPositionY()
	elseif readData(ckey(oid, "campSearchDX")) ~= 0 or readData(ckey(oid, "campSearchDY")) ~= 0 then
		-- Unknown blocker and a direction already: keep going the same way
		return
	elseif pPlayer ~= nil then
		fromX, fromY = SceneObject(pPlayer):getWorldPositionX(), SceneObject(pPlayer):getWorldPositionY()
	end

	local dx, dy = 0, 0

	if fromX ~= nil then
		dx, dy = x - fromX, y - fromY
	end

	local length = math.sqrt(dx * dx + dy * dy)

	if length < 1 then
		local rad = math.rad(getRandomNumber(0, 359))

		dx, dy, length = math.sin(rad), math.cos(rad), 1
	end

	put(ckey(oid, "campSearchDX"), dx / length * 1000)
	put(ckey(oid, "campSearchDY"), dy / length * 1000)
end

-- Spot `try`: campSearchStep metres on from where the bot stands now, along the aim
function BotCrew:campSearchSpot(pBot, oid)
	local x, y = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY()

	return x + readData(ckey(oid, "campSearchDX")) / 1000 * self.campSearchStep,
		y + readData(ckey(oid, "campSearchDY")) / 1000 * self.campSearchStep
end

function BotCrew:campSearchNext(pBot, oid, playerOid, channel, search, try)
	if try > self.campSearchSteps then
		self:endCampSearch(pBot, oid)
		self:say(pBot, oid, playerOid, channel, "campSearchFail", self:firstName(getSceneObject(playerOid)))
		print("BotJobs: " .. self:name(oid) .. " found no spot to camp")
		return
	end

	local x, y = self:campSearchSpot(pBot, oid)
	local z = getTerrainHeight ~= nil and getTerrainHeight(pBot, x, y) or SceneObject(pBot):getWorldPositionZ()

	bot("botMoveTo", pBot, x, z, y, 0, "run")
	createEvent(self.campSearchPollMs, "BotCrew", "campSearchCheck", pBot,
		packArgs(readData(key(oid, "gen")), search, try, playerOid, channel, os.time()))
end

-- Every moment on the way: there (or stuck, or too long) → try the camp
function BotCrew:campSearchCheck(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local search, try, playerOid, channel, started = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), a[5], tonumber(a[6])

	if readData(ckey(oid, "campSearch")) ~= search or readStringData(ckey(oid, "order")) ~= "campSearch" then
		return
	end

	local g = self:group(pBot)

	if g == nil or self:groupFighting(g) or CreatureObject(pBot):isInCombat() or CreatureObject(pBot):isDead() then
		self:endCampSearch(pBot, oid)
		return
	end

	local move = bot("botMoveState", pBot) or {}

	if move.state == "goto" and not move.stuck and os.time() - started < self.campSearchWalk then
		createEvent(self.campSearchPollMs, "BotCrew", "campSearchCheck", pBot, args)
		return
	end

	self:stopMoving(pBot)

	local campOid, why, blocker = bot("botPlaceCamp", pBot, self:campKitOf(oid))

	if (campOid or 0) == 0 then
		print("BotJobs: " .. self:name(oid) .. " camp spot " .. try .. ": " .. tostring(why))

		-- Away from whatever is in the way now (it may be another thing than the first)
		if (blocker or 0) ~= 0 then
			self:campSearchAim(pBot, oid, blocker, nil)
		end

		self:campSearchNext(pBot, oid, playerOid, channel, search, try + 1)
		return
	end

	local pLeader = self:leaderOf(pBot, oid, g, os.time()) or getSceneObject(playerOid)
	local leaderOid = SceneObject(pLeader):getObjectID()

	put(gkey(leaderOid, "camp"), campOid)
	put(gkey(leaderOid, "campGrace"), os.time() + self.campSearchGrace)
	put(ckey(oid, "offerAt"), os.time())
	self:endCampSearch(pBot, oid)

	-- Where it is from the leader
	local dx = SceneObject(pBot):getWorldPositionX() - SceneObject(pLeader):getWorldPositionX()
	local dy = SceneObject(pBot):getWorldPositionY() - SceneObject(pLeader):getWorldPositionY()
	local metres = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
	local way = direction(math.deg(math.atan(dx, dy)))

	print("BotJobs: " .. self:name(oid) .. " placed a camp (" .. campOid .. ") " .. metres .. " m " .. way .. " of the leader, spot " .. try)
	self:huntTallyAdd(pBot, "camps", 1)
	self:huntEvent(pBot, self:firstName(pBot) .. " set up a camp " .. metres .. " m " .. way .. " of " .. self:firstName(pLeader) ..
		" (a lair or building was in the way)")
	self:say(pBot, oid, playerOid, channel, "campUpThere", self:firstName(pLeader), {metres = tostring(metres), way = way})
	-- It waits by its fire for the group
	putString(ckey(oid, "order"), "stay")
	putString(ckey(oid, "campSearchOrder"), "")
	put(ckey(oid, "campWaitUntil"), os.time() + self.campSearchGrace)
end

function BotCrew:endCampSearch(pBot, oid)
	local before = readStringData(ckey(oid, "campSearchOrder"))

	deleteData(ckey(oid, "campSearchDX"))
	deleteData(ckey(oid, "campSearchDY"))

	put(ckey(oid, "campSearch"), readData(ckey(oid, "campSearch")) + 1)

	if readStringData(ckey(oid, "order")) == "campSearch" then
		putString(ckey(oid, "order"), before ~= "" and before or "follow")
	end

	self:stopMoving(pBot)
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
-- ...and spatialGroup tells groupAddressed that the line was spoken out loud, not in group chat
local spatialHeard = false

local STARTERS = {harvest = {"harvest"}, loot = {"loot"}}
local NEGATIONS = {["don't"] = true, dont = true, ["not"] = true, never = true, no = true, stop = true, nor = true}
local FILLER = {just = true, ever = true, yet = true, go = true, to = true, please = true, you = true, now = true}
-- Words that open a clause without being the order ("ok guys, kill it")
local LEADIN = {hey = true, yo = true, ok = true, okay = true, alright = true, right = true, guys = true, all = true,
	everyone = true, team = true, crew = true, now = true, so = true, please = true, just = true, ["and"] = true, ["then"] = true}

-- Does the text (wordsOf) start with this intent's word?
function BotCrew:startsWith(t, intent)
	for _, word in ipairs(STARTERS[intent] or {}) do
		if t:find("^ " .. word .. " ") then
			return true
		end
	end

	return false
end

-- The clauses of a line (wordsOf each), without the words that open them ("ok guys, kill it" -> " kill it ")
local function clausesOf(text)
	local out = {}

	for clause in tostring(text or ""):lower():gmatch("[^%.!%?;,:]+") do
		local t = wordsOf(clause:match("^%s*(.-)%s*$"))

		while true do
			local first, rest = t:match("^ (%S+)( .*)$")

			if first == nil or not LEADIN[first] then
				break
			end

			t = rest
		end

		table.insert(out, t)
	end

	return out
end

-- Is there a negation just before position at of t? ("don't attack it", "never just attack", not "nevermind" or "stopped")
local function negatedAt(t, at)
	local before = {}

	for word in t:sub(1, at - 1):gmatch("%S+") do
		table.insert(before, word)
	end

	local last, previous = before[#before], before[#before - 1]

	return last ~= nil and (NEGATIONS[last] == true or (FILLER[last] == true and previous ~= nil and NEGATIONS[previous] == true))
end

-- An order to attack: one of the attack phrases not preceded by a negation, or a clause that starts with the verb; and not
-- called off ("hold fire", "stop attacking")
function BotCrew:attackOrder(text, t)
	if hasAny(t, self.words.notAttack) then
		return false
	end

	for _, phrase in ipairs(self.words.attack) do
		local from = 1

		while true do
			local at = t:find(phrase, from, true)

			if at == nil then
				break
			end

			if not negatedAt(t, at) then
				return true
			end

			from = at + 1
		end
	end

	for _, clause in ipairs(clausesOf(text)) do
		for _, word in ipairs(self.words.attackStart) do
			if clause:find("^ " .. word .. " ") then
				return true
			end
		end
	end

	return false
end

-- Harvest type talk (Phase 7b): "harvest hide", "skin them for bone", "meat only", "just the hides", "bone from now on";
-- and back to the ranger's own pick: "harvest anything", "your pick", "whatever's best"
local HARVEST_NOUNS = {hide = "hide", hides = "hide", leather = "hide", pelt = "hide", pelts = "hide", meat = "meat",
	meats = "meat", steak = "meat", steaks = "meat", flesh = "meat", bone = "bone", bones = "bone"}
local HARVEST_VERBS = {harvest = true, harvesting = true, harvested = true, skin = true, skinning = true, skinned = true,
	carve = true, carving = true, butcher = true, butchering = true, take = true, taking = true, get = true, grab = true,
	gather = true, collect = true, keep = true}
-- ...the verbs that are only the harvest's own (a reset needs one of these, or harvest talk just before)
local HARVEST_WORDS = {harvest = true, harvesting = true, harvested = true, skin = true, skinning = true, skinned = true,
	carve = true, carving = true, butcher = true, butchering = true}
-- ...a reset needs a harvest word in the line ("harvest anything", "skin your pick"): "your call" alone is about anything.
-- The brain (the bridge reads the exchange before) carries a bare "your pick" after harvest talk as "harvest:any"
local HARVEST_RESET = {" anything ", " any ", " whatever ", " the best "}
local HARVEST_RESET_ALONE = {" whatever's best ", " whatevers best ", " whatever is best ", " whatever s best ", " your pick ", " your choice ",
	" you choose ", " you pick ", " pick for yourself ", " choose for yourself ", " up to you ", " own pick ", " best stats ",
	" your call "}
local QUESTION_FIRST = {what = true, whats = true, ["what's"] = true, which = true, are = true, is = true, ["do"] = true,
	does = true, did = true, why = true, how = true, who = true, where = true, when = true}
-- A question about the harvest: "what are you harvesting?", "what are we skinning for", "harvesting what?"
function BotCrew:harvestQuestion(text)
	local t = wordsOf(text)
	local hasVerb = false

	for word in t:gmatch("%S+") do
		if HARVEST_WORDS[word] then
			hasVerb = true
			break
		end
	end

	if not hasVerb then
		return false
	end

	local first = t:match("^ (%S+)")

	return (first ~= nil and QUESTION_FIRST[first] == true) or t:find(" what ", 1, true) ~= nil or t:find(" which ", 1, true) ~= nil or
		t:find(" whats ", 1, true) ~= nil or t:find(" what's ", 1, true) ~= nil
end

-- The kind a line asks the ranger to harvest ("hide", "meat" or "bone"), "any" for its own pick again, or nil when the
-- line says neither (or asks a question, or says not to)
function BotCrew:harvestKindOf(text)
	if self:harvestQuestion(text) then
		return nil
	end

	local t = wordsOf(text)
	local words = {}

	for word in t:gmatch("%S+") do
		table.insert(words, word)
	end

	local verb, harvestVerb, restricted, kinds, count, kind = false, false, false, {}, 0, nil

	for i, word in ipairs(words) do
		if HARVEST_VERBS[word] then
			verb = true
			harvestVerb = harvestVerb or HARVEST_WORDS[word] == true

			-- "don't harvest hide", "stop skinning": not an order
			local p1, p2 = words[i - 1], words[i - 2]

			if (p1 ~= nil and NEGATIONS[p1]) or (p2 ~= nil and NEGATIONS[p2] and FILLER[p1]) then
				return nil
			end
		elseif HARVEST_NOUNS[word] ~= nil and kinds[HARVEST_NOUNS[word]] == nil then
			kinds[HARVEST_NOUNS[word]] = true
			count = count + 1
			kind = HARVEST_NOUNS[word]
		elseif word == "only" or word == "just" or word == "exclusively" then
			restricted = true
		end
	end

	-- Back to its own pick, with a harvest word in the line
	if count == 0 and harvestVerb then
		for _, list in ipairs({HARVEST_RESET, HARVEST_RESET_ALONE}) do
			for _, phrase in ipairs(list) do
				if t:find(phrase, 1, true) ~= nil then
					return "any"
				end
			end
		end
	end

	if count == 1 and (verb or restricted or t:find(" from now on ", 1, true) ~= nil) then
		return kind
	end

	return nil
end

-- What a line is about for routing: the intent in its words, or "harvest" for a question about the harvest (the ranger
-- answers it)
function BotCrew:talkIntent(text)
	return self:intentFor(text, nil) or (self:harvestQuestion(text) and "harvest" or nil)
end

-- The intent in the words for a role (nil: any role)
function BotCrew:intentFor(text, role)
	local t = wordsOf(text)

	for _, intent in ipairs({"makeroom", "call", "fatigue", "perfstop", "music", "dance", "home", "attack", "follow", "stay", "join", "camp", "track", "buff", "wounds", "harvest", "loot"}) do
		-- A line that starts with the word is an order too ("loot", "harvest?", "loot, please", "kill!")
		if (intent == "attack" and self:attackOrder(text, t)) or
			(intent ~= "attack" and (hasAny(t, self.words[intent]) or self:startsWith(t, intent) or
				(intent == "harvest" and self:harvestKindOf(text) ~= nil))) then
			local owner = self.owners[intent]

			if owner == nil or role == nil or owner == role or self.anyone[intent] == true then
				return intent
			end
		end
	end

	return nil
end

function BotCrew:intent(text)
	lastHeard = text
	spatialHeard = false

	return self:intentFor(text, self.crewRole)
end

local ORDERS = {join = true, follow = true, stay = true, home = true, attack = true}

function BotCrew:isAction(intent)
	return intent ~= nil and (ORDERS[intent] == true or self.owners[intent] ~= nil or self.anyone[intent] == true)
end

-- The brain's action (reply line 4), for this role
function BotCrew:allowed(action)
	-- "harvest:hide": the bridge's harvest with the type asked for ("meat", "hide", "bone", "any")
	local base, kind = tostring(action):match("^(%a+):(%a+)$")

	if base == "harvest" and (kind == "meat" or kind == "hide" or kind == "bone" or kind == "any") and self:allowed(base) ~= nil then
		return action
	end

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

	if self.anyone[action] then
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
	elseif action == "harvest" or action:find("^harvest:") then
		-- (the ranger works it in its loot turn; whoever answered scans and says how many)
		self:harvestAct(pBot, oid, pPlayer, action:match("^harvest:(%a+)$"), channel, brainLine)
	elseif action == "loot" then
		self:lootRequest(pBot, oid, pPlayer, "loot", channel, brainLine)
	elseif (action == "buff" or action == "wounds") and self:role(oid) == "medic" then
		self:medicBuff(pBot, oid, pPlayer, action, channel, brainLine)
	end
end

-- "harvest ...": a type asked for (in the action, or in the words) is kept for the hunt; then the scan, as always
function BotCrew:harvestAct(pBot, oid, pPlayer, kindArg, channel, brainLine)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local g = self:group(pBot)
	local kind = kindArg or self:harvestKindOf(readStringData(ckey(oid, "heard")))

	if kind ~= nil and g ~= nil and g.byOid[playerOid] ~= nil and g.leader ~= nil then
		self:harvestSetKind(pBot, oid, g.leader.oid, kind, playerOid, channel, brainLine)
		brainLine = brainLine or "kind"
	end

	self:lootRequest(pBot, oid, pPlayer, "harvest", channel, brainLine)
end

-- The hunt's harvest type: kept under the leader until the group breaks up or the hunt ends; "any" is the ranger's pick
function BotCrew:harvestSetKind(pBot, oid, leaderOid, kind, playerOid, channel, brainLine)
	local name = self:firstName(getSceneObject(playerOid))

	deleteData(gkey(leaderOid, "harvestNoKindSaid"))

	if kind == "any" then
		deleteStringData(gkey(leaderOid, "harvestKind"))
		deleteStringData(gkey(leaderOid, "harvestSaid"))
		self:huntEvent(pBot, "Told the ranger to choose its own harvest again")
		print("BotJobs: " .. self:name(oid) .. " harvests by its own pick again")

		if brainLine == nil then
			self:say(pBot, oid, playerOid, channel, "harvestAny", name)
		end

		return
	end

	putString(gkey(leaderOid, "harvestKind"), kind)
	self:huntEvent(pBot, "Asked for " .. kind .. " only")
	print("BotJobs: " .. self:name(oid) .. " harvests " .. kind .. " only")

	if brainLine == nil then
		self:say(pBot, oid, playerOid, channel, "harvestKind", name, {kind = kind, Kind = (kind:gsub("^%l", string.upper))})
	end
end

-- Extra fields for the brain's request (BotJobs:ask): grouped is 1 while this bot is in a player's group
function BotCrew:requestFields(pBot, oid, playerOid)
	local fields = {grouped = (pBot ~= nil and CreatureObject(pBot):isGrouped()) and 1 or 0}

	if pBot == nil then
		return fields
	end

	-- What it holds (the brain must not claim missions it doesn't have): "none" or "2: a womp rat lair east, ..."
	local held = bot("botMissions", pBot)

	if held ~= nil then
		local parts = {}

		for _, m in ipairs(held) do
			table.insert(parts, ((tostring(m.target or "lair") .. " " .. tostring(m.direction or "")):gsub("%s+$", "")))
		end

		fields.missions = #parts == 0 and "none" or (#parts .. ": " .. table.concat(parts, ", "))
	end

	-- What the speaker has targeted that this bot may attack, for "attack my target": its name, or "none"
	local pPlayer = playerOid ~= nil and getSceneObject(playerOid) or nil
	local g = pPlayer ~= nil and self:group(pBot) or nil

	if g ~= nil and g.byOid[playerOid] ~= nil then
		local targetOid = self:attackTarget(pBot, pPlayer, g)

		fields.attackTarget = targetOid ~= 0 and (SceneObject(getSceneObject(targetOid)):getDisplayedName() or "a creature") or "none"
	end

	fields.situation = self:situation(pBot, oid)

	-- What the ranger harvests, for the brain's talk about it
	local harvestLeader = pPlayer ~= nil and self:group(pBot) ~= nil and self:harvestLeader(pBot, oid) or 0

	if harvestLeader ~= 0 then
		fields.harvest = self:harvestFacts(harvestLeader)
	end

	local leaderOid, huntAt = self:huntOf(pBot)

	if leaderOid ~= nil then
		fields.hunt = leaderOid .. "-" .. huntAt
		fields.huntLog = self:huntLogText(leaderOid)
		fields.huntTally = self:huntTally(leaderOid, self:group(pBot))
	end

	return fields
end

-- The hunt log: what was said on this hunt, by the humans and every crew bot, in any channel, so each bot's brain
-- knows the whole conversation (and the job lines it spoke itself: "a lair's too close"). A hunt is the time a crew
-- bot is in a group with this leader; it starts afresh after huntQuiet seconds with nothing said.

BotCrew.huntQuiet = 1800
BotCrew.huntLogSize = 24
BotCrew.huntLineChars = 240

-- The leader's oid and the hunt's start, or nil when the bot isn't grouped
function BotCrew:huntOf(pBot)
	local g = self:group(pBot)

	if g == nil or g.leader == nil then
		return nil
	end

	local leaderOid = g.leader.oid
	local now = os.time()
	local huntAt = readData(gkey(leaderOid, "huntAt"))

	if huntAt == 0 or now - readData(gkey(leaderOid, "huntSeen")) > self.huntQuiet then
		huntAt = now
		put(gkey(leaderOid, "huntAt"), huntAt)
		deleteStringData(gkey(leaderOid, "huntLog"))
		deleteStringData(gkey(leaderOid, "killsPending"))
		self:harvestClear(leaderOid)

		for _, field in ipairs(self.huntTallyFields) do
			deleteData(gkey(leaderOid, field))
		end
	end

	put(gkey(leaderOid, "huntSeen"), now)

	return leaderOid, huntAt
end

function BotCrew:huntNote(pBot, who, text)
	local leaderOid = self:huntOf(pBot)

	if leaderOid == nil or who == nil or text == nil then
		return
	end

	text = tostring(text):gsub("[%c\t]", " "):sub(1, self.huntLineChars)

	if text:match("^%s*$") then
		return
	end

	local now = os.time()
	local entries = {}

	for line in readStringData(gkey(leaderOid, "huntLog")):gmatch("[^\n]+") do
		table.insert(entries, line)
	end

	-- Every crew bot hears a group line: it goes in once
	local last = entries[#entries]

	if last ~= nil then
		local t, lastWho, lastText = last:match("^(%d+)\t([^\t]*)\t(.*)$")

		if lastWho == who and lastText == text and now - (tonumber(t) or 0) <= 5 then
			return
		end
	end

	table.insert(entries, now .. "\t" .. who .. "\t" .. text)

	while #entries > self.huntLogSize do
		table.remove(entries, 1)
	end

	putString(gkey(leaderOid, "huntLog"), table.concat(entries, "\n"))
end

-- The hunt's running numbers (the leader's group): kills, lairs destroyed, corpses looted, carcasses harvested, crew
-- deaths, camps. Reset with the log when a new hunt starts.
BotCrew.huntTallyFields = {"kills", "lairs", "looted", "harvested", "deaths", "camps"}

function BotCrew:huntTallyAdd(pBot, field, n)
	local leaderOid = self:huntOf(pBot)

	if leaderOid ~= nil then
		put(gkey(leaderOid, field), readData(gkey(leaderOid, field)) + (n or 1))
	end
end

-- An event of the hunt, as a log entry from "(hunt)" (not anyone's talk)
function BotCrew:huntEvent(pBot, text)
	self:huntNote(pBot, "(hunt)", text)
end

-- A corpse of the group's seen for the first time: a kill. The log gets them in one line per fight (huntKillsFlush)
function BotCrew:huntKill(pBot, name)
	local leaderOid = pBot ~= nil and self:huntOf(pBot) or nil

	if leaderOid == nil then
		return
	end

	put(gkey(leaderOid, "kills"), readData(gkey(leaderOid, "kills")) + 1)

	local pending = readStringData(gkey(leaderOid, "killsPending"))
	local bare = (tostring(name or "creature"):gsub("^[Aa]n? ", ""):gsub("^[Tt]he ", ""):gsub("[%%|]", ""))

	writeStringData(gkey(leaderOid, "killsPending"), pending == "" and bare or (pending .. "|" .. bare))
end

function BotCrew:huntKillsFlush(pBot, leaderOid)
	local pending = readStringData(gkey(leaderOid, "killsPending"))

	if pending == "" then
		return
	end

	deleteStringData(gkey(leaderOid, "killsPending"))

	local counts, order, total = {}, {}, 0

	for name in pending:gmatch("[^|]+") do
		if counts[name] == nil then
			counts[name] = 0
			table.insert(order, name)
		end

		counts[name] = counts[name] + 1
		total = total + 1
	end

	local parts = {}

	for i = 1, math.min(#order, 4) do
		table.insert(parts, order[i] .. (counts[order[i]] > 1 and (" x" .. counts[order[i]]) or ""))
	end

	if #order > 4 then
		table.insert(parts, "others")
	end

	self:huntEvent(pBot, "Killed " .. total .. ": " .. table.concat(parts, ", "))
end

-- "3 lairs done, 2 missions left, 41 kills, 12 corpses looted": for the brain, next to the log
function BotCrew:huntTally(leaderOid, g)
	local function count(field)
		return readData(gkey(leaderOid, field))
	end

	local held = 0

	for _, m in ipairs(g ~= nil and g.crew or {}) do
		held = held + readData(ckey(m.oid, "mHeldN"))
	end

	-- ...and the humans' own (crew_missions.lua)
	for _, m in ipairs(g ~= nil and g.humans or {}) do
		held = held + readData("crew:human:" .. m.oid .. ":mHeldN")
	end

	local parts = {}

	local function add(n, one, many)
		table.insert(parts, n .. " " .. (n == 1 and one or many))
	end

	if count("lairs") > 0 or held > 0 then
		add(count("lairs"), "lair done", "lairs done")
		add(held, "mission left", "missions left")
	end

	if count("kills") > 0 then
		add(count("kills"), "kill", "kills")
	end

	if count("looted") > 0 then
		add(count("looted"), "corpse looted", "corpses looted")
	end

	if count("harvested") > 0 then
		add(count("harvested"), "carcass harvested", "carcasses harvested")
	end

	if count("deaths") > 0 then
		add(count("deaths"), "crew death", "crew deaths")
	end

	if count("camps") > 0 then
		add(count("camps"), "camp", "camps")
	end

	return table.concat(parts, ", ")
end

-- For the brain: "[3 min ago] Eefo: make us a camp" per line, oldest first
function BotCrew:huntLogText(leaderOid)
	local now = os.time()
	local out = {}

	for line in readStringData(gkey(leaderOid, "huntLog")):gmatch("[^\n]+") do
		local t, who, text = line:match("^(%d+)\t([^\t]*)\t(.*)$")

		if t ~= nil then
			local ago = math.floor((now - tonumber(t)) / 60)

			table.insert(out, "[" .. (ago < 1 and "just now" or (ago .. " min ago")) .. "] " .. who .. ": " .. text)
		end
	end

	return table.concat(out, "\n")
end

function BotCrew:onSaid(pBot, oid, playerOid, channel, line)
	if CreatureObject(pBot):isGrouped() then
		self:huntNote(pBot, self:firstName(pBot), line)
	end
end

-- Where the bot is and what it's doing, in words, for the brain ("out in the wild on Tatooine, about 2 km north-east
-- of Mos Eisley; in a fight with a womp rat")

-- The main towns, roughly (their centres), to say where the wild is
BotCrew.towns = {
	tatooine = {{"Mos Eisley", 3500, -4800}, {"Mos Espa", -2900, 2150}, {"Bestine", -1290, -3590},
		{"Anchorhead", 40, -5340}, {"Mos Entha", 1300, 3100}, {"Mos Taike", 3800, 2300}, {"Wayfar", -5200, -6500}},
	naboo = {{"Theed", -4850, 4150}, {"Keren", 1650, 2650}, {"Moenia", 4800, -4800}, {"Kaadara", 5200, 6700},
		{"Deeja Peak", 5000, -1500}, {"Lake Retreat", -5500, -50}, {"Varenhal", -3291, 4911}},
	corellia = {{"Coronet", -150, -4700}, {"Tyrena", -5100, -2300}, {"Kor Vella", -3300, 3200},
		{"Doaba Guerfel", 3300, 5400}, {"Bela Vistal", 6700, -5700}, {"Vreni Island", -5500, -6200}},
}

function BotCrew:situation(pBot, oid)
	local planet = SceneObject(pBot):getZoneName()
	local x, y = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY()
	local nearest, nearestDist, dx, dy = nil, nil, 0, 0

	for _, town in ipairs(self.towns[planet] or {}) do
		local d = math.sqrt((x - town[2]) ^ 2 + (y - town[3]) ^ 2)

		if nearestDist == nil or d < nearestDist then
			nearest, nearestDist, dx, dy = town[1], d, x - town[2], y - town[3]
		end
	end

	local planetName = planet:gsub("^%l", string.upper)
	local where
	local station = self:station(oid)

	if SceneObject(pBot):getParentID() ~= 0 then
		if station ~= nil and SceneObject(pBot):getParentID() == (station.cell or 0) then
			where = "in the Mos Eisley cantina, your usual spot"
		elseif nearest ~= nil and nearestDist < 800 then
			where = "indoors in " .. nearest .. " on " .. planetName
		else
			where = "indoors somewhere on " .. planetName
		end
	elseif nearest ~= nil and nearestDist < 600 then
		where = "in " .. nearest .. " on " .. planetName .. ", outdoors"
	elseif nearest ~= nil then
		local km = nearestDist / 1000
		local far = km < 1.5 and (math.floor(nearestDist / 100 + 0.5) * 100 .. " m") or (string.format("%.0f", km) .. " km")

		where = "out in the wild on " .. planetName .. ", about " .. far .. " " .. direction(math.deg(math.atan(dx, dy))) ..
			" of " .. nearest
	else
		where = "out in the wild on " .. planetName
	end

	local doing = {}
	local g = self:group(pBot)

	-- (CreatureObject(p) calls inline: the wrapper may be shared, and group() made others)
	if CreatureObject(pBot):isRidingMount() then
		table.insert(doing, "riding your swoop")
	end

	local pTarget = getSceneObject(readData(ckey(oid, "target")))

	if pTarget ~= nil and CreatureObject(pBot):isInCombat() then
		table.insert(doing, "in a fight with " .. SceneObject(pTarget):getDisplayedName())
	elseif g ~= nil and self:activeCamp(g, g.leader and g.leader.p) ~= nil then
		table.insert(doing, "resting at the ranger's camp")
	end

	if g ~= nil and g.leader ~= nil and g.leader.oid ~= oid then
		local d = BotJobs:distance(pBot, g.leader.p)

		if d ~= nil and d > 20 then
			table.insert(doing, string.format("%s is %d m away", self:firstName(g.leader.p), math.floor(d + 0.5)))
		elseif d ~= nil then
			table.insert(doing, "with " .. self:firstName(g.leader.p))
		end
	end

	if #doing > 0 then
		where = where .. "; " .. table.concat(doing, ", ")
	end

	return where
end

function BotCrew:onSpoken(pBot, oid, pSpeaker, channel, text)
	putString(ckey(oid, "heard"), lastHeard or "")
	put(ckey(oid, "forGroup"), lastForGroup and 1 or 0)
	lastHeard, lastForGroup = nil, false

	-- On a hunt, what the humans say goes in the hunt log (every crew bot hears group chat; it goes in once)
	if text ~= nil and CreatureObject(pBot):isGrouped() and self:human(pSpeaker) then
		self:huntNote(pBot, self:firstName(pSpeaker), text)
	end

	-- "Make room" (Phase 8): the commando gives its place up so the other human fits in the group
	if text ~= nil and self:role(oid) == "commando" and CreatureObject(pBot):isGrouped() and self:makeRoomWanted(text) then
		local g = self:group(pBot)
		local speakerOid = SceneObject(pSpeaker):getObjectID()

		if g ~= nil and g.byOid[speakerOid] ~= nil and g.byOid[speakerOid].human then
			self:makeRoom(pBot, oid, pSpeaker, channel)

			return true
		end
	end

	-- "Crew, come to me" (Phase 8): by tell, or in group chat from a human far from some of the crew; every free crew bot comes
	if text ~= nil and (channel == "tell" or channel == "group") and self:human(pSpeaker) and self:callWanted(text) then
		self:crewCall(pBot, oid, pSpeaker, channel)

		return true
	end

	-- The entertainer's own: music, dancing, battle fatigue (Phase 8)
	if text ~= nil and self:role(oid) == "entertainer" and self:entertainerAsk(pBot, oid, pSpeaker, channel, text) then
		return true
	end

	-- "What are you harvesting?" the ranger answers from its state (crew_loot.lua), in any channel it was asked in
	if text ~= nil and self:role(oid) == "ranger" and CreatureObject(pBot):isGrouped() and self:harvestQuestion(text) then
		local g = self:group(pBot)
		local speakerOid = SceneObject(pSpeaker):getObjectID()

		if g ~= nil and g.byOid[speakerOid] ~= nil and g.byOid[speakerOid].human then
			self:harvestAnswer(pBot, oid, speakerOid, channel, self:firstName(pSpeaker))

			return true
		end
	end

	-- "Hand it over" by tell or out loud to a bot that isn't grouped any more (holding what it gathered; crew_loot.lua)
	if channel ~= "group" and text ~= nil and not CreatureObject(pBot):isGrouped() and self:handoverWanted(text) then
		if self:handoverUngrouped(pBot, oid, pSpeaker, channel, text) then
			return true
		end
	end

	-- "Hand it over" by tell or out loud to this bot (group chat goes through groupAddressed, crew_loot.lua)
	if channel ~= "group" and text ~= nil and self:handoverWanted(text) then
		local g = self:group(pBot)

		if g ~= nil and g.byOid[SceneObject(pSpeaker):getObjectID()] ~= nil then
			local _, count = self:goodsOf(pBot, oid)

			if count == 0 then
				self:say(pBot, oid, SceneObject(pSpeaker):getObjectID(), channel, "handoverNone", self:firstName(pSpeaker))
				return true
			end

			if self:handoverSpoken(pBot, oid, pSpeaker, channel, text, g) then
				return true
			end
		end
	end

	-- Missions (crew_missions.lua) are the crew's own business: the language model isn't asked
	if self:missionHeard(pBot, oid, pSpeaker, channel, text) then
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

-- Out-loud talk (spatial chat) that names nobody and isn't aimed at anyone else: a grouped crew bot takes it as group
-- talk when a human of its own group says it within spatialRange metres. groupAddressed then picks the one crew
-- member who answers for the crew, among those within range of the speaker (those are the ones who heard it).
function BotCrew:spatialGroup(pBot, pSpeaker, text)
	spatialHeard = false

	local g = self:group(pBot)

	if g == nil then
		return false
	end

	local speakerOid = SceneObject(pSpeaker):getObjectID()
	local member = g.byOid[speakerOid]

	if member == nil or not member.human then
		return false
	end

	-- Talking to someone else: a member of the group (the targeted crew bot answers alone, as addressed; or the other
	-- human), a player or bot outside it, a crowd NPC. A creature they fought (the target stays after the kill) doesn't
	-- count.
	local target = CreatureObject(pSpeaker):getTargetID()

	if target ~= 0 then
		if g.byOid[target] ~= nil then
			return false
		end

		local pTarget = getSceneObject(target)

		if pTarget ~= nil and (SceneObject(pTarget):isPlayerCreature() or readStringData("lc:npc:" .. target .. ":city") ~= "") then
			return false
		end
	end

	local dist = BotJobs:distance(pBot, pSpeaker)

	if dist == nil then
		return false
	end

	-- Within earshot of the speaker, or the one who does this work (a ranger asked to camp, from further off)
	local owner = self.owners[self:talkIntent(text) or ""]

	if dist > self.spatialRange and not (owner ~= nil and owner == self:role(SceneObject(pBot):getObjectID()) and dist <= self.spatialHear) then
		return false
	end

	-- Naming someone else who is near (the town doctor, a crowd NPC, another bot or player): not for the crew
	if self:namesOther(pSpeaker, g, text) then
		return false
	end

	spatialHeard = true

	return true
end

-- Does the text name (by first name) a person near the speaker who isn't in the group?
function BotCrew:namesOther(pSpeaker, g, text)
	local words = " " .. (tostring(text or ""):lower():gsub("[^%a]", " ")) .. " "
	local speakerOid = SceneObject(pSpeaker):getObjectID()

	for _, p in ipairs(bot("botPeopleNear", pSpeaker, self.spatialHear) or {}) do
		if p.oid ~= speakerOid and g.byOid[p.oid] == nil then
			local first = (tostring(p.name or ""):match("^(%S+)") or ""):lower():gsub("[^%a]", "")

			if #first >= 3 and words:find(" " .. first .. " ", 1, true) ~= nil then
				return true
			end
		end
	end

	return false
end

-- Group chat that names nobody (BotJobs:heard asks): a camp the ranger offered, accepted, is placed at once; work
-- that's one member's goes to that member; anything else, the first crew member in the group answers for everyone
-- (and its orders go to the others too)
function BotCrew:groupAddressed(pBot, pSpeaker, text)
	lastForGroup = false

	local spatial = spatialHeard

	spatialHeard = false

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

	-- Asked for the loot: the bots that hold some hand it over, no brain needed (crew_loot.lua)
	if self:handoverWanted(text) then
		self:handoverSpoken(pBot, oid, pSpeaker, "group", text, g)
		return false
	end

	local role = self:role(oid)
	local intent = self:talkIntent(text)

	-- (the camp offer's "yes" in group chat; said out loud it has to be aimed at the ranger, which it isn't here)
	if role == "ranger" and not spatial and os.time() - readData(ckey(oid, "offerAt")) <= self.campOfferWindow and
		readData(ckey(oid, "offerAt")) ~= 0 and intent ~= "home" and self:affirmed(text) then
		put(ckey(oid, "offerAt"), os.time() - self.campOfferWindow - 1)
		self:tryCamp(pBot, oid, pSpeaker, "group", nil)
		return false
	end

	-- Said out loud: the crew within earshot of the speaker (the same for every bot that heard)
	local pool = g.crew

	if spatial then
		pool = {}

		for _, m in ipairs(g.crew) do
			local d = m.oid == oid and BotJobs:distance(pBot, pSpeaker) or BotJobs:distance(m.p, pSpeaker)

			-- (the owner of the work heard it from a little further off)
			if d ~= nil and (d <= self.spatialRange or (m.job == self.owners[intent or ""] and d <= self.spatialHear)) then
				table.insert(pool, m)
			end
		end
	end

	local owner = self.owners[intent or ""]

	if owner ~= nil then
		-- (the one who does the work, if it can: a dead ranger doesn't answer for the harvest, the first in earshot does)
		for _, m in ipairs(pool) do
			if m.job == owner and not CreatureObject(m.p):isDead() then
				return m.oid == oid
			end
		end
	end

	-- "Make room" is the commando's alone: with none in the group, nobody answers it
	if intent == "makeroom" then
		return false
	end

	if pool[1] ~= nil and pool[1].oid == oid then
		lastForGroup = true
		return true
	end

	return false
end

-- Is the group over the cap with a human waiting outside it? (checked every capEvery seconds, not in a fight); if so the commando
-- says it sits this one out and leaves
function BotCrew:overCap(pBot, oid, g, pLeader, now)
	if now - readData(ckey(oid, "capAt")) < self.capEvery or CreatureObject(pBot):isInCombat() or self:groupFighting(g) then
		return false
	end

	put(ckey(oid, "capAt"), now)

	local waiting = 0

	for _, humanOid in ipairs(self:humansOnline()) do
		if g.byOid[humanOid] == nil then
			waiting = waiting + 1
		end
	end

	if waiting == 0 or #g.members + waiting <= self.groupCap then
		return false
	end

	print("BotJobs: " .. self:name(oid) .. " gives its place up: " .. #g.members .. " in the group and " .. waiting .. " player(s) outside it")
	self:groupSay(pBot, oid, "sitOut", self:firstName(pLeader))
	self:applyOrder(pBot, oid, "home", now, 0)

	return true
end

-- "Sitting this one out." (the cap): out loud when the player is near, else a tell
function BotCrew:sitOut(pBot, oid, pPlayer, channel)
	local dist = BotJobs:distance(pBot, pPlayer)

	if channel == "spatial" and (dist == nil or dist > 40) then
		channel = "tell"
	end

	self:say(pBot, oid, SceneObject(pPlayer):getObjectID(), channel, "sitOut", self:firstName(pPlayer))
end

-- "Make room" in group chat (or a tell): the commando leaves the group, so the other human can be invited
function BotCrew:makeRoomWanted(text)
	return hasAny(wordsOf(text), self.words.makeroom)
end

function BotCrew:makeRoom(pBot, oid, pSpeaker, channel)
	print("BotJobs: " .. self:name(oid) .. " makes room: leaves " .. self:firstName(pSpeaker) .. "'s group")
	self:say(pBot, oid, SceneObject(pSpeaker):getObjectID(), channel == "group" and "group" or channel, "sitOut", self:firstName(pSpeaker))
	self:applyOrder(pBot, oid, "home", os.time(), 0)
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
		kind = self:noRoom(oid, pPlayer) and "sitOut" or "askInvite"
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

-- The speaker's target as an oid, if this bot may attack it (else 0)
function BotCrew:attackTarget(pBot, pPlayer, g)
	local targetOid = CreatureObject(pPlayer):getTargetID()

	if targetOid ~= 0 and self:validTarget(pBot, getSceneObject(targetOid), g, false) ~= nil then
		return targetOid
	end

	return 0
end

-- follow, stay, home, attack from a group member; from someone else, "follow" is a join and the rest a shrug
function BotCrew:order(pBot, oid, pPlayer, action, channel, brainLine)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local name = self:firstName(pPlayer)
	local g = self:group(pBot)

	if g == nil or g.byOid[playerOid] == nil then
		-- ("wanna hunt? let's go ..." taken as an attack, from someone not in a group, to a bot with none: a join)
		if action == "follow" or (action == "attack" and g == nil) then
			self:join(pBot, oid, pPlayer, channel, brainLine)
		elseif brainLine == nil then
			self:say(pBot, oid, playerOid, channel, "notWith", name)
		end

		return
	end

	local fighting = readData(ckey(oid, "target")) ~= 0 or readData(ckey(oid, "focus")) ~= 0
	local targetOid = 0

	-- Their target, read now; none that it can attack: it says so and does nothing
	if action == "attack" then
		targetOid = self:attackTarget(pBot, pPlayer, g)

		if targetOid == 0 then
			-- (the brain was told there is no target, and has said so)
			if brainLine == nil then
				self:say(pBot, oid, playerOid, channel, "attackNoTarget", name)
			end

			return
		end
	end

	if brainLine == nil then
		self:say(pBot, oid, playerOid, channel, (action == "follow" and fighting) and "backOff" or action, name)
	end

	self:applyOrder(pBot, oid, action, os.time(), targetOid)

	-- Said to the whole group (this bot answered for it): the other crew members do it too, quietly
	if channel == "group" and readData(ckey(oid, "forGroup")) == 1 then
		put(ckey(oid, "forGroup"), 0)

		for i, m in ipairs(g.crew) do
			if m.oid ~= oid then
				createEvent(300 * i, "BotCrew", "groupOrder", m.p, packArgs(readData(key(m.oid, "gen")), action, targetOid))
			end
		end
	end
end

function BotCrew:groupOrder(pBot, args)
	local a = unpackArgs(args)

	if not BotJobs:current(pBot, a[1]) or not CreatureObject(pBot):isGrouped() then
		return
	end

	self:applyOrder(pBot, SceneObject(pBot):getObjectID(), a[2], os.time(), num(a[3]) or 0)
end

-- (targetOid is an attack's target, the speaker's)
function BotCrew:applyOrder(pBot, oid, action, now, targetOid)
	print("BotJobs: " .. self:name(oid) .. " " .. action .. "s")

	local focus = readData(ckey(oid, "focus"))

	if action == "attack" then
		-- Each bot checks the target for itself (it may be out of its reach)
		if targetOid ~= nil and self:validTarget(pBot, getSceneObject(targetOid), self:group(pBot), false) ~= nil then
			put(ckey(oid, "focus"), targetOid)
			deleteData(ckey(oid, "holdUntil"))

			-- Told to stay, it stays no longer; the fight starts on the next step (pickTarget takes the focus)
			putString(ckey(oid, "order"), "follow")
			self:startLoop(pBot, oid, 200)
		end
	elseif action == "stay" then
		deleteData(ckey(oid, "focus"))
		putString(ckey(oid, "order"), "stay")
		self:stopMoving(pBot)
	elseif action == "follow" then
		deleteData(ckey(oid, "focus"))
		putString(ckey(oid, "order"), "follow")
		deleteData(ckey(oid, "followAt"))

		-- "Back off" in a fight: peace, and no new fight for a moment
		if readData(ckey(oid, "target")) ~= 0 or focus ~= 0 then
			put(ckey(oid, "holdUntil"), now + self.holdFire)
			self:endFight(pBot, oid, now)
		end

		local pLeader = getSceneObject(readData(ckey(oid, "leader")))

		if pLeader ~= nil then
			self:ensureFollow(pBot, oid, pLeader, now)
		end
	elseif action == "home" then
		deleteData(ckey(oid, "focus"))
		put(ckey(oid, "saidBye"), 1)

		if readData(ckey(oid, "target")) ~= 0 then
			self:endFight(pBot, oid, now)
		end

		botEnqueue(pBot, "leavegroup", 0, "")
		self:stopMoving(pBot)

		if self:role(oid) == "medic" and BotDoctor ~= nil then
			BotDoctor:clear(oid)
		end

		self:lootBeforeHome(pBot, oid, now)
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
		-- A provoked fight or a duel (BotFight): the entertainer puts its flute away and holds its pistol
		if (name == "duel" or name == "fightStarted") and self:role(oid) == "entertainer" then
			self:perfStop(pBot, oid, true)
		end

		if name == "died" and CreatureObject(pBot):isGrouped() then
			self:huntTallyAdd(pBot, "deaths", 1)
			self:huntEvent(pBot, self:firstName(pBot) .. " died" ..
				(pOther ~= nil and (" to " .. SceneObject(pOther):getDisplayedName()) or ""))
		end

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
	elseif name == "trade" then
		-- A handover's result (BotTrade's bundleDone / bundleCancelled), see crew_loot.lua
		self:lootTradeEvent(pBot, oid, pOther, detail)
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

	local botOid = SceneObject(pBot):getObjectID()
	local list = {}

	put("crew:pretend:" .. botOid, on and 1 or 0)

	-- (the list humansOnline reads: the bots standing in for players)
	for _, listed in ipairs(oidList(readStringData("crew:pretendList"))) do
		if listed ~= botOid then
			table.insert(list, listed)
		end
	end

	if on then
		table.insert(list, botOid)
	end

	putString("crew:pretendList", table.concat(list, ","))
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

-- The leader says something out loud (spatial chat) to the crew bots in its group, as the chat hook would deliver it
function BotCrew:devSay(leader, text)
	local pLeader = devBot(leader)

	if pLeader == nil or text == nil or text == "" then
		print("BotCrew: usage devSay:<leader bot>:<text>")
		return
	end

	local g = self:group(pLeader)

	if g == nil then
		print("BotCrew: " .. tostring(leader) .. " isn't in a group")
		return
	end

	text = text:gsub("_", " "):gsub(":", " ")
	print("BotCrew: " .. CreatureObject(pLeader):getFirstName() .. " (says): " .. text)

	for _, m in ipairs(g.crew) do
		createEvent(10, "BotCrew", "devSayHear", m.p, packArgs(SceneObject(pLeader):getObjectID(), text))
	end
end

function BotCrew:devSayHear(pBot, args)
	local leaderOid, text = args:match("^(%d+):(.*)$")

	BotJobs:heard(pBot, getSceneObject(tonumber(leaderOid)), text, "spatial", false)
end

-- <speaker> (a bot counted as a player, devLead) says <text> to one bot, out loud ("spatial", it has to name the bot) or by
-- "tell" (default): for a bot that is no longer in the speaker's group
function BotCrew:devHear(speaker, first, text, channel)
	local pSpeaker, pBot = devBot(speaker), devBot(first)

	if pSpeaker == nil or pBot == nil or text == nil or text == "" then
		print("BotCrew: usage devHear:<speaker bot>:<bot>:<text>[:spatial|tell]")
		return
	end

	text = text:gsub("_", " ")
	print("BotCrew: " .. CreatureObject(pSpeaker):getFirstName() .. " (" .. (channel or "tell") .. ") to " .. first .. ": " .. text)
	createEvent(10, "BotCrew", "devHearNow", pBot, packArgs(SceneObject(pSpeaker):getObjectID(), channel or "tell", text))
end

function BotCrew:devHearNow(pBot, args)
	local speakerOid, channel, text = args:match("^(%d+):(%a+):(.*)$")

	BotJobs:heard(pBot, getSceneObject(tonumber(speakerOid)), text, channel, false)
end

-- The hunt log and the tally a crew bot sends the brain
function BotCrew:devHunt(first)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrew: no online bot called " .. tostring(first))
		return
	end

	local leaderOid = self:huntOf(pBot)

	if leaderOid == nil then
		print("BotCrew: " .. tostring(first) .. " isn't on a hunt")
		return
	end

	print("BotCrew: the hunt log:\n" .. self:huntLogText(leaderOid) .. "\nTally: " .. self:huntTally(leaderOid, self:group(pBot)))
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

-- devSpawnBy:<bot>:<creature oid>:<template>: a creature 1.5 m from another (to put one beside a clump), run as an event on the bot
function BotCrew:devSpawnBy(first, oid, template)
	local pBot = devBot(first)

	if pBot == nil or tonumber(oid or "") == nil or template == nil then
		print("BotCrew: usage devSpawnBy:<bot>:<creature oid>:<mobile template>")
		return
	end

	createEvent(10, "BotCrew", "devSpawnByNow", pBot, packArgs(oid, template))
end

function BotCrew:devSpawnByNow(pBot, args)
	local a = unpackArgs(args)
	local pNear = getSceneObject(tonumber(a[1]))

	if pNear == nil then
		print("BotCrew: no creature " .. tostring(a[1]))
		return
	end

	local pMobile = spawnMobile(SceneObject(pNear):getZoneName(), a[2], 0, SceneObject(pNear):getWorldPositionX() + 1.5,
		SceneObject(pNear):getWorldPositionZ(), SceneObject(pNear):getWorldPositionY(), 0, 0)

	print("BotCrew: spawned " .. a[2] .. ": " .. (pMobile ~= nil and tostring(SceneObject(pMobile):getObjectID()) or "failed"))
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

-- devEquip:<first>:<weapon template>: holds that weapon (a leader bot needs a gun to open a fight from range)
function BotCrew:devEquip(first, template)
	local pBot = devBot(first)

	if pBot == nil or template == nil then
		print("BotCrew: usage devEquip:<bot>:<template, e.g. object/weapon/ranged/rifle/rifle_cdef.iff>")
		return
	end

	print("BotCrew: " .. tostring(first) .. " equips " .. template .. ": " .. tostring(bot("botEquip", pBot, template)))
end

-- devToughen:<oid>[:<health>]: a creature's health, action and mind (and their maximums) to that much (default 60000), so a
-- fight lasts long enough to watch
function BotCrew:devToughen(oid, amount)
	local p = getSceneObject(tonumber(oid or "") or 0)
	local hp = tonumber(amount or "") or 60000

	if p == nil or not SceneObject(p):isCreatureObject() then
		print("BotCrew: usage devToughen:<creature oid>[:<health>]")
		return
	end

	for _, pool in ipairs({HEALTH, ACTION, MIND}) do
		CreatureObject(p):setMaxHAM(pool, hp)
		CreatureObject(p):setHAM(pool, hp)
	end

	print("BotCrew: " .. SceneObject(p):getDisplayedName() .. " toughened to " .. hp)
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

-- Phase 8 development: calls, stock, resistances
function BotCrew:devCall(first, to)
	local pBot, pTo = devBot(first), devBot(to)

	if pBot == nil or pTo == nil then
		print("BotCrew: usage devCall:<bot>:<to>, both online")
		return
	end

	createEvent(10, "BotCrew", "devCallNow", pBot, tostring(SceneObject(pTo):getObjectID()))
end

function BotCrew:devCallNow(pBot, args)
	local pTo = getSceneObject(tonumber(args))

	print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " botCallTo " .. tostring(pTo ~= nil and CreatureObject(pTo):getFirstName()) .. ": " ..
		tostring(bot("botCallTo", pBot, pTo)))
end

function BotCrew:devStock(first)
	local pBot = devBot(first)

	if pBot ~= nil then
		createEvent(10, "BotCrew", "devStockNow", pBot, "")
	end
end

function BotCrew:devStockNow(pBot, args)
	print("BotCrew: area poison pack " .. tostring(botStockPack(pBot, MED .. "medpack_poison_area_health_c.iff", 5, 250, 240, 150, 30, 10)) ..
		" oid " .. tostring(botFindPack(pBot, MED .. "medpack_poison_area_health_c.iff")))
	print("BotCrew: grenade oid " .. tostring(botStockItem(pBot, "object/weapon/ranged/grenade/grenade_fragmentation.iff", 5)) ..
		" found " .. tostring(botFindItem(pBot, "object/weapon/ranged/grenade/grenade_fragmentation.iff")))
end

function BotCrew:devField(first)
	local pBot = devBot(first)

	if pBot ~= nil then
		createEvent(10, "BotCrew", "devFieldNow", pBot, "")
	end
end

function BotCrew:devFieldNow(pBot, args)
	local g = self:group(pBot)

	if g == nil then
		print("BotCrew: " .. CreatureObject(pBot):getFirstName() .. " isn't grouped")
		return
	end

	local bx, by = SceneObject(pBot):getWorldPositionX(), SceneObject(pBot):getWorldPositionY()

	for _, e in ipairs(self:creatureField(pBot, g, os.time(), nil, 60)) do
		local pCreature = getSceneObject(e.oid)

		print(string.format("BotCrew: field %s %d at %.0f,%.0f, %.0f m, %s, on %s", pCreature ~= nil and SceneObject(pCreature):getDisplayedName() or "?", e.oid, e.x, e.y,
			math.sqrt((e.x - bx) ^ 2 + (e.y - by) ^ 2), e.pulled and "PULLED" or "unpulled", e.target ~= 0 and tostring(e.target) or "nobody"))
	end
end

function BotCrew:devResists(oid)
	local pCreature = getSceneObject(tonumber(oid))
	local r = pCreature ~= nil and bot("botResists", pCreature) or nil

	if r == nil then
		print("BotCrew: no resists for " .. tostring(oid))
		return
	end

	print(string.format("BotCrew: resists kinetic %d energy %d blast %d heat %d cold %d electricity %d acid %d stun %d", r.kinetic, r.energy,
		r.blast, r.heat, r.cold, r.electricity, r.acid, r.stun))
end

-- Destroy missions in the leader's direction (Phase 7)
includeFile("../custom_scripts/screenplays/bots/crew_missions.lua")

-- The roles share this module; each has its own table (for the role-aware keywords and the brain's actions)
BotJobModules = BotJobModules or {}

for role in pairs(CREW) do
	BotJobModules[role] = BotCrew:new {crewRole = role, kit = role == "medic" and "medic" or (role == "entertainer" and "entertainer" or "fighter")}
end

-- Phase 7: looting, harvesting and the handover (adds to BotCrew)
includeFile("../custom_scripts/screenplays/bots/crew_loot.lua")
