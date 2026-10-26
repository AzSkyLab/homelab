-- Bot players (Phase 9b): the crew's tactics table, doctrine and orders. Included from crew.lua (after BotCrew exists).
-- Spec: ~/github/swgemu/specs/2026-10-25-crew-doctrine/.
--
-- The Lua plays the fight every 1.5 s and stays the only thing that acts. Its choices hang on a few numbers (heal at 75%,
-- hold fire 3 s, ...), which are the DEFAULTS of this table. A bot's value for an entry is looked up in layers:
--   order  what a player told it in chat ("Quillan, just heal"): until "as you were", the crew going home or another
--          order on the same entry (one on a named creature ends when that creature dies);
--   plan   what the language model set for this fight (a plan request, below): ends with the fight;
--   base   what the model made of the bot's doctrine (the bridge's /run/talk/tactics/base.txt): kept across fights;
--   the default: today's number.
-- (An order beats a plan: the plan layer can't undo what a player said.) With no model and no files, every bot fights on the
-- defaults, as before this phase.
--
-- Every value is checked on its way in (an entry the role doesn't have is dropped, a number is clamped, an unknown word is
-- dropped) and again when it is read, and the turns keep the hard rules whatever the table says: the medic heals anyone under
-- 25% before anything else, no area attack on creatures that aren't fighting the group or near a lair, nobody attacks a human
-- or leaves the group, the retreat at three members down.
--
-- Shared memory (strings): bot:<oid>:crew:t:<layer>:<entry> for order and plan, crew:tbase:<first>:<entry> for the base
-- (by first name, so it holds while a bot logs in and out). Group state under the leader: planAt, planId, ...
--
-- The model never acts move by move. Plans: the group's first crew bot that is up writes a "plan" request on changes in the
-- fight (the pull, a new creature on the group, a member down, a member under 30%, the medic under its mind floor), at most
-- every planEvery seconds, polls for the reply once a second, drops one that is older than planLate seconds or comes after the
-- fight, and writes the plan layer of each bot named in it. Orders come with a chat reply (BotJobs:poll -> tacticOrders).

local HEALTH, ACTION, MIND = 0, 3, 6

BotCrew.planEvery = 10
BotCrew.planLate = 15
-- A fight with nobody fighting for this long (s) is over for the plan
BotCrew.planQuiet = 4
-- A member under this share of health or action asks for a plan
BotCrew.planLow = 0.3
-- A plan layer is dropped this long (s) after it was written, whatever
BotCrew.planKeep = 240
-- The base table file is read at most this often (s); after a lesson in game, every planWatchEvery for planWatch seconds
BotCrew.baseEvery = 60
BotCrew.baseWatchEvery = 5
BotCrew.baseWatch = 90
-- The medic heals anyone under this share of health or action before anything else (a hard rule)
BotCrew.nearDeath = 0.25
-- How many creatures and what a plan request tells (the model reads it, so keep it short)
BotCrew.planCreatures = 8

BotCrew.tacticLayers = {"order", "plan", "base"}

local ALL = {tank = true, rifleman = true, medic = true, ranger = true, squadleader = true, entertainer = true, commando = true}
local RANGED = {rifleman = true, ranger = true, squadleader = true, entertainer = true, commando = true, medic = true}

-- Each entry: roles (who has it), kind, its limits and its default (today's number). specials' default is the roster's
-- specialsHam (BotCrew:setting), so a layer-less bot is exactly as before.
BotCrew.tactics = {
	-- What a bot attacks: the tank's target (today; for the tank itself, the leader's), the leader's, the creature with the least or
	-- most health, the one on the medic, or one named creature (creature:<oid>)
	focus = {roles = {tank = true, rifleman = true, ranger = true, squadleader = true, entertainer = true, commando = true},
		kind = "focus", values = {"tank", "leader", "weakest", "strongest", "medic"}, default = "tank"},
	-- Seconds a ranged bot waits for the tank to take a creature (0: it doesn't wait)
	hold = {roles = RANGED, kind = "number", min = 0, max = 6, integer = true, default = function(self) return self.holdFor end},
	-- The band a ranged bot stands in, moved 5 m closer or further (inside the weapon's reach)
	range = {roles = {rifleman = true, ranger = true, squadleader = true, entertainer = true, medic = true},
		kind = "enum", values = {"close", "band", "far"}, default = "band"},
	-- Specials only above 30%, 50% or 75% of each pool
	specials = {roles = ALL, kind = "enum", values = {"full", "normal", "save"}, default = "normal"},
	-- Whom the tank taunts for and the ranger rescues first: the medic, or a member by first name
	protect = {roles = {tank = true, ranger = true}, kind = "protect", default = "medic"},
	healAt = {roles = {medic = true}, kind = "number", min = 0.5, max = 0.9, default = function(self) return self.healBelow.fight end},
	reviveFirst = {roles = {medic = true}, kind = "enum", values = {"yes", "no"}, default = "yes"},
	packs = {roles = {medic = true}, kind = "enum", values = {"area", "single", "none"}, default = "area"},
	mindFloor = {roles = {medic = true}, kind = "number", min = 0.3, max = 0.8, default = function(self) return self.dotMindFloor end},
	-- Shoots between heals (yes), or heals and stays out of it unless something is on it
	shoot = {roles = {medic = true, entertainer = true}, kind = "enum", values = {"yes", "no"}, default = "yes"},
	-- The commando: cones and grenades, cones only, or neither ("save the grenades")
	area = {roles = {commando = true}, kind = "enum", values = {"both", "cones", "none"}, default = "both"},
	-- The squad leader calls the retreat when the tank is down and two members are under this
	retreatAt = {roles = {squadleader = true}, kind = "number", min = 0.2, max = 0.5, default = function(self) return self.retreatLow end},
	-- Which calls the squad leader makes: all, none, or some of rally, volley, formup, steadyaim
	calls = {roles = {squadleader = true}, kind = "set", values = {"rally", "volley", "formup", "steadyaim"}, default = "all"},
}

-- The shares specials stands for
BotCrew.specialsShare = {full = 0.30, normal = 0.50, save = 0.75}

local function key(oid, field)
	return "bot:" .. oid .. ":" .. field
end

local function ckey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

local function gkey(leaderOid, field)
	return "crew:group:" .. leaderOid .. ":" .. field
end

local function put(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
end

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

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function oidList(text)
	local out = {}

	for digits in string.gmatch(text or "", "%d+") do
		table.insert(out, tonumber(digits))
	end

	return out
end

local function layerKey(oid, layer, name)
	return "bot:" .. oid .. ":crew:t:" .. layer .. ":" .. name
end

local function baseKey(first, name)
	return "crew:tbase:" .. first .. ":" .. name
end

local function firstOf(oid)
	return (readStringData(key(oid, "first")):lower():gsub("[^%a']", ""))
end

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then
			return true
		end
	end

	return false
end

-- The canonical text of a value for an entry, or nil when it isn't one (the limits are enforced here: a number is clamped)
function BotCrew:tacticClean(name, raw)
	local def = self.tactics[name]

	if def == nil or raw == nil then
		return nil
	end

	raw = trim(raw):lower()

	if raw == "" then
		return nil
	end

	if def.kind == "number" then
		local n = tonumber((raw:gsub("%%$", "")))

		if n == nil then
			return nil
		end

		-- ("80" or "80%" for a share)
		if def.max <= 1 and n > 1 then
			n = n / 100
		end

		n = math.max(def.min, math.min(def.max, n))

		if def.integer then
			return string.format("%d", math.floor(n + 0.5))
		end

		return string.format("%.2f", n)
	elseif def.kind == "enum" then
		return contains(def.values, raw) and raw or nil
	elseif def.kind == "focus" then
		if contains(def.values, raw) then
			return raw
		end

		local oid = raw:match("^creature:(%d+)$")

		return oid ~= nil and ("creature:" .. oid) or nil
	elseif def.kind == "protect" then
		if raw == "medic" or raw:match("^[a-z][a-z']+$") ~= nil and #raw <= 20 then
			return raw
		end

		return nil
	elseif def.kind == "set" then
		if raw == "all" or raw == "none" then
			return raw
		end

		local picked = {}

		for word in raw:gmatch("[a-z]+") do
			if word == "all" then
				return "all"
			elseif contains(def.values, word) then
				picked[word] = true
			else
				return nil
			end
		end

		local out = {}

		for _, word in ipairs(def.values) do
			if picked[word] then
				table.insert(out, word)
			end
		end

		if #out == 0 then
			return nil
		elseif #out == #def.values then
			return "all"
		end

		return table.concat(out, ",")
	end

	return nil
end

-- A stored text as the value the turns use: a number for a number, else the text. A creature that is gone or dead ends a focus
-- on it (nil)
function BotCrew:tacticValue(name, text)
	local def = self.tactics[name]
	local clean = self:tacticClean(name, text)

	if clean == nil then
		return nil
	end

	if def.kind == "number" then
		return tonumber(clean)
	end

	if def.kind == "focus" then
		local coid = clean:match("^creature:(%d+)$")

		if coid ~= nil then
			local pCreature = getSceneObject(tonumber(coid))

			if pCreature == nil or not SceneObject(pCreature):isCreatureObject() or CreatureObject(pCreature):isDead() then
				return nil
			end
		end
	end

	return clean
end

-- The default of an entry: today's number
function BotCrew:tacticDefault(name)
	local def = self.tactics[name]
	local d = def.default

	if type(d) == "function" then
		d = d(self)
	end

	return d
end

-- A bot's value for an entry and the layer it came from (nil layer: the default). Order first, then this fight's plan, then
-- the base table.
function BotCrew:tactic(oid, name)
	local def = self.tactics[name]

	if def == nil then
		return nil
	end

	for _, layer in ipairs(self.tacticLayers) do
		local k = layer == "base" and baseKey(firstOf(oid), name) or layerKey(oid, layer, name)
		local text = readStringData(k)

		-- (a plan is for a fight: one that has outlived planKeep seconds, whatever the fight, is not read)
		if layer == "plan" and text ~= "" and os.time() - readData(ckey(oid, "planSetAt")) > self.planKeep then
			text = ""
		end

		if text ~= "" then
			local value = self:tacticValue(name, text)

			if value ~= nil then
				return value, layer
			end

			-- (a creature that died: that order is over)
			if layer ~= "base" and def.kind == "focus" then
				deleteStringData(k)
			end
		end
	end

	return self:tacticDefault(name), nil
end

-- Set an entry in the order or plan layer for a bot of a role (nil, the role has no such entry or the value isn't one)
function BotCrew:setTactic(oid, layer, name, value)
	local def = self.tactics[name]

	if def == nil or (layer ~= "order" and layer ~= "plan") or not def.roles[self:role(oid)] then
		return nil
	end

	local clean = self:tacticClean(name, value)

	if clean == nil then
		return nil
	end

	putString(layerKey(oid, layer, name), clean)

	if layer == "plan" then
		put(ckey(oid, "planSetAt"), os.time())
	end

	return clean
end

function BotCrew:clearLayer(oid, layer)
	for name in pairs(self.tactics) do
		deleteStringData(layerKey(oid, layer, name))
	end

	if layer == "plan" then
		deleteData(ckey(oid, "planSetAt"))
	end
end

-- All the entries a layer holds: "entry value" in a stable order
function BotCrew:layerEntries(oid, layer)
	local out = {}

	for name in pairs(self.tactics) do
		local text = layer == "base" and readStringData(baseKey(firstOf(oid), name)) or readStringData(layerKey(oid, layer, name))

		if text ~= "" then
			table.insert(out, name .. " " .. text)
		end
	end

	table.sort(out)

	return out
end

-- Is a call of the squad leader on? (calls: all, none, or a list)
function BotCrew:callOn(oid, which)
	local calls = self:tactic(oid, "calls")

	return calls == "all" or (calls ~= "none" and ("," .. calls .. ","):find("," .. which .. ",", 1, true) ~= nil)
end

-- The share of each pool specials need: the roster's specialsHam unless a layer sets it
function BotCrew:specialsFor(oid)
	local value, layer = self:tactic(oid, "specials")

	if layer == nil then
		return self:setting("specialsHam")
	end

	return self.specialsShare[value] or self:setting("specialsHam")
end

-- The member the tank and ranger look after first: the medic (today) or one by first name; nil when none is in the group
function BotCrew:protectedOf(oid, g)
	local who = self:tactic(oid, "protect")

	if who ~= "medic" then
		for _, m in ipairs(g.members) do
			if m.oid ~= oid and CreatureObject(m.p):getFirstName():lower() == who then
				return m.oid
			end
		end
	end

	for _, m in ipairs(g.crew) do
		if m.job == "medic" then
			return m.oid
		end
	end

	return nil
end

-- The creature a non-default focus picks, or nil (then the bot picks as it did): among the creatures attacking the group
function BotCrew:focusPick(pBot, oid, g, pLeader, focus, now)
	local coid = focus:match("^creature:(%d+)$")

	if coid ~= nil then
		return self:validTarget(pBot, getSceneObject(tonumber(coid)), g, false)
	end

	if focus == "leader" then
		if pLeader ~= nil and CreatureObject(pLeader):isInCombat() then
			return self:validTarget(pBot, getSceneObject(CreatureObject(pLeader):getTargetID()), g, false)
		end

		return nil
	end

	local list = self:groupCreatures(pBot, g, now, nil)

	if focus == "medic" then
		for _, c in ipairs(list) do
			local pOn = CreatureObject(c.p):getMainDefender()
			local onOid = pOn ~= nil and SceneObject(pOn):getObjectID() or 0
			local victim = g.byOid[onOid]

			if victim ~= nil and victim.job == "medic" then
				return c.p
			end
		end

		return nil
	end

	local best, bestHealth = nil, nil

	for _, c in ipairs(list) do
		local health = CreatureObject(c.p):getHAM(HEALTH)

		if best == nil or (focus == "weakest" and health < bestHealth) or (focus == "strongest" and health > bestHealth) then
			best, bestHealth = c.p, health
		end
	end

	return best
end

-- The base table: /run/talk/tactics/base.txt, one "first entry value" line each, for all the crew. Read at most once a minute (a
-- lesson in game makes it every few seconds for a while). A bot's base entries are replaced by what the file says; a file that
-- isn't there leaves the last table as it was.
function BotCrew:baseTick(now)
	local every = now < readData("crew:tactics:watchUntil") and self.baseWatchEvery or self.baseEvery

	if now - readData("crew:tactics:baseAt") < every then
		return
	end

	put("crew:tactics:baseAt", now)

	if LivingTalk == nil then
		return
	end

	local f = io.open(LivingTalk.dir .. "/tactics/base.txt", "r")

	if f == nil then
		return
	end

	local text = f:read("a") or ""

	f:close()

	-- Only a changed file is worth the work
	if text == readStringData("crew:tactics:baseText") and readData("crew:tactics:baseLoaded") == 1 then
		return
	end

	putString("crew:tactics:baseText", text)

	local firsts = {}

	for first in string.gmatch(readStringData("crew:tactics:baseFirsts"), "[^,]+") do
		firsts[first] = true
	end

	local seen = {}

	for first in pairs(firsts) do
		for name in pairs(self.tactics) do
			deleteStringData(baseKey(first, name))
		end
	end

	local count = 0

	for line in text:gmatch("[^\r\n]+") do
		local first, name, value = line:match("^(%a[%a']*)%s+(%a+)%s+(%S+)")

		if first ~= nil and self.tactics[name] ~= nil then
			first = first:lower()
			local clean = self:tacticClean(name, value)
			local entry = BotJobs:entry(first)

			-- (an entry the bot's role doesn't have is dropped; a bot not in the roster has no role to check)
			if clean ~= nil and (entry == nil or self.tactics[name].roles[entry.job]) then
				putString(baseKey(first, name), clean)
				seen[first] = true
				count = count + 1
			end
		end
	end

	local list = {}

	for first in pairs(seen) do
		table.insert(list, first)
	end

	table.sort(list)
	putString("crew:tactics:baseFirsts", table.concat(list, ","))
	put("crew:tactics:baseLoaded", 1)
	print("BotCrew: base tactics loaded: " .. count .. " entries for " .. #list .. " bots")
end

-- Plans (the language model sets the table for a fight)

-- The group's first crew bot that is up: it asks for plans
function BotCrew:planOwner(g)
	for _, m in ipairs(g.crew) do
		local c = CreatureObject(m.p)

		if not c:isDead() and not c:isIncapacitated() then
			return m.oid
		end
	end

	return nil
end

local function share(pCreature, pool)
	local c = CreatureObject(pCreature)
	local max = c:getMaxHAM(pool)

	if max <= 0 then
		return 1
	end

	return c:getHAM(pool) / max
end

local function pct(x)
	return math.floor(x * 100 + 0.5)
end

-- The group's state for a plan request: a line per member and per creature (named, with its oid), the standing orders, the
-- plan so far
function BotCrew:planSituation(pBot, oid, g, now)
	local lines = {}

	for _, list in ipairs({g.humans, g.crew}) do
		for _, m in ipairs(list) do
			local c = CreatureObject(m.p)
			local dist = m.oid == oid and 0 or BotJobs:distance(pBot, m.p) or 0

			table.insert(lines, string.format("%s %s hp %d action %d mind %d %s %dm", (c:getFirstName() or "?"):lower(),
				m.human and "player" or m.job, pct(math.min(self:ratio(m.p, HEALTH), 1)), pct(math.min(self:ratio(m.p, ACTION), 1)),
				pct(share(m.p, MIND)), (c:isDead() or c:isIncapacitated()) and "down" or "up", math.floor(dist + 0.5)))
		end
	end

	local standing, plan = {}, {}

	for _, m in ipairs(g.crew) do
		for _, entry in ipairs(self:layerEntries(m.oid, "order")) do
			table.insert(standing, firstOf(m.oid) .. " " .. entry)
		end

		for _, entry in ipairs(self:layerEntries(m.oid, "plan")) do
			table.insert(plan, firstOf(m.oid) .. " " .. entry)
		end
	end

	return table.concat(lines, "\n"), self:creatureLines(pBot, g, now), table.concat(standing, "\n"), table.concat(plan, "\n")
end

-- The creatures attacking the group, a line each, nearest first: "oid name level N hp N on <first or none> Nm". The oid is what
-- an order or a plan names ("creature:<oid>").
function BotCrew:creatureLines(pBot, g, now)
	local creatures = {}

	for i, c in ipairs(self:groupCreatures(pBot, g, now, nil)) do
		if i > self.planCreatures then
			break
		end

		local pOn = CreatureObject(c.p):getMainDefender()
		local victim = pOn ~= nil and g.byOid[SceneObject(pOn):getObjectID()] or nil
		local name = (SceneObject(c.p):getDisplayedName() or "creature"):gsub("^[Aa]n? ", ""):gsub("^[Tt]he ", ""):gsub("[^%w' -]", "")

		table.insert(creatures, string.format("%d %s level %d hp %d on %s %dm", c.oid, name, CreatureObject(c.p):getLevel() or 0,
			pct(math.min(share(c.p, HEALTH), 1)), victim ~= nil and CreatureObject(victim.p):getFirstName():lower() or "none",
			math.floor(c.dist + 0.5)))
	end

	return table.concat(creatures, "\n")
end

-- The group's members for a chat request: "cameren:player,kragoth:tank,..." (what an order or a lesson may name)
function BotCrew:squadText(g)
	local parts = {}

	for _, list in ipairs({g.humans, g.crew}) do
		for _, m in ipairs(list) do
			table.insert(parts, (CreatureObject(m.p):getFirstName() or "?"):lower() .. ":" .. (m.human and "player" or m.job))
		end
	end

	return table.concat(parts, ",")
end

-- The fields a crew bot's chat request adds (BotCrew:requestFields): the squad, and in a fight its creatures and the standing orders
function BotCrew:doctrineFields(pBot, oid, g)
	local fields = {}

	if g == nil then
		return fields
	end

	fields.squad = self:squadText(g)

	local now = os.time()
	local standing = {}

	for _, m in ipairs(g.crew) do
		for _, entry in ipairs(self:layerEntries(m.oid, "order")) do
			table.insert(standing, firstOf(m.oid) .. " " .. entry)
		end
	end

	if #standing > 0 then
		fields.standing = table.concat(standing, "\n")
	end

	if self:groupFighting(g) then
		local creatures = self:creatureLines(pBot, g, now)

		if creatures ~= "" then
			fields.fight = creatures
		end
	end

	return fields
end

-- Has something changed that asks for a plan? Returns the reason ("pull", "add", "wave", "down", "low", "mind") or nil; the
-- fight's memory (creatures seen, members down or low) is kept under the group's key.
function BotCrew:planChange(pBot, oid, g, pLeader, now)
	local leaderOid = SceneObject(pLeader):getObjectID()
	local reason = nil

	if readData(gkey(leaderOid, "planFight")) == 0 then
		put(gkey(leaderOid, "planFight"), 1)
		reason = "pull"
	end

	-- A creature on the group that wasn't there
	local seen = {}

	for _, coid in ipairs(oidList(readStringData(gkey(leaderOid, "planSeen")))) do
		seen[coid] = true
	end

	local fresh = false
	local list = {}

	for _, c in ipairs(self:groupCreatures(pBot, g, now, nil)) do
		if not seen[c.oid] then
			fresh = true
		end

		table.insert(list, c.oid)
	end

	-- (seen keeps everything met this fight, up to a limit)
	for coid in pairs(seen) do
		if #list < 24 and not contains(list, coid) then
			table.insert(list, coid)
		end
	end

	putString(gkey(leaderOid, "planSeen"), table.concat(list, ","))

	if fresh and reason == nil then
		reason = self:lairFight(g, now) and "wave" or "add"
	end

	-- Members down, and members under planLow of health or action
	local down, low = {}, {}
	local wasDown, wasLow = {}, {}

	for _, v in ipairs(oidList(readStringData(gkey(leaderOid, "planDown")))) do
		wasDown[v] = true
	end

	for _, v in ipairs(oidList(readStringData(gkey(leaderOid, "planLowList")))) do
		wasLow[v] = true
	end

	for _, m in ipairs(g.members) do
		if m.player then
			local c = CreatureObject(m.p)

			if c:isDead() or c:isIncapacitated() then
				table.insert(down, m.oid)

				if not wasDown[m.oid] and reason == nil then
					reason = "down"
				end
			else
				local worst = math.min(self:ratio(m.p, HEALTH), self:ratio(m.p, ACTION))

				-- (it stays low until it is back over 40%)
				if worst < self.planLow or (wasLow[m.oid] and worst < self.planLow + 0.1) then
					table.insert(low, m.oid)

					if not wasLow[m.oid] and reason == nil then
						reason = "low"
					end
				end
			end
		end
	end

	putString(gkey(leaderOid, "planDown"), table.concat(down, ","))
	putString(gkey(leaderOid, "planLowList"), table.concat(low, ","))

	-- The medic under its mind floor
	for _, m in ipairs(g.crew) do
		if m.job == "medic" and not CreatureObject(m.p):isDead() then
			local floor = self:tactic(m.oid, "mindFloor")
			local mind = share(m.p, MIND)
			local was = readData(gkey(leaderOid, "planMind")) == 1

			if mind < floor and not was then
				put(gkey(leaderOid, "planMind"), 1)

				if reason == nil then
					reason = "mind"
				end
			elseif mind >= floor + 0.1 and was then
				put(gkey(leaderOid, "planMind"), 0)
			end
		end
	end

	return reason
end

-- The end of a fight for the plan: the memory and every bot's plan layer
function BotCrew:planEnd(g, leaderOid)
	put(gkey(leaderOid, "planFight"), 0)
	deleteStringData(gkey(leaderOid, "planSeen"))
	deleteStringData(gkey(leaderOid, "planDown"))
	deleteStringData(gkey(leaderOid, "planLowList"))
	deleteData(gkey(leaderOid, "planMind"))
	deleteStringData(gkey(leaderOid, "planWantReason"))
	deleteData(gkey(leaderOid, "planQuietAt"))

	for _, m in ipairs(g.crew) do
		self:clearLayer(m.oid, "plan")
	end
end

-- Each crew step of the plan owner: a reply to collect, the changes to watch, a request to send
function BotCrew:planTick(pBot, oid, g, pLeader, now)
	if LivingTalk == nil then
		return
	end

	local leaderOid = SceneObject(pLeader):getObjectID()
	local fighting = self:groupFighting(g)

	-- The fight is over once nobody has fought for planQuiet seconds: the plan goes with it
	if not fighting then
		if readData(gkey(leaderOid, "planFight")) == 1 then
			if readData(gkey(leaderOid, "planQuietAt")) == 0 then
				put(gkey(leaderOid, "planQuietAt"), now)
			elseif now - readData(gkey(leaderOid, "planQuietAt")) >= self.planQuiet then
				self:planEnd(g, leaderOid)
			end
		end

		-- (a plan that was asked for and comes after the fight is dropped, unread)
		if readStringData(gkey(leaderOid, "planId")) ~= "" then
			LivingTalk:readLines(readStringData(gkey(leaderOid, "planId")))
			deleteStringData(gkey(leaderOid, "planId"))
		end

		return
	end

	deleteData(gkey(leaderOid, "planQuietAt"))

	-- A reply, once a second
	local id = readStringData(gkey(leaderOid, "planId"))

	if id ~= "" and now > readData(gkey(leaderOid, "planPollAt")) then
		put(gkey(leaderOid, "planPollAt"), now)

		local lines = LivingTalk:readLines(id)
		local age = now - readData(gkey(leaderOid, "planAskedAt"))

		if lines ~= nil then
			deleteStringData(gkey(leaderOid, "planId"))

			if age > self.planLate then
				print("BotJobs: a plan came " .. age .. " s late: dropped")
			else
				self:planApply(g, lines, age)
			end
		elseif age > self.planLate then
			deleteStringData(gkey(leaderOid, "planId"))
			print("BotJobs: no plan within " .. self.planLate .. " s")
		end
	end

	local reason = self:planChange(pBot, oid, g, pLeader, now)

	if reason ~= nil and readStringData(gkey(leaderOid, "planWantReason")) == "" then
		putString(gkey(leaderOid, "planWantReason"), reason)
	end

	local want = readStringData(gkey(leaderOid, "planWantReason"))

	if want == "" or readStringData(gkey(leaderOid, "planId")) ~= "" or now - readData(gkey(leaderOid, "planAt")) < self.planEvery then
		return
	end

	-- (the time is set whether or not it goes: a bridge that is down is not asked every step)
	put(gkey(leaderOid, "planAt"), now)
	deleteStringData(gkey(leaderOid, "planWantReason"))
	self:planAsk(pBot, oid, g, pLeader, want, now)
end

function BotCrew:planAsk(pBot, oid, g, pLeader, reason, now)
	-- (no bridge, no plan: nothing is built for it)
	if not LivingTalk:bridgeAlive() then
		return
	end

	local leaderOid = SceneObject(pLeader):getObjectID()
	local crew, creatures, standing, plan = self:planSituation(pBot, oid, g, now)
	local id = LivingTalk:newId(oid)
	local sent = LivingTalk:send(id, {type = "plan", id = id, at = os.time(), bot = 1, city = BotJobs:city(oid), reason = reason,
		leader = (CreatureObject(pLeader):getFirstName() or ""):lower(), crew = crew, creatures = creatures, orders = standing,
		plan = plan, lair = self:lairFight(g, now) and 1 or 0})

	if not sent then
		return
	end

	putString(gkey(leaderOid, "planId"), id)
	put(gkey(leaderOid, "planAskedAt"), now)
	print("BotJobs: a plan is asked for (" .. reason .. "), " .. #g.crew .. " crew")
end

-- The reply: "first entry value" lines and "say first text". The plan layer is replaced (the model was shown the plan so far).
function BotCrew:planApply(g, lines, age)
	local byFirst = {}

	for _, m in ipairs(g.crew) do
		byFirst[firstOf(m.oid)] = m
	end

	for _, m in ipairs(g.crew) do
		self:clearLayer(m.oid, "plan")
	end

	local count, said = 0, false

	for _, line in ipairs(lines) do
		local sayFirst, sayText = line:match("^say%s+(%a[%a']*)%s+(.+)$")

		if sayFirst ~= nil then
			local m = byFirst[sayFirst:lower()]

			if m ~= nil and not said and not CreatureObject(m.p):isDead() and not CreatureObject(m.p):isIncapacitated() then
				said = true
				putString(ckey(m.oid, "planSay"), sayText:sub(1, 200))
				createEvent(300, "BotCrew", "planSay", m.p, tostring(readData(key(m.oid, "gen"))))
			end
		else
			local first, name, value = line:match("^(%a[%a']*)%s+(%a+)%s+(%S+)")
			local m = first ~= nil and byFirst[first:lower()] or nil

			-- (an entry a standing order holds isn't changed by a plan)
			if m ~= nil and readStringData(layerKey(m.oid, "order", name)) == "" and self:setTactic(m.oid, "plan", name, value) ~= nil then
				count = count + 1
			end
		end
	end

	print("BotJobs: a plan applied after " .. age .. " s: " .. count .. " changes" .. (said and ", one line to say" or ""))
end

-- An event on the crew bot: the plan's line, in group chat
function BotCrew:planSay(pBot, gen)
	if not BotJobs:current(pBot, gen) or not CreatureObject(pBot):isGrouped() then
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local text = readStringData(ckey(oid, "planSay"))

	deleteStringData(ckey(oid, "planSay"))

	if text ~= "" then
		BotJobs:reply(pBot, 0, "group", text)
	end
end

-- Orders and lessons, from a chat reply (BotJobs:poll)

-- "first entry value;first entry value;* clear": one order each. The speaker must be in the bot's group (a human of it). A "*"
-- is every crew bot of the group that has the entry. "clear" ends every order of the bot (or the crew): "as you were".
function BotCrew:tacticOrders(pBot, oid, playerOid, channel, text)
	local g = self:group(pBot)
	local member = g ~= nil and g.byOid[playerOid] or nil

	if member == nil or not member.human then
		print("BotJobs: " .. self:name(oid) .. " ignores an order from someone outside its group")
		return 0
	end

	local count = 0

	for item in text:gmatch("[^;]+") do
		local target, name, value = item:match("^%s*(%S+)%s+(%S+)%s*(%S*)")

		if target ~= nil then
			target = target:lower()

			local who = {}

			for _, m in ipairs(g.crew) do
				if target == "*" or target == firstOf(m.oid) then
					table.insert(who, m)
				end
			end

			for _, m in ipairs(who) do
				if name == "clear" then
					self:clearLayer(m.oid, "order")
					count = count + 1
				elseif self:setTactic(m.oid, "order", name, value) ~= nil then
					count = count + 1
					print("BotJobs: " .. self:name(m.oid) .. " is ordered: " .. name .. " " .. value)
				end
			end
		end
	end

	return count
end

-- The lesson's result, reply line 7 ("added quillan", "forgot crew", "none"): the base table will change in a moment
function BotCrew:teachResult(pBot, oid, text)
	if text == nil or text == "" or text == "none" then
		return
	end

	put("crew:tactics:watchUntil", os.time() + self.baseWatch)
	put("crew:tactics:baseAt", 0)
	print("BotJobs: " .. self:name(oid) .. " was taught: " .. text)
end

-- The tables, for the console (BotCrew:devTactics:<first>)
function BotCrew:tacticsText(oid)
	local out = {}

	for _, layer in ipairs({"order", "plan", "base"}) do
		local entries = self:layerEntries(oid, layer)

		table.insert(out, layer .. ": " .. (#entries == 0 and "-" or table.concat(entries, ", ")))
	end

	return table.concat(out, "; ")
end
