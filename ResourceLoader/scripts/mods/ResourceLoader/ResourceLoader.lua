local mod = get_mod("ResourceLoader")

local VERSION = "1.0.0"
local API_VERSION = 1
local CATALOG_INDEX = "ResourceLoader/scripts/mods/ResourceLoader/catalog/index"
local CATALOG_BASE = "ResourceLoader/scripts/mods/ResourceLoader/catalog/"
local MOD_DIRECTORY = "./../mods/"
local TYPE_NAME = 1
local ENGINE_TYPE = 2
local RESOURCE_COUNT = 3
local LOADABLE_COUNT = 4
local TYPE_CHUNKS = 5
local CHUNK_MAXIMUM_KEY = 1
local CHUNK_PATH = 2
local CHUNK_RESOURCE_COUNT = 3
local RESOURCE_KEY = 1
local PACKAGE_INDEX = 2
local math_floor = math.floor
local string_format = string.format
local string_gsub = string.gsub
local string_lower = string.lower
local string_match = string.match
local string_sub = string.sub

local catalog
local catalog_error
local engine_type_index
local shard_cache = {}
local chunk_errors = {}
local tickets = {}
local tickets_by_owner = {}
local completed_tickets = setmetatable({}, { __mode = "k" })
local callback_queue = {}
local next_ticket_id = 0
local active_ticket_count = 0
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

    local compile_ok, chunk, compile_error = pcall(
        compile_lua,
        source,
        "@" .. file_path
    )

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

local function normalize_hash_id(value)
    local hash = string_match(value, "^#ID%[([%x]+)%]$")

    return hash and "#ID[" .. string_lower(hash) .. "]" or value
end

