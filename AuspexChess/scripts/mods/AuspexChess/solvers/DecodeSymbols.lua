local mod = get_mod("AuspexChess")
local minigame_settings = require("scripts/settings/minigame/minigame_settings")
local minigame_util = mod.minigame_util

local math_abs = math.abs
local math_max = math.max
local math_min = math.min

local FINAL_STAGE = minigame_settings.decode_symbols_stage_amount or 4
local TOTAL_SYMBOLS = minigame_settings.decode_symbols_total_items or 28
local PRESS_DURATION = 0.08
local RELEASE_DURATION = 0.12
local CENTER_GRACE = 0.04
local SUBMIT_TIMEOUT = 1.2
local SYNC_STABILITY_DURATION = 0.12
local DEFAULT_STAGE_ACK = PRESS_DURATION + RELEASE_DURATION
local ACK_ALPHA = 0.30

local Solver = {}
Solver.__index = Solver

function Solver.new(controller, session)
    return setmetatable({
        _controller = controller,
        _session = session,
        _minigame = session.minigame,
        _press_until = 0,
        _release_until = 0,
        _submitted_stage = 0,
        _submitted_until = 0,
        _submit_time = 0,
        _stage_ack = DEFAULT_STAGE_ACK,
        _synced = false,
        _synced_start_time = false,
        _candidate_start_time = false,
        _candidate_target = 0,
        _candidate_stage = 0,
        _candidate_since = 0,
        _previous_start_time = session.previous_decode_start_time,
    }, Solver)
end

function Solver:stage()
    return minigame_util.current_stage(self._minigame)
end

function Solver:authoritative_complete()
    return minigame_util.is_completed(self._minigame, FINAL_STAGE)
end

function Solver:_reset_sync_candidate()
    self._candidate_start_time = false
    self._candidate_target = 0
    self._candidate_stage = 0
    self._candidate_since = 0
end

function Solver:_sync_ready(now)
    if self._synced then
        local current_start = self._minigame.start_time
            and self._minigame:start_time()
            or self._minigame._decode_start_time

        if current_start == self._synced_start_time then
            return true
        end

        self._synced = false
        self._synced_start_time = false
        self:_reset_sync_candidate()
    end

    local minigame = self._minigame
    local stage = self:stage()
    local symbols = minigame and (minigame.symbols and minigame:symbols() or minigame._symbols)
    local start_time = minigame and (minigame.start_time and minigame:start_time() or minigame._decode_start_time)
    local target = minigame and stage > 0 and (minigame.current_decode_target and minigame:current_decode_target() or minigame._decode_targets and minigame._decode_targets[stage]) or nil

    if not now
        or stage < 1
        or stage > FINAL_STAGE
        or not start_time
        or not target
        or type(symbols) ~= "table"
        or #symbols < TOTAL_SYMBOLS then
        self:_reset_sync_candidate()
        return false
    end

    if self._previous_start_time and start_time == self._previous_start_time then
        self:_reset_sync_candidate()
        return false
    end

    if self._candidate_start_time ~= start_time
        or self._candidate_target ~= target
        or self._candidate_stage ~= stage then
        self._candidate_start_time = start_time
        self._candidate_target = target
        self._candidate_stage = stage
        self._candidate_since = now
        return false
    end

    if now - self._candidate_since < SYNC_STABILITY_DURATION then
        return false
    end

    self._synced = true
    self._synced_start_time = start_time
    return true
end

function Solver:_clear_submit_if_acked(now)
    local submitted_stage = self._submitted_stage
    if submitted_stage == 0 then
        return
    end

    local stage = self:stage()
    if stage ~= submitted_stage then
        local observed = self._submit_time > 0 and now - self._submit_time or 0
        if observed > 0 and observed < SUBMIT_TIMEOUT then
            local current = self._stage_ack
            self._stage_ack = observed > current
                and observed
                or current + (observed - current) * ACK_ALPHA
        end

        self._submitted_stage = 0
        self._submitted_until = 0
        self._submit_time = 0
    elseif now >= self._submitted_until then
        self._submitted_stage = 0
        self._submitted_until = 0
        self._submit_time = 0
    end
