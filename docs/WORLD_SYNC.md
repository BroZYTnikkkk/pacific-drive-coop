# World sync: options and experiments

## Owner's decisions (2026-10-22)
- Option A: player 2 plays on a copy of the host's save in its own slot (own saves untouched); the save is sent
  automatically on connect when it changed; on every host map change player 2 reloads the fresh save (fast
  "follow the host" travel is a later optimisation; collect data for it).
- One world for both: quests, progress, achievement counters (e.g. "1000 trees") count for both, host is the truth.
- Objects that look at "the player" (garage mini display...) look at the nearest of the two; the car map stays per
  player.
- Order: experiment -> doors and lootable containers -> quests/progress/achievements -> moved/destroyed props ->
  hazards -> weather/storm. Client driving later; 3-4 players only when 2 work almost perfectly.

## Experiment exp93 (2026-10-22, two test copies, the owner's playtest save odsave1)
1. Same save, both standalone, garage: 4189 vs 4187 actors; the differences are the car and its parts (the car
   settled by physics at a slightly different spot). The garage itself is identical.
2. Same save, both `BaseRouteState:TravelTo(RouteShapeLeg_1)`: the route is identical (WorldShapeRandSeed
   1203263204, same legs) but the games picked **different maps** (Rural_Forest_Bridge_Elf_01 vs
   Rural_Forest_Farm_Rooster_11): the zone is chosen at travel time. In co-op this is not an issue: the client loads
   the host's map through the network.
3. Host in the zone with ?listen, client joined by `open` (co-op mod off): host 7794 actors, client 1146. **The
   generated content of the zone does not exist on the client**: abandoned cars (BP_Template_*), their parts, gas
   barrels, destructibles, most StaticMeshActors placed by prefabs. Only the plain level is there. The spawners run
   only with authority. In a zone player 2 would see an empty road and bump into the host's invisible cars.
4. Option C works for at least one class: `SetReplicates(true)` + `SetReplicateMovement(true)` + `bAlwaysRelevant`
   on the host's 205 BP_Spawn_GasBarrel_C -> the client got 206, 198 of them in the same 50 uu cell.

Consequence: the main tool is engine replication of the host's generated actors (C), not a shared seed (A). The
shared save still matters for everything the client game keeps itself (progression, unlocks, garage, quests UI).
Next: replicate every generated class (cars + parts, props, destructibles, containers), check visuals, interaction
(doors, trunks of abandoned cars, looting), and traffic; then remove the client's own duplicates if any appear.



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
