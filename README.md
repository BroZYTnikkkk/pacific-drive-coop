# Pacific Drive Co-op (PDCoopNet)

An experimental two-player co-op mod for **Pacific Drive** (Ironwood Studios), built on Unreal Engine's own
listen-server netcode and driven by a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod.

> **Status: research prototype.** It was built and tested by an AI agent (Claude Code, Opus 5.5) with automated
> two-instance tests on one PC. Nobody has played a full run with it yet. Expect rough edges and crashes.
> Write-up and full lab notes: [coop-anything / games/pacific-drive](https://github.com/BroZYTnikkkk/coop-anything/tree/game/pacific-drive/games/pacific-drive).

## What works (verified by automated tests)

| Feature | Test | Result |
|---|---|---|
| Host opens a listen server, a second player joins | `car`, `rejoincar` | pass |
| The joining player gets their own character and controls it; both see each other move | all | pass |
| No duplicate player car on the client | all | pass |
| Host drives, the second player rides along as a passenger | `car` | 16/16 |
| Passenger drops out and rejoins while the host is driving: spawns next to the car and is seated again; then gets out (UNSEAT) and walks | `rejoincar` | 24/24 |
| Host `servertravel` to another map: the client follows and keeps its character | `travel` | 14/14 |
| The game's own map change (e.g. new game, quit to menu): host re-hosts the new map, the client reconnects and spawns next to the host | `gametravel` | 15/15 (2 n/a) |
| Start of a new game (player starts seated in the intro car): one car on the client, player 2 seated as passenger, not on top of the host | `gametravel` | 15/15 |
| Test runs report game crashes (crash reporters are closed, dumps kept) | all | yes |
| Shared world items: player 2 sees the host's items in the same places, picks them up into their own inventory, the host's copy disappears; the host's pickups disappear for player 2 | `loot` | 25/25 |
| Visible bodies: each player sees the other player's body (on foot and seated), never their own; the driver's body is not hidden for the passenger | `rejoincar`, `loot` | 33/33, 25/25 |
| Shared car trunk: either player puts items in or takes them out, the other sees it; changes made at the same moment merge | `dev/test_carsync.ps1` | 15/15 |
| Car part health, fuel and battery follow the host; damage only on player 2's side is undone; a repair by player 2 reaches the host | `dev/test_carsync.ps1` | 15/15 |
| Player 2's inventory is saved on the host and given back when player 2 joins again (also after a full game restart) | `dev/test_carsync.ps1`, `rejoincar` | 15/15, 33/33 |
| Items keep their state over the network (fuel in a can, battery charge, durability, health): trunk, world, pickups, saved inventory; if a value cannot be written: 50 % of max, never more than it had | `dev/test_itemstate.ps1` | 15/15 |
| Player 2 refuels the car from a can and charges it with the battery charger tool: the host's car gets it (only player actions count, the host computes background changes) | `dev/test_refuel.ps1` | 10/10 |
| Down instead of dead: 60 s, no damage while down, the other player revives (hold E 5 s within 2 m; 60 % health with a food / medicine item, which is used up, else 20 %), both directions | `dev/test_downed.ps1` (zone) | 17/17 |
| Team death (not revived in 60 s, or both down): the game's own death on the host, back to the garage, player 2 rejoins; player 2's pockets go through the game's own item removal with the host's arguments | `dev/test_downed.ps1` (zone) | 17/17 |
| Feature switches (`features.txt`) to turn each new part off | manual | - |
| Seated bodies are lowered into the seat and do not collide with the car; the passenger's camera mirrors the driver's | `rejoincar` | pass |

A joining or re-joining player always appears next to what the host controls right now (the host's character,
or the car, in which case they are seated as a passenger). Saved positions and the garage are never used.

## Known gaps

- World items and the car trunk are shared (host is the truth); **inventories are per player**. Player 2's
  inventory (pockets and hand) is saved on the host in `ue4ss/Mods/PDCoopNet/save_<id>.txt`; the id is in
  player 2's `ue4ss/Mods/PDCoopNet/player_id.txt` (keep that file to keep the inventory). Equipment slots,
  hotbar, health and other player 2 state are not saved.
- Items that cross the network are recreated with their fuel / charge / durability / health; other item
  state (tint, locks, cables, status effects) is not carried.
- Car: installing, removing or losing parts (a door torn off) is not synced. Other car containers (roof
  storage, upgrades) are not synced. Quests, crafting and the host's saves are not synced.
- Down / revive: the on-screen messages use the game's HUD warning list; whether they are visible was not
  confirmed by a human. Player 2's death losses: in the tests (a zone opened directly, not a real run) the
  game removed nothing from the host's pockets and the mod removed nothing from player 2's; the real run
  rule and the tombstone hand-over were not tested.
- Dropping an item by player 2 is implemented (sent to the host) but not tested.
- Fixtures such as the garage gas pump handles are mirrored too; if player 2 stands next to one when a map
  loads, the mod could mistake the pump taking its handle for a pickup and remove the host's handle.
- The game's own map changes drop the listen server; the mod re-hosts by loading the map a second time
  (+15-30 s per map change), and clients reconnect (retry every 30 s).
- Bodies are the game's stock mannequin (the player character is a first-person invisible mesh) with Unreal's
  grey default material. There is no sitting pose: a seated player is a standing mannequin lowered into the
  seat. Held items, the flashlight and animations other than walking are not mirrored (not implemented).
- The screen effects of damage (red/brown blood overlay) are the game's own and not synced.
- Internet play was not tested (only localhost). The mod uses Unreal's IP net driver: the host must be
  reachable on UDP port 7777 (port forward, or a LAN/VPN such as Tailscale/ZeroTier).
- The play keys (F6/F7/F8 below) were not pressed in any test. The tests run the same actions from bots
  (SEAT/UNSEAT commands, `servertravel ...?listen`, `open <host>`), not through the key bindings.
- A real run (garage gateway → zones → back) was not tested, only map changes started by the test bot.
- Game build tested: Steam build 21896301. Other builds may break it.

## Install (both players)

1. Install UE4SS into `<game dir>/PenDriverPro/Binaries/Win64/`. Tested with the UE4SS
   `experimental-latest` dev build `zDEV-UE4SS_v3.0.1-1181-g83330635.zip`
   (SHA-256 `82378cd7f679d055026286f11347355ac67c712f21eb892060c902bb0184b907`), from the
   [official releases](https://github.com/UE4SS-RE/RE-UE4SS/releases).
2. Copy `mod/PDCoopNet` (with all its `Scripts/*.lua` files) into `<game dir>/PenDriverPro/Binaries/Win64/ue4ss/Mods/` and add the line
   `PDCoopNet : 1` to `ue4ss/Mods/mods.txt` (above `Keybinds : 1`).
3. Optional: copy `features.example.txt` to `features.txt` to switch parts off (see [PLAYTEST.md](PLAYTEST.md)).
4. Create `ue4ss/Mods/PDCoopNet/role.txt`:
   - host: one line `host`
   - friend: two lines `client` and the host's address, e.g. `203.0.113.7:7777`
5. **Back up your saves first** (`%LOCALAPPDATA%\PenDriverPro\Saved\SaveGames`).

## Play

| Who | Key | What |
|---|---|---|
| Host | F8 | load your save, then press F8: the current map is re-opened as a listen server |
| Friend | F8 | connect to the host from the main menu |
| Friend | F6 | sit in the host's car as passenger |
| Friend | F7 | get out of the car |
| Either | hold E (5 s) | revive a downed partner next to you |

The keys are only read while the game window has focus. Logs are in `ue4ss/UE4SS.log` (lines tagged `[PDCoopNet]`).

## Tests

`tools/run_test.ps1` runs two copies of the game on one PC (host + client) and checks the logs:

```
powershell -File tools/run_test.ps1 -Root C:\PDCoop -Name mytest -Seconds 300 -Scenario car
```

`-Root` must contain `client1` and `client2`, two copies of the game with UE4SS installed (the second can be
hardlinks to the first, with its own `PenDriverPro/Binaries/Win64`). Both are started with `-NotInstalled`, so
each copy keeps its settings, logs and saves in its own `PenDriverPro/Saved` instead of `%LOCALAPPDATA%`.
Scenarios: `car`, `rejoincar`, `travel`, `gametravel`, `loot` (bots do the driving, walking, travelling and
looting). `tools/run_single.ps1` runs one copy for quick probes. Developer tools (command file, cheats,
`dev/test_carsync.ps1`) are in [`dev/`](dev/README.md); they are not part of the mod.
`tools/paklist.py` and `tools/pakextract.py` list and extract files from the game's own pak v11 archives
(unencrypted, Zlib) for research; never redistribute extracted files.

## How it works

See the lab notes linked above. In short: Pacific Drive ships Unreal 4.27.2 with `IpNetDriver` compiled in
but no replication in its own code. The mod opens the map with `?listen`, spawns and possesses a
`PDP_MainCharacter_C` for each remote player, removes the client's local duplicate car, uses the stock
`ServerChangeName` RPC as a client-to-host command channel, attaches passengers to the host-simulated car,
and makes the car kinematic on clients (following `ReplicatedMovement`).

## Credits and license

- Code: MIT (see LICENSE). No game files are included.
- Built with [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) and the
  [coop-anything](https://github.com/cranebeaker/coop-anything) playbook.
- Built by an AI agent (Claude Code) for its owner; Pacific Drive is © Ironwood Studios / Kepler Interactive.
  This is an unofficial fan mod.
