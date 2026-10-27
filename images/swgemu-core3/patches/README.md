# Our C++ patches to Core3

Core3 is built from upstream at `CORE3_REF` (see `../Dockerfile`). Our C++ goes in two places:

- **`bots/`**: our own source files. They are copied to `MMOCoreORB/src/server/zone/managers/bot/`, and Core3's
  `file(GLOB_RECURSE ...)` picks them up, so CMake needs no change. These are the bot players: characters the server
  plays itself (spec: `~/github/swgemu/specs/2026-10-23-bot-players/`).
  Phase 7 adds `BotMission.*` / `BotMissionLua.*` (destroy missions through Core3's own list, accept and abort, and
  their waypoints in the group leader's datapad; no upstream hook).
  Phase 9 (Part 1, own crews) adds the one-line hook `0010` above and `BotCrews.*` (the own-crews file `/data/bots/crews.lua`, read at boot after `roster.lua` and
  written atomically after each hire and let-go; a hired bot's doctrine seed; the owner's box count) and `BotCrewsLua.*`
  (`botCrewOf`, `botHire`, `botLetGo`, `botOwner`, `botNameFree`, `botNameCheck`, `botBoxCount`, `botEntry`). `BotManager` adds
  and removes bots at runtime (`hire`, `letGo`, the online rule `"owner"`), `BotFactory` reads an entry with its owner, look
  (hair and skin palette indexes) and doctrine seed. The one hook it needed is `0010`. `BOT_CREWS_FILE` (the file) or
  `BOT_DATA_DIR` (its folder, default `/data/bots`) move the file; `TALK_DOCTRINE_DIR` and `TALK_DOCTRINE_SEED` the doctrine
  folders (the talk bridge's own settings).
  Part 2 (training) adds the hook `0011`, `BotGroup::skipXp` / `isOwnCrewBot` / `trainingSquadLeadersIn`, `BotManager::updateGear` / `refreshSquadAura` and the bindings
  `botSkillPoints`, `botSetGear` and `botSquadAura`; the training itself is Lua (`screenplays/bots/crew_train.lua`).
  Part 3 (gear by trade) adds no upstream hook: `BotGear.*` and `BotGearLua.*` (what a bot wears and holds, the owner's gifts recorded in its
  character, equipping through a container transfer so Core3's checks run, the best usable pack of a kind, the give-back filter that turns
  `BotLoot::goods` into the gifts, the let-go's straight return `BotGear::returnGiven`; bindings `botGear*`), the
  starter stims, and changes to our own files: `BotCombat::equip` and `repairGear` make and repair nothing for an own-crew bot, the factory
  makes no gear for one at login, `BotGroup::placeCamp` makes no kit for one, `BotTrade` keeps no customer's items from the owner, and the
  let-go (`BotManager::letGo`) hands the gifts back first. The gear itself is Lua (`screenplays/bots/crew_gear.lua`).
- **`NNNN-name.patch`**: hooks into upstream files, applied in order with `git apply` at the root of the Core3 tree.
  Keep each hook to a few lines that call into `bots/`.
  - `0001`–`0009`: the lifecycle and chat hooks.
  - `0010`–`0019`: the factory, items and experience hooks.

| Patch | File | Hook |
|---|---|---|
| `0001-start-bot-manager` | `ZoneServerImplementation.cpp` | Starts BotManager after the managers |
| `0002-bots-shutdown-logout` | `ServerCore.cpp` | Logs bots out at shutdown, before players are disconnected |
| `0003-bots-hear-chat` | `ChatManagerImplementation.cpp` | Spatial chat, tells and group chat (`handleGroupChat`, `handleChatRoomMessage`) from humans reach the bots |
| `0004-bots-lua-bindings` | `DirectorManager.cpp` | Registers the bot Lua functions in every Lua state |
| `0005-bots-close-sui-boxes` | `PlayerObjectImplementation.cpp` | Closes any game window a bot gets |
| `0006-sui-page-null-client` | `SuiPageData.cpp` | Null-client check in `sendTo` (an upstream crash with a clientless player) |
| `0007-bots-fairness` | group loot, mission rewards, XP | Bots are left out of the credit split, random loot and lottery candidates, the mission reward divisor and the XP damage share |
| `0008-bots-mission-done` | `MissionObjectiveImplementation.cpp` | `awardReward` notes the mission as completed (`BotGroup::missionDone`), so the crew tells a lair destroyed from a mission dropped |
| `0009-bots-squad-leader` | `SquadLeaderCommand.h`, `RetreatCommand.h`, `GroupObjectImplementation.cpp`, `GroupManager.cpp` | A bot squad leader in a group it doesn't lead may call the six squad leader commands (`BotGroup::mayCallSquadLeader`); retreat runs the whole group; the group's aura (`hasSquadLeader`, `addGroupModifiers`) reads a bot squad leader's skills when the leader has none, and a late joiner gets it after its group is set. **Builds on 0007** for the `BotGroup.h` include in `GroupObjectImplementation.cpp` and the context of `GroupManager.cpp` (it was made against the files with 0007 applied, and the two apply in order) |
| `0010-helper-droid-null-zone` | `SpawnHelperDroidTask.h` | Returns if the player has no zone. A character under a day old gets a helper droid 5 s after scene-ready, and a bot logged out within those 5 s (one hired and let go at once) crashed the server on a null zone |
| `0011-bots-squad-leader-xp` | `PlayerManagerImplementation.cpp` (`disseminateExperience`) | Part 2: an own-crew bot (`BotGroup::isOwnCrewBot`) earns experience from fights as a player does, by its share of *all* the damage (humans keep 0007's divisor, so theirs is unchanged); roster bots still earn none (`BotGroup::skipXp`). The squad leader experience of a fight goes to each own-crew squad leader bot in the group that is not its leader (`BotGroup::trainingSquadLeadersIn`; a bot leader is paid by the upstream path, so no double), and a human leader gets none from a bot's fights. **Builds on 0007**: made against the file with 0007 applied, the two apply in order |

The Dockerfile applies both after the checkout. A patch that doesn't apply fails the build, so after a `CORE3_REF`
bump, fix the patches first (`dev/build-core3.sh` shows which one fails).

## Writing a hook patch

Make a patch against a pristine copy of the file:

```
W=~/.cache/swgemu-scratch/core3-dev
d=$(mktemp -d) && cd $d && git init -q
f=MMOCoreORB/src/server/zone/managers/chat/ChatManagerImplementation.cpp
mkdir -p $(dirname $f) && cp $W/pristine/$f $f && git add -A && git commit -qm base
# edit $f, then:
git diff > ~/github/homelab/images/swgemu-core3/patches/0002-chat-to-bots.patch
```

Each patch must apply on its own to pristine Core3. Two patches may not touch the same file: put both hooks in one
patch.

## Building and testing

- `bash ../dev/build-core3.sh` builds incrementally in `~/.cache/swgemu-scratch/core3-dev/src`, with the same
  toolchain and CPU flags as production plus `-DDEBUG_AI`, and tags `ghcr.io/azskylab/swgemu-core3:dev-bots`. Builds
  queue on a lock.
- The local test server: `cd ../dev && CORE3_IMAGE=ghcr.io/azskylab/swgemu-core3:dev-bots docker compose up -d`. Hold
  `flock ~/.cache/swgemu-scratch/core3-dev/server.lock` while you restart or test on it.
- Compile errors are in the script's output. The server log is `docker compose logs core3`.
