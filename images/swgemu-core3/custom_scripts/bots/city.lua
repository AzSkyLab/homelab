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
--   The creator's pick, from the city agent's probes on the local server (botCheckSite): the flattest ground on the
--   plain east of Theed, (-3291, 4911), z about -196, 2.1 km from Theed's centre (-5320, 4368; a city hall needs 1904 m),
--   outside the Theed no-build rectangle. 0.7 m of height difference within 30 m and 4.0 m within 250 m, nothing
--   blocked. The whole plan was laid out round (-3153, 4750) and moved as one piece by (-138, +161); every lot keeps
--   its place relative to the hall.
BotCityPlan = {
	name = "Varenhal",
	key = "varenhal",
	planet = "naboo",

	site = {x = -3291, y = 4911},
	hall = {deed = "object/tangible/deed/city_deed/cityhall_naboo_deed.iff", x = -3291, y = 4911, angle = 2},

	houses = {
		{owner = "Aldren", deed = "object/tangible/deed/player_house_deed/naboo_house_medium_deed.iff", x = -3291, y = 4987, angle = 0},		-- medium house (2 lots)
		{owner = "Talia", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3331, y = 4987, angle = 0},		-- small house (style 1, 1 lot)
		{owner = "Ossin", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3251, y = 4987, angle = 0},		-- small house (style 1, 1 lot)
		{owner = "Brynna", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3371, y = 4987, angle = 2},		-- small house (style 2, 2 lots)
		{owner = "Garvik", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3211, y = 4987, angle = 2},		-- small house (style 2, 2 lots)
		{owner = "Mareth", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3371, y = 4821, angle = 0},		-- small house (style 2, 2 lots)
		{owner = "Mowsha", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3331, y = 4821, angle = 2},		-- small house (style 1, 1 lot)
		{owner = "Sarra", deed = "object/tangible/deed/player_house_deed/naboo_house_medium_deed.iff", x = -3291, y = 4821, angle = 2},		-- medium house (2 lots)
		{owner = "Neebo", deed = "object/tangible/deed/player_house_deed/naboo_house_small_style_02_deed.iff", x = -3251, y = 4821, angle = 2},		-- small house (style 1, 1 lot)
		{owner = "Rrowkarr", deed = "object/tangible/deed/player_house_deed/naboo_house_small_deed.iff", x = -3211, y = 4821, angle = 0},		-- small house (style 2, 2 lots)
	},

	civic = {
		{kind = "garden_sml", rank = 1, deed = "object/tangible/deed/city_deed/garden_naboo_sml_01_deed.iff", x = -3339, y = 4879, angle = 2},
		{kind = "bank", rank = 2, deed = "object/tangible/deed/city_deed/bank_naboo_deed.iff", x = -3243, y = 4879, angle = 2},
		{kind = "garage", rank = 2, deed = "object/tangible/deed/city_deed/garage_naboo_deed.iff", x = -3203, y = 4887, angle = 2},
		{kind = "cantina", rank = 2, by = "dancer", deed = "object/tangible/deed/city_deed/cantina_naboo_deed.iff", x = -3391, y = 4895, angle = 2},
		{kind = "garden_med", rank = 2, deed = "object/tangible/deed/city_deed/garden_naboo_med_01_deed.iff", x = -3159, y = 4819, angle = 0},
		{kind = "cloning", rank = 3, deed = "object/tangible/deed/city_deed/cloning_naboo_deed.iff", x = -3155, y = 4887, angle = 2},
		{kind = "hospital", rank = 3, by = "doctor", deed = "object/tangible/deed/city_deed/hospital_naboo_deed.iff", x = -3423, y = 4819, angle = 0},
		{kind = "garden_lrg", rank = 3, deed = "object/tangible/deed/city_deed/garden_naboo_lrg_01_deed.iff", x = -3431, y = 4995, angle = 2},
		{kind = "shuttleport", rank = 4, deed = "object/tangible/deed/city_deed/shuttleport_naboo_deed.iff", x = -3103, y = 4887, angle = 2},
		{kind = "theater", rank = 4, by = "musician", deed = "object/tangible/deed/city_deed/theater_naboo_deed.iff", x = -3461, y = 4891, angle = 0},
	},

	decorations = {
		{template = "object/tangible/furniture/city/fountain_heroic.iff", x = -3291, y = 4854, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/statue_sentinel_01.iff", x = -3315, y = 4854, heading = 90, rank = 5},
		{template = "object/tangible/furniture/city/statue_sentinel_02.iff", x = -3267, y = 4854, heading = 270, rank = 5},
		{template = "object/tangible/furniture/city/fountain_circle.iff", x = -3391, y = 4854, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/fountain_circle.iff", x = -3191, y = 4854, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3431, y = 4865, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3351, y = 4865, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3231, y = 4865, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3151, y = 4865, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3431, y = 4845, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3351, y = 4845, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3231, y = 4845, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_med_01.iff", x = -3151, y = 4845, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_large_01.iff", x = -3351, y = 4953, heading = 0, rank = 5},
		{template = "object/tangible/furniture/city/streetlamp_large_01.iff", x = -3231, y = 4953, heading = 0, rank = 5},
	},

	streets = {
		{x = -3451, y = 4854}, {x = -3411, y = 4854}, {x = -3371, y = 4854}, {x = -3331, y = 4854},
		{x = -3291, y = 4854}, {x = -3251, y = 4854}, {x = -3211, y = 4854}, {x = -3171, y = 4854},
		{x = -3131, y = 4854}, {x = -3411, y = 4953}, {x = -3371, y = 4953}, {x = -3331, y = 4953},
		{x = -3291, y = 4953}, {x = -3251, y = 4953}, {x = -3211, y = 4953}, {x = -3171, y = 4953},
		{x = -3325, y = 4919}, {x = -3257, y = 4919},
	},

	taxes = {income = 50, property = 5, sales = 2, travel = 25, garage = 5},
	specialization = "@city/city:city_spec_entertainer",	-- Entertainment District, 80,000 a week
	specRank = 3,
	registerRank = 3,
	zoning = false,
}
