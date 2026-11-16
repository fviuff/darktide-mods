local mod = get_mod("NPCLook")

-- Assets live in mods/NPCLook/Custom/<AssetName>/ and are registered by the Custom Assets patcher.
local CustomAssets = {}

local OWNER = "NPCLook"
local REQUIRED_API = 1
local MATERIAL_ITEM_PREFIX = "npclook/custom/"
local SUPPORTED_TYPES = {
    unit = true,
    texture = true,
    material = true,
}
local ENTRY_PREFIX = {
    texture = "@custom_texture:",
    material = "@custom_material:",
}

local state = {
    entries = nil,
    by_key = nil,
    unavailable_reason = nil,
}

local function custom_assets_api()
    local get_mod_function = rawget(_G, "get_mod")
    local ok, api = false, nil

    if type(get_mod_function) == "function" then
        ok, api = pcall(get_mod_function, "CustomAssets")
    end

    if not ok or type(api) ~= "table" then
        return nil, "Custom Assets is not installed"
    elseif type(api.is_api_compatible) ~= "function" or not api.is_api_compatible(REQUIRED_API) then
        return nil, "Custom Assets API v1 is required"
    elseif type(api.list_resources) ~= "function" then
        return nil, "Custom Assets cannot list resources"
    end

    return api
end

local function normalize_name(value)
    if type(value) ~= "string" then
        return nil
    end

    local hash = string.match(value, "^%s*#?[Ii][Dd]%[([%x]+)%]%s*$")

    if hash then
        return "#ID[" .. string.lower(hash) .. "]"
    end

    value = string.gsub(value, "\\", "/")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")

    return value ~= "" and string.lower(value) or nil
end

local function resource_key(engine_type, name)
    return tostring(engine_type) .. "\31" .. tostring(normalize_name(name))
end

local function leaf(name)
    return string.match(name or "", "([^/]+)$") or tostring(name or "")
end

local function load_entries()
    if state.entries then
        return state.entries
    end

    local api, reason = custom_assets_api()
    local entries = {}
    local by_key = {}

    state.unavailable_reason = reason

    if api then
        local ok, resources = pcall(api.list_resources, nil, OWNER)

        if not ok or type(resources) ~= "table" then
            state.unavailable_reason = tostring(ok and "Custom Assets returned no resources" or resources)
            resources = {}
        end

        for i = 1, #resources do
            local resource = resources[i]
            local engine_type = type(resource) == "table" and resource.engine_type
            local asset = type(resource) == "table" and resource.asset
            local name = normalize_name(resource and resource.name)
            local package_name = type(asset) == "table" and asset.package_name

            if SUPPORTED_TYPES[engine_type] and name and type(package_name) == "string" and package_name ~= "" then
                local key = resource_key(engine_type, name)

                if not by_key[key] then
                    local entry = {
                        engine_type = engine_type,
                        name = name,
                        package_name = package_name,
                        asset_id = tostring(asset.id or asset.logical_id or leaf(name)),
                        unit_kind = asset.unit_kind,
                    }

                    entry.label = string.upper(string.gsub(entry.asset_id, "_", " "))
                    by_key[key] = entry
                    entries[#entries + 1] = entry
                end
            end
        end
    end

    table.sort(entries, function(left, right)
        if left.engine_type ~= right.engine_type then
            return left.engine_type > right.engine_type
        elseif left.label ~= right.label then
            return left.label < right.label
        end

        return left.name < right.name
    end)

    state.entries = entries
    state.by_key = by_key

    return entries
end

function CustomAssets.available()
    return custom_assets_api() ~= nil
end

function CustomAssets.unavailable_reason()
    load_entries()

    return state.unavailable_reason
end

function CustomAssets.entries()
    return load_entries()
end

function CustomAssets.lookup(engine_type, name)
    load_entries()

    return state.by_key[resource_key(engine_type, name)]
end

-- Studio rows keep units as raw resources and prefix material resources so they never
-- resolve as raw units.
function CustomAssets.entry_id(entry)
    local prefix = ENTRY_PREFIX[entry.engine_type]

    return prefix and prefix .. entry.name or entry.name
end

function CustomAssets.parse_entry_id(value)
    if type(value) ~= "string" then
        return nil
    end

    for engine_type, prefix in pairs(ENTRY_PREFIX) do
        if string.sub(value, 1, #prefix) == prefix then
            return engine_type, string.sub(value, #prefix + 1)
        end
    end

    return nil
end

function CustomAssets.unit_metadata(name)
    local entry = CustomAssets.lookup("unit", name)

    if not entry then
        return nil
    end

    -- Rigged pieces deform with the character; static props use the overlay path.
    local rigged = entry.unit_kind == "rigged" or entry.unit_kind == "animated"

    return {
        package = entry.package_name,
        label = entry.label,
        category = rigged and "characters" or "custom",
        category_label = "CUSTOM UNIT",
        retain_package = true,
    }
end

function CustomAssets.material_item_name(engine_type, material_slot, name)
    if not ENTRY_PREFIX[engine_type] or type(material_slot) ~= "string" or material_slot == ""
        or string.find(material_slot, "/", 1, true) or type(name) ~= "string" then
        return nil
    end

    return MATERIAL_ITEM_PREFIX .. engine_type .. "/" .. material_slot .. "/" .. name
end

function CustomAssets.is_material_item_name(value)
    return type(value) == "string" and string.sub(value, 1, #MATERIAL_ITEM_PREFIX) == MATERIAL_ITEM_PREFIX
end

function CustomAssets.parse_material_item_name(value)
    if not CustomAssets.is_material_item_name(value) then
        return nil
    end

    return string.match(string.sub(value, #MATERIAL_ITEM_PREFIX + 1), "^([%a_]+)/([^/]+)/(.+)$")
end

-- Synthetic override items carry the asset package so generated items load it.
function CustomAssets.ensure_material_item(cache, value)
    if type(cache) ~= "table" then
        return nil
    end

    local existing = rawget(cache, value)

    if existing then
        return existing
    end

    local engine_type, material_slot, name = CustomAssets.parse_material_item_name(value)
    local entry = engine_type and CustomAssets.lookup(engine_type, name)

    if not entry then
        return nil
    end

    local label = entry.label .. " @ " .. material_slot
    local item = {
        name = value,
        dev_name = label,
        display_name = label,
        description = "",
        resource_dependencies = { [entry.package_name] = true },
        slots = {},
        attachments = {},
        tags = {},
        feature_flags = {},
        item_type = "NPCLOOK_CUSTOM_MATERIAL",
        npclook_custom_material = true,
    }

    if engine_type == "texture" then
        item.texture_material_overrides = {
            {
                texture_slot = material_slot,
                texture = entry.name,
                material_slot = "",
            },
        }
    else
        item.material_overrides = {
            {
                material_slot = material_slot,
                material = entry.name,
            },
        }
    end

    rawset(cache, value, item)

    return item
end

function CustomAssets.release_cache()
    state.entries = nil
    state.by_key = nil
    state.unavailable_reason = nil
end

return CustomAssets
