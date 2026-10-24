-- Bot players (Phase 7): the crew's swoops, included from crew.lua. Each crew bot owns a swoop (BotVehicle: a control
-- device in its datapad, made on first use). The crew mirrors its leader: when the leader rides (a swoop, a speeder
-- or a creature mount) every grouped crew bot within 64 m calls its swoop and mounts; when the leader gets off, they
-- get off and store theirs. A bot that is attacked while riding, or whose leader fights, gets off to fight. BotMover
-- carries a mounted bot and its swoop along the leader's trail. Spec:
-- ~/github/swgemu/specs/2026-10-24-crew-swoops-missions/
--
-- BotCrew:step calls BotCrewSwoop:tick for a grouped bot with its leader; BotCrew:leftGroup calls :release. State lives
-- in shared memory under bot:<oid>:crew:swoop*. Mounting is Core3's own check (outdoors, upright, not in combat), so a
-- bot that can't mount runs and catches up as it does on foot.
--
-- Console (bot-on-bot tests on the local server, a bot plays the leader):
--   runLuaFunction BotCrewSwoop:devMount:<first>      a bot gets a swoop if it has none, calls it and mounts
--   runLuaFunction BotCrewSwoop:devDismount:<first>   a bot gets off and stores its swoop
--   runLuaFunction BotCrewSwoop:devState:<first>      riding, swoop out, swoop in the datapad
--   runLuaFunction BotCrewSwoop:devAggro:<oid>:<first> a creature attacks a bot (attacked while riding)

BotCrewSwoop = {
	range = 64,         -- the leader this near (m): the bot calls its swoop
	reactMin = 0,       -- seconds before it follows the leader onto or off a swoop
	reactMax = 2,
	retryEvery = 8,     -- seconds between tries to mount (or to store a swoop left standing)
	sayChance = 60,
}

local function ckey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

