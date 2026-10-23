-- Bot players (Phase 3): the canned lines of their jobs. The language model (the talk bridge) does the chatting; these
-- are what a doctor or a dancer says while working, and what they say when the model can't answer.
-- {name} is the player's first name, {city} the bot's city. Lines stay in the setting: no out-of-world words.

BotLines = {
	cityNames = {mos_eisley = "Mos Eisley", coronet = "Coronet", theed = "Theed"},

	doctor = {
		-- Starting a buff the player asked for (said only when the model didn't answer first)
		buffStart = {
			"Hold still, {name}. Buffs coming up.",
			"Sure thing. Stand still a moment.",
			"One full set of enhancements, coming up.",
			"Coming right up. Don't wander off.",
			"Stand right there, this takes about a minute.",
		},
		-- Out of reach, but in the room
		closer = {
			"Come a little closer, {name}. I can't reach you from there.",
			"Step in closer, you're out of reach.",
			"You'll need to stand next to me for this.",
			"Closer, please. These packs don't throw.",
		},
		-- Not in the room (another building, another planet, a tell from afar)
		far = {
			"Come by the medical center in {city} and I'll fix you up.",
			"I'm at the {city} med center, by the trainer. Swing by.",
			"Find me in the {city} medical center and I'll take care of you.",
		},
		-- The patient walked off mid-buff
		wandered = {
			"Hey, you wandered off. Come back if you want the rest.",
			"Where'd you go? Come back and I'll finish up.",
		},
		buffDone = {
			"All set. That should hold you about three hours.",
			"There you go, full set.",
			"Done. Go get 'em.",
			"That's the lot. Good hunting.",
		},
		-- Now and then after a buff
		tip = {
			"Tips appreciated!",
			"Tips keep the packs stocked, if you're feeling generous.",
			"Buffs are free, but tips are always welcome.",
			"All done. Tips appreciated, never required.",
		},
		woundsStart = {
			"Let's patch those wounds up.",
			"Hold still, I'll take care of those wounds.",
			"Those wounds look nasty. Stand still.",
		},
		noWounds = {
			"You look fine to me, no wounds to treat.",
			"No wounds on you that I can see.",
			"You're in one piece already. Want a buff instead?",
		},
		woundsDone = {
			"Good as new.",
			"That's all of them. Try to keep it that way.",
			"All patched up.",
		},
		-- Someone else is being treated
		busy = {
			"Be right with you, {name}. One at a time.",
			"Hang on, {name}, I'm with someone. You're next.",
			"Give me a minute, {name}, you're in line.",
		},
		full = {
			"I've got a line already, {name}. Ask me again in a few minutes.",
		},
		-- Asked about battle fatigue or mind while the model can't answer
		notMine = {
			"Battle fatigue's a job for the dancers in the cantina.",
			"For that you want an entertainer. Try the cantina.",
		},
		-- The model can't answer and nothing was asked for: one of these, then a quiet minute
		fallback = {
			"Sorry, I'm counting packs. Need a buff? Just ask.",
			"Hmm? Busy here. If you want buffs, just say so.",
			"Can't chat right now. Buffs and wound care, though, any time.",
		},
		thanks = {
			"Thanks for the tip, {name}!",
			"Much appreciated, {name}.",
			"Thank you kindly, {name}. Come back any time.",
		},
		thanksAnon = {
			"Thank you kindly!",
			"Much appreciated, whoever that was.",
		},
	},

	dancer = {
		-- Made the player its buff target (said only when the model didn't answer first)
		watch = {
			"You're my buff target, {name}. Watch me a few minutes and you'll get the full buff.",
			"Got you, {name}. Watch me for a while; the longer you watch, the longer it lasts.",
			"You're set. Watch at least a minute, more is better.",
			"Buff target set. Pull up a seat and watch.",
		},
		far = {
			"Come by the cantina in {city} and watch me, I'll set you up.",
			"I'm dancing in the {city} cantina. Come watch and I'll buff you.",
		},
		-- Asked about battle fatigue or healing while the model can't answer
		watchHint = {
			"Just watch me a while, that'll clear the fatigue.",
			"Watch for a few minutes and you'll feel better.",
		},
		notMine = {
			"Wounds are a doctor's work. Try the medical center.",
		},
		fallback = {
			"Can't talk much while I'm dancing, but stick around.",
			"Mm-hm. Watch the show, friend.",
			"Ask me for a buff if you want one. I'm a little busy right now.",
		},
		thanks = {
			"Thanks for the tip, {name}!",
			"Aw, thank you, {name}.",
			"Much appreciated, {name}!",
		},
		thanksAnon = {
			"Thank you kindly!",
			"Thanks, whoever that was!",
		},
	},

	-- Social emotes
	doctorIdle = {"stretch", "yawn", "ponder", "scratch", "fidget", "sigh", "adjust", "tap", "contemplate", "nod"},
	dancerIdle = {},
}

-- A random line of a kind for a job, with {name} and {city} filled in; nil if there is none
function BotLines:pick(job, kind, name, city)
	local lines = self[job] ~= nil and self[job][kind] or nil

	if lines == nil or #lines == 0 then
		return nil
	end

	local line = lines[getRandomNumber(1, #lines)]
	local cityName = self.cityNames[city or ""] or "town"

	line = line:gsub("{name}", function() return name or "friend" end)
	line = line:gsub("{city}", function() return cityName end)

	return line
end
