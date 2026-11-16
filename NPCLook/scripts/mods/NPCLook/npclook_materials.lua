local mod = get_mod("NPCLook")

local MaterialSchema = {}
local MATERIAL_TARGET_SEPARATOR = "\29"
local MATERIAL_ITEM_TARGET_PREFIX = "@item:"
local MATERIAL_OVERRIDE_LIMIT = 32
local MATERIAL_OVERRIDE_FIELDS = {
    "scalar_material_overrides",
    "vector2_material_overrides",
    "vector3_material_overrides",
    "vector4_material_overrides",
    "texture_material_overrides",
    "textures_material_overrides_by_items",
    "material_overrides",
}
local reported_errors = {}

local function first_error(current, value)
    return current or (value ~= nil and tostring(value) or nil)
end

function MaterialSchema.install(namespace, dependencies)
    dependencies = dependencies or {}

    local item_cache = dependencies.item_cache or function()
        return {}
    end
    local valid_look_slot = dependencies.valid_look_slot or function()
        return false
    end
    local safe_unit_alive = dependencies.safe_unit_alive or function(unit)
        return unit ~= nil
    end
    local ensure_item = dependencies.ensure_item or function()
        return nil
    end
    namespace.material_target_all = ""

    -- Custom asset overrides are created on demand next to master items.
    function namespace.material_override_item(cache, item_name)
        return rawget(cache, item_name) or ensure_item(cache, item_name)
    end

    function namespace.is_material_override_item(item)
        if type(item) ~= "table" then
            return false
        end

        for i = 1, #MATERIAL_OVERRIDE_FIELDS do
            local values = item[MATERIAL_OVERRIDE_FIELDS[i]]

            if type(values) == "table" and next(values) ~= nil then
                return true
            end
        end

        return false
    end

    function namespace.material_override_summary(item)
        local slots = {}
        local seen = {}
        local global = false

        for _, field in ipairs({ "texture_material_overrides", "textures_material_overrides_by_items", "material_overrides" }) do
            for _, value in pairs(item[field] or {}) do
                local slot = type(value) == "table" and value.material_slot

                if type(slot) == "string" and slot ~= "" and not seen[slot] then
                    seen[slot] = true
                    slots[#slots + 1] = slot
                elseif slot == nil or slot == "" then
                    global = true
                end
            end
        end

        for _, field in ipairs({
            "scalar_material_overrides",
            "vector2_material_overrides",
            "vector3_material_overrides",
            "vector4_material_overrides",
        }) do
            if type(item[field]) == "table" and next(item[field]) ~= nil then
                global = true
            end
        end

        table.sort(slots)

        if #slots > 0 then
            local summary = table.concat(slots, ", ")
            return global and summary .. " + global" or summary
        end

        return global and "global properties" or "material override"
    end

    function namespace.normalize_material_target(value)
        if type(value) ~= "string" then
            return nil
        end

        value = string.gsub(value, "[%c]", "")
        value = string.gsub(value, "^%s+", "")
        value = string.gsub(value, "%s+$", "")

        local item_name = string.match(value, "^@item:(content/items/.+)$")

        if not item_name or item_name == "" then
            -- Legacy mesh targets are migrated to unrestricted overrides.
            return nil
        end

        return MATERIAL_ITEM_TARGET_PREFIX .. string.sub(item_name, 1, 384)
    end

    function namespace.material_target_parts(value)
        value = namespace.normalize_material_target(value)

        if not value then
            return nil, nil
        end

        return "item", string.sub(value, #MATERIAL_ITEM_TARGET_PREFIX + 1)
    end

    function namespace.material_target_from_item(item_name)
        if type(item_name) ~= "string" or not string.match(item_name, "^content/items/") then
            return nil
        end

        return namespace.normalize_material_target(MATERIAL_ITEM_TARGET_PREFIX .. item_name)
    end

    function namespace.material_target_item_name(value)
        local kind, item_name = namespace.material_target_parts(value)

        return kind == "item" and item_name or nil
    end

    function namespace.material_target_label(value)
        local item_name = namespace.material_target_item_name(value)

        if not item_name then
            return nil
        end

        local item = rawget(item_cache() or {}, item_name)
        local dev_name = item and item.dev_name
        local label = type(dev_name) == "string" and string.match(dev_name, "^%s*(.-)%s*$") or nil

        if not label or label == "" then
            label = string.match(item_name, "([^/]+)$") or item_name
        end

        label = string.gsub(tostring(label), "[_%-]+", " ")
        label = string.gsub(label, "%s+", " ")
        label = string.match(label, "^%s*(.-)%s*$") or ""

        return label ~= "" and string.upper(label) or nil
    end

    function namespace.material_entry_parts(value)
        if type(value) ~= "string" or value == "" then
            return nil, nil
        end

        local separator = string.find(value, MATERIAL_TARGET_SEPARATOR, 1, true)

        if not separator then
            return value, nil
        end

        local item_name = string.sub(value, 1, separator - 1)
        local target = namespace.normalize_material_target(string.sub(value, separator + 1))

        return item_name ~= "" and item_name or nil, target
    end

    function namespace.material_entry(item_name, target)
        if type(item_name) ~= "string" or item_name == "" then
            return nil
        end

        target = namespace.normalize_material_target(target)

        return target and (item_name .. MATERIAL_TARGET_SEPARATOR .. target) or item_name
    end

    function namespace.material_item_name(value)
        local item_name = namespace.material_entry_parts(value)

        return item_name
    end

    function namespace.material_display(value)
        local item_name, target = namespace.material_entry_parts(value)

        if not item_name then
            return tostring(value or "")
        end

        return target and string.format("%s @ %s", item_name, namespace.material_target_label(target) or target)
            or item_name
    end

    function namespace.normalize_materials(value)
        local source = type(value) == "table" and (value.materials or value) or {}
        local cache = item_cache() or {}
        local result = {}
        local seen = {}

        for i = 1, math.min(#source, MATERIAL_OVERRIDE_LIMIT) do
            local item_name, target = namespace.material_entry_parts(source[i])
            local item = item_name and namespace.material_override_item(cache, item_name)
            local entry = item and namespace.material_entry(item_name, target)

            if entry and namespace.is_material_override_item(item) and not seen[entry] then
                seen[entry] = true
                result[#result + 1] = entry
            end
        end

        -- Preserve override order while deduplicating.
        return result
    end

    function namespace.filter_materials_for_targets(value, targets)
        local allowed = {}

        for key, candidate in pairs(type(targets) == "table" and targets or {}) do
            local target = namespace.normalize_material_target(type(key) == "string" and candidate == true and key or candidate)

            if target then
                allowed[target] = true
            end
        end

        local result = {}

        for _, entry in ipairs(namespace.normalize_materials(value)) do
            local _, target = namespace.material_entry_parts(entry)

            if not target or allowed[target] then
                result[#result + 1] = entry
            end
        end

        return result
    end

    function namespace.material_list_signature(value)
        return table.concat(namespace.normalize_materials(value), "\31")
    end

    function namespace.clone_material_map(value)
        local result = {}

        for slot_name, materials in pairs(value or {}) do
            if valid_look_slot(slot_name) then
                local normalized = namespace.normalize_materials(materials)

                if #normalized > 0 then
                    result[slot_name] = normalized
                end
            end
        end

        return result
    end

    function namespace.restore_material_map(destination, value)
        table.clear(destination)

        for slot_name, materials in pairs(namespace.clone_material_map(value)) do
            destination[slot_name] = materials
        end
    end

    function namespace.same_material_maps(left, right)
        local left_map = namespace.clone_material_map(left)
        local right_map = namespace.clone_material_map(right)

        for slot_name, materials in pairs(left_map) do
            if namespace.material_list_signature(materials)
                ~= namespace.material_list_signature(right_map[slot_name]) then
                return false
            end
        end

        for slot_name, materials in pairs(right_map) do
            if namespace.material_list_signature(materials)
                ~= namespace.material_list_signature(left_map[slot_name]) then
                return false
            end
        end

        return true
    end

    function namespace.material_map_signature(value)
        local map = namespace.clone_material_map(value)
        local slots = table.keys(map)
        local parts = {}

        table.sort(slots)

        for i = 1, #slots do
            local slot_name = slots[i]
            parts[#parts + 1] = slot_name .. "=" .. namespace.material_list_signature(map[slot_name])
        end

        return table.concat(parts, "\30")
    end

    local function has_nonempty_material_overrides(item)
        for _, value in pairs(type(item) == "table" and item.material_override_items or {}) do
            if type(value) == "string" and value ~= "" then
                return true
            end
        end

        return false
    end

    local function has_utility_base_gear_rig(value)
        if type(value) == "string" then
            return string.find(value, "base_gear_rig", 1, true) ~= nil
        elseif type(value) == "table" then
            for _, nested in pairs(value) do
                if has_utility_base_gear_rig(nested) then
                    return true
                end
            end
        end

        return false
    end

    function namespace.collect_unit_item_names(maps)
        local result = {}

        for _, map in pairs(maps or {}) do
            for unit, item_name in pairs(map or {}) do
                if safe_unit_alive(unit) and type(item_name) == "string" and item_name ~= "" then
                    result[unit] = item_name
                end
            end
        end

        return result
    end

    function namespace.collect_generated_material_scopes(root_item)
        local scopes = {}
        local seen_items = {}

        local visit_item
        local function visit_attachment_tree(tree)
            for _, attachment in pairs(type(tree) == "table" and tree or {}) do
                if type(attachment) == "table" then
                    visit_item(attachment.item)
                    visit_attachment_tree(attachment.children)
                end
            end
        end

        visit_item = function(item)
            if type(item) ~= "table" or seen_items[item] then
                return
            end

            seen_items[item] = true

            local materials = item.npclook_generated == true
                and namespace.normalize_materials(item.npclook_custom_material_overrides) or {}

            if #materials > 0 and type(item.name) == "string" and item.name ~= "" then
                scopes[#scopes + 1] = {
                    item = item,
                    item_name = item.name,
                    materials = materials,
                }
            end

            visit_attachment_tree(item.attachments)
            visit_attachment_tree(item.children)
        end

        visit_item(root_item)

        return scopes
    end

    function namespace.set_generated_material_scope_lists(scopes, combined)
        for i = 1, #(scopes or {}) do
            local item = scopes[i].item

            if type(item) == "table" then
                local values = combined and item.npclook_combined_material_overrides
                    or item.npclook_authored_material_overrides

                if type(values) == "table" then
                    item.material_override_items = values
                end
            end
        end
    end

    function namespace.collect_material_scope_units(root_item_names, roots, attachment_maps, unit_item_names)
        local units = {}
        local seen = {}

        local function add(unit)
            if not safe_unit_alive(unit) or seen[unit] then
                return
            end

            seen[unit] = true
            units[#units + 1] = unit

            local ok_children, children = pcall(Unit.get_child_units, unit)

            if ok_children then
                for _, child in pairs(children or {}) do
                    add(child)
                end
            end
        end

        local matched_root = false

        for unit, item_name in pairs(unit_item_names or {}) do
            if root_item_names and root_item_names[item_name] then
                matched_root = true
                add(unit)

                for _, attachment_map in pairs(attachment_maps or {}) do
                    for _, attachment_unit in ipairs((attachment_map or {})[unit] or {}) do
                        add(attachment_unit)
                    end
                end
            end
        end

        if not matched_root then
            for _, root in pairs(roots or {}) do
                local item_name = unit_item_names and unit_item_names[root]

                if root_item_names and item_name and root_item_names[item_name] then
                    add(root)
                end
            end
        end

        return units
    end

    function namespace.material_targets_from_item_maps(maps, root_item_names, attachment_maps)
        local cache = item_cache() or {}
        local unit_item_names = namespace.collect_unit_item_names(maps)
        local scoped_units = namespace.collect_material_scope_units(
            root_item_names,
            {},
            attachment_maps,
            unit_item_names
        )
        local result = {}
        local seen = {}

        for i = 1, #scoped_units do
            local item_name = unit_item_names[scoped_units[i]]
            local item = item_name and rawget(cache, item_name)
            local include = type(item_name) == "string" and string.match(item_name, "^content/items/") ~= nil

            if include and type(item) == "table" and root_item_names and root_item_names[item_name] then
                local attachments = item.attachments

                -- Exclude invisible base-gear attachment hosts from material targets.
                if type(attachments) == "table" and next(attachments) ~= nil
                    and not has_nonempty_material_overrides(item)
                    and has_utility_base_gear_rig(item.base_unit) then
                    include = false
                end
            end

            if include and not seen[item_name] then
                local target = namespace.material_target_from_item(item_name)

                if target then
                    seen[item_name] = true
                    result[#result + 1] = target
                end
            end
        end

        table.sort(result, function(left, right)
            local left_label = namespace.material_target_label(left) or left
            local right_label = namespace.material_target_label(right) or right

            if left_label ~= right_label then
                return left_label < right_label
            end

            return left < right
        end)

        -- Keep a single detected component visible to confirm item mapping.
        return result
    end

    function namespace.apply_material_entry(
            unit, parent_unit, apply_to_parent, entry, in_editor, definitions, item_manager, unit_item_names)
        local item_name, target = namespace.material_entry_parts(entry)

        if not item_name then
            return false, 0, "invalid material override entry"
        end

        local actual_item_name = unit_item_names and unit_item_names[unit]

        if not actual_item_name and unit then
            local ok_data, stored_name = pcall(Unit.get_data, unit, "attachment_item_name")

            if ok_data and type(stored_name) == "string" and stored_name ~= "" then
                actual_item_name = stored_name
            end
        end

        local target_item_name = target and namespace.material_target_item_name(target)

        if target_item_name and actual_item_name ~= target_item_name then
            return false, 0
        end

        if actual_item_name and type(Unit.set_data) == "function" then
            -- Darktide reads this item name for item-scoped texture overrides.
            pcall(Unit.set_data, unit, "attachment_item_name", actual_item_name)
        end

        local ok, error_message = pcall(
            namespace.visual_loadout_customization.apply_material_override_item,
            unit,
            parent_unit,
            target_item_name and false or apply_to_parent,
            item_name,
            in_editor,
            definitions,
            item_manager
        )

        return ok, ok and 1 or 0, not ok and error_message or nil
    end

    function namespace.apply_generated_material_scopes_to_slot(slot, root_item, definitions, item_manager, context)
        local scopes = namespace.collect_generated_material_scopes(root_item)

        if #scopes == 0 then
            return scopes, true, 0
        end

        local roots = {
            slot and slot.unit_3p,
            slot and slot.unit_1p,
        }
        local attachment_maps = {
            slot and slot.attachments_by_unit_3p,
            slot and slot.attachments_by_unit_1p,
        }
        local unit_item_names = namespace.collect_unit_item_names({
            slot and slot.item_name_by_unit_3p,
            slot and slot.item_name_by_unit_1p,
        })
        local all_applied = true
        local applied_total = 0

        for i = 1, #scopes do
            local scope = scopes[i]
            local scope_units = namespace.collect_material_scope_units(
                { [scope.item_name] = true },
                roots,
                attachment_maps,
                unit_item_names
            )
            local applied, count = namespace.apply_material_entries_to_units(
                scope_units,
                nil,
                false,
                scope.materials,
                false,
                definitions,
                item_manager,
                string.format("%s component %s", tostring(context or "material"), scope.item_name),
                unit_item_names
            )

            all_applied = applied and all_applied
            applied_total = applied_total + (tonumber(count) or 0)
        end

        return scopes, all_applied, applied_total
    end

    function namespace.report_material_error(entry, context, error_message)
        local key = table.concat({
            tostring(context or "material"),
            tostring(entry or ""),
            tostring(error_message or ""),
        }, "\31")

        if reported_errors[key] then
            return
        end

        reported_errors[key] = true
        mod:error(
            "Material override failed (%s, %s): %s",
            tostring(context or "unknown context"),
            namespace.material_display(entry),
            tostring(error_message or "no compatible material property was applied")
        )
    end

    function namespace.collect_units(roots, attachment_maps)
        local units = {}
        local seen = {}

        local function add(unit)
            if not safe_unit_alive(unit) or seen[unit] then
                return
            end

            seen[unit] = true
            units[#units + 1] = unit

            local ok_children, children = pcall(Unit.get_child_units, unit)

            if ok_children then
                for _, child in pairs(children or {}) do
                    add(child)
                end
            end
        end

        for i = 1, #(roots or {}) do
            add(roots[i])
        end

        for i = 1, #(attachment_maps or {}) do
            for base_unit, attachments in pairs(attachment_maps[i] or {}) do
                add(base_unit)

                for j = 1, #(attachments or {}) do
                    add(attachments[j])
                end
            end
        end

        return units
    end

    function namespace.apply_material_entries_to_units(
            units, parent_unit, apply_to_parent, entries, in_editor, definitions, item_manager, context, unit_item_names)
        entries = namespace.normalize_materials(entries)
        definitions = definitions or item_cache() or {}

        local all_applied = true
        local applied_total = 0

        for entry_index = 1, #entries do
            local entry = entries[entry_index]
            local found = false
            local applied_count = 0
            local error_message

            for unit_index = 1, #(units or {}) do
                local ok, entry_found, entry_applied, entry_error = pcall(
                    namespace.apply_material_entry,
                    units[unit_index],
                    parent_unit,
                    apply_to_parent,
                    entry,
                    in_editor,
                    definitions,
                    item_manager,
                    unit_item_names
                )

                if not ok then
                    error_message = first_error(error_message, entry_found)
                else
                    found = entry_found or found
                    applied_count = applied_count + (tonumber(entry_applied) or 0)
                    error_message = first_error(error_message, entry_error)
                end
            end

            local _, target = namespace.material_entry_parts(entry)
            local dormant_target = target and not found and applied_count == 0 and not error_message

            -- Missing component targets stay dormant instead of broadening the override.
            if not dormant_target and (error_message or applied_count == 0) then
                all_applied = false
                namespace.report_material_error(
                    entry,
                    context,
                    error_message or (target and "target item was not spawned"
                        or found and "no compatible property was applied"
                        or "material unit was not found")
                )
            end

            applied_total = applied_total + applied_count
        end

        return all_applied, applied_total
    end

    return namespace
end

return MaterialSchema
