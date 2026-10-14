local mod = get_mod("AuspexChess")
local minigame_settings = require("scripts/settings/minigame/minigame_settings")
local minigame_util = mod.minigame_util

local math_abs = math.abs
local math_atan2 = math.atan2
local math_cos = math.cos
local math_huge = math.huge
local math_max = math.max
local math_pi = math.pi
local math_sin = math.sin
local math_sqrt = math.sqrt

local FINAL_STAGE = minigame_settings.drill_stage_amount or 3
local MOVE_PULSE_DURATION = 0.08
local MOVE_TIMEOUT = 0.8
local MOVE_COOLDOWN = (minigame_settings.drill_move_delay or 0.25) + 0.02
local PRESS_DURATION = 0.08
local RELEASE_DURATION = 0.12
local SUBMIT_TIMEOUT = 1.2
local CURSOR_TOLERANCE = 1 / 128
local ANGLE_SAMPLES = 72
local TWO_PI = math_pi * 2
local SAMPLE_STEP = TWO_PI / ANGLE_SAMPLES
local STARTUP_STABILITY = 0.12

local Solver = {}
Solver.__index = Solver

local function angle_delta(a, b)
    local delta = math_abs(a - b)
    return delta > math_pi and TWO_PI - delta or delta
end

local function selected_for_angle(targets, selected_index, cursor_x, cursor_y, aim_angle)
    local best_index = 0
    local best_points = math_huge
    local power = minigame_settings.drill_move_distance_power or 0.75

    for i = 1, #targets do
        if i ~= selected_index then
            local target = targets[i]
            local dx = target.x - cursor_x
            local dy = target.y - cursor_y
            local target_angle = math_atan2(dy, dx)
            local angle = angle_delta(target_angle, aim_angle)

            if angle < math_pi / 3 then
                local distance = math_sqrt(dx * dx + dy * dy)
                local points = distance + angle * power
                if points < best_points then
                    best_points = points
                    best_index = i
                end
            end
        end
    end

    return best_index
end

function Solver.new(controller, session)
    local now = controller:time() or 0
    return setmetatable({
        _controller = controller,
        _session = session,
        _minigame = session.minigame,
        _pending_move = false,
        _pending_stage = 0,
        _expected_index = 0,
        _expected_x = 0,
        _expected_y = 0,
        _pending_until = 0,
        _move_until = 0,
        _next_move_at = now + STARTUP_STABILITY,
        _move_x = 0,
        _move_y = 0,
        _press_until = 0,
        _release_until = 0,
        _submitted_stage = 0,
        _submitted_until = 0,
        _route_stage = 0,
        _route_from_index = -1,
        _route_target_index = 0,
        _route_angle = 0,
        _queue = {},
        _visited = {},
        _parent = {},
        _parent_angle = {},
    }, Solver)
end

function Solver:stage()
    return minigame_util.current_stage(self._minigame)
end

function Solver:authoritative_complete()
    return minigame_util.is_completed(self._minigame, FINAL_STAGE)
end

function Solver:_selected_index()
    local minigame = self._minigame
    if not minigame then
        return 0
    end

    local selected = minigame.selected_index and minigame:selected_index() or minigame._selected_index
    return selected or 0
end

function Solver:_target_info()
    local minigame = self._minigame
    local stage = self:stage()
    local correct = minigame and minigame.correct_targets and minigame:correct_targets()
    local correct_index = correct and correct[stage] or nil
    local targets = minigame and minigame.targets and minigame:targets()
    local stage_targets = targets and targets[stage] or nil
    local target = correct_index and stage_targets and stage_targets[correct_index] or nil
    return correct_index, target, stage_targets
end

function Solver:_correct_selected()
    local correct_index = self:_target_info()
    return correct_index ~= nil and self:_selected_index() == correct_index
end

function Solver:_search_complete(now)
    local minigame = self._minigame
    if not minigame or not now or not minigame.is_searching or not minigame:is_searching() then
        return false
    end

    return minigame.search_percentage ~= nil and minigame:search_percentage(now) >= 1
end

function Solver:_invalidate_route()
    self._route_stage = 0
    self._route_from_index = -1
    self._route_target_index = 0
    self._route_angle = 0
end

