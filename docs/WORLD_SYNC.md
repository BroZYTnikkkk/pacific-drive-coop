# World sync: options (draft for the next design session)

Status 2026-10-22: each player's game generates its own world. The mod mirrors only world items (loot), the car
(transform, part health, fuel, battery), the trunk and the players. Everything else differs: doors, props (trash
bags), lootable containers, anomalies/hazards, weather, the map. Collision of a door comes from the host (the client
character moves on the host), so a door open only on the client blocks it.

Playbook background (coop-anything `how-coop-mods-work`): retrofits onto closed single-player games are
host-authoritative state sync; "snapshot on join" (full state, then deltas) is the recommended base, and Anchor
(Ocarina of Time) loads a save state from the host on join.

## Option A: same world from the same save (the owner's idea)

Before joining, player 2 loads the host's save (the host sends it: the mod can transfer a file over the existing
channel in parts, or the installer copies it). If the game's generation is deterministic from the save (route, leg
state, `SpawnExecutorSettings.Seed`, `ERandomStateChannel` found in the dumps), both games build the same zone:
same props, containers, loot spots, hazards.

- Then sync only changes: doors (open/close events), container opens and takes, prop physics of what a player
  touched, item pickups (already done), destruction.
- To check first: is generation really deterministic from the save on two machines? Test: two copies load the same
  save, list all actors of a zone (class + transform), compare. The dev tools can do this (`find`).
- Risk: runtime randomness (hazard spawns, weather) uses other random streams; those need host events.

## Option B: host world, client mirrors (extend what the loot sync does)

The client removes its own interactive actors and mirrors the host's (as for items): doors, containers, props,
hazards. Most robust against divergence, most work per actor type, more traffic.

## Option C: engine replication for selected actors

UE4 replicates actors that have `bReplicates`. The game's actors are not marked; turning `SetReplicates(true)` on
host actors could let the engine itself create them on the client (the client must then not spawn its own).
Unknown whether the game's Blueprints survive being replicated (BeginPlay on the client, missing server-only state).
Cheap experiment with the dev tools on one actor type (a door).

## Suggested order

1. Experiment A (determinism of generation from the same save) and C (replicate one door) with the dev tools.
2. Pick per actor type: same-seed + change events where generation matches, mirror (B) or replication (C) where not.
3. Then trunk lock -> real shared containers, car map, client driving (authority hand-off).
