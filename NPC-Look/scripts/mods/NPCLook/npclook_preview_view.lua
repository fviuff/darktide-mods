local mod = get_mod("NPCLook")
local util = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_util")
local extra_slot_runtime = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_extra_slots")
local UIWorkspaceSettings = require("scripts/settings/ui/ui_workspace_settings")
local UIWorldSpawner = require("scripts/managers/ui/ui_world_spawner")
local UIProfileSpawner = require("scripts/managers/ui/ui_profile_spawner")
local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
local Breeds = require("scripts/settings/breed/breeds")
local ItemSlotSettings = require("scripts/settings/item/item_slot_settings")
local InventoryCosmeticsViewSettings = require("scripts/ui/views/inventory_cosmetics_view/inventory_cosmetics_view_settings")

-- Preview layout and camera tuning

local STUDIO_VIEW_NAME = "npclook_studio_view"
local PREVIEW_VIEW_NAME = "npclook_studio_preview_view"
local PREVIEW_WORLD_NAME = "ui_npclook_studio_preview"
local PREVIEW_VIEWPORT_NAME = "ui_npclook_studio_preview_viewport"
local PREVIEW_WORLD_LAYER = 10

local CAMERA_FOCUS_SLOT = {
    full = false,
    head = "slot_gear_head",
    torso = "slot_gear_upperbody",
    legs = "slot_gear_lowerbody",
}

local NORMAL_VIEWPORT = {
    x = 0.226,
    y = 0,
    width = 0.548,
    height = 1,
}

local INSPECT_VIEWPORT = {
    x = 0.025,
    y = 0,
    width = 0.95,
    height = 1,
}

local REGION_FILL = {
    normal = {
        full = 0.58,
        detail = 0.56,
    },
    inspect = {
        full = 0.76,
        detail = 0.72,
    },
}

local FRAMING = {
    -- Fall back while the skeleton is still streaming.
    fallback_head_height = 1.7,
    minimum_character_height = 1.35,

    head_center_drop = 0.10,
    head_height_ratio = 0.40,
    head_minimum_height = 0.72,

    torso_center_drop = 0.02,
    legs_center_lift = 0.02,
    detail_height_ratio = 0.58,
    detail_minimum_height = 1.0,

    full_center_lift = 0.035,
    full_height_padding = 0.34,

    fallback_fov_degrees = 50,
    minimum_fov_degrees = 20,
    -- Keep the distance calculation bounded.
    projection_floor = 0.05,
    zoom_step = 0.88,
    minimum_distance = 1.25,
    maximum_distance = 7.5,

    transition_time = 0.24,
    retry_transition_time = 0.22,
    fallback_transition_time = 0.25,
    fallback_normal_blend = 0.42,
    fallback_inspect_blend = 0.62,

    scroll_deadzone = 0.001,
    scroll_sensitivity = 0.75,
    minimum_zoom_steps = -4,
    maximum_zoom_steps = 5,
}

local function line_color(alpha, red, green, blue)
    if Color then
        return Color(alpha, red, green, blue)
    end

    return Vector4(red / 255, green / 255, blue / 255, alpha / 255)
end

local function add_skeleton_line(line_object, tint, from, to)
    if LineObject and type(LineObject.add_line) == "function" then
        pcall(LineObject.add_line, line_object, tint, from, to)
    end
end

local function add_skeleton_sphere(line_object, tint, position, radius)
    if LineObject and type(LineObject.add_sphere) == "function" then
        local ok = pcall(LineObject.add_sphere, line_object, tint, position, radius)

        if ok then
            return
        end
    end

    local x = Vector3(radius, 0, 0)
    local y = Vector3(0, radius, 0)
    local z = Vector3(0, 0, radius)
    add_skeleton_line(line_object, tint, position - x, position + x)
    add_skeleton_line(line_object, tint, position - y, position + y)
    add_skeleton_line(line_object, tint, position - z, position + z)
end

local function selected_region(slot_name)
    slot_name = tostring(slot_name or "")

    if slot_name == "" then
        return "full"
    end

    if string.find(slot_name, "head", 1, true)
        or string.find(slot_name, "face", 1, true)
        or string.find(slot_name, "hair", 1, true)
        or string.find(slot_name, "eye", 1, true)
        or string.find(slot_name, "makeup", 1, true)
        or string.find(slot_name, "scar", 1, true) then
        return "head"
    end

    if string.find(slot_name, "upperbody", 1, true)
        or string.find(slot_name, "torso", 1, true)
        or string.find(slot_name, "arms", 1, true)
        or string.find(slot_name, "extra", 1, true)
        or string.find(slot_name, "decal", 1, true) then
        return "torso"
    end

    if string.find(slot_name, "lowerbody", 1, true)
        or string.find(slot_name, "legs", 1, true)
        or string.find(slot_name, "boots", 1, true) then
        return "legs"
    end

    return "full"
end

local Definitions = {
    scenegraph_definition = {
        screen = UIWorkspaceSettings.screen,
    },
    widget_definitions = {},
}

local function player_profile(player)
    if not player or type(player.profile) ~= "function" then
        return nil
    end

    local ok, profile = pcall(player.profile, player)

    return ok and profile or nil
end

local function clone_loadout(loadout)
    local clone = {}

    for slot_name, item in pairs(loadout or {}) do
        clone[slot_name] = item
    end

    return clone
end

local function preview_extra_slots_signature(extra_slots)
    local parts = {}

    for i = 1, #(extra_slots or {}) do
        local entry = extra_slots[i]
        parts[i] = table.concat({
            tostring(entry.id),
            tostring(entry.item_name),
            tostring(entry.attach_node or ""),
            tostring(entry.transform_signature or ""),
            tostring(entry.variant_signature or ""),
            tostring(entry.opacity or 100),
            table.concat(entry.dependency_materials or {}, "\31"),
        }, "@")
    end

    return table.concat(parts, "\30")
end

local safe_unit_alive = util.safe_unit_alive

local function profile_spawner_state(spawner)
    if not spawner or type(spawner.loading) ~= "function" or type(spawner.spawned) ~= "function" then
        return false, false, false
    end

    local ok, loading, spawned = pcall(function()
        return spawner:loading(), spawner:spawned()
    end)

    return ok, loading == true, spawned == true
end

