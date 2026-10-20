# First playtest over the internet (two players)

## Before you start (both)

1. Back up your saves: copy `%LOCALAPPDATA%\PenDriverPro\Saved\SaveGames` somewhere safe.
2. Install UE4SS and the mod as in the README (`mod/PDCoopNet` with all three `Scripts/*.lua` files).
3. Install [Radmin VPN](https://www.radmin-vpn.com/), both join the same network (one creates it, the other
   joins with its name and password). Note the host's Radmin IP (26.x.x.x).
4. `ue4ss/Mods/PDCoopNet/role.txt`:
   - host: `host`
   - friend: two lines, `client` and `<host's Radmin IP>:7777`
5. Windows firewall on the host: allow the game (PenDriverPro-Win64-Shipping.exe) on private networks when asked.

## Play

| Who | Key | What |
|---|---|---|
| Host | F8 | load your save, then F8: the map is re-opened for co-op |
| Friend | F8 | connect from the main menu |
| Friend | F6 / F7 | sit in the host's car / get out |
| Either | hold E (5 s) next to a downed partner | revive (a food / medicine item is used if you have one: 60 % health, else 20 %) |

A player who would die goes down instead: 60 s for the partner to revive. Not revived in time, or both down:
the team dies by the game's own rules (garage, losses, tombstone with both players' lost items).

## If something breaks

Switch the part off and keep playing: copy `ue4ss/Mods/PDCoopNet/features.example.txt` to `features.txt` and set
the line to `off` (both players), then restart the game.

| Problem | Switch off |
|---|---|
| items in the trunk vanish or double | `trunk` |
| car fuel / damage jumps around | `carstate` (and `refuel`) |
| items lose or gain fuel / durability | `itemstate` |
| the friend's inventory is wrong after rejoining | `invsave` |
| dying / reviving misbehaves | `downed` |

Still broken: use the previous version v0.6 (git tag / release v0.6).

## What to send back

From both players, after the session:
- `PenDriverPro/Binaries/Win64/ue4ss/UE4SS.log`
- `%LOCALAPPDATA%\PenDriverPro\Saved\Logs\PenDriverPro.log`
- if the game crashed: the newest folder in `%LOCALAPPDATA%\PenDriverPro\Saved\Crashes`
- a few words: what you did right before the problem, roughly when (time of day)

## Please check (nobody has seen these with real players yet)

- the friend can join over Radmin and both see each other on foot and in the car
- a full run: garage -> gateway -> zone -> loot -> back
- the shared trunk while both use it
- reviving: do the on-screen messages show ("... is down: 42 s", "Reviving... 3 / 5 s")?
- lag: how the car looks for the passenger
