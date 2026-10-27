-- Own crews, Part 2 (spec ~/github/swgemu/specs/2026-10-26-crew-grows/, "They level with you"): a bot trains.
-- Included from crew.lua (after BotCrew exists).
--
-- Experience. Core3 gives an own-crew bot experience as it gives a player: by its damage share of a fight (patch 0011), medical
-- experience for heals, dance and music experience for flourishes. The squad leader bot gets the squad leader experience a leader
-- would (patch 0011). What a bot's play never earns (crafting, trapping, the weapon lines it never fires; crews.lua, `cross`) is "fed":
-- when the next box asks for one of those types, the bot pays for it out of its pay pools (the experience its play does earn), fedRatio
-- points of the pool for each point of the box's type, as much as the pools hold at the time and the rest at a later pass. Core3 caps
-- each pool (the highest cap of the boxes owned, else xp_limits.iff), so a pool that is full stops growing: nothing here depends on
-- one growing past its cap.
--
-- Training. After each fight and every trainEvery seconds an own-crew bot trains the next box of its role's training order
-- (crews.lua, `order`) when Core3 says it can (LuaSkillManager: prerequisites, the experience, the skill points; no credits), up to
-- trainMax boxes in a pass. A new box brings the abilities (learn), the packs (restock) and, from the kit, the gear of its new level
-- (botSetGear puts it on and saves it with the crew's entry). It says so in group chat now and then, one line a crew a minute at most.
-- Nothing else is stored: the skills and the experience live on the character. The Mos Eisley crew is master and never trains.
--
-- "how far to your next box?", "what are you working on?": the bot names the box and the experience it is waiting on (keywords, no model).
--
-- Console (output in the pod log):
--   runLuaFunction BotCrew:devXp:<first>:<type>:<amount>     give a bot experience of a type (e.g. combat_rangedspecialize_rifle; negative takes)
--   runLuaFunction BotCrew:devTrain:<first>                  a training pass now
--   runLuaFunction BotCrew:devNext:<first>                   the next box and what it needs; devXpList:<first> every type it has

BotCrew.trainEvery = 300        -- seconds between a bot's training passes
BotCrew.trainAfterFight = 20    -- a fight's end starts a pass if the last was this long ago
BotCrew.trainMax = 4            -- boxes in one pass
BotCrew.trainSayGap = 240       -- seconds between a bot's lines about it (a tier's fourth box and the masters are said whatever it said last)
BotCrew.trainCrewGap = 60       -- seconds between two such lines of one crew; a master line waits for the next free slot, the others are dropped
BotCrew.fedRatio = 1            -- points of a pay pool for each point of a fed type

local function ckey(oid, field)
	return "bot:" .. oid .. ":crew:" .. field
end

local function put(k, v)
	writeData(k, math.floor(tonumber(v) or 0))
end

local function putString(k, v)
	writeStringData(k, v)
end

local ROMAN = {["01"] = "I", ["02"] = "II", ["03"] = "III", ["04"] = "IV"}