local function spawned_character_unit(spawner)
    if not spawner or type(spawner.spawned_character_unit) ~= "function" then
        return nil
    end

    local ok, unit = pcall(spawner.spawned_character_unit, spawner)

    return ok and unit or nil
end

local function spawner_node_world_position(spawner, node_name)
    if not spawner or type(spawner.node_world_position) ~= "function" then
        return nil
    end

    local ok, position = pcall(spawner.node_world_position, spawner, node_name)

    return ok and position or nil
end

-- Darktide unloads a package as soon as its final PackageManager reference is released.
-- UI preview units can keep engine resource references after their Lua units stop reporting
-- alive, so unit polling is not a safe release signal. Keep one deduplicated package cache
-- for Studio previews for the lifetime of the current PackageManager instead.
local PREVIEW_PACKAGE_REFERENCE = "NPCLookStudioPreviewCache"
local preview_package_cache = rawget(mod, "npclook_studio_preview_package_cache")

if type(preview_package_cache) ~= "table" then
    preview_package_cache = {}
    rawset(mod, "npclook_studio_preview_package_cache", preview_package_cache)
end

preview_package_cache.package_ids = type(preview_package_cache.package_ids) == "table"
    and preview_package_cache.package_ids or {}
preview_package_cache.reported_errors = type(preview_package_cache.reported_errors) == "table"
    and preview_package_cache.reported_errors or {}

local preview_dependency_scratch = Script.new_map(64)

local function prepare_preview_package_cache(package_manager)
    if preview_package_cache.manager ~= package_manager then
        preview_package_cache.manager = package_manager
        preview_package_cache.package_ids = {}
        preview_package_cache.reported_errors = {}
    else
        preview_package_cache.package_ids = type(preview_package_cache.package_ids) == "table"
            and preview_package_cache.package_ids or {}
        preview_package_cache.reported_errors = type(preview_package_cache.reported_errors) == "table"
            and preview_package_cache.reported_errors or {}
    end
end

local function report_preview_package_error(key, message)
    local reported = preview_package_cache.reported_errors

    if not reported[key] then
        reported[key] = true
        mod:error(message)
    end
end

local function ensure_preview_packages(profile_spawner, profile)
    local package_manager = Managers.package

    if not profile_spawner or not package_manager or type(profile) ~= "table" then
        return false
    end

    prepare_preview_package_cache(package_manager)

    local item_definitions = profile_spawner._item_definitions
    local mission_template = profile_spawner._mission_template
    local package_ids = preview_package_cache.package_ids

    for _, item in pairs(profile.loadout or {}) do
        if type(item) == "table" and not table.is_empty(item) then
            table.clear(preview_dependency_scratch)

            local compiled, compile_error = pcall(
                ItemPackage.compile_item_instance_dependencies,
                item,
                item_definitions,
                preview_dependency_scratch,
                mission_template
            )

            if not compiled then
                report_preview_package_error(
                    "compile:" .. tostring(item.name),
                    string.format(
                        "Studio preview dependency scan failed for %s: %s",
                        tostring(item.name or "unnamed item"),
                        tostring(compile_error)
                    )
                )
                return false
            end

            for package_name in pairs(preview_dependency_scratch) do
                if not package_ids[package_name] then
                    local ok, load_id = pcall(
                        package_manager.load,
                        package_manager,
                        package_name,
                        PREVIEW_PACKAGE_REFERENCE,
                        nil,
                        true,
                        true
                    )

                    if not ok or not load_id then
                        report_preview_package_error(
                            "load:" .. tostring(package_name),
                            string.format(
                                "Studio preview package cache failed for %s: %s",
                                tostring(package_name),
                                tostring(load_id)
                            )
                        )
                        return false
                    end

                    package_ids[package_name] = load_id
                    preview_package_cache.reported_errors["load:" .. tostring(package_name)] = nil
                end
            end
        end
    end

    return true
end

local NPCLookStudioPreviewView = class("NPCLookStudioPreviewView", "BaseView")

NPCLookStudioPreviewView.init = function(self, settings, context)
    NPCLookStudioPreviewView.super.init(self, Definitions, settings, context)

    self._pass_draw = true
    self._pass_input = true
    self._context = context or {}
    self._preview_player = self._context.player
    self._item_camera_by_slot_id = {}
    self._preview_revision = -1
    self._selected_slot = nil
    self._camera_focus = nil
    self._inspect_mode = false
    self._camera_reset_revision = -1
    self._player_spawned = false
    self._presentation_loadout_signature = nil
    self._base_reconcile_pending = false
    self._base_reconcile_error = nil
    self._preview_extra_slots = {}
    self._preview_extra_slots_signature = ""
    self._material_slot_scan_key = nil
    self._frame_pending = true
    self._frame_retry = util.new_retry()
    self._world_setup_pending = false
    self._user_zoom = 0
    self._node_skeleton_visible = false
    self._preview_attach_node = nil
    self._skeleton_line_object = nil
    self._skeleton_nodes_unit = nil
    self._skeleton_nodes = nil
    self._native_preview_hidden = false
    self._session_attached = false
    self._last_preview_snapshot = nil
end

NPCLookStudioPreviewView._api = function(self)
    local current_mod = get_mod and get_mod("NPCLook")

    return current_mod and current_mod.npclook_view_api
end

NPCLookStudioPreviewView._attach_session = function(self)
    local api = self:_api()

    if not api then
        return false
    end

    if type(api.closing) == "function" then
        local closing_ok, closing = pcall(api.closing)

        if closing_ok and closing == true then
            return false
        end
    end

    if self._session_attached then
        return true
    end

    if type(api.attach_view) ~= "function" then
        return false
    end

    local ok, attached = pcall(api.attach_view, PREVIEW_VIEW_NAME)

    self._session_attached = ok and attached == true

    return self._session_attached
end

