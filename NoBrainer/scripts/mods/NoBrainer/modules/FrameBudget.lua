local mod = get_mod("NoBrainer")
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")

local api = {}

local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local tonumber = tonumber

local remaining = 0
local configured_limit = 0
local effective_limit = 0
local draw_remaining = 0
local draw_limit = 0

local baseline_dt = nil
local smoothed_dt = nil
local load_scale = 1

local frame_deadline = nil
local time_check_counter = 0
local compute_used = 0
local draw_used = 0

local function now()
    if Application and Application.time_since_launch then
        return Application.time_since_launch()
    end
    return nil
end

local function time_ok(force)
    if not frame_deadline then return true end

    -- clock calls arent free either so only really check every few work takes
    time_check_counter = time_check_counter + 1
    if not force and time_check_counter < 10 then return true end
    time_check_counter = 0

    local t = now()
    if t and t >= frame_deadline then
        remaining = 0
        return false
    end
    return true
end

function api.begin_frame(dt)
    configured_limit = math_max(64, math_floor(settings.number("global_frame_budget")))

    local frame_dt = tonumber(dt) or (1 / 60)
    frame_dt = math_max(0.001, math_min(frame_dt, 0.25))
    local previous_busy = compute_used > 0 or draw_used > 0

    if not baseline_dt then
        baseline_dt = frame_dt
        smoothed_dt = frame_dt
    else

        -- only learn slower baseline frames when this mod wasnt busy, otherwise it learns its own slowdown
        if frame_dt < baseline_dt then
            baseline_dt = baseline_dt + (frame_dt - baseline_dt) * 0.12
        elseif not previous_busy then
            baseline_dt = baseline_dt + (frame_dt - baseline_dt) * 0.008
        end
        smoothed_dt = smoothed_dt * 0.86 + frame_dt * 0.14
    end

    local ratio = baseline_dt / math_max(smoothed_dt, 0.001)
    -- square makes overload backoff stronger than the later recovery
    local desired_scale = math_max(0.08, math_min(1, ratio * ratio))
    local response = desired_scale < load_scale and 0.50 or 0.07
    load_scale = load_scale + (desired_scale - load_scale) * response

    effective_limit = math_max(32, math_floor(configured_limit * load_scale))
    remaining = effective_limit

    if settings.boolean("global_draw_limit_enabled") then
        draw_limit = math_max(1, math_floor(settings.number("global_max_draw_lines")))
        draw_remaining = draw_limit
    else
        draw_limit = math.huge
        draw_remaining = math.huge
    end

    local start = now()
    if start then
        -- work units are only guesses across algorithms, this is the actual wall-clock escape hatch
        local max_slice = math_min(0.0060, math_max(0.00075, baseline_dt * 0.30))
        local allowance = math_max(0.00040, max_slice * load_scale * load_scale)
        frame_deadline = start + allowance
    else
        frame_deadline = nil
    end
    time_check_counter = 0
    compute_used = 0
    draw_used = 0
end

function api.take(cost)
    cost = math_max(1, math_floor(cost or 1))
    if remaining < cost or not time_ok(false) then return false end
    remaining = remaining - cost
    compute_used = compute_used + cost
    return true
end

function api.claim_items(cost_per_item, max_items)
    cost_per_item = math_max(1, math_floor(cost_per_item or 1))
    if not time_ok(true) then return 0 end

    local available = math_floor(remaining / cost_per_item)
    if max_items then
        available = math_min(available, math_max(0, math_floor(max_items)))
    end
    if available > 0 then
        local spent = available * cost_per_item
        remaining = remaining - spent
        compute_used = compute_used + spent
    end
    return available
end

function api.take_draw(lines)
    lines = math_max(1, math_floor(lines or 1))
    if draw_remaining < lines then return false end
    if draw_remaining ~= math.huge then draw_remaining = draw_remaining - lines end
    draw_used = draw_used + lines
    return true
end

function api.refund_draw(lines)
    lines = math_max(0, math_floor(lines or 0))
    if lines <= 0 then return end
    draw_used = math_max(0, draw_used - lines)
    if draw_remaining == math.huge then return end
    draw_remaining = math_min(draw_limit, draw_remaining + lines)
end


function api.time_available()
    return time_ok(false)
end

function api.draw_remaining()
    return draw_remaining
end

function api.limit()
    return effective_limit
end


function api.draw_limited()
    return draw_remaining ~= math.huge
end

function api.reset()
    remaining = 0
    configured_limit = 0
    effective_limit = 0
    draw_remaining = 0
    draw_limit = 0
    baseline_dt = nil
    smoothed_dt = nil
    load_scale = 1
    frame_deadline = nil
    time_check_counter = 0
    compute_used = 0
    draw_used = 0
end

return api
