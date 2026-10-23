-- Living Cities: mobile templates for the player-looking NPCs, one per kit, species and sex in bodies.lua.
-- Each wears a random outfit from its group in outfits.lua; the screenplay names them at spawn.
includeFile("../custom_scripts/mobile/living_cities/outfits.lua")
includeFile("../custom_scripts/mobile/living_cities/bodies.lua")

for kit, bodies in pairs(LivingCitiesBodies) do
	for _, body in ipairs(bodies) do
		local name = "living_" .. kit .. "_" .. body.species .. "_" .. body.sex

		local template = Creature:new {
			objectName = "@mob/creature_names:commoner",
			socialGroup = "",
			mobType = MOB_NPC,
			faction = "",
			level = 10,
			chanceHit = 0.3,
			damageMin = 50,
			damageMax = 55,
			baseXp = 0,
			baseHAM = 900,
			baseHAMmax = 1100,
			armor = 0,
			resists = {0,0,0,0,0,0,0,-1,-1},
			-- Not attackable and no con colour, like another player
			pvpBitmask = NONE,
			creatureBitmask = NONE,
			optionsBitmask = AIENABLED,
			diet = HERBIVORE,
			-- Walks only where the screenplay sends it
			customAiMap = "cityPatrol",

			templates = {body.template},
			outfit = body.outfit,

			lootGroups = {},
			primaryWeapon = "unarmed",
			secondaryWeapon = "none",
			conversationTemplate = "",
			primaryAttacks = {},
			secondaryAttacks = {}
		}

		CreatureTemplates:addCreatureTemplate(template, name)
	end
end
