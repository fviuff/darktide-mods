local PresetStore = {}
local SCHEMA_VERSION = 1

local function truncate_utf8(value, limit)
    local utf8_api = rawget(_G, "Utf8")

    if utf8_api and type(utf8_api.string_length) == "function"
        and type(utf8_api.sub_string) == "function" then
        local ok_length, length = pcall(utf8_api.string_length, value)

        if ok_length and type(length) == "number" and length <= limit then
            return value
        elseif ok_length then
            local ok_substring, substring = pcall(utf8_api.sub_string, value, 1, limit)

            if ok_substring and type(substring) == "string" then
                return substring
            end
        end
    end

    local byte_index = 1
    local character_count = 0
    local byte_length = #value

    while byte_index <= byte_length and character_count < limit do
        local first_byte = string.byte(value, byte_index)
        local width = first_byte < 0x80 and 1
            or first_byte < 0xE0 and 2
            or first_byte < 0xF0 and 3
            or first_byte < 0xF8 and 4
            or 1

        if byte_index + width - 1 > byte_length then
            break
        end

        byte_index = byte_index + width
        character_count = character_count + 1
    end

    return string.sub(value, 1, byte_index - 1)
end

local function method_result(object, method_name, ...)
    local method = object and object[method_name]

    if type(method) ~= "function" then
        return false, method_name .. " is unavailable"
    end

    local ok, result, error_message = pcall(method, object, ...)

    if not ok then
        return false, result
    elseif result == false or result == nil then
        return false, error_message
    end

    return true, result
end

