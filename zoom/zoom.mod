return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`zoom` encountered an error loading the Darktide Mod Framework.")

		new_mod("zoom", {
			mod_script       = "zoom/scripts/mods/zoom/zoom",
			mod_data         = "zoom/scripts/mods/zoom/zoom_data",
			mod_localization = "zoom/scripts/mods/zoom/zoom_localization",
		})
	end,
	packages = {},
}
