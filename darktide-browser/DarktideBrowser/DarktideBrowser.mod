return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`DarktideBrowser` encountered an error loading the Darktide Mod Framework.")

        new_mod("DarktideBrowser", {
            mod_script       = "DarktideBrowser/scripts/mods/DarktideBrowser/DarktideBrowser",
            mod_data         = "DarktideBrowser/scripts/mods/DarktideBrowser/DarktideBrowser_data",
            mod_localization = "DarktideBrowser/scripts/mods/DarktideBrowser/DarktideBrowser_localization",
        })
    end,
    packages = {},
}
