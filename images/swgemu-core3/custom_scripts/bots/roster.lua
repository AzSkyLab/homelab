-- Bot players (Phase 3): the six characters the server runs itself, one master doctor and one master dancer in each of
-- Mos Eisley, Coronet and Theed. Spec: ~/github/swgemu/specs/2026-10-23-bot-players/ (interfaces.md has the contract).
--
-- Read by BotManager at boot, in its own Lua state, and by the jobs screenplay through includeFile. Data only: no
-- function calls, so it loads anywhere.
--
-- settings
--   loginDelay, logoutDelay   seconds after the first human logs in / the last human logs out
--   enhancePower              enhance pack power. A master doctor (healing_wound_treatment 100) in a hospital
--                             (private_medical_rating 100) doubles it: 700 gives about +1400 to each attribute
--   enhanceDuration           enhance pack duration in seconds (3 hours; Twi'lek patients get 10% longer)
--   woundPower                wound pack power: a good crafted E-tier pack (medpack_wound_*_e, 30-400). In a hospital a
--                             master doctor heals four times that per pool
--   packStock                 uses kept on each pack
--
-- bots: one table each
--   name       "First Last". Players address a bot by its first name, so first names are unique, and they are reserved
--              in screenplays/living_cities/names.lua: the crowd never uses them. Checked against Core3's NameManager
--              rules for the species and its name filter (oldFilterWords).
--   account    the MySQL account, bot_<first name in lower case>
--   species    as in object/creature/player/<species>_<sex>.iff
--   hair       a hair template the character creator offers for that species and sex (available at creation in
--              datatables/customization/hair_assets_skill_mods.iff); "" for none (Mon Calamari may be bald)
--   job        "doctor" or "dancer"
--   city       the Living Cities city key
--   skills     each awarded with every skill it requires (Master Doctor brings the medic tree; Master Dancer brings
--              Novice Entertainer and the entertainer dance and healing lines)
--   outfit     wearable templates, all equipped. Every item exists in Core3's object scripts, allows the species
--              (playerRaces), has a model for the sex, and no two share a slot
--   station    where the bot stands while online. With a cell, x, z, y are cell-local (the building's frame, as
--              spawnMobile takes them) and z is the floor height of the cell's floor mesh. heading is degrees clockwise
--              from north in the same frame, the convention of Core3's spawn tables and Living Cities' slots. Convert
--              it with deg2rad: CreatureObject::setDirection(float) takes radians, and spawnMobile passes its heading
--              into Quaternion(axis, radians) unconverted (Living Cities calls updateDirection(math.rad(heading)))
--
-- Where the stations came from: the world snapshots (swgemu tools/snapshot.py over snapshot/<planet>.ws) for building
-- and cell ids, floor meshes, portals and furniture, checked as Phase 1 checked its slots:
--   - at least 2 m from every NPC that Core3's screenplays spawn in the building (all screenplays run with stubbed
--     engine calls), and at least 1.5 m from patrol paths;
--   - on the cell's floor mesh at least 0.6 m from its edge, clear of furniture, and z within 0.05 m of the floor;
--   - at least 1.3 m from every Living Cities crowd slot in the same cell.
-- Doctors stand about 2.5 m from the doctor trainer, inside the medical centre, facing the doorway patients come in by
-- from the street door the crowd uses. Dancers stand among the crowd's dance slots, facing the room. Nothing stands
-- within 0.4 m of the 2.5 m in front of any bot.
BotRoster = {
	settings = {
		loginDelay = 60,
		logoutDelay = 600,
		enhancePower = 700,
		enhanceDuration = 10800,
		woundPower = 300,
		packStock = 20,
	},

	bots = {
		-- Mos Eisley medical centre (hospital_tatooine_s02 9655494), main room, east of the doctor trainer (-7.3, 0.1),
		-- in the aisle between the beds, facing the south-west corner where the south-west door's hall comes in
		{
			name = "Hesk Torlan",
			account = "bot_hesk",
			species = "bothan",
			sex = "male",
			hair = "object/tangible/hair/bothan/hair_bothan_male_s07.iff",
			job = "doctor",
			city = "mos_eisley",
			skills = {"science_doctor_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s13.iff",		-- Formal Shirt
				"object/tangible/wearables/pants/pants_s15.iff",		-- Dress Slacks
				"object/tangible/wearables/jacket/jacket_s03.iff",		-- Long Formal Jacket
				"object/tangible/wearables/shoes/shoes_s01.iff",		-- Dress Shoes
			},
			station = {planet = "tatooine", x = -4.8, z = 0.184, y = 0.1, cell = 9655496, heading = 220},
		},
		-- Chalmun's cantina (cantina_tatooine 1082874), main room: in front of the band's alcove, among the crowd's dance
		-- slots, facing the room
		{
			name = "Neela Kaavo",
			account = "bot_neela",
			species = "twilek",
			sex = "female",
			hair = "object/tangible/hair/twilek/hair_twilek_female_s05.iff",
			job = "dancer",
			city = "mos_eisley",
			skills = {"social_dancer_master"},
			outfit = {
				"object/tangible/wearables/dress/dress_s08.iff",		-- Exotic Leotard
				"object/tangible/wearables/shoes/shoes_s07.iff",		-- Sandals
				"object/tangible/wearables/bracelet/bracelet_s05_l.iff",	-- Bangles
				"object/tangible/wearables/bracelet/bracelet_s05_r.iff",	-- Bangles
				"object/tangible/wearables/necklace/necklace_flashy_choker.iff",
			},
			station = {planet = "tatooine", x = 5.4, z = -0.895, y = -11.4, cell = 1082877, heading = 20},
		},
		-- Coronet medical centre (hospital_corellia 1855529), room A, south-east of the doctor trainer (-25.3, -5.0), clear
		-- of the surgical droid's patrol, facing the corner where the north door's hall (entryc) comes in
		{
			name = "Doran Halcott",
			account = "bot_doran",
			species = "human",
			sex = "male",
			hair = "object/tangible/hair/human/hair_human_male_s08.iff",
			job = "doctor",
			city = "coronet",
			skills = {"science_doctor_master"},
			outfit = {
				"object/tangible/wearables/dress/dress_s19.iff",		-- Doctor's Dress (it has a male model)
				"object/tangible/wearables/shoes/shoes_s01.iff",		-- Dress Shoes
			},
			station = {planet = "corellia", x = -23.8, z = 0.26, y = -7, cell = 1855535, heading = 240},
		},
		-- Coronet cantina (cantina_corellia 8105493), main room: the open floor by the stage, on the stage side of the
		-- crowd's dance slots, facing them
		{
			name = "Selka Marrovan",
			account = "bot_selka",
			species = "zabrak",
			sex = "female",
			hair = "object/tangible/hair/zabrak/hair_zabrak_female_s05.iff",
			job = "dancer",
			city = "coronet",
			skills = {"social_dancer_master"},
			outfit = {
				"object/tangible/wearables/bodysuit/bodysuit_s06.iff",	-- Revealing Fleshwrap
				"object/tangible/wearables/shoes/shoes_s09.iff",		-- Dress Slippers
				"object/tangible/wearables/bracelet/bracelet_s03_l.iff",	-- Golden Bracelet
				"object/tangible/wearables/necklace/necklace_sparkling_bijou.iff",
			},
			station = {planet = "corellia", x = -6, z = -0.895, y = -11.3, cell = 8105496, heading = 5},
		},
		-- Theed medical centre (hospital_naboo 1697358), room B, west of the doctor trainer (17.4, 0.8) at the desk, in
		-- the aisle between the beds, facing the corner where the north-east door's hall (entryb) comes in
		{
			name = "Ilyra Seawell",
			account = "bot_ilyra",
			species = "moncal",
			sex = "female",
			hair = "",
			job = "doctor",
			city = "theed",
			skills = {"science_doctor_master"},
			outfit = {
				"object/tangible/wearables/dress/dress_s15.iff",		-- Grand Healer's Robe (it has a Mon Calamari model)
				"object/tangible/wearables/shoes/shoes_s08.iff",		-- Women's Shoes
			},
			station = {planet = "naboo", x = 14.9, z = 0.26, y = 0.8, cell = 1697360, heading = 310},
		},
		-- Theed cantina (cantina_naboo 88), main room: in front of the band's alcove, in the middle of the crowd's dance
		-- slots, facing the room
		{
			name = "Saela Dawnmere",
			account = "bot_saela",
			species = "human",
			sex = "female",
			hair = "object/tangible/hair/human/hair_human_female_s24.iff",
			job = "dancer",
			city = "theed",
			skills = {"social_dancer_master"},
			outfit = {
				"object/tangible/wearables/bikini/bikini_s01.iff",		-- Revealing Bikini
				"object/tangible/wearables/bikini/bikini_leggings_s01.iff",	-- Sheer Leggings
				"object/tangible/wearables/shoes/shoes_s08.iff",		-- Women's Shoes
				"object/tangible/wearables/necklace/necklace_s12.iff",	-- Elegant Gemstone Necklace
				"object/tangible/wearables/bracelet/bracelet_s06_r.iff",	-- Metal Bracelet
			},
			station = {planet = "naboo", x = 5.3, z = -0.895, y = -11.1, cell = 91, heading = 15},
		},
	},
}
