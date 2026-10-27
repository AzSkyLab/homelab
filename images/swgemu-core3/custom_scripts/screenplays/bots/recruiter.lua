-- Own crews (Phase 9, Part 1): the recruiter. A veteran who "knows people looking for work" stands at a table in the Mos Eisley, Coronet
-- and Theed cantinas. He is a Living Cities style NPC, not a bot: a mobile that looks like a player, stands still and listens. Talk
-- to him (target him, or say his name, and say "crew", "recruit" or "hire") and windows open:
--   1. your crew, if you have one: let one go, or hire for a role you left out;
--   2. the roles: a checklist of the seven (a pick toggles it; "Continue" goes on);
--   3. for each role in turn: species and sex, a name (a suggestion from the species' own naming, typed over if you like, checked
--      by Core3's name rules and unique among bots, characters and the crowd), and a look (a hairstyle with a hair colour, or a
--      skin tone);
--   4. a summary: "Hire them" makes the crew (botHire, the C++ makes the account and character in a task).
-- It works with no language model. A bot starts with as many boxes of its role's training order as the player's character has
-- (crew_kit.lua, BotCrewKit), the role's free gear for that level, and waits in the cantina where it was hired. Spec:
-- ~/github/swgemu/specs/2026-10-26-crew-grows/. Data: custom_scripts/bots/crews.lua.
--
-- Lua state is per thread: a player's progress through the windows lives in shared memory under recruit:<player oid>:*, and the
-- recruiter's greeting chain carries a generation.
--
-- Console (output in the pod log), for the local server where a bot stands in for a human (BotCrew:devLead):
--   runLuaFunction BotRecruiter:devHire:<owner first name or oid>:<roles, comma separated>:<cantina>[:<boxes>[:<species>]]
--                                                  hire a crew for an owner as the windows would (no windows)
--   runLuaFunction BotRecruiter:devCrew:<owner first name or oid>        the owner's crew
--   runLuaFunction BotRecruiter:devLetGo:<bot first name>                let a crew bot go
--   runLuaFunction BotRecruiter:devSuggest:<species>                     a name suggestion
--   runLuaFunction BotRecruiter:devWindows:<player first name or oid>:<cantina>[:name|look|confirm|species|roles]
--                                                  open the first window (or a later one, with a made-up design) for a player

includeFile("../custom_scripts/screenplays/bots/crew_kit.lua")

BotRecruiter = ScreenPlay:new {
	screenplayName = "BotRecruiter",

	cities = {"mos_eisley", "coronet", "theed"},

	-- How near (m) a player must be to start the windows, and to be greeted
	talkRange = 14,
	greetRange = 7,
	-- A player is greeted again after this many seconds, and the greeting chain looks every this many ms
	greetCooldown = 900,
	greetEveryMs = 15000,
	-- The same for the nudge when someone talks to him without a keyword
	nudgeCooldown = 60,
	-- A name picked in the windows stays the crowd's off limits this long (s) while the rest of the crew is designed
	reserveSeconds = 1800,
	-- The value of a name kept for a bot (crew:name:<first>); a name being picked holds an expiry time
	keptForever = 4294967295,
	-- Name suggestions tried before giving up
	suggestTries = 80,

	words = {"crew", "crews", "recruit", "recruits", "recruiter", "recruiting", "hire", "hiring", "mercs", "mercenaries"},

	greetings = {
		"Looking for a crew? I know people. Say \"crew\" to me.",
		"Need hands for a hunt? Say \"crew\" and I'll see what I can do.",
		"Hunting alone? I can find you company. Just say \"crew\".",
	},
	nudges = {
		"If it's a crew you want, say \"crew\" to me.",
		"I only deal in crews, friend. Say \"crew\" if you want one.",
	},
	tooFar = "Step closer and say it again.",
	done = "Good. They'll be waiting in the cantina. Mind you treat them right.",
}

registerScreenPlay("BotRecruiter", true)

-- Helpers

local function key(playerOid, field)
	return "recruit:" .. playerOid .. ":" .. field
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

local function split(text)
	local out = {}

	for part in string.gmatch(text or "", "[^,]+") do
		table.insert(out, part)
	end

	return out
end

