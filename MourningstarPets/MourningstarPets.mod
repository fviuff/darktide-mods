return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`MourningstarPets` encountered an error loading the Darktide Mod Framework.")

		new_mod("MourningstarPets", {
			mod_script       = "MourningstarPets/scripts/mods/MourningstarPets/MourningstarPets",
			mod_data         = "MourningstarPets/scripts/mods/MourningstarPets/MourningstarPets_data",
			mod_localization = "MourningstarPets/scripts/mods/MourningstarPets/MourningstarPets_localization",
		})
	end,
	require = { "CustomAssets" },
	load_after = { "CustomAssets" },
	packages = {},
}
