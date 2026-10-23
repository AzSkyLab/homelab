-- Bot players (Phase 5): provoked fights and duels, for every bot. Not a job module: BotJobs calls
-- BotFight:tick(pBot, oid, now) every job tick, BotFight:onReply(pBot, playerOid, flags, channel) after each brain
-- reply (flags from reply line 5, e.g. "insult"), and BotFight:clear(oid) at logout. Stub until the Phase 5 jobs land.

BotFight = ScreenPlay:new {
	screenplayName = "BotFight",
}

function BotFight:tick(pBot, oid, now)
end

function BotFight:onReply(pBot, playerOid, flags, channel)
end

function BotFight:clear(oid)
end