local function pickOne(list)
	return list[getRandomNumber(1, #list)]
end

local function capitalize(word)
	return word:sub(1, 1):upper() .. word:sub(2)
end

-- The first words of the recruiter: his first name, for "Torrin, I want a crew"
local function firstOf(name)
	return tostring(name or ""):match("^(%S+)") or ""
end

-- Start: a recruiter in each cantina

function BotRecruiter:start()
	if botHire == nil or botCrewOf == nil then
		print("BotRecruiter: this build has no own crews")
		return
	end

	writeData("recruit:gen", readData("recruit:gen") + 1)
	self:seedNames()

	for _, cantina in ipairs(self.cities) do
		self:spawn(cantina)
	end

	print("BotRecruiter: started, generation " .. readData("recruit:gen"))
end

-- The crowd fills the cities as the screenplays start, before the C++ has read the crews file (botNameFree knows the bots only once
-- it has): this one small read keeps the crowd off their first names from the start. (The screenplays start in the order of their
-- names, and BotRecruiter comes before LivingCities.) A name stays kept until its bot is let go.
function BotRecruiter:seedNames()
	local path = os.getenv("BOT_CREWS_FILE") or ((os.getenv("BOT_DATA_DIR") or "/data/bots") .. "/crews.lua")
	local f = io.open(path, "r")

	if f == nil then
		return
	end

	local text = f:read("a") or ""

	f:close()

	local count = 0

	for name in text:gmatch('%f[%w]name = "([^"]+)"') do
		writeData("crew:name:" .. firstOf(name):lower(), self.keptForever)
		count = count + 1
	end

	print("BotRecruiter: " .. count .. " crew names kept from the crowd")
end

function BotRecruiter:generation()
	return readData("recruit:gen")
end

function BotRecruiter:spawn(cantina)
	local data = BotCrewData.cantinas[cantina]
	local r = data.recruiter

	-- (after reloadscreenplays the last one is still standing)
	local pOld = getSceneObject(readData("recruit:npc:" .. cantina))

	if pOld ~= nil then
		SceneObject(pOld):destroyObjectFromWorld()
	end

	local pNpc = spawnMobile(data.planet, r.template, 0, r.x, r.z, r.y, r.heading, data.cell)

	if pNpc == nil then
		print("BotRecruiter: could not spawn " .. r.template .. " in " .. data.title)
		return
	end

	local oid = SceneObject(pNpc):getObjectID()

	writeData("recruit:npc:" .. cantina, oid)
	writeStringData("recruit:city:" .. oid, cantina)
	SceneObject(pNpc):setCustomObjectName(r.name)
	CreatureObject(pNpc):setPvpStatusBitmask(0)
	AiAgent(pNpc):addObjectFlag(AI_STATIONARY)
	createObserver(SPATIALCHAT, "BotRecruiter", "onHeard", pNpc)
	createEvent(self.greetEveryMs, "BotRecruiter", "greet", pNpc, tostring(self:generation()))
	print("BotRecruiter: " .. r.name .. " is in the " .. data.title .. " cantina (" .. oid .. ")")
end

-- Humans near him (the bots standing in for humans in tests don't count)
local function humansIn(pNpc, range)
	local out = {}

	for _, pPlayer in ipairs(SceneObject(pNpc):getPlayersInRange(range) or {}) do
		if isBot == nil or not isBot(pPlayer) then
			table.insert(out, pPlayer)
		end
	end

	return out
end

-- An event on him every greetEveryMs: a player who has come in is told what he does, once in a while
function BotRecruiter:greet(pNpc, gen)
	if pNpc == nil or SceneObject(pNpc):getZoneName() == "" or tonumber(gen) ~= self:generation() then
		return
	end

	local now = os.time()

	for _, pPlayer in ipairs(humansIn(pNpc, self.greetRange)) do
		local k = key(SceneObject(pPlayer):getObjectID(), "greeted")

		if now - readData(k) > self.greetCooldown then
			writeData(k, now)
			SceneObject(pNpc):faceObject(pPlayer, true)
			spatialChat(pNpc, pickOne(self.greetings))
			break
		end
	end

	createEvent(self.greetEveryMs, "BotRecruiter", "greet", pNpc, gen)
end

-- Listening

local function wordsOf(text)
	return " " .. (tostring(text or ""):lower():gsub("[^%w']", " "):gsub("%s+", " ")) .. " "
end

function BotRecruiter:wanted(text)
	local t = wordsOf(text)

	for _, word in ipairs(self.words) do
		if t:find(" " .. word .. " ", 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- SPATIALCHAT fires on him when someone speaks within 25 m
function BotRecruiter:onHeard(pNpc, pChatMessage, speakerId)
	if pNpc == nil or pChatMessage == nil then
		return 0
	end

	local pPlayer = getSceneObject(speakerId)

	-- People only: not the bots (a bot never talks to him), not the crowd
	if pPlayer == nil or not SceneObject(pPlayer):isPlayerCreature() or (isBot ~= nil and isBot(pPlayer)) then
		return 0
	end

	local text = getChatMessage(pChatMessage)

	if text == nil or text == "" then
		return 0
	end

	local oid = SceneObject(pNpc):getObjectID()
	local cantina = readStringData("recruit:city:" .. oid)
	local data = BotCrewData.cantinas[cantina]

	if data == nil then
		return 0
	end

	-- Meant for him: he is their target, or they use his name
	local target = CreatureObject(pPlayer):getTargetID()
	local meant = target == oid

	if not meant and target == 0 then
		meant = wordsOf(text):find(" " .. firstOf(data.recruiter.name):lower() .. " ", 1, true) ~= nil
	end

	if not meant then
		return 0
	end

	if self:wanted(text) then
		self:open(pNpc, pPlayer, cantina)
	else
		local k = key(SceneObject(pPlayer):getObjectID(), "nudged")

		if os.time() - readData(k) > self.nudgeCooldown then
			writeData(k, os.time())
			spatialChat(pNpc, pickOne(self.nudges))
		end
	end

	return 0
end

-- Windows

-- A list window with an OK and a cancel button. options: strings.
function BotRecruiter:list(pPlayer, title, text, rows, callback, ok, cancel)
	local options = {}

	for _, row in ipairs(rows) do
		table.insert(options, {row, 0})
	end

	LuaSuiManager():sendListBox(pPlayer, pPlayer, title, text, 2, cancel or "@cancel", "", ok or "@ok", "BotRecruiter", callback, 0, options)
end

-- Tell the player something, in the system line (the recruiter says the good news aloud)
function BotRecruiter:tell(pPlayer, text)
	CreatureObject(pPlayer):sendSystemMessage(text)
end

function BotRecruiter:say(playerOid, line)
	local pNpc = getSceneObject(readData(key(playerOid, "npc")))

	if pNpc ~= nil then
		spatialChat(pNpc, line)
	end
end

-- The windows begin: the player's crew if they have one, else the roles
function BotRecruiter:open(pNpc, pPlayer, cantina, anyDistance)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local dist = SceneObject(pNpc):getDistanceTo(pPlayer)

	if not anyDistance and (dist == nil or dist > self.talkRange) then
		spatialChat(pNpc, self.tooFar)
		return
	end

	-- (a window answered later than this one is dropped)
	writeData(key(playerOid, "session"), os.time())
	writeStringData(key(playerOid, "cantina"), cantina)
	writeData(key(playerOid, "npc"), SceneObject(pNpc):getObjectID())
	self:forget(playerOid)
	SceneObject(pNpc):faceObject(pPlayer, true)

	local crew = botCrewOf(playerOid) or {}

	if #crew > 0 then
		self:showCrew(pPlayer)
	else
		self:showRoles(pPlayer)
	end
end

-- Forget the player's unfinished design (their reserved names go back to the crowd)
function BotRecruiter:forget(playerOid)
	-- (a name that went to a hired bot stays kept)
	for _, first in ipairs(split(readStringData(key(playerOid, "reserved")))) do
		if readData("crew:name:" .. first) ~= self.keptForever then
			deleteData("crew:name:" .. first)
		end
	end

	for _, field in ipairs({"reserved", "roles", "avail", "chosen", "stage", "i", "sugg", "let"}) do
		deleteStringData(key(playerOid, field))
		deleteData(key(playerOid, field))
	end

	for i = 1, 7 do
		for _, field in ipairs({"species", "sex", "name", "look"}) do
			deleteStringData(key(playerOid, "b" .. i .. field))
		end
	end
end

-- 1. The crew

function BotRecruiter:showCrew(pPlayer)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local crew = botCrewOf(playerOid) or {}
	local rows = {}

	for _, member in ipairs(crew) do
		local role = BotCrewKit:role(member.job)
		local species = BotCrewKit:species(member.species)

		table.insert(rows, member.name .. ", " .. (role ~= nil and role.title or member.job) .. " (" ..
			(species ~= nil and species.title or member.species) .. (member.ready and "" or ", just hired") .. ")")
	end

	if #crew < BotCrewData.crewMax then
		table.insert(rows, "Hire someone for a role you left out...")
	end

	writeStringData(key(playerOid, "stage"), "crew")

	self:list(pPlayer, "Your crew", "Pick one of your crew to let go, or hire someone more.\nA bot you let go is gone for good.", rows,
		"onCrew", "Pick")
end

function BotRecruiter:onCrew(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "crew" then
		return
	end

	local crew = botCrewOf(playerOid) or {}
	local row = tonumber(args) or -1

	if row >= 0 and row < #crew then
		local member = crew[row + 1]

		writeData(key(playerOid, "let"), member.oid)
		writeStringData(key(playerOid, "stage"), "letgo")
		self:list(pPlayer, "Let " .. member.firstName .. " go?", member.name .. " leaves your crew and is gone for good.", {"Let " .. member.firstName .. " go"},
			"onLetGo", "Let go", "Keep")
	elseif row == #crew and #crew < BotCrewData.crewMax then
		self:showRoles(pPlayer)
	end
end

function BotRecruiter:onLetGo(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "letgo" then
		return
	end

	local oid = readData(key(playerOid, "let"))

	-- (only their own: the owner is checked here, the C++ lets go any own-crew bot)
	if botOwner(oid) ~= playerOid then
		return
	end

	local first = ""

	for _, member in ipairs(botCrewOf(playerOid) or {}) do
		if member.oid == oid then
			first = member.firstName
		end
	end

	local ok, reason = botLetGo(oid)

	if ok and first ~= "" then
		deleteData("crew:name:" .. first:lower())
	end

	deleteData(key(playerOid, "let"))
	writeStringData(key(playerOid, "stage"), "")

	if ok then
		self:tell(pPlayer, "Your crew member is gone.")
		self:say(playerOid, "Done. I'll tell " .. (first ~= "" and first or "them") .. " it's been a pleasure.")
	else
		self:tell(pPlayer, "That did not work: " .. tostring(reason))
	end
end

-- 2. The roles

-- The roles the player's crew doesn't have yet, in the order of the list
function BotRecruiter:available(playerOid)
	local have = {}

	for _, member in ipairs(botCrewOf(playerOid) or {}) do
		have[member.job] = true
	end

	local out = {}

	for _, role in ipairs(BotCrewData.roles) do
		if not have[role.id] then
			table.insert(out, role.id)
		end
	end

	return out
end

function BotRecruiter:showRoles(pPlayer)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local avail = self:available(playerOid)
	local chosen = {}

	for _, id in ipairs(split(readStringData(key(playerOid, "chosen")))) do
		chosen[id] = true
	end

	local rows, count = {}, 0

	for _, id in ipairs(avail) do
		local role = BotCrewKit:role(id)

		table.insert(rows, (chosen[id] and "[x] " or "[  ] ") .. role.title .. ": " .. role.line)

		if chosen[id] then
			count = count + 1
		end
	end

	table.insert(rows, count > 0 and ("Continue with " .. count .. " role" .. (count == 1 and "" or "s")) or "Continue (pick at least one role)")

	writeStringData(key(playerOid, "avail"), table.concat(avail, ","))
	writeStringData(key(playerOid, "stage"), "roles")

	self:list(pPlayer, "A crew of your own", "Pick the roles you want, one bot each. A pick turns a role on or off; then Continue.\n" ..
		"Each starts with as many skill boxes as your character has, and learns no more yet.", rows, "onRoles", "Pick")
end

function BotRecruiter:onRoles(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		self:cancel(pPlayer)
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "roles" then
		return
	end

	local avail = split(readStringData(key(playerOid, "avail")))
	local row = tonumber(args) or -1
	local chosen = split(readStringData(key(playerOid, "chosen")))

	if row >= 0 and row < #avail then
		local id = avail[row + 1]
		local kept, found = {}, false

		for _, other in ipairs(chosen) do
			if other == id then
				found = true
			else
				table.insert(kept, other)
			end
		end

		if not found then
			table.insert(kept, id)
		end

		writeStringData(key(playerOid, "chosen"), table.concat(kept, ","))
		self:showRoles(pPlayer)
	elseif row == #avail then
		if #chosen == 0 then
			self:showRoles(pPlayer)
			return
		end

		-- In the order of the list, not of the picks
		local picks = {}

		for _, id in ipairs(avail) do
			for _, other in ipairs(chosen) do
				if other == id then
					table.insert(picks, id)
				end
			end
		end

		writeStringData(key(playerOid, "roles"), table.concat(picks, ","))
		writeData(key(playerOid, "i"), 1)
		self:showSpecies(pPlayer)
	end
end

-- 3. Each bot in turn

function BotRecruiter:current(playerOid)
	local roles = split(readStringData(key(playerOid, "roles")))
	local i = readData(key(playerOid, "i"))

	return roles[i], i, #roles
end

function BotRecruiter:showSpecies(pPlayer)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local roleId, i, n = self:current(playerOid)
	local role = BotCrewKit:role(roleId)
	local rows = {}

	for _, species in ipairs(BotCrewData.species) do
		table.insert(rows, species.title .. ", male")
		table.insert(rows, species.title .. ", female")
	end

	writeStringData(key(playerOid, "stage"), "species")
	self:list(pPlayer, role.title .. " (" .. i .. " of " .. n .. ")", "What kind of person is your " .. role.title:lower() .. "?", rows, "onSpecies", "Pick")
end

function BotRecruiter:onSpecies(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		self:cancel(pPlayer)
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "species" then
		return
	end

	local row = tonumber(args) or -1
	local species = BotCrewData.species[math.floor(row / 2) + 1]

	if row < 0 or species == nil then
		self:showSpecies(pPlayer)
		return
	end

	local _, i = self:current(playerOid)

	writeStringData(key(playerOid, "b" .. i .. "species"), species.id)
	writeStringData(key(playerOid, "b" .. i .. "sex"), row % 2 == 0 and "male" or "female")
	self:showName(pPlayer, nil)
end

-- Names

-- Is a first name taken: by a crew bot or a character, by the crowd in any city, by someone else's pick in the windows, or by
-- another of this player's picks? nil if free, else why not
function BotRecruiter:firstTaken(first, playerOid)
	local lower = first:lower()

	-- (the recruiters' own names)
	for _, cantina in ipairs(self.cities) do
		if firstOf(BotCrewData.cantinas[cantina].recruiter.name):lower() == lower then
			return "that is a recruiter's name"
		end
	end

	if botNameFree ~= nil then
		local ok, reason = botNameFree(first)

		if not ok then
			return reason
		end
	end

	for _, cantina in ipairs(self.cities) do
		if readData("lc:" .. cantina .. ":name:" .. lower) ~= 0 then
			return "someone in " .. BotCrewData.cantinas[cantina].title .. " has that name"
		end
	end

	local own = false

	for _, reserved in ipairs(split(readStringData(key(playerOid, "reserved")))) do
		own = own or reserved == lower
	end

	if readData("crew:name:" .. lower) > os.time() and not own then
		return "someone else is choosing that name"
	end

	for i = 1, 7 do
		local other = readStringData(key(playerOid, "b" .. i .. "name"))

		if other ~= "" and firstOf(other):lower() == lower and i ~= readData(key(playerOid, "i")) then
			return "another of your crew has that name"
		end
	end

	return nil
end

-- A name for a species in its own style: from the crowd's lists (names.lua), checked by Core3's rules and free
function BotRecruiter:suggest(species, playerOid)
	local names = LivingCitiesNames ~= nil and (LivingCitiesNames[species] or LivingCitiesNames) or nil
	local info = BotCrewKit:species(species)
	local oneName = info ~= nil and info.oneName == true

	if names == nil then
		return nil
	end

	for _ = 1, self.suggestTries do
		local first, last = pickOne(names.first), pickOne(names.last)
		local name = oneName and first or (first .. " " .. last)

		if #first >= 3 and self:firstTaken(first, playerOid or 0) == nil and (botNameCheck == nil or botNameCheck(name, species)) then
			return name
		end
	end

	return nil
end

-- The name window; complaint: why the last try failed
function BotRecruiter:showName(pPlayer, complaint)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local roleId, i = self:current(playerOid)
	local role = BotCrewKit:role(roleId)
	local species = readStringData(key(playerOid, "b" .. i .. "species"))
	local sex = readStringData(key(playerOid, "b" .. i .. "sex"))
	local info = BotCrewKit:species(species)
	local suggestion = readStringData(key(playerOid, "sugg"))

	if suggestion == "" or complaint == nil then
		suggestion = self:suggest(species, playerOid) or ""
		writeStringData(key(playerOid, "sugg"), suggestion)
	end

	local prompt = "Name your " .. info.title .. " " .. role.title:lower() .. " (" .. sex .. ").\n" ..
		(complaint ~= nil and (complaint .. "\n") or "") ..
		(info.oneName and "A " .. info.title .. " has a single name." or "A first name and a last name.") ..
		(suggestion ~= "" and ("\nLeave it as it is for " .. suggestion .. ", or type your own.") or "\nType a name.")

	writeStringData(key(playerOid, "stage"), "name")

	local sui = SuiInputBox.new("BotRecruiter", "onName")

	sui.setTargetNetworkId(playerOid)
	sui.setTitle("A name")
	sui.setPrompt(prompt)
	sui.setProperty("txtInput", "Text", suggestion)
	sui.sendTo(pPlayer)
end

-- Core3's name rules and ours; nil if the name will do, else a line for the player
function BotRecruiter:nameProblem(name, species, playerOid)
	local info = BotCrewKit:species(species)

	if name:find("[^%a' ]") then
		return "Names are letters only, with an apostrophe if you like."
	end

	local words = {}

	for word in name:gmatch("%S+") do
		table.insert(words, word)
	end

	if #words == 0 or #words > 2 or (info.oneName and #words > 1) then
		return info.oneName and "A " .. info.title .. " has one name." or "A first name, and a last name if you like."
	end

	if #words[1] < 3 then
		return "That first name is too short."
	end

	local taken = self:firstTaken(words[1], playerOid)

	if taken ~= nil then
		return "That won't do: " .. taken .. "."
	end

	if botNameCheck ~= nil then
		local ok, reason = botNameCheck(name, species)

		if not ok then
			return reason ~= "" and reason or "The game won't take that name."
		end
	end

	return nil
end

function BotRecruiter:onName(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		self:cancel(pPlayer)
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "name" then
		return
	end

	local _, i = self:current(playerOid)
	local species = readStringData(key(playerOid, "b" .. i .. "species"))
	local typed = (tostring(args or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
	local name = typed

	if name == "" then
		name = readStringData(key(playerOid, "sugg"))
	end

	-- A first letter big, the rest as they typed
	name = (name:gsub("(%a)([%a']*)", function(a, b) return a:upper() .. b end, 2))

	local problem = name == "" and "Type a name." or self:nameProblem(name, species, playerOid)

	if problem ~= nil then
		self:showName(pPlayer, problem)
		return
	end

	writeStringData(key(playerOid, "b" .. i .. "name"), name)
	deleteStringData(key(playerOid, "sugg"))

	-- Keep the crowd off it while the rest of the crew is designed
	local first = firstOf(name):lower()

	writeData("crew:name:" .. first, os.time() + self.reserveSeconds)
	writeStringData(key(playerOid, "reserved"), readStringData(key(playerOid, "reserved")) .. (readStringData(key(playerOid, "reserved")) == "" and "" or ",") .. first)

	self:showLook(pPlayer)
end

-- Looks

function BotRecruiter:showLook(pPlayer)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local roleId, i = self:current(playerOid)
	local species = readStringData(key(playerOid, "b" .. i .. "species"))
	local sex = readStringData(key(playerOid, "b" .. i .. "sex"))
	local rows = {}

	for _, look in ipairs(BotCrewKit:looks(species, sex)) do
		table.insert(rows, look.label)
	end

	if #rows == 0 then
		table.insert(rows, "As they are")
	end

	writeStringData(key(playerOid, "stage"), "look")
	self:list(pPlayer, "A look for " .. firstOf(readStringData(key(playerOid, "b" .. i .. "name"))),
		"Hairstyles are the ones the character creator offers; a species with no hair gets a skin tone.", rows, "onLook", "Pick")
end

function BotRecruiter:onLook(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		self:cancel(pPlayer)
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "look" then
		return
	end

	local _, i, n = self:current(playerOid)
	local row = tonumber(args) or -1

	if row < 0 then
		self:showLook(pPlayer)
		return
	end

	writeData(key(playerOid, "b" .. i .. "look"), row + 1)

	if i < n then
		writeData(key(playerOid, "i"), i + 1)
		deleteStringData(key(playerOid, "sugg"))
		self:showSpecies(pPlayer)
	else
		self:showConfirm(pPlayer)
	end
end

-- 4. The summary

function BotRecruiter:planOf(playerOid)
	local plan = {}

	for i, roleId in ipairs(split(readStringData(key(playerOid, "roles")))) do
		table.insert(plan, {
			role = roleId,
			species = readStringData(key(playerOid, "b" .. i .. "species")),
			sex = readStringData(key(playerOid, "b" .. i .. "sex")),
			name = readStringData(key(playerOid, "b" .. i .. "name")),
			look = readData(key(playerOid, "b" .. i .. "look")),
		})
	end

	return plan
end

function BotRecruiter:showConfirm(pPlayer)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local rows = {}

	for _, bot in ipairs(self:planOf(playerOid)) do
		local role = BotCrewKit:role(bot.role)
		local species = BotCrewKit:species(bot.species)
		local look = BotCrewKit:looks(bot.species, bot.sex)[bot.look]

		table.insert(rows, bot.name .. ": " .. role.title .. ", " .. bot.sex .. " " .. species.title .. (look ~= nil and (", " .. look.label) or ""))
	end

	writeStringData(key(playerOid, "stage"), "confirm")
	self:list(pPlayer, "Your crew", "They start with " .. botBoxCount(playerOid) .. " skill boxes each, as your character has, and wait in the cantina.", rows,
		"onConfirm", "Hire them", "Not now")
end

function BotRecruiter:onConfirm(pPlayer, pSui, eventIndex, args)
	if eventIndex == 1 or pPlayer == nil then
		self:cancel(pPlayer)
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()

	if readStringData(key(playerOid, "stage")) ~= "confirm" then
		return
	end

	local results = self:hireAll(playerOid, self:planOf(playerOid), readStringData(key(playerOid, "cantina")), botBoxCount(playerOid))
	local failed = {}

	for _, r in ipairs(results) do
		if not r.ok then
			table.insert(failed, r.name .. " (" .. tostring(r.reason) .. ")")
		end
	end

	self:forget(playerOid)

	if #failed == 0 then
		self:say(playerOid, self.done)
		self:tell(pPlayer, "Your crew is hired. They are waiting in the cantina.")
	else
		self:tell(pPlayer, "Not everyone could be hired: " .. table.concat(failed, "; "))
	end
end

-- Hires a plan ({role, species, sex, name, look}, ...) for an owner in a cantina at a level. Returns {{name, ok, reason}, ...}.
-- The same for the windows and the console.
function BotRecruiter:hireAll(ownerOid, plan, cantina, boxes, reuseStations)
	local results = {}
	local used = self:stationsUsed(cantina)

	for _, bot in ipairs(plan) do
		local look = BotCrewKit:looks(bot.species, bot.sex)[bot.look or 1] or {}
		local station = BotCrewKit:station(cantina, used) or (reuseStations and BotCrewKit:station(cantina, {}) or nil)
		local ok, reason = false, "the cantina is full"

		if station ~= nil then
			table.insert(used, {station.x, station.y})

			local entry = BotCrewKit:entry({role = bot.role, species = bot.species, sex = bot.sex, name = bot.name, look = look,
				boxes = boxes, city = cantina, station = station})

			ok, reason = botHire(ownerOid, entry)
		end

		if ok then
			-- (the crowd keeps off the name for good: it is a bot's now)
			writeData("crew:name:" .. firstOf(bot.name):lower(), self.keptForever)
		end

		table.insert(results, {name = bot.name, ok = ok, reason = reason})
	end

	return results
end

-- The station points of the bots already in a cantina
function BotRecruiter:stationsUsed(cantina)
	local used = {}

	for _, member in ipairs(botList() or {}) do
		if member.city == cantina and botEntry ~= nil then
			local entry = botEntry(member.firstName)

			if entry ~= nil and entry.station ~= nil then
				table.insert(used, {entry.station.x, entry.station.y})
			end
		end
	end

	return used
end

function BotRecruiter:cancel(pPlayer)
	if pPlayer == nil then
		return
	end

	self:forget(SceneObject(pPlayer):getObjectID())
end

-- Development ---------------------------------------------------------------------------------------------------------------

-- A character: an online bot by first name (the local server has no clients), or an oid
local function ownerOid(who)
	if tonumber(who) ~= nil then
		return tonumber(who)
	end

	local pBot = botGetCreature ~= nil and botGetCreature(who) or nil

	if pBot ~= nil then
		return SceneObject(pBot):getObjectID()
	end

	-- (a bot that is offline has its oid in the list too: a crew is its owner's whether the owner is on or not)
	for _, m in ipairs(botList ~= nil and botList() or {}) do
		if m.firstName:lower() == tostring(who):lower() then
			return m.oid
		end
	end

	return 0
end

function BotRecruiter:devHire(who, roles, cantina, boxes, species)
	local owner = ownerOid(who)
	local data = BotCrewData.cantinas[cantina or "mos_eisley"]

	if owner == 0 or data == nil then
		print("BotRecruiter: devHire: no such owner (an online bot's first name, or an oid) or cantina")
		return
	end

	local level = tonumber(boxes) or botBoxCount(owner)
	local plan, n = {}, 0

	for _, roleId in ipairs(split(roles)) do
		local info = species ~= nil and BotCrewKit:species(species) or BotCrewData.species[n % #BotCrewData.species + 1]
		local sex = n % 2 == 0 and "male" or "female"

		n = n + 1

		local name = self:suggest(info.id, owner)

		if name == nil then
			print("BotRecruiter: devHire: no name for " .. info.id)
		else
			writeData("crew:name:" .. firstOf(name):lower(), os.time() + self.reserveSeconds)
			table.insert(plan, {role = roleId, species = info.id, sex = sex, name = name, look = 1 + n % 3})
		end
	end

	print("BotRecruiter: devHire for " .. who .. " (" .. owner .. ") at " .. level .. " boxes in " .. (cantina or "mos_eisley"))

	for _, r in ipairs(self:hireAll(owner, plan, cantina or "mos_eisley", level)) do
		print("BotRecruiter:   " .. r.name .. ": " .. (r.ok and "hired" or ("NOT hired: " .. tostring(r.reason))))
	end
end

function BotRecruiter:devCrew(who)
	local owner = ownerOid(who)

	print("BotRecruiter: crew of " .. who .. " (" .. owner .. "):")

	for _, m in ipairs(botCrewOf(owner) or {}) do
		print(string.format("BotRecruiter:   %s %s %s %s %s oid %d %s", m.name, m.job, m.species, m.sex, m.city, m.oid, m.online and "online" or m.state))
	end
end

function BotRecruiter:devLetGo(first)
	for _, m in ipairs(botList() or {}) do
		if m.firstName:lower() == tostring(first):lower() then
			local ok, reason = botLetGo(m.oid)

			print("BotRecruiter: let go " .. m.name .. ": " .. tostring(ok) .. (ok and "" or (" (" .. tostring(reason) .. ")")))

			if ok then
				deleteData("crew:name:" .. m.firstName:lower())
			end

			return
		end
	end

	print("BotRecruiter: no bot " .. tostring(first))
end

function BotRecruiter:devSuggest(species)
	print("BotRecruiter: suggestion for " .. tostring(species) .. ": " .. tostring(self:suggest(species or "human", 0)))
end

-- Opens the first window for a real player (a client), as the recruiter would
function BotRecruiter:devWindows(who, cantina, stage)
	local pPlayer = getSceneObject(ownerOid(who))
	local pNpc = getSceneObject(readData("recruit:npc:" .. (cantina or "mos_eisley")))

	if pPlayer == nil or pNpc == nil then
		print("BotRecruiter: devWindows: no such player or recruiter")
		return
	end

	self:open(pNpc, pPlayer, cantina or "mos_eisley", true)

	-- A later window with a made-up design behind it, to see it open: name, look, confirm
	if stage ~= nil then
		local playerOid = SceneObject(pPlayer):getObjectID()

		self:forget(playerOid)
		writeStringData(key(playerOid, "roles"), "tank")
		writeData(key(playerOid, "i"), 1)
		writeStringData(key(playerOid, "b1species"), "human")
		writeStringData(key(playerOid, "b1sex"), "male")
		writeStringData(key(playerOid, "b1name"), "Test Name")
		writeData(key(playerOid, "b1look"), 1)

		if stage == "name" then
			self:showName(pPlayer, nil)
		elseif stage == "look" then
			self:showLook(pPlayer)
		elseif stage == "confirm" then
			self:showConfirm(pPlayer)
		elseif stage == "species" then
			self:showSpecies(pPlayer)
		elseif stage == "roles" then
			self:showRoles(pPlayer)
		end
	end
end

-- A creature in a bot's own cell, <dx>, <dy> metres east and north of it (BotCrew:devSpawn puts one outdoors, behind walls
-- when the bot is in a building): runLuaFunction BotRecruiter:devSpawnIn:<bot first name>:<mobile template>[:<dx>:<dy>]
function BotRecruiter:devSpawnIn(first, template, dx, dy)
	local pBot = botGetCreature ~= nil and botGetCreature(first) or nil

	if pBot == nil or template == nil then
		print("BotRecruiter: usage devSpawnIn:<online bot>:<mobile template>[:<dx>:<dy>]")
		return
	end

	createEvent(10, "BotRecruiter", "devSpawnInNow", pBot, packArgs(template, tonumber(dx or "") or 4, tonumber(dy or "") or 0))
end

function BotRecruiter:devSpawnInNow(pBot, args)
	local a = unpackArgs(args)
	local pMobile = spawnMobile(SceneObject(pBot):getZoneName(), a[1], 0, SceneObject(pBot):getPositionX() + tonumber(a[2]),
		SceneObject(pBot):getPositionZ(), SceneObject(pBot):getPositionY() + tonumber(a[3]), 0, SceneObject(pBot):getParentID())

	print("BotRecruiter: spawned " .. a[1] .. ": " .. (pMobile ~= nil and tostring(SceneObject(pMobile):getObjectID()) or "failed"))
end

-- Every species and sex in one cantina with the given roles at a level, each pair of species and sex under an owner of its own
-- (an object id counted up from <base>: no such character, so the bots never log in), to see that every piece a kit picks can be worn
-- (BotFactory logs "can't wear" for the ones that can't):  runLuaFunction BotRecruiter:devMatrix:<base oid>:<roles>:<boxes>[:<one species>]
-- and, to take them away again,  runLuaFunction BotRecruiter:devPurge:<base oid>
function BotRecruiter:devMatrix(base, roles, boxes, only)
	local owner = tonumber(base)
	local n = 0

	for _, info in ipairs(BotCrewData.species) do
		for _, sex in ipairs({"male", "female"}) do
			local plan = {}

			for _, roleId in ipairs((only == nil or only == info.id) and split(roles) or {}) do
				local name = self:suggest(info.id, owner + n)

				-- (the species' lists run dry over a hundred bots: Core3's own name generator then)
				for _ = 1, 60 do
					if name ~= nil or makeCreatureName == nil then
						break
					end

					local first = string.match(makeCreatureName(), "%a+") or ""
					local try = first:sub(1, 1):upper() .. first:sub(2):lower()

					if #try >= 4 and self:firstTaken(try, owner + n) == nil and (botNameCheck == nil or botNameCheck(try, info.id)) then
						name = try
					end
				end

				if name == nil then
					print("BotRecruiter: matrix: no name for " .. info.id .. " " .. sex .. " " .. roleId)
				else
					writeData("crew:name:" .. firstOf(name):lower(), os.time() + self.reserveSeconds)
					table.insert(plan, {role = roleId, species = info.id, sex = sex, name = name, look = 1})
				end
			end

			for _, r in ipairs(self:hireAll(owner + n, plan, "mos_eisley", tonumber(boxes) or 0, true)) do
				if not r.ok then
					print("BotRecruiter: matrix " .. info.id .. " " .. sex .. " " .. r.name .. ": NOT hired: " .. tostring(r.reason))
				end
			end

			n = n + 1
		end
	end

	print("BotRecruiter: matrix hired for " .. n .. " owners from " .. owner)
end

function BotRecruiter:devPurge(base)
	local owner = tonumber(base)

	for n = 0, 19 do
		for _, m in ipairs(botCrewOf(owner + n) or {}) do
			botLetGo(m.oid)
			deleteData("crew:name:" .. m.firstName:lower())
		end
	end
end
