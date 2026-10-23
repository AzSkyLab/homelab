-- Bot players (Phase 5): the hunting crew (tank, rifleman, medic, ranger) who group with players. Stub until the Phase 5 jobs land.
-- The job module interface is described at the top of bot_jobs.lua.

BotCrew = ScreenPlay:new {
	screenplayName = "BotCrew",
}

function BotCrew:start(pBot, oid)
end

function BotCrew:clear(oid)
end

function BotCrew:tick(pBot, oid, now)
end

function BotCrew:state(pBot, oid)
	return "not built yet"
end

BotJobModules = BotJobModules or {}
BotJobModules.tank = BotCrew
BotJobModules.rifleman = BotCrew
BotJobModules.medic = BotCrew
BotJobModules.ranger = BotCrew