-- "combat_marksman_rifle_03" is "Marksman Rifle III"; "social_dancer_master" is "Master Dancer"
function BotCrew:boxTitle(name)
	local words = {}

	for w in tostring(name):gmatch("[^_]+") do
		table.insert(words, w)
	end

	if #words > 1 then
		table.remove(words, 1)	-- (combat, science, outdoors, social, crafting)
	end

	local last = words[#words]
	local prefix = ""

	if last == "master" or last == "novice" then
		prefix = last == "master" and "Master " or "Novice "
		table.remove(words)
	end

	local out = {}

	for _, w in ipairs(words) do
		local word = ROMAN[w] or (BotCrewData.boxWords or {})[w] or (w:sub(1, 1):upper() .. w:sub(2))

		table.insert(out, word)
	end

	return prefix .. table.concat(out, " ")
end

-- The first box of the role's training order the bot does not have, or nil when it has them all
function BotCrew:nextBox(pBot, order)
	local creature = CreatureObject(pBot)

	for _, box in ipairs(order or {}) do
		if not creature:hasSkill(box) then
			return box
		end
	end

	return nil
end

local function experience(pBot, kind)
	local pGhost = CreatureObject(pBot):getPlayerObject()

	if pGhost == nil then
		return 0
	end

	return PlayerObject(pGhost):getExperience(kind)
end

-- Called at login (BotCrew:start): the first pass is a minute or so away, spread over the crew
function BotCrew:trainStart(pBot, oid, now)
	if self:ownerOf(oid) == 0 then
		return
	end

	put(ckey(oid, "trainAt"), now + 60 + oid % 30 - self.trainEvery)
	putString(ckey(oid, "trainPend"), "")
end

-- From the 5 s tick: a master line that waited for a free slot, and a pass when trainEvery has gone by
function BotCrew:trainTick(pBot, oid, now)
	local owner = self:ownerOf(oid)

	if owner == 0 then
		return
	end

	local pending = readStringData(ckey(oid, "trainPend"))

	if pending ~= "" and CreatureObject(pBot):isGrouped() and now - readData("crew:trainSayAt:" .. owner) >= self.trainCrewGap then
		putString(ckey(oid, "trainPend"), "")
		put("crew:trainSayAt:" .. owner, now)
		self:groupSay(pBot, oid, "trainedMaster", nil, {box = pending})
	end

	if now - readData(ckey(oid, "trainAt")) >= self.trainEvery and not CreatureObject(pBot):isInCombat() then
		self:trainPass(pBot, oid, now)
	end
end

-- At the end of a fight
function BotCrew:trainAfterFightPass(pBot, oid, now)
	if self:ownerOf(oid) ~= 0 and now - readData(ckey(oid, "trainAt")) >= self.trainAfterFight then
		self:trainPass(pBot, oid, now)
	end
end

-- Pay for the next box out of the pay pools when it asks for a fed type: what the pools hold now, up to what it costs. True when
-- some experience moved (the box may still need more at a later pass)
function BotCrew:payFor(pBot, role, box)
	local info = BotCrewData.boxes[box]
	local cfg = BotCrewData.cross ~= nil and BotCrewData.cross[role] or nil

	if info == nil or cfg == nil or cfg.fed[info.t] ~= true or info.c <= 0 then
		return false
	end

	-- (the prerequisites and the points first: experience is not spent on a box the bot can't have)
	if not LuaSkillManager():canLearnSkill(pBot, box, true) then
		return false
	end

	local creature = CreatureObject(pBot)
	local missing = info.c - experience(pBot, info.t)
	local moved = false

	for _, pool in ipairs(cfg.pay) do
		if pool ~= info.t and missing > 0 then
			local have = experience(pBot, pool)
			local gain = math.min(math.floor(have / self.fedRatio), missing)

			if gain > 0 then
				local before = experience(pBot, info.t)

				creature:awardExperience(info.t, gain, false)

				-- (the type's cap may hold some back: pay for what went in)
				local added = experience(pBot, info.t) - before

				if added > 0 then
					creature:awardExperience(pool, -math.min(have, math.ceil(added * self.fedRatio)), false)
					print("BotJobs: " .. self:name(SceneObject(pBot):getObjectID()) .. " pays " .. added .. " " .. info.t .. " out of its " .. pool .. " experience for " .. box)
					missing = missing - added
					moved = true
				end
			end
		end
	end

	return moved
end

-- The pools' experience a fed box still waits on: its cost less what the bot holds of the type and the pools can pay now
function BotCrew:payLeft(pBot, role, info)
	local cfg = BotCrewData.cross[role]
	local left = info.c - experience(pBot, info.t)
	local best, bestPool = 0, cfg.pay[1]

	for _, pool in ipairs(cfg.pay) do
		if pool ~= info.t then
			local have = experience(pBot, pool)

			left = left - math.floor(have / self.fedRatio)

			if have > best then
				best, bestPool = have, pool
			end
		end
	end

	return math.max(0, math.ceil(left * self.fedRatio)), bestPool
end

function BotCrew:trainPass(pBot, oid, now)
	local creature = CreatureObject(pBot)

	if self:ownerOf(oid) == 0 or botSetGear == nil or creature:isDead() or creature:isIncapacitated() then
		return {}
	end

	put(ckey(oid, "trainAt"), now)

	local role = self:role(oid)
	local order = BotCrewData.order[role]

	if order == nil then
		return {}
	end

	local skillManager = LuaSkillManager()
	local got = {}

	for _ = 1, self.trainMax do
		local box = self:nextBox(pBot, order)

		if box == nil then
			break
		end

		-- (Core3 checks the prerequisites, the experience and the points, and takes the experience)
		if not skillManager:canLearnSkill(pBot, box, false) then
			if not self:payFor(pBot, role, box) or not skillManager:canLearnSkill(pBot, box, false) then
				break
			end
		end

		if not skillManager:awardSkill(pBot, box) then
			break
		end

		table.insert(got, box)
	end

	if #got > 0 then
		self:trained(pBot, oid, role, got, now)
	end

	return got
end

local function same(a, b)
	if #a ~= #b then
		return false
	end

	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end

	return true
end

-- A box or more learned: abilities, packs, gear for the new level, a line
function BotCrew:trained(pBot, oid, role, got, now)
	local creature = CreatureObject(pBot)
	local first = readStringData("bot:" .. oid .. ":first")
	local entry = BotJobs:entry(first)

	-- What it owns of its order, with the novice boxes they needed, is its entry's skills
	local owned = {}

	for _, box in ipairs(BotCrewData.order[role]) do
		if creature:hasSkill(box) then
			table.insert(owned, box)
		end
	end

	local boxes = BotCrewKit:boxesIn(owned)

	print("BotJobs: " .. self:name(oid) .. " trained " .. table.concat(got, ", ") .. " (" .. boxes .. " boxes)")

	if entry ~= nil then
		local gear = BotCrewKit:gear(role, entry.species, entry.sex, boxes, entry.name)
		local changed = not (same(gear.outfit, entry.outfit or {}) and same(gear.carry, entry.carry or {}) and gear.weapon == (entry.weapon or ""))

		botSetGear(oid, {skills = owned, outfit = gear.outfit, carry = gear.carry, weapon = gear.weapon, campKit = gear.campKit})

		if changed then
			print("BotJobs: " .. self:name(oid) .. " has new gear for " .. boxes .. " boxes")
		end
	end

	self:learn(pBot, oid, role)
	self:restock(pBot, oid)

	-- (the new weapon is in its hand when the gear task has run)
	createEvent(4000, "BotCrew", "trainedEquip", pBot, tostring(readData("bot:" .. oid .. ":gen")))

	-- A squad leader box changes the aura the group gets (Core3 only rebuilds it for the leader)
	for _, box in ipairs(got) do
		if box:find("squadleader", 1, true) ~= nil and botSquadAura ~= nil then
			botSquadAura(oid)
			break
		end
	end

	self:trainedSay(pBot, oid, got, now)
end

-- The line about it: at most one a crew each trainCrewGap; the master's waits for the next free slot, a tier's fourth box is
-- said whatever the bot said last, the rest only when it has been quiet for trainSayGap
function BotCrew:trainedSay(pBot, oid, got, now)
	if not CreatureObject(pBot):isGrouped() then
		return
	end

	local owner = self:ownerOf(oid)
	local crewKey = "crew:trainSayAt:" .. owner
	local last, master, always = got[#got], nil, false

	for _, box in ipairs(got) do
		if box:find("_master$") ~= nil then
			master, last = box, box
		end

		always = always or box:find("_04$") ~= nil or box:find("_master$") ~= nil
	end

	if now - readData(crewKey) < self.trainCrewGap then
		if master ~= nil then
			putString(ckey(oid, "trainPend"), self:boxTitle(master))
		end

		return
	end

	if always or now - readData(ckey(oid, "trainSayAt")) >= self.trainSayGap then
		put(ckey(oid, "trainSayAt"), now)
		put(crewKey, now)
		self:groupSay(pBot, oid, master ~= nil and "trainedMaster" or "trained", nil, {box = self:boxTitle(last)})
	end
end

function BotCrew:trainedEquip(pBot, gen)
	if not BotJobs:current(pBot, gen) then
		return
	end

	self:equip(pBot, SceneObject(pBot):getObjectID())
end

-- What an own-crew entertainer can perform: the pick if it has the ability (startDance+<name>, startMusic+<name>), else the first it has of the
-- plainer ones. A bot that starts what it cannot never earns dance or music experience, so the box that gives it more comes slowly
BotCrew.performFallback = {
	Dance = {"basic", "rhythmic", "footloose", "formal", "popular", "poplock", "lyrical", "exotic"},
	Music = {"ballad", "folk", "ceremonial", "jazz", "waltz", "rock", "virtuoso", "starwars1"},
}

function BotCrew:performChoice(pBot, oid, kind, pick)
	if self:ownerOf(oid) == 0 then
		return pick
	end

	local pGhost = CreatureObject(pBot):getPlayerObject()

	if pGhost == nil or PlayerObject(pGhost):hasAbility("start" .. kind .. "+" .. pick) then
		return pick
	end

	local usable = {}

	for _, name in ipairs(self.performFallback[kind]) do
		if PlayerObject(pGhost):hasAbility("start" .. kind .. "+" .. name) then
			table.insert(usable, name)
		end
	end

	if #usable == 0 then
		return pick
	end

	return usable[getRandomNumber(1, #usable)]
end

-- "how far to your next box?" -----------------------------------------------------------------------------------------------

local function wordsOf(text)
	return " " .. (tostring(text or ""):lower():gsub("[^%w']", " "):gsub("%s+", " ")) .. " "
end

-- (a noun for the thing, so ordinary talk is left alone: "how far are you?" or "remember your training" is not a question about boxes)
BotCrew.progressWords = {" next box ", " next skill ", " how far to your next ", " what are you training ", " what are you working on "}

function BotCrew:progressWanted(text)
	local t = wordsOf(text)

	for _, phrase in ipairs(self.progressWords) do
		if t:find(phrase, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- What it would say: the next box and what it lacks
function BotCrew:progressLine(pBot, oid)
	local role = self:role(oid)
	local order = BotCrewData.order[role]
	local box = order ~= nil and self:nextBox(pBot, order) or nil

	if box == nil then
		return "I've learned everything my training offers."
	end

	local info = BotCrewData.boxes[box] or {t = "", c = 0, p = 0}
	local title = self:boxTitle(box)
	local points = botSkillPoints ~= nil and botSkillPoints(pBot) or 0
	local names = BotCrewData.xpNames or {}
	local cfg = BotCrewData.cross ~= nil and BotCrewData.cross[role] or nil

	if info.c > 0 then
		local left = info.c - experience(pBot, info.t)

		if left > 0 and cfg ~= nil and cfg.fed[info.t] == true then
			-- Its own play doesn't earn this type: it pays for it out of the experience it does earn
			local waiting, pool = self:payLeft(pBot, role, info)

			if waiting > 0 then
				return string.format("I'm working on %s: it takes %d %s experience, which I train out of my %s experience. %d more %s experience to go.", title,
					left, names[info.t] or info.t, names[pool] or pool, waiting, names[pool] or pool)
			end
		elseif left > 0 then
			return string.format("I'm working on %s: %d more %s experience to go.", title, left, names[info.t] or info.t)
		end
	end

	if points < info.p then
		return string.format("I have what %s takes, but only %d skill points left and it needs %d.", title, points, info.p)
	end

	return string.format("I have what %s takes. I'll train it next chance I get.", title)
end

function BotCrew:progressAnswer(pBot, oid, pSpeaker, channel)
	BotJobs:reply(pBot, SceneObject(pSpeaker):getObjectID(), channel or "spatial", self:progressLine(pBot, oid))
end

-- Development ---------------------------------------------------------------------------------------------------------------

function BotCrew:devXp(first, kind, amount)
	local pBot = botGetCreature ~= nil and botGetCreature(first) or nil

	if pBot == nil or kind == nil or tonumber(amount or "") == nil then
		print("BotCrew: usage devXp:<online bot>:<experience type>:<amount>")
		return
	end

	CreatureObject(pBot):awardExperience(kind, tonumber(amount), false)
	print("BotCrew: " .. first .. " has " .. experience(pBot, kind) .. " " .. kind .. " experience")
end

function BotCrew:devTrain(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first) or nil

	if pBot == nil then
		print("BotCrew: usage devTrain:<online own-crew bot>")
		return
	end

	createEvent(10, "BotCrew", "devTrainNow", pBot, "")
end

function BotCrew:devTrainNow(pBot)
	local oid = SceneObject(pBot):getObjectID()
	local got = self:trainPass(pBot, oid, os.time())

	print("BotCrew: " .. self:name(oid) .. " trained " .. #got .. " box(es): " .. table.concat(got, ", "))
end

function BotCrew:devNext(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first) or nil

	if pBot == nil then
		print("BotCrew: usage devNext:<online bot>")
		return
	end

	local oid = SceneObject(pBot):getObjectID()
	local box = self:nextBox(pBot, BotCrewData.order[self:role(oid)])
	local info = box ~= nil and BotCrewData.boxes[box] or nil

	print("BotCrew: " .. first .. " next: " .. tostring(box) .. (info ~= nil and (" (" .. info.t .. " " .. experience(pBot, info.t) .. "/" .. info.c ..
		", " .. info.p .. " points, has " .. tostring(botSkillPoints(pBot)) .. ")") or "") .. " | " .. self:progressLine(pBot, oid))
end

function BotCrew:devXpList(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first) or nil

	if pBot == nil then
		print("BotCrew: usage devXpList:<online bot>")
		return
	end

	local pGhost = CreatureObject(pBot):getPlayerObject()
	local parts = {}

	for _, kind in ipairs(PlayerObject(pGhost):getExperienceList() or {}) do
		table.insert(parts, kind .. "=" .. PlayerObject(pGhost):getExperience(kind))
	end

	table.sort(parts)
	print("BotCrew: " .. first .. " experience: " .. table.concat(parts, " "))
end