NPCLookStudioPreviewView._preview_snapshot = function(self)
    local api = self:_api()

    if not api or type(api.preview_snapshot) ~= "function" then
        return self._last_preview_snapshot
    end

    if type(api.available) == "function" then
        local available_ok, available = pcall(api.available)

        if available_ok and available ~= true then
            util.report_once(self, "_preview_snapshot_error", nil)
            return self._last_preview_snapshot
        end
    end

    if type(api.closing) == "function" then
        local closing_ok, closing = pcall(api.closing)

        if closing_ok and closing == true then
            util.report_once(self, "_preview_snapshot_error", nil)
            return self._last_preview_snapshot
        end
    end

    local ok, snapshot, returned_error = pcall(api.preview_snapshot)

    if not ok or type(snapshot) ~= "table" then
        local closing = false

        if type(api.closing) == "function" then
            local closing_ok, closing_value = pcall(api.closing)
            closing = closing_ok and closing_value == true
        end

        if closing then
            util.report_once(self, "_preview_snapshot_error", nil)
            return self._last_preview_snapshot
        end

        local message = tostring(returned_error or snapshot or "Preview snapshot returned no data")

        util.report_once(self, "_preview_snapshot_error", message, function(new_message)
            mod:error("Studio preview snapshot failed: %s", new_message)
        end)

        return self._last_preview_snapshot
    end

    util.report_once(self, "_preview_snapshot_error", nil)
    self._last_preview_snapshot = snapshot

    return snapshot
end

NPCLookStudioPreviewView._clear_preview_extra_slots = function(self)
    extra_slot_runtime.clear_context(self, 0)

    local unit_spawner = self._profile_spawner and self._profile_spawner._unit_spawner
    local flush = unit_spawner and (
        unit_spawner.commit_and_remove_pending_units
        or unit_spawner.remove_pending_units
    )

    if type(flush) == "function" then
        pcall(flush, unit_spawner)
    end
end

NPCLookStudioPreviewView._set_native_preview_hidden = function(self, hidden)
    hidden = hidden == true

    if self._native_preview_hidden == hidden then
        return
    end

    local spawner = self._profile_spawner

    if spawner and type(spawner.set_visibility) == "function" then
        local ok = pcall(spawner.set_visibility, spawner, not hidden)

        if ok then
            self._native_preview_hidden = hidden
        end
    elseif not hidden then
        self._native_preview_hidden = false
    end
end

NPCLookStudioPreviewView._clear_skeleton_draw = function(self)
    local line_object = self._skeleton_line_object
    local world = self._world_spawner and self._world_spawner:world()

    if line_object and world and LineObject then
        if type(LineObject.reset) == "function" then
            pcall(LineObject.reset, line_object)
        end

        if type(LineObject.dispatch) == "function" then
            pcall(LineObject.dispatch, world, line_object)
        end
    end
end

NPCLookStudioPreviewView._destroy_skeleton_drawer = function(self)
    self:_clear_skeleton_draw()

    local world = self._world_spawner and self._world_spawner:world()
    local line_object = self._skeleton_line_object

    if world and line_object then
        pcall(World.destroy_line_object, world, line_object)
    end

    self._skeleton_line_object = nil
    self._skeleton_nodes_unit = nil
    self._skeleton_nodes = nil
end

NPCLookStudioPreviewView._ensure_skeleton_line_object = function(self)
    if self._skeleton_line_object then
        return self._skeleton_line_object
    end

    local world = self._world_spawner and self._world_spawner:world()

    if not world or not World or type(World.create_line_object) ~= "function" then
        return nil
    end

    local ok, line_object = pcall(World.create_line_object, world)

    if not ok or not line_object then
        return nil
    end

    self._skeleton_line_object = line_object

    return line_object
end

local function unit_node_position(unit, node)
    if not safe_unit_alive(unit) or node == nil then
        return nil
    end

    local node_index = node

    if type(node) == "string" then
        local ok_node, has_node = pcall(Unit.has_node, unit, node)

        if not ok_node or not has_node then
            return nil
        end

        local ok_index, resolved = pcall(Unit.node, unit, node)

        if not ok_index or type(resolved) ~= "number" then
            return nil
        end

        node_index = resolved
    end

    local ok_position, position = pcall(Unit.world_position, unit, node_index)

    return ok_position and position or nil
end

NPCLookStudioPreviewView._skeleton_node_rows = function(self, unit)
    if self._skeleton_nodes_unit == unit and type(self._skeleton_nodes) == "table" then
        return self._skeleton_nodes
    end

    local rows = {}
    local ok_bones, bones = false, nil

    -- Match the reference Studio: enumerate the real named skeleton bones once
    -- after the preview character is fully spawned, then cache the result.
    if type(Unit.bones) == "function" then
        ok_bones, bones = pcall(Unit.bones, unit)
    end

    if ok_bones and type(bones) == "table" then
        for i = 1, #bones do
            local name = bones[i]
            local ok_node, node = false, nil

            if type(name) == "string" and name ~= "" then
                ok_node, node = pcall(Unit.node, unit, name)
            end

            if ok_node and type(node) == "number" then
                local parent

                if type(Unit.scene_graph_parent) == "function" then
                    local ok_parent, resolved_parent = pcall(Unit.scene_graph_parent, unit, node)
                    parent = ok_parent and type(resolved_parent) == "number" and resolved_parent or nil
                end

                rows[#rows + 1] = {
                    name = name,
                    node = node,
                    parent = parent,
                }
            end
        end
    end

    self._skeleton_nodes_unit = unit
    self._skeleton_nodes = rows

    return rows
end

NPCLookStudioPreviewView._update_node_skeleton = function(self)
    local spawner = self._profile_spawner
    local state_ok, loading, spawned = profile_spawner_state(spawner)
    local active = self._node_skeleton_visible and state_ok and not loading and spawned
    local unit = active and spawned_character_unit(spawner) or nil

    if not active or not safe_unit_alive(unit) then
        self:_set_native_preview_hidden(false)
        self:_clear_skeleton_draw()
        return
    end

    local line_object = self:_ensure_skeleton_line_object()
    local world = self._world_spawner and self._world_spawner:world()

    if not line_object or not world then
        self:_set_native_preview_hidden(false)
        return
    end

    self:_set_native_preview_hidden(true)

    if LineObject and type(LineObject.reset) == "function" then
        pcall(LineObject.reset, line_object)
    end

    local normal_color = line_color(230, 235, 235, 235)
    local selected_color = line_color(255, 255, 205, 32)
    local rows = self:_skeleton_node_rows(unit)
    local selected_name = self._preview_attach_node

    for i = 1, #rows do
        local row = rows[i]
        local position = unit_node_position(unit, row.node)

        if position then
            local selected = row.name == selected_name or row.node == selected_name
            local tint = selected and selected_color or normal_color
            local radius = selected and 0.045 or 0.012

            add_skeleton_sphere(line_object, tint, position, radius)

            if row.parent and row.parent >= 1 and row.parent ~= row.node then
                local parent_position = unit_node_position(unit, row.parent)

                if parent_position then
                    add_skeleton_line(line_object, tint, parent_position, position)
                end
            end
        end
    end

    if LineObject and type(LineObject.dispatch) == "function" then
        pcall(LineObject.dispatch, world, line_object)
    end