local function put(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
end

-- Called through here so a build without the bindings still runs the rest of the crew
local function call(name, ...)
	local fn = _G[name]

	if fn == nil then
		return nil
	end

	return fn(...)
end

function BotCrewSwoop:say(pBot, oid, kind)
	if getRandomNumber(1, 100) <= self.sayChance then
		BotCrew:groupSay(pBot, oid, kind)
	end
end

-- A reaction delay: the first look sets when it acts, a later one says whether it is time
function BotCrewSwoop:due(oid, now)
	local at = readData(ckey(oid, "swoopAt"))

	if at == 0 then
		put(ckey(oid, "swoopAt"), now + getRandomNumber(self.reactMin, self.reactMax))
		return false
	end

	return now >= at
end

function BotCrewSwoop:retried(oid, now)
	if now - readData(ckey(oid, "swoopTry")) < self.retryEvery then
		return false
	end

	put(ckey(oid, "swoopTry"), now)

	return true
end

-- A grouped crew bot with its leader (a player), once a step. Cheap when nothing changes: it reads a few flags
function BotCrewSwoop:tick(pBot, oid, pLeader, now, g)
	if call("botMounted", pBot) == nil then
		return
	end

	-- (CreatureObject(p) hands back one shared wrapper: a second call rebinds the first, so no variables for them)
	if CreatureObject(pBot):isDead() or CreatureObject(pBot):isIncapacitated() then
		return
	end

	local riding = call("botMounted", pBot)
	local leaderRiding = call("botMounted", pLeader)

	if riding then
		-- Creatures attack a rider's swoop, not the rider: the attacker is the one to fight once it is off
		local attacker = call("botMountAttacker", pBot) or 0

		if CreatureObject(pBot):isInCombat() or attacker ~= 0 then
			-- Attacked while riding: off at once, then fight
			if attacker ~= 0 then
				put(ckey(oid, "defender"), attacker)
				put(ckey(oid, "defenderAt"), now)
			end

			self:getOff(pBot, oid, now, "swoopFight")
		elseif BotCrew:helpWanted(pBot, oid, g, now) then
			-- A crew mate or a human of the group is attacked or fighting: off at once to help
			self:getOff(pBot, oid, now, "swoopFight")
		elseif not leaderRiding or CreatureObject(pLeader):isInCombat() or (call("botMountAttacker", pLeader) or 0) ~= 0 then
			if self:due(oid, now) then
				self:getOff(pBot, oid, now, leaderRiding and "swoopFight" or "swoopOff")
			end
		else
			deleteData(ckey(oid, "swoopAt"))
			deleteData(ckey(oid, "swoopTried"))
		end

		return
	end

	if not leaderRiding then
		-- On foot with the leader: a swoop left standing (after a fight) is stored once it is quiet
		deleteData(ckey(oid, "swoopAt"))
		deleteData(ckey(oid, "swoopTried"))

		if call("botVehicleOut", pBot) and not CreatureObject(pBot):isInCombat() and self:retried(oid, now) then
			call("botDismount", pBot)
		end

		return
	end

	-- The leader rides and the bot doesn't: mount, if it can
	if CreatureObject(pBot):isInCombat() or CreatureObject(pLeader):isInCombat() or (call("botMountAttacker", pLeader) or 0) ~= 0 or
		SceneObject(pBot):getParentID() ~= 0 or BotCrew:helpWanted(pBot, oid, g, now) then
		deleteData(ckey(oid, "swoopAt"))
		return
	end

	if readStringData(ckey(oid, "order")) == "stay" or readData(ckey(oid, "inCamp")) == 1 then
		return
	end

	local dist = BotJobs:distance(pBot, pLeader)

	if dist == nil or dist > self.range then
		deleteData(ckey(oid, "swoopAt"))
		return
	end

	if not self:due(oid, now) or not self:retried(oid, now) then
		return
	end

	if CreatureObject(pBot):getPosture() ~= 0 then
		BotCrew:standUp(pBot, oid)
		return
	end

	-- A swoop that didn't take twice: it runs and catches up (and tries again), saying so once
	local tried = readData(ckey(oid, "swoopTried")) + 1

	put(ckey(oid, "swoopTried"), tried)

	if tried == 3 then
		self:say(pBot, oid, "swoopFail")
	end

	print("BotJobs: " .. BotCrew:name(oid) .. " mounts its swoop (" .. BotCrew:firstName(pLeader) .. " rides, " ..
		math.floor(dist) .. " m)")

	if call("botMount", pBot) then
		self:say(pBot, oid, "swoopMount")
	end
end

function BotCrewSwoop:getOff(pBot, oid, now, kind)
	-- (not again for 3 s: the dismount runs on the bot's own task)
	if now - readData(ckey(oid, "swoopOffAt")) < 3 then
		return
	end

	put(ckey(oid, "swoopOffAt"), now)
	print("BotJobs: " .. BotCrew:name(oid) .. " gets off its swoop (" .. kind .. ")")
	call("botDismount", pBot)
	self:say(pBot, oid, kind)
	deleteData(ckey(oid, "swoopAt"))
end

-- Out of the group, or sent home: off the swoop and stored
function BotCrewSwoop:release(pBot, oid)
	deleteData(ckey(oid, "swoopAt"))
	deleteData(ckey(oid, "swoopTried"))

	-- (forced: leaving after a fight, nobody would store a swoop left standing)
	if call("botMounted", pBot) or call("botVehicleOut", pBot) then
		call("botDismount", pBot, true)
	end
end

-- Console

local function devBot(first)
	return botGetCreature ~= nil and botGetCreature(first or "") or nil
end

function BotCrewSwoop:devMount(first)
	local pBot = devBot(first)

	print("BotCrewSwoop: " .. tostring(first) .. " mounts: " .. tostring(pBot ~= nil and call("botMount", pBot)))
end

function BotCrewSwoop:devDismount(first)
	local pBot = devBot(first)

	print("BotCrewSwoop: " .. tostring(first) .. " dismounts: " .. tostring(pBot ~= nil and call("botDismount", pBot)))
end

function BotCrewSwoop:devState(first)
	local pBot = devBot(first)

	if pBot == nil then
		print("BotCrewSwoop: no online bot called " .. tostring(first))
		return
	end

	local pVehicle = call("botMounted", pBot) and SceneObject(pBot):getParent() or nil
	local where = pVehicle ~= nil and (", vehicle at " .. math.floor(SceneObject(pVehicle):getWorldPositionX()) .. " " ..
		math.floor(SceneObject(pVehicle):getWorldPositionY())) or ""

	print("BotCrewSwoop: " .. first .. " riding " .. tostring(call("botMounted", pBot)) .. ", swoop out " ..
		tostring(call("botVehicleOut", pBot)) .. ", has swoop " .. tostring(call("botHasSwoop", pBot)) .. ", combat " .. tostring(CreatureObject(pBot):isInCombat()) ..
		", pos " .. math.floor(SceneObject(pBot):getWorldPositionX()) .. " " .. math.floor(SceneObject(pBot):getWorldPositionY()) .. where)
end

-- A creature (by oid) goes for a bot: attacked while riding
function BotCrewSwoop:devAggro(mobOid, first)
	local pMob = getSceneObject(tonumber(mobOid) or 0)
	local pBot = devBot(first)

	if pMob == nil or pBot == nil then
		print("BotCrewSwoop: usage devAggro:<creature oid>:<bot>")
		return
	end

	createEvent(10, "BotCrewSwoop", "devAggroNow", pMob, tostring(SceneObject(pBot):getObjectID()))
end

function BotCrewSwoop:devAggroNow(pMob, botOid)
	AiAgent(pMob):setDefender(getSceneObject(tonumber(botOid)))
	print("BotCrewSwoop: " .. SceneObject(pMob):getDisplayedName() .. " attacks " .. botOid)
end
