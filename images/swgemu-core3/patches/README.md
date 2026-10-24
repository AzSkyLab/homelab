# Our C++ patches to Core3

Core3 is built from upstream at `CORE3_REF` (see `../Dockerfile`). Our C++ goes in two places:

- **`bots/`**: our own source files. They are copied to `MMOCoreORB/src/server/zone/managers/bot/`, and Core3's
  `file(GLOB_RECURSE ...)` picks them up, so CMake needs no change. These are the bot players: characters the server
  plays itself (spec: `~/github/swgemu/specs/2026-10-23-bot-players/`).
- **`NNNN-name.patch`**: hooks into upstream files, applied in order with `git apply` at the root of the Core3 tree.
  Keep each hook to a few lines that call into `bots/`.
  - `0001`–`0009`: the lifecycle and chat hooks.
  - `0010`–`0019`: the factory and items hooks.

| Patch | File | Hook |
|---|---|---|
| `0001-start-bot-manager` | `ZoneServerImplementation.cpp` | Starts BotManager after the managers |
| `0002-bots-shutdown-logout` | `ServerCore.cpp` | Logs bots out at shutdown, before players are disconnected |
| `0003-bots-hear-chat` | `ChatManagerImplementation.cpp` | Spatial chat, tells and group chat (`handleGroupChat`, `handleChatRoomMessage`) from humans reach the bots |
| `0004-bots-lua-bindings` | `DirectorManager.cpp` | Registers the bot Lua functions in every Lua state |
| `0005-bots-close-sui-boxes` | `PlayerObjectImplementation.cpp` | Closes any game window a bot gets |
| `0006-sui-page-null-client` | `SuiPageData.cpp` | Null-client check in `sendTo` (an upstream crash with a clientless player) |
| `0007-bots-fairness` | group loot, mission rewards, XP | Bots are left out of the credit split, random loot and lottery candidates, the mission reward divisor and the XP damage share |

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
