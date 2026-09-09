local mod = get_mod("NPCLook")
local shared_runtime = rawget(mod, "npclook_raw_units_runtime")

if type(shared_runtime) == "table" then
    return shared_runtime
end

local RawUnits = {}

local REQUIRED_RESOURCE_LOADER_API = 1
local VARIANTS_PATH = "NPCLook/scripts/mods/NPCLook/npclook_raw_unit_variants"
local string_find = string.find
local string_gsub = string.gsub
local string_lower = string.lower
local string_match = string.match
local string_sub = string.sub
local string_upper = string.upper
local table_concat = table.concat
local table_sort = table.sort

local CATEGORY_LABELS = {
    characters = "CHARACTER UNIT",
    environment = "ENVIRONMENT UNIT",
    weapons = "WEAPON UNIT",
    fx = "FX UNIT",
    pickups = "PICKUP UNIT",
    levels = "LEVEL UNIT",
    units = "CORE UNIT",
    gizmos = "GIZMO UNIT",
    debug = "DEBUG UNIT",
    decals = "DECAL UNIT",
    stingray_renderer = "RENDERER UNIT",
    items = "ITEM UNIT",
    liquid_area = "LIQUID UNIT",
    smoke_fog = "FOG UNIT",
    vector_fields = "VECTOR FIELD UNIT",
    vo = "VOICE UNIT",
    editor_slave = "EDITOR UNIT",
    fallback_resources = "FALLBACK UNIT",
    gwnav = "NAVIGATION UNIT",
    volumetrics = "VOLUMETRIC UNIT",
    empty_unit = "CONTENT UNIT",
    content = "CONTENT UNIT",
    core = "CORE UNIT",
    ui = "UI UNIT",
    boot_assets = "BOOT UNIT",
    game_mode = "GAME MODE UNIT",
    live_events = "LIVE EVENT UNIT",
    videos = "VIDEO UNIT",
    packages = "PACKAGE UNIT",
    hashed = "HASHED UNIT",
    unknown = "HASHED UNIT",
}

local registry = {}
local overlay_fallbacks = {}
local state = {
    registry_revision = 0,
    definitions = {},
    package_ready_by_resource = {},
    catalog_loaded = false,
    package_by_resource = {},
    metadata_cache = {},
    variant_metadata = nil,
    catalog_entries = nil,
    catalog_revision = -1,
    installed_cache = nil,
    installed_resources = {},
    resource_loader = nil,
    resource_loader_error = nil,
    resource_loader_checked = false,
    resource_loader_retry_count = 0,
}

local function resource_loader(force_refresh)
    if state.resource_loader then
        return state.resource_loader
    elseif state.resource_loader_checked and not force_refresh then
        state.resource_loader_retry_count = state.resource_loader_retry_count + 1

        if state.resource_loader_retry_count < 60 then
            return nil, state.resource_loader_error
        end
    end

    state.resource_loader_checked = true
    state.resource_loader_retry_count = 0

    local get_mod_function = rawget(_G, "get_mod")
    local loader
    local err

    if type(get_mod_function) ~= "function" then
        err = "Darktide Mod Framework is unavailable"
    else
        local ok, value = pcall(get_mod_function, "ResourceLoader")

        if not ok or type(value) ~= "table" then
            err = "ResourceLoader is not installed or did not load before NPC Look"
        elseif type(value.is_api_compatible) ~= "function"
            or not value.is_api_compatible(REQUIRED_RESOURCE_LOADER_API) then
            err = "ResourceLoader API v1 is required"
        elseif type(value.visit) ~= "function"
            or type(value.resolve) ~= "function"
            or type(value.acquire_package) ~= "function"
            or type(value.release) ~= "function"
            or type(value.status) ~= "function" then
            err = "ResourceLoader 1.1 or newer is required"
        else
            loader = value
        end
    end

    state.resource_loader = loader
    state.resource_loader_error = err

    return loader, err
end

local function normalize_path(value)
    if type(value) ~= "string" then
        return nil
    end

    value = string_gsub(value, "\\", "/")
    value = string_gsub(value, "^%s+", "")
    value = string_gsub(value, "%s+$", "")
    value = string_gsub(value, "/+", "/")

    if string_sub(value, -5) == ".unit" then
        value = string_sub(value, 1, -6)
    end

    return value ~= "" and string_lower(value) or nil
end

