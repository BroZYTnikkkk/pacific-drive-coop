# Playtest over the internet (two players)

## Setup (both, once)

1. Download `PDCoop-installer.zip` from the [latest release](https://github.com/BroZYTnikkkk/pacific-drive-coop/releases/latest),
   unpack it anywhere (Desktop is fine).
2. Close the game. Double-click `PDCoop.bat`, choose **1 Install / update** (it backs up your saves first).
3. Choose **2 Role**: the host answers `h`; the friend answers `c` and types the host's Radmin VPN IP (26.x.x.x).
4. Both in the same [Radmin VPN](https://www.radmin-vpn.com/) network.
5. Host: when Windows asks about network access for Pacific Drive, allow it for private **and** public networks
   (Radmin's adapter is often a "public" network). No dialog and the friend cannot connect: allow
   `PenDriverPro-Win64-Shipping.exe` by hand in "Windows Defender Firewall -> Allow an app".

New version: run `PDCoop.bat` -> 1 again. Your role and player 2's saved inventory stay.

## Play

1. Host: start the game through Steam, load the save, wait until you are in the garage, press **F8** once.
2. Friend: start the game, in the main menu press **F8** once and wait up to 20 s.

| Who | Key | What |
|---|---|---|
| Host | F8 | open the loaded game for your friend |
| Friend | F8 | connect (main menu) |
| Friend | E at the car / F6 | sit in the passenger seat |
| Friend | E in the car / F7 | get out |
| Either | hold (or tap) E next to a downed partner | revive within 60 s; food or medicine in your inventory gives 60 % health, else 20 % |

- **Do not press Esc as host** while the friend is connected: it is blocked (it crashed the game).
- A player who would die goes down instead (cannot move). Not revived in 60 s, or both down: the team dies as
  in the game (garage, losses). The friend reconnects by itself after the host is back in the garage.
- The trunk opens for one player at a time.

## If something breaks

Switch the part off and keep playing: in `<game>\PenDriverPro\Binaries\Win64\ue4ss\Mods\PDCoopNet` copy
`features.example.txt` to `features.txt` and set the line to `off` (both players), restart the game.

| Problem | Switch off |
|---|---|
| items in the trunk vanish or double | `trunk` |
| car fuel / damage jumps around | `carstate` (and `refuel`) |
| items lose or gain fuel / durability | `itemstate` |
| the friend's inventory is wrong after rejoining | `invsave` |
| dying / reviving misbehaves | `downed` |

## What to send back

After the session (and right after a crash): `PDCoop.bat` -> **3 Collect logs**, send the
`PDCoop-report-....txt` it writes (both players). Plus a few words: what you did right before, roughly when.

## Please check

- the friend enters and leaves the car with E; the camera turns freely in the passenger seat
- the new-game intro for the friend (passenger seat, camera)
- damage: each player has their own health now (a fall of one does not hurt the other)
- downed / revive: do the messages show ("Your partner is down: 42 s", "Reviving... 3 / 5 s")?
- the friend resets (teleports) the car: does it move for both?
- the host dies: does the friend come back to the garage by itself?
- a real run: garage -> gateway -> zone -> back
