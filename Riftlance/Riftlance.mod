return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Riftlance` encountered an error loading the Darktide Mod Framework.")

		new_mod("Riftlance", {
			mod_script       = "Riftlance/scripts/mods/Riftlance/Riftlance",
			mod_data         = "Riftlance/scripts/mods/Riftlance/Riftlance_data",
			mod_localization = "Riftlance/scripts/mods/Riftlance/Riftlance_localization",
		})
	end,
	require = { "CustomAssets" },
	load_after = { "CustomAssets" },
	packages = {},
}
