-- Bot players (Phase 4): the master smuggler who slices armor and weapons by trade. Stub until the Phase 4 jobs land.
-- The job module interface is described at the top of bot_jobs.lua.

BotSmuggler = ScreenPlay:new {
	screenplayName = "BotSmuggler",
}

function BotSmuggler:start(pBot, oid)
end

function BotSmuggler:clear(oid)
end

function BotSmuggler:tick(pBot, oid, now)
end

function BotSmuggler:state(pBot, oid)
	return "not built yet"
end

BotJobModules = BotJobModules or {}
BotJobModules.smuggler = BotSmuggler