end

function Solver:_phase_values(at, stage)
    local minigame = self._minigame
    local targets = minigame and minigame._decode_targets
    local start_time = minigame and (minigame.start_time and minigame:start_time() or minigame._decode_start_time)
    local items = minigame_settings.decode_symbols_items_per_stage or 7
    local sweep = minigame and (minigame.sweep_duration and minigame:sweep_duration() or minigame._decode_symbols_sweep_duration)
    local target = minigame and stage == self:stage() and minigame.current_decode_target and minigame:current_decode_target()
        or targets and targets[stage]

    if not at or not start_time or not target or not items or items <= 1 or not sweep or sweep <= 0 then
        return nil
    end

    local period = sweep * 2
    local margin = sweep / (items - 1)
    local center = (target - 1) * margin
    local mirror = period - center
    local phase = (at - start_time) % period

    return period, center, mirror, phase
end

function Solver:_trigger_delta(now, stage)
    local period, center, mirror, phase = self:_phase_values(now, stage)
    if not period then
        return nil
    end

    local forward = center - phase
    local reverse = mirror - phase

    if forward < -CENTER_GRACE then
        forward = forward + period
    end
    if reverse < -CENTER_GRACE then
        reverse = reverse + period
    end

    return math_abs(forward) < math_abs(reverse) and forward or reverse
end

function Solver:_next_trigger_delay(at, stage)
    local period, center, mirror, phase = self:_phase_values(at, stage)
    if not period then
        return 0.5
    end

    local forward = center - phase
    local reverse = mirror - phase

    if forward < 0 then
        forward = forward + period
    end
    if reverse < 0 then
        reverse = reverse + period
    end

    return math_min(forward, reverse)
end

function Solver:ready_to_commit()
    return self._synced
        and not self:authoritative_complete()
        and self:stage() == FINAL_STAGE
        and self._submitted_stage == 0
end

function Solver:estimated_commit_delay(now)
    if self:authoritative_complete() then
        return 0
    end

    if not self:_sync_ready(now) then
        return 0.75
    end

    local stage = self:stage()
    if stage < 1 or stage > FINAL_STAGE then
        return 0
    end

    local ready_at = now
    local ack_delay = math_max(self._stage_ack, DEFAULT_STAGE_ACK)

    for current_stage = stage, FINAL_STAGE do
        ready_at = ready_at + self:_next_trigger_delay(ready_at, current_stage)

        if current_stage < FINAL_STAGE then
            ready_at = ready_at + ack_delay
        end
    end

    return math_max(ready_at - now, 0)
end

function Solver:_can_submit(stage)
    if not self._synced or stage < 1 or stage > FINAL_STAGE then
        return false
    end

    if stage < FINAL_STAGE then
        return true
    end

    return self._session.commit_requested == true
end

function Solver:_start_press(now, stage)
    self._press_until = now + PRESS_DURATION
    self._release_until = self._press_until + RELEASE_DURATION
    self._submitted_stage = stage
    self._submitted_until = now + SUBMIT_TIMEOUT
    self._submit_time = now

    if stage == FINAL_STAGE and self._session.commit_requested then
        self._controller:mark_commit_sent()
    end
end

function Solver:primary_value(now)
    if not now or self:authoritative_complete() then
        return false
    end

    self:_clear_submit_if_acked(now)

    if now < self._press_until then
        return true
    elseif now < self._release_until or self._submitted_stage ~= 0 then
        return false
    end

    if not minigame_util.is_gameplay(self._minigame) or not self:_sync_ready(now) then
        return false
    end

    local stage = self:stage()
    if not self:_can_submit(stage) then
        return false
    end

    local delta = self:_trigger_delta(now, stage)
    if delta and math_abs(delta) <= CENTER_GRACE then
        self:_start_press(now, stage)
        return true
    end

    return false
end

function Solver:move_value()
    return 0, 0
end

function Solver:update(now)
    self:_clear_submit_if_acked(now)
    self:_sync_ready(now)
end

return Solver
