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
	-- Looting what the group killed (group chat; {n} items now in the pack)
	looted = {
		"Looted it.",
		"Corpse is picked clean.",
		"Got what was on it.",
		"Looted. It's in my pack.",
		"Searched the body.",
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
	-- Asked for something that's another crew member's work
	notMine = {
		"That's not my line of work. Ask the others.",
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
	-- After harvesting a creature ({amount} units of {what}, a kind of {kind})
	harvested = {
		"Skinned it: {amount} {what}.",
		"Got {amount} {what} off that one.",
		"{amount} units of {what} from the carcass.",
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
