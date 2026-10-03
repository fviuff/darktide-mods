local mod = get_mod("NPCLook")

local STUDIO_FONTS = {
    "machine_medium",
    "proxima_nova_bold",
    "proxima_nova_medium",
    "itc_novarese_medium",
    "itc_novarese_bold",
    "mono_tide_medium",
    "friz_quadrata",
    "arial",
}

local font_options = {}

for i = 1, #STUDIO_FONTS do
    font_options[i] = {
        text = "studio_font_" .. STUDIO_FONTS[i],
        value = STUDIO_FONTS[i],
    }
end

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = false,
    options = {
        widgets = {
            {
                setting_id = "open_studio_keybind",
                type = "keybind",
                default_value = {},
                keybind_trigger = "pressed",
                keybind_type = "function_call",
                function_name = "npclook_open_studio",
            },
            {
                setting_id = "studio_text_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "studio_font",
                        type = "dropdown",
                        default_value = "machine_medium",
                        options = font_options,
                    },
                    {
                        setting_id = "studio_text_scale",
                        type = "numeric",
                        default_value = 100,
                        range = { 70, 150 },
                        decimals_number = 0,
                    },
                },
            },
            {
                setting_id = "loadout_button_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "loadout_button_visible",
                        type = "checkbox",
                        default_value = true,
                    },
                    {
                        setting_id = "loadout_button_x",
                        type = "numeric",
                        default_value = 1560,
                        range = { 0, 1590 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "loadout_button_y",
                        type = "numeric",
                        default_value = 560,
                        range = { 0, 1000 },
                        decimals_number = 0,
                    },
                },
            },
        },
    },
}
