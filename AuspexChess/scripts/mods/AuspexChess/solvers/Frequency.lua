local mod = get_mod("AuspexChess")
local minigame_settings = require("scripts/settings/minigame/minigame_settings")
local minigame_util = mod.minigame_util

local math_max = math.max

local FINAL_STAGE = minigame_settings.frequency_search_stage_amount or 3
local PRESS_DURATION = 0.08
local RELEASE_DURATION = 0.12
local SUBMIT_TIMEOUT = 1.2
local STARTUP_STABILITY = 0.35
local TARGET_STABILITY = 0.12

local Solver = {}
Solver.__index = Solver

function Solver.new(controller, session)
    local now = controller:time() or 0
    return setmetatable({
        _controller = controller,
        _session = session,
        _minigame = session.minigame,
        _press_until = 0,
        _release_until = 0,
        _submitted_stage = 0,
        _submitted_until = 0,
        _last_stage = 0,
        _last_target_x = false,
        _last_target_y = false,
        _ready_at = now + STARTUP_STABILITY,
    }, Solver)
end

function Solver:stage()
    return minigame_util.current_stage(self._minigame)
end

function Solver:authoritative_complete()
    return minigame_util.is_completed(self._minigame, FINAL_STAGE)
end

function Solver:_target()
    local minigame = self._minigame
    return minigame and minigame.target_frequency and minigame:target_frequency() or nil
end

function Solver:_refresh_sync(now)
    local stage = self:stage()
    local target = self:_target()
    if not target then
        return false
    end

    if stage ~= self._last_stage
        or target.x ~= self._last_target_x
        or target.y ~= self._last_target_y then
        self._last_stage = stage
        self._last_target_x = target.x
        self._last_target_y = target.y
        self._ready_at = math_max(self._ready_at, now + TARGET_STABILITY)
    end

    return stage >= 1 and stage <= FINAL_STAGE and now >= self._ready_at
end

function Solver:_update_ack(now)
    if self._submitted_stage == 0 then
        return
    end

    local stage = self:stage()
    if stage ~= self._submitted_stage or now >= self._submitted_until then
        self._submitted_stage = 0
        self._submitted_until = 0
    end
end

function Solver:_snap_to_target()
    local minigame = self._minigame
    local target = self:_target()
    local frequency = minigame and minigame._frequency
    if not target or not frequency then
        return false
    end

    frequency.x = target.x
    frequency.y = target.y
    return true
end

function Solver:ready_to_commit()
    local now = self._controller:time()
    return not self:authoritative_complete()
        and self:stage() == FINAL_STAGE
        and self._submitted_stage == 0
        and now ~= nil
        and self:_refresh_sync(now)
end

function Solver:estimated_commit_delay(now)
    return self:ready_to_commit() and 0 or 0.20
end

function Solver:_can_submit(now)
    local stage = self:stage()
    if stage < 1 or stage > FINAL_STAGE or not self:_refresh_sync(now) then
        return false
    end

    return stage < FINAL_STAGE or self._session.commit_requested == true
end

function Solver:_mark_submission(now)
    local stage = self:stage()
    self._submitted_stage = stage
    self._submitted_until = now + SUBMIT_TIMEOUT

    if stage == FINAL_STAGE and self._session.commit_requested then
        self._controller:mark_commit_sent()
    end
end

function Solver:_start_press(now)
    if not self:_snap_to_target() then
        return false
    end

    self._press_until = now + PRESS_DURATION
    self._release_until = self._press_until + RELEASE_DURATION
    self:_mark_submission(now)
    return true
end

function Solver:primary_value(now)
    if not now or self:authoritative_complete() then
        return false
    end

    self:_update_ack(now)

    if now < self._press_until then
        return true
    elseif now < self._release_until or self._submitted_stage ~= 0 then
        return false
    end

    if not minigame_util.is_gameplay(self._minigame) or not self:_can_submit(now) then
        return false
    end

    return self:_start_press(now)
end

function Solver:move_value()
    return 0, 0
end

function Solver:update(now)
    self:_update_ack(now)
    self:_refresh_sync(now)

    if self._minigame._is_server
        and self._submitted_stage == 0
        and minigame_util.is_gameplay(self._minigame)
        and self:_can_submit(now)
        and self:_snap_to_target() then
        local target = self:_target()
        self:_mark_submission(now)
        self._minigame:test_frequency(target.x, target.y)
    end
end

return Solver
