local mod = get_mod("NPCLook")
local shared_runtime = rawget(mod, "npclook_meshes_runtime")

-- Gameplay, Studio and extra slots share one instance so installed helpers reach all of them.
if type(shared_runtime) == "table" then
    return shared_runtime
end

-- Per-mesh visibility and material overrides for one slot item.
-- Mesh keys are "<scope>#<index>": the attachment item name that owns the unit, or "root".
local Meshes = {}

local ROOT_SCOPE = "root"
local HIDDEN_LIMIT = 256
local MATERIAL_LIMIT = 32
local reported_errors = {}

local unit_api = rawget(_G, "Unit") or {}
local mesh_api = rawget(_G, "Mesh") or {}
local material_api = rawget(_G, "Material") or {}

local function safe_unit_alive(unit)
    if not unit or type(unit_api.alive) ~= "function" then
        return false
    end

    local ok, alive = pcall(unit_api.alive, unit)

    return ok and alive == true
end

function Meshes.key(scope, index)
    return tostring(scope or ROOT_SCOPE) .. "#" .. tostring(index)
end

function Meshes.key_parts(key)
    if type(key) ~= "string" then
        return nil, nil
    end

    local scope, index = string.match(key, "^(.+)#(%d+)$")
    index = tonumber(index)

    if not scope or not index or index < 1 then
        return nil, nil
    end

    return scope, index
end

function Meshes.valid_key(key)
    return Meshes.key_parts(key) ~= nil and #key <= 512
end

-- normalize_materials is provided by the material schema so entries stay comparable.
function Meshes.install(dependencies)
    Meshes.normalize_materials = dependencies.normalize_materials
    Meshes.material_item_name = dependencies.material_item_name
    Meshes.apply_override_item = dependencies.material_override_item
end

function Meshes.normalize_state(value, item_name)
    if type(value) ~= "table" then
        return nil
    end

    if type(item_name) == "string" and type(value.item_name) == "string" and value.item_name ~= item_name then
        return nil
    end

    local result = {
        item_name = type(item_name) == "string" and item_name or type(value.item_name) == "string" and value.item_name or nil,
        hidden = {},
        materials = {},
    }
    local hidden_count = 0

    for key, hidden in pairs(type(value.hidden) == "table" and value.hidden or {}) do
        if hidden == true and Meshes.valid_key(key) and hidden_count < HIDDEN_LIMIT then
            result.hidden[key] = true
            hidden_count = hidden_count + 1
        end
    end

    local material_count = 0

    for key, entries in pairs(type(value.materials) == "table" and value.materials or {}) do
        if Meshes.valid_key(key) and material_count < HIDDEN_LIMIT then
            local normalized = Meshes.normalize_materials and Meshes.normalize_materials(entries) or {}

            while #normalized > MATERIAL_LIMIT do
                table.remove(normalized)
            end

            if #normalized > 0 then
                result.materials[key] = normalized
                material_count = material_count + 1
            end
        end
    end

    if not result.item_name or next(result.hidden) == nil and next(result.materials) == nil then
        return nil
    end

    return result
end

function Meshes.clone_state(value)
    return Meshes.normalize_state(value)
end

function Meshes.clone_map(values)
    local result = {}

    for slot_name, value in pairs(type(values) == "table" and values or {}) do
        local state = type(slot_name) == "string" and Meshes.normalize_state(value) or nil

        if state then
            result[slot_name] = state
        end
    end

    return result
end

