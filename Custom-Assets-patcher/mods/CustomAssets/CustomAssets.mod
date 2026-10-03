return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`CustomAssets` encountered an error loading the Darktide Mod Framework.")
        new_mod("CustomAssets", {
            mod_script = "CustomAssets/scripts/mods/CustomAssets/CustomAssets",
            mod_data = "CustomAssets/scripts/mods/CustomAssets/CustomAssets_data",
            mod_localization = "CustomAssets/scripts/mods/CustomAssets/CustomAssets_localization",
        })
    end,
    version = "1.0.2,
    require = {},
    load_after = {},
    packages = {},
}
