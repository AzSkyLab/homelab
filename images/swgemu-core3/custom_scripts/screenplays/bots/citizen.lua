-- Bot players (Phase 6): the player city's citizens. Stub until the Phase 6 jobs land.
-- The job module interface is described at the top of bot_jobs.lua.

BotCitizen = ScreenPlay:new {
	screenplayName = "BotCitizen",
}

function BotCitizen:start(pBot, oid)
end

function BotCitizen:clear(oid)
end

function BotCitizen:tick(pBot, oid, now)
end

function BotCitizen:state(pBot, oid)
	return "not built yet"
end

BotJobModules = BotJobModules or {}
BotJobModules.citizen = BotCitizen
