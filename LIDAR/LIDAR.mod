return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`LIDAR` encountered an error loading the Darktide Mod Framework.")

		new_mod("LIDAR", {
			mod_script = "LIDAR/scripts/mods/LIDAR/LIDAR",
			mod_data = "LIDAR/scripts/mods/LIDAR/LIDAR_data",
			mod_localization = "LIDAR/scripts/mods/LIDAR/LIDAR_localization",
		})
	end,
	packages = {},
}
