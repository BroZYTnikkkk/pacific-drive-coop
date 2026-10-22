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

unreal.EditorAssetLibrary.save_directory(FOLDER, only_if_is_dirty=False)
unreal.log("PDCOOP assets saved")
