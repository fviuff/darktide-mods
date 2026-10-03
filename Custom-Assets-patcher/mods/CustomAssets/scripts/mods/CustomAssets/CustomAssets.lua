local mod = get_mod("CustomAssets")

mod.VERSION = "1.0.2"
mod.API_VERSION = 1

local MANIFEST_PATH = "CustomAssets/generated/manifest"
local MOD_DIRECTORY = "./../mods/"
local lua_io = Mods and Mods.lua and Mods.lua.io
local io_open = lua_io and lua_io.open
local compile_lua = Mods and Mods.lua and Mods.lua.loadstring

local function load_lua_file(relative_path)
    if type(io_open) ~= "function" or type(compile_lua) ~= "function" then
        return nil, "Darktide's Lua file APIs are unavailable"
    end
    local file_path = MOD_DIRECTORY .. relative_path .. ".lua"
    local open_ok, file, open_error = pcall(io_open, file_path, "r")
    if not open_ok then
        return nil, "could not open " .. file_path .. ": " .. tostring(file)
    elseif not file then
        return nil, "could not open " .. file_path .. ": " .. tostring(open_error)
    end
    local read_ok, source = pcall(file.read, file, "*all")
    local close_ok, close_error = pcall(file.close, file)
    if not read_ok then
        return nil, "could not read " .. file_path .. ": " .. tostring(source)
    elseif not close_ok then
        return nil, "could not close " .. file_path .. ": " .. tostring(close_error)
    elseif type(source) ~= "string" then
        return nil, "could not read " .. file_path .. ": file contents were not a string"
    end
    local compile_ok, chunk, compile_error = pcall(compile_lua, source, "@" .. file_path)
    if not compile_ok then
        return nil, "could not compile " .. file_path .. ": " .. tostring(chunk)
    elseif not chunk then
        return nil, "could not compile " .. file_path .. ": " .. tostring(compile_error)
    end
    local execute_ok, result = pcall(chunk)
    if not execute_ok then
        return nil, "could not execute " .. file_path .. ": " .. tostring(result)
    end
    return result
end

local function empty_manifest()
    return {
        schema = 2,
        custom_assets_version = mod.VERSION,
        patch = { resource_count = 0, stream_count = 0, package_count = 0, bundle_count = 0 },
        assets = {},
    }
end

local manifest_load_error = nil
local function load_manifest()
    local value, load_error = load_lua_file(MANIFEST_PATH)
    if type(value) ~= "table" or value.schema ~= 2 or type(value.assets) ~= "table" then
        manifest_load_error = tostring(load_error or "unsupported manifest schema")
        mod:error(
            "Custom Assets manifest is missing or invalid: %s. Run CUSTOM_ASSETS_PATCH.bat with Darktide closed.",
            manifest_load_error
        )
        return empty_manifest()
    end
    return value
end

local manifest = load_manifest()
local assets_by_id = {}
local asset_order = {}
local resources_by_key = {}
local packages_by_name = {}

local function normalize_hash_id(value)
    if type(value) ~= "string" then return value end
    local hash = string.match(value, "^#ID%[([%x]+)%]$")
    if hash and #hash == 16 then return "#ID[" .. string.lower(hash) .. "]" end
    return value
end

local function resource_key(engine_type, name)
    return tostring(normalize_hash_id(engine_type)) .. "\0" .. tostring(normalize_hash_id(name))
end

local function package_key(package_name)
    return normalize_hash_id(package_name)
end

