local Masks = {}

local FIELD_SPECS = {
    {
        name = "mask_hair_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_hair_headgear_mask",
        root = "content/items/material_overrides/player_hair_headgear_mask/",
        prefixes = { "hair_", "ogryn_hair_" },
        reset = "content/items/material_overrides/player_hair_headgear_mask/hair_no_mask",
    },
    {
        name = "mask_facial_hair_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_hair_headgear_mask",
        root = "content/items/material_overrides/player_hair_headgear_mask/",
        prefixes = { "facial_hair_", "ogryn_facial_hair_" },
        reset = "content/items/material_overrides/player_hair_headgear_mask/facial_hair_no_mask",
    },
    {
        name = "mask_hair_override",
        kind = "table",
        visible = false,
    },
    {
        name = "mask_face_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_face_mask",
        root = "content/items/material_overrides/player_face_mask/",
        prefixes = { "mask_face_" },
        reset = "content/items/material_overrides/player_face_mask/mask_face_none",
    },
    {
        name = "mask_face_accessory_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_face_mask",
        root = "content/items/material_overrides/player_face_mask/",
        prefixes = { "mask_accessory_" },
        reset = "content/items/material_overrides/player_face_mask/mask_accessory_none",
    },
    {
        name = "hide_eyebrows",
        kind = "boolean",
    },
    {
        name = "mask_torso_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_base_body_mask",
        root = "content/items/material_overrides/player_base_body_mask/",
        prefixes = { "mask_torso_" },
        reset = "content/items/material_overrides/player_base_body_mask/mask_default",
    },
    {
        name = "mask_arms_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_base_body_mask",
        root = "content/items/material_overrides/player_base_body_mask/",
        prefixes = { "mask_arms_", "mask_hands", "mask_upperarms", "mask_half_upperarms" },
        reset = "content/items/material_overrides/player_base_body_mask/mask_default",
    },
    {
        name = "mask_legs_item",
        kind = "string",
        catalog = "scripts/settings/equipment/item_material_overrides/player_material_overrides_base_body_mask",
        root = "content/items/material_overrides/player_base_body_mask/",
        prefixes = { "mask_legs", "mask_feet" },
        reset = "content/items/material_overrides/player_base_body_mask/mask_default",
    },
}

local SLOT_FIELDS = {
    slot_gear_head = {
        "mask_hair_item",
        "mask_facial_hair_item",
        "hide_eyebrows",
    },
    slot_gear_upperbody = {
        "mask_torso_item",
        "mask_arms_item",
    },
    slot_gear_lowerbody = {
        "mask_legs_item",
    },
}

local LEGACY_FIELD_NAMES = {
    mask_hair_item = "mask_hair",
    mask_facial_hair_item = "mask_facial_hair",
    mask_face_item = "mask_face",
    mask_face_accessory_item = "mask_face_accessory",
    mask_torso_item = "mask_torso",
    mask_arms_item = "mask_arms",
    mask_legs_item = "mask_legs",
}

local FIELD_HIDDEN_SLOTS = {
    mask_hair_item = "slot_body_hair",
    mask_facial_hair_item = "slot_body_face_hair",
    mask_torso_item = "slot_body_torso",
    mask_arms_item = "slot_body_arms",
    mask_legs_item = "slot_body_legs",
}

local FIELD_ORDER = {}
local VISIBLE_FIELD_ORDER = {}
local FIELD_BY_NAME = {}

