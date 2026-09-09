local mod = get_mod("NPCLook")

-- Reuse the live runtime after hot reload.
local shared_runtime = rawget(mod, "npclook_extra_slot_runtime")

if shared_runtime then
    return shared_runtime
end

local util = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_util")
local RAW_UNITS = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_raw_units")
local loc = util.localize
local normalize_opacity = util.normalize_opacity
local apply_opacity_to_units = util.apply_opacity_to_units
local VisualLoadoutCustomization = require("scripts/extension_systems/visual_loadout/utilities/visual_loadout_customization")
local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
local Breeds = require("scripts/settings/breed/breeds")
local ItemSlotSettings = require("scripts/settings/item/item_slot_settings")

local ExtraSlotRuntime = {
    ownership_schema = 2,
}
local normalize_materials
local collect_material_units
local apply_material_entries_to_units
local POSE_FAILURE_LIMIT = 3
local RAW_PHYSICS_CHECK_FRAMES = { 0, 1, 2, 3, 5, 8, 13, 21, 34 }
local LIVE_HEALTH_INTERVAL = 0.25
local FIRST_PERSON_RETRY_INTERVAL = 0.25
local FIRST_PERSON_RETRY_LIMIT = 8
local PHYSICS_MAINTENANCE_INTERVAL = 1
local PACKAGE_RELEASE_SETTLE_FRAMES = 60
local RAW_PACKAGE_RELEASE_SETTLE_FRAMES = 120
local PACKAGE_RELEASE_GUARD_LIMIT = 600
local LIVE_CONTEXT = {}

local contexts = {}
local contexts_by_parent = setmetatable({}, { __mode = "k" })
local physics_contexts = {}
local dirty_contexts = {}
local deletion_pending = setmetatable({}, { __mode = "k" })
local managed_deletion_roots = setmetatable({}, { __mode = "k" })
local raw_equipment_records = {}
-- Runtime-only ownership.
local owned_visual_units = setmetatable({}, { __mode = "k" })
local owned_visual_spawners = setmetatable({}, { __mode = "k" })
local owned_visual_parents = setmetatable({}, { __mode = "k" })
local owned_visual_children = setmetatable({}, { __mode = "k" })
local owned_visual_records = setmetatable({}, { __mode = "k" })
local package_reference_counter = 0
local deferred_package_releases = {}
local live_health_elapsed = 0
local retained_package_cache = rawget(mod, "npclook_extra_package_cache")
local suppress_package_unload = false

if type(retained_package_cache) ~= "table" then
    retained_package_cache = {}
    rawset(mod, "npclook_extra_package_cache", retained_package_cache)
end


-- Package handles are scoped to their PackageManager.
local entries_by_manager = retained_package_cache.entries_by_manager

if type(entries_by_manager) ~= "table" then
    entries_by_manager = {}

    if retained_package_cache.package_manager and type(retained_package_cache.entries) == "table" then
        entries_by_manager[retained_package_cache.package_manager] = retained_package_cache.entries
        retained_package_cache.current_manager = retained_package_cache.package_manager
    end

    retained_package_cache.entries_by_manager = entries_by_manager
    retained_package_cache.package_manager = nil
    retained_package_cache.entries = nil
end

local function retained_package_entries(package_manager)
    if not package_manager then
        return nil
    end

    if retained_package_cache.current_manager ~= package_manager then
        retained_package_cache.current_manager = package_manager

        for manager in pairs(entries_by_manager) do
            if manager ~= package_manager then
                entries_by_manager[manager] = nil
            end
        end
    end

    local entries = entries_by_manager[package_manager]

    if type(entries) ~= "table" then
        entries = {}
        entries_by_manager[package_manager] = entries
    end

    return entries
end

local function cached_package_entries(package_manager)
    local entries = package_manager and entries_by_manager[package_manager]

    return type(entries) == "table" and entries or nil
end
local MATERIAL_TARGET_SEPARATOR = "\29"
local ANCHOR_ATTACH_NODE_BY_SLOT = {
    slot_gear_head = "j_head",
    slot_body_face = "j_head",
    slot_body_hair = "j_head",
    slot_body_hair_color = "j_head",
    slot_body_face_hair = "j_head",
    slot_body_face_hair_color = "j_head",
    slot_body_face_tattoo = "j_head",
    slot_body_face_scar = "j_head",
    slot_body_face_makeup = "j_head",
    slot_body_eye_color = "j_head",
    slot_body_eye_color_secondary = "j_head",
    slot_body_skin_color = "j_spine2",
    slot_body_skin_color_secondary = "j_spine2",
    slot_body_skin_discoloration = "j_spine2",
    slot_gear_upperbody = "j_spine2",
    slot_body_torso = "j_spine2",
    slot_body_arms = "j_spine2",
    slot_gear_lowerbody = "j_hips",
    slot_body_legs = "j_hips",
    slot_body_tattoo = "j_spine2",
    slot_gear_extra_cosmetic = "j_spine2",
    slot_gear_material_override_decal = "j_spine2",
}

local function normalize_attach_node(value)
    if type(value) == "string" then
        value = string.gsub(value, "[%c]", "")
        value = string.gsub(value, "^%s+", "")
        value = string.gsub(value, "%s+$", "")
        value = value ~= "" and string.sub(value, 1, 96) or nil

        if value and string.match(value, "^%d+$") then
            local index = tonumber(value)

            return index and index >= 1 and index or nil
        end

        return value
    elseif type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value >= 1 and value == math.floor(value) then
        return value
    end

    return nil
end

local function material_entry_parts(value)
    if type(value) ~= "string" or value == "" then
        return nil, nil
    end

    local separator = string.find(value, MATERIAL_TARGET_SEPARATOR, 1, true)

    if not separator then
        return value, nil
    end

    local item_name = string.sub(value, 1, separator - 1)
    local target = string.sub(value, separator + 1)
    target = string.gsub(target, "[%c]", "")
    target = string.gsub(target, "^%s+", "")
    target = string.gsub(target, "%s+$", "")

    return item_name ~= "" and item_name or nil, target ~= "" and string.sub(target, 1, 96) or nil
end


local function material_item_name(value)
    local item_name = material_entry_parts(value)

    return item_name
end


function ExtraSlotRuntime.install_material_api(api)
    if type(api) ~= "table" then
        return false, "material API is not a table"
    end

    local normalize = api.normalize_materials
    local collect = api.collect_units
    local apply = api.apply_material_entries_to_units

    if type(normalize) ~= "function" then
        return false, "normalize_materials is unavailable"
    elseif type(collect) ~= "function" then
        return false, "collect_units is unavailable"
    elseif type(apply) ~= "function" then
        return false, "apply_material_entries_to_units is unavailable"
    end

    normalize_materials = normalize
    collect_material_units = collect
    apply_material_entries_to_units = apply

    return true
end

local function normalize_transform(value)
    value = type(value) == "table" and value or {}

    local function number(field, fallback, minimum, maximum)
        local result = tonumber(value[field]) or fallback

        if result ~= result or result == math.huge or result == -math.huge then
            result = fallback
        end

        return math.clamp(result, minimum, maximum)
    end

    local materials = normalize_materials(value)

    local scale = number("scale", 1, -30, 30)
    local xyz_scale = value.xyz_scale == true
    local scale_x = xyz_scale and number("scale_x", scale, -30, 30) or scale
    local scale_y = xyz_scale and number("scale_y", scale, -30, 30) or scale
    local scale_z = xyz_scale and number("scale_z", scale, -30, 30) or scale

    local first_person = value.first_person == true

    -- Later overrides intentionally win.
    return {
        enabled = value.enabled == true,
        deform = value.deform ~= false,
        first_person = first_person,
        animate_first_person = first_person and value.animate_first_person == true,
        attach_node = normalize_attach_node(value.attach_node),
        px = number("px", 0, -5, 5),
        py = number("py", 0, -5, 5),
        pz = number("pz", 0, -5, 5),
        rx = number("rx", 0, -180, 180),
        ry = number("ry", 0, -180, 180),
        rz = number("rz", 0, -180, 180),
        xyz_scale = xyz_scale,
        scale = scale,
        scale_x = scale_x,
        scale_y = scale_y,
        scale_z = scale_z,
        materials = materials,
    }
end

local function runtime_transform(value)
    local transform = value or normalize_transform(nil)

    local enabled = transform.enabled == true
    local rotation = enabled
        and Quaternion.from_euler_angles_xyz(transform.rx, transform.ry, transform.rz)
        or Quaternion.identity()

    local scale_x = transform.xyz_scale and transform.scale_x or transform.scale
    local scale_y = transform.xyz_scale and transform.scale_y or transform.scale
    local scale_z = transform.xyz_scale and transform.scale_z or transform.scale

    return {
        enabled = enabled,
        offset_x = enabled and transform.px or 0,
        offset_y = enabled and transform.py or 0,
        offset_z = enabled and transform.pz or 0,
        rotation = QuaternionBox(rotation),
        scale_x = enabled and scale_x or 1,
        scale_y = enabled and scale_y or 1,
        scale_z = enabled and scale_z or 1,
    }
end

local function transform_signature(value, already_normalized)
    local transform = already_normalized and value or normalize_transform(value)

    local signature = string.format(
        "%s,%s,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f",
        transform.enabled and "1" or "0",
        transform.deform and "1" or "0",
        transform.first_person and "1" or "0",
        transform.animate_first_person and "1" or "0",
        transform.xyz_scale and "1" or "0",
        tostring(transform.attach_node or ""),
        transform.px, transform.py, transform.pz,
        transform.rx, transform.ry, transform.rz,
        transform.scale, transform.scale_x, transform.scale_y, transform.scale_z
    )

    return signature .. "|" .. table.concat(transform.materials, "|")
end

local function capture_root_baseline(unit)
    local ok_position, position = pcall(Unit.local_position, unit, 1)
    local ok_rotation, rotation = pcall(Unit.local_rotation, unit, 1)
    local ok_scale, scale = pcall(Unit.local_scale, unit, 1)

    if not ok_position or not ok_rotation or not ok_scale
        or not position or not rotation or not scale then
        return nil
    end

    -- Copy engine pose values.
    local ok_copy, copied = pcall(function()
        return {
            position = Vector3.to_array(position),
            rotation = QuaternionBox(rotation),
            scale = Vector3.to_array(scale),
        }
    end)

    return ok_copy and copied or nil
end

local function root_baseline_values(baseline)
    if not baseline then
        return nil
    end

    local ok_values, position, rotation, scale = pcall(function()
        return Vector3.from_array(baseline.position),
            QuaternionBox.unbox(baseline.rotation),
            Vector3.from_array(baseline.scale)
    end)

    if ok_values then
        return position, rotation, scale
    end

    return nil
end

local function multiplied_vector(left, right)
    return Vector3(left.x * right.x, left.y * right.y, left.z * right.z)
end

local function divided_vector(vector, divisor)
    local function divide(value, by)
        return math.abs(by) > 1e-06 and value / by or 0
    end

    return Vector3(
        divide(vector.x, divisor.x),
        divide(vector.y, divisor.y),
        divide(vector.z, divisor.z)
    )
end

local function apply_transform(unit, value, baseline, already_normalized)
    local transform = already_normalized and value or normalize_transform(value)
    if not transform.enabled then
        return transform
    end

    baseline = baseline or capture_root_baseline(unit)

    if not baseline then
        error("Could not capture the cosmetic root baseline")
    end

    local baseline_position, baseline_rotation, baseline_scale = root_baseline_values(baseline)

    if not baseline_position or not baseline_rotation or not baseline_scale then
        error("Could not restore the cosmetic root baseline")
    end

    local offset = Vector3(transform.px, transform.py, transform.pz)
    local rotation = Quaternion.from_euler_angles_xyz(transform.rx, transform.ry, transform.rz)

    -- Apply editor values as deltas from the authored linked pose.
    local ok_position, position_error = pcall(Unit.set_local_position, unit, 1, baseline_position + offset)

    if not ok_position then
        error("set_local_position failed: " .. tostring(position_error))
    end

    local ok_rotation, rotation_error = pcall(
        Unit.set_local_rotation,
        unit,
        1,
        Quaternion.multiply(baseline_rotation, rotation)
    )

    if not ok_rotation then
        error("set_local_rotation failed: " .. tostring(rotation_error))
    end

    local scale_x = transform.xyz_scale and transform.scale_x or transform.scale
    local scale_y = transform.xyz_scale and transform.scale_y or transform.scale
    local scale_z = transform.xyz_scale and transform.scale_z or transform.scale
    local ok_scale, scale_error = pcall(
        Unit.set_local_scale,
        unit,
        1,
        Vector3(
            baseline_scale.x * scale_x,
            baseline_scale.y * scale_y,
            baseline_scale.z * scale_z
        )
    )

    if not ok_scale then
        error("set_local_scale failed: " .. tostring(scale_error))
    end

    return transform
end

local function item_cache()
    return type(mod.npclook_item_cache) == "function" and mod.npclook_item_cache() or nil
end

local safe_unit_alive = util.safe_unit_alive
local safe_lod_group = util.safe_lod_group

local function unit_has_direct_node(unit, node)
    if not safe_unit_alive(unit) then
        return false
    elseif type(node) == "string" then
        if node == "" then
            return false
        end

        local ok_has, has_node = pcall(Unit.has_node, unit, node)

        return ok_has and has_node == true
    elseif type(node) == "number" and node == math.floor(node) and node >= 1 then
        local ok_count, count = pcall(Unit.num_scene_graph_items, unit)

        return ok_count and type(count) == "number" and node <= count
    end

    return false
end

local function safe_unit_world(unit)
    if not safe_unit_alive(unit) then
        return nil
    end

    local ok, world = pcall(Unit.world, unit)

    return ok and world or nil
end

local function unregister_context_parent(owner, context)
    local parent_unit = context and context.parent_unit
    local owners = parent_unit and contexts_by_parent[parent_unit]

    if owners then
        owners[owner] = nil

        if next(owners) == nil then
            contexts_by_parent[parent_unit] = nil
        end
    end
end

local function register_context_parent(owner, context)
    local parent_unit = context and context.parent_unit

    if not parent_unit then
        return
    end

    local owners = contexts_by_parent[parent_unit]

    if not owners then
        owners = {}
        contexts_by_parent[parent_unit] = owners
    end

    owners[owner] = true
end

local function new_context(owner, is_live)
    local context = {
        owner = owner,
        is_live = is_live == true,
        records = {},
        pending = {},
        physics_records = {},
        parent_unit = nil,
        world = nil,
        unit_spawner = nil,
        item_definitions = nil,
        mission = nil,
        breed_name = nil,
        from_ui_profile_spawner = false,
        force_highest_lod_step = false,
        first_person_mode = false,
        first_person_unit = nil,
        first_person_extension = nil,
        driver_base_unit = nil,
        context_label = is_live == true and "live" or nil,
    }

    contexts[owner] = context

    return context
end

local function context_for(owner, is_live)
    return contexts[owner] or new_context(owner, is_live)
end

local function refresh_context_activity(context)
    if not context then
        return
    end

    local physics_records = context.physics_records

    table.clear(physics_records)

    for _, record in pairs(context.records) do
        if not record.failed and record.physics_tracker then
            physics_records[record] = true
        end
    end

    physics_contexts[context] = next(physics_records) ~= nil or nil
end

local function clear_context_activity(context)
    if not context then
        return
    end

    table.clear(context.physics_records)
    physics_contexts[context] = nil
    dirty_contexts[context] = nil
end

local function discard_empty_context(context)
    if not context or context.is_live
        or next(context.records) ~= nil or next(context.pending) ~= nil then
        return false
    end

    local owner = context.owner

    unregister_context_parent(owner, context)
    clear_context_activity(context)

    if contexts[owner] == context then
        contexts[owner] = nil
    end

    return true
end

local function is_studio_preview_context(context)
    return context and context.context_label == "NPCLookStudioPreviewView"
end

local function set_visual_hierarchy_visibility(root_unit, attachment_map, visible)
    local seen = {}
    local event_name = visible and "lua_visible" or "lua_hidden"

    local function apply(unit)
        if not safe_unit_alive(unit) or seen[unit] then
            return
        end

        seen[unit] = true
        pcall(Unit.flow_event, unit, event_name)
        pcall(Unit.set_unit_visibility, unit, visible == true, true)

        local children = type(attachment_map) == "table" and attachment_map[unit]

        for i = 1, #(children or {}) do
            apply(children[i])
        end
    end

    apply(root_unit)
end

local function set_record_perspective_visibility(record, first_person_mode, force)
    if not record then
        return
    end

    first_person_mode = first_person_mode == true

    if force or record.first_person_mode ~= first_person_mode then
        record.first_person_mode = first_person_mode
        local visible_by_opacity = normalize_opacity(record.opacity) > 0

        set_visual_hierarchy_visibility(
            record.root_unit,
            record.attachment_map,
            visible_by_opacity and not first_person_mode
        )
        set_visual_hierarchy_visibility(
            record.animated_first_person_root_unit,
            record.animated_first_person_attachment_map,
            visible_by_opacity
                and first_person_mode
                and record.first_person_enabled == true
                and record.first_person_animate == true
        )
        set_visual_hierarchy_visibility(
            record.first_person_root_unit,
            record.first_person_attachment_map,
            visible_by_opacity
                and first_person_mode
                and record.first_person_enabled == true
                and (record.first_person_animate ~= true or record.raw_unit == true)
        )
    end
end

local function apply_context_first_person_visibility(context)
    if not context or not context.is_live then
        return
    end

    for _, record in pairs(context.records) do
        set_record_perspective_visibility(record, context.first_person_mode, true)
    end
end

local function entry_uses_studio_deformation_mirror(context, entry)
    local transform = entry and entry.transform

    -- Studio keeps deformation separate from the editable root.
    return is_studio_preview_context(context)
        and transform ~= nil
        and transform.enabled == true
        and transform.deform == true
        or false
end

local function entry_uses_deformation_driver(context, entry)
    local transform = entry and entry.transform

    -- Studio uses a mirror; live contexts use the character driver.
    return transform and transform.enabled == true and transform.deform == true
        and not entry_uses_studio_deformation_mirror(context, entry)
end

local function studio_mirror_state_matches(record, mirror_required)
    if mirror_required then
        return record.uses_studio_deformation_mirror == true
            or record.studio_mirror_fallback == true
    end

    return record.uses_studio_deformation_mirror ~= true
        and record.studio_mirror_fallback ~= true
end

local function deformation_driver_state_matches(record, driver_required)
    if driver_required then
        return record.uses_deformation_driver == true
            or record.deformation_driver_fallback == true
    end

    return record.uses_deformation_driver ~= true
        and record.deformation_driver_fallback ~= true
end

local function normalize_override_names(values)
    local result = {}
    local seen = {}

    for i = 1, #(values or {}) do
        local value = values[i]

        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end

    return result
end

local EXTRA_ITEM_DEPTH_LIMIT = 24

local function sanitize_raw_item_tree(item, definitions, memo, depth)
    if type(item) ~= "table" then
        return item
    elseif depth > EXTRA_ITEM_DEPTH_LIMIT then
        error(string.format("Raw item attachments exceed %d levels", EXTRA_ITEM_DEPTH_LIMIT))
    end

    memo = memo or {}
    item.npclook_generated = true
    item.voice_fx_preset = nil
    item.event_in_parent_state_machine = nil
    item.stabilize_neck = false

    local function sanitize_tree(tree, tree_depth)
        if type(tree) ~= "table" then
            return tree
        elseif depth + tree_depth > EXTRA_ITEM_DEPTH_LIMIT then
            error(string.format("Raw item attachments exceed %d levels", EXTRA_ITEM_DEPTH_LIMIT))
        end

        for _, entry in pairs(tree) do
            if type(entry) == "table" then
                local attached = entry.item

                if type(attached) == "string" then
                    local source = definitions and rawget(definitions, attached)
                    local clone = memo[attached]

                    if clone == false then
                        error(string.format("Raw item attachment cycle at %s", attached))
                    elseif clone == nil and type(source) == "table" then
                        memo[attached] = false
                        clone = table.clone_instance(source)
                        sanitize_raw_item_tree(clone, definitions, memo, depth + tree_depth + 1)
                        memo[attached] = clone
                    end

                    if type(clone) == "table" then
                        entry.item = clone
                    end
                elseif type(attached) == "table" then
                    sanitize_raw_item_tree(attached, definitions, memo, depth + tree_depth + 1)
                end

                sanitize_tree(entry.children, tree_depth + 1)
            end
        end

        return tree
    end

    sanitize_tree(item.attachments, 1)
    sanitize_tree(item.children, 1)

    return item
