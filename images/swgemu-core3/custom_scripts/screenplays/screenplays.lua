-- Our additions to Core3 (homelab images/swgemu-core3/custom_scripts). Core3's screenplays.lua includes this file
-- last; paths are relative to scripts/screenplays/.
includeFile("../custom_scripts/screenplays/living_cities/living_cities.lua")
includeFile("../custom_scripts/screenplays/living_cities/talk.lua")
-- Bot players (Phase 3): the roster (also read by the C++ BotManager), then their jobs
includeFile("../custom_scripts/bots/roster.lua")
includeFile("../custom_scripts/screenplays/bots/bot_jobs.lua")
