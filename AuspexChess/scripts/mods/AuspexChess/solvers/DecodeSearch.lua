local mod = get_mod("AuspexChess")
local minigame_settings = require("scripts/settings/minigame/minigame_settings")
local minigame_util = mod.minigame_util
local math_abs = math.abs
local math_max = math.max
local math_huge = math.huge

local FINAL_STAGE = minigame_settings.decode_search_stage_amount or 3
local BOARD_W = minigame_settings.decode_search_board_width or 6
local BOARD_H = minigame_settings.decode_search_board_height or 4
local CURSOR_W = minigame_settings.decode_search_cursor_width or 2
local CURSOR_H = minigame_settings.decode_search_cursor_height or 2
local MOVE_PULSE_DURATION = 0.08
local MOVE_TIMEOUT = 0.8
local MOVE_READY_DELAY = (minigame_settings.decode_move_delay or 0.25) + 0.02
local PRESS_DURATION = 0.08
local RELEASE_DURATION = 0.12
local SUBMIT_TIMEOUT = 1.2
local STARTUP_STABILITY = 0.12

local Solver = {}
Solver.__index = Solver

function Solver.new(controller, session)
    local now = controller:time() or 0
    return setmetatable({
        _controller = controller,
        _session = session,
        _minigame = session.minigame,
        _pending_move = false,
        _pending_stage = 0,
        _expected_x = 0,
        _expected_y = 0,
        _pending_until = 0,
        _move_until = 0,
        _move_x = 0,
        _move_y = 0,
        _press_until = 0,
        _release_until = 0,
        _submitted_stage = 0,
        _submitted_until = 0,
        _target_cache_stage = 0,
        _target_x = 0,
        _target_y = 0,
        _ready_at = now + STARTUP_STABILITY,
    }, Solver)
end

function Solver:stage()
    return minigame_util.current_stage(self._minigame)
end

function Solver:authoritative_complete()
    return minigame_util.is_completed(self._minigame, FINAL_STAGE)
end

function Solver:_cursor()
    local minigame = self._minigame
    return minigame and minigame.cursor_position and minigame:cursor_position() or nil
end

function Solver:_invalidate_target()
    self._target_cache_stage = 0
    self._target_x = 0
    self._target_y = 0
end

function Solver:_target_coords()
    local minigame = self._minigame
    local stage = self:stage()
    if not minigame or stage < 1 or stage > FINAL_STAGE then
        return nil
    end

    if self._target_cache_stage == stage then
        return self._target_x, self._target_y
    end

    local target = minigame.current_decode_target and minigame:current_decode_target()
        or minigame._decode_targets and minigame._decode_targets[stage]
    if type(target) ~= "table" or not minigame.get_symbols_for_target then
        return nil
    end

    local cursor = self:_cursor()
    local max_x = BOARD_W - CURSOR_W + 1
    local max_y = BOARD_H - CURSOR_H + 1
    local best_x = 0
    local best_y = 0
    local best_steps = math_huge
    local best_manhattan = math_huge

    for y = 1, max_y do
        for x = 1, max_x do
            local symbols = minigame:get_symbols_for_target(x, y)
            if minigame_util.same4(symbols, target) then
                local dx = cursor and math_abs(x - cursor.x) or 0
                local dy = cursor and math_abs(y - cursor.y) or 0
                local steps = math_max(dx, dy)
                local manhattan = dx + dy

                if steps < best_steps or steps == best_steps and manhattan < best_manhattan then
                    best_x = x
                    best_y = y
                    best_steps = steps
                    best_manhattan = manhattan
                end
            end
        end
    end

    if best_x == 0 then
        return nil
    end

    self._target_cache_stage = stage
    self._target_x = best_x
    self._target_y = best_y
    return best_x, best_y
end

function Solver:_on_target()
    local cursor = self:_cursor()
    local target_x, target_y = self:_target_coords()
    return cursor ~= nil
        and target_x ~= nil
        and cursor.x == target_x
        and cursor.y == target_y
