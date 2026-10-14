return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`WarpEffects` encountered an error loading the Darktide Mod Framework.")

		new_mod("WarpEffects", {
			mod_script       = "WarpEffects/scripts/mods/WarpEffects/WarpEffects",
			mod_data         = "WarpEffects/scripts/mods/WarpEffects/WarpEffects_data",
			mod_localization = "WarpEffects/scripts/mods/WarpEffects/WarpEffects_localization",
		})
	end,
	require = { "CustomAssets" },
	load_after = { "CustomAssets" },
	packages = {},
}
