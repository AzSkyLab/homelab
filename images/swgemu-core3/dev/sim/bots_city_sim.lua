-- Player city simulator (Phase 6): a mock of the C++ city and mover bindings (the contract is
-- ~/github/swgemu/specs/2026-10-23-bot-players/interfaces.md, "Phases 4-6"), the few Core3 rules the city jobs depend
-- on (placestructure's reach, deed, rank, mayor and skill checks; residence; the weekly update with its upkeep, rank
-- and election), and scenarios that drive the mayor, the citizens and the city's dancer, musician and doctor in
-- custom_scripts/screenplays/bots/. living_cities_sim.lua loads this file and lends it its clock, shared memory and
-- world:
--
--   lua living_cities_sim.lua ../../custom_scripts city cityweeks cityelection cityrestart cityroutine
--
-- It uses the real roster's city bots and the real plan (custom_scripts/bots/city.lua) when they're there, else test
-- ones. city: founding, the houses and residences, a dev fast-forward to rank 5 with every building and decoration,
-- taxes, specialization, registration, the treasury, the entertainers and the doctor moving in. cityweeks: real weekly
-- updates with the bots online a couple of hours a week, the upkeep always paid. cityelection: a human candidate wins,
-- the bot mayor stands aside while a human holds the seat, and runs again when they leave. cityrestart: a server
-- restart (shared memory lost, the world kept) and a second login: no second city, house, building or deed.
-- cityroutine: a day of the citizens' lives.