for _, asset in ipairs(manifest.assets) do
    if type(asset) == "table" and type(asset.logical_id) == "string" then
        assets_by_id[asset.logical_id] = asset
        asset_order[#asset_order + 1] = asset.logical_id
        if type(asset.package_name) == "string" and asset.package_name ~= "" then
            packages_by_name[package_key(asset.package_name)] = asset
        end
        for _, resource in ipairs(asset.resources or {}) do
            if type(resource) == "table" and type(resource.engine_type) == "string" and type(resource.name) == "string" then
                resources_by_key[resource_key(resource.engine_type, resource.name)] = {
                    asset = asset,
                    engine_type = resource.engine_type,
                    name = resource.name,
                    mode = resource.mode,
                    stream = resource.stream,
                }
            end
        end
    end
end

table.sort(asset_order)

local function copy_table(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        out[copy_table(key, seen)] = copy_table(item, seen)
    end
    return out
end

local function is_opaque(value)
    local normalized = normalize_hash_id(value)
    return type(normalized) == "string" and string.match(normalized, "^#ID%[%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%]$") ~= nil
end

local function can_get_resource(engine_type, name)
    if not Application or type(Application.can_get_resource) ~= "function" then return false end
    local ok, value = pcall(Application.can_get_resource, engine_type, name)
    return ok and value == true
end

local function verify_asset_visible(asset)
    for _, resource in ipairs(asset.resources or {}) do
        if not is_opaque(resource.engine_type) and not is_opaque(resource.name) then
            if not can_get_resource(resource.engine_type, resource.name) then
                return false, "patched resource is not visible: " .. resource.engine_type .. "/" .. resource.name
            end
        end
    end
    return true
end

local next_ticket_id = 0
local tickets = {}
local tickets_by_owner = {}
local completed_tickets = setmetatable({}, { __mode = "k" })
local callback_queue = {}

local function owner_name(owner)
    if type(owner) == "string" then return owner end
    if type(owner) == "table" then
        local get_name = owner.get_name
        if type(get_name) == "function" then
            local ok, name = pcall(get_name, owner)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
        return tostring(rawget(owner, "name") or rawget(owner, "_name") or owner)
    end
    return tostring(owner)
end

local function queue_callback(record, ticket, value, err)
    local callback = record.callback
    record.callback = nil
    if type(callback) ~= "function" then return end
    callback_queue[#callback_queue + 1] = {
        callback = callback,
        record = record,
        ticket = ticket,
        value = value,
        error = err,
    }
end

local function process_callbacks()
    if #callback_queue == 0 then return end
    local pending = callback_queue
    callback_queue = {}
    for index = 1, #pending do
        local delivery = pending[index]
        local record = delivery.record
        local status = record and record.status
        local deliver = tickets[delivery.ticket] == record or status == "failed" or status == "stale"
        if deliver then
            local ok, callback_error = pcall(delivery.callback, delivery.ticket, delivery.value, delivery.error)
            if not ok then
                mod:error("Callback failed: %s", tostring(callback_error))
            end
        end
    end
end

local function unregister_ticket(ticket, record, final_status)
    if tickets[ticket] ~= record then return end
    tickets[ticket] = nil
    ticket.status = final_status
    record.status = final_status
    completed_tickets[ticket] = final_status
    local owner_tickets = tickets_by_owner[record.owner]
    if owner_tickets then
        owner_tickets[ticket] = nil
        if not next(owner_tickets) then tickets_by_owner[record.owner] = nil end
    end
end

local function acquire_package(owner, package_name, public_value, verify, callback, options)
    if type(owner) ~= "table" and (type(owner) ~= "string" or owner == "") then
        return nil, "owner must be a mod/table or a non-empty string"
    elseif type(package_name) ~= "string" or package_name == "" then
        return nil, "asset has no package name"
    elseif callback ~= nil and type(callback) ~= "function" then
        return nil, "callback must be a function or nil"
    elseif options ~= nil and type(options) ~= "table" then
        return nil, "options must be a table or nil"
    end

    local package_manager = Managers and Managers.package
    local load = package_manager and package_manager.load
    if type(load) ~= "function" then
        return nil, "Managers.package is unavailable"
    elseif package_manager._shutdown_has_started == true then
        return nil, "the package manager is shutting down"
    end

    next_ticket_id = next_ticket_id + 1
    options = options or {}
    local ticket = { id = next_ticket_id, status = "pending", package_name = package_name }
    local record = {
        owner = owner,
        package_manager = package_manager,
        package_name = package_name,
        callback = callback,
        public_value = public_value,
        verify = verify,
        status = "pending",
    }
    local reference_name = options.reference_name
    if type(reference_name) ~= "string" or reference_name == "" then
        reference_name = string.format("CustomAssets:%s:%d", owner_name(owner), ticket.id)
    end
    record.reference_name = reference_name
    tickets[ticket] = record
    local owner_tickets = tickets_by_owner[owner]
    if not owner_tickets then
        owner_tickets = {}
        tickets_by_owner[owner] = owner_tickets
    end
    owner_tickets[ticket] = true

    local load_in_progress = true
    local loaded_during_call = false
    local callback_load_id = nil

    local function finish_loaded(load_id)
        if tickets[ticket] ~= record or record.status ~= "pending" then return end
        if record.package_manager ~= (Managers and Managers.package) then
            unregister_ticket(ticket, record, "stale")
            queue_callback(record, ticket, nil, "package manager changed before loading completed")
            return
        end
        record.package_id = load_id or record.package_id
        local verify_ok, visible, visible_error = pcall(record.verify)
        if not verify_ok then
            visible_error = "package visibility verification failed: " .. tostring(visible)
            visible = false
        end
        if not visible then
            local release = record.package_manager and record.package_manager.release
            if type(release) == "function" and record.package_id ~= nil then
                pcall(release, record.package_manager, record.package_id)
            end
            unregister_ticket(ticket, record, "failed")
            queue_callback(record, ticket, nil, visible_error)
            return
        end
        record.status = "loaded"
        ticket.status = "loaded"
        queue_callback(record, ticket, record.public_value, nil)
    end

    local function on_loaded(load_id)
        if load_in_progress then
            loaded_during_call = true
            callback_load_id = load_id
            return
        end
        finish_loaded(load_id)
    end

    local ok, package_id = pcall(
        load,
        package_manager,
        package_name,
        reference_name,
        on_loaded,
        options.prioritize == true,
        options.resident == true
    )
    load_in_progress = false
    if not ok or package_id == nil then
        unregister_ticket(ticket, record, "failed")
        if not ok then return nil, "package load failed: " .. tostring(package_id) end
        return nil, "package manager returned no load ID"
    end
    record.package_id = callback_load_id or package_id
    if loaded_during_call then finish_loaded(record.package_id) end
    return ticket
end

local function release_ticket(ticket)
    if type(ticket) ~= "table" then return false, "ticket must be a Custom Assets ticket" end
    local record = tickets[ticket]
    if not record then
        if completed_tickets[ticket] then return true end
        return false, "ticket is not active or was not created by Custom Assets"
    end
    local package_manager = record.package_manager
    if package_manager ~= (Managers and Managers.package) or package_manager._shutdown_has_started == true then
        unregister_ticket(ticket, record, "stale")
        return true
    end
    local release = package_manager.release
    if type(release) ~= "function" then return false, "Managers.package.release is unavailable" end
    local ok, err = pcall(release, package_manager, record.package_id)
    if not ok then return false, "package release failed: " .. tostring(err) end
    unregister_ticket(ticket, record, "released")
    return true
end

mod.update = function()
    process_callbacks()
end

mod.is_api_compatible = function(required_version)
    return required_version == mod.API_VERSION
end

mod.get_asset = function(logical_id)
    local asset = assets_by_id[logical_id]
    if not asset then return nil, "unknown custom asset '" .. tostring(logical_id) .. "'" end
    return copy_table(asset)
end

mod.list_assets = function(owner)
    local out = {}
    for _, logical_id in ipairs(asset_order) do
        local asset = assets_by_id[logical_id]
        if asset and (owner == nil or asset.owner == owner) then out[#out + 1] = copy_table(asset) end
    end
    return out
end

mod.resolve_resource = function(engine_type, name)
    if type(engine_type) ~= "string" or engine_type == "" or type(name) ~= "string" or name == "" then
        return nil, "engine_type and name must be non-empty strings"
    end
    local resource = resources_by_key[resource_key(engine_type, name)]
    if not resource then return nil, "unknown custom resource '" .. engine_type .. "/" .. name .. "'" end
    return copy_table(resource)
end

mod.can_get_resource = can_get_resource

mod.acquire = function(owner, logical_id, callback, options)
    local asset = assets_by_id[logical_id]
    if not asset then return nil, "unknown custom asset '" .. tostring(logical_id) .. "'" end
    return acquire_package(owner, asset.package_name, copy_table(asset), function()
        return verify_asset_visible(asset)
    end, callback, options)
end

mod.acquire_resource = function(owner, engine_type, name, callback, options)
    local resource = resources_by_key[resource_key(engine_type, name)]
    if not resource then
        return nil, "unknown custom resource '" .. tostring(engine_type) .. "/" .. tostring(name) .. "'"
    end
    return acquire_package(owner, resource.asset.package_name, copy_table(resource), function()
        if is_opaque(resource.engine_type) or is_opaque(resource.name)
            or can_get_resource(resource.engine_type, resource.name) then return true end
        return false, "patched resource is not visible: " .. resource.engine_type .. "/" .. resource.name
    end, callback, options)
end

mod.acquire_package = function(owner, package_name, callback, options)
    if type(package_name) ~= "string" or package_name == "" then
        return nil, "package_name must be a non-empty string"
    end
    local asset = packages_by_name[package_key(package_name)]
    if not asset then return nil, "unknown Custom Assets package '" .. tostring(package_name) .. "'" end
    return acquire_package(owner, asset.package_name, copy_table(asset), function()
        return verify_asset_visible(asset)
    end, callback, options)
end

mod.list_resources = function(engine_type, owner)
    local normalized_type = engine_type ~= nil and normalize_hash_id(engine_type) or nil
    if engine_type ~= nil and (type(engine_type) ~= "string" or engine_type == "") then
        return nil, "engine_type must be a non-empty string or nil"
    end
    local out = {}
    for _, logical_id in ipairs(asset_order) do
        local asset = assets_by_id[logical_id]
        if asset and (owner == nil or asset.owner == owner) then
            for _, resource in ipairs(asset.resources or {}) do
                if normalized_type == nil or normalize_hash_id(resource.engine_type) == normalized_type then
                    out[#out + 1] = copy_table({
                        asset = asset,
                        engine_type = resource.engine_type,
                        name = resource.name,
                        mode = resource.mode,
                        stream = resource.stream,
                    })
                end
            end
        end
    end
    return out
end

mod.release = release_ticket

mod.release_owner = function(owner)
    local owner_tickets = tickets_by_owner[owner]
    if not owner_tickets then return 0, 0 end
    local pending = {}
    for ticket in pairs(owner_tickets) do pending[#pending + 1] = ticket end
    local released, failed = 0, 0
    for _, ticket in ipairs(pending) do
        local ok = release_ticket(ticket)
        if ok then released = released + 1 else failed = failed + 1 end
    end
    return released, failed
end

mod.status = function(ticket)
    local record = tickets[ticket]
    if record then
        if record.package_manager ~= (Managers and Managers.package) then return "stale" end
        return record.status
    end
    return completed_tickets[ticket] or "unknown"
end

mod.stats = function()
    local active_ticket_count = 0
    for _ in pairs(tickets) do active_ticket_count = active_ticket_count + 1 end
    return {
        version = mod.VERSION,
        api_version = mod.API_VERSION,
        asset_count = #asset_order,
        resource_count = manifest.patch and manifest.patch.resource_count or 0,
        stream_count = manifest.patch and manifest.patch.stream_count or 0,
        package_count = manifest.patch and manifest.patch.package_count or 0,
        bundle_count = manifest.patch and manifest.patch.bundle_count or 0,
        active_ticket_count = active_ticket_count,
    }
end

mod.debug_manifest = function()
    return copy_table(manifest)
end

mod.debug_active_tickets = function()
    local out = {}
    for ticket, record in pairs(tickets) do
        out[#out + 1] = {
            id = ticket.id,
            status = record.status,
            package_name = record.package_name,
            reference_name = record.reference_name,
            owner = owner_name(record.owner),
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

mod.on_all_mods_loaded = function()
    if #asset_order == 0 then
        if manifest_load_error then
            mod:warning("Custom Assets manifest is unavailable. Close Darktide and run CUSTOM_ASSETS_PATCH.bat.")
        else
            mod:info(" %s ready: no assets installed.", mod.VERSION)
        end
    else
        mod:info(
            " %s ready: %d asset(s), %d resource(s).",
            mod.VERSION,
            #asset_order,
            manifest.patch and manifest.patch.resource_count or 0
        )
    end
end

mod.on_unload = function()
    local pending = {}
    for ticket in pairs(tickets) do pending[#pending + 1] = ticket end
    local failed = 0
    for _, ticket in ipairs(pending) do
        local ok = release_ticket(ticket)
        if not ok then failed = failed + 1 end
    end
    if failed > 0 then mod:error("Custom Assets could not release %d package reference(s) during unload.", failed) end
    callback_queue = {}
end

mod:command("custom_assets_status", "Show Custom Assets status", function()
    local status = mod.stats()
    mod:echo(
        " %s / API %d / %d asset(s) / %d resource(s) / %d package(s)",
        status.version,
        status.api_version,
        status.asset_count,
        status.resource_count,
        status.package_count
    )
    if manifest_load_error then mod:echo("Manifest error: %s", manifest_load_error) end
end)

mod:command("custom_assets_list", "List installed Custom Assets", function()
    if #asset_order == 0 then
        mod:echo("No Custom Assets are installed. Run CUSTOM_ASSETS_PATCH.bat with Darktide closed.")
        return
    end
    for _, logical_id in ipairs(asset_order) do
        local asset = assets_by_id[logical_id]
        local source_kind = asset.source and asset.source.kind or "unknown"
        mod:echo(
            "%s [%s/%s] -> %s/%s (%d resource(s))",
            logical_id,
            tostring(source_kind),
            tostring(asset.kind),
            tostring(asset.primary and asset.primary.engine_type),
            tostring(asset.primary and asset.primary.name),
            #(asset.resources or {})
        )
    end
end)

mod:command("custom_assets_check", "Load-check one Custom Asset", function(logical_id)
    if type(logical_id) ~= "string" or logical_id == "" then
        mod:echo("Usage: /custom_assets_check ModName:asset_id")
        return
    end
    local ticket, err = mod.acquire(mod, logical_id, function(loaded_ticket, asset, load_error)
        if load_error then
            mod:echo("FAILED: %s", tostring(load_error))
            return
        end
        mod:echo("READY: %s", tostring(asset.logical_id))
        mod.release(loaded_ticket)
    end)
    if not ticket then mod:echo("FAILED: %s", tostring(err)) end
end)
