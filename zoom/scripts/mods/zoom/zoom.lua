local mod = get_mod("zoom")

local CameraManager = require("scripts/managers/camera/camera_manager")

local data = mod:persistent_table("data")
if data.multiplier == nil then
    data.multiplier = 1.0
end
if data.scroll_timer == nil then
    data.scroll_timer = 0
end
if data.toggle_timer == nil then
    data.toggle_timer = 0
end

local settings = mod:persistent_table("settings")

local LERP = 0.12

local SETTING_MAP = {
    zoom_active = "active",
    zoom_level = "level",
    zoom_steps = "steps",
    hide_hands = "hide",
    show_hands_at_zero = "show_at_zero",
    block_scroll_wield = "block_scroll",
    scroll_cooldown = "scroll_cooldown",
    scroll_cooldown_time = "scroll_cooldown_time",
    toggle_cooldown = "toggle_cooldown",
    toggle_cooldown_time = "toggle_cooldown_time",
}

local function init_settings()
    settings.active = mod:get("zoom_active")
    settings.level = mod:get("zoom_level")
    settings.steps = mod:get("zoom_steps")
    settings.hide = mod:get("hide_hands")
    settings.show_at_zero = mod:get("show_hands_at_zero")
    settings.block_scroll = mod:get("block_scroll_wield")
    settings.scroll_cooldown = mod:get("scroll_cooldown")
    settings.scroll_cooldown_time = mod:get("scroll_cooldown_time")
    settings.toggle_cooldown = mod:get("toggle_cooldown")
    settings.toggle_cooldown_time = mod:get("toggle_cooldown_time")
end

-- Weapon/hands hide - credits to Phantom Arsenal for the method

local function get_first_person_unit()
    local player = Managers.player and Managers.player:local_player(1)
    local player_unit = player and player.player_unit

    if not player_unit or not ScriptUnit.has_extension(player_unit, "first_person_system") then
        return nil
    end

    return ScriptUnit.extension(player_unit, "first_person_system"):first_person_unit()
end

local function set_weapons_visible(visible)
    local fp_unit = get_first_person_unit()

    if not fp_unit or not Unit.alive(fp_unit) then
        return
    end

    if visible then
        Unit.set_shader_pass_flag_for_meshes(fp_unit, "one_bit_alpha", false, true)
        Unit.set_scalar_for_materials(fp_unit, "inv_jitter_alpha", 0, true)
        Unit.set_scalar_for_materials(fp_unit, "alpha_multiplier", 1, true)

        data.weapons_hidden = false
    else
        Unit.set_shader_pass_flag_for_meshes(fp_unit, "one_bit_alpha", true, true)
        Unit.set_scalar_for_materials(fp_unit, "inv_jitter_alpha", 1, true)
        Unit.set_scalar_for_materials(fp_unit, "alpha_multiplier", 0, true)

        data.weapons_hidden = true
    end
end

local function update_weapon_visibility()
    if not settings.hide then
        if data.weapons_hidden then
            set_weapons_visible(true)
        end
        return
    end

    local zoom_level = settings.level
    local show_at_zero = settings.show_at_zero

    local should_hide = settings.active

    if show_at_zero and zoom_level <= 0 then
        should_hide = false
    end

    if should_hide then
        if not data.weapons_hidden then
            set_weapons_visible(false)
        end
    else
        if data.weapons_hidden then
            set_weapons_visible(true)
        end
    end
end

-- FOV

mod:hook(CameraManager, "_update_camera_properties", function(original, self, camera, shadow_cull_camera, camera_nodes, camera_data, viewport_name)
    if camera_data.vertical_fov then
        local target = settings.active and (1.0 - (settings.level / 100) * 0.9) or 1.0

        data.multiplier = math.lerp(data.multiplier, target, LERP)

        if math.abs(data.multiplier - target) < 0.001 then
            data.multiplier = target
        end

        camera_data.vertical_fov = camera_data.vertical_fov * data.multiplier
    end

    original(self, camera, shadow_cull_camera, camera_nodes, camera_data, viewport_name)
end)

-- Block scroll weapon swap while zoomed

mod:hook(CLASS.InputService, "_get", function(func, self, action_name, ...)
    if settings.active and settings.block_scroll and (action_name == "wield_scroll_up" or action_name == "wield_scroll_down" or action_name == "wield_scroll") then
        return false
    end

    return func(self, action_name, ...)
end)

-- Keybind functions

local function is_ui_using_input()
    local ui = Managers.ui
    return ui and ui:using_input()
end

mod.toggle_zoom = function(self)
    if is_ui_using_input() then return end

    if settings.toggle_cooldown and data.toggle_timer > 0 then
        return
    end

    local val = not mod:get("zoom_active")

    mod:set("zoom_active", val, false)

    settings.active = val

    update_weapon_visibility()

    if settings.toggle_cooldown then
        data.toggle_timer = math.max(settings.toggle_cooldown_time or 0.10, 0.05)
    end
end

mod.zoom_in_step = function(self)
    if is_ui_using_input() then return end

    if not settings.active then
        return
    end

    if settings.scroll_cooldown and data.scroll_timer > 0 then
        return
    end

    local level = math.clamp(
        settings.level + settings.steps,
        0,
        100
    )

    settings.level = level

    mod:set("zoom_level", level, false)

    update_weapon_visibility()

    if settings.scroll_cooldown then
        data.scroll_timer = math.max(settings.scroll_cooldown_time or 0.10, 0.05)
    end
end

mod.zoom_out_step = function(self)
    if is_ui_using_input() then return end

    if not settings.active then
        return
    end

    if settings.scroll_cooldown and data.scroll_timer > 0 then
        return
    end

    local level = math.clamp(
        settings.level - settings.steps,
        0,
        100
    )

    settings.level = level

    mod:set("zoom_level", level, false)

    update_weapon_visibility()

    if settings.scroll_cooldown then
        data.scroll_timer = math.max(settings.scroll_cooldown_time or 0.10, 0.05)
    end
end

-- Cooldown timer

mod.update = function(dt)
    if data.scroll_timer > 0 then
        data.scroll_timer = data.scroll_timer - dt
    end
    if data.toggle_timer > 0 then
        data.toggle_timer = data.toggle_timer - dt
    end
end

-- Callbacks

mod.on_game_state_changed = function()
    if data.weapons_hidden then
        set_weapons_visible(true)
    end

    if not mod:get("zoom_active") then
        data.multiplier = 1.0
    end
end

mod.on_setting_changed = function(name)
    local key = SETTING_MAP[name]

    if key then
        settings[key] = mod:get(name)
    end

    if name == "hide_hands" or name == "show_hands_at_zero" then
        update_weapon_visibility()
    end
end

mod.on_disabled = function()
    if data.weapons_hidden then
        set_weapons_visible(true)
    end

    mod:set("zoom_active", false, false)

    settings.active = false
    data.multiplier = 1.0
end

init_settings()