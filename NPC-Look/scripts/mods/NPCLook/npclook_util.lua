local mod = get_mod("NPCLook")
local Items = require("scripts/utilities/items")

local util = {}
local ITEM_2D_PREFIX = "content/items/2d/"

-- Retry timing for streamed UI work.
util.RETRY_INTERVAL = 0.1
util.RETRY_LIMIT = 60

util.localize = function(key, ...)
    return mod:localize(key, ...)
end

util.safe_unit_alive = function(unit)
    if not unit then
        return false
    end

    local ok, alive = pcall(Unit.alive, unit)

    return ok and alive == true
end

util.opacity_default = 100

util.normalize_opacity = function(value)
    value = tonumber(value)

    if not value or value ~= value or value == math.huge or value == -math.huge then
        return util.opacity_default
    end

    return math.floor(math.clamp(value, 0, util.opacity_default) + 0.5)
end

util.clone_opacity_map = function(source)
    local result = {}

    for slot_name, value in pairs(source or {}) do
        local opacity = util.normalize_opacity(value)

        if opacity ~= util.opacity_default then
            result[slot_name] = opacity
        end
    end

    return result
end

util.same_opacity_maps = function(left, right)
    left = left or {}
    right = right or {}

    for slot_name, value in pairs(left) do
        if util.normalize_opacity(value) ~= util.normalize_opacity(right[slot_name]) then
            return false
        end
    end

    for slot_name, value in pairs(right) do
        if left[slot_name] == nil and util.normalize_opacity(value) ~= util.opacity_default then
            return false
        end
    end

    return true
end

util.apply_opacity_to_unit = function(unit, value)
    if not util.safe_unit_alive(unit) then
        return false
    end

    local opacity = util.normalize_opacity(value) / util.opacity_default
    local translucent = opacity < 0.999

    if type(Unit.set_shader_pass_flag_for_meshes_in_unit_and_childs) == "function" then
        pcall(
            Unit.set_shader_pass_flag_for_meshes_in_unit_and_childs,
            unit,
            "one_bit_alpha",
            translucent
        )
    end

    pcall(Unit.set_shader_pass_flag_for_meshes, unit, "one_bit_alpha", translucent, true)
    pcall(Unit.set_scalar_for_materials, unit, "inv_jitter_alpha", 1 - opacity, true)
    pcall(Unit.set_scalar_for_materials, unit, "alpha_multiplier", opacity, true)

    if opacity <= 0 then
        pcall(Unit.set_unit_visibility, unit, false, true)
    end

    return true
end

util.apply_opacity_to_units = function(units, value)
    local applied = false

    for i = 1, #(units or {}) do
        applied = util.apply_opacity_to_unit(units[i], value) or applied
    end

    return applied
end

util.safe_lod_group = function(unit, name)
    if not util.safe_unit_alive(unit) then
        return nil
    end

    local ok, has_group = pcall(Unit.has_lod_group, unit, name)

    if not ok or not has_group then
        return nil
    end

    local group_ok, group = pcall(Unit.lod_group, unit, name)

    return group_ok and group or nil
end

util.item_base_unit = function(item, breed_name)
    if type(item) ~= "table" or item.only_show_in_1p == true then
        return nil
    end

    local ok, base_unit = pcall(Items.base_unit, item, breed_name, false)

    if not ok or type(base_unit) ~= "string" or base_unit == "" then
        return nil
    end

    return base_unit
end

util.item_has_visual_base = function(item, breed_name)
    return util.item_base_unit(item, breed_name) ~= nil
end

util.item_is_2d = function(item, item_name)
    local name = item_name

    if type(name) ~= "string" and type(item) == "table" then
        name = item.name

        if type(name) ~= "string" and type(item.__master_item) == "table" then
            name = item.__master_item.name
        end
    end

    return type(name) == "string"
        and string.sub(string.lower(name), 1, #ITEM_2D_PREFIX) == ITEM_2D_PREFIX
end

util.traceback = function(err)
    local message = tostring(err or "unknown error")

    if debug and type(debug.traceback) == "function" then
        -- Keep error reporting from replacing the original failure.
        local ok, trace = pcall(debug.traceback, message, 2)

        if ok and trace then
            return trace
        end
    end

    return message
end

util.report_once = function(state, key, message, report)
    if message == nil then
        state[key] = nil
        return false
    end

    message = tostring(message)

    if state[key] == message then
        return false
    end

    state[key] = message
    if report then
        report(message)
    end

    return true
end

util.new_retry = function(interval, maximum_interval, backoff)
    interval = math.max(tonumber(interval) or util.RETRY_INTERVAL, 0.001)

    return {
        elapsed = 0,
        attempts = 0,
        interval = interval,
        initial_interval = interval,
        maximum_interval = math.max(tonumber(maximum_interval) or interval, interval),
        backoff = math.max(tonumber(backoff) or 1, 1),
    }
end

util.reset_retry = function(retry)
    retry.elapsed = 0
    retry.attempts = 0
    retry.interval = retry.initial_interval or util.RETRY_INTERVAL
end

util.retry_due = function(retry, dt)
    retry.elapsed = retry.elapsed + math.max(tonumber(dt) or 0, 0)

    local interval = retry.interval or util.RETRY_INTERVAL

    if retry.elapsed < interval then
        return false
    end

    retry.elapsed = retry.elapsed - interval

    return true
end

util.record_attempt = function(retry)
    retry.attempts = retry.attempts + 1

    local interval = retry.interval or util.RETRY_INTERVAL
    local maximum = retry.maximum_interval or interval
    retry.interval = math.min(interval * (retry.backoff or 1), maximum)

    return retry.attempts >= util.RETRY_LIMIT
end

util.defer_retry = function(retry)
    retry.elapsed = 0

    local interval = retry.interval or util.RETRY_INTERVAL
    local maximum = retry.maximum_interval or interval
    retry.interval = math.min(interval * (retry.backoff or 1), maximum)
end

return util
