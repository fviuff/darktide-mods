local LoadoutPresets = {}

local STORAGE_KEY = "loadout_preset_pins_v1"
local DEFAULT_PIN = {}
local APPLY_DELAY = 0.35
local RETRY_DELAY = 0.5
local MAX_RETRIES = 30
local SYNC_TIMEOUT = 10
local CONTEXT_CHECK_INTERVAL = 0.25
local CONTEXT_CHECK_COUNT = 8
local LOAD_IN_CONTEXT_CHECK_COUNT = 40
local LIST_WIDTH = 330
local HEADER_HEIGHT = 40
local ROW_HEIGHT = 40
local ROW_SPACING = 4
local FOOTER_HEIGHT = 34
local ROWS_PER_PAGE = 8
local MIN_ROWS_PER_PAGE = 3
local SCREEN_BOTTOM = 1040
local DEFAULT_X = 1560
-- Darktide 1.13 places the player stats panel under the profile presets.
local DEFAULT_Y = 560
local BASE_Z = 220

local function normalized_string(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function call_method(object, name, ...)
    local method = object and object[name]

    if type(method) ~= "function" then
        return false, name .. " unavailable"
    end

    return pcall(method, object, ...)
end

local function player_character_id(player)
    local ok, value = call_method(player, "character_id")

    return ok and value ~= nil and normalized_string(tostring(value)) or nil
end

local function profile_character_id(profile)
    local value = type(profile) == "table" and profile.character_id

    return value ~= nil and normalized_string(tostring(value)) or nil
end

local function player_identity(player)
    local peer_ok, peer_id = call_method(player, "peer_id")
    local local_ok, local_player_id = call_method(player, "local_player_id")

    if not peer_ok or not local_ok then
        return nil, nil
    end

    return peer_id, local_player_id
end

function LoadoutPresets.new(dependencies)
    dependencies = dependencies or {}

    local mod = dependencies.mod
    local loc = dependencies.loc
    local preset_store = dependencies.preset_store
    local profile_utils = dependencies.profile_utils
    local profile_utils_loaded = profile_utils ~= nil
    local service = {
        pins = nil,
        pending = nil,
        context_check_elapsed = 0,
        context_checks_remaining = CONTEXT_CHECK_COUNT,
        seen_character_id = nil,
        seen_loadout_id = nil,
        seen_context = false,
        sync_in_flight = false,
        sync_timeout = nil,
        sync_host = nil,
        sync_peer_id = nil,
        sync_local_player_id = nil,
        latest_sync_change_id = nil,
        preset_revision = 0,
        managed_character_id = nil,
        managed_loadout_id = nil,
        inventory_states = setmetatable({}, { __mode = "k" }),
    }

    local function local_player()
        return dependencies.get_local_player and dependencies.get_local_player() or nil
    end

    local function button_visible()
        return not dependencies.button_visible or dependencies.button_visible() ~= false
    end

    local function button_position()
        local x, y

        if dependencies.button_position then
            x, y = dependencies.button_position()
        end

        x = math.clamp(tonumber(x) or DEFAULT_X, 0, 1920 - LIST_WIDTH)
        y = math.clamp(tonumber(y) or DEFAULT_Y, 0, SCREEN_BOTTOM - HEADER_HEIGHT)

        return math.floor(x + 0.5), math.floor(y + 0.5)
    end

    -- Shorten the list instead of running it off screen.
    local function rows_per_page(base_y)
        local available = SCREEN_BOTTOM - (base_y + HEADER_HEIGHT + ROW_SPACING + FOOTER_HEIGHT)
        local rows = math.floor(available / (ROW_HEIGHT + ROW_SPACING))

        return math.clamp(rows, MIN_ROWS_PER_PAGE, ROWS_PER_PAGE)
    end

    local function load_pins()
        if service.pins then
            return service.pins
        end

        local stored = mod:get(STORAGE_KEY)
        local pins = {}

        if type(stored) == "table" then
            for character_id, loadouts in pairs(stored) do
                if type(character_id) == "string" and type(loadouts) == "table" then
                    local character_pins = {}

                    for loadout_id, stored_value in pairs(loadouts) do
                        local pin_value = type(stored_value) == "table"
                            and stored_value.default == true and DEFAULT_PIN
                            or normalized_string(stored_value)

                        if type(loadout_id) == "string" and pin_value then
                            character_pins[loadout_id] = pin_value
                        end
                    end

                    if next(character_pins) then
                        pins[character_id] = character_pins
                    end
                end
            end
        end

        service.pins = pins

        return pins
    end

    local function save_pins()
        local serialized = {}

        for character_id, values in pairs(load_pins()) do
            local character_values = {}

            for loadout_id, pin_value in pairs(values) do
                character_values[loadout_id] = pin_value == DEFAULT_PIN
                    and { default = true } or pin_value
            end

            serialized[character_id] = character_values
        end

        mod:set(STORAGE_KEY, serialized, false)
    end

    local function character_data(character_id)
        local managers = rawget(_G, "Managers")
        local save_manager = managers and managers.save
        local ok, data = call_method(save_manager, "character_data", character_id)

        return ok and type(data) == "table" and data or nil
    end

    local function saved_loadout_id(character_id)
        local data = character_id and character_data(character_id)
        local loadout_id = data and data.active_profile_preset_id

        return loadout_id ~= nil and normalized_string(tostring(loadout_id)) or nil
    end

    local function active_context()
        local player = local_player()
        local character_id = player_character_id(player)

        if not character_id then
            return nil, nil, player
        end

        local loadout_id = saved_loadout_id(character_id)

        if loadout_id then
            return character_id, loadout_id, player
        end

        if not profile_utils_loaded then
            local ok, loaded = pcall(require, "scripts/utilities/profile_utils")

            profile_utils = ok and loaded or nil
            profile_utils_loaded = true
        end

        if not profile_utils or type(profile_utils.get_active_profile_preset_id) ~= "function" then
            return character_id, nil, player
        end

        local ok, active_id = pcall(profile_utils.get_active_profile_preset_id)

        return character_id, ok and active_id ~= nil and tostring(active_id) or nil, player
    end

    local function profile_context(profile)
        local character_id = profile_character_id(profile)

        return character_id, saved_loadout_id(character_id)
    end

    local function character_pins(character_id, create)
        local pins = load_pins()
        local values = character_id and pins[character_id]

        if not values and create and character_id then
            values = {}
            pins[character_id] = values
        end

        return values
    end

    local function pinned_value(character_id, loadout_id)
        local values = character_pins(character_id, false)

        return values and loadout_id and values[loadout_id] or nil
    end

    local function preset_by_name(name)
        name = normalized_string(name)

        if not name then
            return nil
        end

        for i = 1, #(preset_store.items or {}) do
            local preset = preset_store.items[i]

            if preset and preset.name == name and type(preset.code) == "string" then
                return preset
            end
        end

        return nil
    end

    local function rebuild_inventory_views()
        for _, state in pairs(service.inventory_states) do
            state.rebuild = true
        end
    end

    local function request_inventory_refresh(character_id)
        for _, state in pairs(service.inventory_states) do
            state.refresh_character_id = character_id
        end
    end

    local function request_context_checks(count)
        service.context_checks_remaining = math.max(
            service.context_checks_remaining,
            math.max(math.floor(tonumber(count) or CONTEXT_CHECK_COUNT), 1)
        )
        service.context_check_elapsed = 0
    end

    local function schedule(character_id, loadout_id, delay, reconcile, sync_change_id)
        if not character_id or not loadout_id then
            service.pending = nil
            return
        end

        local pin_value = pinned_value(character_id, loadout_id)
        local needs_reconcile = reconcile == true
            and service.managed_character_id ~= nil

        if not pin_value and not needs_reconcile then
            service.pending = nil
            return
        end

        service.pending = {
            character_id = character_id,
            loadout_id = loadout_id,
            delay = math.max(tonumber(delay) or APPLY_DELAY, 0),
            retries = 0,
            reconcile = needs_reconcile,
            sync_change_id = sync_change_id,
        }
    end

    local function remove_pin(character_id, loadout_id)
        local values = character_pins(character_id, false)

        if not values or not loadout_id or values[loadout_id] == nil then
            return false
        end

        values[loadout_id] = nil

        if next(values) == nil then
            load_pins()[character_id] = nil
        end

        return true
    end

    local function clear_managed_look()
        service.managed_character_id = nil
        service.managed_loadout_id = nil
    end

    local function active_look_belongs_to(character_id)
        if not dependencies.has_active_look or dependencies.has_active_look() ~= true then
            return false
        end

        local active_character_id = dependencies.active_look_character_id
            and dependencies.active_look_character_id() or nil

        return active_character_id == nil or tostring(active_character_id) == tostring(character_id)
    end

    local function clear_foreign_look(character_id)
        if dependencies.clear_foreign_look then
            local ok, cleared = pcall(dependencies.clear_foreign_look, character_id)

            if ok and cleared ~= false then
                clear_managed_look()
                return true
            end
        end

        return false
    end

    local function reset_current_look(character_id)
        if dependencies.has_active_look and dependencies.has_active_look() == true
            and not active_look_belongs_to(character_id) then
            return clear_foreign_look(character_id)
        end

        local ok, reset_ok, err, changed = pcall(dependencies.reset_look)

        if not ok then
            return false, reset_ok
        end

        return reset_ok == true, err, changed ~= false
    end


    local function apply_pending(dt)
        local pending = service.pending

        if not pending or service.sync_in_flight then
            return
        end

        pending.delay = pending.delay - dt

        if pending.delay > 0 then
            return
        end

        local character_id, loadout_id = active_context()

        if character_id ~= pending.character_id or loadout_id ~= pending.loadout_id then
            service.pending = nil
            return
        end

        if dependencies.game_ready then
            local ready_ok, ready = pcall(dependencies.game_ready)

            if not ready_ok then
                pending.retries = pending.retries + 1

                if pending.retries >= MAX_RETRIES then
                    service.pending = nil
                    mod:warning("Could not check loadout look readiness: %s", tostring(ready))
                else
                    pending.delay = RETRY_DELAY
                end

                return
            elseif ready ~= true then
                pending.retries = pending.retries + 1

                if pending.retries >= MAX_RETRIES then
                    service.pending = nil
                else
                    pending.delay = RETRY_DELAY
                end

                return
            end
        end

        if pending.sync_change_id ~= nil
            and pending.sync_change_id ~= service.latest_sync_change_id then
            service.pending = nil
            return
        end

        local pin_value = pinned_value(character_id, loadout_id)
        local ok
        local err
        local applied_preset = false
        local changed = true

        if pin_value == DEFAULT_PIN then
            ok, err, changed = reset_current_look(character_id)
        elseif pin_value then
            local preset = preset_by_name(pin_value)

            if preset then
                local call_ok, import_ok, import_error = pcall(
                    dependencies.import_code,
                    preset.code
                )

                if call_ok then
                    ok, err = import_ok, import_error
                    applied_preset = import_ok == true
                else
                    ok, err = false, import_ok
                end
            else
                remove_pin(character_id, loadout_id)
                save_pins()
                rebuild_inventory_views()
                service.pending = nil
                return
            end
        elseif pending.reconcile then
            if dependencies.has_active_look and dependencies.has_active_look() == true then
                ok, err, changed = reset_current_look(character_id)
            else
                ok = true
                changed = false
            end
        else
            service.pending = nil
            return
        end

        if ok then
            service.pending = nil

            if applied_preset then
                service.managed_character_id = character_id
                service.managed_loadout_id = loadout_id
            else
                clear_managed_look()
            end

            -- A reconcile that left the vanilla look untouched must not respawn inventory characters.
            if changed ~= false then
                request_inventory_refresh(character_id)
                rebuild_inventory_views()
            end

            return
        end

        pending.retries = pending.retries + 1

        if pending.retries >= MAX_RETRIES then
            service.pending = nil
            mod:warning(
                "Could not apply the loadout look after %d attempts: %s",
                MAX_RETRIES,
                tostring(err)
            )
            return
        end

        pending.delay = RETRY_DELAY
    end

    local function observe_active_context()
        local character_id, loadout_id = active_context()

        if not character_id or not loadout_id then
            return
        end

        if not service.seen_context then
            service.seen_context = true
            service.seen_character_id = character_id
            service.seen_loadout_id = loadout_id
            rebuild_inventory_views()
            schedule(character_id, loadout_id, APPLY_DELAY, service.managed_character_id ~= nil)
            return
        end

        local character_changed = service.seen_character_id ~= character_id
        local loadout_changed = service.seen_loadout_id ~= loadout_id

        if not character_changed and not loadout_changed then
            return
        end

        service.seen_character_id = character_id
        service.seen_loadout_id = loadout_id
        rebuild_inventory_views()

        -- Do not mutate the visual loadout from context observation. A profile-preset
        -- selection can be observed before PackageSynchronizer has started its native
        -- transaction. The pending reconciliation pauses automatically once sync begins.
        schedule(character_id, loadout_id, APPLY_DELAY, character_changed or loadout_changed)
    end

    function service.active()
        local character_id, loadout_id = active_context()

        return character_id, loadout_id, pinned_value(character_id, loadout_id)
    end

    function service.profile_selection(profile)
        local character_id, loadout_id = profile_context(profile)
        local pin_value = pinned_value(character_id, loadout_id)

        if pin_value == DEFAULT_PIN then
            return "default", nil, character_id, loadout_id
        elseif pin_value then
            local preset = preset_by_name(pin_value)

            if preset then
                return "preset", preset, character_id, loadout_id
            end
        end

        return "none", nil, character_id, loadout_id
    end

    function service.set_pin(pin_value)
        local character_id, loadout_id = active_context()

        if not character_id or not loadout_id then
            return false, loc("feedback_loadout_preset_unavailable")
        end

        if pin_value == nil then
            remove_pin(character_id, loadout_id)
            save_pins()
            rebuild_inventory_views()

            if service.pending and service.pending.character_id == character_id
                and service.pending.loadout_id == loadout_id then
                service.pending = nil
            end

            if service.managed_character_id == character_id
                and service.managed_loadout_id == loadout_id then
                clear_managed_look()
            end

            return true
        end

        if pin_value ~= DEFAULT_PIN then
            local preset = preset_by_name(pin_value)

            if not preset then
                return false, loc("feedback_select_player_preset")
            end

            pin_value = preset.name
        end

        local values = character_pins(character_id, true)

        values[loadout_id] = pin_value
        save_pins()
        rebuild_inventory_views()
        schedule(character_id, loadout_id, 0)

        return true
    end

    function service.preset_deleted(name)
        local changed = false

        for character_id, values in pairs(load_pins()) do
            for loadout_id, pin_value in pairs(values) do
                if pin_value == name then
                    values[loadout_id] = nil
                    changed = true

                    if service.managed_character_id == character_id
                        and service.managed_loadout_id == loadout_id then
                        clear_managed_look()
                    end
                end
            end

            if next(values) == nil then
                service.pins[character_id] = nil
            end
        end

        if changed then
            save_pins()
        end

        service.presets_changed()
    end

    function service.settings_changed()
        rebuild_inventory_views()
    end

    function service.presets_changed()
        service.preset_revision = service.preset_revision + 1
        rebuild_inventory_views()

        if dependencies.invalidate_profile_cache then
            dependencies.invalidate_profile_cache()
        end
    end

    local function is_local_player(peer_id, local_player_id)
        local local_peer_id, local_id = player_identity(local_player())

        return local_peer_id ~= nil and local_id ~= nil
            and peer_id == local_peer_id and local_player_id == local_id
    end

    function service.before_profile_sync(host, peer_id, local_player_id)
        if not is_local_player(peer_id, local_player_id) then
            return
        end

        -- PackageSynchronizer owns native unequip, package replacement and re-equip.
        -- NPC Look must remain completely passive until the newest transaction finishes.
        service.sync_in_flight = true
        service.sync_timeout = SYNC_TIMEOUT
        service.sync_host = host
        service.sync_peer_id = peer_id
        service.sync_local_player_id = local_player_id
        service.pending = nil
    end

    function service.profile_sync_started(host, peer_id, local_player_id, sync_data)
        if not is_local_player(peer_id, local_player_id) then
            return
        end

        service.sync_host = host
        service.sync_peer_id = peer_id
        service.sync_local_player_id = local_player_id
        service.sync_in_flight = true
        service.sync_timeout = SYNC_TIMEOUT
        service.latest_sync_change_id = sync_data and sync_data.sync_change_id or nil
    end

    function service.after_profile_sync(peer_id, local_player_id, sync_data)
        if not is_local_player(peer_id, local_player_id) then
            return
        end

        local sync_change_id = sync_data and sync_data.sync_change_id or nil

        if service.latest_sync_change_id ~= nil
            and sync_change_id ~= service.latest_sync_change_id then
            return
        end

        service.sync_in_flight = false
        service.sync_timeout = nil

        local character_id, loadout_id = active_context()

        service.seen_context = character_id ~= nil and loadout_id ~= nil
        service.seen_character_id = character_id
        service.seen_loadout_id = loadout_id
        rebuild_inventory_views()

        -- Reconcile on the normal update path, after the native hook chain has returned.
        -- This is required even for an unpinned destination because a previously managed
        -- look may still occupy slots whose native items did not change between presets.
        schedule(character_id, loadout_id, 0, true, sync_change_id)
        request_context_checks()
    end

    function service.profile_preset_selection_changed()
        local character_id, loadout_id = active_context()
        local changed = service.seen_context
            and character_id ~= nil and loadout_id ~= nil
            and (character_id ~= service.seen_character_id
                or loadout_id ~= service.seen_loadout_id)

        if changed and not service.sync_in_flight then
            -- The native preset event has returned without starting a package sync.
            -- Reconcile after the existing short apply delay. If a sync starts before
            -- then, the passive pre-sync hook cancels this request and the after-sync
            -- hook schedules the final reconciliation instead.
            service.seen_character_id = character_id
            service.seen_loadout_id = loadout_id
            schedule(character_id, loadout_id, APPLY_DELAY, true)
            rebuild_inventory_views()
        end

        request_context_checks()
    end

    function service.game_state_changed(status, state_name)
        if state_name ~= "GameplayStateRun" then
            return
        end

        service.context_check_elapsed = 0

        if status == "enter" then
            service.seen_context = false
            service.seen_character_id = nil
            service.seen_loadout_id = nil
            request_context_checks(LOAD_IN_CONTEXT_CHECK_COUNT)
            observe_active_context()
        else
            service.pending = nil
            service.context_checks_remaining = 0
            service.seen_context = false
            service.seen_character_id = nil
            service.seen_loadout_id = nil
        end
    end

    function service.update(dt)
        dt = math.max(tonumber(dt) or 0, 0)

        if service.sync_timeout then
            service.sync_timeout = service.sync_timeout - dt

            if service.sync_timeout <= 0 then
                local host = service.sync_host
                local peer_syncs = host and host._syncs and host._syncs[service.sync_peer_id]
                local active_sync = peer_syncs and peer_syncs[service.sync_local_player_id]

                if active_sync then
                    service.sync_timeout = SYNC_TIMEOUT
                else
                    service.sync_timeout = nil
                    service.sync_in_flight = false
                    request_context_checks()

                    local character_id, loadout_id = active_context()
                    schedule(character_id, loadout_id, 0, true, service.latest_sync_change_id)
                end
            end
        end

        apply_pending(dt)

        if service.sync_in_flight or service.context_checks_remaining <= 0 then
            return
        end

        service.context_check_elapsed = service.context_check_elapsed + dt

        if service.context_check_elapsed < CONTEXT_CHECK_INTERVAL then
            return
        end

        service.context_check_elapsed = 0
        service.context_checks_remaining = service.context_checks_remaining - 1
        observe_active_context()
    end

    local function copy_color(source, target)
        if not source or not target then
            return
        end

        for i = 1, 4 do
            target[i] = source[i]
        end
    end

    local function button_state_color(content, style)
        local hotspot = content.hotspot or {}
        local color = style.color or style.text_color
        local target

        if hotspot.disabled then
            target = style.disabled_color or style.default_color
        elseif hotspot.is_selected or hotspot.is_focused then
            target = style.selected_color or style.hover_color or style.default_color
        elseif hotspot.is_hover then
            target = style.hover_color or style.default_color
        else
            target = style.default_color
        end

        copy_color(target, color)
    end

    local function button_gradient_change(content, style)
        button_state_color(content, style)

        local hotspot = content.hotspot or {}
        local color = style.color

        if color and not hotspot.disabled then
            if hotspot.is_selected or hotspot.is_focused then
                color[1] = math.max(color[1] or 0, 225)
            elseif hotspot.is_hover then
                color[1] = math.max(color[1] or 0, 205)
            end
        end
    end

    local function button_text_change(content, style)
        content.text = content.original_text or content.text or ""
        button_state_color(content, style)
    end

    local function styled_button_definition(UIWidget, UIFontSettings, UISoundEvents, width, height)
        local text_style = table.clone(UIFontSettings.button_primary)

        text_style.offset = { 0, 0, 6 }
        text_style.text_horizontal_alignment = "center"
        text_style.text_vertical_alignment = "center"
        text_style.font_size = math.max((text_style.font_size or 20) - 2, 16)
        text_style.text_color = Color.terminal_text_header(255, true)
        text_style.default_color = Color.terminal_text_header(255, true)
        text_style.hover_color = Color.ui_terminal(255, true)
        text_style.selected_color = Color.ui_terminal(255, true)
        text_style.disabled_color = Color.ui_grey_medium(180, true)

        local inset = { -14, -8 }
        local passes = {
            {
                content_id = "hotspot",
                pass_type = "hotspot",
                content = {
                    on_released_sound = nil,
                    on_hover_sound = UISoundEvents.default_mouse_hover,
                    on_pressed_sound = UISoundEvents.default_click,
                },
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/backgrounds/terminal_basic",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    scale_to_material = true,
                    size_addition = { 2, 12 },
                    color = Color.terminal_grid_background(255, true),
                    offset = { 0, 0, 0 },
                },
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/backgrounds/default_square",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    size_addition = inset,
                    color = Color.terminal_background(255, true),
                    default_color = Color.terminal_background(255, true),
                    hover_color = Color.terminal_background_gradient(255, true),
                    selected_color = Color.terminal_background_selected(255, true),
                    disabled_color = Color.terminal_background(120, true),
                    offset = { 0, 0, 1 },
                },
                change_function = button_state_color,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/gradients/gradient_vertical",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    size_addition = inset,
                    color = Color.terminal_background_gradient(155, true),
                    default_color = Color.terminal_background_gradient(155, true),
                    hover_color = Color.terminal_background_gradient(205, true),
                    selected_color = Color.terminal_background_gradient(225, true),
                    disabled_color = Color.terminal_background_gradient(70, true),
                    offset = { 0, 0, 2 },
                },
                change_function = button_gradient_change,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/frames/inner_shadow_medium",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    size_addition = inset,
                    color = Color.terminal_frame(180, true),
                    default_color = Color.terminal_frame(180, true),
                    hover_color = Color.terminal_frame_hover(255, true),
                    selected_color = Color.terminal_frame_selected(255, true),
                    disabled_color = Color.terminal_frame(80, true),
                    offset = { 0, 0, 3 },
                },
                change_function = button_state_color,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/frames/frame_tile_2px",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    scale_to_material = true,
                    size_addition = inset,
                    color = Color.terminal_frame(255, true),
                    default_color = Color.terminal_frame(255, true),
                    hover_color = Color.terminal_frame_hover(255, true),
                    selected_color = Color.terminal_frame_selected(255, true),
                    disabled_color = Color.terminal_frame(100, true),
                    offset = { 0, 0, 4 },
                },
                change_function = button_state_color,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/frames/frame_corner_2px",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    scale_to_material = true,
                    size_addition = inset,
                    color = Color.terminal_corner(255, true),
                    default_color = Color.terminal_corner(255, true),
                    hover_color = Color.terminal_corner_hover(255, true),
                    selected_color = Color.terminal_corner_selected(255, true),
                    disabled_color = Color.terminal_corner(100, true),
                    offset = { 0, 0, 5 },
                },
                change_function = button_state_color,
            },
            {
                pass_type = "text",
                style_id = "text",
                value_id = "text",
                style = text_style,
                change_function = button_text_change,
            },
        }

        return UIWidget.create_definition(passes, "screen", {
            original_text = "",
            text = "",
        }, { width, height })
    end

    local function create_view_widget(view, name, definition)
        if not view or type(view._create_widget) ~= "function" then
            return nil
        end

        local widget = view:_create_widget(name, definition)

        if widget and type(view._widgets) == "table" then
            view._widgets[#view._widgets + 1] = widget
        end

        return widget
    end

    local function set_widget_text(widget, value)
        if not widget or not widget.content then
            return
        end

        value = tostring(value or "")
        widget.content.original_text = value
        widget.content.text = value
    end

    local function create_inventory_state(view)
        if service.inventory_states[view] then
            return service.inventory_states[view]
        end

        local ui_ok, UIWidget = pcall(require, "scripts/managers/ui/ui_widget")
        local font_ok, UIFontSettings = pcall(
            require,
            "scripts/managers/ui/ui_font_settings"
        )
        local sound_ok, UISoundEvents = pcall(
            require,
            "scripts/settings/ui/ui_sound_events"
        )

        if not ui_ok or not font_ok or not sound_ok then
            return nil
        end

        local state = {
            open = false,
            page = 1,
            page_count = 1,
            base_x = DEFAULT_X,
            base_y = DEFAULT_Y,
            rows_per_page = ROWS_PER_PAGE,
            rebuild = true,
            preset_revision = -1,
            header = create_view_widget(
                view,
                "npclook_loadout_preset_header",
                styled_button_definition(UIWidget, UIFontSettings, UISoundEvents, LIST_WIDTH, HEADER_HEIGHT)
            ),
            previous = create_view_widget(
                view,
                "npclook_loadout_preset_previous",
                styled_button_definition(UIWidget, UIFontSettings, UISoundEvents, 44, FOOTER_HEIGHT)
            ),
            next = create_view_widget(
                view,
                "npclook_loadout_preset_next",
                styled_button_definition(UIWidget, UIFontSettings, UISoundEvents, 44, FOOTER_HEIGHT)
            ),
            page_label = create_view_widget(
                view,
                "npclook_loadout_preset_page",
                styled_button_definition(
                    UIWidget,
                    UIFontSettings,
                    UISoundEvents,
                    LIST_WIDTH - 96,
                    FOOTER_HEIGHT
                )
            ),
            rows = {},
        }

        if not state.header or not state.previous or not state.next or not state.page_label then
            return nil
        end

        for i = 1, ROWS_PER_PAGE do
            local row = create_view_widget(
                view,
                "npclook_loadout_preset_row_" .. i,
                styled_button_definition(UIWidget, UIFontSettings, UISoundEvents, LIST_WIDTH, ROW_HEIGHT)
            )

            if not row then
                return nil
            end

            state.rows[i] = row
        end

        service.inventory_states[view] = state
        request_context_checks(4)

        return state
    end

    local function entries()
        local values = {
            {
                value = nil,
                label = loc("ui_loadout_preset_none"),
            },
            {
                value = DEFAULT_PIN,
                label = loc("ui_loadout_preset_default"),
            },
        }

        for i = 1, #(preset_store.items or {}) do
            local preset = preset_store.items[i]

            if preset and normalized_string(preset.name) then
                values[#values + 1] = {
                    value = preset.name,
                    label = preset.name,
                }
            end
        end

        return values
    end

    local function pin_label(pin_value)
        if pin_value == DEFAULT_PIN then
            return loc("ui_loadout_preset_default")
        end

        return pin_value or loc("ui_loadout_preset_none")
    end

    local function set_open(state, open)
        state.open = open == true
        state.header.visible = true

        for i = 1, #state.rows do
            state.rows[i].visible = state.open and i <= state.rows_per_page
                and state.rows[i].content._entry ~= nil
        end

        state.previous.visible = state.open
        state.next.visible = state.open
        state.page_label.visible = state.open
    end

    local function hide_inventory_state(state)
        state.open = false
        state.header.visible = false
        state.previous.visible = false
        state.next.visible = false
        state.page_label.visible = false

        for i = 1, #state.rows do
            state.rows[i].visible = false
        end
    end

    local function position_inventory_widgets(state)
        local base_x, base_y = state.base_x, state.base_y

        state.header.offset = { base_x, base_y, BASE_Z }

        local row_y = base_y + HEADER_HEIGHT + ROW_SPACING

        for i = 1, ROWS_PER_PAGE do
            state.rows[i].offset = {
                base_x,
                row_y + (i - 1) * (ROW_HEIGHT + ROW_SPACING),
                BASE_Z + 2,
            }
        end

        local footer_y = row_y + state.rows_per_page * (ROW_HEIGHT + ROW_SPACING)

        state.previous.offset = { base_x, footer_y, BASE_Z + 2 }
        state.page_label.offset = { base_x + 48, footer_y, BASE_Z + 2 }
        state.next.offset = { base_x + LIST_WIDTH - 44, footer_y, BASE_Z + 2 }
    end

    local function rebuild_inventory_state(state)
        local character_id, loadout_id, selected = service.active()
        local available = character_id ~= nil and loadout_id ~= nil
        local values = entries()

        state.base_x, state.base_y = button_position()
        state.rows_per_page = rows_per_page(state.base_y)

        local rows_shown = state.rows_per_page
        local page_count = math.max(math.ceil(#values / rows_shown), 1)

        state.page = math.max(math.min(state.page, page_count), 1)
        state.page_count = page_count
        set_widget_text(state.header, string.format(
            "%s: %s",
            loc("ui_loadout_preset_button"),
            pin_label(selected)
        ))
        state.header.content.hotspot.disabled = not available

        local first = (state.page - 1) * rows_shown + 1

        for i = 1, ROWS_PER_PAGE do
            local row = state.rows[i]
            local entry = i <= rows_shown and values[first + i - 1] or nil

            row.content._entry = entry
            row.content.hotspot.is_selected = entry ~= nil and entry.value == selected
            row.content.hotspot.disabled = not available or entry == nil
            set_widget_text(row, entry and entry.label or "")
        end

        set_widget_text(state.previous, "<")
        state.previous.content.hotspot.disabled = state.page <= 1
        set_widget_text(state.next, ">")
        state.next.content.hotspot.disabled = state.page >= page_count
        set_widget_text(state.page_label, string.format("%d / %d", state.page, page_count))
        state.page_label.content.hotspot.disabled = true
        state.preset_revision = service.preset_revision
        state.rebuild = false
        position_inventory_widgets(state)
        set_open(state, state.open)
    end

    local function consume_press(widget)
        local hotspot = widget and widget.content and widget.content.hotspot

        if hotspot and hotspot.on_pressed then
            hotspot.on_pressed = false

            return hotspot.disabled ~= true
        end

        return false
    end

    local function refresh_inventory_character(view, state)
        local character_id = state.refresh_character_id

        if not character_id or view._destroyed then
            return
        end

        if player_character_id(view._preview_player) ~= character_id then
            state.refresh_character_id = nil
            return
        end

        if not view._profile_spawner or type(view._presentation_profile) ~= "table"
            or type(view._spawn_profile) ~= "function" then
            return
        end

        state.refresh_character_id = nil

        local presentation_profile = view._presentation_profile
        local profile_ok, current_profile = call_method(view._preview_player, "profile")
        local source_profile = profile_ok and type(current_profile) == "table" and current_profile
            or presentation_profile.npclook_source_profile or presentation_profile
        local ok, err = pcall(view._spawn_profile, view, source_profile)

        if not ok then
            mod:warning("Could not refresh the inventory character: %s", tostring(err))
        end
    end

    local function update_inventory_view(view, input_service)
        if view._is_own_player == false or view._is_readonly == true then
            return
        end

        if not button_visible() then
            local hidden_state = service.inventory_states[view]

            if hidden_state then
                hide_inventory_state(hidden_state)
                hidden_state.rebuild = true
            end

            return
        end

        local state = service.inventory_states[view] or create_inventory_state(view)

        if not state then
            return
        end

        refresh_inventory_character(view, state)

        if state.rebuild or state.preset_revision ~= service.preset_revision then
            rebuild_inventory_state(state)
        end

        if consume_press(state.header) then
            set_open(state, not state.open)
        end

        if not state.open then
            return
        end

        if input_service and input_service:get("back") then
            set_open(state, false)
            return
        end

        for i = 1, ROWS_PER_PAGE do
            local row = state.rows[i]

            if row.visible and consume_press(row) then
                local entry = row.content._entry
                local ok, err = service.set_pin(entry and entry.value)

                if not ok then
                    mod:warning("Could not change the loadout look pin: %s", tostring(err))
                end

                state.rebuild = true
                break
            end
        end

        if consume_press(state.previous) then
            state.page = math.max(state.page - 1, 1)
            state.rebuild = true
        elseif consume_press(state.next) then
            state.page = math.min(state.page + 1, state.page_count)
            state.rebuild = true
        end
    end

    local inventory_ok, InventoryBackgroundView = pcall(
        require,
        "scripts/ui/views/inventory_background_view/inventory_background_view"
    )

    if inventory_ok then
        dependencies.hook_method(InventoryBackgroundView, "update", function(
                func,
                self,
                dt,
                t,
                input_service)
            local pass_input, pass_draw = func(self, dt, t, input_service)

            update_inventory_view(self, input_service)

            return pass_input, pass_draw
        end)

        dependencies.hook_method(InventoryBackgroundView, "on_exit", function(func, self, ...)
            service.inventory_states[self] = nil

            return func(self, ...)
        end)
    else
        mod:warning("Compatibility: inventory loadout look UI is unavailable")
    end

    local presets_ok, ViewElementProfilePresets = pcall(
        require,
        "scripts/ui/view_elements/view_element_profile_presets/view_element_profile_presets"
    )

    if presets_ok then
        dependencies.hook_method(
            ViewElementProfilePresets,
            "on_profile_preset_index_change",
            function(func, self, ...)
                local result = func(self, ...)

                service.profile_preset_selection_changed()

                return result
            end
        )
    end

    local synchronizer_ok, PackageSynchronizerHost = pcall(
        require,
        "scripts/loading/package_synchronizer_host"
    )

    if synchronizer_ok then
        dependencies.hook_method(PackageSynchronizerHost, "_player_profile_changed", function(
                func,
                self,
                peer_id,
                local_player_id,
                old_profile,
                old_sync_data)
            service.before_profile_sync(self, peer_id, local_player_id)

            local result = func(self, peer_id, local_player_id, old_profile, old_sync_data)
            local peer_syncs = self._syncs and self._syncs[peer_id]
            local sync_data = peer_syncs and peer_syncs[local_player_id]

            service.profile_sync_started(self, peer_id, local_player_id, sync_data)

            return result
        end)

        dependencies.hook_method(
            PackageSynchronizerHost,
            "_handle_profile_changes_after_sync",
            function(func, self, peer_id, local_player_id, sync_data)
                local result = func(self, peer_id, local_player_id, sync_data)

                service.after_profile_sync(peer_id, local_player_id, sync_data)

                return result
            end
        )
    else
        mod:warning("Compatibility: loadout look synchronization hooks are unavailable")
    end

    function service.shutdown()
        table.clear(service.inventory_states)
        service.pending = nil
        service.context_checks_remaining = 0
        service.sync_in_flight = false
        service.sync_timeout = nil
        service.sync_host = nil
        service.sync_peer_id = nil
        service.sync_local_player_id = nil
        service.latest_sync_change_id = nil
        clear_managed_look()
    end

    return service
end

return LoadoutPresets
