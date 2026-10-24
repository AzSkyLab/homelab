-- Bot players: the characters the server runs itself. Phase 3: a master doctor and a master dancer in each of Mos Eisley,
-- Coronet and Theed. Phase 4: a master musician beside each dancer and a master smuggler in each cantina. Phase 5: the
-- hunting crew in the Mos Eisley cantina. Phase 6: the ten people of Varenhal, the player city on Naboo. Specs:
-- ~/github/swgemu/specs/2026-10-23-bot-players/ (interfaces.md has the contract), 2026-10-23-musicians-smugglers/,
-- 2026-10-23-bot-group-mates/ and 2026-10-23-player-city/.
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
--   slicePriceArmor           the smuggler's price for slicing one armor piece, in credits (2004's going rate)
--   slicePriceWeapon          the smuggler's price for slicing one weapon
--   sliceToolStock            how many of each slicing tool the smuggler keeps in its pack (molecular clamps, armor and
--                             weapon upgrade kits; a laser knife has 10 uses)
--   followNear, followFar     a grouped crew bot walks this many metres behind its leader
--   specialsHam               crew bots use specials while health, action and mind are above this share of their
--                             maximum, otherwise auto-attack
--   insultsToFight            insults from one player within insultWindow seconds before a bot (any bot) attacks: a
--                             real fight to the first incapacitation
--   fightCooldown             seconds before a bot fights the same player again
--   cityName                  the player city the city bots found and run; its plan is in bots/city.lua
--
-- bots: one table each
--   name       "First Last" (a Wookiee has one name: Core3's name rules give Wookiees no last name). Players address a
--              bot by its first name, so first names are unique, and they are reserved in
--              screenplays/living_cities/names.lua: the crowd never uses them. Checked against Core3's NameManager rules
--              for the species and its name filter (oldFilterWords)
--   account    the MySQL account, bot_<first name in lower case>
--   species    as in object/creature/player/<species>_<sex>.iff
--   hair       a hair template the character creator offers for that species and sex (available at creation in
--              datatables/customization/hair_assets_skill_mods.iff); "" for none (Mon Calamari and Wookiees may be
--              bald; Ithorians have no hair)
--   job        "doctor", "dancer", "musician" or "smuggler" (town bots); "tank", "rifleman", "medic" or "ranger" (the
--              crew); "mayor" or "citizen" (the city)
--   city       the Living Cities city key, or "varenhal" for the player city
--   online     optional. "planet": online only while a human is on the station's planet, or was within logoutDelay
--              (the city's bots)
--   skills     each awarded with every skill it requires. The factory first gives the job's starting profession
--              (medic, entertainer, marksman, brawler, scout or artisan) its novice box, so that counts too: every bot
--              is within the 250 skill points (worked out from the client's skills.iff)
--   outfit     templates, all equipped. Wearables exist in Core3's object scripts, allow the species (playerRaces), have
--              a model for the sex, and no two share a slot. A weapon or a hand-held instrument equips to hold_r (rifles
--              and carbines to hold_r and hold_l): one held item each, and every weapon is one the bot is certified for
--   carry      optional. Templates the job keeps in the bot's pack: the rifleman's spare carbine (botEquip swaps it
--              in), the ranger's camp kit
--   station    where the bot stands while online. With a cell, x, z, y are cell-local (the building's frame, as
--              spawnMobile takes them) and z is the floor height of the cell's floor mesh. Outdoors (cell 0), z 0 means
--              the ground height there (BotManager asks the world floor). heading is degrees clockwise from north in
--              the same frame, the convention of Core3's spawn tables and Living Cities' slots. Convert it with
--              deg2rad: CreatureObject::setDirection(float) takes radians, and spawnMobile passes its heading into
--              Quaternion(axis, radians) unconverted (Living Cities calls updateDirection(math.rad(heading)))
--
-- Where the cantina and medical centre stations came from: the world snapshots (swgemu tools/snapshot.py over
-- snapshot/<planet>.ws) for building and cell ids, floor meshes, portals and furniture, checked as Phase 1 checked its
-- slots:
--   - at least 2 m from every NPC that Core3's screenplays spawn in the building (all screenplays run with stubbed
--     engine calls), and at least 1.5 m from patrol paths;
--   - on the cell's floor mesh at least 0.6 m from its edge, clear of furniture, and z within 0.05 m of the floor;
--   - at least 1.3 m from every Living Cities crowd slot in the same cell, and 2 m from every other bot.
-- Doctors stand about 2.5 m from the doctor trainer, inside the medical centre, facing the doorway patients come in by
-- from the street door the crowd uses. Dancers stand among the crowd's dance slots, facing the room. Musicians stand
-- 2-4 m beside their dancer in the same room with a clear line of sight. Smugglers wait at the bar (back to the counter)
-- or at a table. Nothing stands within 0.4 m of the 2.5 m in front of any bot.
BotRoster = {
	settings = {
		loginDelay = 60,
		logoutDelay = 600,
		enhancePower = 700,
		enhanceDuration = 10800,
		woundPower = 300,
		packStock = 20,
		slicePriceArmor = 4000,
		slicePriceWeapon = 6000,
		sliceToolStock = 5,
		followNear = 3,
		followFar = 5,
		specialsHam = 0.5,
		insultsToFight = 3,
		insultWindow = 600,
		fightCooldown = 600,
		cityName = "Varenhal",
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

		-- Phase 4: a master musician beside each dancer and a master smuggler in each cantina

		-- Chalmun's cantina, main room: beside the dancer on her east, at the edge of the dance floor by the booth, facing
		-- the room
		{
			name = "Tibbo Kressik",
			account = "bot_tibbo",
			species = "rodian",
			sex = "male",
			hair = "object/tangible/hair/rodian/hair_rodian_male_s05.iff",
			job = "musician",
			city = "mos_eisley",
			skills = {"social_musician_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s30.iff",		-- Leather Trim Shirt
				"object/tangible/wearables/vest/vest_s15.iff",		-- Decorative Vest
				"object/tangible/wearables/pants/pants_s25.iff",		-- Casual Pants
				"object/tangible/wearables/boots/boots_s21.iff",		-- Paneled Boots
				"object/tangible/instrument/bandfill.iff",		-- Bandfill (held)
			},
			station = {planet = "tatooine", x = 8.2, z = -0.895, y = -11.4, cell = 1082877, heading = 345},
		},
		-- Chalmun's cantina, main room: the quiet west end of the bar's south side, back to the counter, watching the room
		{
			name = "Dorvan Haldis",
			account = "bot_dorvan",
			species = "human",
			sex = "male",
			hair = "object/tangible/hair/human/hair_human_male_s13.iff",
			job = "smuggler",
			city = "mos_eisley",
			skills = {"combat_smuggler_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s16.iff",		-- Longsleeve Shirt
				"object/tangible/wearables/vest/vest_s03.iff",		-- Short Vest
				"object/tangible/wearables/pants/pants_s01.iff",		-- Striped Pants
				"object/tangible/wearables/boots/boots_s12.iff",		-- High Quality Boots
				"object/tangible/wearables/belt/belt_s19.iff",		-- Widebuckle Belt
				"object/weapon/ranged/pistol/pistol_dl44.iff",		-- DL44 (held)
			},
			station = {planet = "tatooine", x = -10.2, z = -0.895, y = -5, cell = 1082877, heading = 180},
		},
		-- Coronet cantina, main room: beside the dancer on her west, on the open floor by the stage, facing the room
		{
			name = "Vianne Corsell",
			account = "bot_vianne",
			species = "human",
			sex = "female",
			hair = "object/tangible/hair/human/hair_human_female_s20.iff",
			job = "musician",
			city = "coronet",
			skills = {"social_musician_master"},
			outfit = {
				"object/tangible/wearables/dress/dress_s29.iff",		-- Sleeveless Dress
				"object/tangible/wearables/shoes/shoes_s08.iff",		-- Women's Shoes
				"object/tangible/wearables/necklace/necklace_s07.iff",		-- Emerald Pendant
				"object/tangible/instrument/fizz.iff",		-- Fizz (held)
			},
			station = {planet = "corellia", x = -8.8, z = -0.895, y = -11.3, cell = 8105496, heading = 20},
		},
		-- Coronet cantina, main room: the west end of the bar's north side, back to the counter, watching the room
		{
			name = "Tarkon Veyle",
			account = "bot_tarkon",
			species = "zabrak",
			sex = "male",
			hair = "object/tangible/hair/zabrak/hair_zabrak_male_s04.iff",
			job = "smuggler",
			city = "coronet",
			skills = {"combat_smuggler_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s14.iff",		-- Formfitting Undershirt
				"object/tangible/wearables/jacket/jacket_s24.iff",		-- Sleeveless Jacket
				"object/tangible/wearables/pants/pants_s14.iff",		-- Large Pocket Pants
				"object/tangible/wearables/boots/boots_s05.iff",		-- Sturdy Boots
				"object/tangible/wearables/belt/belt_s14.iff",		-- Black Leather Belt
				"object/weapon/ranged/pistol/pistol_dh17.iff",		-- DH-17 (held)
			},
			station = {planet = "corellia", x = -9.4, z = -0.895, y = 6, cell = 8105496, heading = 0},
		},
		-- Theed cantina, main room: beside the dancer on her west, at the edge of the dance floor, facing the room
		{
			name = "Rhaan Telluro",
			account = "bot_rhaan",
			species = "twilek",
			sex = "male",
			hair = "object/tangible/hair/twilek/hair_twilek_male_s03.iff",
			job = "musician",
			city = "theed",
			skills = {"social_musician_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s15.iff",		-- Trim Lined Shirt
				"object/tangible/wearables/jacket/jacket_s26.iff",		-- Flared Jacket
				"object/tangible/wearables/pants/pants_s15.iff",		-- Dress Slacks
				"object/tangible/wearables/shoes/shoes_s02.iff",		-- Casual Shoes
				"object/tangible/instrument/slitherhorn.iff",		-- Slitherhorn (held)
			},
			station = {planet = "naboo", x = 2.5, z = -0.895, y = -10.1, cell = 91, heading = 15},
		},
		-- Theed cantina, main room: at the table in the south-west corner, facing the room
		{
			name = "Ylessa Tor'vani",
			account = "bot_ylessa",
			species = "bothan",
			sex = "female",
			hair = "object/tangible/hair/bothan/hair_bothan_female_s11.iff",
			job = "smuggler",
			city = "theed",
			skills = {"combat_smuggler_master"},
			outfit = {
				"object/tangible/wearables/jacket/jacket_s19.iff",		-- Tight Jacket
				"object/tangible/wearables/pants/pants_s22.iff",		-- Infiltrator Leggings
				"object/tangible/wearables/belt/belt_s15.iff",		-- Strap Belt
				"object/tangible/wearables/boots/boots_s15.iff",		-- Standard Boots
				"object/tangible/wearables/gloves/gloves_s06.iff",		-- Tipless Gloves
				"object/weapon/ranged/pistol/pistol_scout_blaster.iff",		-- Scout Blaster (held)
			},
			station = {planet = "naboo", x = -10.4, z = -0.895, y = -7.4, cell = 91, heading = 90},
		},

		-- Phase 5: the hunting crew, four looking-for-group regulars standing together on the open floor inside Chalmun's
		-- front door (main room, east side, between the tables), each facing the middle of the group

		-- Tank: Teras Kasi, Brawler and Medic masters (217 points); bone armor (a Trandoshan wears no boots or gloves),
		-- fights unarmed
		{
			name = "Kragoth Ssival",
			account = "bot_kragoth",
			species = "trandoshan",
			sex = "male",
			hair = "object/tangible/hair/trandoshan/hair_trandoshan_male_s07.iff",
			job = "tank",
			city = "mos_eisley",
			skills = {"combat_unarmed_master", "combat_brawler_master", "science_medic_master"},
			outfit = {
				"object/tangible/wearables/armor/bone/armor_bone_s01_chest_plate.iff",
				"object/tangible/wearables/armor/bone/armor_bone_s01_leggings.iff",
				"object/tangible/wearables/armor/bone/armor_bone_s01_bicep_l.iff",
				"object/tangible/wearables/armor/bone/armor_bone_s01_bicep_r.iff",
				"object/tangible/wearables/armor/bone/armor_bone_s01_bracer_l.iff",
				"object/tangible/wearables/armor/bone/armor_bone_s01_bracer_r.iff",
				"object/tangible/wearables/armor/bone/armor_bone_s01_helmet.iff",
			},
			station = {planet = "tatooine", x = 18.5, z = -0.895, y = -0.2, cell = 1082877, heading = 45},
		},
		-- Rifleman: Rifleman, Marksman and Carbineer masters (203 points); composite armor, a T21 in hand and an E-11
		-- carbine in the pack
		{
			name = "Senna Delmont",
			account = "bot_senna",
			species = "human",
			sex = "female",
			hair = "object/tangible/hair/human/hair_human_female_s31.iff",
			job = "rifleman",
			city = "mos_eisley",
			skills = {"combat_rifleman_master", "combat_marksman_master", "combat_carbine_master"},
			outfit = {
				"object/tangible/wearables/armor/composite/armor_composite_chest_plate.iff",
				"object/tangible/wearables/armor/composite/armor_composite_leggings.iff",
				"object/tangible/wearables/armor/composite/armor_composite_bicep_l.iff",
				"object/tangible/wearables/armor/composite/armor_composite_bicep_r.iff",
				"object/tangible/wearables/armor/composite/armor_composite_bracer_l.iff",
				"object/tangible/wearables/armor/composite/armor_composite_bracer_r.iff",
				"object/tangible/wearables/armor/composite/armor_composite_boots.iff",
				"object/tangible/wearables/armor/composite/armor_composite_gloves.iff",
				"object/tangible/wearables/armor/composite/armor_composite_helmet.iff",
				"object/weapon/ranged/rifle/rifle_t21.iff",		-- T21 (held)
			},
			carry = {"object/weapon/ranged/carbine/carbine_e11.iff"},
			station = {planet = "tatooine", x = 20.6, z = -0.895, y = -0.2, cell = 1082877, heading = 315},
		},
		-- Medic: Combat Medic and Doctor masters (232 points); padded armor and a CDEF pistol (the one every species is
		-- certified for: medics have no pistol line). The crew job stocks its stims and packs
		{
			name = "Quillan Desh",
			account = "bot_quillan",
			species = "moncal",
			sex = "male",
			hair = "",
			job = "medic",
			city = "mos_eisley",
			skills = {"science_combatmedic_master", "science_doctor_master"},
			outfit = {
				"object/tangible/wearables/armor/padded/armor_padded_s01_chest_plate.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_leggings.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_bicep_l.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_bicep_r.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_bracer_l.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_bracer_r.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_boots.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_gloves.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_helmet.iff",
				"object/tangible/wearables/armor/padded/armor_padded_s01_belt.iff",
				"object/weapon/ranged/pistol/pistol_cdef.iff",		-- CDEF pistol (held)
			},
			station = {planet = "tatooine", x = 18.5, z = -0.895, y = 1.9, cell = 1082877, heading = 135},
		},
		-- Ranger: Ranger master with the scout boxes it needs, Marksman master, Novice Carbineer, the carbine ability line
		-- and accuracy 1-2 (246 points; camp 100, so the luxury camp kit); chitin armor, an EE-3 carbine
		{
			name = "Weeta Valsk",
			account = "bot_weeta",
			species = "rodian",
			sex = "female",
			hair = "object/tangible/hair/rodian/hair_rodian_female_s09.iff",
			job = "ranger",
			city = "mos_eisley",
			skills = {"outdoors_ranger_master", "combat_marksman_master", "combat_carbine_ability_04", "combat_carbine_accuracy_02"},
			outfit = {
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_chest_plate.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_leggings.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_bicep_l.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_bicep_r.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_bracer_l.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_bracer_r.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_boots.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_gloves.iff",
				"object/tangible/wearables/armor/chitin/armor_chitin_s01_helmet.iff",
				"object/weapon/ranged/carbine/carbine_ee3.iff",		-- EE-3 (held)
			},
			carry = {"object/tangible/scout/camp/camp_luxury.iff"},
			station = {planet = "tatooine", x = 20.6, z = -0.895, y = 1.9, cell = 1082877, heading = 225},
		},

		-- Phase 6: the people of Varenhal, the player city east of Theed (custom_scripts/bots/city.lua has its plan). Online
		-- only while a human is on Naboo. Until their buildings stand they wait outdoors at the city site, on their own
		-- lots (z 0: the ground height there)

		-- The mayor: Master Politician (no skill points) and Master Architect (92 points with Novice Artisan, the
		-- starting profession), in the Grand Mayoral Robe; waits where the city hall goes
		{
			name = "Aldren Vasche",
			account = "bot_aldren",
			species = "human",
			sex = "male",
			hair = "object/tangible/hair/human/hair_human_male_s26.iff",
			job = "mayor",
			city = "varenhal",
			online = "planet",
			skills = {"social_politician_master", "crafting_architect_master"},
			outfit = {
				"object/tangible/wearables/robe/robe_s12.iff",		-- Grand Mayoral Robe
				"object/tangible/wearables/shoes/shoes_s01.iff",		-- Dress Shoes
			},
			station = {planet = "naboo", x = -3143.0, z = 0, y = 4701.0, cell = 0, heading = 180},
		},
		-- The city's dancer (Master Dancer; she places the cantina at rank 2)
		{
			name = "Talia Marise",
			account = "bot_talia",
			species = "human",
			sex = "female",
			hair = "object/tangible/hair/human/hair_human_female_s38.iff",
			job = "dancer",
			city = "varenhal",
			online = "planet",
			skills = {"social_dancer_master"},
			outfit = {
				"object/tangible/wearables/bikini/bikini_s04.iff",		-- Revealing Top
				"object/tangible/wearables/skirt/skirt_s03.iff",		-- Extremely Revealing Skirt
				"object/tangible/wearables/shoes/shoes_s07.iff",		-- Sandals
				"object/tangible/wearables/necklace/necklace_rosy_pearl.iff",		-- Rosy Pearl
				"object/tangible/wearables/bracelet/bracelet_s03_r.iff",		-- Golden Bracelet
			},
			station = {planet = "naboo", x = -3193.0, z = 0, y = 4700.0, cell = 0, heading = 160},
		},
		-- The city's musician (Master Musician; he places the theater at rank 4)
		{
			name = "Ossin Valcourt",
			account = "bot_ossin",
			species = "bothan",
			sex = "male",
			hair = "object/tangible/hair/bothan/hair_bothan_male_s14.iff",
			job = "musician",
			city = "varenhal",
			online = "planet",
			skills = {"social_musician_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s08.iff",		-- Sidebuttoned Shirt
				"object/tangible/wearables/jacket/jacket_s12.iff",		-- Casual Jacket
				"object/tangible/wearables/pants/pants_s13.iff",		-- Comfortable Slacks
				"object/tangible/wearables/shoes/shoes_s02.iff",		-- Casual Shoes
				"object/tangible/instrument/kloo_horn.iff",		-- Kloo Horn (held)
			},
			station = {planet = "naboo", x = -3196.0, z = 0, y = 4698.0, cell = 0, heading = 140},
		},
		-- The city's doctor (Master Doctor; she places the hospital at rank 3)
		{
			name = "Brynna Solace",
			account = "bot_brynna",
			species = "human",
			sex = "female",
			hair = "object/tangible/hair/human/hair_human_female_s06.iff",
			job = "doctor",
			city = "varenhal",
			online = "planet",
			skills = {"science_doctor_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s28.iff",		-- Dress Blouse
				"object/tangible/wearables/pants/pants_s31.iff",		-- Slacks
				"object/tangible/wearables/jacket/jacket_s03.iff",		-- Long Formal Jacket
				"object/tangible/wearables/shoes/shoes_s08.iff",		-- Women's Shoes
			},
			station = {planet = "naboo", x = -3113.0, z = 0, y = 4700.0, cell = 0, heading = 200},
		},
		-- Six citizens with their own trades. Every one has Novice Artisan, the citizens' starting profession

		-- A weaponsmith (Master Weaponsmith, Master Artisan: 140 points)
		{
			name = "Garvik Thal",
			account = "bot_garvik",
			species = "zabrak",
			sex = "male",
			hair = "object/tangible/hair/zabrak/hair_zabrak_male_s08.iff",
			job = "citizen",
			city = "varenhal",
			online = "planet",
			skills = {"crafting_weaponsmith_master", "crafting_artisan_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s26.iff",		-- Lined Workshirt
				"object/tangible/wearables/pants/pants_s29.iff",		-- Crafter's Pants
				"object/tangible/wearables/apron/apron_s01.iff",		-- Apron
				"object/tangible/wearables/belt/belt_s04.iff",		-- Workman's Belt
				"object/tangible/wearables/gloves/gloves_s11.iff",		-- Workman's Gloves
				"object/tangible/wearables/boots/boots_s04.iff",		-- Hide Boots
			},
			station = {planet = "naboo", x = -3073.0, z = 0, y = 4798.0, cell = 0, heading = 0},
		},
		-- An armorsmith (Master Armorsmith, Master Artisan: 140 points)
		{
			name = "Mareth Kaine",
			account = "bot_mareth",
			species = "human",
			sex = "female",
			hair = "object/tangible/hair/human/hair_human_female_s12.iff",
			job = "citizen",
			city = "varenhal",
			online = "planet",
			skills = {"crafting_armorsmith_master", "crafting_artisan_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s10.iff",		-- Reinforced Work Shirt
				"object/tangible/wearables/pants/pants_s30.iff",		-- Padded Workpants
				"object/tangible/wearables/vest/vest_s09.iff",		-- Cargo Vest
				"object/tangible/wearables/boots/boots_s15.iff",		-- Standard Boots
				"object/tangible/wearables/gloves/gloves_s02.iff",		-- Leather Work Gloves
			},
			station = {planet = "naboo", x = -3233.0, z = 0, y = 4684.0, cell = 0, heading = 180},
		},
		-- A tailor (Master Tailor, Master Artisan: 140 points)
		{
			name = "Mowsha Glenhallow",
			account = "bot_mowsha",
			species = "ithorian",
			sex = "female",
			hair = "",
			job = "citizen",
			city = "varenhal",
			online = "planet",
			skills = {"crafting_tailor_master", "crafting_artisan_master"},
			outfit = {
				"object/tangible/wearables/ithorian/ith_shirt_s02.iff",		-- Ithorian Frilly Shirt
				"object/tangible/wearables/ithorian/ith_jacket_s04.iff",		-- Ithorian Jazzy Jacket
				"object/tangible/wearables/ithorian/ith_skirt_s03.iff",		-- Ithorian Patterned Skirt
				"object/tangible/wearables/ithorian/ith_necklace_s07.iff",		-- Ithorian Emerald Pendant
			},
			station = {planet = "naboo", x = -3193.0, z = 0, y = 4686.0, cell = 0, heading = 180},
		},
		-- A trader (Master Merchant, Master Artisan: 140 points)
		{
			name = "Sarra Venlo",
			account = "bot_sarra",
			species = "bothan",
			sex = "female",
			hair = "object/tangible/hair/bothan/hair_bothan_female_s05.iff",
			job = "citizen",
			city = "varenhal",
			online = "planet",
			skills = {"crafting_merchant_master", "crafting_artisan_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s32.iff",		-- Suit Shirt
				"object/tangible/wearables/jacket/jacket_s11.iff",		-- Suit Jacket
				"object/tangible/wearables/skirt/skirt_s14.iff",		-- Two-Tone Formal Skirt
				"object/tangible/wearables/shoes/shoes_s08.iff",		-- Women's Shoes
				"object/tangible/wearables/necklace/necklace_s09.iff",		-- Silver Pendant
			},
			station = {planet = "naboo", x = -3153.0, z = 0, y = 4686.0, cell = 0, heading = 180},
		},
		-- A hunter (Master Scout, Master Rifleman: 184 points with Novice Artisan), an SG-82 rifle
		{
			name = "Neebo Tulluk",
			account = "bot_neebo",
			species = "rodian",
			sex = "male",
			hair = "object/tangible/hair/rodian/hair_rodian_male_s10.iff",
			job = "citizen",
			city = "varenhal",
			online = "planet",
			skills = {"outdoors_scout_master", "combat_rifleman_master"},
			outfit = {
				"object/tangible/wearables/shirt/shirt_s04.iff",		-- Simple Shirt
				"object/tangible/wearables/jacket/jacket_s07.iff",		-- Scout Jacket
				"object/tangible/wearables/pants/pants_s07.iff",		-- Basic Camos
				"object/tangible/wearables/boots/boots_s04.iff",		-- Hide Boots
				"object/tangible/wearables/backpack/backpack_s01.iff",		-- Travel Pack
				"object/weapon/ranged/rifle/rifle_sg82.iff",		-- SG-82 (held)
			},
			station = {planet = "naboo", x = -3113.0, z = 0, y = 4686.0, cell = 0, heading = 180},
		},
		-- A hunter (Master Creature Handler, Master Ranger: 218 points with Novice Artisan), a bowcaster (Wookiees are
		-- born certified)
		{
			name = "Rrowkarr",
			account = "bot_rrowkarr",
			species = "wookiee",
			sex = "male",
			hair = "",
			job = "citizen",
			city = "varenhal",
			online = "planet",
			skills = {"outdoors_creaturehandler_master", "outdoors_ranger_master"},
			outfit = {
				"object/tangible/wearables/wookiee/wke_shirt_s03.iff",		-- Wookiee Battle Padding
				"object/tangible/wearables/wookiee/wke_skirt_s03.iff",		-- Weighted Waist Wrap
				"object/tangible/wearables/belt/belt_s09.iff",		-- Utility Belt
				"object/tangible/wearables/wookiee/wke_gloves_s04.iff",		-- Wookiee Strapped Gloves
				"object/weapon/ranged/rifle/rifle_bowcaster.iff",		-- Bowcaster (held)
			},
			station = {planet = "naboo", x = -3073.0, z = 0, y = 4684.0, cell = 0, heading = 180},
		},
	},
}
