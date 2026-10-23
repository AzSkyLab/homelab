-- Bot players (Phase 4): the master musician beside each cantina's dancer. Stub until the Phase 4 jobs land.
-- The job module interface is described at the top of bot_jobs.lua.

BotMusician = ScreenPlay:new {
	screenplayName = "BotMusician",
}

function BotMusician:start(pBot, oid)
end

function BotMusician:clear(oid)
end

function BotMusician:tick(pBot, oid, now)
end

function BotMusician:state(pBot, oid)
	return "not built yet"
end

BotJobModules = BotJobModules or {}
BotJobModules.musician = BotMusician
