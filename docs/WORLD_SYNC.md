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

## Experiment exp94: every generated actor (mod module `worldrep.lua`)
Host: every actor without `RF_WasLoaded` -> `SetReplicates`, `SetReplicateMovement`, relevant to 1.5 km, 2 updates
per second; skipped: items (mirrored by the mod), pawns, the player car and everything attached to it, child
actors, controllers / states / game mode / HUD / cameras / managers. Compared with `dev/snapdiff.ps1` (class by
class, same or neighbour 50 uu cell).
- First run (all runtime actors, 1 km): client 895 -> 2924 actors, an abandoned car seen on the client's screen.
  Duplicates: the player car's `BP_CarPart_Interactive_C` 53 -> 106 (the client has its own car), child actors
  (`BP_Destruct_ChainFence_Large_01_C` 16 -> 32: the replicated parent spawns them again on the client).
- With those skipped: client 1146 -> 5111 (host 7719). No car part doubles. Landmines 236 -> 0: the re-host
  (`servertravel <same map>?listen`) builds a new world with the same actor names and the module still thought it
  had handled them; it now forgets a world by its address.
- Landmines are still 0 on the client: `BP_Hazard_Landmine_C` is an `ItemWorldManifestation` (hazards are items in
  this game) and the module leaves items to the mod's item mirror, which does not take them either. Hazards are
  their own step (order above). The radiation volumes `BP_VolCascade_Radiation_C` are spawned by each game on its
  own, at different places (host 85, the client's own 81 elsewhere): also the hazards step.
- Client-local runtime actors (role authority on the client, exp96: 694) were the rest of the duplicates: prefab
  trees (PrefabSettingsActor -> ManageChildrenActor -> StaticMeshActor, shrubs, fences, road splines) that the
  client game builds itself in the same places. Nothing on the host tells them apart from host-only prefabs
  (neither is loaded with the level, none has an owner). Host side, what hangs on a level actor is no longer
  replicated; client side, the module removes its own copy of an actor when a replicated actor of the same class
  is in the same or a neighbour 60 uu cell (exp97: ~400 removed in the first minute, incl. lootable containers,
  doors, lights, posters). The host's copy is the one that breaks / opens.
- exp97 result (Rural_Forest_Bridge_Elf_01, 1 min after the join, both near the start): host 7590, client 5938;
  "extra" left on the client 1240, mostly physics props (traffic cones, barricades, floating rocks) a few cells
  away from the host's (simulated on both sides) and attachments the engine cannot replicate
  (`FNetGUIDCache::SupportsObject` warnings: a parent component that is not net addressable); "missing" 2898,
  mostly beyond the 1.5 km relevance (they come when a player gets near).
- (The exp94-97 totals above are a little high: `snapdiff.ps1` counted a class with one actor as three; fixed in
  exp99, the trends are the same.)
- exp99/100 (`dev/test_worldrep.ps1`, 40 s after the join): host 7668, client 7000 (91 %), abandoned
  `BP_Template_CivCar_01_C` 81 of 82, gas barrels 185 of 202; extra on the client 909 (12 %), missing 1570 (224 of
  them landmines). The player car's parts match (`BP_CarPart_Interactive_C` 53 / 53), but its **set of installed
  parts** differs: the host's car has an empty door, headlight and wheel slot where the client's has parts. The
  mod syncs part health, not which part is installed: a car sync gap, not a world one.
- **Attached actors were off** (exp101): doors 500-900 uu from the host's. The engine sends an attached actor as
  "attached to the root actor of its attachment chain, at its offset to its immediate parent" when the immediate
  parent component is not net addressable; the prefab "folder" actors (plain `Actor` named SetDressing, Layout,
  DOORS..., under PrefabSettingsActor -> building frame -> folder -> self-deletor -> door) create their root
  components at runtime, which are not (`FNetGUIDCache::SupportsObject` warnings, 2000+ per zone). The host's
  prediction "root transform * offset" matched the client's spot within 3 uu.
  - Tried: `SetIsReplicated(true)` on those parent components. Warnings 2000 -> 40, but the client then got its
    own copies of the components with other names and put the folders at their offsets as world positions:
    worse. Reverted.
  - Tried: 16-bit rotation for the replicated movement (`ReplicatedMovement.RotationQuantizationLevel = 1` on the
    host). **Breaks the connection**: the level is not sent, the client reads with its default ("Failed to receive
    property ReplicatedMovement", disconnect, exp106). Never change it on one side only.
  - Works (exp104-107): the host computes where the client will put each such actor (root location rounded to
    whole units, root rotation in 360/256 degree steps, as `ReplicatedMovement` sends them, times the offset) and
    sends "class, that spot -> the right transform" through the mod channel (~3000 entries, 120-150 KB, packed up
    to 7 KB per message, nearest to player 2 first: about 20 messages, the channel does ~2 per second). It checks
    each actor again ~10 s after spawning (a prefab moves content after spawning it). The client keeps the table
    and moves every matching replicated actor every 2 s, also when it comes back into relevance or the engine
    re-applies the attachment. exp107: all doors near both players on the host's spots, extra on the client 616
    of 5075 (12 %).
- Placement, later lessons (exp108-119): the fix is an offset relative to the chain root, not a world spot (a
  prefab root can move after the fix and the content must follow); an immediate parent that is a class component
  of a replicated actor (`CreationMethod` 0 or 1; the folders' roots are 3) resolves on the client, so no fix;
  a fix that turns out unneeded is taken back with an "offset -> same offset" entry (the client keeps the latest
  entry per key); every replicated actor is rechecked in a rolling pass (~1 min); chain roots are always
  relevant (a child that arrives before its root stays at 0,0,0). Still 1-3 doors off in some runs.

## Doors and lootable containers (worlddoors.lua, worldloot.lua)
- Doors (`BP_Door_*`, state in `CurrentState` and the door mesh's relative transform; each game randomizes it at
  BeginPlay): the host sends every door's state when it changes and all of them to a new client; player 2 applies
  them. Player 2's E (the Highlight interact event, declared on `BP_Door_Single_C` / `BP_Door_Sliding_Single_C`)
  is sent as `DOOR,<class>,<x,y,z>` and the host calls the same event on its door (the Highlight component and no
  data are enough). Player 2's own doors that the host does not have (client-generated prefabs) are removed once
  the host's list is complete and quiet for 20 s. test_doors 11/11.
- Lootable containers (`BP_Lootable_*`, `InventoryContainer`; filled by `Populate Container`): player 2's own
  roll is emptied, the host fills its container and sends its items; takes and puts go both ways as count
  deltas, the trunk's merge rules. test_loot 10/10.
- Next: trunks of abandoned cars, physics props, hazards, weather, quests.
- Earlier plan: doors and lootable containers on replicated actors (the client's interaction runs on its proxy; the host
  must do it and send the result), physics props, hazards, the garage (309 runtime actors there are replicated
  too: check that the client has no doubles there).



Status before exp93 (2026-10-22): each player's game generated its own world. The mod mirrored only world items
(loot), the car (transform, part health, fuel, battery), the trunk and the players. Everything else differed: doors,
props (trash bags), lootable containers, anomalies/hazards, weather, the map. Collision of a door comes from the
host (the client character moves on the host), so a door open only on the client blocks it.

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
