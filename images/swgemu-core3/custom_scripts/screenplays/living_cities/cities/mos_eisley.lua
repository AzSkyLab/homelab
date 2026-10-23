-- Living Cities: Mos Eisley spots. Sources: snapshot/tatooine.ws (tools/snapshot.py), tatooine_mos_eisley.lua.
LivingCitiesData = LivingCitiesData or {}

LivingCitiesData.mos_eisley = {
	name = "Mos Eisley",
	planet = "tatooine",
	crowd = 25,
	-- world x, y and radius (m) of the area a player counts as "in the city"
	center = {x = 3480, y = -4810, radius = 450},
	-- where NPCs log in and out: in front of the starport's west door, outdoors
	arrival = {x = 3534, y = -4803, cell = 0, heading = 270},
	-- buildings with indoor slots: every cell id of the building, and the way out through the main door
	buildings = {
		-- Starport: main (west) door, into foyer1; outside past the foot of the entrance ramp
		{id = "starport", cells = {1106369, 1106370, 1106371, 1106372, 1106373, 1106374, 1106375, 1106376, 1106377, 1106378, 1106379, 1106380, 1106381, 1106382, 1106383, 6595536}, exit = {
			inside = {x = -0.18, y = 76.11, z = 0.639, cell = 1106369, heading = 0},
			outside = {x = 3536.4, y = -4802.89, heading = 269},
		}},
		-- Chalmun's cantina: front door, into foyer1
		{id = "cantina", cells = {1082875, 1082876, 1082877, 1082878, 1082879, 1082880, 1082881, 1082882, 1082883, 1082884, 1082885, 1082886, 1082887, 1082888, 1082889}, exit = {
			inside = {x = 46.57, y = -2.49, z = 0.101, cell = 1082875, heading = 135},
			outside = {x = 3467.9, y = -4852.78, heading = 173},
		}},
	},
	spots = {
		-- place: starport | cantina | bank | shops | plaza | medical | hotel
		-- act: stand | pair | sit | dance | terminal | drink
		-- Starport, the street in front of the main (west) door
		{id = "starport_front", place = "starport", slots = {
			{x = 3524.2, y = -4805.5, cell = 0, heading = 250, act = "stand"},
			{x = 3528.6, y = -4808, cell = 0, heading = 90, act = "pair", pair = 3},
			{x = 3530, y = -4808, cell = 0, heading = 270, act = "pair", pair = 2},
			{x = 3531, y = -4812.4, cell = 0, heading = 300, act = "stand"},
		}},
		-- Starport lobby (foyer4): travel terminals on the south wall, chairs round the tables
		{id = "starport_lobby", place = "starport", building = "starport", slots = {
			{x = -2.74, y = 49.97, z = 0.639, cell = 1106372, heading = 180, act = "terminal"},
			{x = 11.29, y = 52.36, z = 0.639, cell = 1106372, heading = 131, act = "terminal"},
			{x = 2.55, y = 49.97, z = 0.639, cell = 1106372, heading = 180, act = "terminal"},
			{x = -11.92, y = 52.63, z = 0.639, cell = 1106372, heading = 217, act = "terminal"},
			{x = 5, y = 62.12, z = 0.639, cell = 1106372, heading = 147, act = "sit"},
			{x = 7.17, y = 59.29, z = 0.639, cell = 1106372, heading = 338, act = "sit"},
			{x = -11.2, y = 60.5, z = 0.639, cell = 1106372, heading = 90, act = "pair", pair = 8},
			{x = -9.8, y = 60.5, z = 0.639, cell = 1106372, heading = 270, act = "pair", pair = 7},
		}},
		-- Chalmun's cantina, main room: standing at the bar (south and north sides of the counter)
		{id = "cantina_bar", place = "cantina", building = "cantina", slots = {
			{x = -6.8, y = -4.9, z = -0.895, cell = 1082877, heading = 0, act = "drink"},
			{x = -5, y = -4.9, z = -0.895, cell = 1082877, heading = 0, act = "drink"},
			{x = -3.2, y = -4.9, z = -0.895, cell = 1082877, heading = 0, act = "drink"},
			{x = -6.7, y = 5.7, z = -0.895, cell = 1082877, heading = 180, act = "drink"},
		}},
		-- Chalmun's cantina, main room: chairs at the two free tables east of the bar
		{id = "cantina_tables", place = "cantina", building = "cantina", slots = {
			{x = 12.25, y = -8.98, z = -0.895, cell = 1082877, heading = 174, act = "sit"},
			{x = 10.89, y = -10.45, z = -0.895, cell = 1082877, heading = 94, act = "sit"},
			{x = 13.51, y = -10.58, z = -0.895, cell = 1082877, heading = 283, act = "sit"},
			{x = 10.16, y = 9.78, z = -0.895, cell = 1082877, heading = 12, act = "sit"},
			{x = 11.26, y = 11.92, z = -0.895, cell = 1082877, heading = 180, act = "sit"},
			{x = 12.12, y = 9.66, z = -0.895, cell = 1082877, heading = 353, act = "sit"},
		}},
		-- Chalmun's cantina, main room: the floor in front of the band's alcove
		{id = "cantina_dance", place = "cantina", building = "cantina", slots = {
			{x = 5, y = -10, z = -0.895, cell = 1082877, heading = 205, act = "dance"},
			{x = 6.5, y = -9.2, z = -0.895, cell = 1082877, heading = 215, act = "dance"},
			{x = 6.6, y = -10.8, z = -0.895, cell = 1082877, heading = 220, act = "dance"},
			{x = 8.1, y = -10, z = -0.895, cell = 1082877, heading = 230, act = "dance"},
			{x = 3.6, y = -11, z = -0.895, cell = 1082877, heading = 195, act = "dance"},
		}},
		-- Chalmun's cantina, main room: standing room west of the band and east of the bar
		{id = "cantina_floor", place = "cantina", building = "cantina", slots = {
			{x = -6.4, y = -8.2, z = -0.895, cell = 1082877, heading = 90, act = "pair", pair = 2},
			{x = -5, y = -8.2, z = -0.895, cell = 1082877, heading = 270, act = "pair", pair = 1},
			{x = 21.2, y = -1.9, z = -0.895, cell = 1082877, heading = 90, act = "pair", pair = 4},
			{x = 22.6, y = -1.9, z = -0.895, cell = 1082877, heading = 270, act = "pair", pair = 3},
			{x = 19.8, y = 10, z = -0.895, cell = 1082877, heading = 200, act = "stand"},
		}},
		-- Chalmun's cantina, outside: the street south-east of the front door
		{id = "cantina_front", place = "cantina", slots = {
			{x = 3472.2, y = -4857.8, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = 3473.6, y = -4857.8, cell = 0, heading = 270, act = "pair", pair = 1},
		}},
		-- Bank: the four terminals on the central pillar of the bank plaza, plus a pair in the plaza
		{id = "bank", place = "bank", slots = {
			{x = 3502.45, y = -4940.15, z = 5.54, cell = 0, heading = 219, act = "terminal"},
			{x = 3503.28, y = -4947.6, cell = 0, heading = 309, act = "terminal"},
			{x = 3495.83, y = -4948.42, cell = 0, heading = 39, act = "terminal"},
			{x = 3495, y = -4940.97, z = 5.54, cell = 0, heading = 129, act = "terminal"},
			{x = 3490.5, y = -4934.8, z = 5.54, cell = 0, heading = 45, act = "pair", pair = 6},
			{x = 3491.49, y = -4933.81, z = 5.54, cell = 0, heading = 225, act = "pair", pair = 5},
		}},
		-- Bazaar terminals at the inner corners of the bank plaza
		{id = "bazaar", place = "shops", slots = {
			{x = 3483.16, y = -4931.47, z = 5.54, cell = 0, heading = 309, act = "terminal"},
			{x = 3511.99, y = -4928.3, z = 5.54, cell = 0, heading = 39, act = "terminal"},
			{x = 3515.06, y = -4957.06, z = 5.54, cell = 0, heading = 129, act = "terminal"},
			{x = 3509, y = -4934, z = 5.54, cell = 0, heading = 230, act = "stand"},
		}},
		-- The open square south of the cantina, between the cantina, the bank and the starport
		{id = "square", place = "plaza", slots = {
			{x = 3472.5, y = -4874.5, cell = 0, heading = 70, act = "pair", pair = 2},
			{x = 3473.82, y = -4874.02, cell = 0, heading = 250, act = "pair", pair = 1},
			{x = 3483.6, y = -4874.8, cell = 0, heading = 120, act = "pair", pair = 4},
			{x = 3484.81, y = -4875.5, cell = 0, heading = 300, act = "pair", pair = 3},
			{x = 3461.5, y = -4870.5, cell = 0, heading = 110, act = "stand"},
			{x = 3489.5, y = -4866, cell = 0, heading = 200, act = "stand"},
		}},
		-- Cafe tables on the little square west of the cantina (three tables, nine chairs)
		{id = "cafe_west", place = "plaza", slots = {
			{x = 3318.62, y = -4849.05, cell = 0, heading = 148, act = "sit"},
			{x = 3321.05, y = -4850.18, cell = 0, heading = 263, act = "sit"},
			{x = 3323.76, y = -4862.87, cell = 0, heading = 148, act = "sit"},
			{x = 3333.25, y = -4860.19, cell = 0, heading = 263, act = "sit"},
			{x = 3326, y = -4855.2, cell = 0, heading = 80, act = "pair", pair = 6},
			{x = 3327.38, y = -4854.96, cell = 0, heading = 260, act = "pair", pair = 5},
		}},
		-- Medical centre, outside its south-west door (the trainers side)
		{id = "medical", place = "medical", slots = {
			{x = 3510.4, y = -4771.4, cell = 0, heading = 125, act = "pair", pair = 2},
			{x = 3511.55, y = -4772.2, cell = 0, heading = 305, act = "pair", pair = 1},
			{x = 3517.4, y = -4775, cell = 0, heading = 215, act = "stand"},
		}},
	},
}
