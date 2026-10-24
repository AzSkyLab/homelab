-- Bot players (Phase 5): what any bot says around a provoked fight or a duel (fight.lua), included from lines.lua.
-- {name} is the player's first name, {city} the bot's city. The language model does the trash talk; these are the
-- bot's own lines at the turns of a fight, said whether or not the model is running.

BotLines.fight = {
	-- The insult before the last one: the warning
	warn = {
		"Watch your mouth, {name}. Say that one more time.",
		"One more word, {name}, and we settle this right here.",
		"Keep it up, {name}. I dare you.",
		"Careful. Next time you open your mouth, I'm closing it.",
	},
	-- Insulted from too far away to fight (a tell, across town)
	faceMe = {
		"Big talk from far away, {name}. Come say that to my face.",
		"Brave over comms. Say it in person.",
	},
	-- The fight starts
	start = {
		"That's it. You and me, {name}, right now.",
		"You want a fight? You've got one.",
		"Alright, {name}. Let's go.",
		"Enough. Come here.",
	},
	-- The player went down
	gloat = {
		"Stay down, {name}. Next time, mind your manners.",
		"That's what you get. Go find a doctor.",
		"Hah. Get up when you've learned some respect.",
		"Kriff off and heal up, {name}.",
	},
	-- The bot went down
	sulk = {
		"Lucky shot. Don't get used to it.",
		"Fine. You win this one. Doesn't make you any less of a nerf herder.",
		"Ow. Alright, alright. Point made.",
		"Sithspit. Enjoy it while it lasts, {name}.",
	},
	-- It broke off with nobody down (they ran, or it dragged on)
	ended = {
		"Running off? Figures.",
		"Done already? Thought so.",
		"That's enough. Walk away, {name}.",
	},
	-- Duels
	duelAccept = {
		"A duel? You're on, {name}.",
		"Alright. First one down loses.",
		"Sure. Try not to cry, {name}.",
	},
	duelWon = {
		"Good fight, {name}. Better luck next time.",
		"And that's that. Want a doctor?",
	},
	duelLost = {
		"Good fight. You got me.",
		"Ugh. Nicely done, {name}.",
	},
	duelEnded = {
		"Calling it off? Fine by me.",
	},
	-- A duel or another fight too soon after the last one with that player
	tooSoon = {
		"Not again so soon, {name}. Give it a few minutes.",
		"I've had enough of you for now. Ask me later.",
	},
	-- Already fighting someone else
	-- A duel asked by someone who'd die at the next incap (two in the last ten minutes)
	tooHurt = {
		"You can barely stand, {name}. Get patched up first, then we'll see.",
		"Not like that. Go see a medic and come back when you can take a hit.",
	},
	busy = {
		"Busy right now. Ask me later.",
	},
}

-- Social emotes at the turns of a fight
BotLines.fightEmotes = {
	start = {"throwdown", "provoke", "glare"},
	gloat = {"gloat", "flex", "chestpound", "laugh"},
	sulk = {"sulk", "pout", "fume", "scowl"},
}
