-- Bot players (Phase 6): the player city's mayor. Stub until the Phase 6 jobs land.
-- The job module interface is described at the top of bot_jobs.lua.

BotMayor = ScreenPlay:new {
	screenplayName = "BotMayor",
}

function BotMayor:start(pBot, oid)
end

function BotMayor:clear(oid)
end

function BotMayor:tick(pBot, oid, now)
end

function BotMayor:state(pBot, oid)
	return "not built yet"
end

BotJobModules = BotJobModules or {}
BotJobModules.mayor = BotMayor
