-- Living Cities: Coronet spots. Sources: snapshot/corellia.ws (tools/snapshot.py), corellia_coronet.lua.
LivingCitiesData = LivingCitiesData or {}

LivingCitiesData.coronet = {
	name = "Coronet",
	planet = "corellia",
	crowd = 25,
	-- world x, y and radius (m) of the area a player counts as "in the city"
	center = {x = -210, y = -4450, radius = 450},
	-- where NPCs log in and out: in front of the starport's west door, outdoors
	arrival = {x = -134, y = -4723, cell = 0, heading = 278},
	spots = {
		-- place: starport | cantina | bank | shops | plaza | medical | hotel
		-- act: stand | pair | sit | dance | terminal | drink
		-- Starport, the street in front of the main (west) door
		{id = "starport_front", place = "starport", slots = {
			{x = -147, y = -4722, cell = 0, heading = 260, act = "stand"},
			{x = -143, y = -4727.5, cell = 0, heading = 90, act = "pair", pair = 3},
			{x = -141.6, y = -4727.5, cell = 0, heading = 270, act = "pair", pair = 2},
			{x = -142.5, y = -4735.5, cell = 0, heading = 300, act = "stand"},
		}},
		-- Starport lobby (foyer4): travel terminals on the south wall, rows of couches in the middle
		{id = "starport_lobby", place = "starport", slots = {
			{x = -2.74, y = 49.97, z = 0.639, cell = 1855675, heading = 180, act = "terminal"},
			{x = 11.44, y = 52.58, z = 0.639, cell = 1855675, heading = 131, act = "terminal"},
			{x = 2.55, y = 49.97, z = 0.639, cell = 1855675, heading = 180, act = "terminal"},
			{x = 4.11, y = 56.33, z = 0.639, cell = 1855675, heading = 180, act = "sit"},
			{x = -2.54, y = 63.4, z = 0.639, cell = 1855675, heading = 0, act = "sit"},
			{x = 13.4, y = 59.8, z = 0.639, cell = 1855675, heading = 0, act = "pair", pair = 7},
			{x = 13.4, y = 61.2, z = 0.639, cell = 1855675, heading = 180, act = "pair", pair = 6},
		}},
		-- Coronet cantina, main room: standing at the bar (south and north sides of the counter)
		{id = "cantina_bar", place = "cantina", slots = {
			{x = -4.5, y = -4.9, z = -0.895, cell = 8105496, heading = 0, act = "drink"},
			{x = -2.7, y = -4.9, z = -0.895, cell = 8105496, heading = 0, act = "drink"},
			{x = -0.9, y = -4.9, z = -0.895, cell = 8105496, heading = 0, act = "drink"},
			{x = -4.6, y = 5.7, z = -0.895, cell = 8105496, heading = 180, act = "drink"},
			{x = 4.4, y = 5.7, z = -0.895, cell = 8105496, heading = 180, act = "drink"},
		}},
		-- Coronet cantina, main room: chairs at the two tables east of the bar
		{id = "cantina_tables", place = "cantina", slots = {
			{x = 14.15, y = 4.25, z = -0.895, cell = 8105496, heading = 53, act = "sit"},
			{x = 17.16, y = 7.75, z = -0.895, cell = 8105496, heading = 226, act = "sit"},
			{x = 14.42, y = 7.4, z = -0.895, cell = 8105496, heading = 140, act = "sit"},
			{x = 16.5, y = -2.36, z = -0.895, cell = 8105496, heading = 233, act = "sit"},
			{x = 13.5, y = -5.86, z = -0.895, cell = 8105496, heading = 46, act = "sit"},
			{x = 16.24, y = -5.51, z = -0.895, cell = 8105496, heading = 320, act = "sit"},
		}},
		-- Coronet cantina, main room: open floor south-west of the bar, by the stage alcove
		{id = "cantina_dance", place = "cantina", slots = {
			{x = -6.8, y = -8.3, z = -0.895, cell = 8105496, heading = 150, act = "dance"},
			{x = -5.3, y = -8.7, z = -0.895, cell = 8105496, heading = 180, act = "dance"},
			{x = -6.4, y = -9.9, z = -0.895, cell = 8105496, heading = 120, act = "dance"},
			{x = -4.9, y = -10.3, z = -0.895, cell = 8105496, heading = 200, act = "dance"},
		}},
		-- Coronet cantina, main room: standing room in the north-east and north-west corners
		{id = "cantina_floor", place = "cantina", slots = {
			{x = 21, y = 9.6, z = -0.895, cell = 8105496, heading = 90, act = "pair", pair = 2},
			{x = 22.4, y = 9.6, z = -0.895, cell = 8105496, heading = 270, act = "pair", pair = 1},
			{x = -11.8, y = 10.4, z = -0.895, cell = 8105496, heading = 90, act = "pair", pair = 4},
			{x = -10.4, y = 10.4, z = -0.895, cell = 8105496, heading = 270, act = "pair", pair = 3},
			{x = 20.6, y = -8.6, z = -0.895, cell = 8105496, heading = 300, act = "stand"},
		}},
		-- Coronet cantina, outside: the street west of the south-west door
		{id = "cantina_front", place = "cantina", slots = {
			{x = -356.5, y = -4545, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -355.1, y = -4545, cell = 0, heading = 270, act = "pair", pair = 1},
		}},
		-- Bank: terminals on the north, east and south faces of the central pillar, plus a pair in the bank square
		{id = "bank", place = "bank", slots = {
			{x = -55.56, y = -4594.03, cell = 0, heading = 180, act = "terminal"},
			{x = -50.29, y = -4599.36, cell = 0, heading = 270, act = "terminal"},
			{x = -55.61, y = -4604.63, cell = 0, heading = 0, act = "terminal"},
			{x = -47, y = -4590.5, z = 28.65, cell = 0, heading = 45, act = "pair", pair = 5},
			{x = -46.01, y = -4589.51, z = 28.65, cell = 0, heading = 225, act = "pair", pair = 4},
		}},
		-- Bazaar terminals on the north, west and east sides of the bank square
		{id = "bazaar", place = "shops", slots = {
			{x = -55.34, y = -4578.81, z = 28.65, cell = 0, heading = 0, act = "terminal"},
			{x = -76.09, y = -4599.34, cell = 0, heading = 270, act = "terminal"},
			{x = -35.1, y = -4599.37, z = 28.65, cell = 0, heading = 90, act = "terminal"},
			{x = -66, y = -4610, cell = 0, heading = 315, act = "stand"},
		}},
		-- The big square north of the Capitol, round the fountain
		{id = "plaza", place = "plaza", slots = {
			{x = -231, y = -4452, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -229.6, y = -4452, cell = 0, heading = 270, act = "pair", pair = 1},
			{x = -200.5, y = -4441, cell = 0, heading = 90, act = "pair", pair = 4},
			{x = -199.1, y = -4441, cell = 0, heading = 270, act = "pair", pair = 3},
			{x = -205, y = -4458.5, cell = 0, heading = 330, act = "stand"},
			{x = -216.5, y = -4436, cell = 0, heading = 160, act = "stand"},
		}},
		-- Medical centre, the street outside its two north doors
		{id = "medical", place = "medical", slots = {
			{x = -93, y = -4410.5, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -91.6, y = -4410.5, cell = 0, heading = 270, act = "pair", pair = 1},
			{x = -86, y = -4408, cell = 0, heading = 180, act = "stand"},
		}},
		-- Hotel, the street in front of its west door, by the planter with benches
		{id = "hotel", place = "hotel", slots = {
			{x = -499.2, y = -4666.5, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -497.8, y = -4666.5, cell = 0, heading = 270, act = "pair", pair = 1},
			{x = -502.6, y = -4672.9, cell = 0, heading = 90, act = "stand"},
			{x = -497, y = -4680.5, cell = 0, heading = 60, act = "stand"},
		}},
	},
}