end

local function single_item_loader_busy(spawner)
    local loader = spawner and spawner._single_item_profile_loader
    local loading_data = loader and loader._slots_loading_data

    return type(loading_data) == "table" and next(loading_data) ~= nil
end

NPCLookStudioPreviewView._reconcile_base_loadout = function(self)
    if not self._base_reconcile_pending then
        return false
    end

    local spawner = self._profile_spawner
    local state_ok, loading, spawned = profile_spawner_state(spawner)

    if not state_ok or loading or not spawned
        or single_item_loader_busy(spawner)
        or type(spawner._sync_profile_changes) ~= "function" then
        return false
    end

    local desired_profile = self._presentation_profile
    local desired_loadout = desired_profile and desired_profile.loadout
    local spawn_data = spawner._character_spawn_data
    local active_profile = spawn_data and spawn_data.profile
    local active_loadout = active_profile and active_profile.loadout
    local loading_items = spawn_data and spawn_data.loading_items

    if type(desired_loadout) ~= "table" or type(active_loadout) ~= "table"
        or type(loading_items) ~= "table" then
        return false
    end

    if not ensure_preview_packages(spawner, desired_profile) then
        self._base_reconcile_pending = false
        return false
    end

    local previous_items = {}
    local previous_present = {}
    local previous_loading_items = {}
    local previous_loading_present = {}
    local ignored_slots = spawner._ignored_slots or {}
    local changed = false

    for slot_name, settings in pairs(ItemSlotSettings) do
        if type(settings) == "table" and not ignored_slots[slot_name]
            and not settings.ignore_character_spawning then
            local desired_item = desired_loadout[slot_name]
            local active_item = active_loadout[slot_name]

            if desired_item ~= active_item then
                previous_items[slot_name] = active_item
                previous_present[slot_name] = active_item ~= nil
                previous_loading_items[slot_name] = loading_items[slot_name]
                previous_loading_present[slot_name] = loading_items[slot_name] ~= nil
                active_loadout[slot_name] = desired_item

                -- Native synchronization normally detects changes by item name. Generated
                -- preview items may keep the same name while materials or other state change.
                local desired_item_name = type(desired_item) == "table" and desired_item.name or nil

                if desired_item_name and loading_items[slot_name] == desired_item_name then
                    loading_items[slot_name] = nil
                end

                changed = true
            end
        end
    end

    if not changed then
        self._base_reconcile_pending = false
        self._base_reconcile_error = nil
        return true
    end

    local ok, err = pcall(spawner._sync_profile_changes, spawner)

    if not ok then
        for slot_name in pairs(previous_present) do
            active_loadout[slot_name] = previous_present[slot_name]
                and previous_items[slot_name] or nil
            loading_items[slot_name] = previous_loading_present[slot_name]
                and previous_loading_items[slot_name] or nil
        end

        local message = tostring(err)

        if self._base_reconcile_error ~= message then
            self._base_reconcile_error = message
            mod:warning("Studio base-slot preview reconciliation failed: %s", message)
        end

        self._base_reconcile_pending = false
        return false
    end

    self._base_reconcile_pending = false
    self._base_reconcile_error = nil
    self._material_slot_scan_key = nil

    return true
end

NPCLookStudioPreviewView._preview_extra_slot_settings = function(self)
    local api = self:_api()
    local profile = self._presentation_profile
    local archetype = profile and profile.archetype
    local item_definitions

    if api and type(api.item_cache) == "function" then
        local ok, cache = pcall(api.item_cache)

        if ok and type(cache) == "table" then
            item_definitions = cache
        end
    end

    return {
        world = self._world_spawner and self._world_spawner:world(),
        unit_spawner = self._profile_spawner and self._profile_spawner._unit_spawner,
        item_definitions = item_definitions,
        mission = nil,
        breed_name = archetype and archetype.breed,
        from_ui_profile_spawner = true,
        force_highest_lod_step = true,
        context_label = "NPCLookStudioPreviewView",
    }
end

NPCLookStudioPreviewView._sync_preview_extra_slots = function(self)
    local spawner = self._profile_spawner

    if self._base_reconcile_pending or not spawner
        or single_item_loader_busy(spawner) then
        return
    end

    local state_ok, loading, spawned = profile_spawner_state(spawner)

    if not state_ok or loading or not spawned then
        return
    end

    local parent_unit = spawned_character_unit(spawner)

    if not safe_unit_alive(parent_unit) then
        return
    end

    local call_ok, sync_ok, _, failed_count, first_error, packages_loading = pcall(
        extra_slot_runtime.sync_context,
        self,
        parent_unit,
        self:_preview_extra_slot_settings(),
        self._preview_extra_slots
    )
    local message

    if not call_ok then
        message = tostring(sync_ok)
    elseif sync_ok or packages_loading then
        message = nil
    elseif (tonumber(failed_count) or 0) > 0 then
        message = tostring(first_error or "extra-slot synchronization failed")
    else
        message = tostring(first_error or "extra-slot synchronization did not complete")
    end

    util.report_once(
        self,
        "_preview_extra_slot_error",
        message,
        function(new_message)
            mod:error("Studio preview extra-slot synchronization failed: %s", new_message)
        end
    )
end

