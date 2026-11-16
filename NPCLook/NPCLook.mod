return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`NPCLook` encountered an error loading the Darktide Mod Framework.")

        new_mod("NPCLook", {
            mod_script = "NPCLook/scripts/mods/NPCLook/NPCLook",
            mod_data = "NPCLook/scripts/mods/NPCLook/NPCLook_data",
            mod_localization = "NPCLook/scripts/mods/NPCLook/NPCLook_localization",
        })
    end,
    load_after = { "ResourceLoader" },
    packages = {},
}
