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
| World in a zone: the host's generated content (abandoned cars and parts, props, barrels, containers) is replicated to player 2 within 1.5 km; player 2's own copies of the same prefabs are removed, the player car's parts are not doubled; attached content (doors, prefab props) is moved to the host's spots | `dev/test_worldrep.ps1` (generated zone) | 13-14/14 (the strict door check fails now and then: 1-3 doors off) |
| Zone doors: player 2's doors are in the host's state (open, closed, ajar, locked), a door the host uses changes for player 2, player 2's E on a door runs on the host; player 2's own doors that the host does not have are removed | `dev/test_doors.ps1` (generated zone) | 10-11/11 (placement: 75-100 % of player 2's doors on the host's spots) |
| Lootable containers (crates, backpacks, cabinets...): player 2 opening one gets the host's items, not its own roll; what player 2 takes is gone on the host, what the host puts in shows up for player 2 | `dev/test_loot.ps1` (generated zone) | 10/10 |
| Feature switches (`features.txt`) to turn each new part off | manual | - |
| Seated bodies are lowered into the seat and do not collide with the car; the passenger's camera mirrors the driver's | `rejoincar` | pass |

A joining or re-joining player always appears next to what the host controls right now (the host's character,
or the car, in which case they are seated as a passenger). Saved positions and the garage are never used.

## Known gaps

- **The world is shared only in part.** In a zone the host's generated content (abandoned cars and their parts,
  props, barrels, containers, signs...) is sent to player 2 by the engine (`worldrep`, see `docs/WORLD_SYNC.md`):
  player 2 sees what the host sees within 1.5 km; doors and lootable containers are shared. Not yet: trunks of
  abandoned cars, a few doors still stand off for player 2, physics props may sit a little apart, hazards
  (landmines are there for player 2 on the refactor branch, their explosions for player 2 are not tested; radiation clouds differ) and weather.
- **Which parts are installed on the car is not synced** (only their health, fuel, battery): a part taken off or
  put on by one player can look different for the other.
- **Pause is shared**: either player's pause menu (Esc) pauses the game for both; it stays paused while one of
  the two menus is open, and the other player sees a note. The logbook does not pause the game in co-op.
- The trunk is used by one player at a time: while it is open at one player, the other cannot open it.
- The game's map in the car shows nothing for player 2.
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
- An item dropped by player 2 is placed at its feet on the host (no throw, no falling physics).
- Fixtures such as the garage gas pump handles are mirrored too; if player 2 stands next to one when a map
  loads, the mod could mistake the pump taking its handle for a pickup and remove the host's handle.
- The game's own map changes drop the listen server; the mod re-hosts by loading the map a second time
  (+15-30 s per map change), and clients reconnect (retry every 30 s).
- Bodies are the game's stock mannequin (the player character is a first-person invisible mesh), one colour per
  player (refactor branch: host orange, player 2 blue), animated with the game's own ALS v3 clips: idle, walk,
  run, sprint, crouch, jump, fall, lying when down. There is no sitting clip in the game: a seated player has
  the crouch pose, lowered into the seat. Held items and the flashlight are not mirrored.
- The screen effects of damage (red/brown blood overlay) are the game's own and not synced.
- The mod uses Unreal's IP net driver: the host must be reachable on UDP port 7777. Played over Radmin VPN on
  2026-10-21 (works); a port forward or another VPN (Tailscale, ZeroTier) works the same way.
- A real run (garage gateway → zones → back) was not tested, only map changes started by the test bot.
- Game build tested: Steam build 21896301. Other builds may break it.

## Install (both players)

**Easiest:** download `PDCoop-installer.zip` from the [latest release](https://github.com/BroZYTnikkkk/pacific-drive-coop/releases/latest),
unpack it anywhere, double-click `PDCoop.bat`:

| Menu | What |
|---|---|
| 1 Install / update | backs up your saves (Documents\PDCoop-backups), installs UE4SS (pinned build, SHA-256 checked) and the newest mod; an update replaces the old mod files and keeps your role.txt, features.txt, player_id.txt, save_*.txt. A `PDCoopNet-*.zip` next to the script is installed instead of the download (offline / test builds). |
| 2 Role | host, or client + the host's address |
| 3 Collect logs | writes one `PDCoop-report-<time>.txt` with versions, settings, logs and crash summaries; user and PC names, account ids and IPs other than Radmin VPN are removed. Send that file. |
| 4 Uninstall | removes the mod (UE4SS too if you say so) |

Then start the game through Steam as usual.

**By hand:**

1. Install UE4SS into `<game dir>/PenDriverPro/Binaries/Win64/`. Tested with the UE4SS
   `experimental-latest` dev build `zDEV-UE4SS_v3.0.1-1181-g83330635.zip`
   (SHA-256 `82378cd7f679d055026286f11347355ac67c712f21eb892060c902bb0184b907`), from the
   [official releases](https://github.com/UE4SS-RE/RE-UE4SS/releases).
2. Copy `mod/PDCoopNet` (with all its `Scripts/*.lua` files) into `<game dir>/PenDriverPro/Binaries/Win64/ue4ss/Mods/` and add the line
   `PDCoopNet : 1` to `ue4ss/Mods/mods.txt` (above `Keybinds : 1`). Copy `mod/PDCoopNet/LogicMods/PDCoopNet.pak` into
   `<game dir>/PenDriverPro/Content/Paks/LogicMods/` and make sure `mods.txt` has `BPModLoaderMod : 1`
   (refactor branch, v0.9).
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
| Friend | E at the car / F6 | sit in the host's car as passenger (always the passenger: the host drives) |
| Friend | E in the car / F7 | get out of the car |
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
`PDP_MainCharacter_C` for each remote player, removes the client's local duplicate car, attaches passengers
to the host-simulated car, and makes the car kinematic on clients (following `ReplicatedMovement`).

Messages between the host and the other players go through our own replicated actor, `PDCoopChannel`, from
`PDCoopNet.pak` (a small Blueprint-only UE 4.27 project in [`pak/`](pak/README.md), loaded by UE4SS's
BPModLoaderMod): the host spawns one per remote player, owned by that player's controller, and reliable
Server / Client RPCs carry the messages over the game's own connection (`channel.lua`). Sync modules react to
game events where the game has them (items entering or leaving a container, doors: `events.lua`). World items
cannot be replicated directly (the copy has no item data and the game crashes), so the host gives each one a
marker of our own (`PDCoopItemMarker`, movement replicated) and player 2's game keeps its own item of that type
on the marker (`items.lua`).

## Credits and license

- Code: MIT (see LICENSE). No game files are included.
- Built with [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) and the
  [coop-anything](https://github.com/cranebeaker/coop-anything) playbook.
- Built by an AI agent (Claude Code) for its owner; Pacific Drive is © Ironwood Studios / Kepler Interactive.
  This is an unofficial fan mod.
