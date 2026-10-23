-- Living Cities: Theed spots. Sources: snapshot/naboo.ws (tools/snapshot.py), naboo_theed.lua.
LivingCitiesData = LivingCitiesData or {}

LivingCitiesData.theed = {
	name = "Theed",
	planet = "naboo",
	crowd = 25,
	-- world x, y and radius (m) of the area a player counts as "in the city"
	center = {x = -5050, y = 4200, radius = 450},
	-- where NPCs log in and out: in front of the spaceport's south-west door, outdoors
	arrival = {x = -4853.7, y = 4170.3, cell = 0, heading = 221},
	spots = {
		-- place: starport | cantina | bank | shops | plaza | medical | hotel
		-- act: stand | pair | sit | dance | terminal | drink
		-- Spaceport, the plaza in front of the main (south-west) door
		{id = "spaceport_front", place = "starport", slots = {
			{x = -4860.5, y = 4170, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -4859.1, y = 4170, cell = 0, heading = 270, act = "pair", pair = 1},
			{x = -4856, y = 4164.5, cell = 0, heading = 200, act = "stand"},
			{x = -4849, y = 4163, cell = 0, heading = 250, act = "stand"},
		}},
		-- Spaceport lobby and the west hall (hall1): travel terminal, couches
		{id = "spaceport_lobby", place = "starport", slots = {
			{x = -26.95, y = -68.94, z = 0.749, cell = 1692102, heading = 0, act = "terminal"},
			{x = -19, y = -77, z = 0.749, cell = 1692102, heading = 0, act = "sit"},
			{x = -8, y = -65, z = 0.749, cell = 1692101, heading = 90, act = "sit"},
			{x = -17.6, y = -71.5, z = 0.749, cell = 1692102, heading = 90, act = "pair", pair = 5},
			{x = -16.2, y = -71.5, z = 0.749, cell = 1692102, heading = 270, act = "pair", pair = 4},
		}},
		-- Theed cantina, main room: standing at the bar (south and north sides of the counter)
		{id = "cantina_bar", place = "cantina", slots = {
			{x = -4.5, y = -4.9, z = -0.895, cell = 91, heading = 0, act = "drink"},
			{x = -2.7, y = -4.9, z = -0.895, cell = 91, heading = 0, act = "drink"},
			{x = -0.9, y = -4.9, z = -0.895, cell = 91, heading = 0, act = "drink"},
			{x = -4.6, y = 5.7, z = -0.895, cell = 91, heading = 180, act = "drink"},
			{x = 4.4, y = 5.7, z = -0.895, cell = 91, heading = 180, act = "drink"},
		}},
		-- Theed cantina, main room: chairs at the two tables east of the bar
		{id = "cantina_tables", place = "cantina", slots = {
			{x = 14.15, y = 4.25, z = -0.895, cell = 91, heading = 53, act = "sit"},
			{x = 17.16, y = 7.75, z = -0.895, cell = 91, heading = 226, act = "sit"},
			{x = 14.42, y = 7.4, z = -0.895, cell = 91, heading = 140, act = "sit"},
			{x = 16.5, y = -2.36, z = -0.895, cell = 91, heading = 233, act = "sit"},
			{x = 13.5, y = -5.86, z = -0.895, cell = 91, heading = 46, act = "sit"},
			{x = 16.24, y = -5.51, z = -0.895, cell = 91, heading = 320, act = "sit"},
		}},
		-- Theed cantina, main room: the floor in front of the band's alcove
		{id = "cantina_dance", place = "cantina", slots = {
			{x = 4, y = -10.2, z = -0.895, cell = 91, heading = 200, act = "dance"},
			{x = 5.5, y = -9.4, z = -0.895, cell = 91, heading = 210, act = "dance"},
			{x = 6.8, y = -10.6, z = -0.895, cell = 91, heading = 220, act = "dance"},
			{x = 8.2, y = -9.6, z = -0.895, cell = 91, heading = 230, act = "dance"},
			{x = 3, y = -11.6, z = -0.895, cell = 91, heading = 190, act = "dance"},
		}},
		-- Theed cantina, main room: standing room in the north-east and north-west corners
		{id = "cantina_floor", place = "cantina", slots = {
			{x = 21, y = 9.6, z = -0.895, cell = 91, heading = 90, act = "pair", pair = 2},
			{x = 22.4, y = 9.6, z = -0.895, cell = 91, heading = 270, act = "pair", pair = 1},
			{x = -11.8, y = 10.4, z = -0.895, cell = 91, heading = 90, act = "pair", pair = 4},
			{x = -10.4, y = 10.4, z = -0.895, cell = 91, heading = 270, act = "pair", pair = 3},
			{x = 20.6, y = -8.6, z = -0.895, cell = 91, heading = 300, act = "stand"},
		}},
		-- Theed cantina, outside: the plaza east of the front door
		{id = "cantina_front", place = "cantina", slots = {
			{x = -5149, y = 4297, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -5147.6, y = 4297, cell = 0, heading = 270, act = "pair", pair = 1},
		}},
		-- Bank (the one by the cantina): the four terminals on the central pillar, plus a pair in the bank square
		{id = "bank", place = "bank", slots = {
			{x = -5135.24, y = 4163.32, cell = 0, heading = 130, act = "terminal"},
			{x = -5127.77, y = 4163.92, cell = 0, heading = 220, act = "terminal"},
			{x = -5127.17, y = 4156.45, cell = 0, heading = 310, act = "terminal"},
			{x = -5134.64, y = 4155.85, cell = 0, heading = 40, act = "terminal"},
			{x = -5139, y = 4152, cell = 0, heading = 40, act = "pair", pair = 6},
			{x = -5138.1, y = 4153.07, cell = 0, heading = 220, act = "pair", pair = 5},
		}},
		-- Bazaar terminals in the plaza north-east of the medical centre
		{id = "bazaar", place = "shops", slots = {
			{x = -5017.02, y = 4245.99, cell = 0, heading = 310, act = "terminal"},
			{x = -5013.13, y = 4250.56, cell = 0, heading = 310, act = "terminal"},
			{x = -5009.24, y = 4255.13, cell = 0, heading = 310, act = "terminal"},
			{x = -5006, y = 4246, cell = 0, heading = 300, act = "stand"},
		}},
		-- The big open plaza north-east of the medical centre, between it and the cantina and spaceport
		{id = "plaza", place = "plaza", slots = {
			{x = -5000, y = 4230, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -4998.6, y = 4230, cell = 0, heading = 270, act = "pair", pair = 1},
			{x = -4993, y = 4248, cell = 0, heading = 120, act = "pair", pair = 4},
			{x = -4991.79, y = 4247.3, cell = 0, heading = 300, act = "pair", pair = 3},
			{x = -5008, y = 4220, cell = 0, heading = 30, act = "stand"},
			{x = -4988, y = 4232, cell = 0, heading = 250, act = "stand"},
		}},
		-- Medical centre, outside its north-east door
		{id = "medical", place = "medical", slots = {
			{x = -4986.66, y = 4168.19, cell = 0, heading = 40, act = "pair", pair = 2},
			{x = -4985.76, y = 4169.26, cell = 0, heading = 220, act = "pair", pair = 1},
			{x = -4991.47, y = 4172.88, cell = 0, heading = 40, act = "stand"},
		}},
		-- Hotel (the one by the medical centre), the street in front of its south-west door
		{id = "hotel", place = "hotel", slots = {
			{x = -5091, y = 4078, cell = 0, heading = 90, act = "pair", pair = 2},
			{x = -5089.6, y = 4078, cell = 0, heading = 270, act = "pair", pair = 1},
			{x = -5085, y = 4068.5, cell = 0, heading = 220, act = "stand"},
		}},
	},
}