local function normalize_hash(value)
    if type(value) ~= "string" then
        return nil
    end

    local hash = string_match(value, "^%s*#?[Ii][Dd]%[([%x]+)%]%s*$")
        or string_match(value, "^%s*0[xX]([%x]+)%s*$")
    local plain = not hash and string_match(value, "^%s*([%x]+)%s*$") or nil

    if not hash and plain and #plain == 16 then
        hash = plain
    end

    return hash and ("#ID[" .. string_lower(hash) .. "]") or nil
end

local function normalize_resource(value)
    return normalize_hash(value) or normalize_path(value)
end

local function valid_path(path)
    return type(path) == "string"
        and (string_sub(path, 1, 8) == "content/" or string_sub(path, 1, 5) == "core/")
        and string_sub(path, -1) ~= "/"
        and not string_find(path, "[\r\n\t]")
end

local function valid_hash(value)
    return type(value) == "string" and string_match(value, "^#ID%[[%x]+%]$") ~= nil
end

local function valid_resource(value)
    return valid_path(value) or valid_hash(value)
end

local function resource_from(value)
    local resource = type(value) == "table"
        and (value.npclook_raw_resource or value.base_unit or value.name)
        or value

    return normalize_resource(resource)
end

local function path_category(path)
    local root, category = string_match(path or "", "^([^/]+)/([^/]+)")
    root = root or "hash"
    category = category or (root == "hash" and "hashed" or root)

    if root == "packages" and category == "content" then
        category = string_match(path or "", "^packages/content/([^/]+)") or category
    end

    local label = CATEGORY_LABELS[category]
        or string_upper(string_gsub(category, "_", " ")) .. " UNIT"

    return category, label
end

local function path_leaf(path)
    local leaf = string_match(path or "", "([^/]+)$")
    if leaf == "world" then
        leaf = string_match(path or "", "([^/]+)/world$")
    end
    return leaf
end

local function load_variant_metadata()
    if state.variant_metadata ~= nil then
        return state.variant_metadata
    end

    local ok, variants = pcall(mod.io_dofile, mod, VARIANTS_PATH)
    if not ok or type(variants) ~= "table" then
        state.variant_metadata = {}
    else
        state.variant_metadata = variants
    end

    return state.variant_metadata
end

local function load_catalog()
    if state.catalog_loaded then
        return true
    end

    local loader = resource_loader(true)
    if not loader then
        return false
    end

    local packages = {}
    local visit_count = loader.visit("unit", function(resource_name, package_name)
        local resource = normalize_resource(resource_name)

        if valid_resource(resource) and packages[resource] == nil then
            packages[resource] = type(package_name) == "string" and package_name ~= ""
                and package_name or false
        end
    end, { retain_chunks = false })

    if not visit_count then
        return false
    end

    state.catalog_loaded = true
    state.package_by_resource = packages

    return true
end

local function metadata_for(resource, transient)
    load_catalog()

    local cached = state.metadata_cache[resource]
    if cached then
        return cached
    end

    local package_value = state.package_by_resource[resource]
    local package_name = type(package_value) == "string" and package_value or nil
    local override = registry[resource]
    local in_catalog = package_value ~= nil

    if not in_catalog and type(override) ~= "table" then
        return nil
    end

    local category, category_label
    if valid_hash(resource) and package_name then
        category, category_label = path_category(package_name)
    elseif valid_hash(resource) then
        category, category_label = "hashed", CATEGORY_LABELS.hashed
    else
        category, category_label = path_category(resource)
    end

    local metadata = {
        label = valid_hash(resource) and (path_leaf(package_name) or resource)
            or path_leaf(resource) or resource,
        category = category,
        category_label = category_label,
        package = package_name,
        retain_package = true,
    }
    local variants = load_variant_metadata()[resource]

    if type(variants) == "table" then
        for key, value in pairs(variants) do
            metadata[key] = value
        end
    end

    if type(override) == "table" then
        for key, value in pairs(override) do
            metadata[key] = value
        end
    end

    if not transient then
        state.metadata_cache[resource] = metadata
    end

    return metadata
end