NPCLookStudioPreviewView._report_material_slots = function(self)
    local api = self:_api()
    local slot_name = self._selected_slot
    local spawner = self._profile_spawner

    local state_ok, loading, spawned = profile_spawner_state(spawner)

    if not api or type(api.material_targets_from_item_maps) ~= "function"
        or type(api.report_material_slots) ~= "function" or not slot_name
        or not state_ok or loading or not spawned
        or self._base_reconcile_pending or single_item_loader_busy(spawner) then
        return
    end

    local spawn_data = spawner._character_spawn_data
    local spawned_slots = spawn_data and spawn_data.slots or {}
    local selected_loadout_item = self._presentation_profile
        and self._presentation_profile.loadout
        and self._presentation_profile.loadout[slot_name]
    local selected_item_name = type(selected_loadout_item) == "table" and selected_loadout_item.name
        or type(selected_loadout_item) == "string" and selected_loadout_item or nil
    local slot = spawned_slots[slot_name]

    local function slot_contains_item(candidate, item_name)
        if not candidate or type(item_name) ~= "string" or item_name == "" then
            return false
        end

        for _, names in pairs({ candidate.item_name_by_unit_3p, candidate.item_name_by_unit_1p }) do
            for unit, mapped_name in pairs(names or {}) do
                if safe_unit_alive(unit) and mapped_name == item_name then
                    return true
                end
            end
        end

        return false
    end

    -- Resolve dependent cosmetics through the spawned item mapping.
    if selected_item_name and not slot_contains_item(slot, selected_item_name) then
        for _, candidate in pairs(spawned_slots) do
            if slot_contains_item(candidate, selected_item_name) then
                slot = candidate
                break
            end
        end
    end

    local maps = {}
    local attachment_maps = {}
    local root_item_names = {}

    if slot then
        if type(slot.item_name_by_unit_3p) == "table" then
            maps[#maps + 1] = slot.item_name_by_unit_3p
        end

        if type(slot.item_name_by_unit_1p) == "table" then
            maps[#maps + 1] = slot.item_name_by_unit_1p
        end

        if type(slot.attachments_by_unit_3p) == "table" then
            attachment_maps[#attachment_maps + 1] = slot.attachments_by_unit_3p
        end

        if type(slot.attachments_by_unit_1p) == "table" then
            attachment_maps[#attachment_maps + 1] = slot.attachments_by_unit_1p
        end

        local root_item_name = selected_item_name or slot.item and slot.item.name

        if type(root_item_name) == "string" and root_item_name ~= "" then
            root_item_names[root_item_name] = true
        end
    elseif type(extra_slot_runtime.context_material_target_data) == "function" then
        local data = extra_slot_runtime.context_material_target_data(self, slot_name)

        for i = 1, #((data and data.item_name_maps) or {}) do
            maps[#maps + 1] = data.item_name_maps[i]
        end

        for i = 1, #((data and data.attachment_maps) or {}) do
            attachment_maps[#attachment_maps + 1] = data.attachment_maps[i]
        end

        for item_name in pairs((data and data.root_item_names) or {}) do
            root_item_names[item_name] = true
        end
    end

    local mapped_count = 0
    local mapped_names = {}

    for i = 1, #maps do
        for unit, item_name in pairs(maps[i] or {}) do
            if safe_unit_alive(unit) and type(item_name) == "string" and item_name ~= "" then
                mapped_count = mapped_count + 1
                mapped_names[item_name] = true
            end
        end
    end

    if mapped_count == 0 or next(root_item_names) == nil then
        local report_ok, report_error = pcall(api.report_material_slots, slot_name, {}, false)

        util.report_once(
            self,
            "_material_slot_report_error",
            not report_ok and tostring(report_error) or nil,
            function(message)
                mod:error("Studio material target reporting failed: %s", message)
            end
        )
        self._material_slot_scan_key = nil
        return
    end

    local mapped_name_list = table.keys(mapped_names)
    table.sort(mapped_name_list)

    local key = table.concat({
        tostring(slot_name),
        tostring(selected_item_name or ""),
        tostring(self._preview_revision),
        tostring(self._preview_extra_slots_signature),
        tostring(mapped_count),
        table.concat(mapped_name_list, "\31"),
    }, "|")

    if self._material_slot_scan_key == key then
        return
    end

    local targets_ok, targets_or_error = pcall(
        api.material_targets_from_item_maps,
        maps,
        root_item_names,
        attachment_maps
    )
    local report_ok, report_error = false, targets_or_error

    if targets_ok and type(targets_or_error) == "table" then
        report_ok, report_error = pcall(
            api.report_material_slots,
            slot_name,
            targets_or_error,
            true
        )
    end

    if not targets_ok or not report_ok then
        local message = tostring(report_error or "material target bridge failed")

        util.report_once(self, "_material_slot_report_error", message, function(new_message)
            mod:error("Studio material target reporting failed: %s", new_message)
        end)
        return
    end

    util.report_once(self, "_material_slot_report_error", nil)
    self._material_slot_scan_key = key
end

NPCLookStudioPreviewView._sync_preview = function(self, force)
    local snapshot = self:_preview_snapshot()

    if not snapshot then
        return false
    end

    local player = snapshot.player or self._preview_player
    local profile = player_profile(player)
    local loadout = snapshot.preview_loadout
    local loadout_signature = tostring(snapshot.preview_loadout_signature or "")
    local preview_extra_slots = type(snapshot.preview_extra_slots) == "table" and snapshot.preview_extra_slots or {}
    local extra_slots_signature = preview_extra_slots_signature(preview_extra_slots)
    local revision = tonumber(snapshot.preview_revision) or 0
    local revision_changed = revision ~= self._preview_revision

    if not profile or type(loadout) ~= "table" then
        return false
    end

    self._preview_player = player
    self._node_skeleton_visible = snapshot.node_skeleton_visible == true
    self._preview_attach_node = type(snapshot.preview_attach_node) == "string"
        and snapshot.preview_attach_node or nil

    if force or extra_slots_signature ~= self._preview_extra_slots_signature then
        self._preview_extra_slots = preview_extra_slots
        self._preview_extra_slots_signature = extra_slots_signature
    end

    if force or not self._presentation_profile or revision_changed then
        local loadout_changed = not self._presentation_profile
            or loadout_signature ~= self._presentation_loadout_signature

        self._preview_revision = revision

        -- UIProfileSpawner writes synchronized slot values back into its active profile.
        -- Keep the Studio snapshot immutable, then reconcile changed base slots through
        -- Darktide's native per-slot update path instead of replacing the whole character.
        if force or loadout_changed then
            local presentation_profile = table.clone_instance(profile)
            presentation_profile.character_id = "npclook_studio_preview"
            presentation_profile.loadout = clone_loadout(loadout)
            self._presentation_profile = presentation_profile
            self._presentation_loadout_signature = loadout_signature

            if not force and self._profile_spawner then
                self._base_reconcile_pending = true
            end
        end
    end

    local selected_slot = snapshot.selected_slot
    local camera_focus = snapshot.camera_focus
    local inspect_mode = snapshot.inspect_mode == true
    local camera_reset_revision = tonumber(snapshot.camera_reset_revision) or 0
    local framing_changed = selected_slot ~= self._selected_slot
        or camera_focus ~= self._camera_focus
        or inspect_mode ~= self._inspect_mode

    if selected_slot ~= self._selected_slot or revision_changed then
        self._material_slot_scan_key = nil
    end

    self._selected_slot = selected_slot
    self._camera_focus = camera_focus

    if inspect_mode ~= self._inspect_mode then
        self._inspect_mode = inspect_mode
        self:_apply_viewport_rect()
    end

    if camera_reset_revision ~= self._camera_reset_revision then
        self._camera_reset_revision = camera_reset_revision
        self._user_zoom = 0
        framing_changed = true
    end

    if framing_changed then
        self:_request_frame()
    end

    return true
end

NPCLookStudioPreviewView._apply_viewport_rect = function(self)
    local world_spawner = self._world_spawner

    if not world_spawner or not world_spawner._viewport then
        return false
    end

    local rect = self._inspect_mode and INSPECT_VIEWPORT or NORMAL_VIEWPORT
    world_spawner:set_viewport_position(rect.x, rect.y)
    world_spawner:set_viewport_size(rect.width, rect.height)

    return true
end

NPCLookStudioPreviewView._request_frame = function(self)
    self._frame_pending = true
    util.reset_retry(self._frame_retry)
    util.report_once(self, "_frame_timeout", nil)
end

local function node_position(profile_spawner, node_name)
    return spawner_node_world_position(profile_spawner, node_name)
end

local function average_position(a, b)
    if a and b then
        return (a + b) * 0.5
    end

    return a or b
end

NPCLookStudioPreviewView._framing_target = function(self, region)
    local spawner = self._profile_spawner
    local head = node_position(spawner, "j_head")
    local hips = node_position(spawner, "j_hips")
    local left_foot = node_position(spawner, "j_leftfoot")
    local right_foot = node_position(spawner, "j_rightfoot")
    local feet = average_position(left_foot, right_foot)
    local root = spawned_character_unit(spawner)
    local root_position

    if safe_unit_alive(root) then
        local ok_position, position = pcall(Unit.world_position, root, 1)
        root_position = ok_position and position or nil
    end

    hips = hips or root_position
    feet = feet or root_position
    head = head or (root_position and root_position + Vector3(0, 0, FRAMING.fallback_head_height))

    if not head or not feet then
        return nil
    end

    local total_height = math.max(math.abs(head.z - feet.z), FRAMING.minimum_character_height)
    local up = Vector3(0, 0, 1)
    local center
    local visible_height

    if region == "head" then
        center = head - up * (total_height * FRAMING.head_center_drop)
        visible_height = math.max(total_height * FRAMING.head_height_ratio, FRAMING.head_minimum_height)
    elseif region == "torso" then
        center = average_position(head, hips or feet) - up * (total_height * FRAMING.torso_center_drop)
        visible_height = math.max(total_height * FRAMING.detail_height_ratio, FRAMING.detail_minimum_height)
    elseif region == "legs" then
        center = average_position(hips or head, feet) + up * (total_height * FRAMING.legs_center_lift)
        visible_height = math.max(total_height * FRAMING.detail_height_ratio, FRAMING.detail_minimum_height)
    else
        center = average_position(head, feet) + up * (total_height * FRAMING.full_center_lift)
        visible_height = total_height + FRAMING.full_height_padding
    end

    return center, visible_height
end

NPCLookStudioPreviewView._frame_region = function(self)
    local explicit = self._camera_focus

    if explicit == "full" or explicit == "head" or explicit == "torso" or explicit == "legs" then
        return explicit
    end

    return selected_region(self._selected_slot)
end

NPCLookStudioPreviewView._frame_character = function(self, animation_time)
    local world_spawner = self._world_spawner
    local profile_spawner = self._profile_spawner

    if not world_spawner or not profile_spawner or not self._default_camera_unit then
        return false
    end

    local state_ok, loading, spawned = profile_spawner_state(profile_spawner)

    if not state_ok or loading or not spawned then
        return false
    end

    local region = self:_frame_region()
    local center, visible_height = self:_framing_target(region)

    if not center or not visible_height then
        return false
    end

    local focus_slot = CAMERA_FOCUS_SLOT[region]
    local reference_camera_unit = focus_slot and self._item_camera_by_slot_id[focus_slot] or self._default_camera_unit
    reference_camera_unit = reference_camera_unit or self._default_camera_unit

    -- The UI world can disappear before its camera event.
    local ok_rotation, rotation = pcall(Unit.world_rotation, reference_camera_unit, 1)

    if not ok_rotation or not rotation then
        return false
    end

    local camera = world_spawner:camera()

    if not camera then
        return false
    end

    local ok_current_fov, current_fov = pcall(Camera.vertical_fov, camera)
    local fov_radians = ok_current_fov and current_fov or math.rad(FRAMING.fallback_fov_degrees)
    local ok_reference_camera, reference_camera = pcall(Unit.camera, reference_camera_unit, "camera")

    if ok_reference_camera and reference_camera then
        local ok_fov, reference_fov = pcall(Camera.vertical_fov, reference_camera)

        if ok_fov and reference_fov then
            fov_radians = reference_fov
        end
    end

    fov_radians = math.max(
        tonumber(fov_radians) or math.rad(FRAMING.fallback_fov_degrees),
        math.rad(FRAMING.minimum_fov_degrees)
    )
    local mode = self._inspect_mode and "inspect" or "normal"
    local fill_key = region == "full" and "full" or "detail"
    local fill = REGION_FILL[mode][fill_key]
    local half_height = visible_height * 0.5
    local projection = math.tan(fov_radians * 0.5) * fill
    local distance = half_height / math.max(projection, FRAMING.projection_floor)
    distance = distance * math.pow(FRAMING.zoom_step, self._user_zoom or 0)
    distance = math.clamp(distance, FRAMING.minimum_distance, FRAMING.maximum_distance)

    local forward = Quaternion.forward(rotation)

    local target_position = center - forward * distance
    local duration = animation_time == nil and FRAMING.transition_time or animation_time
    local easing = math.easeCubic
    world_spawner:set_target_camera_rotation(rotation, duration, easing)
    world_spawner:set_target_camera_position(target_position.x, target_position.y, target_position.z, duration, easing)
    world_spawner:set_target_camera_fov(math.deg(fov_radians), duration, easing)
    self._frame_pending = false
    util.reset_retry(self._frame_retry)

    return true
end

NPCLookStudioPreviewView._fallback_frame = function(self)
    if not self._world_spawner or not self._default_camera_unit then
        return false
    end

    local region = self:_frame_region()
    local focus_slot = CAMERA_FOCUS_SLOT[region]
    local camera_unit = focus_slot and self._item_camera_by_slot_id[focus_slot] or self._default_camera_unit
    local percent = self._inspect_mode and FRAMING.fallback_inspect_blend or FRAMING.fallback_normal_blend
    self._world_spawner:interpolate_to_camera(
        camera_unit or self._default_camera_unit,
        percent,
        FRAMING.fallback_transition_time,
        math.easeCubic
    )
    self._frame_pending = false
    util.reset_retry(self._frame_retry)

    return true
end

NPCLookStudioPreviewView._update_preview_input = function(self)
    if not self._inspect_mode then
        return nil
    end

    local api = self:_api()
    local input_service

    if api and type(api.preview_input) == "function" then
        local ok, service = pcall(api.preview_input)
        input_service = ok and service or nil

        util.report_once(
            self,
            "_preview_input_bridge_error",
            not ok and tostring(service) or nil,
            function(message)
                mod:error("Studio preview input bridge failed: %s", message)
            end
        )
    end

    if not input_service or type(input_service.get) ~= "function" then
        return nil
    end

    local input_ok, scroll_axis = pcall(input_service.get, input_service, "scroll_axis")

    if not input_ok then
        util.report_once(self, "_preview_input_error", tostring(scroll_axis), function(message)
            mod:error("Studio preview input failed: %s", message)
        end)
        return nil
    end

    util.report_once(self, "_preview_input_error", nil)
    local scroll_delta = scroll_axis and scroll_axis[2] or 0

    if scroll_delta and math.abs(scroll_delta) > FRAMING.scroll_deadzone then
        self._user_zoom = math.clamp(
            (self._user_zoom or 0) + scroll_delta * FRAMING.scroll_sensitivity,
            FRAMING.minimum_zoom_steps,
            FRAMING.maximum_zoom_steps
        )
        self:_request_frame()
    end

    return input_service
end

-- Preview world and profile

-- Darktide: scripts/managers/ui/ui_world_spawner.lua
NPCLookStudioPreviewView._setup_background_world = function(self)
    local profile = player_profile(self._preview_player)

    if not profile then
        return false
    end

    local archetype = profile.archetype
    local breed_name = archetype and (archetype.breed or "human") or "human"
    local breed = Breeds[breed_name]
    local body_size = breed and breed.body_size or "medium"
    local default_camera_event_id = string.format("event_register_%s_cosmetics_preview_default_camera", body_size)

    self[default_camera_event_id] = function(instance, camera_unit)
        -- First camera event is where the viewport actually comes online.
        local ok, err = xpcall(function()
            instance._default_camera_unit = camera_unit

            if not instance._world_spawner then
                error("Preview world disappeared during setup")
            end

            instance._world_spawner:create_viewport(
                camera_unit,
                PREVIEW_VIEWPORT_NAME,
                InventoryCosmeticsViewSettings.viewport_type or "default",
                InventoryCosmeticsViewSettings.viewport_layer or 1,
                InventoryCosmeticsViewSettings.shading_environment or "content/shading_environments/ui/inventory"
            )
            instance:_apply_viewport_rect()
            instance:_request_frame()
        end, util.traceback)

        instance:_unregister_event(default_camera_event_id)

        if not ok then
            mod:error("Preview viewport setup failed: %s", tostring(err))
        end
    end

    self:_register_event(default_camera_event_id)

    for slot_name, slot in pairs(ItemSlotSettings) do
        local slot_type = type(slot) == "table" and slot.slot_type
        local visual = slot_type == "gear" or slot_type == "body" or slot_type == "material"
        local companion = string.find(tostring(slot_name), "slot_companion_", 1, true) == 1

        if visual and not companion then
            local registered_slot_name = slot_name
            local event_id = string.format(
                "event_register_%s_%s_cosmetics_preview_item_camera",
                body_size,
                registered_slot_name
            )
            local registered_event_id = event_id

            self[registered_event_id] = function(instance, camera_unit)
                instance._item_camera_by_slot_id[registered_slot_name] = camera_unit
                instance:_unregister_event(registered_event_id)
            end

            self:_register_event(registered_event_id)
        end
    end

    self:_register_event("event_register_cosmetics_preview_character_spawn_point")

    self._world_spawner = UIWorldSpawner:new(
        PREVIEW_WORLD_NAME,
        PREVIEW_WORLD_LAYER,
        InventoryCosmeticsViewSettings.timer_name or "ui",
        self.view_name
    )
    self._world_spawner:spawn_level(
        InventoryCosmeticsViewSettings.level_name or "content/levels/ui/cosmetics_preview/cosmetics_preview"
    )

    return true
end

NPCLookStudioPreviewView.event_register_cosmetics_preview_character_spawn_point = function(self, spawn_point_unit)
    self:_unregister_event("event_register_cosmetics_preview_character_spawn_point")
    self._spawn_point_unit = spawn_point_unit
end

NPCLookStudioPreviewView._profile_spawn_transform = function(self)
    if not safe_unit_alive(self._spawn_point_unit) then
        return nil, nil
    end

    local ok_position, spawn_position = pcall(Unit.world_position, self._spawn_point_unit, 1)
    local ok_rotation, spawn_rotation = pcall(Unit.world_rotation, self._spawn_point_unit, 1)

    if not ok_position or not ok_rotation or not spawn_position or not spawn_rotation then
        return nil, nil
    end

    local profile_spawner = self._profile_spawner

    if self._player_spawned and profile_spawner then
        local unit = spawned_character_unit(profile_spawner)

        if safe_unit_alive(unit) then
            local ok_position, position = pcall(Unit.world_position, unit, 1)

            if ok_position and position then
                spawn_position = position
            end
        end
    end

    return spawn_position, spawn_rotation
end

-- Darktide: scripts/managers/ui/ui_profile_spawner.lua
NPCLookStudioPreviewView._submit_profile = function(self)
    if not self._presentation_profile or not self._world_spawner or not self._spawn_point_unit or not self._default_camera_unit then
        return false
    end

    if not self._profile_spawner then
        local world = self._world_spawner:world()
        local camera = self._world_spawner:camera()
        local unit_spawner = self._world_spawner:unit_spawner()
        local ok_spawner, spawner_or_error = pcall(
            UIProfileSpawner.new,
            UIProfileSpawner,
            "NPCLookStudioPreviewView",
            world,
            camera,
            unit_spawner
        )

        if not ok_spawner or not spawner_or_error then
            util.report_once(self, "_profile_spawn_error", tostring(spawner_or_error), function(message)
                mod:error("Studio profile spawner creation failed: %s", message)
            end)
            return false
        end

        self._profile_spawner = spawner_or_error
    end

    local spawn_position, spawn_rotation = self:_profile_spawn_transform()

    if not spawn_position or not spawn_rotation then
        return false
    end

    local profile = self._presentation_profile
    local archetype = profile.archetype
    local archetype_name = archetype and archetype.name
    local animations_per_archetype = InventoryCosmeticsViewSettings.animations_per_archetype or {}
    local animations = type(animations_per_archetype) == "table" and archetype_name and animations_per_archetype[archetype_name]
    local animation_event = animations and animations.initial_event or "character_cosmetics_idle"
    local state_machine = archetype and archetype.character_appearance_state_machine

    if not ensure_preview_packages(self._profile_spawner, profile) then
        return false
    end

    self:_set_native_preview_hidden(false)
    self:_clear_skeleton_draw()
    self:_clear_preview_extra_slots()

    -- Do this in one spawn. Splitting it makes dependent slots pop.
    local spawned_ok, spawn_error = pcall(
        self._profile_spawner.spawn_profile,
        self._profile_spawner,
        profile,
        spawn_position,
        spawn_rotation,
        nil,
        state_machine,
        animation_event,
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        {
            ignore = true,
            position = spawn_position,
            rotation = spawn_rotation,
        }
    )

    if not spawned_ok then
        util.report_once(self, "_profile_spawn_error", tostring(spawn_error), function(message)
            mod:error("Studio profile spawn failed: %s", message)
        end)
        return false
    end

    util.report_once(self, "_profile_spawn_error", nil)
    self._player_spawned = true
    self._base_reconcile_pending = false
    self._base_reconcile_error = nil
    self._material_slot_scan_key = nil
    self._skeleton_nodes_unit = nil
    self._skeleton_nodes = nil
    self:_request_frame()

    return true
end

NPCLookStudioPreviewView.on_enter = function(self)
    NPCLookStudioPreviewView.super.on_enter(self)

    if self:_attach_session() then
        self:_sync_preview(true)
    end

    local ok, ready_or_error = xpcall(function()
        return self:_setup_background_world()
    end, util.traceback)

    if not ok then
        mod:error("Preview world setup failed: %s", tostring(ready_or_error))
    else
        self._world_setup_pending = not ready_or_error
    end
end

NPCLookStudioPreviewView.update = function(self, dt, t, input_service)
    if self:_attach_session() then
        self:_sync_preview(false)
    end

    if self._world_setup_pending and player_profile(self._preview_player) then
        local ok, ready_or_error = xpcall(function()
            return self:_setup_background_world()
        end, util.traceback)

        if not ok then
            self._world_setup_pending = false
            mod:error("Preview world setup failed: %s", tostring(ready_or_error))
        elseif ready_or_error then
            self._world_setup_pending = false
        end
    end

    if not self._player_spawned and self._spawn_point_unit and self._default_camera_unit and self._presentation_profile then
        self:_submit_profile()
    end

    local preview_input = self:_update_preview_input()

    if self._profile_spawner then
        self:_reconcile_base_loadout()

        local update_ok, update_error = pcall(
            self._profile_spawner.update,
            self._profile_spawner,
            dt,
            t,
            preview_input
        )

        util.report_once(
            self,
            "_profile_update_error",
            not update_ok and tostring(update_error) or nil,
            function(message)
                mod:error("Studio profile update failed: %s", message)
            end
        )

        if update_ok then
            self:_reconcile_base_loadout()
            self:_sync_preview_extra_slots()
            self:_report_material_slots()
            self:_update_node_skeleton()
        end
    end

    if self._frame_pending and util.retry_due(self._frame_retry, dt) then
        local framed = self:_frame_character(FRAMING.retry_transition_time)

        if not framed and util.record_attempt(self._frame_retry) then
            self:_fallback_frame()
            self._frame_pending = false
            util.report_once(self, "_frame_timeout", "Preview rig did not become ready in time", function(message)
                mod:error(message)
            end)
        end
    end

    if self._world_spawner then
        self._world_spawner:update(dt, t)
    end

    return NPCLookStudioPreviewView.super.update(self, dt, t, input_service)
end

NPCLookStudioPreviewView.on_exit = function(self)
    local function cleanup(label, fn, ...)
        if type(fn) ~= "function" then
            return true
        end

        local ok, err = pcall(fn, ...)

        if not ok then
            mod:warning("Studio preview cleanup failed (%s): %s", tostring(label), tostring(err))
        end

        return ok
    end

    cleanup("restore native visibility", self._set_native_preview_hidden, self, false)
    cleanup("clear extra slots", self._clear_preview_extra_slots, self)
    cleanup("destroy skeleton", self._destroy_skeleton_drawer, self)

    local profile_spawner = self._profile_spawner
    self._profile_spawner = nil

    if profile_spawner then
        cleanup("destroy profile spawner", profile_spawner.destroy, profile_spawner)
    end

    local world_spawner = self._world_spawner
    self._world_spawner = nil

    if world_spawner then
        cleanup("destroy world spawner", world_spawner.destroy, world_spawner)
    end

    local api = self:_api()

    if api and self._session_attached then
        cleanup("detach preview session", api.detach_view, PREVIEW_VIEW_NAME)
        self._session_attached = false
    end

    if api and type(api.view_attached) == "function" and type(api.finish) == "function" then
        local owner_ok, studio_attached = pcall(api.view_attached, STUDIO_VIEW_NAME)

        if owner_ok and studio_attached ~= true then
            cleanup("finish orphaned session", api.finish)
        end
    end

    NPCLookStudioPreviewView.super.on_exit(self)
end

return NPCLookStudioPreviewView
