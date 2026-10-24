-- Bot players (Phase 5): the hunting crew's canned lines (crew.lua), included from crew.lua. The language model does
-- the chatting; these are what a crew member says on the job, and what it says when the model can't answer.
-- {name} is the player's first name, {city} the bot's city; the ranger's track lines also fill {tracks} and {what}.
-- Lines stay in the setting: no out-of-world words. BotCrew looks a kind up under the bot's role first (tank,
-- rifleman, medic, ranger), then under crew.

BotLines.crew = {
	-- Just joined the group (group chat)
	joined = {
		"Hey all.",
		"Ready when you are.",
		"Alright, where are we headed?",
		"Good to go.",
		"Let's go get some.",
		"Here. Lead on.",
	},
	-- Asked to come along by someone not in a group: the bot sends the invite (and hands them the lead after)
	inviteSent = {
		"Sure, sent you an invite.",
		"Invite's out, {name}. Accept it and let's go.",
		"Sending you an invite now.",
	},
	-- Asked by someone already in a group: they have to invite
	askInvite = {
		"Sure, send me an invite.",
		"Count me in. Invite me, {name}.",
		"I'm in. Toss me an invite.",
	},
	alreadyWith = {
		"I'm already with you, {name}.",
		"Already in your group, {name}.",
	},
	otherGroup = {
		"I'm running with a group already. Maybe later.",
		"Got a group already, sorry.",
	},
	notWith = {
		"I'm not with you, friend.",
		"We're not grouped, {name}.",
	},
	-- Orders
	follow = {
		"On you.",
		"Right behind you.",
		"Following.",
		"Lead the way.",
	},
	backOff = {
		"Backing off.",
		"Pulling back.",
		"Alright, disengaging.",
	},
	stay = {
		"Holding here.",
		"I'll wait here.",
		"Staying put.",
	},
	attack = {
		"On it.",
		"Engaging.",
		"Taking it down.",
		"Going in.",
	},
	-- Told to attack with nothing of theirs to attack (no target, dead, too far, a player or one of the group)
	attackNoTarget = {
		"Target something first, {name}.",
		"What am I hitting?",
		"Which one, {name}? Mark it first.",
	},
	home = {
		"Heading back to the cantina. Good hunting, {name}.",
		"I'm off. Holler if you need a hand again.",
		"Calling it. See you around, {name}.",
	},
	-- Dismissed or the group broke up (said out loud, if the leader is near)
	bye = {
		"Guess that's it. See you around.",
		"Back to the cantina for me.",
		"Good hunt. Later.",
	},
	-- Dying, cloning, getting back up (group chat)
	down = {
		"I'm down!",
		"I'm dead. Rez?",
		"Down. Anyone got a rez?",
	},
	cloned = {
		"Cloned. On my way back.",
		"Back from the cloner, heading your way.",
		"That hurt. Coming back to you.",
	},
	revived = {
		"Thanks, doc.",
		"Back up. Thanks.",
		"Up again, thanks.",
	},
	-- Looting what the group killed (group chat). One corpse: {creature} (the bare name) and {items} (what came off it,
	-- "a Tusken Spear, a Power Core and 2 more"); several together: {n} corpses; {credits} (" and 85 credits for the
	-- group", or nothing) ends the line
	lootedOne = {
		"Looted the {creature}: {items}{credits}.",
		"Searched the {creature}: {items}{credits}.",
		"Off the {creature}: {items}{credits}.",
	},
	lootedMany = {
		"Looted {n} bodies: {items}{credits}.",
		"Searched {n} corpses: {items}{credits}.",
		"Went through {n} bodies: {items}{credits}.",
	},
	lootedNothing = {
		"Nothing worth taking on the {creature}{credits}.",
		"The {creature} had nothing on it{credits}.",
	},
	lootedNothingMany = {
		"Searched {n} bodies, nothing worth taking{credits}.",
		"{n} bodies and nothing on them{credits}.",
	},
	-- Asked to loot or harvest ({n} corpses found in reach, {name} the player)
	lootAsk = {
		"On it, {n} bodies to go through.",
		"Looting. {n} bodies around here.",
		"Right, {n} bodies to search.",
	},
	lootAskNone = {
		"Nothing left to loot around here.",
		"Everything's been searched, {name}.",
		"No bodies of ours left to search.",
	},
	harvestAsk = {
		"Skinning them. {n} to do.",
		"On it, {n} carcasses to work.",
		"Harvesting. {n} to go.",
	},
	harvestAskNone = {
		"Nothing left to skin here, {name}.",
		"No carcasses left to harvest around here.",
	},
	-- Handing the loot over by trade ({goods} is what's in the trade, {name} the player). Accept the window
	handover = {
		"{goods}. Accept the trade.",
		"Here you go, {name}: {goods}. Accept the trade.",
		"{goods}. Trade's open.",
		"Your share, {name}. {goods}. Accept the trade.",
	},
	-- A first trade that wasn't all of it
	handoverPart = {
		"{goods}, and more after that. Accept the trade.",
		"That's what fits, {name}: {goods}. I've more for when you've made room.",
	},
	-- The next trade
	handoverRest = {
		"The rest, {name}: {goods}. Accept the trade.",
		"And the last of it: {goods}.",
	},
	-- Opening the trade because the bot's pack is full
	handoverFull = {
		"My pack's full, {name}. {goods}. Accept the trade.",
		"No room left in my pack. {goods}: take it off me.",
	},
	-- Holding goods from before when regrouped
	holding = {
		"Still carrying your loot from last time: {goods}.",
		"Got {goods} in my pack from before, {name}. Taking it over.",
	},
	handoverNone = {
		"Nothing on me, {name}.",
		"My pack's empty of loot.",
		"Haven't got anything for you.",
	},
	handoverRoom = {
		"Your pack's full, {name}. Make some room and ask again.",
		"No space in your pack, {name}. Clear some out and say the word.",
	},
	handoverCancelled = {
		"Alright, I'll hang on to it.",
		"No trade? I'll keep it safe until you want it.",
	},
	-- Now and then in the cantina, with someone near, while looking for a group
	lfg = {
		"Anyone heading out to hunt? Looking for a group.",
		"LFG, anyone hunting tonight?",
		"Anyone need an extra gun out there?",
		"Got time for a hunt if anyone's going out.",
	},
	-- Destroy missions (crew_missions.lua), group chat. {dir} is the direction asked, {list} the lairs it took ("womp
	-- rat lair 1.8 km out, 4,300; ..."), {count} "one" or "two", {lairs} "lair" or "lairs"
	missionTook = {
		"Took {count} {dir}: {list}.",
		"{Count} {dir} {lairs} for me: {list}.",
		"Got {count} to the {dir}: {list}.",
		"{Count} {lairs} {dir}. {list}.",
	},
	-- Short of the asked direction after the last list, it took the best within 90 degrees: {dir} the asked direction,
	-- {where} where the lairs lie ("northeast", "north and east"), {count}, {Count} and {list} as for missionTook
	missionWide = {
		"Nothing due {dir}. Took {count}, {where}: {list}.",
		"Not much {dir} on that terminal; {count} {where} instead: {list}.",
		"Couldn't fill {dir}, so {Count} {where}: {list}.",
	},
	-- ...asked for any direction or the nearest ({dir} is "any direction" or "nearby")
	missionTookAny = {
		"Took {count} ({dir}): {list}.",
		"{Count} {lairs}, {dir}: {list}.",
		"Got {count}, {dir}: {list}.",
	},
	missionNoneAny = {
		"That terminal has no destroy missions for me, {name}. Tried {tries} lists.",
		"Nothing on offer at all after {tries} refreshes, {name}.",
	},
	missionNone = {
		"Nothing worth taking {dir} on that terminal. Tried {tries} lists.",
		"No lair {dir} on offer after {tries} refreshes, {name}.",
		"Couldn't find a lair {dir}. The terminal had nothing for me.",
	},
	missionFull = {
		"I'm carrying two already: {list}.",
		"My hands are full, {name}: {list}.",
	},
	missionWhere = {
		"Which way, {name}? North, south, east, west, in between, or any.",
		"Missions in what direction, {name}?",
	},
	missionNoTerminal = {
		"No mission terminal near here, {name}.",
		"I don't see a mission terminal close by.",
	},
	missionLost = {
		"Couldn't get to the terminal. Skipping the missions.",
		"Never made it to the mission terminal. Maybe later.",
	},
	missionCombat = {
		"Not while we're fighting!",
		"Ask me again when this is over.",
	},
	missionDropped = {
		"Dropped {count}.",
		"Scrapped {count}, {name}.",
		"Missions dropped.",
	},
	missionNoneHeld = {
		"I haven't got any.",
		"Nothing to drop.",
	},
	-- Asked for something that's another crew member's work
	notMine = {
		"That's not my line of work. Ask the others.",
	},
	-- Swoops (crew_swoop.lua), group chat: the leader mounted, got off, a fight started, or the swoop won't take
	swoopMount = {
		"Mounting up.",
		"Calling my swoop.",
		"Right behind you.",
		"Swoop's coming.",
		"On my bike.",
	},
	swoopOff = {
		"Parking the swoop.",
		"Off the bike.",
		"Stowing my swoop.",
		"Walking from here.",
	},
	swoopFight = {
		"Off the bike!",
		"Getting down to fight.",
		"Contact! Off the swoop.",
		"Dismounting, covering you.",
	},
	swoopFail = {
		"Can't get my swoop going here. I'll run.",
		"Swoop won't take. Catching up on foot.",
		"No room for my bike here. Running.",
	},
	-- The model can't answer and nothing was asked for: one of these, then a quiet minute
	fallback = {
		"Hm?",
		"Say again?",
		"Ready when you are.",
		"Sure, whatever you say.",
	},
}

BotLines.tank = {
	-- Opening a fight (group chat, now and then)
	pull = {
		"Pulling!",
		"I've got its attention.",
		"On it. Stay behind me.",
	},
	fallback = BotLines.crew.fallback,
}

BotLines.rifleman = {
	fallback = BotLines.crew.fallback,
}

BotLines.medic = {
	reviving = {
		"Hang on, {name}, coming to get you up.",
		"Hold on, {name}, rez incoming.",
		"Don't go anywhere, {name}. Getting you up.",
	},
	-- Asked for buffs where there's no camp or medical centre
	noSite = {
		"Not out here. Get our ranger to throw down a camp and I'll do the full set.",
		"I need a camp or a med center for buffs, {name}.",
	},
	-- In camp, the leader is too far from the fire
	campCome = {
		"Come sit by the fire, {name}, and I'll buff you up.",
		"Over here by the fire, {name}. Buffs.",
	},
	-- Asked for buffs mid-fight
	inCombat = {
		"Not now, we're in a fight!",
		"Ask me again when this thing's dead.",
	},
	fallback = BotLines.crew.fallback,
}

BotLines.ranger = {
	-- After harvesting: {creature} (the bare name) and {what} ("373 Tatooinian Herbivore Meat"); several carcasses:
	-- {n} of them, {what} the totals
	harvestedOne = {
		"Skinned the {creature}: {what}.",
		"Got {what} off the {creature}.",
		"Harvested the {creature}: {what}.",
	},
	harvestedMany = {
		"Skinned {n} carcasses: {what}.",
		"Harvested {n} of them: {what}.",
		"That's {n} carcasses worked: {what}.",
	},
	campUp = {
		"Camp's up. Sit by the fire a while.",
		"There, a fire. Rest up.",
		"Camp's down. Take a load off.",
	},
	-- Offered when the group is wounded (group chat)
	campOffer = {
		"We're pretty beat up. Want me to throw down a camp?",
		"Rough going. Camp for a bit?",
		"Could use a fire and a rest. Camp?",
	},
	campCombat = {
		"Not while we're fighting!",
		"Kill this thing first, then we rest.",
	},
	campIndoors = {
		"I can't build a fire in here. Let's get outside.",
	},
	campFail = {
		"Can't get a camp going here. Too close to town, maybe.",
		"Ground's no good here. Let's move a bit and try again.",
	},
	-- botPlaceCamp's reasons
	campWater = {
		"Too wet here for a camp. Let's find dry ground.",
		"No camp in the water. Move a bit and ask again.",
	},
	campCity = {
		"Too close to town for a camp. Let's get further out.",
		"Can't camp this near a city. Move on a bit.",
	},
	campCrowded = {
		"Too close to a building or another camp. Move a bit and ask again.",
		"Ground's taken here. Let's go a little further and try again.",
	},
	campLair = {
		"There's a lair too close for a camp. Let's move off a bit.",
		"I won't camp by a lair. Further out.",
	},
	-- Refused for a lair (or a camp or building) close by: the ranger goes looking
	campSearchLair = {
		"Lair's too close here. Hang on, I'll find us clear ground.",
		"Not by a lair. Give me a minute to find a better spot.",
	},
	campSearch = {
		"Ground's taken here. Let me find somewhere clear.",
	},
	-- Placed out there: {metres} and {way} from the leader
	campUpThere = {
		"Camp's up, {metres} metres {way}. Come on over.",
		"Found a spot. Fire's going {metres} metres {way} of you.",
	},
	campSearchFail = {
		"No clear ground anywhere near. We'll have to move on and try somewhere else.",
	},
	campAlready = {
		"Camp's already up. Sit down.",
	},
	-- Tracking: {tracks} is the list of what it found, {what} the creature asked for
	trackNone = {
		"Quiet. Nothing around worth the walk.",
		"No fresh sign anywhere near.",
	},
	trackFound = {
		"Tracks around here: {tracks}.",
		"Fresh sign: {tracks}.",
		"I see {tracks}.",
	},
	trackNoMatch = {
		"No sign of {what} around here. There's {tracks}.",
		"No {what} near us. I've got {tracks}.",
	},
	fallback = BotLines.crew.fallback,
}
