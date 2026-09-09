local mod = get_mod("AuspexChess")
local minigame_settings = require("scripts/settings/minigame/minigame_settings")
local minigame_util = mod.minigame_util
local math_abs = math.abs
local math_sqrt = math.sqrt

local MIN_SAMPLE_DT = 1 / 240
local MAX_SAMPLE_DT = 0.25
local STALE_SAMPLE_DT = 0.10
local VELOCITY_ALPHA = 0.55
local OMEGA = 1.6
local POSITION_EPSILON = 0.000001

local Solver = {}
Solver.__index = Solver

function Solver.new(_, session)
    return setmetatable({
        _minigame = session.minigame,
        _last_x = false,
        _last_y = false,
        _last_sample_t = 0,
        _vx = 0,
        _vy = 0,
        _move_x = 0,
        _move_y = 0,
    }, Solver)
end

function Solver:stage()
    return 1
end

function Solver:authoritative_complete()
    local minigame = self._minigame
    return minigame ~= nil and minigame.is_completed ~= nil and minigame:is_completed() == true
end

function Solver:ready_to_commit()
    local minigame = self._minigame
    return not self:authoritative_complete()
        and minigame ~= nil
        and minigame.position ~= nil
        and minigame:position() ~= nil
end

function Solver:estimated_commit_delay()
    return 0
end

function Solver:finalize_progress()
    local minigame = self._minigame
    if not minigame or not minigame.progression then
        return 0
    end

    return minigame_util.clamp(minigame:progression() or 0, 0, 1)
end

function Solver:primary_value()
    return false
end

local function outward_acceleration(x, y)
    local distance = math_sqrt(x * x + y * y)
    if distance >= 1 then
        return 0, 0
    end

    local power = (1 - distance) * (minigame_settings.balance_push_ratio or 1.08)
    if distance <= POSITION_EPSILON then
        return power, 0
    end

    return x / distance * power, y / distance * power
end

function Solver:_recompute_command(x, y)
    local gx, gy = outward_acceleration(x, y)
    local omega2 = OMEGA * OMEGA
    local desired_ax = -gx - omega2 * x - 2 * OMEGA * self._vx
    local desired_ay = -gy - omega2 * y - 2 * OMEGA * self._vy
    local move_ratio = minigame_settings.balance_move_ratio or 4.2

    self._move_x = minigame_util.clamp(desired_ax / move_ratio, -1, 1)
    self._move_y = minigame_util.clamp(-desired_ay / move_ratio, -1, 1)
end

function Solver:_sample(now)
    local minigame = self._minigame
    local position = minigame and minigame.position and minigame:position() or nil
    if not position or not now then
        return
    end

    local x = position.x
    local y = position.y

    if self._last_x == false then
        self._last_x = x
        self._last_y = y
        self._last_sample_t = now
    else
        local dt = now - self._last_sample_t
        local changed = math_abs(x - self._last_x) > POSITION_EPSILON
            or math_abs(y - self._last_y) > POSITION_EPSILON

        if changed then
            if dt >= MIN_SAMPLE_DT and dt <= MAX_SAMPLE_DT then
                local raw_vx = (x - self._last_x) / dt
                local raw_vy = (y - self._last_y) / dt
                self._vx = self._vx + (raw_vx - self._vx) * VELOCITY_ALPHA
                self._vy = self._vy + (raw_vy - self._vy) * VELOCITY_ALPHA
            else
                self._vx = 0
                self._vy = 0
            end

            self._last_x = x
            self._last_y = y
            self._last_sample_t = now
        elseif dt >= STALE_SAMPLE_DT then
            self._vx = 0
            self._vy = 0
            self._last_sample_t = now
        end
    end

    self:_recompute_command(x, y)
end

function Solver:move_value(now)
    if not now or self:authoritative_complete() then
        return 0, 0
    end

    self:_sample(now)
    return self._move_x, self._move_y
end

function Solver:update(now)
    self:_sample(now)
end

return Solver
