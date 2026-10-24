-- Bot players (Phase 4): the canned lines of the musician and the smuggler, included from lines.lua. As there,
-- {name} is the player's first name and {city} the bot's city. The smuggler's lines also carry the job's numbers,
-- filled in by smuggler.lua: {armor} and {weapon} (the prices), {price}, {credits}, {missing}, {kind} ("armor" or "a
-- weapon"), {item} (the item's name) and {result} ("+27% effectiveness").

BotLines.musician = {
	-- Made the player its buff target (said only when the model didn't answer first)
	listen = {
		"You're my buff target, {name}. Listen a few minutes and you'll walk out sharp.",
		"Got you, {name}. /listen to me a while; the longer you listen, the longer it lasts.",
		"You're set. Listen at least a minute, more is better.",
		"Buff target set. Pull up a stool and listen.",
		"Done, {name}. Listen to a song or two, then stop listening when you're ready to go.",
	},
	-- Asked from afar (another building, another planet, a tell)
	far = {
		"Come by the cantina in {city} and listen to me play, I'll set you up.",
		"I'm playing in the {city} cantina, right next to the dancer. Come listen and I'll buff you.",
	},
	-- Asked about battle fatigue or healing while the model can't answer
	watchHint = {
		"Just listen a while, the music clears the fatigue.",
		"Grab a seat and listen for a few minutes, you'll feel it lift.",
		"Listen to me and watch the dancer at the same time, it clears twice as fast.",
	},
	fallback = {
		"Can't talk much mid-song, but stick around.",
		"Mm. Listen to this part, friend.",
		"Ask me for a buff if you want one. My hands are a bit busy.",
	},
	thanks = {
		"Thanks for the tip, {name}!",
		"That's going in the instrument fund. Thanks, {name}!",
		"Much appreciated, {name}.",
	},
	thanksAnon = {
		"Thank you kindly!",
		"Thanks, whoever that was!",
	},
}

BotLines.smuggler = {
	-- Asked the price (by keyword, when the model can't answer)
	price = {
		"Armor's {armor} credits a piece, weapons {weapon}. Drag it onto me, credits in the window, and I do the rest.",
		"{armor} for armor, {weapon} for a weapon. Cash in the trade window and I'll make it sing.",
		"Five-percent jobs are for amateurs. Drag it over, {armor} for armor, {weapon} for weapons, and I'll make it sing.",
	},
	-- Asked how slicing works
	howto = {
		"Drag your armor or weapon onto me and I'll open a trade. Put the piece and the credits in, {armor} for armor, {weapon} for weapons. Accept, and it's back in your pack sliced before you blink.",
		"Easy. Drag it onto me, put it in the window with the credits, hit accept. {armor} for armor, {weapon} for a weapon. I use a clamp, so it never fails.",
	},
	-- A trade window opened
	open = {
		"Let's see it. Armor's {armor}, weapons {weapon}. One piece at a time, and stay close or the deal's off.",
		"Alright, put it in the window. {armor} for armor, {weapon} for a weapon. Don't wander off mid-deal.",
		"Business. Put the piece in with the credits, {armor} for armor, {weapon} for weapons. Stay within arm's reach.",
	},
	-- The same customer again within a few minutes
	openAgain = {
		"Go on, put it in.",
		"Back again? Let's see it.",
	},
	-- What's wrong with the offer
	noItem = {
		"I don't see a piece in the window. Armor or a weapon, one at a time.",
		"Nothing in the window yet. Put the piece in.",
	},
	tooMany = {
		"One piece at a time, friend. Take the rest back out.",
		"Whoa, one item. Pull the others out.",
	},
	wrongKind = {
		"I only slice armor and weapons. That {item} is neither.",
		"What am I supposed to do with that {item}? Armor or weapons only.",
	},
	sliced = {
		"This one's been hacked already. Nobody can get more out of it.",
		"Somebody already sliced that {item}. It can't be done twice.",
	},
	-- Armor or a weapon that can't be sliced at all (a Jedi's weapon, say)
	unsliceable = {
		"That {item} can't be sliced. Not by me, not by anybody.",
	},
	short = {
		"That's {credits} credits. For {kind} it's {price}, so you're {missing} short.",
		"I count {credits}. It's {price} for {kind}. Another {missing} and we're in business.",
	},
	-- A weapon with a powerup on it
	powerup = {
		"Heads up: slicing wipes the powerup on that {item}. Pull it out now if you care, otherwise give me a moment.",
		"That {item} has a powerup on it, and the slice burns it off. Last chance to back out.",
	},
	-- The offer is right, waiting for them to accept
	ready = {
		"That'll do. Hit accept when you're ready.",
		"Looks good. Accept and it's done.",
	},
	-- The slice landed; {result} is e.g. "+27% effectiveness"
	result = {
		"Done. {result} on your {item}.",
		"There. Your {item}, {result}. Check your pack.",
		"Clean cut on your {item}: {result}. It's back in your pack.",
	},
	-- After the result
	thanksJob = {
		"Pleasure doing business.",
		"Come back when you've got more.",
		"Tell your friends. Or don't.",
		"Wear it well.",
	},
	-- Their inventory is full: the sliced item comes back in a trade window instead
	giveBack = {
		"Your pack's full, so the {item} comes back in a trade window. Accept it.",
		"No room in your pack. I'm handing the {item} back in a trade, take it.",
	},
	-- That trade went through
	returned = {
		"There, it's yours again.",
		"All yours.",
	},
	-- Core3 turned the trade down (too far apart, no room)
	tradeFailed = {
		"That didn't go through. Stay close, make some room in your pack, and try again.",
	},
	-- The slice couldn't be done (the item and the credits go back)
	failed = {
		"Something went wrong on my end. Your piece is back and so are your credits.",
		"Not today, the tools are acting up. You've got your piece and your credits back.",
	},
	aborted = {
		"Changed your mind? Suit yourself.",
		"No deal, no slice.",
	},
	-- Another customer's trade is open
	busy = {
		"Hang on, {name}, I'm in the middle of a job. One at a time.",
		"Wait your turn, {name}.",
	},
	-- A trade that went nowhere for minutes
	timeout = {
		"I don't have all day. Come back when you're ready.",
	},
	-- It can't slice at all right now
	closed = {
		"Not slicing today, friend. Come back later.",
	},
	fallback = {
		"Got something that needs slicing? Ask me the price.",
		"Talk's cheap. Slicing isn't. Ask me how it works.",
		"Hm? If you're not buying, keep moving.",
	},
	thanks = {
		"Thanks for the extra, {name}.",
		"Generous. I'll remember that, {name}.",
		"Much obliged, {name}.",
	},
	thanksAnon = {
		"Much obliged, whoever you are.",
	},
}

-- Social emotes: the smuggler between jobs (the musician doesn't emote while it plays)
BotLines.smugglerIdle = {"smirk", "lean", "shrug", "tiphat", "flipcoin", "eyebrow", "yawn", "stretch", "sharpen", "twiddle",
	"peer", "thirst", "nod"}
