local mod = get_mod("MourningstarPets")

local mod_data = {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
}

mod_data.options = {
	widgets = {
		{
			setting_id = "cat_name",
			type = "text",
			default_value = "Mouser",
			placeholder_text = "cat_name_placeholder",
			max_length = 24,
		},
	},
}

return mod_data