for i = 1, #FIELD_SPECS do
    local spec = FIELD_SPECS[i]

    FIELD_ORDER[i] = spec.name
    FIELD_BY_NAME[spec.name] = spec

    if spec.visible ~= false then
        VISIBLE_FIELD_ORDER[#VISIBLE_FIELD_ORDER + 1] = spec.name
    end
end

local CATALOG_CACHE = {}
local CANDIDATE_CACHE = setmetatable({}, { __mode = "k" })
local FIELD_CACHE = setmetatable({}, { __mode = "k" })
local AUTHORED_CACHE = setmetatable({}, { __mode = "k" })
local OPTION_CACHE = setmetatable({}, { __mode = "k" })

local function clone_value(value, depth, seen)
    if type(value) ~= "table" then
        return value
    elseif depth > 12 then
        return {}
    end

    seen = seen or {}

    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy

    for key, child in pairs(value) do
        copy[clone_value(key, depth + 1, seen)] = clone_value(child, depth + 1, seen)
    end

    return copy
end

local function has_value(value)
    local value_type = type(value)

    if value_type == "string" then
        return value ~= ""
    elseif value_type == "table" then
        return next(value) ~= nil
    end

    return value ~= nil
end

local function array_contains(values, wanted)
    for i = 1, #(type(values) == "table" and values or {}) do
        if values[i] == wanted then
            return true
        end
    end

    return false
end

local function remove_array_value(values, unwanted)
    if type(values) ~= "table" then
        return values
    end

    local result = {}

    for i = 1, #values do
        if values[i] ~= unwanted then
            result[#result + 1] = values[i]
        end
    end

    return result
end

local function explicit_fields(state)
    return type(state) == "table" and type(state.fields) == "table"
        and state.fields or nil
end

function Masks.filtered_hide_slots(hide_slots, state)
    local fields = explicit_fields(state)
    local overridden_slots = {}
    local result = {}

    if fields then
        for field, slot_name in pairs(FIELD_HIDDEN_SLOTS) do
            if fields[field] ~= nil then
                overridden_slots[slot_name] = true
            end
        end
    end

    for i = 1, #(type(hide_slots) == "table" and hide_slots or {}) do
        local slot_name = hide_slots[i]

        if not overridden_slots[slot_name] then
            result[#result + 1] = slot_name
        end
    end

    return result
end

local function resolve_item(reference, definitions)
    if type(reference) == "table" then
        return reference
    elseif type(reference) == "string" and type(definitions) == "table" then
        return rawget(definitions, reference)
    end
end

local function normalized_item_field(item, field)
    if type(item) ~= "table" then
        return nil
    end

    local value = item[field]

    if value == nil then
        value = item[LEGACY_FIELD_NAMES[field]]
    end

    local spec = FIELD_BY_NAME[field]

    if type(value) == "string" and value ~= "" and spec and spec.root
        and not string.find(value, "/", 1, true) then
        value = spec.root .. value
    end

    return value
end

local visit_item

local function visit_tree(tree, definitions, result, visited, depth)
    if type(tree) ~= "table" or depth > 24 then
        return
    end

    for _, entry in pairs(tree) do
        if type(entry) == "table" then
            visit_item(entry.item, definitions, result, visited, depth + 1)
            visit_tree(entry.children, definitions, result, visited, depth + 1)
        end
    end
end

visit_item = function(reference, definitions, result, visited, depth)
    if depth > 24 then
        return
    end

    local item = resolve_item(reference, definitions)

    if type(item) ~= "table" or visited[item] then
        return
    end

    visited[item] = true

    for i = 1, #VISIBLE_FIELD_ORDER do
        local field = VISIBLE_FIELD_ORDER[i]

        if has_value(normalized_item_field(item, field)) then
            result[field] = true
        end
    end

    visit_tree(item.attachments, definitions, result, visited, depth)
    visit_tree(item.children, definitions, result, visited, depth)
end

local function uncached_available_fields(item, definitions, slot_name)
    local found = {}
    local result = {}

    visit_item(item, definitions, found, {}, 0)

    for i = 1, #(SLOT_FIELDS[slot_name] or {}) do
        found[SLOT_FIELDS[slot_name][i]] = true
    end

    for i = 1, #FIELD_ORDER do
        local field = FIELD_ORDER[i]

        if found[field] then
            result[#result + 1] = field
        end
    end

    return result
end

function Masks.available_fields(item, definitions, slot_name)
    if type(item) ~= "table" then
        return {}
    end

    local item_name = item.name
    local cache_item = type(item_name) == "string" and type(definitions) == "table"
        and rawget(definitions, item_name) or nil

    if cache_item ~= item then
        return uncached_available_fields(item, definitions, slot_name)
    end

    local by_item = FIELD_CACHE[definitions]

    if not by_item then
        by_item = setmetatable({}, { __mode = "k" })
        FIELD_CACHE[definitions] = by_item
    end

    local by_slot = by_item[item]

    if not by_slot then
        by_slot = {}
        by_item[item] = by_slot
    end

    local cache_key = tostring(slot_name or "")
    local fields = by_slot[cache_key]

    if not fields then
        fields = uncached_available_fields(item, definitions, slot_name)
        by_slot[cache_key] = fields
    end

    local result = {}

    for i = 1, #fields do
        result[i] = fields[i]
    end

    return result
end

local function valid_override(spec, value)
    if spec.kind == "boolean" then
        return type(value) == "boolean"
    elseif spec.kind == "string" then
        return value == false or type(value) == "string" and value ~= ""
    elseif spec.kind == "table" then
        return value == false
    end

    return false
end

function Masks.normalize_state(state, item_name, available_fields)
    local result = {
        item_name = item_name,
        fields = {},
    }
    local allowed

    if type(available_fields) == "table" then
        allowed = {}

        for i = 1, #available_fields do
            allowed[available_fields[i]] = true
        end
    end

    if type(state) == "table" and (state.item_name == nil or state.item_name == item_name) then
        local source = type(state.fields) == "table" and state.fields or state

        for field, value in pairs(source) do
            local spec = FIELD_BY_NAME[field]

            if spec and valid_override(spec, value) and (not allowed or allowed[field]) then
                result.fields[field] = clone_value(value, 0)
            end
        end
    end

    return result
end

local function configured_value(spec, value)
    if value ~= false then
        return clone_value(value, 0)
    elseif spec.kind == "boolean" then
        return false
    elseif spec.kind == "string" then
        return spec.reset
    elseif spec.kind == "table" then
        return {}
    end
end

function Masks.configured_value(field, value)
    local spec = FIELD_BY_NAME[field]

    return spec and configured_value(spec, value) or nil
end

function Masks.configure_item(item, state, allow_new_fields)
    local fields = explicit_fields(state)

    if type(item) ~= "table" or not fields then
        return
    end

    for field, hidden_slot in pairs(FIELD_HIDDEN_SLOTS) do
        if fields[field] ~= nil and array_contains(item.hide_slots, hidden_slot) then
            rawset(item, "hide_slots", remove_array_value(item.hide_slots, hidden_slot))
        end
    end

    if fields.mask_hair_item ~= nil
        and (allow_new_fields or item.mask_hair_override ~= nil) then
        rawset(item, "mask_hair_override", {})
    end

    for field, value in pairs(fields) do
        local spec = FIELD_BY_NAME[field]
        local legacy_field = LEGACY_FIELD_NAMES[field]
        local field_exists = item[field] ~= nil or legacy_field and item[legacy_field] ~= nil

        if spec and (allow_new_fields or field_exists) then
            rawset(item, field, configured_value(spec, value))

            if legacy_field and item[legacy_field] ~= nil then
                rawset(item, legacy_field, nil)
            end
        end
    end
end

local function stable_value(value)
    local value_type = type(value)

    if value_type == "boolean" then
        return value and "b:1" or "b:0"
    elseif value_type == "string" then
        return "s:" .. value
    end

    return value_type .. ":" .. tostring(value)
end

function Masks.signature(state)
    local fields = {}
    local item_name = type(state) == "table" and tostring(state.item_name or "") or ""
    local source = type(state) == "table" and type(state.fields) == "table" and state.fields or {}

    for field, value in pairs(source) do
        local spec = FIELD_BY_NAME[field]

        if spec and valid_override(spec, value) then
            fields[#fields + 1] = field .. "=" .. stable_value(value)
        end
    end

    table.sort(fields)

    return item_name .. "\29" .. table.concat(fields, "\30")
end

function Masks.clone_state(state)
    if type(state) ~= "table" then
        return nil
    end

    local copy = Masks.normalize_state(state, state.item_name)

    if next(copy.fields) == nil then
        return nil
    end

    return copy
end

function Masks.clone_map(map)
    local result = {}

    for slot_name, state in pairs(type(map) == "table" and map or {}) do
        local copy = Masks.clone_state(state)

        if copy then
            result[slot_name] = copy
        end
    end

    return result
end

function Masks.same_maps(left, right)
    left = type(left) == "table" and left or {}
    right = type(right) == "table" and right or {}

    for slot_name, state in pairs(left) do
        if Masks.signature(state) ~= Masks.signature(right[slot_name]) then
            return false
        end
    end

    for slot_name, state in pairs(right) do
        if Masks.signature(state) ~= Masks.signature(left[slot_name]) then
            return false
        end
    end

    return true
end

local find_authored_value

local function find_authored_value_in_tree(tree, field, definitions, visited, depth)
    if type(tree) ~= "table" or depth > 24 then
        return nil
    end

    for _, entry in pairs(tree) do
        if type(entry) == "table" then
            local value = find_authored_value(entry.item, field, definitions, visited, depth + 1)

            if value ~= nil then
                return value
            end

            value = find_authored_value_in_tree(entry.children, field, definitions, visited, depth + 1)

            if value ~= nil then
                return value
            end
        end
    end

    return nil
end

find_authored_value = function(reference, field, definitions, visited, depth)
    if depth > 24 then
        return nil
    end

    local item = resolve_item(reference, definitions)

    if type(item) ~= "table" or visited[item] then
        return nil
    end

    visited[item] = true

    local direct_value = normalized_item_field(item, field)

    if has_value(direct_value) then
        return direct_value
    end

    local value = find_authored_value_in_tree(item.attachments, field, definitions, visited, depth)

    if value ~= nil then
        return value
    end

    return find_authored_value_in_tree(item.children, field, definitions, visited, depth)
end

local authored_hides_slot

local function tree_hides_slot(tree, slot_name, definitions, visited, depth)
    if type(tree) ~= "table" or depth > 24 then
        return false
    end

    for _, entry in pairs(tree) do
        if type(entry) == "table" then
            if authored_hides_slot(entry.item, slot_name, definitions, visited, depth + 1)
                or tree_hides_slot(entry.children, slot_name, definitions, visited, depth + 1) then
                return true
            end
        end
    end

    return false
end

authored_hides_slot = function(reference, slot_name, definitions, visited, depth)
    depth = depth or 0
    visited = visited or {}

    if depth > 24 then
        return false
    end

    local item = resolve_item(reference, definitions)

    if type(item) ~= "table" or visited[item] then
        return false
    end

    visited[item] = true

    if array_contains(item.hide_slots, slot_name) then
        return true
    end

    return tree_hides_slot(item.attachments, slot_name, definitions, visited, depth)
        or tree_hides_slot(item.children, slot_name, definitions, visited, depth)
end

local function authored_value(item, field, definitions)
    if type(item) ~= "table" then
        return nil
    end

    local by_item = AUTHORED_CACHE[definitions]

    if not by_item then
        by_item = setmetatable({}, { __mode = "k" })
        AUTHORED_CACHE[definitions] = by_item
    end

    local values = by_item[item]

    if not values then
        values = {}
        by_item[item] = values
    end

    if values[field] == nil then
        local value = find_authored_value(item, field, definitions, {}, 0)

        values[field] = value == nil and false or clone_value(value, 0)
    end

    return values[field] == false and nil or clone_value(values[field], 0)
end

local function ensure_array_value(values, wanted)
    values = type(values) == "table" and values or {}

    if not array_contains(values, wanted) then
        values[#values + 1] = wanted
    end

    return values
end

function Masks.configure_effective_item(item, source, definitions, slot_name, state)
    if type(item) ~= "table" or type(source) ~= "table" then
        return
    end

    local explicit = type(state) == "table" and type(state.fields) == "table"
        and state.fields or {}

    local fields = Masks.available_fields(source, definitions, slot_name)

    for i = 1, #fields do
        local field = fields[i]

        if explicit[field] == nil then
            local value = authored_value(source, field, definitions)

            if value ~= nil then
                rawset(item, field, clone_value(value, 0))

                local legacy_field = LEGACY_FIELD_NAMES[field]

                if legacy_field then
                    rawset(item, legacy_field, nil)
                end
            end
        end
    end

    if slot_name == "slot_gear_head" and explicit.mask_hair_item == nil then
        local override = authored_value(source, "mask_hair_override", definitions)

        if override ~= nil then
            rawset(item, "mask_hair_override", clone_value(override, 0))
        end

        if authored_hides_slot(source, "slot_body_hair", definitions) then
            rawset(item, "hide_slots", ensure_array_value(item.hide_slots, "slot_body_hair"))
        end
    end

    if slot_name == "slot_gear_head" and explicit.hide_beard == nil then
        local hide_beard = authored_value(source, "hide_beard", definitions)

        if hide_beard ~= nil then
            rawset(item, "hide_beard", hide_beard == true)
        end
    end
end

local function candidate_suffix(spec, item_name)
    if not spec.root or string.sub(item_name, 1, #spec.root) ~= spec.root then
        return nil
    end

    local suffix = string.sub(item_name, #spec.root + 1)

    for i = 1, #(spec.prefixes or {}) do
        local prefix = spec.prefixes[i]

        if string.sub(suffix, 1, #prefix) == prefix then
            return suffix, prefix
        end
    end

    return nil
end

local function display_name(suffix, prefix)
    local value = string.sub(suffix, #prefix + 1)

    if value == "" then
        value = string.gsub(prefix, "_+$", "")
    end

    value = string.gsub(value, "^mask_", "")
    value = string.gsub(value, "_", " ")

    return string.upper(value)
end

local function load_catalog(path)
    if type(path) ~= "string" then
        return nil
    end

    local cached = CATALOG_CACHE[path]

    if cached ~= nil then
        return cached or nil
    end

    local ok, result = pcall(require, path)

    CATALOG_CACHE[path] = ok and type(result) == "table" and result or false

    return CATALOG_CACHE[path] or nil
end

local function candidate_breed(item, authored, spec)
    local authored_suffix = type(authored) == "string" and candidate_suffix(spec, authored) or nil

    if authored_suffix then
        return string.sub(authored_suffix, 1, 6) == "ogryn_" and "ogryn" or "human"
    end

    local item_name = type(item) == "table" and tostring(item.name or "") or ""

    return string.find(item_name, "/ogryn/", 1, true) and "ogryn" or "human"
end

local function add_candidate(candidates, seen, spec, definitions, item_name)
    local suffix
    local prefix

    if type(item_name) == "string" then
        suffix, prefix = candidate_suffix(spec, item_name)
    end

    if not suffix or item_name == spec.reset or seen[item_name] then
        return
    end

    if type(definitions) == "table" and type(rawget(definitions, item_name)) ~= "table" then
        return
    end

    seen[item_name] = true
    candidates[#candidates + 1] = {
        breed = string.sub(suffix, 1, 6) == "ogryn_" and "ogryn" or "human",
        label = display_name(suffix, prefix),
        value = item_name,
    }
end

local function field_candidates(spec, definitions)
    if not spec.root or type(definitions) ~= "table" then
        return {}
    end

    local by_field = CANDIDATE_CACHE[definitions]

    if not by_field then
        by_field = {}
        CANDIDATE_CACHE[definitions] = by_field
    end

    local cached = by_field[spec.name]

    if cached then
        return cached
    end

    local candidates = {}
    local seen = {}
    local catalog = load_catalog(spec.catalog)

    if type(catalog) == "table" then
        for key in pairs(catalog) do
            local item_name = tostring(key or "")

            if string.sub(item_name, 1, #spec.root) ~= spec.root then
                item_name = spec.root .. item_name
            end

            add_candidate(candidates, seen, spec, definitions, item_name)
        end
    end

    if #candidates == 0 then
        for key, item in pairs(definitions) do
            local item_name = type(key) == "string" and key
                or type(item) == "table" and item.name or nil

            add_candidate(candidates, seen, spec, definitions, item_name)
        end
    end

    table.sort(candidates, function(a, b)
        if a.label == b.label then
            return a.value < b.value
        end

        return a.label < b.label
    end)

    by_field[spec.name] = candidates

    return candidates
end

local function option_id(value)
    return stable_value(value)
end

local function active_authored_value(spec, value)
    if spec.kind == "boolean" then
        return value == true and true or nil
    elseif spec.kind == "string" then
        return type(value) == "string" and value ~= "" and value ~= spec.reset and value or nil
    elseif spec.kind == "table" then
        return type(value) == "table" and next(value) ~= nil and value or nil
    end
end

local function authored_hair_behavior(item, definitions)
    local has_override = active_authored_value(
        FIELD_BY_NAME.mask_hair_override,
        authored_value(item, "mask_hair_override", definitions)
    ) ~= nil

    return has_override or authored_hides_slot(item, "slot_body_hair", definitions)
end

local function field_options(item, field, definitions)
    local by_item = OPTION_CACHE[definitions]

    if not by_item then
        by_item = setmetatable({}, { __mode = "k" })
        OPTION_CACHE[definitions] = by_item
    end

    local by_field = by_item[item]

    if not by_field then
        by_field = {}
        by_item[item] = by_field
    end

    local cached = by_field[field]

    if cached then
        return cached.options, cached.active_authored, cached.authored_behavior
    end

    local spec = FIELD_BY_NAME[field]
    local authored = authored_value(item, field, definitions)
    local active_authored = active_authored_value(spec, authored)
    local authored_behavior = false

    if field == "mask_hair_item" then
        authored_behavior = authored_hair_behavior(item, definitions)
    end
    local options = {}
    local seen = {}

    if spec.kind == "boolean" then
        options[1] = {
            id = option_id(true),
            label = "HIDE",
            value = true,
        }
    elseif spec.kind == "string" then
        if authored_behavior then
            options[#options + 1] = {
                authored = true,
                id = "authored_override",
                label = "AUTHORED",
            }
        end

        if type(active_authored) == "string" then
            local suffix, prefix = candidate_suffix(spec, active_authored)

            options[#options + 1] = {
                authored = not authored_behavior,
                id = option_id(active_authored),
                label = suffix and display_name(suffix, prefix) or "AUTHORED",
                value = active_authored,
            }
            seen[active_authored] = true
        end

        local breed = candidate_breed(item, authored, spec)

        for _, candidate in ipairs(field_candidates(spec, definitions)) do
            if candidate.breed == breed and not seen[candidate.value] then
                options[#options + 1] = {
                    id = option_id(candidate.value),
                    label = candidate.label,
                    value = candidate.value,
                }
                seen[candidate.value] = true
            end
        end
    elseif spec.kind == "table" and active_authored then
        options[1] = {
            id = "authored",
            label = "AUTHORED",
            value = nil,
        }
    end

    local index_by_id = {}
    local authored_index

    for i = 1, #options do
        index_by_id[options[i].id] = i

        if options[i].authored then
            authored_index = authored_index or i
        end
    end

    options._index_by_id = index_by_id
    options._authored_index = authored_index
    by_field[field] = {
        active_authored = active_authored,
        authored_behavior = authored_behavior,
        options = options,
    }

    return options, active_authored, authored_behavior
end

local function effective_value(state, field, active_authored)
    local fields = type(state) == "table" and type(state.fields) == "table" and state.fields or {}
    local value = fields[field]

    if value ~= nil then
        return value == false and nil or value, value ~= false
    end

    return active_authored, active_authored ~= nil
end

function Masks.rows(item, definitions, slot_name, state)
    definitions = type(definitions) == "table" and definitions or {}

    local fields = Masks.available_fields(item, definitions, slot_name)
    local normalized = Masks.normalize_state(state, item and item.name, fields)
    local rows = {}

    for i = 1, #fields do
        local field = fields[i]
        local spec = FIELD_BY_NAME[field]
        local options, active_authored, authored_behavior = field_options(item, field, definitions)
        local current, enabled = effective_value(normalized, field, active_authored)
        local current_index

        if normalized.fields[field] == nil and authored_behavior then
            enabled = true
            current_index = options._authored_index
        elseif current ~= nil then
            current_index = options._index_by_id[option_id(current)]
        end
        local value_label

        if enabled then
            if spec.kind == "table" then
                value_label = "AUTHORED"
            elseif current_index and options[current_index] then
                value_label = options[current_index].label
            elseif spec.kind == "boolean" then
                value_label = "HIDE"
            else
                value_label = "AUTHORED"
            end
        else
            value_label = "OFF"
        end

        rows[#rows + 1] = {
            field = field,
            can_toggle = enabled or active_authored ~= nil or #options > 0,
            enabled = enabled,
            option_count = #options,
            option_index = current_index or 1,
            options = options,
            value_label = value_label,
        }
    end

    return rows, normalized
end

local function find_row(rows, field)
    for i = 1, #rows do
        if rows[i].field == field then
            return rows[i]
        end
    end
end

local function compact_state(state)
    if type(state) ~= "table" or type(state.fields) ~= "table" or next(state.fields) == nil then
        return nil
    end

    return state
end

function Masks.toggle_field(item, definitions, slot_name, state, field)
    local rows, normalized = Masks.rows(item, definitions, slot_name, state)
    local row = find_row(rows, field)

    if not row then
        return compact_state(normalized)
    end

    local authored = active_authored_value(FIELD_BY_NAME[field], authored_value(item, field, definitions))
    local authored_behavior = field == "mask_hair_item"
        and authored_hair_behavior(item, definitions) or false

    if row.enabled then
        normalized.fields[field] = false
    elseif authored ~= nil or authored_behavior then
        normalized.fields[field] = nil
    elseif row.options[1] then
        normalized.fields[field] = clone_value(row.options[1].value, 0)
    end

    return compact_state(normalized)
end

function Masks.cycle_field(item, definitions, slot_name, state, field, delta)
    local rows, normalized = Masks.rows(item, definitions, slot_name, state)
    local row = find_row(rows, field)

    if not row or not row.enabled or row.option_count <= 1 then
        return compact_state(normalized), false
    end

    local next_index = ((row.option_index - 1 + (tonumber(delta) or 1)) % row.option_count) + 1
    local option = row.options[next_index]

    if option.authored then
        normalized.fields[field] = nil
    else
        normalized.fields[field] = clone_value(option.value, 0)
    end

    return compact_state(normalized), true
end

function Masks.option_matches(field, value, item, definitions, slot_name)
    definitions = type(definitions) == "table" and definitions or {}

    local spec = FIELD_BY_NAME[field]

    if not spec then
        return false
    elseif value == false then
        return true
    elseif spec.kind == "boolean" then
        return value == true
    elseif spec.kind ~= "string" or type(value) ~= "string" or value == "" then
        return false
    end

    local fields = Masks.available_fields(item, definitions, slot_name)
    local found = false

    for i = 1, #fields do
        if fields[i] == field then
            found = true
            break
        end
    end

    if not found then
        return false
    end

    local authored = authored_value(item, field, definitions)

    if value == authored or value == spec.reset then
        return true
    end

    local breed = candidate_breed(item, authored, spec)

    for _, candidate in ipairs(field_candidates(spec, definitions)) do
        if candidate.value == value and candidate.breed == breed then
            return true
        end
    end

    return false
end

function Masks.field_label_key(field)
    return FIELD_BY_NAME[field] and "ui_mask_field_" .. field or nil
end

return Masks
