local mod = get_mod("NPCLook")
local util = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_util")
local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")

-- Every load goes through a lease, released once nothing made from it is left

local Packages = {}

-- Same delay the game uses in PackageSynchronizerClient
local RELEASE_DELAY = 3

-- On the mod object so a reload still releases the old leases
local state = rawget(mod, "npclook_package_leases")

if type(state) ~= "table" then
    state = {
        leases = {},
        counter = 0,
    }
    rawset(mod, "npclook_package_leases", state)
end

-- ItemPackage only reads these from the master items, not our edited copies
local ITEM_LIST_FIELDS = { "material_override_items", "npclook_combined_material_overrides", "deform_override_items" }
local MASK_ITEM_FIELDS = {
    "mask_hair_item",
    "mask_facial_hair_item",
    "mask_face_item",
    "mask_face_accessory_item",
    "mask_torso_item",
    "mask_arms_item",
    "mask_legs_item",
}

local function add_resources(result, resources)
    for package_name in pairs(type(resources) == "table" and resources or {}) do
        result[package_name] = true
    end
end

local function add_item(result, definitions, item_name)
    local entry = type(item_name) == "string" and item_name ~= "" and rawget(definitions, item_name)

    if type(entry) == "table" then
        add_resources(result, entry.resource_dependencies)
    end
end

local add_instance

local function add_attachments(result, definitions, tree, seen)
    for _, attachment in pairs(type(tree) == "table" and tree or {}) do
        if type(attachment) == "table" then
            add_instance(result, definitions, attachment.item, seen)
            add_attachments(result, definitions, attachment.children, seen)
        end
    end
end

add_instance = function(result, definitions, item, seen)
    if type(item) ~= "table" or seen[item] then
        return
    end

    seen[item] = true
    add_resources(result, item.resource_dependencies)

    for i = 1, #ITEM_LIST_FIELDS do
        local list = item[ITEM_LIST_FIELDS[i]]

        for _, item_name in pairs(type(list) == "table" and list or {}) do
            add_item(result, definitions, item_name)
        end
    end

    for _, override in pairs(type(item.mask_hair_override) == "table" and item.mask_hair_override or {}) do
        add_item(result, definitions, type(override) == "table" and override.HairMaskOverrideItem)
    end

    -- Studio masks paint from the mask state even without the field
    local mask_state = type(item.npclook_mask_state) == "table" and item.npclook_mask_state.fields

    for i = 1, #MASK_ITEM_FIELDS do
        local field = MASK_ITEM_FIELDS[i]

        add_item(result, definitions, item[field])
        add_item(result, definitions, type(mask_state) == "table" and mask_state[field])
    end

    add_attachments(result, definitions, item.attachments, seen)
    add_attachments(result, definitions, item.children, seen)
end

function Packages.item_dependencies(item, definitions, mission)
    local dependencies = {}
    local ok, err = pcall(ItemPackage.compile_item_instance_dependencies, item, definitions, dependencies, mission)

    if not ok then
        return nil, err
    end

    add_instance(dependencies, definitions, item, {})

    local package_names = {}

    for package_name in pairs(dependencies) do
        if type(package_name) ~= "string" or package_name == "" then
            return nil, string.format("%s has an empty package reference", tostring(item and item.name or "item"))
        end

        package_names[#package_names + 1] = package_name
    end

    table.sort(package_names)

    return package_names
end

local function unit_world(unit)
    local ok, world = pcall(Unit.world, unit)

    return ok and world or nil
end

function Packages.acquire(package_names, label)
    local package_manager = Managers.package

    if not package_manager then
        return nil, "no package manager"
    end

    state.counter = state.counter + 1

    local lease = {
        package_manager = package_manager,
        package_names = {},
        load_ids = {},
        units = {},
        unit_lookup = {},
        rule = "units",
        retired = false,
        ready = false,
        elapsed = 0,
    }
    local reference_name = string.format("NPCLook_%s_%d", tostring(label or "lease"), state.counter)

    state.leases[lease] = true

    for i = 1, #package_names do
        local package_name = package_names[i]
        local ok, load_id = pcall(package_manager.load, package_manager, package_name, reference_name, nil, true)

        if not ok or load_id == nil then
            Packages.retire(lease)

            return nil, tostring(load_id)
        end

        lease.package_names[i] = package_name
        lease.load_ids[i] = load_id
    end

    return lease
end

function Packages.ready(lease)
    if lease.ready then
        return true
    end

    local package_manager = lease.package_manager

    for i = 1, #lease.load_ids do
        if not package_manager:has_loaded_id(lease.load_ids[i]) then
            return false, lease.package_names[i]
        end
    end

    lease.ready = true

    return true
end

-- Parent colours and raw unit flow effects outlive the unit, wait for the world
function Packages.use_world_rule(lease)
    if lease then
        lease.rule = "world"
    end
end

function Packages.bind(lease, units)
    if not lease or type(units) ~= "table" then
        return
    end

    for i = 1, #units do
        local unit = units[i]

        if unit and not lease.unit_lookup[unit] and util.safe_unit_alive(unit) then
            lease.unit_lookup[unit] = true
            lease.units[#lease.units + 1] = unit

            if not lease.world then
                local world = unit_world(unit)
                local world_manager = Managers.world

                lease.world = world
                lease.world_name = world and world_manager and world_manager:world_name(world)
            end
        end
    end
end

function Packages.retire(lease)
    if lease and not lease.retired then
        lease.retired = true
        lease.elapsed = 0
    end
end

local function users_gone(lease)
    local units = lease.units

    for i = #units, 1, -1 do
        local unit = units[i]

        if util.safe_unit_alive(unit) then
            return false
        end

        lease.unit_lookup[unit] = nil
        table.remove(units, i)
    end

    if lease.rule == "world" and lease.world and lease.world_name then
        local world_manager = Managers.world

        return not world_manager or world_manager:world(lease.world_name) ~= lease.world
    end

    return true
end

local function release(lease)
    state.leases[lease] = nil

    local package_manager = lease.package_manager

    -- An old or shutting down manager drops its load ids itself
    if package_manager ~= Managers.package or package_manager._shutdown_has_started then
        return
    end

    for i = #lease.load_ids, 1, -1 do
        pcall(package_manager.release, package_manager, lease.load_ids[i])
        lease.load_ids[i] = nil
    end
end

-- Tells sync when a lease finished loading so it can retry
function Packages.update(dt)
    local became_ready = false

    for lease in pairs(state.leases) do
        if lease.retired then
            if lease.package_manager ~= Managers.package or users_gone(lease) then
                lease.elapsed = lease.elapsed + dt

                if lease.elapsed >= RELEASE_DELAY then
                    release(lease)
                end
            else
                lease.elapsed = 0
            end
        elseif not lease.ready and Packages.ready(lease) then
            became_ready = true
        end
    end

    return became_ready
end

return Packages
