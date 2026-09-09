local function discover_installed_mods()
    local result = {}
    local seen = {}
    local lua_io = Mods and Mods.lua and Mods.lua.io
    local popen = lua_io and lua_io.popen
    local open = lua_io and lua_io.open

    if type(popen) ~= "function" and io then
        popen = io.popen
    end

    if type(popen) ~= "function" then
        return result
    end

    local function is_valid_mod_folder(folder)
        if type(open) ~= "function" then
            return true
        end

        local path = "./../mods/" .. folder .. "/" .. folder .. ".mod"
        local ok, file = pcall(open, path, "r")

        if not ok or not file then
            return false
        end

        pcall(file.close, file)
        return true
    end

    local commands = {
        'cmd /d /s /c "dir /b /ad .\\..\\mods 2>nul"',
        'ls -1 ./../mods 2>/dev/null',
    }

    for command_index = 1, #commands do
        local ok, pipe = pcall(popen, commands[command_index])

        if ok and pipe then
            while true do
                local read_ok, folder = pcall(pipe.read, pipe, "*l")

                if not read_ok or not folder then
                    break
                end

                folder = string.gsub(folder, "^%s+", "")
                folder = string.gsub(folder, "%s+$", "")

                local lower = string.lower(folder)
                local eligible = folder ~= ""
                    and string.sub(folder, 1, 1) ~= "_"
                    and lower ~= "base"
                    and lower ~= "dmf"
                    and lower ~= "resourceloader"
                    and not seen[folder]
                    and is_valid_mod_folder(folder)

                if eligible then
                    seen[folder] = true
                    result[#result + 1] = folder
                end
            end

            pcall(pipe.close, pipe)

            if #result > 0 then
                break
            end
        end
    end

    table.sort(result)
    return result
end

return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`ResourceLoader` encountered an error loading the Darktide Mod Framework.")

        new_mod("ResourceLoader", {
            mod_script = "ResourceLoader/scripts/mods/ResourceLoader/ResourceLoader",
            mod_data = "ResourceLoader/scripts/mods/ResourceLoader/ResourceLoader_data",
            mod_localization = "ResourceLoader/scripts/mods/ResourceLoader/ResourceLoader_localization",
        })
    end,
    load_before = discover_installed_mods(),
    version = "1.0.0-aml-first",
    packages = {},
}
