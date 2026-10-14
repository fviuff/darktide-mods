return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Cursed` encountered an error loading the Darktide Mod Framework.")

		new_mod("Cursed", {
			mod_script       = "Cursed/scripts/mods/Cursed/Cursed",
			mod_data         = "Cursed/scripts/mods/Cursed/Cursed_data",
			mod_localization = "Cursed/scripts/mods/Cursed/Cursed_localization",
		})
	end,
	packages = {},
}
