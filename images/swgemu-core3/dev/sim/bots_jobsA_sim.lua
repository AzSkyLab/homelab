-- Bot players simulator, Phases 4-5 (the jobsA part): the musician, the smuggler and BotFight (provoked fights and
-- duels), driven against a mock of what they use: Phase 3's bot API plus the Phases 4-6 bindings for trade and
-- slicing (patches/bots/BotTradeLua.h, BotTrade.h), combat and duels (BotCombatLua.h, BotCombat.h) and walking
-- (BotMoverLua.h), as their headers describe them. living_cities_sim.lua loads this file after bots_sim.lua and lends
-- it its clock, shared memory and world. The mock (and a roster of its own) is installed only while these scenarios
-- run, so Phase 3's scenarios keep theirs.
--
--   lua living_cities_sim.lua ../../custom_scripts botmusic botslice botfight
--   SIM_TALK_DIR=<empty dir with req/ and rep/> lua living_cities_sim.lua ../../custom_scripts botfight
--
-- botmusic: the song at login, flourishes, song changes, the outro and restarts, never sitting, action, the buff target
-- (near, from afar, again after a restart), the instrument equipped again, no music in a fight or on the walk back,
-- one chain after a second login, logout.
-- botslice: prices and how-to by keyword, the trade (open, check, accept, verify last, slice in the same step, item
-- back, result, thanks), short payments, sliced, unsliceable, wrong and too many items, the powerup warning, tips on
-- top, a failed slice refunded, a full inventory, aborts, a busy smuggler, the watchdog, a build without the
-- bindings, idling.
-- botfight: insults counted in the window, the warning, the fight, gloat and sulk, the cooldown, the walk back, far
-- insults, a fight called off, duels (accepted, ended by the body at the first incap, the backstop when it doesn't,
-- called off), refusals, death and cloning, logout, and (with SIM_TALK_DIR) insults flagged by the faked talk bridge.

