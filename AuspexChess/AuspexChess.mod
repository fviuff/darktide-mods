return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`AuspexChess` encountered an error loading the Darktide Mod Framework.")

        new_mod("AuspexChess", {
            mod_script = "AuspexChess/scripts/mods/AuspexChess/AuspexChess",
            mod_data = "AuspexChess/scripts/mods/AuspexChess/AuspexChess_data",
            mod_localization = "AuspexChess/scripts/mods/AuspexChess/AuspexChess_localization",
        })
    end,
    packages = {},
}