end

local function make_extra_slot_item(item_name, breed_name, value, dependency_materials, anchor_attach_node, variant_state, opacity)
    local cache = item_cache()
    local master_item = type(mod.npclook_item_definition) == "function"
        and mod.npclook_item_definition(item_name)
        or cache and rawget(cache, item_name)

    if type(master_item) ~= "table" then
        return nil, loc("error_missing_item", tostring(item_name))
    elseif util.item_is_2d(master_item, item_name) or not util.item_has_visual_base(master_item, breed_name) then
        return nil, loc("error_visual_slot_unavailable")
    end

    local item = table.clone_instance(master_item)
    item.npclook_generated = true
    item.voice_fx_preset = nil

    if item.npclook_raw_unit == true then
        local memo = {}

        if type(item.name) == "string" then
            memo[item.name] = false
        end

        sanitize_raw_item_tree(item, cache, memo, 0)

        if type(item.name) == "string" then
            memo[item.name] = item
        end
    end

    item.npclook_raw_variant_state = RAW_UNITS.normalize_variant_state(variant_state, item_name)
    item.npclook_raw_variant_signature = RAW_UNITS.variant_signature(item.npclook_raw_variant_state)
    item.npclook_opacity = normalize_opacity(opacity)

    -- Keep parent material overrides local to this item.
    item.material_override_apply_to_parent = false

    local transform = normalize_transform(value)
    local loose_transform = transform.enabled and not transform.deform
    local deformed_transform = transform.enabled and transform.deform
    local inherited_overrides = normalize_override_names(dependency_materials)
    local authored_overrides = type(item.material_override_items) == "table"
        and table.clone(item.material_override_items) or {}
    local combined_overrides = table.clone(authored_overrides)

    for i = 1, #inherited_overrides do
        combined_overrides[#combined_overrides + 1] = inherited_overrides[i]
    end

    item.npclook_dependency_material_overrides = inherited_overrides
    item.npclook_authored_material_overrides = authored_overrides
    item.material_override_items = combined_overrides
    item.npclook_material_signature = table.concat(inherited_overrides, "\30")
        .. "\29" .. table.concat(transform.materials, "\31")

    if #transform.materials > 0 then
        for i = 1, #transform.materials do
            local override_name = material_item_name(transform.materials[i])

            if override_name then
                item.material_override_items[#item.material_override_items + 1] = override_name
            end
        end

        item.npclook_custom_material_overrides = transform.materials
    end

    -- Transformed items use a driver or the Studio mirror.
    if loose_transform then
        item.link_map_mode = "LINK_MODE_NONE"
        item.attach_node = anchor_attach_node or 1
        -- Use the selected anchor.
        rawset(item, "breed_attach_node", false)
    elseif deformed_transform then
        -- Deformed links use node names.
        item.link_map_mode = "LINK_MODE_NODE_NAME"
    end

    return item
end

local function item_dependencies(item, definitions, mission)
    local dependencies = {}
    local ok, err = pcall(
        ItemPackage.compile_item_instance_dependencies,
        item,
        definitions,
        dependencies,
        mission
    )

    if not ok then
        return nil, err
    end

    for package_name in pairs(dependencies) do
        if type(package_name) ~= "string" or package_name == "" then
            return nil, string.format("%s has an empty package reference", tostring(item and item.name or "item"))
        end
    end

    return dependencies
end

local function release_package_record(record)
    if not record or record.released then
        return true
    end

    record.cancelled = true
    record.released = true
    record.release_queued = nil

    local package_manager = record.package_manager
    local package_entries = record.package_entries
    local retained_entries = cached_package_entries(package_manager)
    local release = package_manager and package_manager.release
    local seen = {}

    for i = 1, #(package_entries or {}) do
        local entry = package_entries[i]

        if type(entry) == "table" and not seen[entry] then
            seen[entry] = true

            if record.retain_packages == true then
                entry.persistent = true
            end

            entry.references = math.max((tonumber(entry.references) or 1) - 1, 0)

            if entry.references == 0 and not entry.persistent and not suppress_package_unload
                and retained_package_cache.current_manager == package_manager
                and package_manager == Managers.package
                and package_manager._shutdown_has_started ~= true then
                if retained_entries and retained_entries[entry.package_name] == entry then
                    retained_entries[entry.package_name] = nil
                end

                if entry.resource_loader_ticket then
                    RAW_UNITS.release_ticket(entry.resource_loader_ticket)
                elseif entry.load_id and type(release) == "function" then
                    pcall(release, package_manager, entry.load_id)
                end

                entry.resource_loader_ticket = nil
                entry.load_id = nil
                entry.ready = false
            end
        end
    end

    record.package_entries = nil
    record.release_guard_units = nil

    return true
end

local function package_release_guard_alive(units)
    for i = 1, #(units or {}) do
        if safe_unit_alive(units[i]) then
            return true
        end
    end

    return false
end

local function extend_package_release_guard(record, units)
    if type(record) ~= "table" or type(units) ~= "table" or #units == 0 then
        return
    end

    local guard = record.release_guard_units

    if type(guard) ~= "table" then
        guard = {}
        record.release_guard_units = guard
    end

    local seen = {}

    for i = 1, #guard do
        local unit = guard[i]

        if unit then
            seen[unit] = true
        end
    end

    for i = 1, #units do
        local unit = units[i]

        if unit and not seen[unit] then
            seen[unit] = true
            guard[#guard + 1] = unit
        end
    end
end

local function queue_package_release(context, record, delay)
    if not record or record.released or record.release_queued then
        return
    end

    record.release_queued = true

    local minimum = record.raw_unit
        and RAW_PACKAGE_RELEASE_SETTLE_FRAMES
        or PACKAGE_RELEASE_SETTLE_FRAMES
    local frames = math.max(math.floor(tonumber(delay) or 0), minimum)

    deferred_package_releases[#deferred_package_releases + 1] = {
        record = record,
        frames = frames,
        waited_frames = 0,
    }
end

local function update_deferred_package_releases()
    for i = #deferred_package_releases, 1, -1 do
        local pending = deferred_package_releases[i]
        local record = pending.record
        local guard_alive = package_release_guard_alive(record and record.release_guard_units)

        pending.waited_frames = (pending.waited_frames or 0) + 1

        if guard_alive then
            if pending.waited_frames >= PACKAGE_RELEASE_GUARD_LIMIT then
                record.retain_packages = true
                mod:warning(
                    "Retaining extra-slot packages for %s because its units did not finish deleting.",
                    tostring(record.item_name or "unknown")
                )
                release_package_record(record)
                table.remove(deferred_package_releases, i)
            end
        else
            pending.frames = pending.frames - 1

            if pending.frames <= 0 then
                release_package_record(record)
                table.remove(deferred_package_releases, i)
            end
        end
    end
end

local function retire_pending_package(context, id, delay)
    local pending = context.pending[id]

    if pending then
        context.pending[id] = nil
        pending.cancelled = true
        queue_package_release(context, pending, delay)
    end
end

local function refresh_package_ready(record)
    if record.cancelled then
        record.ready = false
        return false
    end

    for i = 1, record.expected_loads do
        local entry = record.package_entries and record.package_entries[i]

        if not entry or not entry.ready then
            record.waiting_package = record.package_names[i]
            record.ready = false
            return false
        end
    end

    record.ready = true
    record.waiting_package = nil

    return true
end

local function package_entry_has_reference(entry)
    if type(entry) ~= "table" then
        return false
    elseif entry.resource_loader_ticket then
        local status = RAW_UNITS.ticket_status(entry.resource_loader_ticket)
        return status == "pending" or status == "loaded"
    end

    return entry.load_id ~= nil
end

local function acquire_packages(context, id, item)
    local package_manager = Managers.package
    local load = package_manager and package_manager.load

    if type(load) ~= "function" then
        return nil, loc("error_live_package_manager"), false
    end

    local use_resource_loader = item.npclook_raw_unit == true and RAW_UNITS.available()
    local waiting = context.pending[id]

    if waiting and (waiting.package_manager ~= package_manager
        or waiting.item_name ~= item.name
        or waiting.material_signature ~= item.npclook_material_signature
        or waiting.variant_signature ~= item.npclook_raw_variant_signature
        or waiting.transform_signature ~= item.npclook_extra_transform_signature) then
        retire_pending_package(context, id, 0)
        waiting = nil
    end

    if waiting then
        refresh_package_ready(waiting)

        if waiting.ready then
            context.pending[id] = nil
            return waiting, nil, false
        end

        return nil, loc("error_live_package_not_ready", tostring(waiting.waiting_package)), true
    end

    local definitions = context.item_definitions or item_cache()
    local dependencies, dependency_error = item_dependencies(item, definitions, context.mission)

    if not dependencies then
        return nil, loc("error_package_dependencies", tostring(dependency_error)), false
    end

    local package_names = table.keys(dependencies)
    local retained_entries = retained_package_entries(package_manager)
    local retain_packages = item.npclook_raw_unit == true
        and item.npclook_raw_retain_package ~= false

    table.sort(package_names)
    package_reference_counter = package_reference_counter + 1

    local record = {
        item_name = item.name,
        material_signature = item.npclook_material_signature,
        variant_signature = item.npclook_raw_variant_signature,
        transform_signature = item.npclook_extra_transform_signature,
        package_entries = {},
        package_names = package_names,
        package_manager = package_manager,
        ready = #package_names == 0,
        waiting_package = package_names[1],
        expected_loads = #package_names,
        cancelled = false,
        retain_packages = retain_packages,
        raw_unit = item.npclook_raw_unit == true,
    }
    local reference_name = string.format("NPCLookExtraSlot_%d", package_reference_counter)

    if not record.ready then
        context.pending[id] = record
    end

    for i = 1, #package_names do
        local package_name = package_names[i]
        local package_entry = retained_entries[package_name]

        if type(package_entry) ~= "table"
            or package_entry.package_manager ~= package_manager
            or package_entry.package_name ~= package_name
            or not package_entry_has_reference(package_entry) then
            if type(package_entry) == "table"
                and not package_entry.persistent and not retain_packages then
                if package_entry.resource_loader_ticket then
                    RAW_UNITS.release_ticket(package_entry.resource_loader_ticket)
                elseif package_entry.load_id then
                    local entry_manager = package_entry.package_manager or package_manager
                    local release = entry_manager and entry_manager.release

                    if type(release) == "function" and not suppress_package_unload
                        and entry_manager == Managers.package
                        and entry_manager._shutdown_has_started ~= true then
                        pcall(release, entry_manager, package_entry.load_id)
                    end
                end
            end

            retained_entries[package_name] = nil
            package_entry = nil
        end

        if package_entry and retain_packages then
            package_entry.persistent = true
        end

        if not package_entry then
            package_entry = {
                package_manager = package_manager,
                package_name = package_name,
                ready = false,
                references = 0,
                persistent = retain_packages,
            }
            retained_entries[package_name] = package_entry
            package_entry.references = 1
            record.package_entries[i] = package_entry

            if use_resource_loader then
                local function package_loaded(ticket, _, load_error)
                    local no_longer_retained = retained_entries[package_name] ~= package_entry
                    local no_references = (tonumber(package_entry.references) or 0) <= 0

                    if no_longer_retained or no_references and not package_entry.persistent then
                        if ticket and not package_entry.persistent then
                            RAW_UNITS.release_ticket(ticket)
                        end
                        return
                    elseif load_error then
                        package_entry.error = tostring(load_error)
                        return
                    end

                    package_entry.resource_loader_ticket = ticket
                    package_entry.ready = true

                    if type(mod.npclook_schedule_reapply) == "function" then
                        mod.npclook_schedule_reapply()
                    end
                end

                local ticket, load_error = RAW_UNITS.acquire_package(
                    package_name,
                    package_loaded,
                    {
                        prioritize = true,
                        reference_name = reference_name,
                    }
                )

                if not ticket then
                    context.pending[id] = nil

                    if retained_entries[package_name] == package_entry then
                        retained_entries[package_name] = nil
                    end

                    release_package_record(record)

                    return nil, loc(
                        "error_live_package_acquire",
                        tostring(package_name),
                        tostring(load_error or loc("generic_unknown_error"))
                    ), false
                end

                package_entry.resource_loader_ticket = ticket
                package_entry.ready = RAW_UNITS.ticket_status(ticket) == "loaded"
            else
                local function package_loaded(load_id)
                    local no_longer_retained = retained_entries[package_name] ~= package_entry
                    local no_references = (tonumber(package_entry.references) or 0) <= 0

                    if no_longer_retained or no_references and not package_entry.persistent then
                        local release = package_manager and package_manager.release

                        if type(release) == "function" and load_id
                            and not package_entry.persistent and not suppress_package_unload
                            and retained_package_cache.current_manager == package_manager then
                            pcall(release, package_manager, load_id)
                        end

                        return
                    end

                    if package_entry.load_id == nil or package_entry.load_id == load_id then
                        package_entry.load_id = load_id
                        package_entry.ready = true

                        if type(mod.npclook_schedule_reapply) == "function" then
                            mod.npclook_schedule_reapply()
                        end
                    end
                end

                local ok_load, load_id = pcall(
                    load,
                    package_manager,
                    package_name,
                    reference_name,
                    package_loaded,
                    true
                )

                if not ok_load or not load_id then
                    context.pending[id] = nil

                    if retained_entries[package_name] == package_entry then
                        retained_entries[package_name] = nil
                    end

                    release_package_record(record)

                    return nil, loc(
                        "error_live_package_acquire",
                        tostring(package_name),
                        tostring(load_id or loc("generic_unknown_error"))
                    ), false
                end

                package_entry.load_id = load_id
            end
        end

        if retain_packages then
            package_entry.persistent = true
        end

        if record.package_entries[i] ~= package_entry then
            package_entry.references = (tonumber(package_entry.references) or 0) + 1
            record.package_entries[i] = package_entry
        end
    end

    refresh_package_ready(record)

    if record.ready then
        context.pending[id] = nil
        return record, nil, false
    end

    return nil, loc("error_live_package_not_ready", tostring(record.waiting_package)), true
end

local function desired_extra_slots(applied, suppressed, empty, anchors, transforms)
    local ids = {}

    for id, anchor in pairs(anchors or {}) do
        if type(id) == "string" and string.match(id, "^extra_%d+$") and type(anchor) == "string" then
            ids[#ids + 1] = id
        end
    end

    table.sort(ids, function(left, right)
        return (tonumber(string.match(left, "(%d+)$")) or 0) < (tonumber(string.match(right, "(%d+)$")) or 0)
    end)

    local entries = {}

    for i = 1, #ids do
        local id = ids[i]
        local item_name = applied and applied[id]

        if type(item_name) == "string" and item_name ~= ""
            and not (suppressed and suppressed[id]) and not (empty and empty[id]) then
            entries[#entries + 1] = {
                id = id,
                item_name = item_name,
                anchor = anchors[id],
                transform = normalize_transform(transforms and transforms[id]),
                transform_signature = transform_signature(transforms and transforms[id]),
            }
        end
    end

    return entries
end

local function loadout_item(value, definitions)
    if type(value) == "table" then
        return value
    elseif type(value) == "string" and type(definitions) == "table" then
        return rawget(definitions, value)
    end

    return nil
end

local function fallback_anchor_attach_node(slot_name)
    local configured = ANCHOR_ATTACH_NODE_BY_SLOT[slot_name]

    if configured then
        return configured
    elseif type(slot_name) == "string" then
        local lower = string.lower(slot_name)

        if string.find(lower, "head", 1, true)
            or string.find(lower, "face", 1, true)
            or string.find(lower, "hair", 1, true)
            or string.find(lower, "eye", 1, true) then
            return "j_head"
        elseif string.find(lower, "lower", 1, true)
            or string.find(lower, "leg", 1, true)
            or string.find(lower, "foot", 1, true)
            or string.find(lower, "shoe", 1, true) then
            return "j_hips"
        end
    end

    return "j_spine2"
end

local function anchor_attach_node(slot_name)
    -- Resolve rigid anchors on the character skeleton.
    return fallback_anchor_attach_node(slot_name)
end

local function anchor_region_candidates(slot_name, preferred)
    local candidates = {}
    local seen = {}

    local function append(node)
        node = normalize_attach_node(node)

        if node ~= nil and not seen[node] then
            seen[node] = true
            candidates[#candidates + 1] = node
        end
    end

    append(preferred)

    local region = fallback_anchor_attach_node(slot_name)
    append(region)

    if region == "j_head" then
        append("j_neck")
        append("j_spine2")
    elseif region == "j_hips" then
        append("j_spine1")
        append("j_spine2")
    else
        append("j_spine1")
        append("j_hips")
    end

    append(1)

    return candidates
end

local function resolve_anchor_attach_node(parent_unit, slot_name, preferred)
    local candidates = anchor_region_candidates(slot_name, preferred)

    for i = 1, #candidates do
        if unit_has_direct_node(parent_unit, candidates[i]) then
            return candidates[i]
        end
    end

    -- Fall back to the character root.
    return 1
end

local function resolve_entry_anchor_nodes(parent_unit, entries)
    for i = 1, #(entries or {}) do
        local entry = entries[i]

        if entry.transform.enabled and not entry.transform.deform then
            entry.attach_node = resolve_anchor_attach_node(
                parent_unit,
                entry.anchor,
                entry.attach_node
            )
        end
    end

    return entries
end

local function is_persistent_ui_preview_context(context)
    return context
        and context.from_ui_profile_spawner == true
        and not is_studio_preview_context(context)
end

local function material_parent_slots(slot_name, item, authored_parent_slots)
    local settings = ItemSlotSettings[slot_name]
    local forced = settings and settings.forced_parent_slot_names

    if type(forced) == "table" and next(forced) ~= nil then
        return forced, true
    end

    local parents = type(authored_parent_slots) == "table" and authored_parent_slots
        or type(item) == "table" and item.parent_slot_names

    return type(parents) == "table" and parents or nil, false
end

local function is_parent_material_item(slot_name, item, authored_parent_slots)
    if type(item) ~= "table" or item.material_override_apply_to_parent ~= true then
        return false
    end

    local parents = material_parent_slots(slot_name, item, authored_parent_slots)

    return type(parents) == "table" and next(parents) ~= nil
end

local function append_item_overrides(result, seen, item)
    for i = 1, #(type(item) == "table" and item.material_override_items or {}) do
        local override_name = item.material_override_items[i]

        if type(override_name) == "string" and override_name ~= "" and not seen[override_name] then
            seen[override_name] = true
            result[#result + 1] = override_name
        end
    end
end

local function parent_list_contains(parents, slot_name)
    for i = 1, #(parents or {}) do
        if parents[i] == slot_name then
            return true
        end
    end

    return false
end

local function plan_extra_slots(loadout, applied, suppressed, empty, anchors, transforms, breed_name, variants, opacity)
    local definitions = item_cache() or {}
    local raw_entries = desired_extra_slots(applied, suppressed, empty, anchors, transforms)

    for slot_name, item_name in pairs(applied or {}) do
        if not (anchors and anchors[slot_name])
            and not (suppressed and suppressed[slot_name])
            and not (empty and empty[slot_name]) then
            local item = type(mod.npclook_item_definition) == "function"
                and mod.npclook_item_definition(item_name)
                or rawget(definitions, item_name)

            if RAW_UNITS.use_overlay_spawn(item) then
                local transform = normalize_transform({
                    enabled = true,
                    deform = false,
                    first_person = false,
                })

                raw_entries[#raw_entries + 1] = {
                    id = "raw_slot:" .. tostring(slot_name),
                    variant_key = slot_name,
                    item_name = item_name,
                    anchor = slot_name,
                    transform = transform,
                    transform_signature = transform_signature(transform),
                }
            end
        end
    end

    local physical_entries = {}
    local physical_by_anchor = {}
    local overlay_by_anchor = {}
    local ordinal_by_id = {}
    local ordered_ids = {}

    for id, anchor in pairs(anchors or {}) do
        if type(id) == "string" and string.match(id, "^extra_%d+$")
            and type(anchor) == "string" then
            ordered_ids[#ordered_ids + 1] = id
        end
    end

    table.sort(ordered_ids, function(left, right)
        return (tonumber(string.match(left, "(%d+)$")) or 0)
            < (tonumber(string.match(right, "(%d+)$")) or 0)
    end)

    local counts_by_anchor = {}

    for i = 1, #ordered_ids do
        local id = ordered_ids[i]
        local anchor = anchors[id]
        counts_by_anchor[anchor] = (counts_by_anchor[anchor] or 0) + 1
        ordinal_by_id[id] = counts_by_anchor[anchor]
    end

    for i = 1, #raw_entries do
        local entry = raw_entries[i]
        local item = type(mod.npclook_item_definition) == "function"
            and mod.npclook_item_definition(entry.item_name)
            or rawget(definitions, entry.item_name)
        local ordinal = ordinal_by_id[entry.id] or 1
        entry.attach_node = entry.transform.enabled and not entry.transform.deform
            and normalize_attach_node(entry.transform.attach_node)
            or anchor_attach_node(entry.anchor)
        entry.variant_state = RAW_UNITS.normalize_variant_state(
            type(variants) == "table" and variants[entry.variant_key or entry.id],
            entry.item_name
        )
        entry.variant_signature = RAW_UNITS.variant_signature(entry.variant_state)
        entry.opacity = normalize_opacity(type(opacity) == "table" and opacity[entry.variant_key or entry.id])

        if is_parent_material_item(entry.anchor, item) then
            local overlays = overlay_by_anchor[entry.anchor] or {}
            overlays[#overlays + 1] = {
                entry = entry,
                item = item,
                ordinal = ordinal,
            }
            overlay_by_anchor[entry.anchor] = overlays
        else
            entry.dependency_materials = {}
            physical_entries[#physical_entries + 1] = entry
            local entries = physical_by_anchor[entry.anchor] or {}
            entries[ordinal] = entry
            physical_by_anchor[entry.anchor] = entries
        end
    end

    local normal_dependencies = {}

    for slot_name, value in pairs(loadout or {}) do
        local item = loadout_item(value, definitions)

        if is_parent_material_item(slot_name, item) then
            local parents, forced = material_parent_slots(slot_name, item)
            normal_dependencies[#normal_dependencies + 1] = {
                slot_name = slot_name,
                item = item,
                parents = parents,
                forced = forced,
            }
        end
    end

    -- Slot-specific parent dependencies override broad authored dependencies.
    table.sort(normal_dependencies, function(left, right)
        if left.forced ~= right.forced then
            return left.forced == false
        end

        return left.slot_name < right.slot_name
    end)

    for i = 1, #physical_entries do
        local entry = physical_entries[i]
        local physical_item = rawget(definitions, entry.item_name)
        local seen = {}

        if not (physical_item and physical_item.npclook_raw_unit == true) then
            for j = 1, #normal_dependencies do
                local dependency = normal_dependencies[j]

                if parent_list_contains(dependency.parents, entry.anchor) then
                    append_item_overrides(entry.dependency_materials, seen, dependency.item)
                end
            end
        end
    end

    -- Pair dependency slots and visible extras by ordinal.
    for _, overlays in pairs(overlay_by_anchor) do
        for index = 1, #overlays do
            local overlay = overlays[index]
            local parents = material_parent_slots(overlay.entry.anchor, overlay.item)

            for parent_index = 1, #(parents or {}) do
                local parent_slot = parents[parent_index]
                local target = physical_by_anchor[parent_slot]
                    and physical_by_anchor[parent_slot][overlay.ordinal]

                if target then
                    local seen = {}

                    for existing_index = 1, #target.dependency_materials do
                        seen[target.dependency_materials[existing_index]] = true
                    end

                    append_item_overrides(target.dependency_materials, seen, overlay.item)

                    -- Inherit only material overrides from the paired dependency slot.
                    local target_transform = normalize_transform(target.transform)
                    local overlay_transform = normalize_transform(overlay.entry.transform)
                    local seen_materials = {}

                    for material_index = 1, #target_transform.materials do
                        seen_materials[target_transform.materials[material_index]] = true
                    end

                    for material_index = 1, #overlay_transform.materials do
                        local material = overlay_transform.materials[material_index]

                        if not seen_materials[material] then
                            seen_materials[material] = true
                            target_transform.materials[#target_transform.materials + 1] = material
                        end
                    end

                    target.transform = normalize_transform(target_transform)
                    target.transform_signature = transform_signature(target.transform, true)
                end
            end
        end
    end

    return physical_entries
end

local function remove_item_actors(item_unit)
    if not safe_unit_alive(item_unit) then
        return
    end

    for _, actor_name in ipairs({ "dynamic", "smart_tagging" }) do
        local ok_find, actor_id = pcall(Unit.find_actor, item_unit, actor_name)

        if ok_find and actor_id then
            pcall(Unit.destroy_actor, item_unit, actor_id)
        end
    end
end

local RUNTIME_CHILD_DATA_KEYS = {
    "attached_items",
    "attached_units",
    "child_units",
    "spawned_units",
}

local function runtime_child_units(unit)
    local children = {}
    local seen = {}

    if not safe_unit_alive(unit) then
        return children
    end

    local data_table_size = Unit.data_table_size
    local get_data = Unit.get_data

    if type(data_table_size) == "function" and type(get_data) == "function" then
        for key_index = 1, #RUNTIME_CHILD_DATA_KEYS do
            local key = RUNTIME_CHILD_DATA_KEYS[key_index]
            local ok_size, size = pcall(data_table_size, unit, key)

            if ok_size and type(size) == "number" then
                for index = 1, size do
                    local ok_child, child = pcall(get_data, unit, key, index)

                    if ok_child and safe_unit_alive(child) and not seen[child] then
                        seen[child] = true
                        children[#children + 1] = child
                    end
                end
            end
        end
    end

    local get_child_units = Unit.get_child_units

    if type(get_child_units) == "function" then
        local ok_children, linked_children = pcall(get_child_units, unit)

        if ok_children and type(linked_children) == "table" then
            for _, child in pairs(linked_children) do
                if safe_unit_alive(child) and not seen[child] then
                    seen[child] = true
                    children[#children + 1] = child
                end
            end
        end
    end

    return children
end

local function configure_first_person_render_hierarchy(root_unit, attachment_map, custom_fov)
    if not safe_unit_alive(root_unit) then
        return false
    end

    local seen = {}
    local units = {}

    local function visit(unit)
        if not safe_unit_alive(unit) or seen[unit] then
            return
        end

        seen[unit] = true
        units[#units + 1] = unit

        local mapped_children = type(attachment_map) == "table" and attachment_map[unit]

        for i = 1, #(mapped_children or {}) do
            visit(mapped_children[i])
        end

        for _, child in ipairs(runtime_child_units(unit)) do
            visit(child)
        end
    end

    visit(root_unit)

    for parent, children in pairs(attachment_map or {}) do
        visit(parent)

        if type(children) == "table" then
            for i = 1, #children do
                visit(children[i])
            end
        end
    end

    local lod_api = rawget(_G, "LODObject")
    local visibility_contexts = rawget(_G, "VisibilityContexts")
    local raytracing_context = visibility_contexts and visibility_contexts.RAYTRACING_CONTEXT

    for i = 1, #units do
        local unit = units[i]

        pcall(Unit.set_unit_culling, unit, false)

        if raytracing_context and type(Unit.set_unit_objects_visibility) == "function" then
            pcall(Unit.set_unit_objects_visibility, unit, false, true, raytracing_context)
        end

        if lod_api and type(lod_api.set_static_select) == "function" then
            for _, lod_name in ipairs({ "lod", "lod_shadow" }) do
                local ok_has, has_lod = pcall(Unit.has_lod_object, unit, lod_name)

                if ok_has and has_lod then
                    local ok_object, object = pcall(Unit.lod_object, unit, lod_name)

                    if ok_object and object then
                        pcall(lod_api.set_static_select, object, 0)
                    end
                end
            end
        end
    end

    if type(Unit.set_shader_pass_flag_for_meshes_in_unit_and_childs) == "function" then
        pcall(
            Unit.set_shader_pass_flag_for_meshes_in_unit_and_childs,
            root_unit,
            "custom_fov",
            custom_fov == true
        )
    end

    return true
end

local function child_unit_set(parent)
    local result = {}

    for _, child in ipairs(runtime_child_units(parent)) do
        result[child] = true
    end

    return result
end

local function world_unit_set(world)
    local result = {}
    local units_function = World and World.units

    if not world or type(units_function) ~= "function" then
        return result
    end

    local ok, units = pcall(units_function, world)

    if ok and type(units) == "table" then
        for _, unit in pairs(units) do
            if safe_unit_alive(unit) then
                result[unit] = true
            end
        end
    end

    return result
end

local function neutralize_unit_physics(unit, destroy_actors)
    if not safe_unit_alive(unit) then
        return
    end

    pcall(Unit.disable_physics, unit)

    local num_actors = Unit.num_actors
    local actor = Unit.actor

    if type(num_actors) ~= "function" or type(actor) ~= "function" then
        return
    end

    local ok_count, count = pcall(num_actors, unit)

    if not ok_count or type(count) ~= "number" then
        return
    end

    for actor_index = 1, count do
        local ok_actor, actor_instance = pcall(actor, unit, actor_index)

        if ok_actor and actor_instance then
            if Actor and type(Actor.set_collision_enabled) == "function" then
                pcall(Actor.set_collision_enabled, actor_instance, false)
            end

            if Actor and type(Actor.set_scene_query_enabled) == "function" then
                pcall(Actor.set_scene_query_enabled, actor_instance, false)
            end

            if destroy_actors and Actor and type(Actor.set_simulation_enabled) == "function" then
                pcall(Actor.set_simulation_enabled, actor_instance, false)
            end
        end
    end

    if destroy_actors and type(Unit.destroy_actor) == "function" then
        for actor_index = count, 1, -1 do
            pcall(Unit.destroy_actor, unit, actor_index)
        end
    end
end

local function collect_record_units(record)
    local ordered = {}
    local visited = {}
    local visiting = {}
    local attachment_maps = {
        record and record.attachment_map or {},
        record and record.pose_source_attachment_map or {},
        record and record.first_person_attachment_map or {},
        record and record.animated_first_person_attachment_map or {},
    }

    local function visit(unit)
        if not unit or visited[unit] or visiting[unit] then
            return
        end

        visiting[unit] = true

        for map_index = 1, #attachment_maps do
            local children = attachment_maps[map_index][unit]

            if type(children) == "table" then
                for child_index = #children, 1, -1 do
                    visit(children[child_index])
                end
            end
        end

        local runtime_children = runtime_child_units(unit)

        for child_index = #runtime_children, 1, -1 do
            visit(runtime_children[child_index])
        end

        visiting[unit] = nil
        visited[unit] = true
        ordered[#ordered + 1] = unit
    end

    for _, unit in ipairs(record and record.spawned_world_units or {}) do
        visit(unit)
    end

    for _, unit in ipairs(record and record.parent_spawned_units or {}) do
        visit(unit)
    end

    visit(record and record.first_person_root_unit)
    visit(record and record.animated_first_person_root_unit)
    visit(record and record.root_unit)
    visit(record and record.pose_source_unit)
    visit(record and record.animated_first_person_driver_unit)
    visit(record and record.driver_unit)

    for map_index = 1, #attachment_maps do
        for parent, children in pairs(attachment_maps[map_index]) do
            if type(children) == "table" then
                for child_index = #children, 1, -1 do
                    visit(children[child_index])
                end
            end

            visit(parent)
        end
    end

    return ordered
end


local function mark_owned_visual(unit, unit_spawner, parent_unit, owner_record)
    if not safe_unit_alive(unit) then
        return
    end

    owned_visual_units[unit] = true

    if unit_spawner then
        owned_visual_spawners[unit] = unit_spawner
    end

    local old_parent = owned_visual_parents[unit]

    if old_parent and old_parent ~= parent_unit then
        local old_children = owned_visual_children[old_parent]

        if old_children then
            old_children[unit] = nil
        end
    end

    if parent_unit then
        owned_visual_parents[unit] = parent_unit
        local children = owned_visual_children[parent_unit]

        if not children then
            children = setmetatable({}, { __mode = "k" })
            owned_visual_children[parent_unit] = children
        end

        children[unit] = true
    end

    if owner_record then
        owned_visual_records[unit] = owner_record
    end
end

local function collect_world_spawn_delta(world, baseline, unit_spawner)
    local result = {}

    if type(baseline) ~= "table" then
        return result
    end

    local current = world_unit_set(world)

    for unit in pairs(current) do
        if not (baseline and baseline[unit]) then
            result[#result + 1] = unit
            mark_owned_visual(unit, unit_spawner)
        end
    end

    return result
end

local function collect_new_parent_children(parent, baseline, result, seen, unit_spawner)
    if not safe_unit_alive(parent) then
        return false
    end

    baseline = baseline or {}
    result = result or {}
    seen = seen or {}
    local changed = false

    for _, child in ipairs(runtime_child_units(parent)) do
        if not baseline[child] and not seen[child] and safe_unit_alive(child) then
            seen[child] = true
            result[#result + 1] = child
            mark_owned_visual(child, unit_spawner, parent)
            changed = true
        end
    end

    return changed
end

local function capture_record_parent_children(record)
    if not record then
        return false
    end

    record.parent_spawned_units = record.parent_spawned_units or {}
    record.parent_spawned_seen = record.parent_spawned_seen or {}
    local changed = false

    changed = collect_new_parent_children(
        record.parent_unit,
        record.parent_child_baseline,
        record.parent_spawned_units,
        record.parent_spawned_seen,
        record.unit_spawner
    ) or changed
    changed = collect_new_parent_children(
        record.first_person_parent_unit,
        record.first_person_child_baseline,
        record.parent_spawned_units,
        record.parent_spawned_seen,
        record.unit_spawner
    ) or changed

    return changed
end

local function is_owned_visual(unit)
    return owned_visual_units[unit] == true
end

local function new_physics_tracker(record)
    local tracker = {
        record = record,
        units = {},
        seen = {},
        age_frames = 0,
        next_check_index = 1,
        maintenance_required = record and record.raw_unit == true,
    }

    local initial_units = collect_record_units(record)

    for i = 1, #initial_units do
        local unit = initial_units[i]

        if safe_unit_alive(unit) and not tracker.seen[unit] then
            local parent_unit

            if unit == record.root_unit or unit == record.pose_source_unit
                or unit == record.driver_unit
                or unit == record.animated_first_person_driver_unit then
                parent_unit = record.parent_unit
            elseif unit == record.first_person_root_unit then
                parent_unit = record.first_person_parent_unit
            elseif unit == record.animated_first_person_root_unit then
                parent_unit = record.animated_first_person_driver_unit or record.driver_unit
            end

            mark_owned_visual(unit, record.unit_spawner, parent_unit, record)
            tracker.seen[unit] = true
            tracker.units[#tracker.units + 1] = unit
        end
    end

    return tracker
end

local function run_physics_tracker(tracker)
    local record = tracker and tracker.record

    if not record then
        return false, true
    end

    local target_frame = RAW_PHYSICS_CHECK_FRAMES[tracker.next_check_index]

    if target_frame == nil then
        return false, true
    elseif tracker.age_frames < target_frame then
        return false, false
    end

    local changed = false
    local current_units = collect_record_units(record)

    for i = 1, #current_units do
        local unit = current_units[i]

        if safe_unit_alive(unit) and not tracker.seen[unit] then
            mark_owned_visual(unit, record.unit_spawner, owned_visual_parents[unit], record)
            tracker.seen[unit] = true
            tracker.units[#tracker.units + 1] = unit
            changed = true
        end
    end

    local index = 1

    while index <= #tracker.units do
        local unit = tracker.units[index]

        if safe_unit_alive(unit) then
            neutralize_unit_physics(unit, record.raw_unit == true)

            local children = runtime_child_units(unit)

            for child_index = 1, #children do
                local child = children[child_index]

                if safe_unit_alive(child) and not tracker.seen[child] then
                    mark_owned_visual(child, record.unit_spawner, unit, record)
                    tracker.seen[child] = true
                    tracker.units[#tracker.units + 1] = child
                    changed = true
                end
            end
        end

        index = index + 1
    end

    if record.variant_item then
        RAW_UNITS.apply_variants(
            record.variant_item,
            record.root_unit,
            record.attachment_map,
            record.variant_state
        )
        RAW_UNITS.apply_variants(
            record.variant_item,
            record.first_person_root_unit,
            record.first_person_attachment_map,
            record.variant_state
        )
        RAW_UNITS.apply_variants(
            record.variant_item,
            record.animated_first_person_root_unit,
            record.animated_first_person_attachment_map,
            record.variant_state
        )
    end

    tracker.next_check_index = tracker.next_check_index + 1

    return changed, RAW_PHYSICS_CHECK_FRAMES[tracker.next_check_index] == nil
end

local function maintain_physics_tracker(tracker)
    local record = tracker and tracker.record

    if not record then
        return false
    end

    local changed = false
    local current_units = collect_record_units(record)

    for i = 1, #current_units do
        local unit = current_units[i]

        if safe_unit_alive(unit) and not tracker.seen[unit] then
            mark_owned_visual(unit, record.unit_spawner, owned_visual_parents[unit], record)
            tracker.seen[unit] = true
            tracker.units[#tracker.units + 1] = unit
            changed = true
        end
    end

    local index = 1

    while index <= #tracker.units do
        local unit = tracker.units[index]

        if safe_unit_alive(unit) then
            neutralize_unit_physics(unit, record.raw_unit == true)

            for _, child in ipairs(runtime_child_units(unit)) do
                if safe_unit_alive(child) and not tracker.seen[child] then
                    mark_owned_visual(child, record.unit_spawner, unit, record)
                    tracker.seen[child] = true
                    tracker.units[#tracker.units + 1] = child
                    changed = true
                end
            end
        end

        index = index + 1
    end

    if record.variant_item then
        RAW_UNITS.apply_variants(
            record.variant_item,
            record.root_unit,
            record.attachment_map,
            record.variant_state
        )
        RAW_UNITS.apply_variants(
            record.variant_item,
            record.first_person_root_unit,
            record.first_person_attachment_map,
            record.variant_state
        )
        RAW_UNITS.apply_variants(
            record.variant_item,
            record.animated_first_person_root_unit,
            record.animated_first_person_attachment_map,
            record.variant_state
        )
    end

    return changed
end

local function neutralize_record_physics(record)
    local tracker = new_physics_tracker(record)
    run_physics_tracker(tracker)

    return tracker
end

local function unlink_unit_all(world, unit)
    if not world or not safe_unit_alive(unit) then
        return
    end

    -- Some component units are linked more than once.
    for _ = 1, 256 do
        pcall(World.unlink_unit, world, unit)
    end
end

local function schedule_unit_deletion(unit_spawner, unit)
    if not unit_spawner or not safe_unit_alive(unit) or deletion_pending[unit] then
        return false
    end

    local mark_for_deletion = unit_spawner.mark_for_deletion

    if type(mark_for_deletion) ~= "function" then
        return false
    end

    deletion_pending[unit] = "scheduling"

    local ok = pcall(mark_for_deletion, unit_spawner, unit)

    if ok then
        deletion_pending[unit] = "queued"
    else
        deletion_pending[unit] = nil
    end

    return ok
end

local function collect_update_units(record)
    local ordered = {}
    local seen = {}

    local function append(unit)
        if unit and not seen[unit] then
            seen[unit] = true
            ordered[#ordered + 1] = unit
        end
    end

    local function append_hierarchy(root_unit, attachment_map)
        append(root_unit)

        local root_attachments = root_unit and attachment_map[root_unit]

        if type(root_attachments) == "table" then
            for i = 1, #root_attachments do
                append(root_attachments[i])
            end
        end

        for parent, children in pairs(attachment_map) do
            append(parent)

            if type(children) == "table" then
                for i = 1, #children do
                    append(children[i])
                end
            end
        end

        local runtime_children = runtime_child_units(root_unit)

        for i = 1, #runtime_children do
            append(runtime_children[i])
        end
    end

    for _, unit in ipairs(record and record.parent_spawned_units or {}) do
        append(unit)
    end

    -- Update linked parents before children.
    append_hierarchy(record and record.root_unit, record and record.attachment_map or {})
    append_hierarchy(
        record and record.first_person_root_unit,
        record and record.first_person_attachment_map or {}
    )
    append_hierarchy(
        record and record.animated_first_person_root_unit,
        record and record.animated_first_person_attachment_map or {}
    )
    append(record and record.animated_first_person_driver_unit)
    append(record and record.driver_unit)

    return ordered
end

local function stabilize_transformed_visibility(record)
    if not record then
        return false
    elseif not record.transform_enabled
        and not record.uses_deformation_driver
        and not record.uses_studio_deformation_mirror then
        record.visibility_stabilized = true
        record.update_units = record.update_units or collect_update_units(record)
        return true
    elseif not record.transform_enabled then
        record.visibility_stabilized = true
        record.update_units = collect_update_units(record)
        return true
    end

    local units = collect_record_units(record)
    local lod_api = rawget(_G, "LODObject")

    -- Transformed units need culling disabled and a fixed highest LOD.
    for i = 1, #units do
        local unit = units[i]

        if safe_unit_alive(unit) then
            pcall(Unit.set_unit_culling, unit, false)

            if not record.raw_unit and lod_api and type(lod_api.set_static_select) == "function" then
                for _, lod_name in ipairs({ "lod", "lod_shadow" }) do
                    local ok_has, has_lod = pcall(Unit.has_lod_object, unit, lod_name)

                    if ok_has and has_lod then
                        local ok_object, object = pcall(Unit.lod_object, unit, lod_name)

                        if ok_object and object then
                            pcall(lod_api.set_static_select, object, 0)
                        end
                    end
                end
            end
        end
    end

    record.visibility_stabilized = true
    record.update_units = collect_update_units(record)

    return true
end

local function destroy_ordered_units(units, unit_spawner, world)
    local mark_for_deletion = unit_spawner and unit_spawner.mark_for_deletion

    for i = 1, #(units or {}) do
        local unit = units[i]

        if safe_unit_alive(unit) then
            pcall(Unit.flow_event, unit, "lua_hidden")
            pcall(Unit.set_unit_visibility, unit, false, true)
            neutralize_unit_physics(unit, true)
            unlink_unit_all(world or safe_unit_world(unit), unit)
        end
    end

    for i = 1, #(units or {}) do
        local unit = units[i]
        local already_pending = deletion_pending[unit] ~= nil
        local scheduled = type(mark_for_deletion) == "function"
            and schedule_unit_deletion(unit_spawner, unit)

        if not already_pending and not scheduled then
            local unit_world = world or safe_unit_world(unit)

            if unit_world and safe_unit_alive(unit) then
                pcall(Unit.flow_event, unit, "cleanup_before_destroy")
                pcall(World.destroy_unit, unit_world, unit)
            end
        end

        local parent_unit = owned_visual_parents[unit]
        local siblings = parent_unit and owned_visual_children[parent_unit]

        if siblings then
            siblings[unit] = nil
        end

        owned_visual_children[unit] = nil
        owned_visual_units[unit] = nil
        owned_visual_spawners[unit] = nil
        owned_visual_parents[unit] = nil
        owned_visual_records[unit] = nil
    end
end

local function flush_unit_spawner(unit_spawner)
    local flush = unit_spawner and (unit_spawner.commit_and_remove_pending_units
        or unit_spawner.remove_pending_units)

    if type(flush) == "function" then
        pcall(flush, unit_spawner)
    end
end

local function destroy_parent_spawn_delta(context, parent_baseline, first_person_baseline, package_record)
    if not context then
        return
    end

    local units = {}
    local seen = {}

    collect_new_parent_children(
        context.parent_unit,
        parent_baseline,
        units,
        seen,
        context.unit_spawner
    )
    collect_new_parent_children(
        context.first_person_unit,
        first_person_baseline,
        units,
        seen,
        context.unit_spawner
    )

    if #units > 0 then
        extend_package_release_guard(package_record, units)
        destroy_ordered_units(units, context.unit_spawner, context.world)
        flush_unit_spawner(context.unit_spawner)
    end
end

local function active_context_units(context)
    local active = {}

    for _, record in pairs(context and context.records or {}) do
        for _, unit in ipairs(collect_record_units(record)) do
            active[unit] = true
        end
    end

    return active
end

local function sweep_context_owned_children(context)
    if not context then
        return 0
    end

    local active = active_context_units(context)
    local destroyed = 0
    local visited = {}
    local roots = { context.parent_unit, context.first_person_unit }

    local function scan(parent)
        if visited[parent] or not safe_unit_alive(parent) then
            return
        end

        visited[parent] = true
        local children = runtime_child_units(parent)

        for i = 1, #children do
            local child = children[i]

            if not visited[child] and safe_unit_alive(child) then
                if not active[child] and (is_owned_visual(child)) then
                    destroyed = destroyed + 1
                    destroy_ordered_units({ child }, context.unit_spawner or owned_visual_spawners[child], context.world)
                else
                    scan(child)
                end
            end
        end
    end

    for i = 1, #roots do
        scan(roots[i])
    end

    if destroyed > 0 then
        flush_unit_spawner(context.unit_spawner)
    end

    return destroyed
end

local function destroy_units(record)
    if not record then
        return
    end

    local units = collect_record_units(record)
    local package_record = record.package_record

    if type(package_record) == "table" and #units > 0 then
        extend_package_release_guard(package_record, units)
    end

    for i = 1, #units do
        if owned_visual_records[units[i]] == record then
            owned_visual_records[units[i]] = nil
        end
    end

    destroy_ordered_units(units, record.unit_spawner, record.world)

    record.root_unit = nil
    record.first_person_root_unit = nil
    record.first_person_attachment_map = nil
    record.first_person_item_name_by_unit = nil
    record.first_person_root_baseline = nil
    record.first_person_attach_node = nil
    record.first_person_pending = nil
    record.first_person_retry_elapsed = nil
    record.first_person_retry_count = nil
    record.first_person_error = nil
    record.first_person_material_entries = nil
    record.first_person_retry_exhausted = nil
    record.first_person_error_reported = nil
    record.animated_first_person_root_unit = nil
    record.animated_first_person_attachment_map = nil
    record.animated_first_person_item_name_by_unit = nil
    record.animated_first_person_root_baseline = nil
    record.animated_first_person_driver_unit = nil
    record.animated_first_person_driver_node_pairs = nil
    record.animated_first_person_driver_transform = nil
    record.animated_first_person_driver_runtime_transform = nil
    record.animated_first_person_update_units = nil
    record.animated_first_person_driver_required = nil
    record.animated_first_person_pose_failure_count = nil
    record.animated_first_person_rebuild_pending = nil
    record.driver_unit = nil
    record.deformation_driver_fallback = nil
    record.driver_node_pairs = nil
    record.pose_source_unit = nil
    record.pose_source_attachment_map = nil
    record.pose_source_world_nodes = nil
    record.studio_mirror_fallback_pending = nil
    record.root_baseline = nil
    record.attachment_map = nil
    record.item_name_by_unit = nil
    record.variant_item = nil
    record.variant_state = nil
    record.update_units = nil
    record.visibility_stabilized = nil
    record.pose_failure_count = nil
    record.pose_failed = nil
    record.physics_tracker = nil
    record.runtime_transform = nil
    record.spawned_world_units = nil
    record.parent_spawned_units = nil
    record.parent_spawned_seen = nil
    record.parent_child_baseline = nil
    record.first_person_child_baseline = nil
    record.first_person_parent_unit = nil

    return units
end

local function track_record_deletion_roots(record)
    for _, unit in pairs({
        record and record.root_unit,
        record and record.first_person_root_unit,
        record and record.animated_first_person_root_unit,
        record and record.pose_source_unit,
        record and record.animated_first_person_driver_unit,
        record and record.driver_unit,
    }) do
        if safe_unit_alive(unit) then
            managed_deletion_roots[unit] = true
        end
    end
end

local function remove_extra_slot(context, id, delay)
    local record = context.records[id]

    if record then
        destroy_units(record)
        context.records[id] = nil
        queue_package_release(context, record.package_record, delay)
    end

    retire_pending_package(context, id, delay)
end

local function configure_context(context, parent_unit, settings)
    local world = settings and settings.world
    local unit_spawner = settings and settings.unit_spawner
    local item_definitions = settings and settings.item_definitions
    local changed = context.parent_unit ~= parent_unit
        or context.world ~= world
        or context.unit_spawner ~= unit_spawner
        or context.item_definitions ~= item_definitions
        or context.breed_name ~= (settings and settings.breed_name)
        or context.driver_base_unit ~= (settings and settings.driver_base_unit)
        or context.first_person_unit ~= (settings and settings.first_person_unit)
        or context.first_person_extension ~= (settings and settings.first_person_extension)
        or context.mission ~= (settings and settings.mission)

    if changed and (next(context.records) or next(context.pending)) then
        local ids = table.keys(context.records)

        for i = 1, #ids do
            remove_extra_slot(context, ids[i], 0)
        end

        local pending_ids = table.keys(context.pending)

        for i = 1, #pending_ids do
            retire_pending_package(context, pending_ids[i], 0)
        end
    end

    if context.parent_unit ~= parent_unit then
        unregister_context_parent(context.owner, context)
    end

    context.parent_unit = parent_unit
    register_context_parent(context.owner, context)
    context.world = world
    context.unit_spawner = unit_spawner
    context.item_definitions = item_definitions
    context.mission = settings and settings.mission
    context.breed_name = settings and settings.breed_name
    context.from_ui_profile_spawner = settings and settings.from_ui_profile_spawner == true
    context.force_highest_lod_step = settings and settings.force_highest_lod_step == true
    context.first_person_unit = settings and settings.first_person_unit
    context.first_person_extension = settings and settings.first_person_extension
    context.driver_base_unit = settings and settings.driver_base_unit
    context.context_label = settings and settings.context_label
        or (context.is_live and "live" or context.context_label)
    context.variants = settings and settings.variants or context.variants
end

local function attach_settings(context, parent_override)
    local attachment_parent = parent_override or context.parent_unit
    local owner_unit = context.parent_unit
    local unit_spawner = context.unit_spawner

    return {
        from_script_component = unit_spawner == nil,
        from_ui_profile_spawner = context.from_ui_profile_spawner,
        item_definitions = context.item_definitions or item_cache(),
        unit_spawner = unit_spawner,
        world = context.world,
        character_unit = attachment_parent,
        owner_unit = owner_unit,
        in_editor = false,
        is_first_person = false,
        is_minion = false,
        breed_name = context.breed_name,
        lod_group = safe_lod_group(owner_unit, "lod"),
        lod_shadow_group = safe_lod_group(owner_unit, "lod_shadow"),
        force_highest_lod_step = context.force_highest_lod_step,
    }
end

local function hide_driver_unit(unit)
    pcall(Unit.set_unit_visibility, unit, false, false)
    pcall(Unit.disable_physics, unit)
    pcall(Unit.disable_animation_state_machine, unit)

    local ok_meshes, mesh_count = pcall(Unit.num_meshes, unit)

    if ok_meshes and type(mesh_count) == "number" then
        -- Stingray mesh indices are one-based.
        for mesh_index = 1, mesh_count do
            pcall(Unit.set_mesh_visibility, unit, mesh_index, false)
        end
    end
end

local function hide_pose_source_hierarchy(root_unit, attachment_map)
    local seen = {}

    local function hide(unit)
        if not safe_unit_alive(unit) or seen[unit] then
            return
        end

        seen[unit] = true
        remove_item_actors(unit)
        pcall(Unit.set_unit_culling, unit, false)

        local ok_meshes, mesh_count = pcall(Unit.num_meshes, unit)

        if ok_meshes and type(mesh_count) == "number" then
            for mesh_index = 1, mesh_count do
                pcall(Unit.set_mesh_visibility, unit, mesh_index, false)
            end
        end
    end

    hide(root_unit)

    for parent, children in pairs(attachment_map or {}) do
        hide(parent)

        if type(children) == "table" then
            for i = 1, #children do
                hide(children[i])
            end
        end
    end
end

local function build_driver_node_pairs(driver, parent)
    local pairs = {}
    local ok_driver_count, driver_count = pcall(Unit.num_scene_graph_items, driver)
    local ok_parent_count, parent_count = pcall(Unit.num_scene_graph_items, parent)

    -- Matching breed units can copy scene-graph nodes by index only when their
    -- parent topology also matches. Equal node counts alone are not sufficient.
    if ok_driver_count and ok_parent_count
        and type(driver_count) == "number" and type(parent_count) == "number"
        and driver_count == parent_count and driver_count > 1 then
        for node = 2, driver_count do
            local ok_driver_parent, driver_parent = pcall(
                Unit.scene_graph_parent,
                driver,
                node
            )
            local ok_character_parent, character_parent = pcall(
                Unit.scene_graph_parent,
                parent,
                node
            )

            if not ok_driver_parent or not ok_character_parent
                or type(driver_parent) ~= "number"
                or type(character_parent) ~= "number"
                or driver_parent ~= character_parent then
                return nil
            end

            pairs[#pairs + 1] = {
                driver = node,
                parent = node,
            }
        end

        return pairs
    end

    -- A mismatched breed layout is not safe to inspect or copy at runtime.
    -- Let the caller reject the driver and use the normal visual fallback.
    return nil
end

local function apply_driver_root(record)
    local driver = record and record.driver_unit
    local parent = record and record.parent_unit
    local transform = record and record.transform or normalize_transform(nil)
    local prepared = record.runtime_transform or runtime_transform(transform)
    record.runtime_transform = prepared

    if not safe_unit_alive(driver) or not safe_unit_alive(parent) then
        return false
    end

    local ok_position, parent_position = pcall(Unit.world_position, parent, 1)
    local ok_rotation, parent_rotation = pcall(Unit.world_rotation, parent, 1)
    local ok_scale, parent_scale = pcall(Unit.world_scale, parent, 1)

    if not ok_position or not ok_rotation or not ok_scale
        or not parent_position or not parent_rotation or not parent_scale then
        return false
    end

    local local_offset = Vector3(
        prepared.offset_x * parent_scale.x,
        prepared.offset_y * parent_scale.y,
        prepared.offset_z * parent_scale.z
    )
    local ok_offset, world_offset = pcall(Quaternion.rotate, parent_rotation, local_offset)

    if not ok_offset or not world_offset then
        return false
    end

    local world_rotation = Quaternion.multiply(
        parent_rotation,
        QuaternionBox.unbox(prepared.rotation)
    )
    local world_scale = Vector3(
        parent_scale.x * prepared.scale_x,
        parent_scale.y * prepared.scale_y,
        parent_scale.z * prepared.scale_z
    )

    local ok_root = pcall(function()
        -- Keep the driver root independent while copying the animated child pose.
        Unit.set_local_position(driver, 1, parent_position + world_offset)
        Unit.set_local_rotation(driver, 1, world_rotation)
        Unit.set_local_scale(driver, 1, world_scale)
    end)

    return ok_root
end

local function copy_driver_nodes(record)
    local driver = record and record.driver_unit
    local parent = record and record.parent_unit

    if not safe_unit_alive(driver) or not safe_unit_alive(parent) then
        return false
    end

    local pairs = record.driver_node_pairs

    -- Topology is discovered only during spawn, never from the render hook.
    if type(pairs) ~= "table" or #pairs == 0 then
        return false
    end

    local ok_copy = pcall(function()
        for i = 1, #pairs do
            local pair = pairs[i]
            Unit.set_local_pose(driver, pair.driver, Unit.local_pose(parent, pair.parent))
        end
    end)

    return ok_copy
end

local function update_record_units(record, primary_unit)
    local world = record and record.world

    if not world or not safe_unit_alive(primary_unit) then
        return false
    end

    local ok_primary_update = pcall(World.update_unit, world, primary_unit)

    if not ok_primary_update then
        return false
    end

    -- Refresh the full cosmetic hierarchy after changing its pose.
    local linked_units = record.update_units or { primary_unit }

    for i = 1, #linked_units do
        local unit = linked_units[i]

        if unit ~= primary_unit and safe_unit_alive(unit) then
            pcall(World.update_unit, world, unit)
        end
    end

    return true
end

local function relative_transform(parent_position, parent_rotation, parent_scale,
        child_position, child_rotation, child_scale)
    local inverse_parent_rotation = Quaternion.inverse(parent_rotation)

    return divided_vector(
            Quaternion.rotate(inverse_parent_rotation, child_position - parent_position),
            parent_scale
        ),
        Quaternion.multiply(inverse_parent_rotation, child_rotation),
        divided_vector(child_scale, parent_scale)
end

local function composed_transform(parent_position, parent_rotation, parent_scale,
        local_position, local_rotation, local_scale)
    return parent_position + Quaternion.rotate(
            parent_rotation,
            multiplied_vector(parent_scale, local_position)
        ),
        Quaternion.multiply(parent_rotation, local_rotation),
        multiplied_vector(parent_scale, local_scale)
end

local function studio_mirror_root_values(record)
    local visible = record and record.root_unit
    local source = record and record.pose_source_unit
    local parent = record and record.parent_unit
    local transform = record and record.transform or normalize_transform(nil)
    local prepared = record.runtime_transform or runtime_transform(transform)
    record.runtime_transform = prepared

    if not safe_unit_alive(visible) or not safe_unit_alive(source)
        or not safe_unit_alive(parent) then
        return nil
    end

    local ok_values, parent_position, parent_rotation, parent_scale,
        source_position, source_rotation, source_scale = pcall(function()
        return Unit.world_position(parent, 1),
            Unit.world_rotation(parent, 1),
            Unit.world_scale(parent, 1),
            Unit.world_position(source, 1),
            Unit.world_rotation(source, 1),
            Unit.world_scale(source, 1)
    end)

    if not ok_values or not parent_position or not parent_rotation or not parent_scale
        or not source_position or not source_rotation or not source_scale then
        return nil
    end

    local ok_root, world_position, world_rotation, world_scale = pcall(function()
        local source_local_position, source_local_rotation, source_local_scale =
            relative_transform(
                parent_position,
                parent_rotation,
                parent_scale,
                source_position,
                source_rotation,
                source_scale
            )
        local custom_rotation = QuaternionBox.unbox(prepared.rotation)
        local custom_scale = Vector3(prepared.scale_x, prepared.scale_y, prepared.scale_z)
        local custom_offset = Vector3(
            prepared.offset_x,
            prepared.offset_y,
            prepared.offset_z
        )
        local transformed_local_position = custom_offset + Quaternion.rotate(
            custom_rotation,
            multiplied_vector(source_local_position, custom_scale)
        )
        local transformed_local_rotation = Quaternion.multiply(
            custom_rotation,
            source_local_rotation
        )
        local transformed_local_scale = multiplied_vector(source_local_scale, custom_scale)

        return composed_transform(
            parent_position,
            parent_rotation,
            parent_scale,
            transformed_local_position,
            transformed_local_rotation,
            transformed_local_scale
        )
    end)

    if not ok_root then
        return nil
    end

    return world_position, world_rotation, world_scale,
        source_position, source_rotation, source_scale
end

local function scene_graph_depth(unit, node, cache, visiting)
    if node == 1 then
        return 0
    elseif cache[node] ~= nil then
        return cache[node]
    elseif visiting[node] then
        return nil
    end

    visiting[node] = true

    local ok_parent, parent = pcall(Unit.scene_graph_parent, unit, node)

    if not ok_parent or type(parent) ~= "number" or parent < 1 then
        visiting[node] = nil
        return nil
    end

    local parent_depth = scene_graph_depth(unit, parent, cache, visiting)

    visiting[node] = nil

    if parent_depth == nil then
        return nil
    end

    cache[node] = parent_depth + 1

    return cache[node]
end

local function build_studio_mirror_nodes(destination, source)
    local ok_destination_count, destination_count = pcall(Unit.num_scene_graph_items, destination)
    local ok_source_count, source_count = pcall(Unit.num_scene_graph_items, source)

    -- Require matching scene-graph layouts for source and visible copies.
    if not ok_destination_count or not ok_source_count
        or type(destination_count) ~= "number" or type(source_count) ~= "number"
        or destination_count ~= source_count or destination_count <= 1 then
        return nil
    end

    local nodes = {}
    local depth_cache = { [1] = 0 }

    for node = 2, destination_count do
        local ok_parent, parent = pcall(Unit.scene_graph_parent, destination, node)
        local depth = ok_parent and type(parent) == "number"
            and scene_graph_depth(destination, node, depth_cache, {}) or nil

        if not depth then
            return nil
        end

        nodes[#nodes + 1] = {
            destination = node,
            source = node,
            parent = parent,
            depth = depth,
        }
    end

    table.sort(nodes, function(left, right)
        if left.depth == right.depth then
            return left.destination < right.destination
        end

        return left.depth < right.depth
    end)

    return nodes
end

local function apply_studio_mirror_pose(record)
    local world = record and record.world
    local visible = record and record.root_unit
    local source = record and record.pose_source_unit

    if not world or not safe_unit_alive(visible) or not safe_unit_alive(source) then
        return false
    end

    -- The hidden linked source contains the body's evaluated deformation in its
    -- world-space scene graph. Preserve that full affine pose instead of
    -- decomposing every node into position/rotation/scale, which loses shear
    -- under non-uniform XYZ scaling and can visibly shorten rotated chains.
    if not pcall(World.update_unit, world, source) then
        return false
    end

    local root_position, root_rotation, root_scale = studio_mirror_root_values(record)

    if not root_position or not root_rotation or not root_scale then
        return false
    end

    local nodes = record.pose_source_world_nodes

    -- Scene-graph topology is cached during spawn. Never query it from render.
    if type(nodes) ~= "table" or #nodes == 0 then
        return false
    end

    local ok_pose = pcall(function()
        local source_root_pose = Unit.world_pose(source, 1)
        local source_root_inverse = Matrix4x4.inverse(source_root_pose)
        local root_world_pose = Matrix4x4.from_quaternion_position_scale(
            root_rotation,
            root_position,
            root_scale
        )
        local desired_world = {
            [1] = root_world_pose,
        }

        Unit.set_local_pose(visible, 1, root_world_pose)

        for i = 1, #nodes do
            local node = nodes[i]
            local parent_world_pose = desired_world[node.parent]

            if not parent_world_pose then
                error("Missing visible scene-graph parent pose")
            end

            -- Stingray uses child_world * inverse(parent_world) for a local
            -- scene-graph pose. First express the evaluated source node relative
            -- to the source root, then place that complete affine transform under
            -- the edited visible root. This retains deformation and shear.
            local source_world_pose = Unit.world_pose(source, node.source)
            local source_relative_pose = Matrix4x4.multiply(
                source_world_pose,
                source_root_inverse
            )
            local node_world_pose = Matrix4x4.multiply(
                source_relative_pose,
                root_world_pose
            )
            local parent_world_inverse = Matrix4x4.inverse(parent_world_pose)
            local local_pose = Matrix4x4.multiply(
                node_world_pose,
                parent_world_inverse
            )

            Unit.set_local_pose(visible, node.destination, local_pose)
            desired_world[node.destination] = node_world_pose
        end
    end)

    if not ok_pose then
        return false
    end

    return update_record_units(record, visible)
end

local function apply_linked_root_pose(record)
    local root = record and record.root_unit

    if not safe_unit_alive(root) then
        return false, "root_dead"
    end

    local ok_transform, transform_or_error = pcall(
        apply_transform,
        root,
        record.transform,
        record.root_baseline,
        true
    )

    if not ok_transform then
        return false, "transform", tostring(transform_or_error)
    end

    if not update_record_units(record, root) then
        return false, "update_units"
    end

    return true
end

local function fallback_studio_mirror_pose(record, transform)
    if not record or not safe_unit_alive(record.root_unit) then
        return false
    end

    destroy_units({
        world = record.world,
        unit_spawner = record.unit_spawner,
        package_record = record.package_record,
        pose_source_unit = record.pose_source_unit,
        pose_source_attachment_map = record.pose_source_attachment_map,
    })
    record.pose_source_unit = nil
    record.pose_source_attachment_map = {}
    record.pose_source_world_nodes = nil
    record.uses_studio_deformation_mirror = false
    record.studio_mirror_fallback = true
    record.transform = normalize_transform(transform or record.transform)
    record.runtime_transform = runtime_transform(record.transform)

    pcall(World.update_unit, record.world, record.root_unit)
    record.root_baseline = record.root_baseline or capture_root_baseline(record.root_unit)

    if not record.root_baseline then
        return false
    end

    return apply_linked_root_pose(record)
end

local function apply_driver_pose(record)
    local driver = record and record.driver_unit
    local parent = record and record.parent_unit

    if not safe_unit_alive(driver) or not safe_unit_alive(parent) then
        return false
    end

    -- Copy non-root animation before applying the independent root.
    if not copy_driver_nodes(record) or not apply_driver_root(record) then
        return false
    end

    return update_record_units(record, driver)
end

local function spawn_transform_driver(context, transform, package_record)
    local parent = context.parent_unit
    local breed = context.breed_name and Breeds[context.breed_name]
    local candidates = {}
    local seen = {}

    local function append_candidate(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            candidates[#candidates + 1] = value
        end
    end

    append_candidate(context.driver_base_unit)
    append_candidate(breed and breed.base_unit)

    if #candidates == 0 then
        return nil
    end

    local world = context.world
    local unit_spawner = context.unit_spawner
    local ok_pose, pose = pcall(Unit.world_pose, parent, 1)

    if not ok_pose or not pose then
        return nil
    end

    for i = 1, #candidates do
        local base_unit = candidates[i]
        local ok_spawn, driver

        if unit_spawner and type(unit_spawner.spawn_unit) == "function" then
            ok_spawn, driver = pcall(unit_spawner.spawn_unit, unit_spawner, base_unit, pose)
        elseif world then
            ok_spawn, driver = pcall(World.spawn_unit_ex, world, base_unit, nil, pose)
        end

        if ok_spawn and safe_unit_alive(driver) then
            hide_driver_unit(driver)

            local temporary_record = {
                driver_unit = driver,
                parent_unit = parent,
                world = world,
                transform = normalize_transform(transform),
                driver_node_pairs = build_driver_node_pairs(driver, parent),
            }

            if apply_driver_pose(temporary_record) then
                return driver, temporary_record.driver_node_pairs
            end

            destroy_units({
                world = world,
                unit_spawner = unit_spawner,
                package_record = package_record,
                driver_unit = driver,
            })
        end
    end

    return nil
end

local function spawn_item_instance(item, settings, parent, mission)
    local ok_spawn, item_unit, attachment_units, _, _, _, _, item_name_by_unit = pcall(
        VisualLoadoutCustomization.spawn_item,
        item,
        settings,
        parent,
        true,
        false,
        true,
        mission,
        nil
    )

    if not ok_spawn then
        return nil, nil, nil, tostring(item_unit)
    elseif not item_unit then
        return nil, nil, nil, "no unit was spawned"
    end

    return item_unit, attachment_units or {}, item_name_by_unit or {}, nil
end

local function visual_apply_error(stage, reason)
    local detail = type(reason) == "string" and reason ~= ""
        and reason or loc("generic_unknown_error")

    return loc("error_visual_apply", string.format("%s: %s", tostring(stage), detail))
end

local function apply_material_entries_to_visual(
        context,
        settings,
        entry,
        item,
        item_unit,
        attachment_units,
        item_name_by_unit,
        material_entries,
        label_suffix)
    if not safe_unit_alive(item_unit) or #material_entries == 0 then
        return
    end

    local material_units = collect_material_units({ item_unit }, { attachment_units or {} })

    apply_material_entries_to_units(
        material_units,
        context.parent_unit,
        false,
        material_entries,
        false,
        settings.item_definitions,
        nil,
        "extra slot " .. tostring(entry.id or item.name or "unknown") .. tostring(label_suffix or ""),
        item_name_by_unit or {}
    )
end

local function first_person_item_graph(
        item,
        item_definitions,
        breed_name,
        attach_node,
        preserve_native_root_link)
    local source_definitions = type(item_definitions) == "table" and item_definitions or {}
    local overlay_definitions = {}
    local cloned_items = setmetatable({}, { __mode = "k" })
    local cloned_attachment_tables = setmetatable({}, { __mode = "k" })
    local prepare_item

    local function clone_attachment_tree(value)
        if type(value) ~= "table" then
            return value
        end

        local existing = cloned_attachment_tables[value]

        if existing then
            return existing
        end

        local result = {}
        cloned_attachment_tables[value] = result

        for key, child in pairs(value) do
            if key == "item" and type(child) == "table" then
                result[key] = prepare_item(child, false)
            elseif type(child) == "table" then
                result[key] = clone_attachment_tree(child)
            else
                result[key] = child
            end
        end

        return result
    end

    prepare_item = function(source, is_root)
        if type(source) ~= "table" then
            return source
        end

        local existing = cloned_items[source]

        if existing then
            return existing
        end

        local copy = table.clone_instance(source)
        cloned_items[source] = copy

        -- Darktide evaluates first-person eligibility on every item in the
        -- attachment hierarchy, not only on the root cosmetic. Keep the whole
        -- private graph eligible without mutating MasterItems globally.
        copy.show_in_1p = true
        copy.only_show_in_1p = false

        local first_person_base = type(source.base_unit_1p) == "string"
            and source.base_unit_1p ~= "" and source.base_unit_1p
            or util.item_base_unit(source, breed_name)

        if not first_person_base and type(source.breed_base_unit) == "table" then
            local breed_base = source.breed_base_unit[breed_name]

            if type(breed_base) == "string" and breed_base ~= "" then
                first_person_base = breed_base
            end
        end

        if not first_person_base and type(source.base_unit) == "string"
            and source.base_unit ~= "" then
            first_person_base = source.base_unit
        end

        if type(first_person_base) == "string" and first_person_base ~= "" then
            copy.base_unit_1p = first_person_base
        else
            rawset(copy, "base_unit_1p", false)
        end

        if type(source.attachments) == "table" then
            copy.attachments = clone_attachment_tree(source.attachments)
        end

        if is_root then
            if preserve_native_root_link and source.npclook_raw_unit ~= true then
                -- Match the older working cosmetic path: ordinary cosmetics
                -- keep their native link mode and authored attach-node fields in
                -- first person. If no base_unit_1p exists, the private graph uses
                -- the normal cosmetic base resource and Darktide's native node-
                -- name linker can still drive compatible skeletons such as gloves.
                if copy.attach_node == nil and copy.breed_attach_node == nil then
                    copy.attach_node = attach_node or 1
                end
            else
                -- Raw units and transformed roots remain rigid. Those are the
                -- cases where NPC Look must own the root transform rather than
                -- letting the native 1p skeleton mapping control the hierarchy.
                copy.attach_node = attach_node or 1
                rawset(copy, "breed_attach_node", false)
                copy.link_map_mode = "LINK_MODE_NONE"
            end
        end

        return copy
    end

    setmetatable(overlay_definitions, {
        __index = function(_, item_name)
            local source = source_definitions[item_name]

            if type(source) ~= "table" then
                return source
            end

            local copy = prepare_item(source, false)
            rawset(overlay_definitions, item_name, copy)

            return copy
        end,
    })

    local root_item = prepare_item(item, true)

    if type(root_item.name) == "string" and root_item.name ~= "" then
        rawset(overlay_definitions, root_item.name, root_item)
    end

    return root_item, overlay_definitions
end

local function spawn_first_person_visual(context, entry, item, applied_transform, material_entries, package_record)
    local parent = context.first_person_unit

    if not context.is_live or not applied_transform.first_person
        or not safe_unit_alive(context.parent_unit) or not safe_unit_alive(parent) then
        return nil, "first-person parent unavailable"
    end

    local attach_node = resolve_anchor_attach_node(parent, entry.anchor, entry.attach_node)
    local settings = attach_settings(context, parent)
    -- Match the older working first-person cosmetic path for ordinary
    -- untransformed extras: let Darktide's native visual-loadout linker decide
    -- how the cosmetic skeleton follows the 1p rig. This intentionally does not
    -- require a distinct base_unit_1p; when the item has none, the private 1p
    -- graph already falls back to its normal cosmetic base resource. Raw units
    -- and transformed roots stay on the newer rigid-safe path.
    local preserve_native_root_link = not applied_transform.enabled
        and item.npclook_raw_unit ~= true
    local copy, first_person_definitions = first_person_item_graph(
        item,
        settings.item_definitions,
        context.breed_name,
        attach_node,
        preserve_native_root_link
    )

    -- Use the vanilla first-person attachment path with a private item graph.
    settings.item_definitions = first_person_definitions
    settings.character_unit = parent
    settings.owner_unit = parent
    settings.is_first_person = true
    settings.lod_group = false
    settings.lod_shadow_group = false
    settings.force_highest_lod_step = nil

    local attempt_baseline = child_unit_set(parent)

    local function cleanup_attempt_delta()
        local units = {}
        local seen = {}

        collect_new_parent_children(
            parent,
            attempt_baseline,
            units,
            seen,
            context.unit_spawner
        )

        if #units > 0 then
            extend_package_release_guard(package_record, units)
            destroy_ordered_units(units, context.unit_spawner, settings.world)
            flush_unit_spawner(context.unit_spawner)
        end
    end

    local root_unit, attachment_map, item_names, spawn_error = spawn_item_instance(
        copy,
        settings,
        parent,
        context.mission
    )

    if not root_unit then
        cleanup_attempt_delta()
        return nil, spawn_error or "first-person hierarchy did not spawn"
    end

    pcall(World.update_unit, settings.world, root_unit)
    pcall(Unit.set_unit_visibility, root_unit, false, true)
    pcall(
        Unit.set_shader_pass_flag_for_meshes_in_unit_and_childs,
        root_unit,
        "custom_fov",
        true
    )
    remove_item_actors(root_unit)

    neutralize_record_physics({
        raw_unit = copy.npclook_raw_unit == true,
        root_unit = root_unit,
        attachment_map = attachment_map or {},
    })

    apply_material_entries_to_visual(
        context,
        settings,
        entry,
        copy,
        root_unit,
        attachment_map,
        item_names,
        material_entries,
        " first person"
    )
    RAW_UNITS.apply_variants(copy, root_unit, attachment_map, entry.variant_state)

    local root_baseline = capture_root_baseline(root_unit)

    if applied_transform.enabled then
        local ok_transform, transform_error = pcall(
            apply_transform,
            root_unit,
            applied_transform,
            root_baseline,
            true
        )

        if not ok_transform then
            destroy_units({
                world = settings.world,
                unit_spawner = context.unit_spawner,
                package_record = package_record,
                root_unit = root_unit,
                attachment_map = attachment_map or {},
            })
            cleanup_attempt_delta()
            return nil, "first-person transform failed: " .. tostring(transform_error)
        end

        pcall(World.update_unit, settings.world, root_unit)
    end

    return {
        root_unit = root_unit,
        attachment_map = attachment_map or {},
        item_name_by_unit = item_names or {},
        root_baseline = root_baseline,
        attach_node = attach_node,
    }, nil
end

local function animated_first_person_item(item, transform, attach_node)
    local result = table.clone_instance(item)

    -- This copy deliberately uses the complete third-person cosmetic resource
    -- hierarchy. It is attached to an isolated full-body pose proxy, not to the
    -- player's recursively hidden third-person hierarchy.
    result.show_in_1p = true
    result.only_show_in_1p = false
    result.event_in_parent_state_machine = nil

    if result.npclook_raw_unit == true then
        result.link_map_mode = "LINK_MODE_NONE"
        result.attach_node = attach_node or result.attach_node or 1
        rawset(result, "breed_attach_node", false)
    elseif transform.deform then
        -- Deforming cosmetics need the proxy's complete skeleton map.
        result.link_map_mode = "LINK_MODE_NODE_NAME"
    else
        -- Rigid cosmetics follow one animated proxy anchor while keeping their
        -- editable root transform independent.
        result.link_map_mode = "LINK_MODE_NONE"
        result.attach_node = attach_node or result.attach_node or 1
        rawset(result, "breed_attach_node", false)
    end

    return result
end

local function spawn_animated_first_person_visual(
        context,
        entry,
        item,
        applied_transform,
        material_entries,
        shared_driver_unit,
        package_record)
    if not context.is_live or not applied_transform.first_person
        or not applied_transform.animate_first_person
        or item.npclook_raw_unit == true
        or not safe_unit_alive(context.parent_unit) then
        return nil, "animated first-person proxy unavailable"
    end

    local driver_unit = safe_unit_alive(shared_driver_unit) and shared_driver_unit or nil
    local driver_node_pairs
    local owns_driver = false
    local driver_transform

    if not driver_unit then
        -- The proxy root is transformed only for deforming transforms. Rigid
        -- transforms stay on the cosmetic root so the proxy can remain a neutral
        -- copy of the evaluated character pose.
        if applied_transform.enabled and applied_transform.deform then
            driver_transform = applied_transform
        else
            driver_transform = normalize_transform(nil)
        end

        driver_unit, driver_node_pairs = spawn_transform_driver(
            context,
            driver_transform,
            package_record
        )
        owns_driver = safe_unit_alive(driver_unit)
    end

    if not safe_unit_alive(driver_unit) then
        return nil, "animated first-person pose proxy did not spawn"
    end

    local attach_node = resolve_anchor_attach_node(driver_unit, entry.anchor, entry.attach_node)
    local copy = animated_first_person_item(item, applied_transform, attach_node)
    local settings = attach_settings(context, driver_unit)

    -- Intentionally use the third-person spawn path. This bypasses show_in_1p
    -- filtering on nested cosmetic items while the proxy keeps the hierarchy out
    -- of Darktide's hidden player unit tree.
    settings.character_unit = driver_unit
    settings.owner_unit = context.parent_unit
    settings.is_first_person = false
    settings.lod_group = false
    settings.lod_shadow_group = false
    settings.force_highest_lod_step = true

    local attempt_baseline = child_unit_set(driver_unit)

    local function cleanup_attempt_delta()
        local units = {}
        local seen = {}

        collect_new_parent_children(
            driver_unit,
            attempt_baseline,
            units,
            seen,
            context.unit_spawner
        )

        if #units > 0 then
            extend_package_release_guard(package_record, units)
            destroy_ordered_units(units, context.unit_spawner, settings.world)
            flush_unit_spawner(context.unit_spawner)
        end
    end

    local root_unit, attachment_map, item_names, spawn_error = spawn_item_instance(
        copy,
        settings,
        driver_unit,
        context.mission
    )

    if not root_unit then
        cleanup_attempt_delta()

        if owns_driver then
            destroy_units({
                world = settings.world,
                unit_spawner = context.unit_spawner,
                package_record = package_record,
                driver_unit = driver_unit,
            })
        end

        return nil, spawn_error or "animated first-person hierarchy did not spawn"
    end

    pcall(Unit.set_unit_visibility, root_unit, false, true)
    remove_item_actors(root_unit)

    neutralize_record_physics({
        raw_unit = false,
        root_unit = root_unit,
        attachment_map = attachment_map or {},
    })

    apply_material_entries_to_visual(
        context,
        settings,
        entry,
        copy,
        root_unit,
        attachment_map,
        item_names,
        material_entries,
        " animated first person"
    )
    RAW_UNITS.apply_variants(copy, root_unit, attachment_map, entry.variant_state)

    for _, deform_override_item in pairs(copy.deform_override_items or {}) do
        pcall(
            VisualLoadoutCustomization.apply_material_override_item,
            root_unit,
            driver_unit,
            false,
            deform_override_item,
            false,
            settings.item_definitions
        )
    end

    local root_baseline

    if applied_transform.enabled and not applied_transform.deform then
        pcall(World.update_unit, settings.world, root_unit)
        root_baseline = capture_root_baseline(root_unit)

        local ok_transform, transform_error = root_baseline and pcall(
            apply_transform,
            root_unit,
            applied_transform,
            root_baseline,
            true
        )

        if not ok_transform then
            destroy_units({
                world = settings.world,
                unit_spawner = context.unit_spawner,
                package_record = package_record,
                root_unit = root_unit,
                attachment_map = attachment_map or {},
                driver_unit = owns_driver and driver_unit or nil,
            })
            cleanup_attempt_delta()
            return nil, "animated first-person transform failed: "
                .. tostring(transform_error or "unknown error")
        end

        pcall(World.update_unit, settings.world, root_unit)
    end

    configure_first_person_render_hierarchy(root_unit, attachment_map, false)

    return {
        root_unit = root_unit,
        attachment_map = attachment_map or {},
        item_name_by_unit = item_names or {},
        root_baseline = root_baseline,
        driver_unit = owns_driver and driver_unit or nil,
        driver_node_pairs = driver_node_pairs,
        driver_transform = driver_transform,
        reuses_driver = not owns_driver,
    }, nil
end

local function apply_animated_first_person_driver_pose(record)
    local driver = record and record.animated_first_person_driver_unit

    if not safe_unit_alive(driver) or not safe_unit_alive(record.parent_unit) then
        return false
    end

    local proxy = {
        world = record.world,
        parent_unit = record.parent_unit,
        driver_unit = driver,
        driver_node_pairs = record.animated_first_person_driver_node_pairs,
        transform = record.animated_first_person_driver_transform or normalize_transform(nil),
        runtime_transform = record.animated_first_person_driver_runtime_transform,
        root_unit = record.animated_first_person_root_unit,
        attachment_map = record.animated_first_person_attachment_map or {},
        update_units = record.animated_first_person_update_units,
    }

    if not copy_driver_nodes(proxy) or not apply_driver_root(proxy) then
        return false
    end

    local ok_update = update_record_units(proxy, driver)

    record.animated_first_person_driver_node_pairs = proxy.driver_node_pairs
    record.animated_first_person_driver_runtime_transform = proxy.runtime_transform
    record.animated_first_person_update_units = proxy.update_units

    return ok_update
end

local function spawn_extra_slot(context, entry)
    local studio_mirror = entry_uses_studio_deformation_mirror(context, entry)
    local deformed_transform = entry_uses_deformation_driver(context, entry)
    local loose_transform = entry.transform.enabled and not entry.transform.deform
    local item, item_error = make_extra_slot_item(
        entry.item_name,
        context.breed_name,
        entry.transform,
        entry.dependency_materials,
        entry.attach_node,
        entry.variant_state,
        entry.opacity
    )

    if not item then
        return nil, item_error, false
    end

    item.npclook_extra_transform_signature = entry.transform_signature

    if item.npclook_raw_unit == true then
        RAW_UNITS.refresh(item)
        item.npclook_raw_definition = nil
    end

    if studio_mirror or deformed_transform then
        item.link_map_mode = "LINK_MODE_NODE_NAME"
    end

    if loose_transform and type(entry.attach_node) == "string"
        and not unit_has_direct_node(context.parent_unit, entry.attach_node) then
        return nil, loc("error_extra_anchor_node_missing", tostring(entry.anchor), entry.attach_node), false
    end

    local package_record, package_error, loading = acquire_packages(context, entry.id, item)

    if not package_record then
        return nil, package_error, loading
    end

    if item.npclook_raw_unit == true then
        RAW_UNITS.mark_package_ready(item, package_record.package_manager)
        local ready, raw_error, raw_loading = RAW_UNITS.ensure_ready(
            item,
            true,
            package_record.package_manager
        )

        if not ready then
            queue_package_release(context, package_record, 0)
            return nil, raw_error or loc("error_raw_unit_unavailable", tostring(item.base_unit)), raw_loading
        end
    end

    -- Compile dependencies before applying overrides to spawned item units.
    if #(item.npclook_dependency_material_overrides or {}) > 0
        or item.npclook_custom_material_overrides then
        item.material_override_items = item.npclook_authored_material_overrides
    end

    local settings = attach_settings(context)

    if item.npclook_raw_unit == true then
        settings.force_highest_lod_step = false
    end

    if not settings.world or not safe_unit_alive(context.parent_unit) then
        queue_package_release(context, package_record, 0)
        return nil, loc("error_local_visual_not_ready"), false
    end

    local parent_child_baseline = child_unit_set(context.parent_unit)
    local first_person_child_baseline = child_unit_set(context.first_person_unit)
    local capture_preview_world = item.npclook_raw_unit == true
        and is_persistent_ui_preview_context(context)
    local world_baseline = capture_preview_world and world_unit_set(settings.world) or nil
    local driver_unit
    local driver_node_pairs
    local pose_source_unit
    local pose_source_attachment_map
    local pose_source_world_nodes
    local attachment_parent = context.parent_unit
    local item_unit
    local attachment_units
    local item_name_by_unit

    local studio_mirror_fallback = false
    local original_item = item
    local spawn_error

    local function discard_pose_source()
        destroy_units({
            world = settings.world,
            unit_spawner = context.unit_spawner,
            package_record = package_record,
            pose_source_unit = pose_source_unit,
            pose_source_attachment_map = pose_source_attachment_map,
        })
        pose_source_unit = nil
        pose_source_attachment_map = nil
        pose_source_world_nodes = nil
    end

    local function clear_partial_studio_spawn()
        discard_pose_source()
        destroy_units({
            world = settings.world,
            unit_spawner = context.unit_spawner,
            package_record = package_record,
            spawned_world_units = collect_world_spawn_delta(
                settings.world,
                world_baseline,
                context.unit_spawner
            ),
        })
        destroy_parent_spawn_delta(context, parent_child_baseline, first_person_child_baseline, package_record)
    end

    if studio_mirror then
        -- Use a native linked copy as the evaluated pose source for Studio previews.
        -- If either copy is incompatible with the UI spawner, fall back to a single
        -- independently transformed visual instead of failing the whole extra slot.
        local source_settings = table.shallow_copy(settings)
        source_settings.lod_group = nil
        source_settings.lod_shadow_group = nil

        local source_error
        pose_source_unit, pose_source_attachment_map, _, source_error = spawn_item_instance(
            item,
            source_settings,
            context.parent_unit,
            context.mission
        )

        if pose_source_unit then
            remove_item_actors(pose_source_unit)
            hide_pose_source_hierarchy(pose_source_unit, pose_source_attachment_map)

            local visible_item = table.clone_instance(item)
            visible_item.event_in_parent_state_machine = nil
            visible_item.link_map_mode = "LINK_MODE_NONE"
            visible_item.attach_node = 1
            rawset(visible_item, "breed_attach_node", false)
            item = visible_item

            local visible_error
            item_unit, attachment_units, item_name_by_unit, visible_error = spawn_item_instance(
                item,
                attach_settings(context),
                context.parent_unit,
                context.mission
            )

            if item_unit then
                -- Unlink the visible copy so its root transform remains independent.
                pcall(World.unlink_unit, settings.world, item_unit)
                pose_source_world_nodes = build_studio_mirror_nodes(item_unit, pose_source_unit)

                if not pose_source_world_nodes then
                    discard_pose_source()
                    studio_mirror = false
                    studio_mirror_fallback = true
                end
            else
                spawn_error = visible_error
                clear_partial_studio_spawn()
                studio_mirror = false
                studio_mirror_fallback = true
                item = original_item
            end
        else
            spawn_error = source_error
            clear_partial_studio_spawn()
            studio_mirror = false
            studio_mirror_fallback = true
        end

        if studio_mirror_fallback and not item_unit then
            item = original_item
            local fallback_error
            item_unit, attachment_units, item_name_by_unit, fallback_error = spawn_item_instance(
                item,
                settings,
                attachment_parent,
                context.mission
            )
            spawn_error = fallback_error or spawn_error
        end
    elseif deformed_transform then
        driver_unit, driver_node_pairs = spawn_transform_driver(context, entry.transform, package_record)

        if driver_unit then
            attachment_parent = driver_unit
            settings = attach_settings(context, driver_unit)
            item_unit, attachment_units, item_name_by_unit, spawn_error = spawn_item_instance(
                item,
                settings,
                attachment_parent,
                context.mission
            )
        else
            -- A driver can be unavailable during character transitions or when an
            -- authored breed layout does not match the live parent. Preserve the
            -- slot as a rigid root transform instead of failing and respawning it.
            deformed_transform = false
            loose_transform = true
            item = table.clone_instance(original_item)
            item.link_map_mode = "LINK_MODE_NONE"
            item.attach_node = resolve_anchor_attach_node(
                context.parent_unit,
                entry.anchor,
                entry.attach_node
            )
            rawset(item, "breed_attach_node", false)
            settings = attach_settings(context)
            item_unit, attachment_units, item_name_by_unit, spawn_error = spawn_item_instance(
                item,
                settings,
                context.parent_unit,
                context.mission
            )
        end
    else
        item_unit, attachment_units, item_name_by_unit, spawn_error = spawn_item_instance(
            item,
            settings,
            attachment_parent,
            context.mission
        )
    end

    if not item_unit then
        destroy_units({
            world = settings.world,
            unit_spawner = context.unit_spawner,
            package_record = package_record,
            driver_unit = driver_unit,
            pose_source_unit = pose_source_unit,
            pose_source_attachment_map = pose_source_attachment_map,
            spawned_world_units = collect_world_spawn_delta(settings.world, world_baseline, context.unit_spawner),
        })
        destroy_parent_spawn_delta(context, parent_child_baseline, first_person_child_baseline, package_record)
        queue_package_release(context, package_record, 0)
        return nil, visual_apply_error("item spawn", spawn_error), false
    end

    pcall(Unit.set_unit_visibility, item_unit, true, true)
    remove_item_actors(item_unit)

    neutralize_record_physics({
        raw_unit = item.npclook_raw_unit == true,
        root_unit = item_unit,
        attachment_map = attachment_units or {},
        pose_source_unit = pose_source_unit,
        pose_source_attachment_map = pose_source_attachment_map or {},
    })

    local material_entries = {}

    for i = 1, #(item.npclook_dependency_material_overrides or {}) do
        material_entries[#material_entries + 1] = item.npclook_dependency_material_overrides[i]
    end

    for i = 1, #(item.npclook_custom_material_overrides or {}) do
        material_entries[#material_entries + 1] = item.npclook_custom_material_overrides[i]
    end

    apply_material_entries_to_visual(
        context,
        settings,
        entry,
        item,
        item_unit,
        attachment_units,
        item_name_by_unit,
        material_entries
    )
    RAW_UNITS.apply_variants(item, item_unit, attachment_units, entry.variant_state)

    if deformed_transform then
        -- Reapply parent-facing effects to the real character.
        pcall(
            VisualLoadoutCustomization.apply_material_overrides,
            item,
            item_unit,
            context.parent_unit,
            settings
        )
        if item.npclook_raw_unit ~= true then
            pcall(VisualLoadoutCustomization.play_item_on_spawn_anim_event, item, context.parent_unit)
        end
    end

    local applied_transform = normalize_transform(entry.transform)

    local root_transform = loose_transform or studio_mirror_fallback

    if root_transform then
        -- Settle the new link before recording its authored local root pose.
        pcall(World.update_unit, settings.world, item_unit)
    end

    local root_baseline = root_transform and capture_root_baseline(item_unit) or nil
    local ok_transform
    local transform_error

    if root_transform and not root_baseline then
        transform_error = "root transform baseline unavailable"
        ok_transform = false
    elseif studio_mirror then
        local mirror_record = {
            parent_unit = context.parent_unit,
            world = settings.world,
            root_unit = item_unit,
            attachment_map = attachment_units or {},
            pose_source_unit = pose_source_unit,
            pose_source_attachment_map = pose_source_attachment_map or {},
            pose_source_world_nodes = pose_source_world_nodes,
            transform = applied_transform,
        }
        ok_transform = apply_studio_mirror_pose(mirror_record)
        pose_source_world_nodes = mirror_record.pose_source_world_nodes

        if not ok_transform then
            -- Some authored cosmetics can spawn in the UI world but expose an
            -- incompatible scene graph. Keep the visible slot and degrade to
            -- direct root transformation instead of entering a retry/error loop.
            discard_pose_source()
            studio_mirror = false
            studio_mirror_fallback = true
            pcall(World.update_unit, settings.world, item_unit)
            root_baseline = capture_root_baseline(item_unit)

            if root_baseline then
                local fallback_record = {
                    world = settings.world,
                    root_unit = item_unit,
                    attachment_map = attachment_units or {},
                    transform = applied_transform,
                    root_baseline = root_baseline,
                }
                ok_transform = apply_linked_root_pose(fallback_record)
                transform_error = ok_transform and nil or "deformation mirror fallback failed"
            else
                transform_error = "deformation mirror fallback baseline unavailable"
            end
        end
    elseif deformed_transform then
        local driver_record = {
            driver_unit = driver_unit,
            driver_node_pairs = driver_node_pairs,
            parent_unit = context.parent_unit,
            world = settings.world,
            root_unit = item_unit,
            attachment_map = attachment_units or {},
            transform = applied_transform,
        }
        ok_transform = apply_driver_pose(driver_record)
        driver_node_pairs = driver_record.driver_node_pairs
        transform_error = ok_transform and nil or "deformation driver pose failed"
    elseif root_transform then
        local temporary_record = {
            world = settings.world,
            root_unit = item_unit,
            attachment_map = attachment_units or {},
            transform = applied_transform,
            root_baseline = root_baseline,
        }
        ok_transform = apply_linked_root_pose(temporary_record)
        transform_error = ok_transform and nil or "root transform application failed"
    else
        ok_transform = true
    end

    if not ok_transform then
        local failed_record = {
            world = settings.world,
            unit_spawner = context.unit_spawner,
            package_record = package_record,
            root_unit = item_unit,
            attachment_map = attachment_units or {},
            driver_unit = driver_unit,
            pose_source_unit = pose_source_unit,
            pose_source_attachment_map = pose_source_attachment_map,
            spawned_world_units = collect_world_spawn_delta(settings.world, world_baseline, context.unit_spawner),
        }
        destroy_units(failed_record)
        destroy_parent_spawn_delta(context, parent_child_baseline, first_person_child_baseline, package_record)
        queue_package_release(context, package_record, 0)
        return nil, visual_apply_error("transform", transform_error), false
    end

    for _, deform_override_item in pairs(item.deform_override_items or {}) do
        pcall(
            VisualLoadoutCustomization.apply_material_override_item,
            item_unit,
            context.parent_unit,
            false,
            deform_override_item,
            false,
            settings.item_definitions
        )
    end

    local first_person_visual
    local animated_first_person_visual
    local first_person_error

    if context.is_live and applied_transform.first_person then
        if applied_transform.animate_first_person and item.npclook_raw_unit ~= true then
            animated_first_person_visual, first_person_error = spawn_animated_first_person_visual(
                context,
                entry,
                item,
                applied_transform,
                material_entries,
                driver_unit,
                package_record
            )
        else
            first_person_visual, first_person_error = spawn_first_person_visual(
                context,
                entry,
                item,
                applied_transform,
                material_entries,
                package_record
            )
        end
    end

    -- Keep the valid 3p visual while the requested 1p presentation settles.
    -- Animated body cosmetics retry their isolated pose-proxy presentation; raw
    -- units and rigid 1p slots retry the normal first-person hierarchy.
    local first_person_pending = context.is_live and applied_transform.first_person
        and (applied_transform.animate_first_person and item.npclook_raw_unit ~= true
            and animated_first_person_visual == nil
            or (not applied_transform.animate_first_person or item.npclook_raw_unit == true)
            and first_person_visual == nil)

    local record = {
        id = entry.id,
        item_name = entry.item_name,
        anchor = entry.anchor,
        transform = applied_transform,
        runtime_transform = runtime_transform(applied_transform),
        transform_signature = transform_signature(applied_transform),
        material_signature = item.npclook_material_signature,
        variant_signature = entry.variant_signature,
        opacity = entry.opacity,
        variant_item = item,
        variant_state = RAW_UNITS.normalize_variant_state(entry.variant_state, entry.item_name),
        transform_enabled = applied_transform.enabled,
        transform_deform = applied_transform.deform,
        first_person_enabled = applied_transform.first_person,
        first_person_animate = applied_transform.animate_first_person,
        uses_deformation_driver = deformed_transform,
        deformation_driver_fallback = entry_uses_deformation_driver(context, entry)
            and not deformed_transform,
        uses_studio_deformation_mirror = studio_mirror,
        studio_mirror_fallback = studio_mirror_fallback,
        attach_node = entry.attach_node,
        parent_unit = context.parent_unit,
        first_person_parent_unit = context.first_person_unit,
        parent_child_baseline = parent_child_baseline,
        first_person_child_baseline = first_person_child_baseline,
        spawned_world_units = collect_world_spawn_delta(settings.world, world_baseline, context.unit_spawner),
        parent_spawned_units = {},
        parent_spawned_seen = {},
        world = settings.world,
        unit_spawner = context.unit_spawner,
        root_unit = item_unit,
        attachment_map = attachment_units or {},
        item_name_by_unit = item_name_by_unit or {},
        first_person_root_unit = first_person_visual and first_person_visual.root_unit,
        first_person_attachment_map = first_person_visual and first_person_visual.attachment_map or {},
        first_person_item_name_by_unit = first_person_visual and first_person_visual.item_name_by_unit or {},
        first_person_root_baseline = first_person_visual and first_person_visual.root_baseline,
        first_person_attach_node = first_person_visual and first_person_visual.attach_node,
        animated_first_person_root_unit = animated_first_person_visual
            and animated_first_person_visual.root_unit,
        animated_first_person_attachment_map = animated_first_person_visual
            and animated_first_person_visual.attachment_map or {},
        animated_first_person_item_name_by_unit = animated_first_person_visual
            and animated_first_person_visual.item_name_by_unit or {},
        animated_first_person_root_baseline = animated_first_person_visual
            and animated_first_person_visual.root_baseline,
        animated_first_person_driver_unit = animated_first_person_visual
            and animated_first_person_visual.driver_unit,
        animated_first_person_driver_node_pairs = animated_first_person_visual
            and animated_first_person_visual.driver_node_pairs,
        animated_first_person_driver_transform = animated_first_person_visual
            and animated_first_person_visual.driver_transform,
        animated_first_person_driver_runtime_transform = nil,
        animated_first_person_update_units = nil,
        animated_first_person_driver_required = animated_first_person_visual ~= nil
            and animated_first_person_visual.driver_unit ~= nil,
        animated_first_person_pose_failure_count = 0,
        animated_first_person_rebuild_pending = nil,
        first_person_pending = first_person_pending,
        first_person_retry_elapsed = 0,
        first_person_retry_count = 0,
        first_person_error = first_person_error,
        first_person_material_entries = material_entries,
        driver_unit = driver_unit,
        driver_node_pairs = driver_node_pairs,
        pose_source_unit = pose_source_unit,
        pose_source_attachment_map = pose_source_attachment_map or {},
        pose_source_world_nodes = pose_source_world_nodes,
        root_baseline = root_baseline,
        package_record = package_record,
        raw_unit = item.npclook_raw_unit == true,
        physics_tracker = nil,
        failed = false,
    }

    capture_record_parent_children(record)
    track_record_deletion_roots(record)

    if loose_transform and is_persistent_ui_preview_context(context) then
        -- Apply the local transform before the first UI render.
        update_record_units(record, item_unit)
    end

    local tracker = neutralize_record_physics(record)
    record.physics_tracker = tracker

    stabilize_transformed_visibility(record)
    apply_opacity_to_units(collect_record_units(record), record.opacity)

    set_record_perspective_visibility(record, context.first_person_mode, true)

    return record, nil, false
end

local function normalize_entries(entries)
    local normalized = {}

    for i = 1, #(entries or {}) do
        local entry = entries[i]

        if type(entry) == "table" and type(entry.id) == "string"
            and type(entry.item_name) == "string" then
            local transform = normalize_transform(entry.transform)
            local dependency_materials = normalize_override_names(entry.dependency_materials)

            normalized[#normalized + 1] = {
                id = entry.id,
                item_name = entry.item_name,
                anchor = entry.anchor,
                attach_node = normalize_attach_node(entry.attach_node) or 1,
                transform = transform,
                transform_signature = transform_signature(transform, true),
                dependency_materials = dependency_materials,
                variant_state = RAW_UNITS.normalize_variant_state(entry.variant_state, entry.item_name),
                variant_signature = RAW_UNITS.variant_signature(entry.variant_state),
                opacity = normalize_opacity(entry.opacity),
                material_signature = table.concat(dependency_materials, "\30")
                    .. "\29" .. table.concat(transform.materials, "\31"),
            }
        end
    end

    table.sort(normalized, function(left, right)
        return tostring(left.id) < tostring(right.id)
    end)

    return normalized
end

local function sync_context(context, entries, retry_failed)
    entries = resolve_entry_anchor_nodes(context.parent_unit, normalize_entries(entries))
    local desired_by_id = {}
    local spawned_count = 0
    local failed_count = 0
    local first_error
    local packages_loading = false

    for i = 1, #entries do
        desired_by_id[entries[i].id] = entries[i]
    end

    local stale_ids = {}

    for id, record in pairs(context.records) do
        local entry = desired_by_id[id]
        local driver_required = entry and entry_uses_deformation_driver(context, entry)
        local mirror_required = entry and entry_uses_studio_deformation_mirror(context, entry)
        local valid = entry
            and record.parent_unit == context.parent_unit
            and record.item_name == entry.item_name
            and record.anchor == entry.anchor
            and record.transform_enabled == entry.transform.enabled
            and record.transform_deform == entry.transform.deform
            and record.first_person_enabled == entry.transform.first_person
            and record.first_person_animate == entry.transform.animate_first_person
            and deformation_driver_state_matches(record, driver_required)
            and studio_mirror_state_matches(record, mirror_required)
            -- Rebuild when the resolved character anchor changes.
            and (not (entry.transform.enabled and not entry.transform.deform)
                or record.attach_node == entry.attach_node)
            and record.material_signature == entry.material_signature
            and record.variant_signature == entry.variant_signature
            and not (retry_failed and record.failed)
            and (record.failed or safe_unit_alive(record.root_unit))
            and (not (context.is_live and entry.transform.first_person)
                or record.first_person_pending == true
                or record.first_person_retry_exhausted == true
                or entry.transform.animate_first_person and record.raw_unit ~= true
                    and safe_unit_alive(record.animated_first_person_root_unit)
                or (not entry.transform.animate_first_person or record.raw_unit == true)
                    and safe_unit_alive(record.first_person_root_unit))
            and (not record.animated_first_person_driver_required
                or safe_unit_alive(record.animated_first_person_driver_unit))
            and (not record.uses_deformation_driver or safe_unit_alive(record.driver_unit))
            and (not record.uses_studio_deformation_mirror
                or safe_unit_alive(record.pose_source_unit))

        if not valid then
            stale_ids[#stale_ids + 1] = id
        end
    end

    for i = 1, #stale_ids do
        remove_extra_slot(context, stale_ids[i], 0)
    end

    if #stale_ids > 0 then
        flush_unit_spawner(context.unit_spawner)
        sweep_context_owned_children(context)
    end

    local pending_ids = table.keys(context.pending)

    for i = 1, #pending_ids do
        local id = pending_ids[i]
        local entry = desired_by_id[id]
        local pending = context.pending[id]

        if not entry or pending.item_name ~= entry.item_name
            or pending.material_signature ~= entry.material_signature
            or pending.variant_signature ~= entry.variant_signature
            or pending.transform_signature ~= entry.transform_signature then
            retire_pending_package(context, id)
        end
    end

    for i = 1, #entries do
        local entry = entries[i]
        local record = context.records[entry.id]

        if record and not record.failed and record.transform_signature ~= entry.transform_signature then
            local applied_transform = normalize_transform(entry.transform)
            local ok_transform

            if record.uses_studio_deformation_mirror then
                record.transform = applied_transform
                record.runtime_transform = runtime_transform(applied_transform)
                ok_transform = apply_studio_mirror_pose(record)

                if not ok_transform then
                    ok_transform = fallback_studio_mirror_pose(record, applied_transform)
                end
            elseif record.uses_deformation_driver then
                record.transform = applied_transform
                record.runtime_transform = runtime_transform(applied_transform)
                ok_transform = apply_driver_pose(record)
            else
                ok_transform, applied_transform = pcall(
                    apply_transform,
                    record.root_unit,
                    applied_transform,
                    record.root_baseline,
                    true
                )
            end

            if ok_transform and record.first_person_enabled
                and (record.first_person_animate ~= true or record.raw_unit == true)
                and safe_unit_alive(record.first_person_root_unit)
                and applied_transform.enabled then
                local ok_first_person

                ok_first_person, applied_transform = pcall(
                    apply_transform,
                    record.first_person_root_unit,
                    applied_transform,
                    record.first_person_root_baseline,
                    true
                )

                if ok_first_person then
                    update_record_units(record, record.first_person_root_unit)
                else
                    ok_transform = false
                end
            end

            if ok_transform and record.first_person_animate
                and safe_unit_alive(record.animated_first_person_root_unit)
                and applied_transform.enabled and not applied_transform.deform then
                local ok_animated

                ok_animated, applied_transform = pcall(
                    apply_transform,
                    record.animated_first_person_root_unit,
                    applied_transform,
                    record.animated_first_person_root_baseline,
                    true
                )

                if ok_animated then
                    update_record_units(record, record.animated_first_person_root_unit)
                else
                    ok_transform = false
                end
            end

            if ok_transform and record.first_person_animate
                and safe_unit_alive(record.animated_first_person_driver_unit) then
                if applied_transform.enabled and applied_transform.deform then
                    record.animated_first_person_driver_transform = applied_transform
                else
                    record.animated_first_person_driver_transform = normalize_transform(nil)
                end

                record.animated_first_person_driver_runtime_transform = nil
                ok_transform = apply_animated_first_person_driver_pose(record)
            end

            if ok_transform then
                record.transform = applied_transform
                record.runtime_transform = runtime_transform(applied_transform)
                record.transform_signature = transform_signature(applied_transform)
                record.transform_deform = applied_transform.deform
                record.first_person_animate = applied_transform.animate_first_person
            else
                remove_extra_slot(context, entry.id)
                record = nil
            end
        end

        if record and not record.failed and record.opacity ~= entry.opacity then
            record.opacity = entry.opacity
            set_record_perspective_visibility(record, context.first_person_mode, true)
            apply_opacity_to_units(collect_record_units(record), entry.opacity)
        end

        if record and record.failed then
            failed_count = failed_count + 1
            first_error = first_error or record.error
        elseif not record then
            local spawned, err, loading = spawn_extra_slot(context, entry)

            if spawned then
                context.records[entry.id] = spawned
                spawned_count = spawned_count + 1
            elseif loading then
                packages_loading = true
                first_error = first_error or string.format("%s: %s", entry.id, tostring(err))
            else
                context.records[entry.id] = {
                    id = entry.id,
                    item_name = entry.item_name,
                    anchor = entry.anchor,
                    transform = normalize_transform(entry.transform),
                    transform_signature = entry.transform_signature,
                    material_signature = entry.material_signature,
                    variant_signature = entry.variant_signature,
                    opacity = entry.opacity,
                    transform_enabled = entry.transform.enabled,
                    transform_deform = entry.transform.deform,
                    first_person_enabled = entry.transform.first_person,
                    first_person_animate = entry.transform.animate_first_person,
                    uses_deformation_driver = entry_uses_deformation_driver(context, entry),
                    deformation_driver_fallback = false,
                    uses_studio_deformation_mirror = entry_uses_studio_deformation_mirror(context, entry),
                    attach_node = entry.attach_node,
                    parent_unit = context.parent_unit,
                    failed = true,
                    error = string.format("%s: %s", entry.id, tostring(err)),
                }
                failed_count = failed_count + 1
                first_error = first_error or context.records[entry.id].error
            end
        end
    end

    refresh_context_activity(context)
    discard_empty_context(context)

    local sync_ok = failed_count == 0 and not packages_loading

    return sync_ok, spawned_count, failed_count, first_error, packages_loading
end

local function live_settings(player_unit, ext)
    local unit_data_extension = ext and ext._unit_data_extension
    local breed = unit_data_extension and unit_data_extension:breed()

    local equipment_component = ext and ext._equipment_component

    return {
        world = safe_unit_world(player_unit),
        unit_spawner = equipment_component and equipment_component._unit_spawner
            or Managers.state and Managers.state.unit_spawner,
        item_definitions = ext and ext._item_definitions or item_cache(),
        mission = ext and ext._mission,
        breed_name = breed and breed.name,
        driver_base_unit = breed and breed.base_unit,
        from_ui_profile_spawner = false,
        force_highest_lod_step = false,
        first_person_unit = ext and ext._first_person_unit,
        first_person_extension = ext and ext._first_person_extension,
    }
end

function ExtraSlotRuntime.sync(player_unit, ext, applied, suppressed, empty, anchors, transforms, loadout, variants, opacity)
    local context = context_for(LIVE_CONTEXT, true)
    configure_context(context, player_unit, live_settings(player_unit, ext))
    context.variants = variants or context.variants
    context.first_person_mode = ext and ext._is_in_first_person_mode == true

    local ok, spawned_count, failed_count, first_error, packages_loading = sync_context(
        context,
        plan_extra_slots(loadout, applied, suppressed, empty, anchors, transforms, context.breed_name, context.variants, opacity),
        true
    )

    apply_context_first_person_visibility(context)

    return ok, spawned_count, failed_count, first_error, packages_loading
end

function ExtraSlotRuntime.set_first_person_mode(player_unit, first_person_mode)
    local context = contexts[LIVE_CONTEXT]

    if not context or player_unit and context.parent_unit ~= player_unit then
        return
    end

    context.first_person_mode = first_person_mode == true

    apply_context_first_person_visibility(context)
    refresh_context_activity(context)
end

local function match_error(id, reason)
    return loc("error_visual_apply", string.format("%s: %s", tostring(id), tostring(reason)))
end

function ExtraSlotRuntime.matches(applied, suppressed, empty, anchors, transforms, loadout, variants, opacity)
    local context = contexts[LIVE_CONTEXT]
    local entries = normalize_entries(plan_extra_slots(
        loadout,
        applied,
        suppressed,
        empty,
        anchors,
        transforms,
        context and context.breed_name,
        variants or context and context.variants,
        opacity
    ))

    if context then
        entries = resolve_entry_anchor_nodes(context.parent_unit, entries)
    end

    local desired_by_id = {}

    for i = 1, #entries do
        desired_by_id[entries[i].id] = entries[i]
    end

    if not context then
        if #entries == 0 then
            return true
        end

        return false, match_error("extra slots", "runtime context missing")
    end

    -- A pending package means the requested visual has not finished applying yet.
    if next(context.pending or {}) ~= nil then
        return false, match_error("extra slots", "package load pending")
    end

    -- Reject records that are no longer requested.
    for id in pairs(context.records or {}) do
        if not desired_by_id[id] then
            return false, match_error(id, "stale visual")
        end
    end

    for i = 1, #entries do
        local entry = entries[i]
        local record = context.records[entry.id]
        local driver_required = entry_uses_deformation_driver(context, entry)
        local mirror_required = entry_uses_studio_deformation_mirror(context, entry)
        local anchor_node_required = entry.transform.enabled and not entry.transform.deform

        if not record then
            return false, match_error(entry.id, "visual missing")
        elseif record.failed then
            return false, record.error or match_error(entry.id, "spawn failed")
        elseif record.parent_unit ~= context.parent_unit then
            return false, match_error(entry.id, "parent changed")
        elseif record.item_name ~= entry.item_name or record.anchor ~= entry.anchor then
            return false, match_error(entry.id, "stale item")
        elseif record.transform_enabled ~= entry.transform.enabled
            or record.transform_deform ~= entry.transform.deform
            or record.transform_signature ~= entry.transform_signature then
            return false, match_error(entry.id, "transform not applied")
        elseif record.first_person_enabled ~= entry.transform.first_person then
            return false, match_error(entry.id, "first-person state not applied")
        elseif record.first_person_animate ~= entry.transform.animate_first_person then
            return false, match_error(entry.id, "first-person animation state not applied")
        elseif context.is_live and entry.transform.first_person
            and entry.transform.animate_first_person
            and record.raw_unit ~= true
            and record.first_person_pending ~= true
            and record.first_person_retry_exhausted ~= true
            and not safe_unit_alive(record.animated_first_person_root_unit) then
            return false, match_error(entry.id, "animated first-person visual missing")
        elseif record.animated_first_person_driver_required
            and not safe_unit_alive(record.animated_first_person_driver_unit) then
            return false, match_error(entry.id, "animated first-person proxy missing")
        elseif not deformation_driver_state_matches(record, driver_required)
            or not studio_mirror_state_matches(record, mirror_required) then
            return false, match_error(entry.id, "deformation state not applied")
        elseif anchor_node_required and record.attach_node ~= entry.attach_node then
            return false, match_error(entry.id, "anchor node changed")
        elseif record.material_signature ~= entry.material_signature then
            return false, match_error(entry.id, "materials not applied")
        elseif record.variant_signature ~= entry.variant_signature then
            return false, match_error(entry.id, "variant not applied")
        elseif record.opacity ~= entry.opacity then
            return false, match_error(entry.id, "opacity not applied")
        elseif not safe_unit_alive(record.root_unit) then
            return false, match_error(entry.id, "visual was destroyed")
        elseif context.is_live and entry.transform.first_person
            and (not entry.transform.animate_first_person or record.raw_unit == true)
            and record.first_person_pending ~= true
            and record.first_person_retry_exhausted ~= true
            and not safe_unit_alive(record.first_person_root_unit) then
            return false, match_error(entry.id, "first-person visual missing")
        elseif record.uses_deformation_driver and not safe_unit_alive(record.driver_unit) then
            return false, match_error(entry.id, "deformation driver missing")
        elseif record.uses_studio_deformation_mirror
            and not safe_unit_alive(record.pose_source_unit) then
            return false, match_error(entry.id, "preview pose source missing")
        end
    end

    return true
end

function ExtraSlotRuntime.preview_items(applied, suppressed, empty, anchors, transforms, breed_name, loadout, variants, opacity)
    local extra_slot_items = {}

    for _, entry in ipairs(plan_extra_slots(loadout, applied, suppressed, empty, anchors, transforms, breed_name, variants, opacity)) do
        local item = make_extra_slot_item(
            entry.item_name,
            breed_name,
            entry.transform,
            entry.dependency_materials,
            entry.attach_node,
            entry.variant_state,
            entry.opacity
        )

        if item then
            extra_slot_items[#extra_slot_items + 1] = {
                id = entry.id,
                item_name = entry.item_name,
                anchor = entry.anchor,
                attach_node = entry.attach_node,
                transform = normalize_transform(entry.transform),
                transform_signature = entry.transform_signature,
                dependency_materials = normalize_override_names(entry.dependency_materials),
                variant_state = RAW_UNITS.normalize_variant_state(entry.variant_state, entry.item_name),
                variant_signature = entry.variant_signature,
                opacity = entry.opacity,
            }
        end
    end

    return extra_slot_items
end

function ExtraSlotRuntime.sync_context(owner, parent_unit, settings, entries)
    if not owner then
        return false, 0, 0, loc("error_local_visual_not_ready"), false
    end

    local context = context_for(owner, false)
    configure_context(context, parent_unit, settings or {})

    return sync_context(context, entries)
end

function ExtraSlotRuntime.clear_context(owner, delay)
    local context = contexts[owner]

    if not context then
        return
    end

    local ids = table.keys(context.records)

    for i = 1, #ids do
        remove_extra_slot(context, ids[i], delay)
    end

    local pending_ids = table.keys(context.pending)

    for i = 1, #pending_ids do
        retire_pending_package(context, pending_ids[i], delay)
    end

    flush_unit_spawner(context.unit_spawner)
    sweep_context_owned_children(context)
    flush_unit_spawner(context.unit_spawner)

    unregister_context_parent(owner, context)
    clear_context_activity(context)
    contexts[owner] = nil
end

function ExtraSlotRuntime.destroy_unit_list(units, unit_spawner)
    local ordered = {}
    local seen = {}

    for i = 1, #(units or {}) do
        local unit = units[i]

        if safe_unit_alive(unit) and not seen[unit] then
            seen[unit] = true
            ordered[#ordered + 1] = unit
        end
    end

    destroy_ordered_units(ordered, unit_spawner)
end

function ExtraSlotRuntime.destroy_equipment_slot(slot, unit_spawner)
    if type(slot) ~= "table" then
        return
    end

    destroy_units({
        world = safe_unit_world(slot.unit_3p or slot.item_unit_3p or slot.unit_1p or slot.item_unit_1p),
        unit_spawner = unit_spawner,
        root_unit = slot.unit_3p or slot.item_unit_3p,
        attachment_map = slot.attachments_by_unit_3p or slot.attachment_map_by_unit_3p or {},
        first_person_root_unit = slot.unit_1p or slot.item_unit_1p,
        first_person_attachment_map = slot.attachments_by_unit_1p or slot.attachment_map_by_unit_1p or {},
    })
end

function ExtraSlotRuntime.neutralize_equipment_slot(slot, item, unit_spawner)
    if type(slot) ~= "table" then
        return
    end

    local record = {
        raw_unit = true,
        externally_managed = true,
        parent_unit = slot.parent_unit_3p,
        first_person_parent_unit = slot.parent_unit_1p,
        root_unit = slot.unit_3p or slot.item_unit_3p,
        attachment_map = slot.attachments_by_unit_3p or slot.attachment_map_by_unit_3p or {},
        first_person_root_unit = slot.unit_1p or slot.item_unit_1p,
        first_person_attachment_map = slot.attachments_by_unit_1p or slot.attachment_map_by_unit_1p or {},
        variant_item = item,
        variant_state = item and item.npclook_raw_variant_state,
        unit_spawner = unit_spawner,
    }

    for _, root_unit in pairs({ record.root_unit, record.first_person_root_unit }) do
        local world = safe_unit_world(root_unit)

        if world then
            pcall(World.update_unit, world, root_unit)
        end
    end

    track_record_deletion_roots(record)

    local tracker = neutralize_record_physics(record)
    local key = safe_unit_alive(record.root_unit) and record.root_unit
        or safe_unit_alive(record.first_person_root_unit) and record.first_person_root_unit

    if key then
        raw_equipment_records[tracker] = true
    end
end

function ExtraSlotRuntime.needs_deletion_prepare(unit)
    if not unit then
        return false
    elseif deletion_pending[unit] or managed_deletion_roots[unit] or contexts_by_parent[unit] then
        return true
    end

    local children = owned_visual_children[unit]

    if not children then
        return false
    end

    local found = false

    for child in pairs(children) do
        if is_owned_visual(child) and safe_unit_alive(child) then
            found = true
        else
            children[child] = nil
        end
    end

    if not found then
        owned_visual_children[unit] = nil
    end

    return found
end

function ExtraSlotRuntime.prepare_unit_deletion(unit_spawner, unit)
    if not unit_spawner or not unit then
        return false
    elseif not ExtraSlotRuntime.needs_deletion_prepare(unit) then
        return true
    end

    local pending_state = deletion_pending[unit]

    if pending_state == "scheduling" then
        return true
    elseif pending_state == "queued" then
        return false
    elseif not safe_unit_alive(unit) then
        managed_deletion_roots[unit] = nil
        return false
    end

    local visited = {}

    local function clear_owned_descendants(parent)
        if visited[parent] or not safe_unit_alive(parent) then
            return
        end

        visited[parent] = true

        for _, child in ipairs(runtime_child_units(parent)) do
            if is_owned_visual(child) then
                local owner_record = owned_visual_records[child]

                destroy_units({
                    world = safe_unit_world(child),
                    unit_spawner = unit_spawner or owned_visual_spawners[child],
                    package_record = owner_record and owner_record.package_record,
                    root_unit = child,
                    attachment_map = {},
                })
            else
                clear_owned_descendants(child)
            end
        end
    end

    -- Components can add several links to the same child. Sweep, flush, then sweep again.
    clear_owned_descendants(unit)
    flush_unit_spawner(unit_spawner)
    table.clear(visited)
    clear_owned_descendants(unit)
    flush_unit_spawner(unit_spawner)

    if not managed_deletion_roots[unit] then
        return true
    end

    managed_deletion_roots[unit] = nil
    deletion_pending[unit] = "queued"

    return true
end

function ExtraSlotRuntime.cleanup_owned_parent_children(parent_unit, unit_spawner)
    if not safe_unit_alive(parent_unit) then
        return 0
    end

    local destroyed = 0
    local visited = {}

    local function scan(parent)
        if visited[parent] or not safe_unit_alive(parent) then
            return
        end

        visited[parent] = true

        for _, child in ipairs(runtime_child_units(parent)) do
            if not visited[child] then
                if is_owned_visual(child) then
                    destroyed = destroyed + 1
                    local owner_record = owned_visual_records[child]

                    destroy_units({
                        world = safe_unit_world(child),
                        unit_spawner = unit_spawner or owned_visual_spawners[child],
                        package_record = owner_record and owner_record.package_record,
                        root_unit = child,
                        attachment_map = {},
                    })
                else
                    scan(child)
                end
            end
        end
    end

    scan(parent_unit)

    return destroyed
end

function ExtraSlotRuntime.clear_parent_unit(parent_unit, delay)
    local owner_set = parent_unit and contexts_by_parent[parent_unit]

    if not owner_set then
        return
    end

    local owners = table.keys(owner_set)

    for i = 1, #owners do
        ExtraSlotRuntime.clear_context(owners[i], delay)
    end
end

function ExtraSlotRuntime.clear(delay)
    ExtraSlotRuntime.clear_context(LIVE_CONTEXT, delay)
end

function ExtraSlotRuntime.context_material_target_data(owner, id)
    local context = contexts[owner]
    local record = context and context.records and context.records[id]

    if not record or record.failed then
        return nil
    end

    local root_item_names = {}

    if type(record.item_name) == "string" and record.item_name ~= "" then
        root_item_names[record.item_name] = true
    end

    return {
        item_name_maps = {
            record.item_name_by_unit or {},
            record.first_person_item_name_by_unit or {},
            record.animated_first_person_item_name_by_unit or {},
        },
        attachment_maps = {
            record.attachment_map or {},
            record.first_person_attachment_map or {},
            record.animated_first_person_attachment_map or {},
        },
        root_item_names = root_item_names,
    }
end

function ExtraSlotRuntime.has_units()
    local context = contexts[LIVE_CONTEXT]

    return context and next(context.records) ~= nil or false
end

local function record_pose_result(context, record, ok_pose)
    if ok_pose then
        record.pose_failure_count = 0
        record.pose_failed = nil
        return true
    end

    local failures = (record.pose_failure_count or 0) + 1
    record.pose_failure_count = failures

    -- Tolerate brief UI pose gaps.
    if failures >= POSE_FAILURE_LIMIT then
        record.pose_failed = true
        dirty_contexts[context] = true
    end

    return false
end

local function record_animated_first_person_pose_result(record, ok_pose)
    if ok_pose then
        record.animated_first_person_pose_failure_count = 0
        return true
    end

    local failures = (record.animated_first_person_pose_failure_count or 0) + 1
    record.animated_first_person_pose_failure_count = failures

    if failures >= POSE_FAILURE_LIMIT then
        -- Never sacrifice the valid third-person slot for a first-person proxy
        -- failure. Rebuild only the isolated 1p presentation outside render.
        record.animated_first_person_rebuild_pending = true
    end

    return false
end

function ExtraSlotRuntime.update_pose(world_filter)
    for _, context in pairs(contexts) do
        if not world_filter or context.world == world_filter then
            for _, record in pairs(context.records) do
                if not record.failed and (
                    record.transform_enabled
                    or record.uses_deformation_driver
                    or record.uses_studio_deformation_mirror
                    or record.first_person_animate == true
                ) then
                    local ok_pose = record.visibility_stabilized == true
                    local pose_attempted = false

                    if record.uses_studio_deformation_mirror then
                        pose_attempted = record.visibility_stabilized == true
                        ok_pose = pose_attempted and apply_studio_mirror_pose(record) or false

                        if pose_attempted and not ok_pose then
                            -- Convert the record outside ScriptWorld.render.
                            record.studio_mirror_fallback_pending = true
                            dirty_contexts[context] = true
                        end
                    elseif record.uses_deformation_driver then
                        pose_attempted = record.visibility_stabilized == true
                        ok_pose = pose_attempted and apply_driver_pose(record) or false
                    elseif not context.is_live and record.transform_enabled then
                        if is_persistent_ui_preview_context(context)
                            and record.ui_rigid_render_bypass then
                            -- Keep the spawn transform after a late pose failure.
                        else
                            pose_attempted = record.visibility_stabilized == true
                            ok_pose = pose_attempted and apply_linked_root_pose(record) or false

                            if not ok_pose and is_persistent_ui_preview_context(context) then
                                record.ui_rigid_render_bypass = true
                                record.pose_failure_count = 0
                                record.pose_failed = nil
                                pose_attempted = false
                                ok_pose = true
                            end
                        end
                    end

                    if pose_attempted then
                        record_pose_result(context, record, ok_pose)
                    end

                    if context.is_live and record.first_person_animate == true
                        and safe_unit_alive(record.animated_first_person_driver_unit) then
                        record_animated_first_person_pose_result(
                            record,
                            apply_animated_first_person_driver_pose(record)
                        )
                    end
                end
            end
        end
    end
end

local function record_roots_alive(record)
    return record and (
        safe_unit_alive(record.root_unit)
        or safe_unit_alive(record.first_person_root_unit)
        or safe_unit_alive(record.animated_first_person_root_unit)
        or safe_unit_alive(record.animated_first_person_driver_unit)
    )
end

local function advance_tracker(tracker, context, dt)
    tracker.age_frames = tracker.age_frames + 1

    local changed = false
    local finished = false

    if not tracker.initial_complete then
        local initial_changed, done = run_physics_tracker(tracker)
        changed = initial_changed

        if done then
            tracker.initial_complete = true
            tracker.maintenance_elapsed = 0

            finished = tracker.maintenance_required ~= true
        end
    else
        tracker.maintenance_elapsed = (tracker.maintenance_elapsed or 0) + dt

        if tracker.maintenance_elapsed >= PHYSICS_MAINTENANCE_INTERVAL then
            tracker.maintenance_elapsed = 0
            changed = maintain_physics_tracker(tracker)
        end
    end

    local record = tracker.record

    if changed and record then
        record.update_units = collect_update_units(record)

        if safe_unit_alive(record.first_person_root_unit) then
            configure_first_person_render_hierarchy(
                record.first_person_root_unit,
                record.first_person_attachment_map,
                true
            )
        end

        if safe_unit_alive(record.animated_first_person_root_unit) then
            configure_first_person_render_hierarchy(
                record.animated_first_person_root_unit,
                record.animated_first_person_attachment_map,
                false
            )
        end

        if context and context.is_live then
            set_record_perspective_visibility(record, context.first_person_mode, true)
        end
    end

    return finished
end

local function apply_first_person_visual_to_record(context, record, visual)
    record.first_person_root_unit = visual.root_unit
    record.first_person_attachment_map = visual.attachment_map or {}
    record.first_person_item_name_by_unit = visual.item_name_by_unit or {}
    record.first_person_root_baseline = visual.root_baseline
    record.first_person_attach_node = visual.attach_node
    record.first_person_pending = nil
    record.first_person_retry_elapsed = 0
    record.first_person_retry_count = 0
    record.first_person_retry_exhausted = nil
    record.first_person_error_reported = nil
    record.first_person_error = nil

    capture_record_parent_children(record)
    track_record_deletion_roots(record)
    record.update_units = collect_update_units(record)
    record.physics_tracker = neutralize_record_physics(record)
    stabilize_transformed_visibility(record)
    apply_opacity_to_units(collect_record_units(record), record.opacity)
    set_record_perspective_visibility(record, context.first_person_mode, true)
    refresh_context_activity(context)
end

local function apply_animated_first_person_visual_to_record(context, record, visual)
    record.animated_first_person_root_unit = visual.root_unit
    record.animated_first_person_attachment_map = visual.attachment_map or {}
    record.animated_first_person_item_name_by_unit = visual.item_name_by_unit or {}
    record.animated_first_person_root_baseline = visual.root_baseline
    record.animated_first_person_driver_unit = visual.driver_unit
    record.animated_first_person_driver_node_pairs = visual.driver_node_pairs
    record.animated_first_person_driver_transform = visual.driver_transform
    record.animated_first_person_driver_runtime_transform = nil
    record.animated_first_person_update_units = nil
    record.animated_first_person_driver_required = visual.driver_unit ~= nil
    record.animated_first_person_pose_failure_count = 0
    record.animated_first_person_rebuild_pending = nil
    record.first_person_pending = nil
    record.first_person_retry_elapsed = 0
    record.first_person_retry_count = 0
    record.first_person_retry_exhausted = nil
    record.first_person_error_reported = nil
    record.first_person_error = nil

    capture_record_parent_children(record)
    track_record_deletion_roots(record)
    record.update_units = collect_update_units(record)
    record.physics_tracker = neutralize_record_physics(record)
    configure_first_person_render_hierarchy(
        record.animated_first_person_root_unit,
        record.animated_first_person_attachment_map,
        false
    )
    stabilize_transformed_visibility(record)
    apply_opacity_to_units(collect_record_units(record), record.opacity)
    set_record_perspective_visibility(record, context.first_person_mode, true)
    refresh_context_activity(context)
end

local function clear_animated_first_person_visual(record)
    if not record then
        return
    end

    destroy_units({
        world = record.world,
        unit_spawner = record.unit_spawner,
        package_record = record.package_record,
        root_unit = record.animated_first_person_root_unit,
        attachment_map = record.animated_first_person_attachment_map or {},
        driver_unit = record.animated_first_person_driver_unit,
    })

    record.animated_first_person_root_unit = nil
    record.animated_first_person_attachment_map = {}
    record.animated_first_person_item_name_by_unit = {}
    record.animated_first_person_root_baseline = nil
    record.animated_first_person_driver_unit = nil
    record.animated_first_person_driver_node_pairs = nil
    record.animated_first_person_driver_transform = nil
    record.animated_first_person_driver_runtime_transform = nil
    record.animated_first_person_update_units = nil
    record.animated_first_person_driver_required = false
    record.animated_first_person_pose_failure_count = 0
    record.animated_first_person_rebuild_pending = nil
    record.update_units = collect_update_units(record)
end

local function retry_first_person_visual(context, record, dt)
    if not context or not context.is_live or not record
        or record.first_person_pending ~= true then
        return
    end

    local animated = record.first_person_animate == true and record.raw_unit ~= true

    if not safe_unit_alive(context.parent_unit)
        or not animated and not safe_unit_alive(context.first_person_unit) then
        return
    end

    record.first_person_retry_elapsed = (record.first_person_retry_elapsed or 0) + dt

    if record.first_person_retry_elapsed < FIRST_PERSON_RETRY_INTERVAL then
        return
    end

    record.first_person_retry_elapsed = 0
    local entry = {
        id = record.id,
        anchor = record.anchor,
        attach_node = record.attach_node,
        variant_state = record.variant_state,
    }
    local visual, err

    if animated then
        visual, err = spawn_animated_first_person_visual(
            context,
            entry,
            record.variant_item,
            record.transform,
            record.first_person_material_entries or {},
            record.driver_unit,
            record.package_record
        )
    else
        visual, err = spawn_first_person_visual(
            context,
            entry,
            record.variant_item,
            record.transform,
            record.first_person_material_entries or {},
            record.package_record
        )
    end

    if visual then
        if animated then
            apply_animated_first_person_visual_to_record(context, record, visual)
        else
            apply_first_person_visual_to_record(context, record, visual)
        end

        return
    end

    record.first_person_error = err
    record.first_person_retry_count = (record.first_person_retry_count or 0) + 1

    if record.first_person_retry_count >= FIRST_PERSON_RETRY_LIMIT then
        record.first_person_pending = nil
        record.first_person_retry_exhausted = true

        if not record.first_person_error_reported then
            record.first_person_error_reported = true
            mod:error(
                "Extra slot %s first-person visual failed after %d attempts: %s",
                tostring(record.id),
                record.first_person_retry_count,
                tostring(err or "unknown error")
            )
        end
    end
end

function ExtraSlotRuntime.has_update_work()
    local live_context = contexts[LIVE_CONTEXT]

    return #deferred_package_releases > 0
        or next(raw_equipment_records) ~= nil
        or next(physics_contexts) ~= nil
        or next(dirty_contexts) ~= nil
        or live_context ~= nil and next(live_context.records) ~= nil
end

function ExtraSlotRuntime.update(dt)
    dt = math.max(tonumber(dt) or 0, 0)

    local live_context = contexts[LIVE_CONTEXT]
    local first_person_extension = live_context and live_context.first_person_extension
    local is_in_first_person_mode = first_person_extension
        and first_person_extension.is_in_first_person_mode

    if type(is_in_first_person_mode) == "function" then
        local ok_mode, first_person_mode = pcall(
            is_in_first_person_mode,
            first_person_extension
        )

        if ok_mode and type(first_person_mode) == "boolean"
            and live_context.first_person_mode ~= first_person_mode then
            live_context.first_person_mode = first_person_mode
            apply_context_first_person_visibility(live_context)
        end
    end

    if live_context then
        for _, record in pairs(live_context.records) do
            if record.animated_first_person_rebuild_pending then
                clear_animated_first_person_visual(record)
                record.first_person_pending = record.first_person_enabled == true
                    and record.first_person_animate == true and record.raw_unit ~= true
                record.first_person_retry_elapsed = 0
                record.first_person_retry_count = 0
                record.first_person_retry_exhausted = nil
                record.first_person_error_reported = nil
            end

            retry_first_person_visual(live_context, record, dt)
        end
    end

    update_deferred_package_releases()

    for tracker in pairs(raw_equipment_records) do
        if not record_roots_alive(tracker.record) then
            raw_equipment_records[tracker] = nil
        else
            advance_tracker(tracker, nil, dt)
        end
    end

    for context in pairs(physics_contexts) do
        local completed = false

        for record in pairs(context.physics_records) do
            local tracker = record.physics_tracker

            if not tracker or not record_roots_alive(record) then
                record.physics_tracker = nil
                completed = true
            elseif advance_tracker(tracker, context, dt) then
                record.physics_tracker = nil
                completed = true
            end
        end

        if completed then
            refresh_context_activity(context)
        end
    end

    -- Render only applies cached poses. Complete cache setup and destructive
    -- fallback transitions here, outside ScriptWorld.render.
    for _, context in pairs(contexts) do
        for _, record in pairs(context.records) do
            if not record.failed and not record.visibility_stabilized then
                stabilize_transformed_visibility(record)
            end

            if not record.failed and record.studio_mirror_fallback_pending then
                record.studio_mirror_fallback_pending = nil

                if fallback_studio_mirror_pose(record, record.transform) then
                    record.pose_failure_count = 0
                    record.pose_failed = nil
                    record.update_units = collect_update_units(record)
                    stabilize_transformed_visibility(record)
                else
                    record.pose_failed = true
                    dirty_contexts[context] = true
                end
            end
        end
    end

    for context in pairs(dirty_contexts) do
        dirty_contexts[context] = nil

        local failed_ids = {}

        for id, record in pairs(context.records) do
            if record.pose_failed then
                failed_ids[#failed_ids + 1] = id
            end
        end

        for i = 1, #failed_ids do
            remove_extra_slot(context, failed_ids[i], 0)
        end

        refresh_context_activity(context)
        discard_empty_context(context)
    end

    live_health_elapsed = live_health_elapsed + dt

    if live_health_elapsed >= LIVE_HEALTH_INTERVAL then
        live_health_elapsed = 0

        local context = contexts[LIVE_CONTEXT]

        if context then
            local invalid_ids = {}

            for id, record in pairs(context.records) do
                if not record.failed then
                    local core_invalid = not safe_unit_alive(record.root_unit)
                        or not safe_unit_alive(record.parent_unit)
                        or record.uses_deformation_driver
                            and not safe_unit_alive(record.driver_unit)
                        or record.uses_studio_deformation_mirror
                            and not safe_unit_alive(record.pose_source_unit)

                    if core_invalid then
                        invalid_ids[#invalid_ids + 1] = id
                    elseif record.first_person_enabled
                        and record.first_person_pending ~= true
                        and record.first_person_retry_exhausted ~= true then
                        if record.first_person_animate == true and record.raw_unit ~= true then
                            local animated_invalid = not safe_unit_alive(
                                record.animated_first_person_root_unit
                            ) or record.animated_first_person_driver_required
                                and not safe_unit_alive(record.animated_first_person_driver_unit)

                            if animated_invalid then
                                record.animated_first_person_rebuild_pending = true
                            end
                        elseif not safe_unit_alive(record.first_person_root_unit) then
                            -- A lost 1p-only presentation should never destroy the
                            -- healthy 3p slot. Retry it independently.
                            record.first_person_pending = true
                            record.first_person_retry_elapsed = 0
                            record.first_person_retry_count = 0
                            record.first_person_retry_exhausted = nil
                            record.first_person_error_reported = nil
                        end
                    end
                end
            end

            for i = 1, #invalid_ids do
                remove_extra_slot(context, invalid_ids[i], 0)
            end

            if #invalid_ids > 0 then
                refresh_context_activity(context)

                if type(mod.npclook_schedule_reapply) == "function" then
                    mod.npclook_schedule_reapply()
                end
            end
        end
    end
end

ExtraSlotRuntime.is_parent_material_item = is_parent_material_item

function ExtraSlotRuntime.release_all()
    for i = #deferred_package_releases, 1, -1 do
        release_package_record(deferred_package_releases[i].record)
        deferred_package_releases[i] = nil
    end

    local owners = table.keys(contexts)
    local unit_spawners = {}

    for _, context in pairs(contexts) do
        if context.unit_spawner then
            unit_spawners[context.unit_spawner] = true
        end
    end

    for i = 1, #owners do
        ExtraSlotRuntime.clear_context(owners[i], 0)
    end

    for unit, owned in pairs(owned_visual_units) do
        local owner_record = owned_visual_records[unit]
        local externally_managed = owner_record and owner_record.externally_managed == true

        if owned and not externally_managed and not deletion_pending[unit] and safe_unit_alive(unit) then
            local unit_spawner = owned_visual_spawners[unit]

            if unit_spawner then
                unit_spawners[unit_spawner] = true
            end

            destroy_units({
                world = safe_unit_world(unit),
                unit_spawner = unit_spawner,
                package_record = owner_record and owner_record.package_record,
                root_unit = unit,
                attachment_map = {},
            })
        end
    end

    for unit_spawner in pairs(unit_spawners) do
        local flush = unit_spawner.commit_and_remove_pending_units
            or unit_spawner.remove_pending_units

        if type(flush) == "function" then
            pcall(flush, unit_spawner)
        end
    end

    table.clear(contexts_by_parent)
    table.clear(raw_equipment_records)
    table.clear(deletion_pending)
    table.clear(managed_deletion_roots)
    table.clear(owned_visual_units)
    table.clear(owned_visual_spawners)
    table.clear(owned_visual_parents)
    table.clear(owned_visual_children)
    table.clear(owned_visual_records)
    table.clear(physics_contexts)
    table.clear(dirty_contexts)
    live_health_elapsed = 0
end

function ExtraSlotRuntime.begin_shutdown()
    -- This must run before any visual teardown. Removing a unit can queue package
    -- retirement, and a hot reload may continue PackageManager updates before the
    -- replacement mod instance has loaded.
    suppress_package_unload = true
end

function ExtraSlotRuntime.shutdown()
    ExtraSlotRuntime.begin_shutdown()
    ExtraSlotRuntime.release_all()
end

rawset(mod, "npclook_extra_slot_runtime", ExtraSlotRuntime)

return ExtraSlotRuntime
