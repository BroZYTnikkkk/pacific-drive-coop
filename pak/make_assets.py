# Creates the pak mod's Blueprints (run by build_pak.ps1 through the editor's pythonscript commandlet).
# ModActor: BPModLoader's bootstrap (spawned locally on every machine, does nothing).
# PDCoopChannel: the replicated channel; the host spawns one per remote player, owned by its controller.
# The two RPC events (ServerSend / ClientSend) are added in the editor by hand (UE 4.27 Python cannot add them).
import unreal

FOLDER = "/Game/Mods/PDCoopNet"


def make_bp(name):
    path = FOLDER + "/" + name
    if unreal.EditorAssetLibrary.does_asset_exist(path):
        return unreal.EditorAssetLibrary.load_asset(path)
    factory = unreal.BlueprintFactory()
    factory.set_editor_property("parent_class", unreal.Actor)
    tools = unreal.AssetToolsHelpers.get_asset_tools()
    return tools.create_asset(name, FOLDER, unreal.Blueprint, factory)


make_bp("ModActor")
make_bp("PDCoopChannel")
cdo = unreal.get_default_object(unreal.EditorAssetLibrary.load_blueprint_class(FOLDER + "/PDCoopChannel"))
for prop, value in (
    ("replicates", True),
    ("only_relevant_to_owner", True),
    ("always_relevant", False),
    ("replicate_movement", False),
    ("net_update_frequency", 1.0),
    ("hidden", True),
):
    cdo.set_editor_property(prop, value)
    unreal.log("PDCOOP %s = %s" % (prop, cdo.get_editor_property(prop)))

# PDCoopItemMarker: one per host world item (the game's item actors cannot be replicated: player 2's game reads the
# missing item data of the proxy and crashes, exp143). Movement replicated, nothing to draw, no collision; player 2's
# own item follows it.
make_bp("PDCoopItemMarker")
mk = unreal.get_default_object(unreal.EditorAssetLibrary.load_blueprint_class(FOLDER + "/PDCoopItemMarker"))
for prop, value in (
    ("replicates", True),
    ("replicate_movement", True),
    ("always_relevant", False),
    ("net_cull_distance_squared", 2.25e10),
    ("net_update_frequency", 4.0),
    ("min_net_update_frequency", 1.0),
    # not hidden: the engine never replicates a hidden actor without collision (exp144); it has nothing to draw
    ("hidden", False),
):
    mk.set_editor_property(prop, value)
    unreal.log("PDCOOP marker %s = %s" % (prop, mk.get_editor_property(prop)))

# M_PDCoopBody: the remote players' body material (the game's mannequin has none of its own in the cooked game);
# one colour parameter so each player gets their own colour (MaterialInstanceDynamic from Lua)
MAT = FOLDER + "/M_PDCoopBody"
if not unreal.EditorAssetLibrary.does_asset_exist(MAT):
    tools = unreal.AssetToolsHelpers.get_asset_tools()
    mat = tools.create_asset("M_PDCoopBody", FOLDER, unreal.Material, unreal.MaterialFactoryNew())
    mel = unreal.MaterialEditingLibrary
    color = mel.create_material_expression(mat, unreal.MaterialExpressionVectorParameter, -400, 0)
    color.set_editor_property("parameter_name", "Color")
    color.set_editor_property("default_value", unreal.LinearColor(0.8, 0.35, 0.1, 1.0))
    mel.connect_material_property(color, "", unreal.MaterialProperty.MP_BASE_COLOR)
    rough = mel.create_material_expression(mat, unreal.MaterialExpressionConstant, -400, 200)
    rough.set_editor_property("r", 0.6)
    mel.connect_material_property(rough, "", unreal.MaterialProperty.MP_ROUGHNESS)
    mat.set_editor_property("used_with_skeletal_mesh", True)
    mel.recompile_material(mat)
    unreal.log("PDCOOP material created")

unreal.EditorAssetLibrary.save_directory(FOLDER, only_if_is_dirty=False)
unreal.log("PDCOOP assets saved")