end

function Solver:_update_acks(now)
    local stage = self:stage()

    if self._submitted_stage ~= 0 then
        if stage ~= self._submitted_stage then
            self._submitted_stage = 0
            self._submitted_until = 0
            self._ready_at = now
            self:_invalidate_target()
        elseif now >= self._submitted_until then
            self._submitted_stage = 0
            self._submitted_until = 0
        end
    end

    if self._pending_move then
        if stage ~= self._pending_stage then
            self._pending_move = false
        else
            local cursor = self:_cursor()
            if cursor and cursor.x == self._expected_x and cursor.y == self._expected_y then
                self._pending_move = false
            elseif now >= self._pending_until then
                self._pending_move = false
            end
        end
    end
end

function Solver:ready_to_commit()
    return not self:authoritative_complete()
        and self:stage() == FINAL_STAGE
        and self:_on_target()
        and self._submitted_stage == 0
        and not self._pending_move
end

function Solver:estimated_commit_delay()
    if self:ready_to_commit() then
        return 0
    end

    local cursor = self:_cursor()
    local target_x, target_y = self:_target_coords()
    if cursor and target_x then
        local steps = math_max(math_abs(target_x - cursor.x), math_abs(target_y - cursor.y))
        return steps * MOVE_READY_DELAY
    end

    return 0.25
end

function Solver:_can_submit()
    local stage = self:stage()
    if stage < 1 or stage > FINAL_STAGE or not self:_on_target() then
        return false
    end

    return stage < FINAL_STAGE or self._session.commit_requested == true
end

function Solver:_start_press(now)
    local stage = self:stage()
    self._press_until = now + PRESS_DURATION
    self._release_until = self._press_until + RELEASE_DURATION
    self._submitted_stage = stage
    self._submitted_until = now + SUBMIT_TIMEOUT

    if stage == FINAL_STAGE and self._session.commit_requested then
        self._controller:mark_commit_sent()
    end
end

function Solver:primary_value(now)
    if not now or self:authoritative_complete() then
        return false
    end

    self:_update_acks(now)

    if now < self._press_until then
        return true
    elseif now < self._release_until
        or self._submitted_stage ~= 0
        or self._pending_move then
        return false
    end

    if now < self._ready_at or not minigame_util.is_gameplay(self._minigame) then
        return false
    end

    if self:_can_submit() then
        self:_start_press(now)
        return true
    end

    return false
end

function Solver:move_value(now)
    if not now or self:authoritative_complete() then
        return 0, 0
    end

    self:_update_acks(now)

    if now < self._ready_at
        or not minigame_util.is_gameplay(self._minigame)
        or self._submitted_stage ~= 0 then
        return 0, 0
    end

    if self._pending_move then
        if now < self._move_until then
            return self._move_x, self._move_y
        end
        return 0, 0
    end

    local minigame = self._minigame
    if minigame._moved_time and minigame.time_since_move and minigame:time_since_move() < MOVE_READY_DELAY then
        return 0, 0
    end

    local cursor = self:_cursor()
    local target_x, target_y = self:_target_coords()
    if not cursor or not target_x then
        return 0, 0
    end

    local dx = target_x - cursor.x
    local dy = target_y - cursor.y
    if dx == 0 and dy == 0 then
        return 0, 0
    end

    local step_x = minigame_util.sign(dx)
    local step_y = minigame_util.sign(dy)

    self._move_x = step_x
    self._move_y = -step_y
    self._move_until = now + MOVE_PULSE_DURATION
    self._pending_move = true
    self._pending_stage = self:stage()
    self._expected_x = cursor.x + step_x
    self._expected_y = cursor.y + step_y
    self._pending_until = now + MOVE_TIMEOUT

    return self._move_x, self._move_y
end

function Solver:update(now)
    self:_update_acks(now)
end

return Solver
