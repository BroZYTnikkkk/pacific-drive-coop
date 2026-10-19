// assetdump: cooked UE4.27 .uasset(+.uexp) -> UAssetAPI JSON, using the game's .usmap for unversioned properties.
// usage: assetdump <mappings.usmap> <in.uasset> <out.json>
using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

if (args.Length != 3) { Console.Error.WriteLine("usage: assetdump <mappings.usmap> <in.uasset> <out.json>"); return 2; }
var mappings = new Usmap(args[0]);
var asset = new UAsset(args[1], EngineVersion.VER_UE4_27, mappings);
File.WriteAllText(args[2], asset.SerializeJson(true));
Console.WriteLine($"ok {args[1]} exports={asset.Exports.Count} imports={asset.Imports.Count}");
return 0;
