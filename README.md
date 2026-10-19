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

A joining or re-joining player always appears next to what the host controls right now (the host's character,
or the car, in which case they are seated as a passenger). Saved positions and the garage are never used.

## Known gaps

- Only the host's game is the real game: loot, inventory, car parts, damage, quests and saves are **not**
  synced. The second player is a companion who can walk around and ride along.
- The game's own map changes drop the listen server; the mod re-hosts by loading the map a second time
  (+15-30 s per map change), and clients reconnect (retry every 30 s).
- The passenger does not play a sitting animation; camera and visuals were not checked by a human.
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
2. Copy `mod/PDCoopNet` into `<game dir>/PenDriverPro/Binaries/Win64/ue4ss/Mods/` and add the line
   `PDCoopNet : 1` to `ue4ss/Mods/mods.txt` (above `Keybinds : 1`).
3. Create `ue4ss/Mods/PDCoopNet/role.txt`:
   - host: one line `host`
   - friend: two lines `client` and the host's address, e.g. `203.0.113.7:7777`
4. **Back up your saves first** (`%LOCALAPPDATA%\PenDriverPro\Saved\SaveGames`).

## Play

| Who | Key | What |
|---|---|---|
| Host | F8 | load your save, then press F8: the current map is re-opened as a listen server |
| Friend | F8 | connect to the host from the main menu |
| Friend | F6 | sit in the host's car as passenger |
| Friend | F7 | get out of the car |

The keys are only read while the game window has focus. Logs are in `ue4ss/UE4SS.log` (lines tagged `[PDCoopNet]`).

## Tests

`tools/run_test.ps1` runs two copies of the game on one PC (host + client) and checks the logs:

```
powershell -File tools/run_test.ps1 -Root C:\PDCoop -Name mytest -Seconds 300 -Scenario car
```

`-Root` must contain `client1` and `client2`, two copies of the game with UE4SS installed (the second can be
hardlinks to the first, with its own `PenDriverPro/Binaries/Win64`). Both are started with `-NotInstalled`, so
each copy keeps its settings, logs and saves in its own `PenDriverPro/Saved` instead of `%LOCALAPPDATA%`.
Scenarios: `car`, `rejoincar`, `travel`, `gametravel` (bots do the driving, walking and travelling).
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
