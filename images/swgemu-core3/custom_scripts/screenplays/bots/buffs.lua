-- Bot players (Phase 11, built with Phase 9b): buff time left. Spec: ~/github/swgemu/specs/2026-10-25-crew-doctrine/ (5).
--
-- "buffs" in group chat (or a tell with it to a crew bot or a band bot) opens a window for whoever asked: a row for each member
-- of their group, them first and then the crew, with the minutes left on the dancer's mind buff, the musician's focus and
-- willpower, the doctor's six enhancements (the least time left of them and how many are on) and battle fatigue. Out of a group
-- it is their own row only. The window is read when it opens; asking again reads it fresh (a window can be closed and sent again,
-- not updated). Their own buffs the client already shows, with time left in the icon's tooltip; what is new here is the group's,
-- which never reaches the client.
-- A system message tells each human online when their own mind buffs reach 15 minutes ("Your mind buffs have 15 minutes
-- left."), once per buff.
--
-- botGetBuffs locks the creature it reads, so every reading is an event on that creature (never from inside another creature's
-- lock): gather (on the asker: who is in the group), readOne (on each member), show (on the asker: sends the window). State lives
-- in shared memory under buffs:*; a window waits for its readings at most a few seconds. No model is asked.
--
-- Console: runLuaFunction BotBuffs:devWindow:<first>   a bot's window, as if it had asked (the rows go to the log)

BotBuffs = ScreenPlay:new {
	screenplayName = "BotBuffs",

	-- The mind buffs, as Core3 names them (modifiers.iff), and the doctor's enhancements (medical_enhance_<attribute>)
	mind = {"performance_enhance_dance_mind", "performance_enhance_music_focus", "performance_enhance_music_willpower"},
	-- A human's own mind buffs are looked at this often (s), and warned about at this many seconds left
	warnEvery = 60,
	warnAt = 900,
	-- A warning chain that hasn't run for this long (s) is started again by the bots' tick
	warnStale = 150,
	-- A window waits this long (ms) for the members' readings, and again (up to showTries times) when some are missing
	showAfter = 700,
	showAgain = 400,
	showTries = 3,
	-- Asking again within this many seconds is one window
	askGap = 3,
}

registerScreenPlay("BotBuffs", true)

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

function BotBuffs:start()
	print("BotBuffs: started")
end

-- "buffs", "buff check", "how are the buffs": the whole line, nothing else (so "buff us up" is still a request for the doctor's work)
function BotBuffs:wanted(text)
	local t = (tostring(text or ""):lower():gsub("[^%w' ]", " "):gsub("'", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))

	if t == "" then
		return false
	end

	local patterns = {"^buffs$", "^buffs? check$", "^buff times?$", "^buffs? status$", "^buffs? left$", "^buffs? time left$",
		"^check buffs$", "^check the buffs$", "^check our buffs$", "^check my buffs$", "^show buffs$", "^show the buffs$",
		"^how are the buffs$", "^how are our buffs$", "^how are my buffs$", "^hows the buffs$", "^hows our buffs$", "^hows my buffs$",
		"^how s the buffs$", "^how s our buffs$", "^how s my buffs$", "^how re the buffs$", "^time left on buffs$",
		"^time left on the buffs$", "^time left on our buffs$", "^how long are the buffs$", "^how long are our buffs$",
		"^how long are my buffs$", "^how long left on buffs$", "^how long left on the buffs$"}

	for _, pattern in ipairs(patterns) do
		if t:match(pattern) then
			return true
		end
	end

	return false
end

-- Someone asked: gather the rows in events and open the window. pBot is the bot that heard it (it only starts the gathering)
function BotBuffs:window(pBot, pAsker, channel)
	local askerOid = SceneObject(pAsker):getObjectID()
	local now = os.time()

	if now - readData("buffs:ask:" .. askerOid) < self.askGap then
		return false
	end

	put("buffs:ask:" .. askerOid, now)

	local id = askerOid .. "x" .. getTimestampMilli()

	putString("buffs:win:" .. id .. ":asker", tostring(askerOid))
	createEvent(1, "BotBuffs", "gather", pAsker, packArgs(id, channel or "tell"))

	return true
end

-- An event on the asker: who is in their group (the asker, then the other humans, then the crew, then anyone else)
function BotBuffs:gather(pAsker, args)
	local a = unpackArgs(args)
	local id = a[1]

	if pAsker == nil or id == nil then
		return
	end

	local asker = CreatureObject(pAsker)
	local askerOid = SceneObject(pAsker):getObjectID()
	local list = {pAsker}

	if asker:isGrouped() then
		local others = {humans = {}, bots = {}}

		for i = 0, (asker:getGroupSize() or 0) - 1 do
			local pMember = asker:getGroupMember(i)

			if pMember ~= nil and SceneObject(pMember):isCreatureObject() and SceneObject(pMember):getObjectID() ~= askerOid then
				table.insert(BotCrew:human(pMember) and others.humans or others.bots, pMember)
			end
		end

		for _, kind in ipairs({"humans", "bots"}) do
			for _, pMember in ipairs(others[kind]) do
				table.insert(list, pMember)
			end
		end
	end

	put("buffs:win:" .. id .. ":n", #list)
	deleteStringData("buffs:win:" .. id .. ":rows")

	for i, pMember in ipairs(list) do
		deleteStringData("buffs:win:" .. id .. ":" .. i)
		createEvent(1, "BotBuffs", "readOne", pMember, packArgs(id, i, SceneObject(pMember):getObjectID() == askerOid and 1 or 0))
	end

	createEvent(self.showAfter, "BotBuffs", "show", pAsker, packArgs(id, 1))
end

-- The minutes left, rounded up (a buff with 10 s left is still 1)
local function minutes(seconds)
	return math.ceil((tonumber(seconds) or 0) / 60)
end

-- An event on a member: its buffs as a row. botGetBuffs locks the creature, which this event holds.
function BotBuffs:readOne(pMember, args)
	local a = unpackArgs(args)
	local id, index, isAsker = a[1], tonumber(a[2]), a[3] == "1"

	if pMember == nil or id == nil or index == nil then
		return
	end

	local left, doctor, count = {}, nil, 0

	for _, buff in ipairs(botGetBuffs(pMember) or {}) do
		local name = tostring(buff.name or "")
		local seconds = tonumber(buff.secondsLeft) or 0

		if name:find("^performance_enhance_") then
			left[name] = seconds
		elseif name:find("^medical_enhance_") then
			count = count + 1

			if doctor == nil or seconds < doctor then
				doctor = seconds
			end
		end
	end

	local function show(seconds)
		return seconds ~= nil and tostring(minutes(seconds)) or "-"
	end

	local fatigue = tonumber(botGetShockWounds(pMember)) or 0
	local name = CreatureObject(pMember):getFirstName() or "?"

	putString("buffs:win:" .. id .. ":" .. index, string.format("%s%s: mind %s, focus %s, willpower %s, doctor %s%s, battle fatigue %s",
		name, isAsker and " (you)" or "", show(left[self.mind[1]]), show(left[self.mind[2]]), show(left[self.mind[3]]),
		show(doctor), count > 0 and (" (" .. count .. " of 6)") or "", fatigue > 0 and tostring(fatigue) or "none"))
end

-- An event on the asker, after the readings: the window (a row that is missing is waited for a little, then left out)
function BotBuffs:show(pAsker, args)
	local a = unpackArgs(args)
	local id, tries = a[1], tonumber(a[2]) or 1

	if pAsker == nil or id == nil then
		return
	end

	local n = readData("buffs:win:" .. id .. ":n")
	local rows, missing = {}, 0

	for i = 1, n do
		local row = readStringData("buffs:win:" .. id .. ":" .. i)

		if row == "" then
			missing = missing + 1
		else
			table.insert(rows, row)
		end
	end

	if missing > 0 and tries < self.showTries then
		createEvent(self.showAgain, "BotBuffs", "show", pAsker, packArgs(id, tries + 1))
		return
	end

	for i = 1, n do
		deleteStringData("buffs:win:" .. id .. ":" .. i)
	end

	deleteStringData("buffs:win:" .. id .. ":asker")
	deleteData("buffs:win:" .. id .. ":n")

	if #rows == 0 then
		return
	end

	print("BotBuffs: window for " .. (CreatureObject(pAsker):getFirstName() or "?") .. ":\n" .. table.concat(rows, "\n"))

	local options = {}

	for _, row in ipairs(rows) do
		table.insert(options, {row, 0})
	end

	-- (one OK button, no distance limit: the window stays until it is closed)
	LuaSuiManager():sendListBox(pAsker, pAsker, "Buff times", "Minutes left on each buff. Say \"buffs\" again for fresh times.", 1, "", "",
		"@ok", "BotBuffs", "windowClosed", 0, options)
end

-- (the window's callback: nothing to do)
function BotBuffs:windowClosed(pPlayer, pSui, eventIndex, args)
end

-- The warning: each human online has a chain of events on themselves, once a minute

-- Called from the bots' tick (BotJobs:tick): a chain for every human online that has none (at most every 20 s)
function BotBuffs:keep(now)
	if now - readData("buffs:keepAt") < 20 then
		return
	end

	put("buffs:keepAt", now)

	for _, humanOid in ipairs(BotCrew:humansOnline()) do
		local k = "buffs:warn:" .. humanOid

		if now - readData(k .. ":at") > self.warnStale then
			local pHuman = getSceneObject(humanOid)

			if pHuman ~= nil then
				local seq = readData(k .. ":seq") + 1

				put(k .. ":seq", seq)
				put(k .. ":at", now)
				createEvent(getRandomNumber(5000, 30000), "BotBuffs", "warn", pHuman, packArgs(humanOid, seq))
			end
		end
	end
end

-- An event on the human: their own mind buffs, a system message at warnAt seconds left, once per buff (keyed by its end time, so a
-- renewed buff warns again)
function BotBuffs:warn(pHuman, args)
	local a = unpackArgs(args)
	local humanOid, seq = tonumber(a[1]), tonumber(a[2])

	if pHuman == nil or humanOid == nil or seq ~= readData("buffs:warn:" .. humanOid .. ":seq") then
		return
	end

	local now = os.time()
	local k = "buffs:warn:" .. humanOid

	put(k .. ":at", now)

	local ending = false
	local mine = {}

	for _, name in ipairs(self.mind) do
		mine[name] = true
	end

	for _, buff in ipairs(botGetBuffs(pHuman) or {}) do
		local left = tonumber(buff.secondsLeft) or 0

		if mine[tostring(buff.name or "")] and left > 0 and left <= self.warnAt then
			local endAt = now + left
			local last = readData(k .. ":" .. buff.name)

			if last == 0 or math.abs(endAt - last) > 120 then
				put(k .. ":" .. buff.name, endAt)
				ending = true
			end
		end
	end

	if ending then
		CreatureObject(pHuman):sendSystemMessage("Your mind buffs have " .. math.floor(self.warnAt / 60) .. " minutes left.")
		print("BotBuffs: warned " .. (CreatureObject(pHuman):getFirstName() or "?") .. " that their mind buffs have " ..
			math.floor(self.warnAt / 60) .. " minutes left")
	end

	-- (the chain ends when they log out; keep starts it again when they're back)
	for _, online in ipairs(BotCrew:humansOnline()) do
		if online == humanOid then
			createEvent(self.warnEvery * 1000, "BotBuffs", "warn", pHuman, args)
			return
		end
	end

	deleteData(k .. ":at")
end

-- Development: a bot's window, as if it had asked for it (the local server has no client; the rows go to the log)
function BotBuffs:devWindow(first)
	local pBot = botGetCreature ~= nil and botGetCreature(first or "") or nil

	if pBot == nil then
		print("BotBuffs: no online bot called " .. tostring(first))
		return
	end

	put("buffs:ask:" .. SceneObject(pBot):getObjectID(), 0)
	self:window(pBot, pBot, "tell")
end
