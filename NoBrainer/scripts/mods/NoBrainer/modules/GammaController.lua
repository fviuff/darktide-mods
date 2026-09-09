local mod = get_mod("NoBrainer")
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")

local api = {}
local original_gamma = nil
local captured = false
local applied = false

local function apply_user_settings()
    if Application.apply_user_settings then
        pcall(Application.apply_user_settings)
    end
end

local function capture_original()
    if captured then return end
    captured = true
    if Application.user_setting then
        local ok, value = pcall(Application.user_setting, "gamma")
        if ok then original_gamma = value end
    end
end

function api.apply()
    if settings.boolean("darkness_enabled") then
        capture_original()
        if Application.set_user_setting then
            pcall(Application.set_user_setting, "gamma", settings.number("gamma_level"))
            apply_user_settings()
            applied = true
        end
    elseif applied then
        api.restore()
    end
end

function api.restore()
    if applied and original_gamma ~= nil and Application.set_user_setting then
        pcall(Application.set_user_setting, "gamma", original_gamma)
        apply_user_settings()
    end
    applied = false

    original_gamma = nil
    captured = false
end


return api
