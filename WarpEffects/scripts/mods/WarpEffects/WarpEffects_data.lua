local mod = get_mod("WarpEffects")

local mod_data = {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
}

mod_data.options = {
	widgets = {
		{
			setting_id = "trauma_marker",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "hide_game_marker",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "trauma_explosion",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "voidstrike",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "voidstrike_explosion",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "purgatus",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "void_bolt",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "red_lightning",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "assail",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "shield",
			type = "checkbox",
			default_value = true,
		},
		{
			setting_id = "shield_style",
			type = "dropdown",
			default_value = "hex",
			options = {
				{ text = "shield_style_hex", value = "hex" },
				{ text = "shield_style_clear", value = "clear" },
			},
		},
		{
			setting_id = "brain_burst",
			type = "dropdown",
			default_value = "ghost",
			options = {
				{ text = "brain_burst_off", value = "off" },
				{ text = "brain_burst_rift", value = "rift" },
				{ text = "brain_burst_ghost", value = "ghost" },
			},
		},
	},
}

return mod_data
