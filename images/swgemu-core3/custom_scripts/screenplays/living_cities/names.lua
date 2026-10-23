-- Living Cities: names for the crowd, in the style players picked on a 2004 server. A first name is unique per city
-- while its owner is in town (Phase 2 lets players call an NPC by it). Species without a list here use the general one.
--
-- Reserved for the bot players (custom_scripts/bots/roster.lua), so never in these lists: Hesk Torlan, Neela Kaavo,
-- Doran Halcott, Selka Marrovan, Ilyra Seawell, Saela Dawnmere. A first name a player calls out means one character.
LivingCitiesNames = {
	first = {
		"Aren", "Bela", "Corvan", "Dahla", "Davin", "Eris", "Faela", "Garen", "Halia", "Ivo", "Jaela", "Jarek", "Kael",
		"Kira", "Landry", "Lira", "Maro", "Nessa", "Orin", "Pell", "Quin", "Rhea", "Rorik", "Tavik", "Teva",
		"Ulric", "Vara", "Venn", "Wes", "Xara", "Yorin", "Zara", "Ardo", "Brisa", "Cael", "Dax", "Elan", "Fenn", "Gella",
		"Jaro", "Kesh", "Lorn", "Mira", "Nalo", "Oska", "Pira", "Raen", "Sorin", "Tamsin", "Ula",
		"Varek", "Wren", "Yana", "Zev", "Alys", "Bram", "Cira", "Deln", "Essa", "Galt", "Hana", "Isko", "Jessa", "Korr",
		"Lusa", "Mott", "Nira", "Oren", "Pax", "Remy", "Siva", "Tor", "Vela", "Wynn", "Yarro", "Zelle", "Ansel", "Breck",
		"Cassa", "Eila", "Ferro", "Gavin", "Holt", "Imra", "Juno", "Kade", "Lyse", "Marn", "Nyla", "Orsk", "Perrin",
		"Rissa", "Tobin", "Vex", "Willa", "Yeva", "Zander", "Aleka", "Bastian", "Celia", "Dorn", "Elwen", "Jaxen",
		"Kerra", "Luthe", "Maddox", "Rook", "Shae", "Talon", "Vix",
	},
	last = {
		"Vosk", "Darklin", "Merrik", "Sunrider", "Tarrant", "Holloway", "Venn", "Kessler", "Draven", "Corwin", "Starling",
		"Thorne", "Vael", "Rendar", "Malrek", "Okuda", "Brask", "Calder", "Dunmore", "Everin", "Fallow", "Grael", "Hask",
		"Ironwood", "Jandor", "Kell", "Lorne", "Marsh", "Nightwind", "Orlo", "Pryce", "Quell", "Raskin", "Sarno", "Telgar",
		"Ulvane", "Varn", "Wexley", "Yorke", "Zand", "Arkwell", "Bellamy", "Cross", "Dace", "Embry", "Farrow", "Gant",
		"Harlan", "Ives", "Jaxon", "Krayne", "Lockhart", "Madreth", "Norvan", "Odar", "Pell", "Quarrel", "Ryland", "Sable",
		"Tanvar", "Udo", "Voss", "Wilder", "Xander", "Yarrow", "Zeller", "Antrell", "Brightwater", "Cade", "Delvar",
		"Estrin", "Fendrel", "Greystone", "Hollis", "Ithane", "Jorvik", "Kaldor", "Larsen", "Mirren", "Nash", "Ostrand",
		"Parrin", "Rourke", "Stavros", "Tavell", "Ursen", "Valen", "Wyke", "Yeager", "Zorn", "Ashgrove", "Blackwell",
		"Coldwater", "Duskmane", "Emberly", "Frost", "Galeway", "Hawke", "Kestrel", "Longshot", "Moonraker", "Redhand",
		"Stormcrow", "Tallow", "Vantor", "Windrunner",
	},
	-- Wookiee players mostly went for growly names
	wookiee = {
		first = {"Rrawrok", "Chalarr", "Gorrwa", "Lowrakk", "Wrrorr", "Kallaarr", "Grrakk", "Mahrrok", "Tarrgal", "Oorrak",
			"Wuhrr", "Raakkar", "Arrgok", "Hrrowl", "Kirrbak", "Shyyrr", "Grawwk", "Rrooka", "Lummrak", "Warrnok"},
		last = {"Kashyyyk", "Rwookrrorro", "Kachirho", "Wroshyr", "Shadowlands", "Arrbacca", "Grrowl", "Hrrawr"},
	},
	trandoshan = {
		first = {"Sskarr", "Garrsk", "Vossk", "Ssorak", "Krassk", "Tessak", "Brassk", "Ssirra", "Hssik", "Grassk", "Rrask",
			"Zassk"},
		last = {"Dosshan", "Clawborn", "Ssirruk", "Hsskor", "Sharptooth", "Tessken"},
	},
	ithorian = {
		first = {"Holmaw", "Oraw", "Tomla", "Herba", "Ugmaw", "Nusa", "Fawla", "Tarmaw", "Eshmaw", "Gomaw", "Rinawa", "Ulmaw"},
		last = {"Nadrel", "Tafanda", "Bayhaven", "Moonglade", "Fernhollow", "Treesong"},
	},
}
