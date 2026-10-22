# PDCoopNet.pak (source)

A tiny Unreal Engine 4.27 project that builds the pak part of the co-op mod. It holds only our own Blueprints,
no game files. The project is named `PenDriverPro` like the game, so the cooked assets mount at
`/Game/Mods/PDCoopNet/` inside the game.

| Asset | What |
|---|---|
| `ModActor` | Empty actor. UE4SS's BPModLoaderMod spawns it on every map load; it only makes the pak's package load. |
| `PDCoopChannel` | The co-op channel. Replicates, relevant only to its owner, no movement, hidden. The host spawns one per remote player and gives it to that player's controller. `ServerSend(Msg: String)` runs on the server (reliable), `ClientSend(Msg: String)` runs on the owning client (reliable). Both bodies are empty: the Lua mod hooks them on the receiving side. |

## Build

Needs Unreal Engine 4.27 from the Epic Games Launcher (core components are enough, no Visual Studio).

```
powershell -File pak/build_pak.ps1
```

Cooks the project (`-unversioned`, like the game) and packs only `Content/Mods/PDCoopNet` into
`pak/out/PDCoopNet.pak`. The installer puts it in `<game dir>\PenDriverPro\Content\Paks\LogicMods\`.

## Remaking the assets

`make_assets.py` creates both Blueprints and sets the channel's replication defaults (`-MakeAssets`). UE 4.27's
Python cannot add RPC events, so the two events were added in the editor: Custom Event, `Replicates` = Run on
Server / Run on owning Client, `Reliable`, one String input `Msg`. (Pasting the node text works as well:
`K2Node_CustomEvent` with `FunctionFlags=2097344` for ServerSend, `16777408` for ClientSend.)

## Limits (measured, exp123)

- One RPC carries up to 64 KB (`MaximumSize=65536`); a bigger one is refused on the sending side with
  `LogNetPartialBunch: Error` and the connection stays up. The Lua side splits bigger messages.
- Order is kept per channel (reliable RPCs).
- Lua loads the class with `AssetRegistryHelpers:GetAsset` (as BPModLoaderMod does); UE4SS `LoadAsset` returned
  an invalid object for it.
