local mod = get_mod("AuspexChess")

local function replacement_options()
    return {
        { text = "opt_replacement_chess", value = "chess" },
        { text = "opt_replacement_stock", value = "stock" },
    }
end

local function replacement_widget(setting_id)
    return {
        setting_id = setting_id,
        type = "dropdown",
        default_value = "chess",
        options = replacement_options(),
    }
end

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "replacement_group",
                type = "group",
                sub_widgets = {
                    replacement_widget("balance_replacement"),
                    replacement_widget("decode_search_replacement"),
                    replacement_widget("decode_symbols_replacement"),
                    replacement_widget("drill_replacement"),
                },
            },
            {
                setting_id = "puzzle_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "display_mode",
                        type = "dropdown",
                        default_value = "overlay",
                        options = {
                            { text = "opt_display_overlay", value = "overlay" },
                            { text = "opt_display_auspex", value = "auspex" },
                        },
                    },
                    {
                        setting_id = "puzzle_difficulty",
                        type = "dropdown",
                        default_value = "normal",
                        options = {
                            { text = "opt_difficulty_easy", value = "easy" },
                            { text = "opt_difficulty_normal", value = "normal" },
                            { text = "opt_difficulty_hard", value = "hard" },
                            { text = "opt_difficulty_expert", value = "expert" },
                            { text = "opt_difficulty_mixed", value = "mixed" },
                        },
                    },
                    {
                        setting_id = "board_scale",
                        type = "dropdown",
                        default_value = 1.00,
                        options = {
                            { text = "opt_board_small", value = 0.80 },
                            { text = "opt_board_compact", value = 0.90 },
                            { text = "opt_board_default", value = 1.00 },
                            { text = "opt_board_large", value = 1.15 },
                            { text = "opt_board_larger", value = 1.30 },
                        },
                    },
                    {
                        setting_id = "wrong_move_delay",
                        type = "dropdown",
                        default_value = 0.50,
                        options = {
                            { text = "opt_wrong_move_short", value = 0.25 },
                            { text = "opt_wrong_move_default", value = 0.50 },
                            { text = "opt_wrong_move_long", value = 1.00 },
                        },
                    },
                },
            },
        },
    },
}