function PresetStore.new(dependencies)
    dependencies = dependencies or {}

    local mod = dependencies.mod
    local disk = dependencies.disk
    local loc = dependencies.loc
    local has_look_code_prefix = dependencies.has_look_code_prefix
    local store = {
        file_name = "presets.json",
        items = {},
        name_limit = 48,
        schema_version = SCHEMA_VERSION,
    }

    function store.paths()
        local appdata = disk.os.getenv("APPDATA")

        if type(appdata) ~= "string" or appdata == "" then
            return nil, nil
        end

        appdata = string.gsub(appdata, "/", [[\]])
        appdata = string.gsub(appdata, [[[\]+$]], "")

        local directory = appdata .. [[\Fatshark\Darktide\NPCLook]]

        return directory, directory .. [[\]] .. store.file_name
    end

    function store.path_exists(path)
        if type(path) ~= "string" or path == "" then
            return false
        end

        local file = disk.io.open(path, "r")

        if file then
            pcall(file.close, file)
            return true
        end

        local called, result, _, code = pcall(disk.os.rename, path, path)

        return called and (result == true or code == 13)
    end

    function store.directory_exists(path)
        if type(path) ~= "string" or path == "" then
            return false
        end

        local directory = string.gsub(path, [[[/\]+$]], "") .. [[\]]
        local called, result, _, code = pcall(disk.os.rename, directory, directory)

        return called and (result == true or code == 13)
    end

    function store.directory_writable(path)
        local probe_path = path .. [[\.npclook_write_test.tmp]]
        local file, open_error = disk.io.open(probe_path, "w")

        if not file then
            return false, open_error
        end

        local close_ok, close_error = method_result(file, "close")

        if not close_ok then
            pcall(disk.os.remove, probe_path)
            return false, close_error
        end

        local remove_ok, remove_result, remove_error = pcall(disk.os.remove, probe_path)

        if not remove_ok or remove_result == nil or remove_result == false then
            return false, remove_ok and remove_error or remove_result
        end

        return true
    end

    function store.remove_path(path)
        if not path or not store.path_exists(path) then
            return true
        end

        local ok, result, error_message = pcall(disk.os.remove, path)

        return ok and result ~= nil, ok and error_message or result
    end

    function store.rename_path(source, destination)
        local ok, result, error_message = pcall(disk.os.rename, source, destination)

        if not ok then
            return false, result
        elseif result == nil or result == false then
            return false, error_message
        end

        return true
    end

    function store.read_file(path)
        local file, open_error = disk.io.open(path, "r")

        if not file then
            return nil, tostring(open_error or loc("error_preset_write"))
        end

        local read_ok, contents, read_error = pcall(file.read, file, "*a")
        local close_ok, close_error = method_result(file, "close")

        if not read_ok or type(contents) ~= "string" then
            return nil, tostring(read_error or (not read_ok and contents) or loc("error_preset_write"))
        elseif not close_ok then
            return nil, tostring(close_error or loc("error_preset_write"))
        end

        return contents
    end

    function store.ensure_directory()
        local directory = store.paths()

        if not directory then
            return false, loc("error_preset_path")
        end

        if not store.directory_exists(directory) then
            local quoted_directory = string.gsub(directory, '"', '""')

            pcall(disk.os.execute, 'mkdir "' .. quoted_directory .. '" >NUL 2>NUL')
        end

        local writable, write_error = store.directory_writable(directory)

        if not writable then
            return false, tostring(write_error or loc("error_preset_directory"))
        end

        return true
    end

    function store.normalize_name(value)
        value = type(value) == "string" and value or ""
        value = string.gsub(value, "[%c]", "")
        value = string.gsub(value, "^%s+", "")
        value = string.gsub(value, "%s+$", "")
        value = string.gsub(value, "%s+", " ")

        value = truncate_utf8(value, store.name_limit)

        return value
    end

    function store.decode_contents(contents)
        if type(contents) ~= "string" or contents == "" then
            return nil, "empty"
        end

        local json = rawget(_G, "cjson")

        if not json or type(json.decode) ~= "function" then
            return nil, "cjson is unavailable"
        end

        local ok, data = pcall(json.decode, contents)

        if not ok or type(data) ~= "table" or type(data.presets) ~= "table" then
            return nil, "invalid preset JSON"
        elseif data.version ~= nil and data.version ~= SCHEMA_VERSION then
            return nil, "unsupported preset schema version: " .. tostring(data.version)
        end

        return data
    end

    function store.sort()
        table.sort(store.items, function(left, right)
            return string.lower(left.name) < string.lower(right.name)
        end)
    end

    function store.clone()
        local copy = {}

        for i = 1, #store.items do
            copy[i] = {
                name = store.items[i].name,
                code = store.items[i].code,
            }
        end

        return copy
    end

    function store.index(name)
        local wanted = string.lower(store.normalize_name(name))

        for i = 1, #store.items do
            if string.lower(store.items[i].name) == wanted then
                return i
            end
        end

        return nil
    end

    function store.recover_atomic_files()
        local _, path = store.paths()

        if not path then
            return false, loc("error_preset_path")
        end

        local temporary_path = path .. ".tmp"
        local backup_path = path .. ".bak"

        local function candidate(path_to_check)
            if not store.path_exists(path_to_check) then
                return false, false
            end

            local contents, read_error = store.read_file(path_to_check)

            if contents == nil then
                return true, false, read_error
            end

            local _, decode_error = store.decode_contents(contents)

            return true, decode_error == nil, decode_error
        end

        local main_exists, main_valid, main_error = candidate(path)
        local temporary_exists, temporary_valid, temporary_error = candidate(temporary_path)
        local backup_exists, backup_valid, backup_error = candidate(backup_path)

        if main_valid then
            store.remove_path(temporary_path)
            store.remove_path(backup_path)
            return true
        end

        local recovery_path = temporary_valid and temporary_path or backup_valid and backup_path or nil

        if recovery_path then
            if main_exists then
                local removed, remove_error = store.remove_path(path)

                if not removed then
                    return false, remove_error
                end
            end

            local recovered, recover_error = store.rename_path(recovery_path, path)

            if recovered then
                -- A completed recovery must leave one authoritative file. A
                -- stale valid backup can otherwise survive indefinitely and be
                -- mistaken for a newer recovery candidate after a later fault.
                store.remove_path(temporary_path)
                store.remove_path(backup_path)

                return true
            end

            if recovery_path == temporary_path and backup_valid then
                local backup_recovered, backup_recover_error = store.rename_path(backup_path, path)

                if backup_recovered then
                    store.remove_path(temporary_path)
                end

                return backup_recovered, backup_recover_error
            end

            return false, recover_error
        end

        if main_exists then
            local main_contents = store.read_file(path)

            if main_contents == "" and not temporary_exists and not backup_exists then
                return true
            end

            return false, main_error or temporary_error or backup_error or "invalid preset JSON"
        end

        if temporary_exists or backup_exists then
            return false, temporary_error or backup_error or "invalid preset JSON"
        end

        return true
    end

    function store.read()
        local _, path = store.paths()

        if not path then
            return false, loc("error_preset_path")
        end

        local contents, read_error = store.read_file(path)

        if contents == nil then
            return false, read_error
        elseif contents == "" then
            return false, "empty"
        end

        local data, decode_error = store.decode_contents(contents)

        if not data then
            return false, decode_error
        end

        table.clear(store.items)

        for i = 1, #data.presets do
            local entry = data.presets[i]
            local name = type(entry) == "table" and store.normalize_name(entry.name) or ""
            local code = type(entry) == "table" and entry.code or nil

            if name ~= "" and type(code) == "string" and has_look_code_prefix(code) then
                store.items[#store.items + 1] = { name = name, code = code }
            end
        end

        store.sort()

        return true
    end

    function store.write()
        local directory_ok, directory_error = store.ensure_directory()

        if not directory_ok then
            return false, directory_error
        end

        local _, path = store.paths()
        local json = rawget(_G, "cjson")

        if not json or type(json.encode) ~= "function" then
            return false, loc("error_preset_encode")
        end

        local ok, encoded = pcall(json.encode, {
            version = SCHEMA_VERSION,
            presets = store.items,
        })

        if not ok or type(encoded) ~= "string" then
            return false, loc("error_preset_encode")
        end

        local temporary_path = path .. ".tmp"
        local backup_path = path .. ".bak"
        local file, open_error = disk.io.open(temporary_path, "w")

        if not file then
            return false, tostring(open_error or loc("error_preset_write"))
        end

        local write_ok, wrote, write_error = pcall(file.write, file, encoded .. "\n")
        local flush_ok, flush_error = method_result(file, "flush")
        local close_ok, close_error = method_result(file, "close")

        if not write_ok or wrote == nil or wrote == false then
            store.remove_path(temporary_path)
            return false, tostring(write_error or (not write_ok and wrote) or loc("error_preset_write"))
        elseif not flush_ok then
            store.remove_path(temporary_path)
            return false, tostring(flush_error or loc("error_preset_write"))
        elseif not close_ok then
            store.remove_path(temporary_path)
            return false, tostring(close_error or loc("error_preset_write"))
        end

        local backup_removed, backup_remove_error = store.remove_path(backup_path)

        if not backup_removed and store.path_exists(backup_path) then
            store.remove_path(temporary_path)
            return false, tostring(backup_remove_error or loc("error_preset_write"))
        end

        local had_existing = store.path_exists(path)

        if had_existing then
            local backed_up, backup_error = store.rename_path(path, backup_path)

            if not backed_up then
                store.remove_path(temporary_path)
                return false, tostring(backup_error or loc("error_preset_write"))
            end
        end

        local replaced, replace_error = store.rename_path(temporary_path, path)

        if not replaced then
            if had_existing and store.path_exists(backup_path) then
                store.rename_path(backup_path, path)
            end

            store.remove_path(temporary_path)
            return false, tostring(replace_error or loc("error_preset_write"))
        end

        store.remove_path(backup_path)

        return true
    end

    function store.ensure_file()
        local directory_ok, directory_error = store.ensure_directory()

        if not directory_ok then
            return false, directory_error
        end

        local recovered, recover_error = store.recover_atomic_files()

        if not recovered then
            return false, recover_error
        end

        local _, path = store.paths()

        if not path then
            return false, loc("error_preset_path")
        end

        if store.path_exists(path) then
            local contents, read_error = store.read_file(path)

            if contents == nil then
                return false, read_error
            elseif contents ~= "" then
                return true
            end
        end

        return store.write()
    end

    function store.initialize()
        -- The directory and file only need validating once; later opens just reread presets.
        if not store.file_ready then
            local ready, ready_error = store.ensure_file()

            if not ready then
                mod:error("Could not create player preset file: %s", tostring(ready_error))
                return false
            end

            store.file_ready = true
        end

        local read_ok, read_error = store.read()

        if not read_ok then
            mod:error("Could not read player presets: %s", tostring(read_error))
            return false
        end

        return true
    end

    return store
end

return PresetStore
