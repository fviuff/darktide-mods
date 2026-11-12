return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`VoiceVolume` encountered an error loading the Darktide Mod Framework.")

        new_mod("VoiceVolume", {
            mod_script       = "VoiceVolume/scripts/mods/VoiceVolume/VoiceVolume",
            mod_data         = "VoiceVolume/scripts/mods/VoiceVolume/VoiceVolume_data",
            mod_localization = "VoiceVolume/scripts/mods/VoiceVolume/VoiceVolume_localization",
        })
    end,
    packages = {},
}
