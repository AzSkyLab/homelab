-- Own crews (Phase 9, Part 1): what a hired bot is made of. Pure functions over custom_scripts/bots/crews.lua (BotCrewData):
-- the boxes of a role's training order for a level, the gear for that level, the looks of a species and sex, and a bot's
-- roster-shaped entry. No game calls, so the simulator runs it as it is. Spec: ~/github/swgemu/specs/2026-10-26-crew-grows/.
--
-- A level is a count of boxes: the skill boxes a character owns, not counting novice, species or language boxes (the C++ counts
-- a human's the same way, botBoxCount). The training order lists the novice boxes a build needs beside the counted ones; a bot
-- with N boxes owns everything in the order up to its (N+1)th counted box.

includeFile("../custom_scripts/bots/crews.lua")

BotCrewKit = BotCrewKit or {}

local function isNovice(box)
	return box:find("_novice$") ~= nil
end

-- A number from a string, the same in every Lua state (a name picks its clothes by it)
function BotCrewKit:hash(text)
	local h = 7

	for i = 1, #text do
		h = (h * 31 + text:byte(i)) % 1000003
	end

	return h
end

function BotCrewKit:role(id)
	for _, role in ipairs(BotCrewData.roles) do
		if role.id == id then
			return role
		end
	end

	return nil
end

function BotCrewKit:species(id)
	for _, species in ipairs(BotCrewData.species) do
		if species.id == id then
			return species
		end
	end

	return nil
end

-- The boxes a bot of this role owns at a level (the training order up to its (boxes+1)th counted box), and how many of them
-- count (fewer than asked when the build is complete)
function BotCrewKit:skillsFor(role, boxes)
	local skills, counted = {}, 0

	for _, box in ipairs(BotCrewData.order[role] or {}) do
		if not isNovice(box) then
			if counted >= boxes then
				break
			end

			counted = counted + 1
		end

		table.insert(skills, box)
	end

	return skills, counted
end

-- How many counted boxes are in a list of skills (the entry's own, for the level it was hired at)
function BotCrewKit:boxesIn(skills)
	local counted = 0

	for _, box in ipairs(skills or {}) do
		if not isNovice(box) and not box:find("^species_") and not box:find("^social_language_") then
			counted = counted + 1
		end
	end

	return counted
end

-- The pieces of a set that this species and role can wear (the armor region of crews.lua lists, for each piece, who can't), and how
-- many the species could wear if its stats allowed: the second is the size of the whole set for it
function BotCrewKit:armorPieces(set, species, role)
	local pieces, whole = {}, 0

	for _, piece in ipairs(BotCrewData.armor[set] or {}) do
		local cant = " " .. piece[2] .. " "

		if not cant:find(" " .. species .. " ", 1, true) then
			whole = whole + 1

			if not cant:find(" " .. species .. "/" .. tostring(role) .. " ", 1, true) then
				table.insert(pieces, piece[1])
			end
		end
	end

	return pieces, whole
end

-- The armor for a role and species at a level: the first set of the tier that the bot can wear all of, else what it can wear of the
-- last. nil for the entertainer, who wears clothes. Returns the pieces.
function BotCrewKit:armor(role, species, boxes)
	if role == "entertainer" then
		return {}
	end

	local tier = BotCrewData.armorTiers[1]

	for _, candidate in ipairs(BotCrewData.armorTiers) do
		if candidate.from <= boxes then
			tier = candidate
		end
	end

	local sets = species == "wookiee" and tier.wookiee or species == "ithorian" and tier.ithorian or tier.standard
	local last = {}

	for _, name in ipairs(sets) do
		if name == "final" then
			name = BotCrewData.armorFinal[role]
		end

		if name ~= nil then
			local pieces, whole = self:armorPieces(name, species, role)

			if #pieces == whole and whole > 0 then
				return pieces
			end

			last = pieces
		end
	end

	return last
end

-- The gear of a role at a level: {outfit = worn and held templates, carry = in the pack, weapon = the one in hand (or ""),
-- campKit = the ranger's camp kit (or "")}. name picks the outfit among a family's few.
function BotCrewKit:gear(role, species, sex, boxes, name)
	local outfit, carry = {}, {}
	local weapon, campKit = "", ""
	local pick = self:hash(name or "")

	local family = species == "wookiee" and "wookiee" or species == "ithorian" and "ithorian" or "standard"
	local clothes = BotCrewData.clothes[family]
	local wear = clothes[pick % #clothes + 1]

	local armor = self:armor(role, species, boxes)

	-- (armor legs and clothes pants take the same slot: with armor trousers on, no pants)
	local trousers, boots = false, false

	for _, template in ipairs(armor) do
		if template:find("leggings", 1, true) ~= nil or template:find("_pants", 1, true) ~= nil then
			trousers = true
		end

		if template:find("boots", 1, true) ~= nil then
			boots = true
		end
	end

	-- (a Wookiee's shirt and its chest armor take the same place: the fur shows under the armor)
	if family == "wookiee" and #armor > 0 then
		wear = {}
	end

	for _, template in ipairs(wear) do
		if not (trousers and (template:find("/pants/", 1, true) ~= nil or template:find("_pants_", 1, true) ~= nil)) then
			table.insert(outfit, template)
		end
	end

	for _, template in ipairs(armor) do
		table.insert(outfit, template)
	end

	-- Shoes when no armor boots cover them (a Trandoshan wears none)
	if family == "standard" and species ~= "trandoshan" and not boots then
		table.insert(outfit, BotCrewData.shoes[pick % #BotCrewData.shoes + 1])
	end

	for _, tier in ipairs(BotCrewData.weapons[role] or {}) do
		if tier.from <= boxes then
			if tier.held ~= nil then
				weapon = tier.held
			elseif tier.carry ~= nil then
				table.insert(carry, tier.carry)
			end
		end
	end

	if weapon ~= "" then
		table.insert(outfit, weapon)
	end

	for _, template in ipairs(BotCrewData.carry[role] or {}) do
		table.insert(carry, template)
	end

	if role == "ranger" then
		for _, camp in ipairs(BotCrewData.camps) do
			if camp.from <= boxes then
				campKit = camp.kit
			end
		end

		if campKit ~= "" then
			table.insert(carry, campKit)
		end
	end

	return {outfit = outfit, carry = carry, weapon = weapon, campKit = campKit}
end

-- The looks of a species and sex: a list of {label, hair, hairColor, skinTone}
function BotCrewKit:looks(species, sex)
	local bySpecies = BotCrewData.looks[species]

	return bySpecies ~= nil and bySpecies[sex] or {}
end

-- The first name of a full name
function BotCrewKit:first(name)
	return tostring(name or ""):match("^(%S+)") or ""
end

-- The station of a new bot in a cantina: the first point none of `used` ({{x, y}, ...}) is within a metre of, facing the middle of
-- the room. nil when the cantina is full.
function BotCrewKit:station(cantina, used)
	local data = BotCrewData.cantinas[cantina]

	if data == nil then
		return nil
	end

	for _, point in ipairs(BotCrewData.stations) do
		local free = true

		for _, other in ipairs(used or {}) do
			if math.abs(other[1] - point[1]) < 1 and math.abs(other[2] - point[2]) < 1 then
				free = false
				break
			end
		end

		if free then
			local heading = math.deg(math.atan(data.face.x - point[1], data.face.y - point[2])) % 360

			return {planet = data.planet, x = point[1], z = BotCrewData.stationZ, y = point[2], cell = data.cell,
				heading = math.floor(heading + 0.5)}
		end
	end

	return nil
end

-- A roster-shaped entry. spec: {role, species, sex, name ("First Last"), look = {hair, hairColor, skinTone}, boxes, city, station}.
-- The account is bot_ and the first name in lower case, letters and digits only.
function BotCrewKit:entry(spec)
	local skills = self:skillsFor(spec.role, spec.boxes or 0)
	local gear = self:gear(spec.role, spec.species, spec.sex, spec.boxes or 0, spec.name)
	local look = spec.look or {}
	local first = self:first(spec.name)

	return {
		name = spec.name,
		account = "bot_" .. first:lower():gsub("[^%w]", ""),
		species = spec.species,
		sex = spec.sex,
		hair = look.hair or "",
		hairColor = look.hairColor,
		skinTone = look.skinTone,
		job = spec.role,
		city = spec.city,
		skills = skills,
		outfit = gear.outfit,
		carry = gear.carry,
		weapon = gear.weapon,
		campKit = gear.campKit,
		doctrine = BotCrewData.doctrineSeeds[spec.role],
		station = spec.station,
	}
end