local function normalize_resource_key(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end

    return normalize_hash_id((string_gsub(value, "\\", "/")))
end

local function ensure_catalog()
    if catalog then
        return catalog
    elseif catalog_error then
        return nil, catalog_error
    end

    local value, load_error = load_lua_file(CATALOG_INDEX)

    if not value then
        catalog_error = "could not read the resource catalog: " .. tostring(load_error)
        mod:error("%s", catalog_error)
        return nil, catalog_error
    elseif type(value) ~= "table"
        or value.schema_version ~= 2
        or type(value.types) ~= "table"
        or type(value.type_index) ~= "table" then
        catalog_error = "resource catalog schema is missing or unsupported"
        mod:error("%s", catalog_error)
        return nil, catalog_error
    end

    catalog = value
    engine_type_index = {}

    for index = 1, #catalog.types do
        engine_type_index[catalog.types[index][ENGINE_TYPE]] = index
    end

    return catalog
end

local function resolve_type(resource_type_or_index)
    local current_catalog, err = ensure_catalog()

    if not current_catalog then
        return nil, nil, err
    end

    local index = resource_type_or_index

    if type(index) == "string" then
        local normalized = normalize_hash_id(index)
        index = current_catalog.type_index[normalized]
            or current_catalog.type_index[string_lower(normalized)]
            or engine_type_index[normalized]
    end

    if type(index) ~= "number" or index % 1 ~= 0 then
        return nil, nil, "unknown resource type: " .. tostring(resource_type_or_index)
    end

    local type_row = current_catalog.types[index]

    if not type_row then
        return nil, nil, "unknown resource type index: " .. tostring(index)
    end

    return index, type_row
end


local function select_chunk(type_row, key)
    local chunks = type_row[TYPE_CHUNKS]
    local low = 1
    local high = #chunks
    local selected

    while low <= high do
        local middle = math_floor((low + high) / 2)
        local chunk = chunks[middle]

        if key <= chunk[CHUNK_MAXIMUM_KEY] then
            selected = chunk
            high = middle - 1
        else
            low = middle + 1
        end
    end

    return selected
end

local function load_chunk(type_row, chunk_route)
    local path = chunk_route[CHUNK_PATH]
    local cached = shard_cache[path]

    if cached then
        return cached
    elseif chunk_errors[path] then
        return nil, chunk_errors[path]
    end

    local chunk, load_error = load_lua_file(CATALOG_BASE .. path)
    local error_message

    if not chunk then
        error_message = "could not read the " .. type_row[TYPE_NAME]
            .. " resource chunk: " .. tostring(load_error)
    elseif type(chunk) ~= "table"
        or chunk.schema_version ~= 2
        or type(chunk.packages) ~= "table"
        or type(chunk.resources) ~= "table"
        or #chunk.resources ~= chunk_route[CHUNK_RESOURCE_COUNT] then
        error_message = "invalid " .. type_row[TYPE_NAME] .. " resource chunk"
    end

    if error_message then
        chunk_errors[path] = error_message
        mod:error("%s", error_message)
        return nil, error_message
    end

    shard_cache[path] = chunk

    return chunk
end

local function find_row(rows, key)
    local low = 1
    local high = #rows

    while low <= high do
        local middle = math_floor((low + high) / 2)
        local row = rows[middle]
        local candidate = row[RESOURCE_KEY]

        if candidate == key then
            return row
        elseif candidate < key then
            low = middle + 1
        else
            high = middle - 1
        end
    end

    return nil
end

local function resolve_resource(resource_type, resource_name)
    local key = normalize_resource_key(resource_name)

    if not key then
        return nil, "resource name must be a non-empty string"
    end

    local _, type_row, err = resolve_type(resource_type)

    if not type_row then
        return nil, err
    end

    local chunk_route = select_chunk(type_row, key)

    if not chunk_route then
        return nil, string_format(
            "resource was not found: %s:%s",
            type_row[TYPE_NAME],
            key
        )
    end

    local chunk, chunk_error = load_chunk(type_row, chunk_route)

    if not chunk then
        return nil, chunk_error
    end

    local row = find_row(chunk.resources, key)

    if not row then
        return nil, string_format(
            "resource was not found: %s:%s",
            type_row[TYPE_NAME],
            key
        )
    end

    local package_index = row[PACKAGE_INDEX]

    return {
        resource_type = type_row[TYPE_NAME],
        engine_type = type_row[ENGINE_TYPE],
        name = row[RESOURCE_KEY],
        package_name = package_index > 0 and chunk.packages[package_index] or nil,
        package_index = package_index,
        loadable = package_index > 0,
    }
end

local function visit_resources(resource_type, callback, options)
    if type(callback) ~= "function" then
        return nil, "callback must be a function"
    elseif options ~= nil and type(options) ~= "table" then
        return nil, "options must be a table or nil"
    end

    local _, type_row, err = resolve_type(resource_type)

    if not type_row then
        return nil, err
    end

    options = options or {}

    local named_only = options.named_only == true
    local loadable_only = options.loadable_only == true
    local retain_chunks = options.retain_chunks ~= false
    local chunks = type_row[TYPE_CHUNKS]
    local type_name = type_row[TYPE_NAME]
    local engine_type = type_row[ENGINE_TYPE]
    local transient_paths = {}
    local visited = 0
    local stopped = false

    local ok, loop_error = pcall(function()
        for chunk_index = 1, #chunks do
            local route = chunks[chunk_index]
            local path = route[CHUNK_PATH]
            local was_cached = shard_cache[path] ~= nil
            local chunk, chunk_error = load_chunk(type_row, route)

            if not chunk then
                error(chunk_error, 0)
            elseif not retain_chunks and not was_cached then
                transient_paths[#transient_paths + 1] = path
            end

            local rows = chunk.resources
            local packages = chunk.packages

            for row_index = 1, #rows do
                local row = rows[row_index]
                local resource_name = row[RESOURCE_KEY]
                local package_index = row[PACKAGE_INDEX]
                local package_name = package_index > 0 and packages[package_index] or nil
                local is_hash = string_sub(resource_name, 1, 4) == "#ID["

                if (not named_only or not is_hash)
                    and (not loadable_only or package_name ~= nil) then
                    visited = visited + 1

                    if callback(
                        resource_name,
                        package_name,
                        type_name,
                        engine_type,
                        package_index
                    ) == false then
                        stopped = true
                        return
                    end
                end
            end
        end
    end)

    for index = 1, #transient_paths do
        shard_cache[transient_paths[index]] = nil
    end

    if not ok then
        return nil, tostring(loop_error)
    end

    return visited, stopped
end

local function owner_name(owner)
    if type(owner) == "string" then
        return owner
    elseif type(owner) == "table" and type(owner.get_name) == "function" then
        local ok, name = pcall(owner.get_name, owner)

        if ok and type(name) == "string" then
            return name
        end
    end

    return tostring(owner)
end

local function unregister_ticket(ticket, record, final_status)
    if tickets[ticket] ~= record then
        return
    end

    tickets[ticket] = nil
    active_ticket_count = active_ticket_count - 1
    ticket.status = final_status
    completed_tickets[ticket] = final_status

    local owner_tickets = tickets_by_owner[record.owner]

    if owner_tickets then
        owner_tickets[ticket] = nil

        if not next(owner_tickets) then
            tickets_by_owner[record.owner] = nil
        end
    end
end

local function queue_ready_callback(ticket, record, err, require_active)
    local callback = record.callback

    record.callback = nil

    if callback then
        callback_queue[#callback_queue + 1] = {
            callback = callback,
            error = err,
            package_name = record.package_name,
            record = require_active and record or nil,
            resource = err and nil or record.resource,
            ticket = ticket,
        }
    end
end

local function process_callback_queue()
    if #callback_queue == 0 then
        return
    end

    local pending = callback_queue
    callback_queue = {}

    for index = 1, #pending do
        local delivery = pending[index]
        local record = delivery.record

        if not record or tickets[delivery.ticket] == record then
            local ok, callback_error = pcall(
                delivery.callback,
                delivery.ticket,
                delivery.resource,
                delivery.error
            )

            if not ok then
                mod:error(
                    "ResourceLoader callback for %s failed: %s",
                    delivery.package_name,
                    tostring(callback_error)
                )
            end
        end
    end
end

local function acquire_package(owner, package_name, callback, options, resource)
    if type(owner) ~= "table" and (type(owner) ~= "string" or owner == "") then
        return nil, "owner must be a mod/table or a non-empty string"
    elseif type(package_name) ~= "string" or package_name == "" then
        return nil, "package name must be a non-empty string"
    elseif callback ~= nil and type(callback) ~= "function" then
        return nil, "callback must be a function or nil"
    elseif options ~= nil and type(options) ~= "table" then
        return nil, "options must be a table or nil"
    end

    local package_manager = Managers and Managers.package
    local load = package_manager and package_manager.load

    if type(load) ~= "function" then
        return nil, "Managers.package is not available"
    elseif package_manager._shutdown_has_started == true then
        return nil, "the package manager is shutting down"
    end

    options = options or {}
    next_ticket_id = next_ticket_id + 1

    local ticket = {
        id = next_ticket_id,
        status = "pending",
        package_name = package_name,
        resource = resource,
    }
    local record = {
        owner = owner,
        package_manager = package_manager,
        package_name = package_name,
        callback = callback,
        resource = resource,
        status = "pending",
    }
    local reference_name = options.reference_name

    if type(reference_name) ~= "string" or reference_name == "" then
        reference_name = string_format(
            "ResourceLoader:%s:%d",
            owner_name(owner),
            ticket.id
        )
    end

    record.reference_name = reference_name
    tickets[ticket] = record
    active_ticket_count = active_ticket_count + 1

    local owner_tickets = tickets_by_owner[owner]

    if not owner_tickets then
        owner_tickets = {}
        tickets_by_owner[owner] = owner_tickets
    end

    owner_tickets[ticket] = true

    local load_in_progress = true
    local loaded_during_call = false
    local callback_load_id

    local function finish_loaded(load_id)
        if tickets[ticket] ~= record or record.status ~= "pending" then
            return
        elseif record.package_manager ~= (Managers and Managers.package) then
            record.status = "stale"
            unregister_ticket(ticket, record, "stale")
            queue_ready_callback(
                ticket,
                record,
                "package manager changed before loading completed",
                false
            )
            return
        end

        record.package_id = load_id or record.package_id
        record.status = "loaded"
        ticket.status = "loaded"
        queue_ready_callback(ticket, record, nil, true)
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
        ticket.status = "failed"

        if not ok then
            return nil, "package load failed: " .. tostring(package_id)
        end

        return nil, "package manager returned no load ID"
    end

    record.package_id = callback_load_id or package_id

    if loaded_during_call then
        finish_loaded(record.package_id)
    end

    return ticket
end

local function release_ticket(ticket)
    if type(ticket) ~= "table" then
        return false, "ticket must be a ResourceLoader ticket"
    end

    local record = tickets[ticket]

    if not record then
        if completed_tickets[ticket] then
            return true
        end

        return false, "ticket is not active or was not created by ResourceLoader"
    end

    local package_manager = record.package_manager

    if package_manager ~= (Managers and Managers.package) then
        unregister_ticket(ticket, record, "stale")
        return true, "package manager changed; the old reference is already invalid"
    elseif package_manager._shutdown_has_started == true then
        unregister_ticket(ticket, record, "stale")
        return true, "package manager is shutting down"
    end

    local release = package_manager.release

    if type(release) ~= "function" then
        return false, "package manager release is unavailable"
    end

    local ok, err = pcall(release, package_manager, record.package_id)

    if not ok then
        return false, "package release failed: " .. tostring(err)
    end

    unregister_ticket(ticket, record, "released")

    return true
end

local function release_owner(owner)
    local owner_tickets = tickets_by_owner[owner]

    if not owner_tickets then
        return 0, 0
    end

    local pending = {}

    for ticket in pairs(owner_tickets) do
        pending[#pending + 1] = ticket
    end

    local released = 0
    local failed = 0

    for index = 1, #pending do
        local ok = release_ticket(pending[index])

        if ok then
            released = released + 1
        else
            failed = failed + 1
        end
    end

    return released, failed
end

local function release_all()
    local pending = {}

    for ticket in pairs(tickets) do
        pending[#pending + 1] = ticket
    end

    local released = 0
    local failed = 0

    for index = 1, #pending do
        local ok = release_ticket(pending[index])

        if ok then
            released = released + 1
        else
            failed = failed + 1
        end
    end

    return released, failed
end


mod.API_VERSION = API_VERSION
mod.VERSION = VERSION

mod.is_api_compatible = function(required_version)
    return required_version == API_VERSION
end

mod.resolve = resolve_resource
mod.visit = visit_resources

mod.acquire = function(owner, resource_type, resource_name, callback, options)
    local resource, err = resolve_resource(resource_type, resource_name)

    if not resource then
        return nil, err
    elseif not resource.package_name then
        return nil, "resource has no resolved package: " .. resource.engine_type
            .. ":" .. resource.name
    end

    return acquire_package(owner, resource.package_name, callback, options, resource)
end

mod.acquire_package = function(owner, package_name, callback, options)
    return acquire_package(owner, package_name, callback, options)
end

mod.release = release_ticket
mod.release_owner = release_owner
mod.update = process_callback_queue

mod.status = function(ticket)
    local record = tickets[ticket]

    if not record then
        return completed_tickets[ticket] or "unknown"
    elseif record.package_manager ~= (Managers and Managers.package) then
        return "stale"
    end

    return record.status
end

mod.warm_type = function(resource_type)
    local _, type_row, err = resolve_type(resource_type)

    if not type_row then
        return nil, err
    end

    local chunks = type_row[TYPE_CHUNKS]

    for index = 1, #chunks do
        local loaded, load_error = load_chunk(type_row, chunks[index])

        if not loaded then
            return nil, load_error
        end
    end

    return type_row[RESOURCE_COUNT], type_row[LOADABLE_COUNT]
end

mod.trim = function(resource_type)
    if resource_type == nil then
        local removed = 0

        for path in pairs(shard_cache) do
            shard_cache[path] = nil
            removed = removed + 1
        end

        return removed
    end

    local _, type_row, err = resolve_type(resource_type)

    if not type_row then
        return nil, err
    end

    local chunks = type_row[TYPE_CHUNKS]
    local removed = 0

    for index = 1, #chunks do
        local path = chunks[index][CHUNK_PATH]

        if shard_cache[path] then
            shard_cache[path] = nil
            removed = removed + 1
        end
    end

    return removed
end

mod.list_types = function()
    local current_catalog, err = ensure_catalog()

    if not current_catalog then
        return nil, err
    end

    local result = {}

    for index = 1, #current_catalog.types do
        local row = current_catalog.types[index]
        local chunks = row[TYPE_CHUNKS]
        local cached_chunk_count = 0

        for chunk_index = 1, #chunks do
            if shard_cache[chunks[chunk_index][CHUNK_PATH]] then
                cached_chunk_count = cached_chunk_count + 1
            end
        end

        result[index] = {
            resource_type = row[TYPE_NAME],
            engine_type = row[ENGINE_TYPE],
            resource_count = row[RESOURCE_COUNT],
            package_loadable_count = row[LOADABLE_COUNT],
            chunk_count = #chunks,
            cached_chunk_count = cached_chunk_count,
            cached = cached_chunk_count == #chunks,
        }
    end

    return result
end


mod.stats = function()
    local cached_chunk_count = 0
    local cached_type_count = 0

    for _ in pairs(shard_cache) do
        cached_chunk_count = cached_chunk_count + 1
    end

    if catalog then
        for type_index = 1, #catalog.types do
            local chunks = catalog.types[type_index][TYPE_CHUNKS]

            for chunk_index = 1, #chunks do
                if shard_cache[chunks[chunk_index][CHUNK_PATH]] then
                    cached_type_count = cached_type_count + 1
                    break
                end
            end
        end
    end

    return {
        api_version = API_VERSION,
        version = VERSION,
        catalog_loaded = catalog ~= nil,
        cached_type_count = cached_type_count,
        cached_chunk_count = cached_chunk_count,
        active_ticket_count = active_ticket_count,
        resource_count = catalog and catalog.resource_count or nil,
        named_resource_count = catalog and catalog.named_resource_count or nil,
        hash_resource_count = catalog and catalog.hash_resource_count or nil,
        package_loadable_count = catalog and catalog.package_loadable_count or nil,
        selected_package_count = catalog and catalog.selected_package_count or nil,
        chunk_count = catalog and catalog.chunk_count or nil,
    }
end

mod.on_unload = function()
    local _, failed = release_all()

    if failed > 0 then
        mod:error(
            "ResourceLoader could not release %d package reference(s) during unload.",
            failed
        )
    end

    shard_cache = {}
    chunk_errors = {}
    tickets = {}
    tickets_by_owner = {}
    completed_tickets = setmetatable({}, { __mode = "k" })
    callback_queue = {}
    active_ticket_count = 0
    catalog = nil
    catalog_error = nil
    engine_type_index = nil
end