local function register_resource(value, metadata)
    local resource = normalize_resource(value)
    if not valid_resource(resource) or not load_catalog() then
        return nil, false
    end

    local in_catalog = state.package_by_resource[resource] ~= nil
    local existing = registry[resource]
    local changed = false

    if not in_catalog and state.package_by_resource[resource] == nil then
        local loader = resource_loader()
        local resolved = loader and loader.resolve("unit", resource)

        if type(resolved) == "table" then
            state.package_by_resource[resource] = resolved.package_name
        end
    end

    if type(existing) ~= "table" then
        existing = {}
        registry[resource] = existing
        changed = true
    end

    if type(metadata) == "table" then
        for key, value in pairs(metadata) do
            if value ~= nil and existing[key] ~= value then
                existing[key] = value
                changed = true
            end
        end
    end

    if changed then
        state.registry_revision = state.registry_revision + 1
        state.metadata_cache[resource] = nil
        state.catalog_entries = nil
        state.definitions[resource] = nil
    end

    return metadata_for(resource), changed
end

local function display_name(resource, metadata)
    metadata = metadata or metadata_for(resource)
    return type(metadata) == "table" and metadata.label
        or path_leaf(resource)
        or tostring(resource or "")
end

local function category_metadata(resource, metadata)
    metadata = metadata or metadata_for(resource)
    if type(metadata) == "table" then
        return metadata.category, metadata.category_label
    elseif valid_hash(resource) then
        return "hashed", CATEGORY_LABELS.hashed
    end
    return path_category(resource)
end

local function package_dependencies(package_name)
    local dependencies = {}
    if type(package_name) == "string" and package_name ~= "" then
        dependencies[package_name] = true
    end
    return dependencies
end

local function refresh_definition(item, resource)
    if type(item) ~= "table" or rawget(item, "npclook_raw_definition") ~= true then
        return item
    end

    local metadata = metadata_for(resource) or {}
    local package_name = metadata.package
    local category, category_label = category_metadata(resource, metadata)

    item.name = resource
    item.base_unit = resource
    item.npclook_raw_resource = resource
    item.npclook_raw_package = package_name
    item.npclook_raw_label = display_name(resource, metadata)
    local _, package_source_label = package_name and path_category(package_name)

    item.npclook_raw_category = category
    item.npclook_raw_category_label = category_label
    item.npclook_raw_package_source_label = package_source_label
    item.npclook_raw_package_members = metadata.package_members
    item.npclook_raw_package_count = metadata.package_count
    item.npclook_raw_membership_count = metadata.membership_count
    item.npclook_raw_retain_package = metadata.retain_package ~= false
    item.npclook_raw_mesh_count = metadata.mesh_count
    item.npclook_raw_variant_families = metadata.variant_families
    item.npclook_raw_visibility_groups = metadata.visibility_groups
    item.npclook_raw_estimated_variant_combinations = metadata.estimated_variant_combinations
    item.npclook_raw_variant_parse_failure = metadata.variant_parse_failure
    item.dev_name = item.npclook_raw_label
    item.display_name = item.npclook_raw_label
    item.resource_dependencies = package_dependencies(package_name)

    return item
end

local function definition(resource)
    local item = {
        name = resource,
        dev_name = resource,
        display_name = resource,
        description = "",
        base_unit = resource,
        attach_node = 1,
        attachments = {},
        resource_dependencies = {},
        slots = {},
        tags = {},
        feature_flags = {},
        item_type = "NPCLOOK_RAW_UNIT",
        item_category = "NPCLOOK",
        is_fallback_item = false,
        show_in_1p = false,
        only_show_in_1p = false,
        hide_in_ui_preview = false,
        npclook_raw_unit = true,
        npclook_raw_definition = true,
    }
    return refresh_definition(item, resource)
end

