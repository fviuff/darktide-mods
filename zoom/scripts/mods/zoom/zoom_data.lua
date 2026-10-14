local mod = get_mod("zoom")

local mod_data = {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
}

mod_data.options = {
	widgets = {
		{
			setting_id = "zoom_active",
			type = "checkbox",
			default_value = false,
		},
		{
			setting_id = "zoom_toggle",
			type = "keybind",
			default_value = {},
			keybind_global = true,
			keybind_trigger = "pressed",
			keybind_type = "function_call",
			function_name = "toggle_zoom",
		},
		{
			setting_id = "zoom_in_keybind",
			type = "keybind",
			default_value = { "mouse_wheel_up" },
			keybind_global = true,
			keybind_trigger = "pressed",
			keybind_type = "function_call",
			function_name = "zoom_in_step",
		},
		{
			setting_id = "zoom_out_keybind",
			type = "keybind",
			default_value = { "mouse_wheel_down" },
			keybind_global = true,
			keybind_trigger = "pressed",
			keybind_type = "function_call",
			function_name = "zoom_out_step",
		},
		{
			setting_id = "zoom_level",
			type = "numeric",
			default_value = 50,
			range = { 0, 100 },
		},
		{
			setting_id = "zoom_steps",
			type = "numeric",
			default_value = 10,
			range = { 5, 100 },
		},
		{
			setting_id = "hide_hands",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "show_hands_at_zero",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "block_scroll_wield",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "scroll_cooldown",
			type = "checkbox",
			default_value = false,
		},
		{
			setting_id = "scroll_cooldown_time",
			type = "numeric",
			default_value = 0.10,
			range = { 0.05, 1 },
			decimals_number = 2,
		},
		{
			setting_id = "toggle_cooldown",
			type = "checkbox",
			default_value = false,
		},
		{
			setting_id = "toggle_cooldown_time",
			type = "numeric",
			default_value = 0.10,
			range = { 0.05, 1 },
			decimals_number = 2,
		},
	},
}

return mod_data