return function(ctx)
	local sim, Obj, fail, realPrint = ctx.sim, ctx.Obj, ctx.fail, ctx.realPrint
	local scenarios, order = ctx.scenarios, ctx.order

	assert(Obj.getHAM ~= nil, "bots_jobsA_sim.lua needs bots_sim.lua's creature mock (it loads first)")

	local function nowMs()
		return sim.now * 1000 + (sim.subMs or 0)
	end

	local ACTION = 3

	local SONGS = {}
	for _, s in ipairs({"starwars1", "starwars2", "starwars3", "starwars4", "rock", "folk", "ballad", "funk", "waltz", "jazz",
		"virtuoso"}) do
		SONGS[s] = true
	end

	-- The client's social_types.iff names (botEmote looks them up there)
	local SOCIALS = {}
	for name in string.gmatch([[accuse ache adjust adn agree airguitar amazing anxious apologize applaud arch attend
		backhand bad badfeeling bah bang bark batlashes beam beckon belch bite blame bleed blink blow blowkiss blush bob
		bodyslam boggle bonk boogie bored bounce bouquet bow bow2 bow3 bow4 bowhead brandish bump burp bye cackle calm
		catchbreath cheek cheer chestpound chestpuff chortle chuckle clap claw closeeyes comfort congratulate contemplate
		cough cover cower cringe cry curse curtsey dance deepbow defend demure deride disagree doh down dream drool duck
		eek elbow embrace encourage evilgrin exhausted eyebrow eyeroll faint fear feh fiddle fidget fistpalm flail flex
		flip flipcoin flirt flower flutter frown fume gag gape gasp gawk gaze giggle giveup glare gloat glow greet grin
		groan grovel growl grumble grunt gulp hail hand handshake headache hiccup hiss hop hug hum innocent introduce jump
		kiss knockwood kowtow laugh lean leer lick lol love luck makeroom mercy mock model mope mourn mutter nails nap nod
		nono noogie nudge nuzzle oneknee pant pat payup peer pet pinch pointat poke ponder pout pound preen primp prod
		protect provoke pshrug pucker punch push puzzle question quiet raise raspberry ready reassure roar rofl rolleyes
		rose rude salute scare scared scold scowl scratch scream shake sharpen shiver shoo shrug shudder shush sigh skip
		slap smile smirk snap snarl sneer sneeze snicker sniff snore snort softclap spin spit squeeze stare stomp stretch
		strut sulk surprised sweat tap tease thank thirst throwat throwdown thumbdown thumbup tickle tiphat tiptoe toss
		tsktsk twiddle twirl twitch wait wave welcome whistle wince wink yawn yes]], "%S+") do
		SOCIALS[name] = true
	end

	-- Creature parts the new jobs read (bots_sim.lua has HAM, cash, skill mods)

	function Obj:isPlayingMusic() return self.music ~= nil end
	function Obj:getPerformanceName() return self.music or self.dancing end
	function Obj:isIncapacitated() return self.incap == true end
	function Obj:isDead() return self.dead == true end
	function Obj:isInCombat() return self.inCombat == true end
	function Obj:getSlottedObject(slot)
		if slot == "hold_r" then
			return self.holdR
		end
		return nil
	end

	-- The mock

	local log, bots, trades, fights, opt = nil, {}, {}, {}, {}
	local function resetLog()
		log = {commands = {}, says = {}, tells = {}, emotes = {}, calls = {}, trades = {}}
	end
	resetLog()

	local function called(name, bot, a, b)
		table.insert(log.calls, {name = name, bot = bot and bot.oid or 0, t = nowMs(), a = a, b = b})
	end

	local function fire(bot, name, other, detail)
		sim.call("BotJobs", "onEvent", bot, name, other, detail or "")
	end

	-- Like the body: in the bot's own task, after the caller's Lua returns
	local function fireLater(ms, bot, name, other, detail)
		sim.schedule(ms, function()
			if bot.online then
				fire(bot, name, other, detail)
			end
		end)
	end

	local function performing(bot)
		return bot.music ~= nil or bot.dancing ~= nil
	end

	local function noPlaceholder(text)
		assert(not text:find("{%a+}"), "unfilled placeholder: " .. text)
	end

	-- Fights and duels as the body keeps them: fights[botOid] = {other = oid, duel = bool}
	local function dueling(a, b)
		return (a.duelList or {})[b.oid] and (b.duelList or {})[a.oid]
	end

	-- The body ends a fight: lists and flags cleared, peace, "fightEnded" in the bot's task
	local function endFight(bot, detail)
		local f = fights[bot.oid]
		if f == nil then
			return false
		end
		local other = ctx.objects[f.other]
		fights[bot.oid] = nil
		if f.duel then
			bot.duelList[other.oid], other.duelList[bot.oid] = nil, nil
		end
		bot.inCombat, other.inCombat, bot.targetOid = false, false, 0
		fireLater(0, bot, "fightEnded", other, detail)
		return true
	end

	-- The Core3 commands the jobs queue, as far as they depend on them
	local function runCommand(bot, command, target, args)
		if command == "startmusic" then
			if performing(bot) then
				return false, "already performing"
			elseif bot.inCombat then
				return false, "in combat"
			elseif bot.holdR == nil then
				return false, "no instrument"
			elseif not SONGS[args] then
				return false, "not a song: " .. args
			end
			bot.music, bot.outroUntil = args, nil
			return true
		elseif command == "startdance" then
			-- (Phase 8's band: the dancer; any dance of the master dancer's)
			if performing(bot) then
				return false, "already performing"
			elseif bot.inCombat then
				return false, "in combat"
			end
			bot.dancing = args
			return true
		elseif command == "stopdance" then
			bot.dancing, bot.buffTarget = nil, nil
			return true
		elseif command == "changemusic" then
			-- (Core3 has no outro check here, nor in /flourish: isPlayingMusic() holds through the outro)
			if bot.music == nil then
				return false, "not playing"
			elseif not SONGS[args] then
				return false, "not a song: " .. args
			end
			bot.music = args
			return true
		elseif command == "stopmusic" then
			if bot.music == nil or bot.outroUntil ~= nil then
				return false, "not playing"
			end
			-- The 15 s outro: still playing until it ends; the buff target goes with the song
			bot.outroUntil = sim.now + 15
			sim.schedule(15000, function()
				bot.music, bot.outroUntil, bot.buffTarget = nil, nil, nil
			end)
			return true
		elseif command == "flourish" then
			local n = tonumber(args)
			if not performing(bot) then
				return false, "not performing"
			elseif n == nil or n < 1 or n > 8 or math.type(n) ~= "integer" then
				return false, "bad flourish " .. args
			end
			return true
		elseif command == "setperformancebufftarget" then
			local patient = ctx.objects[target]
			if patient == nil or patient == bot or not patient.isPlayer then
				return false, "invalid target"
			end
			bot.buffTarget = target
			return true
		elseif command == "tip" then
			local to, n = ctx.objects[target], tonumber(args)
			if to == nil or n == nil or n <= 0 or (bot.cash or 0) < n then
				return false, "can't tip " .. tostring(args)
			end
			bot.cash, to.cash = bot.cash - n, (to.cash or 0) + n
			return true
		elseif command == "duel" then
			local to = ctx.objects[target]
			if to == nil or to == bot or not to.isPlayer then
				return false, "invalid target"
			elseif bot:getDistanceTo(to) > 25 then
				return false, "too far"
			end
			bot.duelList[target] = true
			-- The body's tick: the duel is on
			if dueling(bot, to) and fights[bot.oid] == nil then
				fights[bot.oid] = {other = target, duel = true}
				fireLater(500, bot, "duel", to, "started")
			end
			return true
		elseif command == "endduel" then
			local to = ctx.objects[target]
			if to == nil or not bot.duelList[target] then
				return false, "not dueling"
			end
			if fights[bot.oid] ~= nil and fights[bot.oid].other == target then
				endFight(bot, "ended")
			else
				bot.duelList[target] = nil
				to.duelList[bot.oid] = nil
			end
			return true
		elseif command == "sitserver" or command == "stand" or command == "healenhance" or command == "healwound" then
			-- (the doctor's; the musician must never sit or stand)
			return true
		end
		return false, "unknown command " .. command
	end

	local api = {}

	function api.botList()
		local out = {}
		for _, entry in ipairs(BotRoster.bots) do
			local b = bots[(entry.name:match("^(%S+)")):lower()]
			table.insert(out, {name = entry.name, firstName = entry.name:match("^(%S+)"), job = entry.job, city = entry.city,
				oid = b and b.oid or 0, online = b ~= nil and b.online == true})
		end
		return out
	end

	function api.botGetCreature(first)
		local b = bots[tostring(first):lower()]
		return (b ~= nil and b.online) and b or nil
	end

	function api.isBot(p)
		return p ~= nil and p.isBotFlag == true
	end

	function api.botSetDevHuman(on) end

	function api.botEnqueue(bot, command, target, args)
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

	function api.botSay(bot, text, mood)
		assert(type(text) == "string" and #text > 0 and not text:find("[%c]"), "botSay: bad line " .. tostring(text))
		assert(type(mood) == "string", "botSay: mood must be a string")
		noPlaceholder(text)
		table.insert(log.says, {bot = bot.oid, t = nowMs(), text = text, mood = mood})
		if sim.chatLog then
			table.insert(sim.chatLog, bot.name .. ": " .. text)
		end
		return true
	end

	function api.botTell(bot, to, text)
		assert(type(to) == "string" and #to > 0, "botTell: no name")
		assert(type(text) == "string" and #text > 0 and not text:find("[%c]"), "botTell: bad line")
		noPlaceholder(text)
		table.insert(log.tells, {bot = bot.oid, t = nowMs(), to = to, text = text})
		return true
	end

	function api.botEmote(bot, emote, target)
		assert(SOCIALS[emote], "botEmote: not a social: " .. tostring(emote))
		assert(math.type(target) == "integer", "botEmote: target must be an integer oid")
		table.insert(log.emotes, {bot = bot.oid, t = nowMs(), emote = emote, target = target})
		return true
	end

	function api.botFace(bot, target)
		assert(target ~= nil, "botFace: no target")
		bot.facing = target.oid
		return true
	end

	function api.botStockPack(bot, template, uses, power, duration)
		return true
	end

	function api.botGetWounds(p, pool)
		return p ~= nil and (p.wounds or {})[pool] or 0
	end

	function api.botGetShockWounds(p)
		return p ~= nil and p.shock or 0
	end

	function api.botGetBuffs(p)
		return {}
	end

	function api.botLogin(first)
		local b = bots[tostring(first):lower()]
		if b == nil then
			return false
		end
		b.online, b.inWorld = true, true
		sim.call("BotJobs", "onLogin", b)
		return true
	end

	function api.botLogout(first)
		local b = bots[tostring(first):lower()]
		if b == nil or not b.online then
			return false
		end
		sim.call("BotJobs", "onLogout", b)
		b.online, b.inWorld, b.music, b.outroUntil = false, false, nil, nil
		trades[b.oid] = nil
		return true
	end

	-- Combat (BotCombatLua.h)

	function api.botEquip(bot, template)
		called("botEquip", bot, template)
		if template:find("/instrument/", 1, true) then
			bot.holdR = template
		end
		return 900000 + bot.oid
	end

	-- With engage (the default), a target the bot may attack gets an attack queued: combat, and auto-attack runs
	function api.botSetTarget(bot, oid, engage)
		called("botSetTarget", bot, oid)
		bot.targetOid = oid
		if oid == 0 then
			return true
		end
		local f = fights[bot.oid]
		if engage ~= false and f ~= nil and f.other == oid then
			bot.inCombat = true
			ctx.objects[oid].inCombat = true
		end
		return true
	end

	function api.botDuelState(bot, other)
		if bot == nil or other == nil then
			return "none"
		end
		local mine, theirs = (bot.duelList or {})[other.oid], (other.duelList or {})[bot.oid]
		if mine and theirs then
			return "dueling"
		elseif theirs then
			return "challenged"
		elseif mine then
			return "challenging"
		end
		return "none"
	end

	function api.botStartFight(bot, human)
		called("botStartFight", bot, human and human.oid)
		if bot == nil or human == nil or fights[bot.oid] ~= nil or bot:getDistanceTo(human) > 128 then
			return false
		end
		fights[bot.oid] = {other = human.oid, duel = false}
		bot.inCombat, human.inCombat = true, true
		-- Core3's setCombatState stops a performance
		bot.music, bot.dancing, bot.outroUntil = nil, nil, nil
		return true
	end

	function api.botEndFight(bot, human)
		called("botEndFight", bot, human and human.oid)
		local f = fights[bot.oid]
		if f == nil or human == nil or f.other ~= human.oid then
			return false
		end
		return endFight(bot, "ended")
	end

	function api.botClone(bot)
		called("botClone", bot)
		sim.schedule(5000, function()
			bot.dead, bot.incap = false, false
			bot.x = bot.x + 200
			fire(bot, "cloned", nil, "")
		end)
		return true
	end

	-- Walking (BotMoverLua.h)

	function api.botFollow(bot, leader, near, far)
		called("botFollow", bot, leader.oid, {near, far})
		-- (it catches up: next to them, on the far side)
		bot.following = leader.oid
		bot.x, bot.y, bot.cell = leader.x + (near or 3), leader.y, leader.cell
		return true
	end

	function api.botStop(bot)
		called("botStop", bot)
		bot.following = nil
		return true
	end

	function api.botMoveTo(bot, x, z, y, cell, pace)
		called("botMoveTo", bot, {x, z, y, cell})
		bot.following = nil
		sim.schedule(4000, function()
			if bot.online then
				bot.x, bot.z, bot.y, bot.cell = x, z, y, cell
				fire(bot, "arrived", nil, "")
			end
		end)
		return true
	end

	function api.botMoveState(bot)
		return {state = bot.following and "follow" or "idle", leader = bot.following or 0, distance = 0, stuck = false}
	end

	-- Trade and slicing (BotTradeLua.h, BotTrade.h)

	local function copyItems(list)
		local out = {}
		for i, item in ipairs(list) do
			out[i] = item
		end
		return out
	end

	-- What the bot last read is what verify re-checks against
	function api.botTradeState(bot)
		local t = bot ~= nil and trades[bot.oid] or nil
		if t == nil then
			return {partner = 0, stage = "none", items = {}, credits = 0, partnerAccepted = false, accepted = false, give = 0}
		end
		t.seen = {items = table.concat(t.items, ","), credits = t.credits}
		return {partner = t.partner, stage = t.stage, items = copyItems(t.items), credits = t.credits,
			partnerAccepted = t.partnerAccepted, accepted = t.botAccepted, give = 0}
	end

	function api.botTradeAccept(bot)
		called("botTradeAccept", bot)
		if bot.tradeRequest == nil then
			return false, "no request"
		end
		trades[bot.oid] = {partner = bot.tradeRequest, stage = "open", items = {}, credits = 0}
		bot.tradeRequest = nil
		return true, ""
	end

	-- Accepts; if the partner verified, verifies last and the goods move now (Core3's second verify)
	function api.botTradeVerify(bot, minCredits, itemOid)
		called("botTradeVerify", bot, minCredits, itemOid)
		local t = trades[bot.oid]
		if t == nil then
			return false, "none"
		end
		if t.seen == nil or t.seen.items ~= table.concat(t.items, ",") or t.seen.credits ~= t.credits then
			return false, "changed"
		end
		if minCredits ~= nil and minCredits >= 0 and t.credits < minCredits then
			return false, "credits"
		end
		if itemOid ~= nil and itemOid ~= 0 and (#t.items ~= 1 or t.items[1] ~= itemOid) then
			return false, "items"
		end
		t.botAccepted = true
		if t.stage ~= "partnerVerified" then
			return false, "waiting"
		end
		local human = ctx.objects[t.partner]
		for _, item in ipairs(t.items) do
			assert(human.inventory[item], "trade: the item isn't the partner's")
			human.inventory[item] = nil
			bot.inventory[item] = true
		end
		assert((human.cash or 0) >= t.credits, "trade: the partner lacks the credits")
		human.cash, bot.cash = human.cash - t.credits, bot.cash + t.credits
		table.insert(log.trades, {bot = bot.oid, partner = t.partner, items = t.items, credits = t.credits, t = nowMs()})
		trades[bot.oid] = nil
		fireLater(0, bot, "trade", human, "done")
		return true, "done"
	end

	-- No "aborted" event: the jobs asked for it
	function api.botTradeAbort(bot)
		called("botTradeAbort", bot)
		local had = trades[bot.oid] ~= nil or bot.tradeRequest ~= nil
		trades[bot.oid], bot.tradeRequest = nil, nil
		return had
	end

	function api.botItemInfo(oid)
		local it = ctx.objects[oid]
		if it == nil or not it.isItem then
			return nil
		end
		local sliceable = it.kind ~= "other" and not it.sliced and not it.jedi
		return {kind = it.kind, sliced = it.sliced, sliceable = sliceable, powerup = it.powerup, name = it.itemName, parent = 0}
	end

	-- Sliced or not, the item goes back to the owner in the same step (a give-back trade when their inventory is full)
	function api.botSlice(bot, itemOid, owner, want)
		called("botSlice", bot, itemOid, owner and owner.oid)
		local it = ctx.objects[itemOid]
		if bot == nil or it == nil or not bot.inventory[itemOid] then
			return {ok = false, kind = "", stat = "", percent = 0, error = "not in inventory", returned = false}
		end
		local result = {ok = false, kind = it.kind, stat = "", percent = 0, error = "", returned = false}
		if opt.sliceError ~= nil then
			result.error = opt.sliceError
		elseif (bot.tools or 0) <= 0 then
			result.error = "no slicing tools"
		elseif it.sliced or it.kind == "other" or it.jedi then
			result.error = "can't slice that"
		else
			bot.tools = bot.tools - 1
			if it.kind == "armor" then
				if math.random() < 0.5 then result.stat, result.percent = "effectiveness", math.random(11, 35) else result.stat, result.percent = "encumbrance", math.random(20, 45) end
			else
				if math.random() < 0.5 then result.stat, result.percent = "damage", math.random(20, 35) else result.stat, result.percent = "speed", math.random(20, 35) end
			end
			-- The type the customer named, in its range (as the body swaps it)
			local ranges = {effectiveness = {11, 35}, encumbrance = {20, 45}, damage = {20, 35}, speed = {20, 35}}
			local fits = (it.kind == "armor") == (want == "effectiveness" or want == "encumbrance")
			if want ~= nil and ranges[want] ~= nil and fits then
				result.stat, result.percent = want, math.random(ranges[want][1], ranges[want][2])
			end
			it.sliced, it.powerup, it.stat, it.percent = true, false, result.stat, result.percent
			result.ok = true
		end
		if owner ~= nil then
			if opt.ownerFull then
				result.error = result.error == "" and "inventory full" or (result.error .. ", inventory full")
				-- (the give-back trade completes a little later)
				sim.schedule(5000, function()
					bot.inventory[itemOid], owner.inventory[itemOid] = nil, true
					fire(bot, "trade", owner, "returned")
				end)
			else
				bot.inventory[itemOid], owner.inventory[itemOid] = nil, true
				result.returned = true
			end
		end
		return result
	end

	function api.botStockSlicingTools(bot, count)
		called("botStockSlicingTools", bot, count)
		assert(math.type(count) == "integer" and count > 0, "botStockSlicingTools: bad count " .. tostring(count))
		bot.tools = math.max(bot.tools or 0, count)
		return true
	end

	-- The roster these scenarios use

	local function testRoster()
		local function station(x, y)
			return {planet = "tatooine", x = x, z = 5, y = y, cell = 0, heading = 0}
		end
		return {
			settings = {loginDelay = 60, logoutDelay = 600, enhancePower = 700, enhanceDuration = 10800, woundPower = 250,
				packStock = 20, slicePriceArmor = 4000, slicePriceWeapon = 6000, sliceToolStock = 5, insultsToFight = 3,
				insultWindow = 600, fightCooldown = 600},
			bots = {
				{name = "Tobin Vael", species = "human", sex = "male", job = "musician", city = "mos_eisley",
					outfit = {"object/tangible/wearables/shirt/shirt_s13.iff", "object/tangible/instrument/bandfill.iff"},
					station = station(1003, 1000)},
				{name = "Vex Marrin", species = "zabrak", sex = "male", job = "smuggler", city = "mos_eisley",
					outfit = {"object/tangible/wearables/vest/vest_s03.iff"}, station = station(1010, 1005)},
				{name = "Hesk Torlan", species = "bothan", sex = "male", job = "doctor", city = "mos_eisley",
					outfit = {}, station = station(1000, 990)},
			},
		}
	end

	local function makeBots()
		bots = {}
		for _, entry in ipairs(BotRoster.bots) do
			local first = entry.name:match("^(%S+)")
			local holdR = nil
			for _, t in ipairs(entry.outfit or {}) do
				if t:find("/instrument/", 1, true) then
					holdR = t
				end
			end
			local b = ctx.newObject({
				isBotFlag = true, isPlayer = true, first = first, last = entry.name:match("%S+$"), name = entry.name,
				planet = entry.station.planet, x = entry.station.x, y = entry.station.y, z = 5, cell = 0, inWorld = false,
				online = false, cash = 300, bank = 2000, packs = {}, buffs = {}, inventory = {}, duelList = {}, holdR = holdR,
				job = entry.job, skillMods = entry.job == "doctor" and {healing_wound_speed = 100} or {},
			})
			bots[first:lower()] = b
			ctx.addPlayer(b)
		end
	end

	local function byJob(job)
		for _, b in pairs(bots) do
			if b.job == job then
				return b
			end
		end
	end

	local function makePlayer(first, planet, x, y)
		local p = ctx.newObject({isPlayer = true, first = first, planet = planet, x = x, y = y, z = 5, cell = 0, inWorld = true,
			buffs = {}, wounds = {}, inventory = {}, duelList = {}, cash = 50000, bank = 0})
		ctx.addPlayer(p)
		return p
	end

	local function makeItem(owner, kind, name, fields)
		local it = ctx.newObject({isItem = true, kind = kind, itemName = name, sliced = false, powerup = false})
		for k, v in pairs(fields or {}) do
			it[k] = v
		end
		owner.inventory[it.oid] = true
		return it
	end

	-- Driving it

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

	local function calls(name, bot, since)
		local out = {}
		for _, c in ipairs(log.calls) do
			if c.name == name and (bot == nil or c.bot == bot.oid) and c.t >= (since or 0) then
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

	local function emotesOf(bot, since)
		local out = {}
		for _, e in ipairs(log.emotes) do
			if e.bot == bot.oid and e.t >= (since or 0) then
				table.insert(out, e)
			end
		end
		return out
	end

	-- Is the text one of these canned lines (with any placeholders filled)?
	local function isLine(text, job, kind)
		for _, pattern in ipairs((BotLines[job] or {})[kind] or {}) do
			local p = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("{%a+}", ".-") .. "$"
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

	local function countLines(lines, job, kind)
		local n = 0
		for _, l in ipairs(lines) do
			if isLine(l.text, job, kind) then
				n = n + 1
			end
		end
		return n
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

	-- The human's side of a trade, as the body reports it (BotTrade.h)
	local function requestTrade(human, bot)
		bot.tradeRequest = human.oid
		fire(bot, "trade", human, "requested")
	end

	local function offer(human, bot, itemList, credits)
		local t = trades[bot.oid]
		if t == nil or t.partner ~= human.oid then
			return false
		end
		t.items = {}
		for _, it in ipairs(itemList) do
			table.insert(t.items, it.oid)
		end
		t.credits = credits
		fire(bot, "trade", human, "changed")
		return true
	end

	local function humanAccept(human, bot)
		local t = trades[bot.oid]
		if t == nil then
			return false
		end
		t.partnerAccepted = true
		fire(bot, "trade", human, "changed")
		return true
	end

	-- The client offers the verify only once both sides have accepted; Core3 keeps a verify through later changes
	local function humanVerify(human, bot)
		local t = trades[bot.oid]
		if t == nil or not t.partnerAccepted or not t.botAccepted then
			return false
		end
		t.stage = "partnerVerified"
		fire(bot, "trade", human, "partnerVerified")
		return true
	end

	local function humanAbort(human, bot)
		trades[bot.oid] = nil
		fire(bot, "trade", human, "aborted")
	end

	-- Down: the body ends a fight or a duel at the first incap of either side (unless told not to, for the backstop)
	local function incap(who)
		who.incap, who.inCombat = true, false
		if opt.bodyIgnoresIncap then
			return
		end
		for botOid, f in pairs(fights) do
			if f.other == who.oid or botOid == who.oid then
				endFight(ctx.objects[botOid], f.other == who.oid and "humanIncap" or "botIncap")
			end
		end
		if who.isBotFlag then
			fireLater(0, who, "incapacitated", nil, "")
		end
	end

	local function insult(bot, player, times, gap)
		for i = 1, times do
			sim.call("BotFight", "onReply", bot, player.oid, "insult", "spatial")
			if gap ~= nil then
				sim.run(gap)
			end
		end
	end

	local saved, savedSettings = nil, nil

	local function setup(talkDir, withDancer)
		saved = {roster = BotRoster, fns = {}}
		for name, fn in pairs(api) do
			saved.fns[name] = _G[name] == nil and false or _G[name]
			_G[name] = fn
		end
		BotRoster = testRoster()
		if withDancer then
			table.insert(BotRoster.bots, {name = "Lena Soro", species = "twilek", sex = "female", job = "dancer", city = "mos_eisley",
				outfit = {"object/tangible/wearables/dress/dress_s08.iff"}, station = {planet = "tatooine", x = 1006, z = 5, y = 1000, cell = 0, heading = 0}})
		end
		savedSettings = {dir = LivingTalk.dir, chatterEvery = LivingCities.chatterEvery, greetChance = LivingCities.greetChance}
		LivingTalk.dir = talkDir
		LivingCities.chatterEvery, LivingCities.greetChance = 1e12, 0
		ctx.setHour(20)
		resetLog()
		trades, fights, opt = {}, {}, {}
		makeBots()
		BotJobs:start()
		sim.chatLog = {}
	end

	local function teardown()
		for name, fn in pairs(saved.fns) do
			if fn == false then
				_G[name] = nil
			else
				_G[name] = fn
			end
		end
		BotRoster = saved.roster
		LivingTalk.dir, LivingCities.chatterEvery, LivingCities.greetChance = savedSettings.dir, savedSettings.chatterEvery,
			savedSettings.greetChance
		sim.chatLog = nil
	end


	-- Scenario: Phase 8 group 6, the cantina band

	function scenarios.botband()
		setup("/nonexistent/sim-talk", true)
		local mus, dancer = byJob("musician"), byJob("dancer")
		api.botLogin(mus.first)
		api.botLogin(dancer.first)
		local t0 = nowMs()

		-- 1. Both perform from login; an hour of flourishes together: each of the dancer's comes within 3 s of the musician's
		sim.run(3600)
		if mus.music == nil or dancer.dancing == nil then fail("botband: not both performing") end
		local fm, fd = commands(mus, "flourish", t0), commands(dancer, "flourish", t0)
		if #fm < 60 or #fd < 60 then fail("botband: " .. #fm .. " and " .. #fd .. " flourishes in an hour") end
		if math.abs(#fm - #fd) > 1 then fail("botband: " .. #fm .. " musician flourishes against " .. #fd .. " dancer ones") end
		local apart = 0
		for i = 1, math.min(#fm, #fd) do
			local gap = math.abs(fm[i].t - fd[i].t)
			if gap > 3000 then apart = apart + 1 end
		end
		if apart > 0 then fail("botband: " .. apart .. " flourishes more than 3 s apart") end
		for i = 2, #fm do
			local gap = fm[i].t - fm[i - 1].t
			if gap < 19000 or gap > 50000 then fail("botband: " .. gap .. " ms between the band's flourishes") break end
		end

		-- 2. Asked for a buff, the musician gets the dancer to set the same target, and each says its line
		local player = makePlayer("Cameren", "tatooine", 1004, 1000)
		player.target = mus.oid
		local t = nowMs()
		speak(mus, player, "can I get a buff?", "spatial")
		sim.run(5)
		if mus.buffTarget ~= player.oid then fail("botband: the musician didn't make the player its buff target") end
		if dancer.buffTarget ~= player.oid then fail("botband: the dancer didn't join the buff") end
		if not anyLine(linesOf(mus, t), "musician", "listen") then fail("botband: the musician didn't say to listen") end
		if not anyLine(linesOf(dancer, t), "dancer", "band") then fail("botband: the dancer didn't say to watch") end
		if #linesOf(mus, t) ~= 1 or #linesOf(dancer, t) ~= 1 then fail("botband: " .. #linesOf(mus, t) .. " and " .. #linesOf(dancer, t) .. " lines for one buff") end

		-- ...and asked of the dancer, the musician joins
		local other = makePlayer("Dex", "tatooine", 1004, 1001)
		other.target = dancer.oid
		t = nowMs()
		speak(dancer, other, "buff please", "spatial")
		sim.run(5)
		if dancer.buffTarget ~= other.oid or mus.buffTarget ~= other.oid then fail("botband: the dancer's buff didn't reach both") end
		if not anyLine(linesOf(dancer, t), "dancer", "watch") or not anyLine(linesOf(mus, t), "musician", "band") then
			fail("botband: the lines of a buff asked of the dancer")
		end

		-- 3. The musician offline: the dancer flourishes on its own timer, and a buff is hers alone
		api.botLogout(mus.first)
		sim.run(5)
		t = nowMs()
		sim.run(600)
		local alone = commands(dancer, "flourish", t)
		if #alone < 10 then fail("botband: the dancer flourished " .. #alone .. " times in ten minutes without the musician") end
		player.target = dancer.oid
		speak(dancer, player, "buff please", "spatial")
		sim.run(5)
		if dancer.buffTarget ~= player.oid then fail("botband: the lone dancer's buff") end

		-- 4. Varenhal's dancer and musician are not a band (they are the same pair here, with the city changed)
		api.botLogin(mus.first)
		sim.run(10)
		if BotBand:partner(dancer.oid) == nil then fail("botband: the pair isn't a band again after the musician came back") end
		for _, entry in ipairs(BotRoster.bots) do
			if entry.job == "dancer" or entry.job == "musician" then entry.city = "varenhal" end
		end
		writeStringData("bot:" .. dancer.oid .. ":city", "varenhal")
		writeStringData("bot:" .. mus.oid .. ":city", "varenhal")
		if BotBand:partner(dancer.oid) ~= nil or BotBand:partner(mus.oid) ~= nil then fail("botband: Varenhal's pair formed a band") end

		realPrint(string.format("botband %d musician flourishes, %d dancer flourishes", #fm, #fd))
		teardown()
	end

	-- Scenario: the musician

	function scenarios.botmusic()
		setup("/nonexistent/sim-talk")
		local mus = byJob("musician")
		local songs = {}
		for _, s in ipairs(BotMusician.songs) do songs[s] = true end

		api.botLogin(mus.first)
		local all = commands(mus, nil, 0)
		if #all == 0 or all[1].cmd ~= "startmusic" or not all[1].ok or not songs[all[1].args] then
			fail("botmusic: no startmusic with a song name at login (" .. (all[1] and (all[1].cmd .. " " .. all[1].args) or "nothing") .. ")")
		end

		-- An hour of playing: flourishes every 20-40 s, a new song every 10-20 minutes, never a sit or a stand
		local t0 = nowMs()
		sim.run(3600)
		local flourishes, changes = commands(mus, "flourish", t0), commands(mus, "changemusic", 0)
		for i = 2, #flourishes do
			local gap = flourishes[i].t - flourishes[i - 1].t
			if gap < 20000 or gap > 50000 then
				fail("botmusic: " .. gap .. " ms between flourishes")
				break
			end
		end
		if #flourishes < 3600 / 45 or #flourishes > 3600 / 20 then
			fail("botmusic: " .. #flourishes .. " flourishes in an hour")
		end
		for i, c in ipairs(changes) do
			local prev = i > 1 and changes[i - 1].t or all[1].t
			if c.t - prev < 600000 or c.t - prev > 1210000 then
				fail("botmusic: " .. (c.t - prev) .. " ms between songs")
			end
			if not songs[c.args] or (i > 1 and c.args == changes[i - 1].args) then
				fail("botmusic: changed to " .. c.args)
			end
		end
		if #changes < 3 or #changes > 6 then
			fail("botmusic: " .. #changes .. " song changes in an hour")
		end
		if #commands(mus, "sitserver", 0) + #commands(mus, "stand", 0) > 0 or #emotesOf(mus, 0) > 0 then
			fail("botmusic: the musician sat, stood or emoted while playing")
		end
		local fails = failedCommands(mus, 0)
		if #fails > 0 then
			fail("botmusic: failed commands: " .. table.concat(fails, "; "))
		end

		-- Action kept up
		mus:pool(ACTION).cur = 50
		sim.run(6)
		if mus:getHAM(ACTION) < mus:getMaxHAM(ACTION) * 0.3 then
			fail("botmusic: action not topped up")
		end

		-- /stopmusic: nothing during the 15 s outro (Core3 counts it as playing), then the song again
		local t = nowMs()
		api.botEnqueue(mus, "stopmusic", 0, "")
		sim.run(14)
		if #commands(mus, "startmusic", t) > 0 then
			fail("botmusic: startmusic during the outro")
		end
		sim.run(25)
		local starts = commands(mus, "startmusic", t)
		if #starts ~= 1 or not starts[1].ok or mus.music == nil or starts[1].t < t + 15000 then
			fail("botmusic: after the outro " .. #starts .. " startmusic, playing " .. tostring(mus.music))
		end
		-- A song that stopped outright
		mus.music = nil
		t = nowMs()
		sim.run(25)
		starts = commands(mus, "startmusic", t)
		if #starts ~= 1 or not starts[1].ok then
			fail("botmusic: no restart after the song stopped")
		end

		-- A buff by keyword: the buff target and "listen"
		local player = makePlayer("Cameren", mus.planet, mus.x + 3, mus.y)
		player.target = mus.oid
		t = nowMs()
		speak(mus, player, "can I get a buff?")
		sim.run(3)
		local set = commands(mus, "setperformancebufftarget", t)
		if #set ~= 1 or set[1].target ~= player.oid or not set[1].ok or mus.buffTarget ~= player.oid then
			fail("botmusic: no buff target after a buff request")
		end
		if not anyLine(linesOf(mus, t), "musician", "listen") then
			fail("botmusic: no 'listen' line")
		end
		-- The song stops: started again, and the buff target set again
		mus.music, mus.buffTarget = nil, nil
		t = nowMs()
		sim.run(30)
		if #commands(mus, "startmusic", t) ~= 1 or mus.buffTarget ~= player.oid then
			fail("botmusic: the buff target wasn't set again after a restart")
		end

		-- From another planet by tell: directions by tell; the buff target when they come in
		local far = makePlayer("Dex", "naboo", 1000, 1000)
		t = nowMs()
		speak(mus, far, "buff me when I'm there?", "tell")
		sim.run(5)
		local tells = linesOf(mus, t, log.tells)
		if #tells ~= 1 or tells[1].to ~= "Dex" or not anyLine(tells, "musician", "far") or
			#commands(mus, "setperformancebufftarget", t) > 0 then
			fail("botmusic: a far tell got " .. #tells .. " tells")
		end
		far.planet, far.x, far.y = mus.planet, mus.x + 4, mus.y + 2
		sim.run(10)
		set = commands(mus, "setperformancebufftarget", t)
		if #set ~= 1 or set[1].target ~= far.oid or not anyLine(linesOf(mus, t), "musician", "listen") then
			fail("botmusic: no buff target on arrival")
		end

		-- Battle fatigue, no brain: a hint to listen
		t = nowMs()
		speak(mus, player, "my battle fatigue is awful")
		sim.run(3)
		if not anyLine(linesOf(mus, t), "musician", "watchHint") then
			fail("botmusic: no hint to listen for battle fatigue")
		end

		-- Nothing in hand at login: the roster's instrument equipped again, then the song
		api.botLogout(mus.first)
		mus.holdR = nil
		t = nowMs()
		api.botLogin(mus.first)
		local equips = calls("botEquip", mus, t)
		starts = commands(mus, "startmusic", t)
		if #equips ~= 1 or equips[1].a ~= "object/tangible/instrument/bandfill.iff" or #starts ~= 1 or not starts[1].ok then
			fail("botmusic: the instrument wasn't equipped again (" .. #equips .. " botEquip)")
		end

		-- A provoked fight: no music while it lasts or while it walks back, then the song again
		sim.run(65)
		player.x, player.y = mus.x + 3, mus.y
		t = nowMs()
		insult(mus, player, 3, 1)
		sim.run(5)
		if BotFight:fighting(mus.oid) ~= player.oid or mus.music ~= nil then
			fail("botmusic: no fight after three insults, or still playing")
		end
		sim.run(60)
		if #commands(mus, "startmusic", t) > 0 then
			fail("botmusic: startmusic in the middle of a fight")
		end
		local fightOver = nowMs()
		incap(player)
		player.incap = false
		sim.run(8)
		if #commands(mus, "startmusic", fightOver) > 0 or #calls("botMoveTo", mus, fightOver) ~= 1 then
			fail("botmusic: startmusic while walking back (or no walk back)")
		end
		sim.run(30)
		starts = commands(mus, "startmusic", fightOver)
		if #starts ~= 1 or not starts[1].ok or mus.music == nil then
			fail("botmusic: no song after the fight (" .. #starts .. " startmusic)")
		end

		-- A second login (BotJobs:restart): one chain
		sim.call("BotJobs", "onLogin", mus)
		t = nowMs()
		sim.run(1200)
		local n = #commands(mus, "flourish", t)
		if n > 1200 / 20 + 2 or n < 1200 / 45 then
			fail("botmusic: " .. n .. " flourishes in 20 minutes after a second login")
		end

		-- Logout: quiet
		api.botLogout(mus.first)
		t = nowMs() + 1
		sim.run(120)
		if #commands(mus, nil, t) > 0 then
			fail("botmusic: a logged-out musician still plays")
		end

		fails = failedCommands(mus, 0)
		if #fails > 0 then
			fail("botmusic: failed commands: " .. table.concat(fails, "; "))
		end
		realPrint(string.format("botmusic %d commands: %d flourishes, %d song changes, %d starts; %d lines, %d tells",
			#commands(mus, nil, 0), #commands(mus, "flourish", 0), #commands(mus, "changemusic", 0),
			#commands(mus, "startmusic", 0), #log.says, #log.tells))
		teardown()
	end

	-- Scenario: the smuggler

	function scenarios.botslice()
		setup("/nonexistent/sim-talk")
		local smug = byJob("smuggler")
		local s = BotRoster.settings

		api.botLogin(smug.first)
		local stocked = calls("botStockSlicingTools", smug, 0)
		if #stocked ~= 1 or stocked[1].a ~= s.sliceToolStock or smug.tools ~= s.sliceToolStock then
			fail("botslice: tools not stocked at login")
		end

		local player = makePlayer("Cameren", smug.planet, smug.x + 2, smug.y)
		player.target = smug.oid

		-- Keywords with no brain: the price, and how it works
		local t = nowMs()
		speak(smug, player, "how much to slice my armor?")
		sim.run(2)
		local said = linesOf(smug, t)
		if #said ~= 1 or not anyLine(said, "smuggler", "price") or not said[1].text:find("4,000", 1, true) or
			not said[1].text:find("6,000", 1, true) then
			fail("botslice: the price by keyword (" .. #said .. " lines)")
		end
		t = nowMs()
		sim.run(4)
		speak(smug, player, "can you slice stuff?")
		sim.run(2)
		if not anyLine(linesOf(smug, t), "smuggler", "howto") then
			fail("botslice: no how-to by keyword")
		end

		-- The deal, as a player does it: drag, item and credits in, accept, then verify once the bot has accepted
		local function deal(label, items, credits)
			local before = {bot = smug.cash, human = player.cash, trades = #log.trades}
			local t1 = nowMs()
			requestTrade(player, smug)
			sim.run(1)
			if trades[smug.oid] == nil or trades[smug.oid].stage ~= "open" then
				fail(label .. ": the trade wasn't opened")
				return t1, before
			end
			offer(player, smug, items, credits)
			sim.run(3)
			humanAccept(player, smug)
			sim.run(3)
			before.verified = humanVerify(player, smug)
			sim.run(1)
			return t1, before
		end

		local armor = makeItem(player, "armor", "Composite Chest Plate")
		local t1, before = deal("botslice armor", {armor}, 4000)
		if not before.verified then
			fail("botslice: the smuggler never accepted a right offer, so the player couldn't verify")
		end
		-- (sliced in the step that completed the trade)
		if #log.trades ~= before.trades + 1 or not player.inventory[armor.oid] or smug.inventory[armor.oid] or not armor.sliced then
			fail("botslice: the armor wasn't sliced and returned at once (" .. (#log.trades - before.trades) .. " trades)")
		end
		sim.run(10)
		said = linesOf(smug, t1)
		if not anyLine(said, "smuggler", "open") then
			fail("botslice: no price line when the trade opened")
		end
		if countLines(said, "smuggler", "ready") ~= 1 then
			fail("botslice: " .. countLines(said, "smuggler", "ready") .. " 'ready' lines for a right offer")
		end
		local result = nil
		for _, l in ipairs(said) do
			if isLine(l.text, "smuggler", "result") then
				result = l.text
			end
		end
		local want = (armor.stat == "effectiveness" and "+" or "-") .. armor.percent .. "% " .. tostring(armor.stat)
		if result == nil or not result:find(want, 1, true) or not result:find("Composite Chest Plate", 1, true) then
			fail("botslice: the result line '" .. tostring(result) .. "' doesn't say " .. want)
		end
		if not anyLine(said, "smuggler", "thanksJob") then
			fail("botslice: no thanks after the job")
		end
		if smug.cash ~= before.bot + 4000 or player.cash ~= before.human - 4000 then
			fail("botslice: the credits didn't change hands")
		end
		if anyLine(said, "smuggler", "thanks") then
			fail("botslice: the payment was thanked as a tip")
		end
		if #calls("botStockSlicingTools", smug, t1) ~= 1 then
			fail("botslice: tools not restocked after the job")
		end
		local verifies = calls("botTradeVerify", smug, t1)
		if #verifies < 2 or verifies[1].a ~= 4000 or verifies[1].b ~= armor.oid then
			fail("botslice: botTradeVerify wasn't given the price and the item")
		end

		-- A weapon, 6,500: the extra 500 is a tip, thanked by name
		local rifle = makeItem(player, "weapon", "T21 Rifle")
		t1, before = deal("botslice weapon", {rifle}, 6500)
		sim.run(12)
		said = linesOf(smug, t1)
		if not rifle.sliced or not player.inventory[rifle.oid] or smug.cash ~= before.bot + 6500 then
			fail("botslice: the rifle wasn't sliced for 6,500")
		end
		local tipThanks = false
		for _, l in ipairs(said) do
			if isLine(l.text, "smuggler", "thanks") and l.text:find("Cameren", 1, true) then
				tipThanks = true
			end
		end
		if not tipThanks then
			fail("botslice: the 500 on top wasn't thanked")
		end

		-- Short: what's missing (once, though they accept), no accept from the bot; then the rest, and it goes through
		local boots = makeItem(player, "armor", "Padded Boots")
		local trades0 = #log.trades
		t = nowMs()
		requestTrade(player, smug)
		sim.run(1)
		offer(player, smug, {boots}, 3000)
		sim.run(3)
		humanAccept(player, smug)
		sim.run(3)
		if humanVerify(player, smug) then
			fail("botslice: the smuggler accepted a short payment")
		end
		said = linesOf(smug, t)
		local shorts = 0
		for _, l in ipairs(said) do
			if isLine(l.text, "smuggler", "short") then
				shorts = shorts + 1
				if not l.text:find("1,000", 1, true) or not l.text:find("3,000", 1, true) then
					fail("botslice: the short line doesn't say 3,000 and 1,000: " .. l.text)
				end
			end
		end
		if shorts ~= 1 or #log.trades ~= trades0 then
			fail("botslice: a short payment got " .. shorts .. " short lines and " .. (#log.trades - trades0) .. " trades")
		end
		offer(player, smug, {boots}, 4000)
		sim.run(3)
		humanAccept(player, smug)
		sim.run(3)
		humanVerify(player, smug)
		sim.run(2)
		if #log.trades ~= trades0 + 1 or not boots.sliced then
			fail("botslice: making up the price didn't go through")
		end

		-- Refusals: a sliced item, a Jedi's weapon, a non-armor item, two items
		local function refused(label, list, credits, kind)
			sim.run(10)
			local n0 = #log.trades
			local t2 = nowMs()
			requestTrade(player, smug)
			sim.run(1)
			offer(player, smug, list, credits)
			sim.run(3)
			humanAccept(player, smug)
			sim.run(3)
			if humanVerify(player, smug) or #log.trades ~= n0 then
				fail("botslice: " .. label .. " was accepted")
			end
			if countLines(linesOf(smug, t2), "smuggler", kind) ~= 1 then
				fail("botslice: " .. countLines(linesOf(smug, t2), "smuggler", kind) .. " '" .. kind .. "' lines for " .. label)
			end
			humanAbort(player, smug)
			sim.run(2)
			return t2
		end
		refused("a sliced item", {armor}, 4000, "sliced")
		local saber = makeItem(player, "weapon", "Lightsaber", {jedi = true})
		refused("a Jedi's weapon", {saber}, 6000, "unsliceable")
		local datapad = makeItem(player, "other", "Datapad")
		local t2 = refused("a datapad", {datapad}, 4000, "wrongKind")
		local wrong = false
		for _, l in ipairs(linesOf(smug, t2)) do
			if isLine(l.text, "smuggler", "wrongKind") and l.text:find("Datapad", 1, true) then
				wrong = true
			end
		end
		if not wrong then
			fail("botslice: the wrong-kind line doesn't name the item")
		end
		local helmet, gloves = makeItem(player, "armor", "Helmet"), makeItem(player, "armor", "Gloves")
		refused("two pieces for one price", {helmet, gloves}, 4000, "short")
		if readData("bot:" .. smug.oid .. ":trade:step") ~= 0 then
			fail("botslice: the trade state wasn't cleared after an abort")
		end

		-- The customer names the type: encumbrance on armor, speed on weapons; then several pieces at once, each at its
		-- price: all sliced with those types and back in the one trade
		local tChoose = nowMs()
		speak(smug, player, "encumbrance and speed please")
		sim.run(2)
		if not anyLine(linesOf(smug, tChoose), "smuggler", "chosen") then
			fail("botslice: naming the slice type wasn't confirmed")
		end
		local rifle = makeItem(player, "weapon", "T21 Rifle")
		local nLot = #log.trades
		local _, lotBefore = deal("botslice lot", {helmet, gloves, rifle}, 14000)
		if not lotBefore.verified or #log.trades ~= nLot + 1 then
			fail("botslice: the smuggler didn't take two armor pieces and a weapon for 14,000")
		end
		for _, it in ipairs({helmet, gloves, rifle}) do
			if not it.sliced or not player.inventory[it.oid] or smug.inventory[it.oid] then
				fail("botslice: the lot's " .. it.itemName .. " wasn't sliced and returned")
			end
			if it.stat ~= (it.kind == "armor" and "encumbrance" or "speed") then
				fail("botslice: the lot's " .. it.itemName .. " got " .. tostring(it.stat) .. ", not the type named")
			end
		end
		speak(smug, player, "random")
		sim.run(2)
		sim.run(10)

		-- A weapon with a powerup: the warning, and no accept until a few seconds after it; then the slice
		local pistol = makeItem(player, "weapon", "DL-44 Pistol", {powerup = true})
		local n0 = #log.trades
		t = nowMs()
		requestTrade(player, smug)
		sim.run(1)
		offer(player, smug, {pistol}, 6000)
		sim.run(3)
		humanAccept(player, smug)
		sim.run(2)
		if not anyLine(linesOf(smug, t), "smuggler", "powerup") or humanVerify(player, smug) then
			fail("botslice: no powerup warning before accepting (or it accepted at once)")
		end
		sim.run(8)
		if not humanVerify(player, smug) then
			fail("botslice: the smuggler never accepted after the powerup warning")
		end
		sim.run(2)
		if #log.trades ~= n0 + 1 or not pistol.sliced or pistol.powerup then
			fail("botslice: the pistol wasn't sliced after the warning")
		end

		-- A slice that fails: the item back unsliced, the credits back by /tip, no thanks for a tip
		opt.sliceError = "the laser knife broke"
		local vest = makeItem(player, "armor", "Bone Vest")
		t1, before = deal("botslice failure", {vest}, 4000)
		sim.run(12)
		opt.sliceError = nil
		said = linesOf(smug, t1)
		if vest.sliced or not player.inventory[vest.oid] or player.cash ~= before.human or smug.cash ~= before.bot then
			fail("botslice: a failed slice wasn't refunded (player " .. (player.cash - before.human) .. " credits)")
		end
		if not anyLine(said, "smuggler", "failed") or anyLine(said, "smuggler", "thanks") or anyLine(said, "smuggler", "result") then
			fail("botslice: the lines after a failed slice")
		end
		local tips = commands(smug, "tip", t1)
		if #tips ~= 1 or tips[1].target ~= player.oid or tips[1].args ~= "4000" or not tips[1].ok then
			fail("botslice: the refund wasn't a /tip of 4000")
		end

		-- Their inventory is full: the result, then the item comes back by a trade window
		opt.ownerFull = true
		local belt = makeItem(player, "armor", "Utility Belt")
		t1, before = deal("botslice full inventory", {belt}, 4000)
		sim.run(10)
		opt.ownerFull = false
		said = linesOf(smug, t1)
		if not belt.sliced or not player.inventory[belt.oid] or not anyLine(said, "smuggler", "giveBack") or
			not anyLine(said, "smuggler", "returned") then
			fail("botslice: a full inventory: no give-back line or no 'returned' line")
		end

		-- Busy: someone else's trade waits
		local other = makePlayer("Mara", smug.planet, smug.x - 2, smug.y + 1)
		sim.run(10)
		requestTrade(player, smug)
		sim.run(1)
		t = nowMs()
		requestTrade(other, smug)
		sim.run(2)
		if trades[smug.oid] == nil or trades[smug.oid].partner ~= player.oid or not anyLine(linesOf(smug, t), "smuggler", "busy") then
			fail("botslice: a second customer wasn't told to wait")
		end
		smug.tradeRequest = nil

		-- The watchdog: a trade that goes nowhere is called off
		t = nowMs()
		sim.run(BotSmuggler.tradeTimeout + 10)
		if trades[smug.oid] ~= nil or #calls("botTradeAbort", smug, t) ~= 1 or not anyLine(linesOf(smug, t), "smuggler", "timeout") then
			fail("botslice: a stale trade wasn't called off")
		end

		-- No trade bindings in the build: no trade opened, the request refused
		local savedSlice = botSlice
		botSlice = nil
		sim.run(10)
		t = nowMs()
		requestTrade(other, smug)
		sim.run(2)
		botSlice = savedSlice
		if trades[smug.oid] ~= nil or #calls("botTradeAccept", smug, t) > 0 or not anyLine(linesOf(smug, t), "smuggler", "closed") then
			fail("botslice: opened a trade with no botSlice")
		end

		-- Idling: emotes between jobs
		t = nowMs()
		sim.run(1800)
		local emotes = emotesOf(smug, t)
		if #emotes < 5 or #emotes > 25 then
			fail("botslice: " .. #emotes .. " emotes in 30 idle minutes")
		end

		local fails = failedCommands(smug, 0)
		if #fails > 0 then
			fail("botslice: failed commands: " .. table.concat(fails, "; "))
		end
		realPrint(string.format("botslice %d trades, %d slices, %d lines, %d emotes, %d cr; first result: %s", #log.trades,
			#calls("botSlice", smug, 0), #linesOf(smug, 0), #emotesOf(smug, 0), smug.cash, tostring(result)))
		teardown()
	end

	-- Scenario: provoked fights and duels

	-- The faked talk bridge: a heartbeat, and each request answered after 2 s; a crude line is flagged "insult"
	local function fakeBridge(dir, requests)
		local bridge = {on = true}
		local function heartbeat()
			local f = io.open(dir .. "/alive", "w")
			f:write(tostring(sim.now) .. "\n")
			f:close()
		end
		local function tick()
			if not bridge.on then
				return
			end
			heartbeat()
			local handle = io.popen('ls "' .. dir .. '/req" 2>/dev/null')
			for name in handle:lines() do
				if name:match("%.json$") then
					local path = dir .. "/req/" .. name
					local f = io.open(path)
					local body = f:read("a")
					f:close()
					os.remove(path)
					local id = body:match('"id":"([^"]+)"')
					local text = (body:match('"text":"([^"]*)"') or ""):lower()
					table.insert(requests, text)
					if body:find('"type":"say"', 1, true) and id ~= nil then
						local reply = text:find("nerf herder", 1, true) and "ok\nangry\nSay that again, I dare you.\n\ninsult\n" or
							"ok\nhappy\nSure thing.\n\n\n"
						sim.schedule(2000, function()
							local out = io.open(dir .. "/rep/" .. id .. ".txt", "w")
							out:write(reply)
							out:close()
						end)
					end
				end
			end
			handle:close()
			sim.schedule(1000, tick)
		end
		heartbeat()
		tick()
		return bridge
	end

	function scenarios.botfight()
		setup("/nonexistent/sim-talk")
		local doc, mus, smug = byJob("doctor"), byJob("musician"), byJob("smuggler")
		for _, b in ipairs({doc, mus, smug}) do
			api.botLogin(b.first)
		end
		local player = makePlayer("Cameren", doc.planet, doc.x + 3, doc.y)
		local home = {doc.x, doc.y}

		-- One insult: nothing of its own; two: the warning; three: the fight
		local t = nowMs()
		insult(doc, player, 1)
		sim.run(5)
		if #linesOf(doc, t) > 0 then
			fail("botfight: a line after the first insult")
		end
		insult(doc, player, 1)
		sim.run(5)
		if not anyLine(linesOf(doc, t), "fight", "warn") or #calls("botStartFight", doc, t) > 0 then
			fail("botfight: no warning after the second insult")
		end
		t = nowMs()
		insult(doc, player, 1)
		sim.run(5)
		local started = calls("botStartFight", doc, t)
		if #started ~= 1 or started[1].a ~= player.oid or BotFight:fighting(doc.oid) ~= player.oid then
			fail("botfight: no fight after the third insult")
		end
		local follows = calls("botFollow", doc, t)
		if not anyLine(linesOf(doc, t), "fight", "start") or #follows ~= 1 or follows[1].b[1] ~= BotFight.fightNear or
			#calls("botSetTarget", doc, t) < 1 or not doc.inCombat then
			fail("botfight: the fight didn't start with a line, a target, combat and the bot going at them")
		end

		-- The player goes down: the body ends it; a gloat, then the walk back
		sim.run(20)
		t = nowMs()
		incap(player)
		sim.run(3)
		if BotFight:fighting(doc.oid) ~= 0 or not anyLine(linesOf(doc, t), "fight", "gloat") then
			fail("botfight: no gloat after the player went down")
		end
		if #calls("botEndFight", doc, t) > 0 then
			fail("botfight: ended a fight the body had already ended")
		end
		player.incap = false
		sim.run(12)
		local moves = calls("botMoveTo", doc, t)
		if #moves ~= 1 or math.abs(moves[1].a[1] - home[1]) > 0.01 or math.abs(moves[1].a[3] - home[2]) > 0.01 then
			fail("botfight: the doctor didn't walk back to its spot")
		end
		if BotFight:busy(doc.oid) or math.abs(doc.x - home[1]) > 0.01 then
			fail("botfight: still walking back after arriving")
		end

		-- The cooldown: three more insults start nothing; after it, they do
		t = nowMs()
		insult(doc, player, 3, 2)
		sim.run(5)
		if #calls("botStartFight", doc, t) > 0 then
			fail("botfight: a fight in the cooldown")
		end
		sim.run(BotRoster.settings.fightCooldown)
		t = nowMs()
		insult(doc, player, 3, 4)
		sim.run(5)
		if #calls("botStartFight", doc, t) ~= 1 then
			fail("botfight: no fight after the cooldown")
		end
		if countLines(linesOf(doc, t), "fight", "warn") ~= 1 then
			fail("botfight: " .. countLines(linesOf(doc, t), "fight", "warn") .. " warnings before the second fight")
		end
		-- ...this time the bot goes down: it sulks once it's up
		t = nowMs()
		incap(doc)
		sim.run(10)
		if anyLine(linesOf(doc, t), "fight", "sulk") then
			fail("botfight: sulked while incapacitated")
		end
		doc.incap = false
		sim.run(5)
		if not anyLine(linesOf(doc, t), "fight", "sulk") then
			fail("botfight: no sulk after going down")
		end
		sim.run(20)

		-- Insults spread wider than the window never add up
		sim.run(BotRoster.settings.fightCooldown)
		t = nowMs()
		insult(doc, player, 1, 400)
		insult(doc, player, 1, 700)
		insult(doc, player, 1, 5)
		if #calls("botStartFight", doc, t) > 0 then
			fail("botfight: insults over " .. BotRoster.settings.insultWindow .. " s apart started a fight")
		end
		-- Not an insult: nothing
		sim.call("BotFight", "onReply", doc, player.oid, "", "spatial")
		sim.call("BotFight", "onReply", doc, player.oid, "polite", "spatial")

		-- From another planet: "say it to my face", no fight; the next insult in reach starts it
		sim.run(BotRoster.settings.insultWindow + 10)
		local far = makePlayer("Dex", "naboo", 1000, 1000)
		t = nowMs()
		for i = 1, 3 do
			sim.call("BotFight", "onReply", smug, far.oid, "insult", "tell")
			sim.run(3)
		end
		local tells = linesOf(smug, t, log.tells)
		if #calls("botStartFight", smug, t) > 0 or not anyLine(tells, "fight", "faceMe") then
			fail("botfight: an insult by tell from afar")
		end
		far.planet, far.x, far.y = smug.planet, smug.x + 4, smug.y
		t = nowMs()
		sim.call("BotFight", "onReply", smug, far.oid, "insult", "spatial")
		sim.run(5)
		if #calls("botStartFight", smug, t) ~= 1 then
			fail("botfight: no fight when the far insulter came over")
		end
		-- They run off: the bot calls it off
		far.x = smug.x + 150
		t = nowMs()
		sim.run(6)
		if BotFight:fighting(smug.oid) ~= 0 or #calls("botEndFight", smug, t) ~= 1 or not anyLine(linesOf(smug, t), "fight", "ended") then
			fail("botfight: a fight with someone who ran off wasn't called off")
		end
		far.x = smug.x + 4
		sim.run(30)

		-- Duels: accepted, fought to the first incap (the body ends it), never a deathblow
		local duelist = makePlayer("Rook", doc.planet, doc.x + 5, doc.y)
		local function challenge(who, bot)
			who.duelList[bot.oid] = true
			fire(bot, "duel", who, "challenged")
		end
		t = nowMs()
		challenge(duelist, doc)
		sim.run(2)
		local duels = commands(doc, "duel", t)
		if #duels ~= 1 or duels[1].target ~= duelist.oid or api.botDuelState(doc, duelist) ~= "dueling" or
			not anyLine(linesOf(doc, t), "fight", "duelAccept") or doc.targetOid ~= duelist.oid or not doc.inCombat then
			fail("botfight: a duel challenge wasn't accepted and fought")
		end
		sim.run(15)
		t = nowMs()
		incap(duelist)
		sim.run(3)
		if api.botDuelState(doc, duelist) ~= "none" or BotFight:fighting(doc.oid) ~= 0 or
			not anyLine(linesOf(doc, t), "fight", "duelWon") then
			fail("botfight: the duel didn't end at the challenger's incap with a line")
		end
		duelist.incap = false
		-- Again at once: too soon after someone went down
		t = nowMs()
		challenge(duelist, doc)
		sim.run(2)
		if #commands(doc, "duel", t) > 0 or not anyLine(linesOf(doc, t), "fight", "tooSoon") then
			fail("botfight: a duel right after an incap wasn't refused")
		end
		duelist.duelList[doc.oid] = nil

		-- A duel the bot loses, and the body doesn't end it: the backstop does, and the bot sulks once it's up
		local second = makePlayer("Siva", smug.planet, smug.x + 3, smug.y + 1)
		challenge(second, smug)
		sim.run(10)
		opt.bodyIgnoresIncap = true
		t = nowMs()
		incap(smug)
		sim.run(2)
		if BotFight:fighting(smug.oid) == 0 then
			fail("botfight: the backstop ended a duel before giving the body its few seconds")
		end
		sim.run(BotFight.backstopSeconds + 3)
		if BotFight:fighting(smug.oid) ~= 0 or api.botDuelState(smug, second) ~= "none" or #calls("botEndFight", smug, t) ~= 1 then
			fail("botfight: the backstop didn't end the duel")
		end
		opt.bodyIgnoresIncap = false
		smug.incap = false
		sim.run(8)
		if not anyLine(linesOf(smug, t), "fight", "duelLost") then
			fail("botfight: no line after losing the duel")
		end

		-- A duel the player calls off: a line, no cooldown, and a new challenge is taken
		sim.run(BotRoster.settings.fightCooldown + 10)
		local third = makePlayer("Orla", mus.planet, mus.x + 3, mus.y - 1)
		challenge(third, mus)
		sim.run(10)
		t = nowMs()
		runCommand(third, "endduel", mus.oid, "")
		sim.run(3)
		if BotFight:fighting(mus.oid) ~= 0 or not anyLine(linesOf(mus, t), "fight", "duelEnded") then
			fail("botfight: a duel called off by the player")
		end
		sim.run(10)
		t = nowMs()
		challenge(third, mus)
		sim.run(2)
		if #commands(mus, "duel", t) ~= 1 then
			fail("botfight: a new challenge after a called-off duel wasn't taken")
		end
		-- ...and while it duels, someone else's challenge gets "busy"
		t = nowMs()
		challenge(duelist, mus)
		sim.run(2)
		if #commands(mus, "duel", t) > 0 or not anyLine(linesOf(mus, t), "fight", "busy") then
			fail("botfight: a second challenge mid-duel")
		end
		duelist.duelList[mus.oid] = nil
		incap(third)
		sim.run(3)
		third.incap = false
		sim.run(20)

		-- Dead: cloned, then back at its spot with its job started afresh
		t = nowMs()
		local gen = readData("bot:" .. doc.oid .. ":gen")
		doc.dead = true
		fire(doc, "died", nil, "")
		sim.run(BotFight.cloneDelayMs / 1000 + 8)
		if #calls("botClone", doc, t) ~= 1 then
			fail("botfight: a dead doctor wasn't cloned")
		end
		sim.run(BotFight.homeAfterCloneMs / 1000 + 5)
		if math.abs(doc.x - home[1]) > 0.01 or readData("bot:" .. doc.oid .. ":gen") ~= gen + 1 then
			fail("botfight: after cloning the doctor isn't back at its spot with its job restarted")
		end

		-- Logout mid-fight: the fight ends with it
		sim.run(BotRoster.settings.fightCooldown + 10)
		player.x, player.y = doc.x + 3, doc.y
		insult(doc, player, 3, 2)
		sim.run(5)
		t = nowMs()
		if BotFight:fighting(doc.oid) ~= player.oid then
			fail("botfight: no fight before the logout")
		end
		api.botLogout(doc.first)
		if BotFight:fighting(doc.oid) ~= 0 or #calls("botEndFight", doc, t) ~= 1 then
			fail("botfight: a logout didn't end the fight")
		end
		api.botLogin(doc.first)
		sim.run(10)

		-- Insults flagged by the brain (the faked talk bridge)
		local dir = os.getenv("SIM_TALK_DIR")
		if dir ~= nil then
			LivingTalk.dir = dir
			local requests = {}
			local bridge = fakeBridge(dir, requests)
			sim.run(BotRoster.settings.fightCooldown + 10)
			player.target = doc.oid
			t = nowMs()
			for i = 1, 3 do
				speak(doc, player, "you're a nerf herder, doc")
				sim.run(10)
			end
			if #calls("botStartFight", doc, t) ~= 1 or #requests < 3 then
				fail("botfight: the brain's insult flags didn't start a fight (" .. #requests .. " requests)")
			end
			bridge.on = false
			os.remove(dir .. "/alive")
			sim.run(3)
		else
			realPrint("botfight the brain part skipped (set SIM_TALK_DIR to an empty directory with req/ and rep/)")
		end

		for _, b in ipairs({doc, mus, smug}) do
			local fails = failedCommands(b, 0)
			if #fails > 0 then
				fail("botfight: " .. b.first .. "'s failed commands: " .. table.concat(fails, "; "))
			end
		end
		realPrint(string.format("botfight %d fights, %d ended by the bot, %d duels accepted, %d clones; %d lines",
			#calls("botStartFight", nil, 0), #calls("botEndFight", nil, 0), #commands(doc, "duel", 0) + #commands(smug, "duel", 0) +
			#commands(mus, "duel", 0), #calls("botClone", nil, 0), #log.says))
		for i = 1, math.min(#sim.chatLog, 8) do
			realPrint("         " .. sim.chatLog[i])
		end
		teardown()
	end

	table.insert(order, "botmusic")
	table.insert(order, "botband")
	table.insert(order, "botslice")
	table.insert(order, "botfight")
end