local function variant_search_text(metadata)
    local families = type(metadata) == "table" and metadata.variant_families or nil
    local groups = type(metadata) == "table" and metadata.visibility_groups or nil

    if not families and not groups then
        return nil
    end

    local names = {}

    for _, family in ipairs(families or {}) do
        names[#names + 1] = tostring(family.name or "")

        for _, option in ipairs(family.options or {}) do
            names[#names + 1] = tostring(type(option) == "table" and option.name or option)
        end
    end

    for _, group in ipairs(groups or {}) do
        names[#names + 1] = tostring(type(group) == "table" and group.name or group)
    end

    return #names > 0 and table_concat(names, " ") or nil
end

function RawUnits.available()
    return resource_loader() ~= nil
end

function RawUnits.unavailable_reason()
    local _, err = resource_loader()
    return err
end

function RawUnits.normalize(value)
    return normalize_resource(value)
end

function RawUnits.is_resource(value)
    return valid_resource(normalize_resource(value))
end

function RawUnits.package_name(value)
    local resource = resource_from(value)
    local metadata = resource and metadata_for(resource)
    return type(metadata) == "table" and metadata.package or nil
end

function RawUnits.metadata(value)
    local resource = resource_from(value)
    return resource and metadata_for(resource) or nil
end

function RawUnits.variant_metadata(value)
    local metadata = RawUnits.metadata(value)
    if type(metadata) ~= "table" then
        return nil
    end
    return {
        mesh_count = metadata.mesh_count,
        visibility_group_count = metadata.visibility_group_count,
        variant_families = metadata.variant_families,
        visibility_groups = metadata.visibility_groups,
        estimated_variant_combinations = metadata.estimated_variant_combinations,
        variant_parse_failure = metadata.variant_parse_failure,
    }
end

function RawUnits.catalog_entries()
    if not load_catalog() then
        return {}
    elseif state.catalog_entries and state.catalog_revision == state.registry_revision then
        return state.catalog_entries
    end

    local sortable = {}

    local function add_entry(resource)
        local metadata = metadata_for(resource, true)
        local label = display_name(resource, metadata)
        local _, category_label = category_metadata(resource, metadata)
        local entry = {
            name = resource,
            label = label,
            sub = category_label,
            variant_search = variant_search_text(metadata),
        }

        sortable[#sortable + 1] = {
            string_lower(tostring(label or resource)),
            entry,
        }
    end

    for resource in pairs(state.package_by_resource) do
        add_entry(resource)
    end

    for resource in pairs(registry) do
        if state.package_by_resource[resource] == nil and valid_resource(resource) then
            add_entry(resource)
        end
    end

    table_sort(sortable, function(a, b)
        local left = a[2]
        local right = b[2]

        if a[1] ~= b[1] then
            return a[1] < b[1]
        elseif left.sub ~= right.sub then
            return tostring(left.sub or "") < tostring(right.sub or "")
        end

        return tostring(left.name or "") < tostring(right.name or "")
    end)

    local entries = {}

    for i = 1, #sortable do
        entries[i] = sortable[i][2]
    end

    state.catalog_entries = entries
    state.catalog_revision = state.registry_revision

    return entries
end

function RawUnits.mark_package_ready(value, package_manager)
    local resource = resource_from(value)
    if valid_resource(resource) then
        state.package_ready_by_resource[resource] = package_manager or Managers.package or true
    end
end

function RawUnits.package_ready(value, package_manager)
    local resource = resource_from(value)
    local ready_manager = resource and state.package_ready_by_resource[resource]
    if ready_manager == nil then
        return false
    elseif ready_manager == true then
        return true
    end
    return ready_manager == (package_manager or Managers.package)
end

function RawUnits.ensure_ready(value, package_ready, package_manager)
    local resource = resource_from(value)
    if not valid_resource(resource) then
        return false, "Invalid raw unit resource", false
    elseif not RawUnits.available() then
        return false, RawUnits.unavailable_reason(), false
    end

    local package_name = RawUnits.package_name(resource)
    local package_is_ready = package_ready == true or RawUnits.package_ready(resource, package_manager)

    if type(package_name) == "string" and package_name ~= "" and not package_is_ready then
        return false, "Unit package is still loading: " .. package_name, true
    end

    return true, nil, false
end

function RawUnits.refresh(value)
    local resource = resource_from(value)
    if type(value) == "table" and rawget(value, "npclook_raw_definition") == true
        and valid_resource(resource) then
        return refresh_definition(value, resource)
    end
    return value
end

function RawUnits.ensure(cache, value, metadata)
    local resource = normalize_resource(value)
    if type(cache) ~= "table" or not valid_resource(resource) or not load_catalog() then
        return nil, false
    end

    local _, registered_now = register_resource(resource, metadata)
    local existing = rawget(cache, resource)

    if existing then
        if type(existing) == "table" and existing.npclook_raw_unit == true then
            return existing, registered_now
        end
        return nil, registered_now
    end

    local item = state.definitions[resource]
    if not item then
        item = definition(resource)
        state.definitions[resource] = item
    end

    rawset(cache, resource, item)
    state.installed_cache = cache
    state.installed_resources[resource] = true
    return item, registered_now
end

function RawUnits.install(cache)
    if type(cache) ~= "table" or state.installed_cache == cache then
        return cache
    end

    local old_cache = state.installed_cache
    if type(old_cache) == "table" then
        for resource in pairs(state.installed_resources or {}) do
            local item = rawget(old_cache, resource)
            if type(item) == "table" and rawget(item, "npclook_raw_definition") == true then
                rawset(old_cache, resource, nil)
            end
        end
    end

    state.installed_cache = cache
    state.installed_resources = {}
    return cache
end

function RawUnits.acquire_package(package_name, callback, options)
    local loader, err = resource_loader()
    if not loader then
        return nil, err
    end
    return loader.acquire_package(mod, package_name, callback, options)
end

function RawUnits.release_ticket(ticket)
    local loader, err = resource_loader()
    if not loader then
        return false, err
    end
    return loader.release(ticket)
end

function RawUnits.ticket_status(ticket)
    local loader = resource_loader()
    return loader and loader.status(ticket) or "unavailable"
end

local function clone_string_map(values)
    local result = {}

    for key, value in pairs(type(values) == "table" and values or {}) do
        if type(key) == "string" and type(value) == "string" then
            result[key] = value
        end
    end

    return result
end

local function clone_boolean_map(values)
    local result = {}

    for key, value in pairs(type(values) == "table" and values or {}) do
        if type(key) == "string" and type(value) == "boolean" then
            result[key] = value
        end
    end

    return result
end

function RawUnits.normalize_variant_state(value, item_name)
    value = type(value) == "table" and value or {}

    -- Variant state is scoped to one unit.
    if type(item_name) == "string" and type(value.item_name) == "string"
        and value.item_name ~= item_name then
        value = {}
    end

    local result = {
        item_name = type(item_name) == "string" and item_name or type(value.item_name) == "string" and value.item_name or nil,
        families = clone_string_map(value.families),
        visibility = clone_boolean_map(value.visibility),
    }

    return result
end

function RawUnits.variant_signature(value)
    local state_value = RawUnits.normalize_variant_state(value)
    local family_names = table.keys(state_value.families)
    local group_names = table.keys(state_value.visibility)

    if #family_names == 0 and #group_names == 0 then
        return ""
    end

    local parts = { tostring(state_value.item_name or "") }
    table_sort(family_names)
    table_sort(group_names)

    for i = 1, #family_names do
        local name = family_names[i]
        parts[#parts + 1] = "f:" .. name .. "=" .. tostring(state_value.families[name])
    end

    for i = 1, #group_names do
        local name = group_names[i]
        parts[#parts + 1] = "g:" .. name .. "=" .. (state_value.visibility[name] and "1" or "0")
    end

    return table_concat(parts, "\31")
end

function RawUnits.clone_variant_map(values)
    local result = {}

    for slot_name, state_value in pairs(type(values) == "table" and values or {}) do
        if type(slot_name) == "string" then
            result[slot_name] = RawUnits.normalize_variant_state(state_value)
        end
    end

    return result
end

function RawUnits.same_variant_maps(left, right)
    local seen = {}

    for slot_name, value in pairs(type(left) == "table" and left or {}) do
        seen[slot_name] = true
        if RawUnits.variant_signature(value) ~= RawUnits.variant_signature(type(right) == "table" and right[slot_name]) then
            return false
        end
    end

    for slot_name, value in pairs(type(right) == "table" and right or {}) do
        if not seen[slot_name] and RawUnits.variant_signature(value) ~= RawUnits.variant_signature(nil) then
            return false
        end
    end

    return true
end

local unit_api = rawget(_G, "Unit") or {}
local unit_alive = unit_api.alive
local unit_set_visibility = unit_api.set_visibility
local unit_has_visibility_group = unit_api.has_visibility_group
local unit_num_meshes = unit_api.num_meshes
local unit_set_mesh_visibility = unit_api.set_mesh_visibility

local function safe_unit_alive(unit)
    if not unit or type(unit_alive) ~= "function" then
        return false
    end

    local ok, alive = pcall(unit_alive, unit)

    return ok and alive == true
end

local function visit_visual_units(root_unit, attachment_map, callback)
    local seen = {}

    local function visit(unit)
        if not unit or seen[unit] then
            return
        end

        if not safe_unit_alive(unit) then
            return
        end

        seen[unit] = true
        callback(unit)

        local children = type(attachment_map) == "table" and attachment_map[unit]
        for i = 1, #(children or {}) do
            visit(children[i])
        end
    end

    visit(root_unit)
end

local function set_group(root_unit, attachment_map, name, visible, mesh_indices)
    local applied_named_group = false

    if type(unit_set_visibility) == "function" and type(name) == "string" and name ~= "" then
        visit_visual_units(root_unit, attachment_map, function(unit)
            local has_group = true

            if type(unit_has_visibility_group) == "function" then
                local ok_has, result = pcall(unit_has_visibility_group, unit, name)
                has_group = ok_has and result == true
            end

            if has_group then
                local ok_set = pcall(unit_set_visibility, unit, name, visible == true)
                applied_named_group = applied_named_group or ok_set
            end
        end)
    end

    -- Mesh fallback is root-only.
    if not applied_named_group and safe_unit_alive(root_unit) then
        local mesh_count

        if type(unit_num_meshes) == "function" then
            local ok_count, count = pcall(unit_num_meshes, root_unit)
            mesh_count = ok_count and tonumber(count) or nil
        end

        for i = 1, #(mesh_indices or {}) do
            local mesh_index = tonumber(mesh_indices[i])

            if type(unit_set_mesh_visibility) == "function"
                and mesh_index and mesh_index >= 1
                and (not mesh_count or mesh_index <= mesh_count) then
                local ok_set = pcall(
                    unit_set_mesh_visibility,
                    root_unit,
                    mesh_index,
                    visible == true
                )
                applied_named_group = applied_named_group or ok_set
            end
        end
    end

    return applied_named_group
end

function RawUnits.apply_variants(item, root_unit, attachment_map, explicit_state)
    if type(item) ~= "table" or item.npclook_raw_unit ~= true or not root_unit then
        return false
    end

    local state_value = RawUnits.normalize_variant_state(explicit_state or item.npclook_raw_variant_state, item.name)
    local changed = false

    local metadata = RawUnits.metadata(item) or {}
    local families = item.npclook_raw_variant_families or metadata.variant_families or {}
    local groups = item.npclook_raw_visibility_groups or metadata.visibility_groups or {}

    for _, family in ipairs(families) do
        local family_name = tostring(family.name or "")
        local selected = state_value.families[family_name]

        if selected then
            for _, option in ipairs(family.options or {}) do
                local option_name = tostring(type(option) == "table" and option.name or option)
                local indexes = type(option) == "table" and option.mesh_indices or nil
                changed = set_group(
                    root_unit,
                    attachment_map,
                    option_name,
                    option_name == selected,
                    indexes
                ) or changed
            end
        end
    end

    for _, group in ipairs(groups) do
        local group_name = tostring(type(group) == "table" and group.name or group)
        local visible = state_value.visibility[group_name]

        if visible ~= nil then
            changed = set_group(
                root_unit,
                attachment_map,
                group_name,
                visible,
                type(group) == "table" and group.mesh_indices or nil
            ) or changed
        end
    end

    return changed
end

function RawUnits.force_overlay_spawn(item)
    local resource = type(item) == "table" and normalize_resource(item.name or item.base_unit)

    if resource then
        overlay_fallbacks[resource] = true
    end
end

function RawUnits.use_overlay_spawn(item)
    if type(item) ~= "table" or item.npclook_raw_unit ~= true then
        return false
    end

    local resource = normalize_resource(item.name or item.base_unit)
    local category = tostring(item.npclook_raw_category or "")

    return overlay_fallbacks[resource] == true
        or category ~= "characters" and category ~= "weapons"
end

function RawUnits.apply_variants_to_slot(slot, item)
    if type(slot) ~= "table" or type(item) ~= "table" then
        return false
    end

    local changed_3p = RawUnits.apply_variants(item, slot.unit_3p, slot.attachments_by_unit_3p)
    local changed_1p = RawUnits.apply_variants(item, slot.unit_1p, slot.attachments_by_unit_1p)

    return changed_3p or changed_1p
end

function RawUnits.release_transient_cache()
    state.catalog_loaded = false
    state.package_by_resource = {}
    state.metadata_cache = {}
    state.variant_metadata = nil
    state.catalog_entries = nil
    state.catalog_revision = -1
end

function RawUnits.release_all()
    state.package_ready_by_resource = {}

    local cache = state.installed_cache
    if type(cache) == "table" then
        for resource in pairs(state.installed_resources or {}) do
            local item = rawget(cache, resource)
            if type(item) == "table" and rawget(item, "npclook_raw_definition") == true then
                rawset(cache, resource, nil)
            end
        end
    end

    state.installed_cache = nil
    state.installed_resources = {}
    RawUnits.release_transient_cache()
end

rawset(mod, "npclook_raw_units_runtime", RawUnits)

return RawUnits