function Solver:_find_route_angle()
    local correct_index, _, targets = self:_target_info()
    local cursor = self._minigame.cursor_position and self._minigame:cursor_position() or nil
    if not correct_index or not targets or not cursor then
        return nil
    end

    local selected_index = self:_selected_index()
    local stage = self:stage()
    if self._route_stage == stage and self._route_from_index == selected_index then
        return self._route_angle, self._route_target_index
    end

    local count = #targets
    local queue = self._queue
    local visited = self._visited
    local parent = self._parent
    local parent_angle = self._parent_angle

    for i = 1, count do
        queue[i] = nil
        visited[i] = false
        parent[i] = nil
        parent_angle[i] = nil
    end

    local queue_head = 1
    local queue_tail = 1
    queue[1] = selected_index

    if selected_index > 0 then
        visited[selected_index] = true
    end

    while queue_head <= queue_tail do
        local state = queue[queue_head]
        queue_head = queue_head + 1

        local state_x
        local state_y
        if state == selected_index then
            state_x = cursor.x
            state_y = cursor.y
        else
            local state_target = targets[state]
            state_x = state_target.x
            state_y = state_target.y
        end

        local excluded = state > 0 and state or 0

        for candidate = 1, count do
            if candidate ~= excluded then
                local candidate_target = targets[candidate]
                local aim = math_atan2(candidate_target.y - state_y, candidate_target.x - state_x)
                local destination = selected_for_angle(targets, excluded, state_x, state_y, aim)

                if destination > 0 and not visited[destination] then
                    visited[destination] = true
                    parent[destination] = state
                    parent_angle[destination] = aim
                    queue_tail = queue_tail + 1
                    queue[queue_tail] = destination
                end
            end
        end

        for sample = 0, ANGLE_SAMPLES - 1 do
            local aim = sample * SAMPLE_STEP
            local destination = selected_for_angle(targets, excluded, state_x, state_y, aim)

            if destination > 0 and not visited[destination] then
                visited[destination] = true
                parent[destination] = state
                parent_angle[destination] = aim
                queue_tail = queue_tail + 1
                queue[queue_tail] = destination
            end
        end

        if visited[correct_index] then
            break
        end
    end

    if not visited[correct_index] then
        return nil
    end

    local first_hop = correct_index
    local previous = parent[first_hop]
    while previous ~= nil and previous ~= selected_index do
        first_hop = previous
        previous = parent[first_hop]
    end

    local angle = parent_angle[first_hop]
    if angle == nil then
        return nil
    end

    self._route_stage = stage
    self._route_from_index = selected_index
    self._route_target_index = first_hop
    self._route_angle = angle
    return angle, first_hop
end

function Solver:_update_acks(now)
    local stage = self:stage()

    if self._submitted_stage ~= 0 then
        if stage ~= self._submitted_stage then
            self._submitted_stage = 0
            self._submitted_until = 0
            self._next_move_at = now + MOVE_COOLDOWN
            self:_invalidate_route()
        elseif now >= self._submitted_until then
            self._submitted_stage = 0
            self._submitted_until = 0
        end
    end

    if self._pending_move then
        if stage ~= self._pending_stage then
            self._pending_move = false
            self:_invalidate_route()
        else
            local selected = self:_selected_index()
            local cursor = self._minigame.cursor_position and self._minigame:cursor_position() or nil

            if selected == self._expected_index
                and cursor
                and math_abs(cursor.x - self._expected_x) <= CURSOR_TOLERANCE
                and math_abs(cursor.y - self._expected_y) <= CURSOR_TOLERANCE then
                self._pending_move = false
                self:_invalidate_route()
            elseif selected ~= 0 and selected ~= self._expected_index then
                self._pending_move = false
                self:_invalidate_route()
            elseif now >= self._pending_until then
                self._pending_move = false
                self:_invalidate_route()
            end
        end
    end
end

function Solver:ready_to_commit()
    local now = self._controller:time()
    return not self:authoritative_complete()
        and self:stage() == FINAL_STAGE
        and self:_correct_selected()
        and self:_search_complete(now)
        and self._submitted_stage == 0
        and not self._pending_move
end

function Solver:estimated_commit_delay(now)
    if self:ready_to_commit() then
        return 0
    end

    if self:_correct_selected() and self._minigame.search_percentage then
        local percentage = self._minigame:search_percentage(now or self._controller:time() or 0)
        return math_max(0, (1 - percentage) * (minigame_settings.drill_search_time or 0.5))
    end

    return 0.35
end

function Solver:_can_submit(now)
    local stage = self:stage()
    if stage < 1 or stage > FINAL_STAGE or not self:_correct_selected() or not self:_search_complete(now) then
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
    elseif now < self._release_until or self._submitted_stage ~= 0 then
        return false
    end

    if not minigame_util.is_gameplay(self._minigame) then
        return false
    end

    if self:_can_submit(now) then
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

    if not minigame_util.is_gameplay(self._minigame)
        or self._submitted_stage ~= 0
        or self:_correct_selected()
        or now < self._next_move_at then
        return 0, 0
    end

    if self._pending_move then
        if now < self._move_until then
            return self._move_x, self._move_y
        end
        return 0, 0
    end

    local angle, expected_index = self:_find_route_angle()
    local _, _, targets = self:_target_info()
    if angle == nil or not expected_index or not targets then
        return 0, 0
    end

    local expected_target = targets[expected_index]
    if not expected_target then
        return 0, 0
    end

    self._move_x = math_cos(angle)
    self._move_y = -math_sin(angle)
    self._move_until = now + MOVE_PULSE_DURATION
    self._next_move_at = now + MOVE_COOLDOWN
    self._pending_move = true
    self._pending_stage = self:stage()
    self._expected_index = expected_index
    self._expected_x = expected_target.x
    self._expected_y = expected_target.y
    self._pending_until = now + MOVE_TIMEOUT

    return self._move_x, self._move_y
end

function Solver:update(now)
    self:_update_acks(now)
end

return Solver
