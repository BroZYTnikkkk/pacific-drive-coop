# Developer tools (not part of the playable mod)

Everything in `dev/` is for developing and testing the co-op mod on **test copies** of the game.
Do not install `PDCoopDev` for normal play: it has cheats and runs Lua sent through a file.

| File | What |
|---|---|
| `PDCoopDev/` | UE4SS Lua mod: command file, state dumps, cheats, keys |
| `dev_session.ps1` | starts one or two test copies (host + client on 127.0.0.1) with the co-op mod and PDCoopDev, leaves them running |
| `dev.ps1` | sends one command to a running copy and prints the answer |
| `test_carsync.ps1` | automated test of the shared trunk, car part state and player 2's saved inventory, driven through `dev.ps1` |
| `test_itemstate.ps1` | items keep fuel / durability through the trunk, the world, pickups and the saved inventory; 50 % fallback; clamp |
| `test_refuel.ps1` | player 2 refuels (TransferFuel) and charges (DoCharge) the car, the host's car gets it |
| `test_downed.ps1` | down instead of dead, revive both ways (with / without food), team death after 60 s, player 2's losses, tombstone (zone map, `-ResetSave`) |
| `test_worldrep.ps1` | the host's generated zone content reaches player 2 (zone via `zone_pair.ps1`, compared with `snapdiff.ps1`): coverage, no doubles of the car parts / prefabs |
| `test_doors.ps1` | zone doors: player 2's doors in the host's state, the host's and player 2's door use reach the other side |
| `test_loot.ps1` | lootable containers: player 2 gets the host's items, takes and puts reach the other side |
| `zone_pair.ps1` | host loads a save slot, drives the route into a real generated zone, re-hosts it, player 2 joins; leaves both running |
| `snapdiff.ps1` | compares two `snapshot` files class by class: counts, actors without a twin on the other side |
| `run_all.ps1` | every test one after the other, one summary line each |
| `testlib.ps1` | helpers shared by the tests |

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
| `lethal [n]` | n hits of 500 through the game's own player damage path (zone only: the garage protects the player) |
| `holdrevive on\|off` | the co-op mod treats the revive key (E) as held (shared UE4SS variable) |
| `setstate <container> <slot> <state>`, `wstate [filter]`, `wsetstate <filter> <state>` | item state (`F6.5_D3`: fuel, battery, durability, health) in a container slot / of world items |
| `pickup <filter>` | picks up the nearest matching world item with the game's own pickup |
| `car`, `carfix`, `carhurt [pct]` | car parts' health, fuel, battery; repair/refuel/charge; damage all parts to pct % |
| `tp x y z`, `tpcar`, `carhere` | teleports |
| `find <class> [filter]`, `props <class\|name> [filter]`, `funcs <class\|name> [filter]` | reflection: live objects, property values, functions |
| `shot`, `con <console command>` | screenshot, console |
| `snapshot <tag> [grid]` | every actor (class + position in grid cells, default 50 uu) to `PDCoopDev/snap_<tag>.txt` |
| `loadslot <n>` | loads save slot n from the main menu |
| `lua <code>`, `luafile <path>` | runs Lua in the game thread; the helpers (`me()`, `car()`, `im()`, `find()`, `props()`, `arch()`, `carParts()`, `res()`...) are in scope, the result is printed |

Keys in the game window: Ctrl+F9 god mode, Ctrl+F10 repair/refuel/charge the car, Ctrl+F11 state into the UE4SS log.

`dev_session.ps1 -Map <map> -ResetSave`: zone tests need a host save from before any team death (after one, a
zone opened directly takes no damage); `-ResetSave` copies `<root>\saves-baseline\odsave_scratch.sav` over the
host copy's save. With `-Two` the client starts once the host listens. From Git Bash, prefix the call with
`MSYS_NO_PATHCONV=1`, or `/Game/...` arguments are rewritten into Windows paths.

`PDCoopDev/dev.txt` (written by `dev_session.ps1`, removed by `-Stop` and by `tools/run_test.ps1`):
`open <map or address>` opens it once the main menu is up, `god` starts with god mode on.

## Test copies: intro videos

The test copies start faster without the startup videos: move every file except `CompiledIntroSequence.mp4`
from `<copy>\PenDriverPro\Content\Movies` to a folder next to it (the game skips missing movies; this is what
the intro-skip mods on Nexus do). Move them back to undo. Never do this in your Steam install unless you want to.