function Meshes.signature(value)
    local state = Meshes.normalize_state(value)

    if not state then
        return ""
    end

    local hidden = table.keys(state.hidden)
    local material_keys = table.keys(state.materials)
    local parts = { state.item_name }

    table.sort(hidden)
    table.sort(material_keys)

    for i = 1, #hidden do
        parts[#parts + 1] = "h:" .. hidden[i]
    end

    for i = 1, #material_keys do
        local key = material_keys[i]
        parts[#parts + 1] = "m:" .. key .. "=" .. table.concat(state.materials[key], "\30")
    end

    return table.concat(parts, "\31")
end

function Meshes.same_maps(left, right)
    local seen = {}

    for slot_name, value in pairs(type(left) == "table" and left or {}) do
        seen[slot_name] = true

        if Meshes.signature(value) ~= Meshes.signature(type(right) == "table" and right[slot_name]) then
            return false
        end
    end

    for slot_name, value in pairs(type(right) == "table" and right or {}) do
        if not seen[slot_name] and Meshes.signature(value) ~= "" then
            return false
        end
    end

    return true
end

-- Units

function Meshes.mesh_count(unit)
    if not safe_unit_alive(unit) or type(unit_api.num_meshes) ~= "function" then
        return 0
    end

    local ok, count = pcall(unit_api.num_meshes, unit)

    return ok and tonumber(count) or 0
end

function Meshes.material_count(unit, index)
    if type(unit_api.mesh) ~= "function" or type(mesh_api.num_materials) ~= "function" then
        return 0
    end

    local ok_mesh, mesh = pcall(unit_api.mesh, unit, index)

    if not ok_mesh or not mesh then
        return 0
    end

    local ok_count, count = pcall(mesh_api.num_materials, mesh)

    return ok_count and tonumber(count) or 0
end

-- Collects the slot's root and attachment units with the scope each mesh key uses.
-- Item names are stable between the Studio preview, extra slots and the live character.
function Meshes.scoped_units(roots, attachment_maps, item_name_maps, root_item_name)
    local result = {}
    local seen = {}

    local function scope_for(unit)
        for i = 1, #(item_name_maps or {}) do
            local name = item_name_maps[i] and item_name_maps[i][unit]

            if type(name) == "string" and name ~= "" and name ~= root_item_name then
                return name
            end
        end

        return ROOT_SCOPE
    end

    local function add(unit)
        if not unit or seen[unit] or not safe_unit_alive(unit) then
            return
        end

        seen[unit] = true
        result[#result + 1] = {
            unit = unit,
            scope = scope_for(unit),
        }
    end

    for i = 1, #(roots or {}) do
        add(roots[i])
    end

    for i = 1, #(attachment_maps or {}) do
        for parent, children in pairs(attachment_maps[i] or {}) do
            add(parent)

            for _, child in pairs(type(children) == "table" and children or {}) do
                add(child)
            end
        end
    end

    return result
end

function Meshes.inventory(scoped_units)
    local rows = {}
    local seen = {}

    for i = 1, #(scoped_units or {}) do
        local entry = scoped_units[i]

        for index = 1, Meshes.mesh_count(entry.unit) do
            local key = Meshes.key(entry.scope, index)

            if not seen[key] then
                seen[key] = true
                rows[#rows + 1] = {
                    key = key,
                    scope = entry.scope,
                    index = index,
                    material_count = Meshes.material_count(entry.unit, index),
                }
            end
        end
    end

    table.sort(rows, function(left, right)
        if left.scope ~= right.scope then
            return left.scope == ROOT_SCOPE or right.scope ~= ROOT_SCOPE and left.scope < right.scope
        end

        return left.index < right.index
    end)

    return rows
end

local function report_once(key, message)
    if reported_errors[key] then
        return
    end

    reported_errors[key] = true
    mod:error("Mesh override failed (%s): %s", tostring(key), tostring(message))
end

local function mesh_materials(unit, index, material_slot)
    local ok_mesh, mesh = pcall(unit_api.mesh, unit, index)

    if not ok_mesh or not mesh or type(mesh_api.material) ~= "function" then
        return {}
    end

    if type(material_slot) == "string" and material_slot ~= "" then
        local ok_material, material = pcall(mesh_api.material, mesh, material_slot)

        return ok_material and material and { material } or {}
    end

    local materials = {}
    local count = 0

    if type(mesh_api.num_materials) == "function" then
        local ok_count, value = pcall(mesh_api.num_materials, mesh)
        count = ok_count and tonumber(value) or 0
    end

    for material_index = 1, count do
        local ok_material, material = pcall(mesh_api.material, mesh, material_index)

        if ok_material and material then
            materials[#materials + 1] = material
        end
    end

    return materials
end

local function apply_property(materials, setter, property_name, value)
    if type(setter) ~= "function" or type(property_name) ~= "string" then
        return 0
    end

    local applied = 0

    for i = 1, #materials do
        if pcall(setter, materials[i], property_name, value) then
            applied = applied + 1
        end
    end

    return applied
end

-- Mirrors VisualLoadoutCustomization._apply_material_override_item on one mesh.
local function apply_override_to_mesh(unit, index, override)
    local applied = 0
    local all_materials = mesh_materials(unit, index)

    for _, data in pairs(override.scalar_material_overrides or {}) do
        applied = applied + apply_property(all_materials, material_api.set_scalar, data.property_name, data.value)
    end

    for _, data in pairs(override.vector2_material_overrides or {}) do
        local value = data.value or {}
        applied = applied + apply_property(all_materials, material_api.set_vector2, data.property_name, Vector2(value[1] or 0, value[2] or 0))
    end

    for _, data in pairs(override.vector3_material_overrides or {}) do
        local value = data.value or {}
        applied = applied + apply_property(all_materials, material_api.set_vector3, data.property_name, Vector3(value[1] or 0, value[2] or 0, value[3] or 0))
    end

    for _, data in pairs(override.vector4_material_overrides or {}) do
        local value = data.value or {}
        applied = applied + apply_property(all_materials, material_api.set_vector4, data.property_name, Color(value[2] or 0, value[3] or 0, value[4] or 0, value[1] or 0))
    end

    for _, data in pairs(override.texture_material_overrides or {}) do
        local texture = data.texture

        if type(texture) == "string" and texture ~= "" then
            applied = applied + apply_property(
                mesh_materials(unit, index, data.material_slot),
                material_api.set_texture,
                data.texture_slot,
                texture
            )
        end
    end

    return applied
end

local PER_MESH_FIELDS = {
    "scalar_material_overrides",
    "vector2_material_overrides",
    "vector3_material_overrides",
    "vector4_material_overrides",
    "texture_material_overrides",
}

-- Whole-material swaps cannot target one mesh.
function Meshes.supports_override(override)
    if type(override) ~= "table" then
        return false
    end

    for i = 1, #PER_MESH_FIELDS do
        local values = override[PER_MESH_FIELDS[i]]

        if type(values) == "table" and next(values) ~= nil then
            return true
        end
    end

    return false
end

function Meshes.apply(scoped_units, state, item_definitions)
    state = Meshes.normalize_state(state)

    if not state then
        return
    end

    for i = 1, #(scoped_units or {}) do
        local entry = scoped_units[i]
        local unit = entry.unit

        for index = 1, Meshes.mesh_count(unit) do
            local key = Meshes.key(entry.scope, index)

            if state.hidden[key] and type(unit_api.set_mesh_visibility) == "function" then
                pcall(unit_api.set_mesh_visibility, unit, index, false)
            end

            local entries = state.materials[key]

            for j = 1, #(entries or {}) do
                local item_name = Meshes.material_item_name and Meshes.material_item_name(entries[j]) or entries[j]
                local override = Meshes.apply_override_item and Meshes.apply_override_item(item_definitions, item_name)
                    or type(item_definitions) == "table" and rawget(item_definitions, item_name)

                if type(override) == "table" then
                    local ok, applied = pcall(apply_override_to_mesh, unit, index, override)

                    if not ok then
                        report_once(key .. "|" .. tostring(item_name), applied)
                    end
                end
            end
        end
    end
end

-- Native visibility updates show every mesh again; only hidden meshes need reapplying.
function Meshes.apply_visibility(scoped_units, state)
    if type(state) ~= "table" or type(state.hidden) ~= "table" or next(state.hidden) == nil
        or type(unit_api.set_mesh_visibility) ~= "function" then
        return
    end

    for i = 1, #(scoped_units or {}) do
        local entry = scoped_units[i]

        for index = 1, Meshes.mesh_count(entry.unit) do
            if state.hidden[Meshes.key(entry.scope, index)] then
                pcall(unit_api.set_mesh_visibility, entry.unit, index, false)
            end
        end
    end
end

function Meshes.slot_scoped_units(slot, root_item_name)
    if type(slot) ~= "table" then
        return {}
    end

    return Meshes.scoped_units(
        { slot.unit_3p, slot.unit_1p },
        { slot.attachments_by_unit_3p, slot.attachments_by_unit_1p },
        { slot.item_name_by_unit_3p, slot.item_name_by_unit_1p },
        root_item_name
    )
end

-- Mesh materials load with the item that carries them.
function Meshes.add_package_dependencies(item, state, item_definitions)
    if type(item) ~= "table" or type(state) ~= "table" or next(state.materials or {}) == nil then
        return
    end

    local dependencies = table.clone(type(item.resource_dependencies) == "table" and item.resource_dependencies or {})

    for _, entries in pairs(state.materials) do
        for i = 1, #entries do
            local item_name = Meshes.material_item_name and Meshes.material_item_name(entries[i]) or entries[i]
            local override = item_name and (Meshes.apply_override_item and Meshes.apply_override_item(item_definitions, item_name)
                or type(item_definitions) == "table" and rawget(item_definitions, item_name))

            for resource_name in pairs(type(override) == "table" and override.resource_dependencies or {}) do
                dependencies[resource_name] = true
            end
        end
    end

    item.resource_dependencies = dependencies
end

rawset(mod, "npclook_meshes_runtime", Meshes)

return Meshes
