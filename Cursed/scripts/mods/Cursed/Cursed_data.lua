local mod = get_mod("Cursed")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			-- Master toggle keybind
			{
				setting_id = "master_toggle",
				type = "keybind",
				default_value = {},
				keybind_global = true,
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_master",
			},

			-- Screensaver: bouncing text
			{
				setting_id = "screensaver_enabled",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "screensaver_count",
						type = "numeric",
						default_value = 8,
						range = { 1, 20 },
						decimals_number = 0,
					},
					{
						setting_id = "screensaver_opacity",
						type = "numeric",
						default_value = 70,
						range = { 10, 100 },
						decimals_number = 0,
					},
					{
						setting_id = "screensaver_speed_mult",
						type = "numeric",
						default_value = 100,
						range = { 25, 300 },
						decimals_number = 0,
					},
				},
			},

			-- FPS Throttle
			{
				setting_id = "throttle_enabled",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "throttle_min_delay",
						type = "numeric",
						default_value = 30,
						range = { 5, 300 },
						decimals_number = 0,
					},
					{
						setting_id = "throttle_max_delay",
						type = "numeric",
						default_value = 120,
						range = { 10, 600 },
						decimals_number = 0,
					},
					{
						setting_id = "throttle_fps",
						type = "numeric",
						default_value = 15,
						range = { 5, 30 },
						decimals_number = 0,
					},
					{
						setting_id = "throttle_duration",
						type = "numeric",
						default_value = 3,
						range = { 1, 10 },
						decimals_number = 0,
					},
				},
			},

			-- Darkness Flash
			{
				setting_id = "darkness_enabled",
				type = "checkbox",
				default_value = false,
				sub_widgets = {
					{
						setting_id = "darkness_min_delay",
						type = "numeric",
						default_value = 20,
						range = { 5, 300 },
						decimals_number = 0,
					},
					{
						setting_id = "darkness_max_delay",
						type = "numeric",
						default_value = 90,
						range = { 10, 600 },
						decimals_number = 0,
					},
					{
						setting_id = "darkness_gamma",
						type = "numeric",
						default_value = -10,
						range = { -15, -3 },
						decimals_number = 0,
					},
					{
						setting_id = "darkness_duration",
						type = "numeric",
						default_value = 5,
						range = { 1, 30 },
						decimals_number = 0,
					},
				},
			},

			-- LIDAR
			{
				setting_id = "lidar_enabled",
				type = "checkbox",
				default_value = false,
				sub_widgets = {
					{
						setting_id = "lidar_interval",
						type = "numeric",
						default_value = 8,
						range = { 3, 60 },
						decimals_number = 1,
					},
					{
						setting_id = "lidar_mode",
						type = "dropdown",
						default_value = "radial",
						options = {
							{ text = "lidar_mode_radial", value = "radial" },
							{ text = "lidar_mode_fov",    value = "fov" },
						},
					},
				},
			},

			-- Zoom Spasm
			{
				setting_id = "zoom_enabled",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "zoom_min_delay",
						type = "numeric",
						default_value = 15,
						range = { 5, 300 },
						decimals_number = 0,
					},
					{
						setting_id = "zoom_max_delay",
						type = "numeric",
						default_value = 60,
						range = { 10, 600 },
						decimals_number = 0,
					},
					{
						setting_id = "zoom_amount",
						type = "numeric",
						default_value = 70,
						range = { 10, 95 },
						decimals_number = 0,
					},
					{
						setting_id = "zoom_duration",
						type = "numeric",
						default_value = 3,
						range = { 1, 10 },
						decimals_number = 1,
					},
				},
			},

			-- Hand Flicker
			{
				setting_id = "flicker_enabled",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "flicker_min_delay",
						type = "numeric",
						default_value = 20,
						range = { 5, 300 },
						decimals_number = 0,
					},
					{
						setting_id = "flicker_max_delay",
						type = "numeric",
						default_value = 90,
						range = { 10, 600 },
						decimals_number = 0,
					},
					{
						setting_id = "flicker_duration",
						type = "numeric",
						default_value = 2,
						range = { 1, 10 },
						decimals_number = 1,
					},
				},
			},

			-- Rave Aura
			{
				setting_id = "rave_enabled",
				type = "checkbox",
				default_value = false,
				sub_widgets = {
					{
						setting_id = "rave_intensity",
						type = "numeric",
						default_value = 50,
						range = { 5, 500 },
						decimals_number = 0,
					},
					{
						setting_id = "rave_falloff",
						type = "numeric",
						default_value = 8,
						range = { 2, 50 },
						decimals_number = 0,
					},
					{
						setting_id = "rave_speed",
						type = "numeric",
						default_value = 100,
						range = { 25, 500 },
						decimals_number = 0,
					},
				},
			},
		},
	},
}
