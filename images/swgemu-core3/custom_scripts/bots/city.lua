-- Varenhal, the player city the bot players found and run on Naboo (Phase 6). Spec:
-- ~/github/swgemu/specs/2026-10-23-player-city/. Read by the city jobs (screenplays/bots/city_jobs.lua) through
-- includeFile. Data only: no function calls. The roster (bots/roster.lua) has the ten city bots; settings.cityName
-- is this plan's name.
--
-- The format
--   name, key, planet   the city's name (Core3 checks it at founding: no region name inside it), the roster's city
--                       key, and the planet
--   site                the city's centre: the city hall's spot (Core3 centres the city on the hall)
--   hall                the city hall: its deed, spot and angle (botFoundCity places it)
--   houses              one lot per city bot, by first name: the deed, the spot, the angle. Each owner places its
--                       house on day 0 and declares residence there: ten citizens with the mayor, rank 5's number
--   civic               the civic buildings: kind, the rank that unlocks it, who places it (by job: the mayor
--                       unless it says dancer, musician or doctor), the deed, the spot and the angle
--   decorations         rank 5's decorations: template, spot, heading. Core3 puts a decoration where the mayor
--                       stands, facing as the mayor faces, so the mayor walks to each spot first
--   streets             points on the streets, for the citizens' walks
--   taxes               income (credits a week), property (% of house upkeep), sales (%), travel (credits a
--                       ticket), garage (%): CityManager::setTax indexes 0-4 in that order
--   specialization      Core3's string for Entertainment District (city_manager.lua CitySpecializations), set
--                       at specRank; the city registers on the planetary map at registerRank
--   zoning              false: the mayor turns zoning off, so anyone may place a house in the city
-- Spots are world x/y (east, north). An angle is /placestructure's 0-3 (times 90 degrees); this plan uses only 0
-- (the front, the door side, north) and 2 (the front south), so a footprint's turn can't be mistaken. A house
-- is placed at the highest ground under its footprint (StructureManager::placeStructure), so the lots are on the
-- flattest ground near the hall.
--
-- The town: the city hall faces south onto Main Street, which runs east-west; the cantina, small garden, bank and
-- garage stand on its north side beside the hall, five houses on its south side face it, and its two ends take
-- the theater (west) and the cloning centre and shuttleport (east). The Back Lane runs behind the hall, with five
-- houses facing it. The hospital, the medium and the large gardens are on the edges. Footprints (Core3's
-- getStructureFootprint over the client's .sfp files: 8 m cells) keep at least 8 m apart and off both streets;
-- the houses are within 135 m of the hall (rank 1's radius is 150 m), and every civic building is inside the
-- radius of the rank that unlocks it.
--
-- Where the site came from (2026-10-23):
--   Provisional site, before the probe.
BotCityPlan = {
	name = "Varenhal",
	key = "varenhal",
	planet = "naboo",

	site = {x = -3153, y = 4750},
	hall = {deed = "object/tangible/deed/city_deed/cityhall_naboo_deed.iff", x = -3153, y = 4750, angle = 2},

	houses = {
		{owner = "Aldren", deed = "object/tangible/deed/player_house_deed/naboo_house_medium_deed.iff", x = -3153, y = 4826, angle = 0},		-- medium house (2 lots)
		{owner = "Talia", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3193, y = 4826, angle = 0},		-- small house (style 1, 1 lot)
		{owner = "Ossin", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3113, y = 4826, angle = 0},		-- small house (style 1, 1 lot)
		{owner = "Brynna", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3233, y = 4826, angle = 2},		-- small house (style 2, 2 lots)
		{owner = "Garvik", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3073, y = 4826, angle = 2},		-- small house (style 2, 2 lots)
		{owner = "Mareth", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3233, y = 4660, angle = 0},		-- small house (style 2, 2 lots)
		{owner = "Mowsha", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3193, y = 4660, angle = 2},		-- small house (style 1, 1 lot)
		{owner = "Sarra", deed = "object/tangible/deed/player_house_deed/naboo_house_medium_deed.iff", x = -3153, y = 4660, angle = 2},		-- medium house (2 lots)
		{owner = "Neebo", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3113, y = 4660, angle = 2},		-- small house (style 1, 1 lot)
		{owner = "Rrowkarr", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3073, y = 4660, angle = 0},		-- small house (style 2, 2 lots)
	},

	civic = {
		{kind = "garden_sml", rank = 1, deed = "object/tangible/deed/city_deed/garden_naboo_sml_01_deed.iff", x = -3201, y = 4718, angle = 2},
		{kind = "bank", rank = 2, deed = "object/tangible/deed/city_deed/bank_naboo_deed.iff", x = -3105, y = 4718, angle = 2},
		{kind = "garage", rank = 2, deed = "object/tangible/deed/city_deed/garage_naboo_deed.iff", x = -3065, y = 4726, angle = 2},
		{kind = "cantina", rank = 2, by = "dancer", deed = "object/tangible/deed/city_deed/cantina_naboo_deed.iff", x = -3253, y = 4734, angle = 2},
		{kind = "garden_med", rank = 2, deed = "object/tangible/deed/city_deed/garden_naboo_med_01_deed.iff", x = -3021, y = 4658, angle = 0},
		{kind = "cloning", rank = 3, deed = "object/tangible/deed/city_deed/cloning_naboo_deed.iff", x = -3017, y = 4726, angle = 2},
		{kind = "hospital", rank = 3, by = "doctor", deed = "object/tangible/deed/city_deed/hospital_naboo_deed.iff", x = -3285, y = 4658, angle = 0},
		{kind = "garden_lrg", rank = 3, deed = "object/tangible/deed/city_deed/garden_naboo_lrg_01_deed.iff", x = -3293, y = 4834, angle = 2},
		{kind = "shuttleport", rank = 4, deed = "object/tangible/deed/city_deed/shuttleport_naboo_deed.iff", x = -2965, y = 4726, angle = 2},
		{kind = "theater", rank = 4, by = "musician", deed = "object/tangible/deed/city_deed/theater_naboo_deed.iff", x = -3323, y = 4730, angle = 0},
	},

	decorations = {
		{template = "object/tangible/furniture/city/fountain_heroic.iff", x = -3153, y = 4693, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/statue_sentinel_01.iff", x = -3177, y = 4693, heading = 90, rank = 5},
		{template = "object/tangible/furniture/city/statue_sentinel_02.iff", x = -3129, y = 4693, heading = 270, rank = 5},
		{template = "object/tangible/furniture/city/fountain_circle.iff", x = -3253, y = 4693, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/fountain_circle.iff", x = -3053, y = 4693, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3293, y = 4704, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3213, y = 4704, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3093, y = 4704, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3013, y = 4704, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3293, y = 4684, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3213, y = 4684, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3093, y = 4684, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3013, y = 4684, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_large_01.iff", x = -3213, y = 4792, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_large_01.iff", x = -3093, y = 4792, heading = 0, rank = 5},
	},

	streets = {
		{x = -3313, y = 4693}, {x = -3273, y = 4693}, {x = -3233, y = 4693}, {x = -3193, y = 4693},
		{x = -3153, y = 4693}, {x = -3113, y = 4693}, {x = -3073, y = 4693}, {x = -3033, y = 4693},
		{x = -2993, y = 4693}, {x = -3273, y = 4792}, {x = -3233, y = 4792}, {x = -3193, y = 4792},
		{x = -3153, y = 4792}, {x = -3113, y = 4792}, {x = -3073, y = 4792}, {x = -3033, y = 4792},
		{x = -3187, y = 4758}, {x = -3119, y = 4758},
	},

	taxes = {income = 50, property = 5, sales = 2, travel = 25, garage = 5},
	specialization = "@city/city:city_spec_entertainer",	-- Entertainment District, 80,000 a week
	specRank = 3,
	registerRank = 3,
	zoning = false,
}
