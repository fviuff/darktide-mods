return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`ResourceLoader` encountered an error loading the Darktide Mod Framework.")

        new_mod("ResourceLoader", {
            mod_script = "ResourceLoader/scripts/mods/ResourceLoader/ResourceLoader",
            mod_data = "ResourceLoader/scripts/mods/ResourceLoader/ResourceLoader_data",
            mod_localization = "ResourceLoader/scripts/mods/ResourceLoader/ResourceLoader_localization",
        })
    end,
    packages = {},
}
