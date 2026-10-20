# Developer tools (not part of the playable mod)

Everything in `dev/` is for developing and testing the co-op mod on **test copies** of the game.
Do not install `PDCoopDev` for normal play: it has cheats and runs Lua sent through a file.

| File | What |
|---|---|
| `PDCoopDev/` | UE4SS Lua mod: command file, state dumps, cheats, keys |
| `dev_session.ps1` | starts one or two test copies (host + client on 127.0.0.1) with the co-op mod and PDCoopDev, leaves them running |
| `dev.ps1` | sends one command to a running copy and prints the answer |
| `test_carsync.ps1` | automated test of the shared trunk, car part state and player 2's saved inventory, driven through `dev.ps1` |

```
powershell -File dev/dev_session.ps1 -Two          # client1 hosts RB_Garage, client2 joins
powershell -File dev/dev.ps1 state                 # client1
powershell -File dev/dev.ps1 -Client client2 "inv trunk"
powershell -File dev/dev_session.ps1 -Stop         # close, logs to <root>\results\devsession
```

`-Root` (default `C:\PDCoop`) must contain `client1` and `client2`, test copies with UE4SS installed (see the
main README). The copies run with `-NotInstalled`, so they never touch your own settings or saves.

## Commands

| Command | What |
|---|---|
| `state` | map, host/client, players, your character, health, car (parts, fuel, battery), containers |
| `inv [all\|player\|hand\|trunk\|<Inventory_ field>]` | items per container and slot |
| `give <item> [n] [trunk]` | creates items in your inventory (or the trunk); `<item>` = `IA_...` name, full path or a unique part of the name |
| `spawn <item> [n]` | spawns world items in front of you |
| `items <filter>` | lists item archetypes |
| `god [on\|off]`, `heal`, `hurt [n]` | player health (the `PlayerHealth` resource of `BP_ResourceManager_C`) |
| `car`, `carfix`, `carhurt [pct]` | car parts' health, fuel, battery; repair/refuel/charge; damage all parts to pct % |
| `tp x y z`, `tpcar`, `carhere` | teleports |
| `find <class> [filter]`, `props <class\|name> [filter]`, `funcs <class\|name> [filter]` | reflection: live objects, property values, functions |
| `shot`, `con <console command>` | screenshot, console |
| `lua <code>`, `luafile <path>` | runs Lua in the game thread; the helpers (`me()`, `car()`, `im()`, `find()`, `props()`, `arch()`, `carParts()`, `res()`...) are in scope, the result is printed |

Keys in the game window: Ctrl+F9 god mode, Ctrl+F10 repair/refuel/charge the car, Ctrl+F11 state into the UE4SS log.

`PDCoopDev/dev.txt` (written by `dev_session.ps1`, removed by `-Stop` and by `tools/run_test.ps1`):
`open <map or address>` opens it once the main menu is up, `god` starts with god mode on.

## Test copies: intro videos

The test copies start faster without the startup videos: move every file except `CompiledIntroSequence.mp4`
from `<copy>\PenDriverPro\Content\Movies` to a folder next to it (the game skips missing movies; this is what
the intro-skip mods on Nexus do). Move them back to undo. Never do this in your Steam install unless you want to.