return function(ctx)
	local sim, Obj, fail, realPrint = ctx.sim, ctx.Obj, ctx.fail, ctx.realPrint
	local scenarios, order = ctx.scenarios, ctx.order

	local function nowMs()
		return sim.now * 1000 + (sim.subMs or 0)
	end

	local function flat(ax, ay, bx, by)
		return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
	end

	local function firstOf(name)
		return (tostring(name):match("^(%S+)"))
	end

	-- Core3's numbers (city_manager.lua, the building templates)
	local CITIZENS = {2, 4, 6, 8, 10}
	local RADIUS = {150, 200, 300, 400, 450}
	local UPKEEP = {garden_sml = 10000, garden_med = 20000, garden_lrg = 30000, bank = 1500, garage = 20000, cloning = 20000,
		shuttleport = 25000}
	local RANK_OF = {garden_sml = 1, bank = 2, garage = 2, cantina = 2, garden_med = 2, cloning = 3, hospital = 3, garden_lrg = 3,
		shuttleport = 4, theater = 4}
	local COMMERCIAL = {cantina = {"dancer", "musician"}, theater = {"dancer", "musician"}, hospital = {"doctor"}}
	local UNIQUE = {bank = false, garage = true, cloning = true, shuttleport = true, cantina = false, hospital = false, theater = false}
	local CELLS = {cantina = {"foyer", "cantina"}, hospital = {"entry", "corner", "mainroom", "crafting"},
		cityhall = {"hall1", "hall2", "grandhall", "mayoroffice", "library"}}

	-- Creature parts the city jobs use (bots_sim.lua adds the HAM ones when it's loaded)
	Obj.getHAM = Obj.getHAM or function(self, pool) return 1000 end
	Obj.getMaxHAM = Obj.getMaxHAM or function(self, pool) return 1000 end
	Obj.getBaseHAM = Obj.getBaseHAM or function(self, pool) return 1000 end
	Obj.setHAM = Obj.setHAM or function(self, pool, v) end
	Obj.getSkillMod = Obj.getSkillMod or function(self, name) return 0 end
	Obj.isDancing = Obj.isDancing or function(self) return self.dancing ~= nil end
	Obj.getCashCredits = Obj.getCashCredits or function(self) return self.cash or 0 end
	Obj.getBankCredits = Obj.getBankCredits or function(self) return self.bank or 0 end
	Obj.getPosture = Obj.getPosture or function(self) return 0 end
	function Obj:addBankCredits(n, notify)
		assert(type(n) == "number" and n >= 0, "addBankCredits " .. tostring(n))
		self.bank = (self.bank or 0) + n
		self.income = (self.income or 0) + n
	end
	function Obj:subtractBankCredits(n)
		assert(type(n) == "number" and n >= 0 and n <= (self.bank or 0), "subtractBankCredits " .. tostring(n) .. " of " .. tostring(self.bank))
		self.bank = self.bank - n
	end
	function Obj:addCashCredits(n) self.cash = (self.cash or 0) + n end
	function Obj:getTemplateObjectPath() return self.template or "" end
	function Obj:getNamedCell(name) return self.cellsByName ~= nil and self.cellsByName[name] or nil end
	-- A bot in a cell has cell-local coordinates; the building's position stands in for its frame
	function Obj:worldXY()
		local x, y, cell = self:now()
		local pCell = (cell or 0) ~= 0 and ctx.objects[cell] or nil
		if pCell ~= nil and pCell.building ~= nil then
			return pCell.building.x + x, pCell.building.y + y
		end
		return x, y
	end
	function Obj:getWorldPositionX() local x = self:worldXY() return x end
	function Obj:getWorldPositionY() local _, y = self:worldXY() return y end
	BuildingObject = BuildingObject or function(p) return p end

	-- One scenario's world
	local W = {}
	local weeklyUpkeep
	local saved = {}
	local overridden = {
		"botList", "botGetCreature", "isBot", "botLogin", "botLogout", "botSetDevHuman", "botEnqueue", "botSay", "botTell",
		"botEmote", "botFace", "botStockPack", "botGetWounds", "botGetShockWounds", "botGetBuffs", "giveItem",
		"getContainerObjectByTemplate", "botMoveTo", "botStop", "botMoveState", "botCheckSite", "botFoundCity", "botCityInfo",
		"botDeclareResidence", "botOwnedStructures", "botCityDeposit", "botCitySetTax", "botCitySetSpec", "botCityZoning",
		"botCityRegister", "botCityCandidate", "botCityVote", "botCityExpand", "botPlaceDecoration", "botPlaceStructure",
		"BotRoster", "BotCityPlan",
		"writeData", "writeStringData",
	}

	-- Test data, when the roster and the plan don't have the city yet
	local testBots = {
		{name = "Tovan Rells", job = "mayor"}, {name = "Lissa Varn", job = "dancer"}, {name = "Corin Dask", job = "musician"},
		{name = "Mela Oskarr", job = "doctor"}, {name = "Brann Teel", job = "citizen", role = "armorsmith"},
		{name = "Ysa Morrow", job = "citizen", role = "chef"}, {name = "Kel Durano", job = "citizen", role = "scout"},
		{name = "Pia Senn", job = "citizen", role = "merchant"}, {name = "Dovic Marr", job = "citizen", role = "bounty hunter"},
		{name = "Reth Callow", job = "citizen", role = "weaponsmith"},
	}

	-- A test plan around the mayor's station: the hall there, its square to the north, civic buildings on a ring at
	-- 85 m and the house lots on one at 125 m, both leaving the square's side free
	local function testPlan(entries)
		local hx, hy = 1000, 1000
		for _, e in ipairs(entries) do
			if e.job == "mayor" and e.station ~= nil then
				hx, hy = e.station.x, e.station.y
			end
		end
		local function ring(r, degrees)
			local a = math.rad(degrees)
			return hx + math.cos(a) * r, hy + math.sin(a) * r
		end
		local houses = {}
		local deeds = {"object/tangible/deed/player_house_deed/naboo_house_small_deed.iff",
			"object/tangible/deed/player_house_deed/naboo_house_medium_deed.iff",
			"object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff"}
		local n = 0
		for _, e in ipairs(entries) do
			if e.job ~= "mayor" then
				local x, y = ring(125, 130 + n * 28)
				n = n + 1
				table.insert(houses, {owner = firstOf(e.name), deed = deeds[n % 3 + 1], x = x, y = y, angle = n % 4})
			end
		end
		-- A spare lot for a human
		local sx, sy = ring(125, 50)
		table.insert(houses, {x = sx, y = sy, deed = deeds[1], angle = 0})
		local function deed(kind) return "object/tangible/deed/city_deed/" .. kind .. "_naboo_deed.iff" end
		local civic = {}
		local kinds = {
			{"object/tangible/deed/city_deed/garden_naboo_sml_01_deed.iff", 1}, {deed("bank"), 2}, {deed("garage"), 2},
			{deed("cantina"), 2}, {"object/tangible/deed/city_deed/garden_naboo_med_01_deed.iff", 2}, {deed("cloning"), 3},
			{deed("hospital"), 3}, {"object/tangible/deed/city_deed/garden_naboo_lrg_01_deed.iff", 3}, {deed("shuttleport"), 4},
			{deed("theater"), 4},
		}
		for i, k in ipairs(kinds) do
			local x, y = ring(85, 135 + (i - 1) * 30)
			table.insert(civic, {deed = k[1], x = x, y = y, rank = k[2]})
		end
		return {
			name = "Varenhal", planet = "naboo",
			cityHall = {x = hx, y = hy, angle = 0},
			houses = houses,
			civic = civic,
			decorations = {
				{template = "object/tangible/furniture/city/statue_naboo_01.iff", x = hx - 12, y = hy + 62},
				{template = "object/tangible/furniture/city/fountain_naboo_01.iff", x = hx + 12, y = hy + 62},
				{template = "object/tangible/furniture/city/streetlamp_large_01.iff", x = hx - 22, y = hy + 70},
				{template = "object/tangible/furniture/city/streetlamp_large_01.iff", x = hx + 22, y = hy + 70},
			},
			taxes = {property = 5, travel = 20},
			specialization = "Entertainment District",
		}
	end

	local function cityEntriesOf(roster)
		local out = {}
		for _, e in ipairs(roster ~= nil and roster.bots or {}) do
			if e.city == "varenhal" then
				table.insert(out, e)
			end
		end
		return out
	end

	-- The roster and plan for the city scenarios: the real ones if they have the city, else test ones
	local function cityData()
		local roster, rosterFrom = BotRoster, "custom_scripts/bots/roster.lua"
		if #cityEntriesOf(roster) == 0 then
			rosterFrom = "test city bots"
			roster = {settings = (BotRoster or {}).settings or {}, bots = {}}
			for _, e in ipairs((BotRoster or {}).bots or {}) do
				table.insert(roster.bots, e)
			end
			for i, t in ipairs(testBots) do
				table.insert(roster.bots, {name = t.name, job = t.job, role = t.role, city = "varenhal", online = "planet",
					species = "human", sex = i % 2 == 0 and "female" or "male",
					station = {planet = "naboo", x = 1000 + (i - 5) * 3, z = 5, y = 955 - (t.job == "mayor" and 0 or 5), cell = 0}})
			end
		end
		local plan, planFrom = BotCityPlan, "custom_scripts/bots/city.lua"
		if plan == nil then
			plan, planFrom = testPlan(cityEntriesOf(roster)), "a test plan"
		end
		return roster, rosterFrom, plan, planFrom
	end

	-- Mock structures

	local function deedInfo(deed)
		local size = deed:match("player_house_deed/naboo_house_(%a+)")
		if size ~= nil then
			local style = deed:find("style_02", 1, true) and "_style_01" or (size == "small" and "_style_02" or "_style_01")
			local template = "object/building/player/player_house_naboo_" .. size .. style .. ".iff"
			local cells = {small_style_01 = {"foyer", "room1", "room2"}, small_style_02 = {"foyer", "hall", "room1", "room2"},
				medium_style_01 = {"foyerdown", "mainchamber"}, large_style_01 = {"mainfoyer"}}
			return {house = true, kind = "house", template = template, cells = cells[size .. style] or {}}
		end
		local garden = deed:match("garden_naboo_(%a%a%a)_%d+")
		if garden ~= nil then
			return {kind = "garden_" .. garden, template = (deed:gsub("tangible/deed/city_deed", "building/player/city"):gsub("_deed%.iff$", ".iff")), cells = {}}
		end
		local kind = deed:match("city_deed/(%a+)_naboo_deed")
		if kind ~= nil then
			local template = kind == "garage" and "object/building/player/player_garage_naboo_style_01.iff" or
				("object/building/player/city/" .. kind .. "_naboo.iff")
			return {kind = kind, template = template, cells = CELLS[kind] or {}}
		end
		return nil
	end

	local function makeStructure(template, kind, x, y, owner, cells)
		local s = ctx.newObject({isStructure = true, template = template, kind = kind, planet = "naboo", x = x, y = y, z = 5,
			cell = 0, inWorld = true, owner = owner, cellsByName = {}})
		for _, name in ipairs(cells or {}) do
			s.cellsByName[name] = ctx.newObject({isCell = true, building = s, cellName = name, planet = "naboo", x = 0, y = 0,
				z = 0, cell = 0, inWorld = true})
		end
		table.insert(W.structures, s)
		W.placedAt[string.format("%d:%d", math.floor(x + 0.5), math.floor(y + 0.5))] =
			(W.placedAt[string.format("%d:%d", math.floor(x + 0.5), math.floor(y + 0.5))] or 0) + 1
		return s
	end

	local function inCity(x, y)
		local c = W.city
		return c ~= nil and flat(x, y, c.hall.x, c.hall.y) <= RADIUS[c.rank]
	end

	local function count(set)
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		return n
	end

	local function botOf(p)
		return p ~= nil and p.isBotFlag and p or nil
	end

	-- Core3's /placestructure as far as the city depends on it
	local function placeStructure(bot, args)
		local deedOid, x, y, angle = args:match("^(%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%d)$")
		if deedOid == nil then
			return false, "bad arguments " .. args
		end
		deedOid, x, y = tonumber(deedOid), tonumber(x), tonumber(y)
		if (bot.cell or 0) ~= 0 then
			return false, "inside a building"
		end
		if bot.dancing ~= nil or bot.playing ~= nil or bot.music ~= nil then
			return false, "performing"
		end
		local bx, by = bot:worldXY()
		if flat(bx, by, x, y) > 100 then
			return false, string.format("%.0f m away", flat(bx, by, x, y))
		end
		local deed, index = nil, nil
		for i, item in ipairs(bot.inv.items) do
			if item.oid == deedOid then
				deed, index = item, i
			end
		end
		if deed == nil then
			return false, "deed not in the inventory"
		end
		local info = deedInfo(deed.template)
		if info == nil then
			return false, "not a structure deed: " .. deed.template
		end
		local c = W.city
		if info.house then
			if inCity(x, y) and c.zoning and c.mayor ~= bot.oid then
				return false, "zoning"
			end
		else
			if c == nil or not inCity(x, y) then
				return false, "not in a city"
			end
			if c.rank < (RANK_OF[info.kind] or 1) then
				return false, "rank " .. c.rank .. " < " .. (RANK_OF[info.kind] or 1)
			end
			local skills = COMMERCIAL[info.kind]
			if skills ~= nil then
				local ok = false
				for _, job in ipairs(skills) do
					ok = ok or bot.job == job
				end
				if not ok then
					return false, "no place_" .. info.kind .. " ability"
				end
				if c.zoning and c.mayor ~= bot.oid then
					return false, "zoning"
				end
			elseif c.mayor ~= bot.oid then
				return false, "civic, not the mayor"
			end
			if UNIQUE[info.kind] then
				for _, s in ipairs(W.structures) do
					if s.kind == info.kind and s.inWorld then
						return false, "unique"
					end
				end
			end
		end
		for _, s in ipairs(W.structures) do
			if s.inWorld and flat(s.x, s.y, x, y) < 14 then
				return false, "no room"
			end
		end
		table.remove(bot.inv.items, index)
		local ms = info.house and 6000 or 300
		sim.schedule(ms, function()
			local s = makeStructure(info.template, info.kind, x, y, bot.oid, info.cells)
			s.angle = tonumber(angle)
			s.class = info.house and "house" or (COMMERCIAL[info.kind] ~= nil and "commercial" or "civic")
			if not info.house then
				table.insert(c.structures, s)
			end
			if W.watching[bot.oid] ~= nil then
				-- botPlaceStructure's watcher
				W.watching[bot.oid] = nil
				sim.call("BotJobs", "onEvent", bot, "placed", s, s.template)
			end
		end)
		return true
	end

	local function runCommand(bot, command, target, args)
		if command == "placestructure" then
			return placeStructure(bot, args)
		elseif command == "startdance" then
			if bot.dancing ~= nil then return false, "already dancing" end
			bot.dancing = args
		elseif command == "changedance" then
			if bot.dancing == nil then return false, "not dancing" end
			bot.dancing = args
		elseif command == "stopdance" then
			bot.dancing = nil
		elseif command == "startmusic" then
			if bot.holdR == nil then return false, "no instrument" end
			bot.playing = args ~= "" and args or "starwars1"
			bot.music = bot.playing
		elseif command == "changemusic" then
			bot.playing, bot.music = args, args
		elseif command == "stopmusic" then
			bot.playing, bot.music = nil, nil
		elseif command == "sitserver" then
			bot.posture = "sitting"
		elseif command == "stand" then
			bot.posture = "upright"
		end
		return true
	end

	-- The mock API

	local function install(roster, plan)
		saved = {}
		for _, name in ipairs(overridden) do
			saved[name] = _G[name]
		end
		-- Creature methods other parts' mocks also define (bots_jobsA_sim.lua: hold_r, music): both kinds
		saved.getSlottedObject, saved.isPlayingMusic = Obj.getSlottedObject, Obj.isPlayingMusic
		function Obj:getSlottedObject(slot)
			if slot == "inventory" then
				return self.inv
			elseif slot == "hold_r" then
				return self.holdR
			end
			return nil
		end
		function Obj:isPlayingMusic() return self.playing ~= nil or self.music ~= nil end
		BotRoster, BotCityPlan = roster, plan
		BotCityJobs:resetPlan()

		-- Every key the jobs write, so a "restart" can wipe shared memory
		local realWrite, realWriteStr = saved.writeData, saved.writeStringData
		W.keys, W.strKeys = {}, {}
		writeData = function(k, v) W.keys[k] = true; return realWrite(k, v) end
		writeStringData = function(k, v) W.strKeys[k] = true; return realWriteStr(k, v) end

		function botList()
			local out = {}
			for _, e in ipairs(BotRoster.bots) do
				local b = W.bots[firstOf(e.name):lower()]
				table.insert(out, {name = e.name, firstName = firstOf(e.name), job = e.job, city = e.city, oid = b and b.oid or 0,
					online = b ~= nil and b.online == true, state = b ~= nil and b.online and "online" or "offline", forced = false})
			end
			return out
		end
		function botGetCreature(first)
			local b = W.bots[tostring(first):lower()]
			return b ~= nil and b.online and b or nil
		end
		function isBot(p) return p ~= nil and p.isBotFlag == true end
		function botSetDevHuman(on) end
		function botEnqueue(bot, command, target, args)
			assert(type(command) == "string" and command == command:lower(), "botEnqueue: command must be a lowercase name")
			assert(math.type(target) == "integer", "botEnqueue: target must be an integer oid, got " .. tostring(target))
			assert(type(args) == "string", "botEnqueue: args must be a string")
			if botOf(bot) == nil or not bot.online then
				return false
			end
			local ok, why = runCommand(bot, command, target, args)
			table.insert(W.commands, {bot = bot.oid, t = nowMs(), cmd = command, target = target, args = args, ok = ok, why = why})
			return true
		end
		function botSay(bot, text, mood)
			assert(type(text) == "string" and #text > 0 and not text:find("[%c]"), "botSay: bad line " .. tostring(text))
			assert(not text:find("{%a+}"), "unfilled placeholder: " .. text)
			assert(type(mood) == "string", "botSay: mood must be a string")
			table.insert(W.says, {bot = bot.oid, t = nowMs(), text = text})
		end
		function botTell(bot, to, text)
			assert(not tostring(text):find("{%a+}"), "unfilled placeholder: " .. tostring(text))
			return true
		end
		function botEmote(bot, emote, target)
			assert(type(emote) == "string" and emote ~= "", "botEmote: no emote")
			assert(math.type(target) == "integer", "botEmote: target must be an integer oid")
			table.insert(W.emotes, {bot = bot.oid, t = nowMs(), emote = emote, target = target})
		end
		function botFace(bot, target) assert(target ~= nil, "botFace: no target") end
		function botStockPack(bot, template, uses, power, duration) return true end
		function botGetWounds(p, pool) return 0 end
		function botGetShockWounds(p) return 0 end
		function botGetBuffs(p) return {} end

		function giveItem(pContainer, template, slot)
			assert(pContainer ~= nil and pContainer.isInventory, "giveItem: not an inventory")
			assert(type(template) == "string" and template:match("^object/.+%.iff$"), "giveItem: bad template " .. tostring(template))
			local item = ctx.newObject({template = template, planet = "", x = 0, y = 0, z = 0, cell = 0, inWorld = false})
			table.insert(pContainer.items, item)
			W.deedsGiven = W.deedsGiven + 1
			return item
		end
		function getContainerObjectByTemplate(pContainer, template, recursive)
			for _, item in ipairs(pContainer ~= nil and pContainer.items or {}) do
				if item.template == template then
					return item
				end
			end
			return nil
		end

		-- The mover: a walk takes distance / 1.4 m/s outdoors, 25 s into or out of a building; "arrived" at the end
		-- (or "stuck", W.stuckChance of the time)
		function botMoveTo(bot, x, z, y, cell, pace)
			assert(type(x) == "number" and type(z) == "number" and type(y) == "number", "botMoveTo: bad point")
			assert(pace == nil or pace == "walk" or pace == "run", "botMoveTo: bad pace " .. tostring(pace))
			assert(math.type(cell) == "integer" or cell == math.floor(cell), "botMoveTo: bad cell")
			if botOf(bot) == nil or not bot.online then
				return false
			end
			bot.moveId = (bot.moveId or 0) + 1
			local id = bot.moveId
			local bx, by = bot:worldXY()
			local ms = 25000
			if (cell or 0) == 0 and (bot.cell or 0) == 0 then
				ms = math.floor(flat(bx, by, x, y) / 1.4 * 1000) + 500
			end
			W.walks = W.walks + 1
			local stuck = math.random() < (W.stuckChance or 0)
			sim.schedule(stuck and math.floor(ms / 2) or ms, function()
				if bot.moveId ~= id or not bot.online then
					return
				end
				bot.moveId = bot.moveId + 1
				if stuck then
					W.stucks = W.stucks + 1
					sim.call("BotJobs", "onEvent", bot, "stuck", nil, "")
					return
				end
				bot.x, bot.z, bot.y, bot.cell = x, z, y, cell
				sim.call("BotJobs", "onEvent", bot, "arrived", nil, "")
			end)
			return true
		end
		function botStop(bot) bot.moveId = (bot.moveId or 0) + 1 end
		function botMoveState(bot) return {state = "idle", leader = 0, distance = 0, stuck = false} end

		-- The city
		function botCheckSite(planet, x, y, radius) return {ok = true, reasons = {}, heightDiff = 1.5} end
		function botFoundCity(pMayor, x, y, angle, name)
			W.foundCalls = W.foundCalls + 1
			if W.city ~= nil then
				return W.city.name == name and W.city.id or 0
			end
			if botOf(pMayor) == nil or pMayor.job ~= "mayor" then
				return 0
			end
			W.city = {id = 4242, name = name, rank = 1, treasury = 0, zoning = true, registered = false, spec = "",
				mayor = pMayor.oid, citizens = {[pMayor.oid] = true}, structures = {}, decorations = {}, candidates = {},
				voters = {}, updates = 0, taxes = {}, locked = false}
			local hall = makeStructure("object/building/player/city/cityhall_naboo.iff", "cityhall", x, y, pMayor.oid, CELLS.cityhall)
			W.city.hall = hall
			hall.class = "cityhall"
			table.insert(W.city.structures, hall)
			-- Core3 makes the mayor a citizen, resident in the hall
			pMayor.residence = hall.oid
			W.cities = W.cities + 1
			return W.city.id
		end
		function botCityInfo(name)
			local c = W.city
			if c == nil or c.name ~= name then
				return W.emptyInfo
			end
			-- As BotCityLua's pushCityInfo: the civic and commercial buildings, then the decorations, in one list
			local structures = {}
			for _, s in ipairs(c.structures) do
				if s.inWorld then
					table.insert(structures, {oid = s.oid, template = s.template, name = s.kind, kind = s.class or "civic", x = s.x,
						y = s.y, city = c.name, residence = false})
				end
			end
			for _, d in ipairs(c.decorations) do
				table.insert(structures, {oid = d.oid, template = d.template, name = "", kind = "decoration", x = d.x, y = d.y,
					city = c.name, residence = false})
			end
			local candidates = {}
			for oid in pairs(c.candidates) do
				local votes = 0
				for _, voted in pairs(c.voters) do
					if voted == oid then votes = votes + 1 end
				end
				local p = ctx.objects[oid]
				table.insert(candidates, {oid = oid, name = p ~= nil and p.first or "?", votes = votes, incumbent = oid == c.mayor,
					bot = isBot(p)})
			end
			table.sort(candidates, function(a, b) return a.oid < b.oid end)
			local citizenList = {}
			for oid in pairs(c.citizens) do
				local p = ctx.objects[oid]
				table.insert(citizenList, {oid = oid, name = p ~= nil and p.first or "?", bot = isBot(p)})
			end
			local spec = c.spec
			local taxes = {income = c.taxes[0] or 0, property = c.taxes[1] or 0, sales = c.taxes[2] or 0, travel = c.taxes[3] or 0,
				garage = c.taxes[4] or 0}
			return {id = c.id, name = c.name, planet = "naboo", x = c.hall.x, y = c.hall.y, rank = c.rank, radius = RADIUS[c.rank],
				citizens = count(c.citizens), citizensToKeep = CITIZENS[c.rank], citizensForNextRank = CITIZENS[c.rank + 1] or 0,
				mayor = c.mayor, mayorName = ctx.objects[c.mayor] and ctx.objects[c.mayor].name or "", mayorIsBot = isBot(ctx.objects[c.mayor]),
				treasury = c.treasury, upkeep = weeklyUpkeep(), nextUpdate = 604800, nextUpdateText = "7 days",
				specialization = spec, spec = spec:match("city_spec_([%w_]+)") or "", registered = c.registered, zoning = c.zoning,
				taxes = taxes, decorations = #c.decorations, maxDecorations = 10 * c.rank, cityHall = c.hall.oid,
				citizenList = citizenList, election = {locked = c.locked, seconds = 1814400, candidates = candidates},
				structures = structures}
		end
		function botDeclareResidence(pBot, structureOid)
			local s = ctx.objects[structureOid]
			W.declares = W.declares + 1
			if botOf(pBot) == nil or s == nil or not s.isStructure or s.owner ~= pBot.oid then
				return false
			end
			if pBot.residence == structureOid then
				return true
			end
			if W.city ~= nil and W.city.mayor == pBot.oid then
				fail(W.label .. ": the mayor tried to move its residence out of the city hall")
				return false
			end
			pBot.residence = structureOid
			if W.city ~= nil and inCity(s.x, s.y) then
				W.city.citizens[pBot.oid] = true
			end
			return true
		end
		function botOwnedStructures(pBot)
			local out = {}
			for _, s in ipairs(W.structures) do
				if s.inWorld and pBot ~= nil and s.owner == pBot.oid then
					table.insert(out, {oid = s.oid, template = s.template, name = s.kind, kind = s.class or "house", x = s.x, y = s.y,
						city = (W.city ~= nil and inCity(s.x, s.y)) and W.city.name or "", residence = pBot.residence == s.oid})
				end
			end
			return out
		end
		function botCityDeposit(name, credits, pFrom)
			assert(math.type(credits) == "integer" or credits == math.floor(credits), "botCityDeposit: whole credits")
			if W.city == nil or W.city.name ~= name or credits <= 0 then
				return false
			end
			if pFrom ~= nil and (pFrom.cash or 0) + (pFrom.bank or 0) < credits then
				return false
			end
			-- Queued, as the C++ does: paid from the payer's cash, then its bank
			sim.schedule(50, function()
				if pFrom ~= nil then
					local cash = math.min(credits, pFrom.cash or 0)
					pFrom.cash = (pFrom.cash or 0) - cash
					pFrom.bank = pFrom.bank - (credits - cash)
					assert(pFrom.bank >= 0, "botCityDeposit: the payer's bank went negative")
				end
				W.city.treasury = W.city.treasury + credits
			end)
			W.deposits = W.deposits + 1
			W.deposited = W.deposited + credits
			return true
		end
		-- The real /placestructure after BotCity's own checks, and its watcher's events
		function botPlaceStructure(pBot, deedOid, x, y, angle)
			assert(math.type(angle) == "integer" and angle >= 0 and angle <= 3, "botPlaceStructure: angle " .. tostring(angle))
			if botOf(pBot) == nil or not pBot.online then
				return false
			end
			local args = string.format("%.0f %.1f %.1f %d", deedOid, x, y, angle)
			local ok, why = placeStructure(pBot, args)
			table.insert(W.commands, {bot = pBot.oid, t = nowMs(), cmd = "placestructure", target = 0, args = args, ok = ok, why = why})
			if ok then
				W.watching[pBot.oid] = true
			end
			return ok
		end
		if W.noPlaceBinding then
			botPlaceStructure = nil
		end
		function botCitySetTax(name, index, value)
			assert(math.type(index) == "integer" and index >= 0 and index <= 4, "botCitySetTax: index " .. tostring(index))
			if W.city == nil then return false end
			W.city.taxes[index] = value
			return true
		end
		function botCitySetSpec(name, spec)
			assert(type(spec) == "string" and spec:match("^@city/city:city_spec_[%w_]+$"), "botCitySetSpec: " .. tostring(spec))
			if W.city == nil or W.city.rank < 3 then return false end
			W.city.spec = spec
			return true
		end
		function botCityZoning(name, on)
			if W.city == nil then return false end
			W.city.zoning = on == true
			return true
		end
		function botCityRegister(name)
			if W.city == nil or W.city.rank < 3 then return false end
			W.city.registered = true
			return true
		end
		function botCityCandidate(pBot, name)
			local c = W.city
			if c == nil or not c.citizens[pBot.oid] or c.locked or c.candidates[pBot.oid] ~= nil then
				return false
			end
			c.candidates[pBot.oid] = true
			W.candidacies = W.candidacies + 1
			return true
		end
		function botCityVote(pBot, name, candidateOid)
			local c = W.city
			if c == nil or not c.citizens[pBot.oid] or c.candidates[candidateOid] == nil then
				return false
			end
			c.voters[pBot.oid] = candidateOid
			return true
		end
		function botCityExpand(name)
			if W.city == nil or W.city.rank >= 5 then return false end
			W.city.rank = W.city.rank + 1
			return true
		end
		function botPlaceDecoration(pMayor, template)
			local c = W.city
			if c == nil or c.mayor ~= pMayor.oid or c.treasury < 1000 or (pMayor.cell or 0) ~= 0 then
				return 0
			end
			local x, y = pMayor:worldXY()
			local d = ctx.newObject({isDecoration = true, template = template, planet = "naboo", x = x, y = y, z = 5, cell = 0,
				inWorld = true})
			table.insert(c.decorations, d)
			return d.oid
		end
	end

	local function uninstall()
		for _, name in ipairs(overridden) do
			_G[name] = saved[name]
		end
		Obj.getSlottedObject, Obj.isPlayingMusic = saved.getSlottedObject, saved.isPlayingMusic
		BotCityJobs:resetPlan()
	end

	-- The weekly update (CityManager::processCityUpdate as the city depends on it): rank by citizens, upkeep from the
	-- treasury, and every third update the election
	local function cityUpdate()
		local c = W.city
		c.updates = c.updates + 1
		local citizens = count(c.citizens)
		if c.rank < 5 and citizens >= CITIZENS[c.rank + 1] then
			c.rank = c.rank + 1
		elseif citizens < CITIZENS[c.rank] then
			fail(W.label .. ": the city contracted, " .. citizens .. " citizens at rank " .. c.rank)
			c.rank = math.max(1, c.rank - 1)
		end
		local cost = 35000 + 25000 * (c.rank - 1)
		for _, s in ipairs(c.structures) do
			cost = cost + (UPKEEP[s.kind] or 0)
		end
		cost = cost + 1500 * #c.decorations + (c.registered and 5000 or 0) + (c.spec ~= "" and 80000 or 0)
		c.treasury = c.treasury - cost
		W.upkeepPaid = W.upkeepPaid + cost
		if c.treasury < 0 then
			fail(string.format("%s: update %d couldn't pay %d upkeep (treasury %d)", W.label, c.updates, cost, c.treasury + cost))
			c.treasury = 0
		end
		if c.updates % 3 == 0 then
			local top, topVotes = c.mayor, 0
			for oid in pairs(c.candidates) do
				local votes = 0
				for voter, voted in pairs(c.voters) do
					if voted == oid and c.citizens[voter] then votes = votes + 1 end
				end
				if c.citizens[oid] and (votes > topVotes or (votes == topVotes and oid == c.mayor)) then
					top, topVotes = oid, votes
				end
			end
			W.elections = W.elections + 1
			c.mayor = top
			c.candidates, c.voters = {}, {}
		end
		c.locked = c.updates % 3 == 2
	end

	-- The city's bots, at their stations, offline
	local function makeBots()
		W.bots = {}
		for _, e in ipairs(BotRoster.bots) do
			if e.city == "varenhal" then
				local s = e.station or {x = 1000, y = 950, z = 5}
				local inv = ctx.newObject({isInventory = true, items = {}, planet = "", x = 0, y = 0, z = 0, cell = 0, inWorld = false})
				local b = ctx.newObject({isBotFlag = true, isPlayer = true, first = firstOf(e.name), last = e.name:match("%S+$"),
					name = e.name, job = e.job, planet = "naboo", x = s.x, y = s.y, z = s.z or 5, cell = 0, inWorld = false,
					online = false, cash = 0, bank = 0, inv = inv, buffs = {}, station = s})
				for _, item in ipairs(e.outfit or {}) do
					if item:find("instrument", 1, true) or item:find("/weapon/", 1, true) then
						b.holdR = ctx.newObject({template = item, planet = "", x = 0, y = 0, z = 0, cell = 0, inWorld = false})
					end
				end
				W.bots[firstOf(e.name):lower()] = b
				ctx.addPlayer(b)
			end
		end
	end

	-- Log in like the C++ body: at the station, scene-ready, then the event
	local function login(b)
		b.online, b.inWorld = true, true
		b.x, b.y, b.z, b.cell = b.station.x, b.station.y, b.station.z or 5, 0
		b.dancing, b.playing, b.music, b.moveId = nil, nil, nil, (b.moveId or 0) + 1
		sim.call("BotJobs", "onLogin", b)
	end

	local function logout(b)
		if not b.online then return end
		sim.call("BotJobs", "onLogout", b)
		b.online, b.inWorld, b.dancing, b.playing, b.music = false, false, nil, nil, nil
		b.moveId = (b.moveId or 0) + 1
	end

	local function loginAll()
		for _, b in pairs(W.bots) do login(b) end
	end

	local function logoutAll()
		for _, b in pairs(W.bots) do logout(b) end
	end

	local function botWithJob(job)
		for _, b in pairs(W.bots) do
			if b.job == job then return b end
		end
		return nil
	end

	local function setup(label)
		W = {label = label, structures = {}, placedAt = {}, commands = {}, says = {}, emotes = {}, foundCalls = 0, cities = 0,
			watching = {}, noPlaceBinding = label == "cityroutine",
			declares = 0, deposits = 0, deposited = 0, deedsGiven = 0, walks = 0, stucks = 0, candidacies = 0, elections = 0,
			upkeepPaid = 0, stuckChance = 0, emptyInfo = nil}
		local roster, rosterFrom, plan, planFrom = cityData()
		install(roster, plan)
		W.rosterFrom, W.planFrom = rosterFrom, planFrom
		saved.talkDir, saved.chatterEvery = LivingTalk.dir, LivingCities.chatterEvery
		LivingTalk.dir = "/nonexistent/sim-talk"
		ctx.setHour(14)
		makeBots()
		-- A human on Naboo, far from the city, so the bots' greetings don't fire
		W.human = ctx.newObject({isPlayer = true, first = "Cameren", planet = "naboo", x = -4000, y = 4000, z = 5, cell = 0,
			inWorld = true, inv = {items = {}}})
		ctx.addPlayer(W.human)
		return plan
	end

	local function teardown()
		logoutAll()
		sim.run(5)
		LivingTalk.dir = saved.talkDir
		uninstall()
	end

	-- Checks

	local function failedCommands(since)
		local out = {}
		for _, c in ipairs(W.commands) do
			if not c.ok and c.t >= (since or 0) then
				table.insert(out, ctx.objects[c.bot].first .. " " .. c.cmd .. " " .. c.args .. ": " .. tostring(c.why))
			end
		end
		return out
	end

	local function structureAt(x, y)
		for _, s in ipairs(W.structures) do
			if s.inWorld and flat(s.x, s.y, x, y) <= 10 then
				return s
			end
		end
		return nil
	end

	local function checkNoDuplicates(label)
		for k, n in pairs(W.placedAt) do
			if n > 1 then
				fail(label .. ": " .. n .. " structures placed at " .. k)
			end
		end
		if W.cities > 1 then
			fail(label .. ": " .. W.cities .. " cities founded")
		end
		for _, b in pairs(W.bots) do
			local seen = {}
			for _, item in ipairs(b.inv.items) do
				seen[item.template] = (seen[item.template] or 0) + 1
				if seen[item.template] > 1 then
					fail(label .. ": " .. b.first .. " holds " .. seen[item.template] .. " of " .. item.template)
				end
			end
		end
	end

	-- Every house up and its owner a citizen; the mayor a citizen
	local function checkHouses(label, plan)
		local p = BotCityJobs:plan()
		for _, lot in ipairs(p.houses) do
			local b = W.bots[lot.owner]
			local s = structureAt(lot.x, lot.y)
			if b ~= nil then
				if s == nil or s.owner ~= b.oid then
					fail(label .. ": " .. b.first .. "'s house isn't on its lot")
				end
				if b.job ~= "mayor" and not W.city.citizens[b.oid] then
					fail(label .. ": " .. b.first .. " isn't a citizen")
				end
			end
		end
		local mayor = botWithJob("mayor")
		if mayor ~= nil and not W.city.citizens[mayor.oid] then
			fail(label .. ": the mayor isn't a citizen")
		end
	end

	local function checkRankBuildings(label, rank)
		for _, item in ipairs(BotCityJobs:plan().civic) do
			if item.rank <= rank then
				local s = structureAt(item.x, item.y)
				if s == nil then
					fail(label .. ": no " .. item.kind .. " at rank " .. rank)
				elseif s.kind ~= item.kind then
					fail(label .. ": a " .. tostring(s.kind) .. " where the " .. item.kind .. " should be")
				else
					local placer = item.by == "mayor" and botWithJob("mayor") or botWithJob(item.by)
					if placer ~= nil and s.owner ~= placer.oid then
						fail(label .. ": the " .. item.kind .. " was placed by " .. tostring(ctx.objects[s.owner] and ctx.objects[s.owner].first) ..
							", not the " .. item.by)
					end
				end
			elseif structureAt(item.x, item.y) ~= nil then
				fail(label .. ": the " .. item.kind .. " (rank " .. item.rank .. ") is up at rank " .. rank)
			end
		end
	end

	weeklyUpkeep = function()
		local c = W.city
		local cost = 35000 + 25000 * (c.rank - 1)
		for _, s in ipairs(c.structures) do cost = cost + (UPKEEP[s.kind] or 0) end
		return cost + 1500 * #c.decorations + (c.registered and 5000 or 0) + (c.spec ~= "" and 80000 or 0)
	end

	-- The workers inside their buildings: the dancer dancing in the cantina, the musician there, the doctor in the
	-- hospital
	local function checkWorkers(label)
		local plan = BotCityJobs:plan()
		for job, kind in pairs(BotCityJobs.workplaces) do
			local b = botWithJob(job)
			local item = BotCityJobs:civicOfKind(kind)
			local s = item ~= nil and structureAt(item.x, item.y) or nil
			if b ~= nil and s ~= nil then
				local cell = s.cellsByName[plan.interiors[kind].cell]
				if cell == nil or b.cell ~= cell.oid then
					fail(label .. ": the " .. job .. " isn't inside the " .. kind .. " (cell " .. tostring(b.cell) .. ")")
				end
				if BotCityJobs:held(b.oid) then
					fail(label .. ": the " .. job .. "'s job is still held: " .. readStringData("bot:" .. b.oid .. ":cityHoldWhy"))
				end
			end
		end
		local dancer = botWithJob("dancer")
		if dancer ~= nil and dancer.dancing == nil then
			fail(label .. ": the city's dancer isn't dancing")
		end
	end

	local function checkNoFalseThanks(label)
		for _, e in ipairs(W.emotes) do
			if e.emote == "thank" then
				fail(label .. ": " .. ctx.objects[e.bot].first .. " thanked for a tip nobody gave (credits it was given)")
				return
			end
		end
	end

	local function report(label)
		local c = W.city
		local placed = 0
		for _ in pairs(W.placedAt) do placed = placed + 1 end
		realPrint(string.format("%-12s rank %d, %d citizens, treasury %d (upkeep %d a week), %d structures, %d decorations, %d deposits (%d), %d walks (%d stuck), %d lines",
			label, c and c.rank or 0, c and count(c.citizens) or 0, c and c.treasury or 0, c and weeklyUpkeep() or 0, placed,
			c and #c.decorations or 0, W.deposits, W.deposited, W.walks, W.stucks, #W.says))
	end

	-- Scenario: founding and a dev fast-forward to rank 5

	function scenarios.city()
		local plan = setup("city")
		realPrint("city         roster: " .. W.rosterFrom .. "; plan: " .. W.planFrom)
		for _, p in ipairs(BotCityJobs:plan().problems) do
			fail("city: plan problem: " .. p)
		end
		if #BotCityJobs:cityEntries() ~= 10 then
			fail("city: " .. #BotCityJobs:cityEntries() .. " city bots in the roster, expected 10")
		end

		loginAll()
		sim.run(600)
		local c = W.city
		if c == nil then
			fail("city: not founded after 10 minutes")
			teardown()
			return
		end
		if c.zoning then
			fail("city: zoning still on")
		end
		local taxes = 0
		for _ in pairs(c.taxes) do taxes = taxes + 1 end
		if taxes ~= #BotCityJobs:plan().taxes then
			fail("city: " .. taxes .. " taxes set, the plan has " .. #BotCityJobs:plan().taxes)
		end
		checkHouses("city day 0", plan)
		checkRankBuildings("city day 0", 1)
		if count(c.citizens) ~= 10 then
			fail("city: " .. count(c.citizens) .. " citizens on day 0, expected 10")
		end
		local mayor = botWithJob("mayor")
		local mayorBank = mayor.bank
		for _, b in pairs(W.bots) do
			if b.job ~= "mayor" and b.bank < BotCityJobs.bankFloor then
				fail("city: " .. b.first .. " has only " .. b.bank .. " in the bank (no seed credits)")
			end
		end
		if c.treasury < weeklyUpkeep() * BotCityJobs.treasuryWeeks then
			fail("city: treasury " .. c.treasury .. " on day 0, under two weeks of upkeep")
		end

		-- The dev fast-forward, from the console
		BotCityJobs:toRank("5")
		sim.run(3 * 3600)
		if c.rank ~= 5 then
			fail("city: rank " .. c.rank .. " after the fast-forward")
		end
		checkRankBuildings("city rank 5", 5)
		if #c.decorations ~= #BotCityJobs:plan().decorations then
			fail("city: " .. #c.decorations .. " decorations of " .. #BotCityJobs:plan().decorations)
		end
		for i, item in ipairs(BotCityJobs:plan().decorations) do
			local found = false
			for _, d in ipairs(c.decorations) do
				if flat(d.x, d.y, item.x, item.y) <= 3 then found = true end
			end
			if not found then
				fail("city: decoration " .. i .. " isn't at its spot")
			end
		end
		if BotCityJobs:plan().spec ~= nil and c.spec ~= BotCityJobs:plan().spec then
			fail("city: specialization " .. tostring(c.spec))
		end
		if not c.registered then
			fail("city: not registered on the map")
		end
		if c.treasury < weeklyUpkeep() * BotCityJobs.treasuryWeeks then
			fail("city: treasury " .. c.treasury .. " under two weeks of upkeep (" .. weeklyUpkeep() .. " a week)")
		end
		if readData("botcity:toRank") ~= 0 or readData("botcity:fast") ~= 0 then
			fail("city: the fast-forward didn't finish")
		end
		checkWorkers("city")
		checkNoDuplicates("city")
		checkNoFalseThanks("city")
		local fails = failedCommands(0)
		if #fails > 0 then
			fail("city: refused commands: " .. table.concat(fails, "; "))
		end
		if W.walks == 0 then
			fail("city: nobody walked")
		end
		-- The mayor is back on the square in front of the city hall
		local mx, my = mayor:worldXY()
		local spot = BotCityJobs:plan().mayorSpot
		if flat(mx, my, spot.x, spot.y) > 5 then
			fail(string.format("city: the mayor is %.0f m from its spot in front of the city hall", flat(mx, my, spot.x, spot.y)))
		end
		-- And the brain's summary knows the city
		local summary = BotCityJobs:summary()
		if not summary:find("rank 5", 1, true) or not summary:find("Varenhal", 1, true) or not summary:find("shuttleport", 1, true) then
			fail("city: the brain's city summary: " .. summary)
		end
		-- Each city bot's extra request fields for the brain (BotJobs:ask merges module:requestFields)
		local places = {cantina = true, hospital = true, cityhall = true, home = true, street = true, bank = true, garden = true}
		for _, b in pairs(W.bots) do
			local module = BotJobs:module(BotJobs:job(b.oid))
			local fields = module ~= nil and module.requestFields ~= nil and module:requestFields(b, b.oid) or {}
			if fields.cityInfo ~= summary or fields.cityName ~= "Varenhal" or not places[fields.place or ""] then
				fail("city: " .. b.first .. "'s request fields: " .. tostring(fields.cityName) .. ", " .. tostring(fields.place))
			end
			if b.job == "citizen" and (fields.role or "") == "" then
				fail("city: " .. b.first .. " has no trade for the brain")
			end
		end
		-- The status prints without errors
		BotCityJobs:status()
		BotCityJobs:showPlan()
		BotJobs:list()
		report("city")
		realPrint("             " .. summary)
		teardown()
	end

	-- Scenario: real weekly updates, the bots online a couple of hours each week

	function scenarios.cityweeks()
		setup("cityweeks")
		local ranks = {}
		for week = 0, 5 do
			loginAll()
			sim.run(2 * 3600)
			logoutAll()
			sim.run(60)
			local c = W.city
			if c == nil then
				fail("cityweeks: not founded")
				break
			end
			checkRankBuildings("cityweeks week " .. week, c.rank)
			if c.treasury < weeklyUpkeep() * BotCityJobs.treasuryWeeks then
				fail("cityweeks week " .. week .. ": treasury " .. c.treasury .. " under two weeks of upkeep")
			end
			table.insert(ranks, c.rank)
			-- A week goes by with nobody on Naboo, then the update
			sim.now = sim.now + 7 * 86400 - 2 * 3600 - 60
			cityUpdate()
		end
		local c = W.city
		if c ~= nil then
			if table.concat(ranks, ",") ~= "1,2,3,4,5,5" then
				fail("cityweeks: ranks by week " .. table.concat(ranks, ","))
			end
			if c.mayor ~= botWithJob("mayor").oid then
				fail("cityweeks: the bot mayor lost an election nobody else ran in")
			end
			if W.elections < 2 then
				fail("cityweeks: " .. W.elections .. " elections in six updates")
			end
			checkHouses("cityweeks", nil)
			checkNoDuplicates("cityweeks")
			checkNoFalseThanks("cityweeks")
			local fails = failedCommands(0)
			if #fails > 0 then
				fail("cityweeks: refused commands: " .. table.concat(fails, "; "))
			end
			report("cityweeks")
			realPrint(string.format("             ranks by week %s, %d elections, upkeep paid %d", table.concat(ranks, ","), W.elections, W.upkeepPaid))
		end
		teardown()
	end

	-- Scenario: an election with a human candidate

	function scenarios.cityelection()
		setup("cityelection")
		local mayor = botWithJob("mayor")
		loginAll()
		sim.run(900)
		local c = W.city
		if c == nil then
			fail("cityelection: not founded")
			teardown()
			return
		end
		if c.candidates[mayor.oid] == nil then
			fail("cityelection: the bot mayor didn't register for the race")
		end

		-- A human settles in the city and runs (Novice Politician; the mock takes the residence as given)
		local human = W.human
		human.x, human.y = c.hall.x + 130, c.hall.y - 40
		c.citizens[human.oid] = true
		c.candidates[human.oid] = true
		sim.run(2 * 3600)
		local forHuman, total = 0, 0
		for voter, voted in pairs(c.voters) do
			total = total + 1
			if voted == human.oid then forHuman = forHuman + 1 end
		end
		if forHuman < 9 then
			fail("cityelection: " .. forHuman .. " of " .. total .. " bot votes for the human candidate")
		end
		-- Three updates: the human wins
		cityUpdate(); cityUpdate(); cityUpdate()
		if c.mayor ~= human.oid then
			fail("cityelection: the human candidate lost")
		end
		-- The bot mayor no longer governs and doesn't run against the human mayor; the treasury stays paid
		local candidacies = W.candidacies
		local before = #W.commands
		local deposits = W.deposits
		c.treasury = 1000
		sim.run(2 * 3600)
		if W.candidacies ~= candidacies then
			fail("cityelection: the bot ran against the human mayor")
		end
		for i = before + 1, #W.commands do
			if W.commands[i].cmd == "placestructure" and W.commands[i].bot == mayor.oid then
				fail("cityelection: the old mayor placed a building under the human mayor")
				break
			end
		end
		if W.deposits == deposits then
			fail("cityelection: nobody paid the treasury under the human mayor")
		end
		-- The human runs again: the bots vote for them; the human mayor leaves the city: the bot runs again
		c.candidates[human.oid] = true
		sim.run(2 * 3600)
		local again = 0
		for _, voted in pairs(c.voters) do
			if voted == human.oid then again = again + 1 end
		end
		if again < 9 then
			fail("cityelection: " .. again .. " bot votes for the human incumbent")
		end
		c.candidates, c.voters = {}, {}
		c.citizens[human.oid] = nil
		sim.run(2 * 3600)
		if c.candidates[mayor.oid] == nil then
			fail("cityelection: the bot didn't run again once the human mayor left")
		end
		cityUpdate(); cityUpdate(); cityUpdate()
		if c.mayor ~= mayor.oid then
			fail("cityelection: the bot didn't win back the empty seat")
		end
		checkNoFalseThanks("cityelection")
		report("cityelection")
		teardown()
	end

	-- Scenario: a server restart (shared memory lost, the world kept), and a second login without logout

	function scenarios.cityrestart()
		setup("cityrestart")
		loginAll()
		sim.run(900)
		BotCityJobs:toRank("3")
		sim.run(3600)
		local c = W.city
		if c == nil or c.rank ~= 3 then
			fail("cityrestart: rank " .. tostring(c and c.rank) .. " before the restart")
			teardown()
			return
		end
		local structures, deeds, declares = #W.structures, W.deedsGiven, W.declares
		local foundCalls = W.foundCalls

		-- The restart: the bots go, shared memory is wiped, the world stays
		logoutAll()
		sim.events = {}
		for k in pairs(W.keys) do deleteData(k) end
		for k in pairs(W.strKeys) do deleteStringData(k) end
		BotCityJobs:resetPlan()
		loginAll()
		sim.run(1800)
		-- ...and a BotJobs:restart (a second onLogin, no logout)
		for _, b in pairs(W.bots) do
			sim.call("BotJobs", "onLogin", b)
		end
		sim.run(1800)
		if #W.structures ~= structures then
			fail("cityrestart: " .. (#W.structures - structures) .. " new structures after the restart")
		end
		if W.deedsGiven ~= deeds then
			fail("cityrestart: " .. (W.deedsGiven - deeds) .. " new deeds after the restart")
		end
		if W.cities ~= 1 then
			fail("cityrestart: " .. W.cities .. " cities")
		end
		if W.declares - declares > 0 then
			fail("cityrestart: " .. (W.declares - declares) .. " residences declared again")
		end
		checkRankBuildings("cityrestart", 3)
		checkWorkers("cityrestart")
		checkNoDuplicates("cityrestart")
		local fails = failedCommands(0)
		if #fails > 0 then
			fail("cityrestart: refused commands: " .. table.concat(fails, "; "))
		end
		report("cityrestart")
		realPrint(string.format("             after the restart: %d founding calls (city found by name), %d residence calls",
			W.foundCalls - foundCalls, W.declares - declares))
		teardown()
	end

	-- Scenario: a day in the citizens' lives at rank 3

	function scenarios.cityroutine()
		setup("cityroutine")
		W.stuckChance = 0.05
		loginAll()
		sim.run(900)
		BotCityJobs:toRank("3")
		sim.run(1800)
		ctx.setHour(6)
		local citizens = {}
		for _, b in pairs(W.bots) do
			if b.job == "citizen" then table.insert(citizens, b) end
		end
		local visits, homeAtNight, spotClash = {}, 0, 0
		local function sample()
			local spots = {}
			for _, b in ipairs(citizens) do
				local at = readStringData("bot:" .. b.oid .. ":cityAt")
				if at ~= "" then
					visits[at] = (visits[at] or 0) + 1
				end
				if b.cell ~= 0 then
					local k = b.cell .. ":" .. b.x .. ":" .. b.y
					if spots[k] then spotClash = spotClash + 1 end
					spots[k] = true
				end
			end
		end
		for hour = 1, 24 do
			for _ = 1, 6 do
				sim.run(600)
				sample()
			end
			if (hour + 6) % 24 == 3 then
				for _, b in ipairs(citizens) do
					if readStringData("bot:" .. b.oid .. ":cityAt") == "home" or BotCityJobs:moving(b.oid) then
						homeAtNight = homeAtNight + 1
					end
				end
			end
		end
		for _, place in ipairs({"home", "cantina", "bank", "streets"}) do
			if (visits[place] or 0) == 0 then
				fail("cityroutine: no citizen was ever at the " .. place)
			end
		end
		if homeAtNight < #citizens - 1 then
			fail("cityroutine: only " .. homeAtNight .. " of " .. #citizens .. " citizens home (or on the way) at 03:00")
		end
		if spotClash > 0 then
			fail("cityroutine: two citizens on one spot " .. spotClash .. " times")
		end
		checkWorkers("cityroutine")
		local fails = failedCommands(0)
		if #fails > 0 then
			fail("cityroutine: refused commands: " .. table.concat(fails, "; "))
		end
		local parts = {}
		for place, n in pairs(visits) do table.insert(parts, place .. " " .. n) end
		table.sort(parts)
		report("cityroutine")
		realPrint("             samples by place: " .. table.concat(parts, ", ") .. "; home at 03:00: " .. homeAtNight .. "/" .. #citizens)
		teardown()
	end

	table.insert(order, "city")
	table.insert(order, "cityweeks")
	table.insert(order, "cityelection")
	table.insert(order, "cityrestart")
	table.insert(order, "cityroutine")
end
