local mod = get_mod("AuspexChess")
local minigame_settings = require("scripts/settings/minigame/minigame_settings")

-- helpers

local minigame_util = (function()
    local type = type

    local api = {}

    function api.current_stage(minigame)
        if not minigame then
            return 0
        end

        if minigame.current_stage then
            return minigame:current_stage() or 0
        end

        return minigame._current_stage or 0
    end

    function api.is_completed(minigame, stage_amount)
        if not minigame then
            return false
        end

        if minigame.is_completed and minigame:is_completed() then
            return true
        end

        return api.current_stage(minigame) > stage_amount
    end

    function api.is_gameplay(minigame)
        return minigame ~= nil
            and minigame.state ~= nil
            and minigame:state() == minigame_settings.game_states.gameplay
    end

    function api.clamp(value, low, high)
        if value < low then
            return low
        elseif value > high then
            return high
        end

        return value
    end

    function api.sign(value)
        if value > 0 then
            return 1
        elseif value < 0 then
            return -1
        end

        return 0
    end

    function api.same4(left, right)
        if type(left) ~= "table" or type(right) ~= "table" then
            return false
        end

        return left[1] == right[1]
            and left[2] == right[2]
            and left[3] == right[3]
            and left[4] == right[4]
    end

    return api
end)()

mod.minigame_util = minigame_util

-- backend

local backend = (function()
    local mod = get_mod("AuspexChess")
    local ROOT = "AuspexChess/scripts/mods/AuspexChess/"
    local solvers = {
        [minigame_settings.types.balance] = mod:io_dofile(ROOT .. "solvers/Balance"),
        [minigame_settings.types.decode_search] = mod:io_dofile(ROOT .. "solvers/DecodeSearch"),
        [minigame_settings.types.decode_symbols] = mod:io_dofile(ROOT .. "solvers/DecodeSymbols"),
        [minigame_settings.types.drill] = mod:io_dofile(ROOT .. "solvers/Drill"),
    }

    local Managers = Managers
    local Vector3 = rawget(_G, "Vector3")
    local math_max = math.max
    local math_min = math.min

    local TYPE_DECODE_SYMBOLS = minigame_settings.types.decode_symbols

    local MIN_FINALIZE_DURATION = 0.35
    local FINALIZE_ACK_MARGIN = 0.25
    local FINALIZE_PROGRESS_CAP = 0.97
    local COMPLETE_SNAPSHOT_HOLD = 0.75
    local STARTUP_RELEASE_DURATION = 0.08

    local CLASS_NAMES = {
        "MinigameDecodeSymbols",
        "MinigameDecodeSearch",
        "MinigameDrill",
        "MinigameBalance",
    }

    local CLASS_TYPES = {
        minigame_settings.types.decode_symbols,
        minigame_settings.types.decode_search,
        minigame_settings.types.drill,
        minigame_settings.types.balance,
    }

    local Backend = {}
    Backend.__index = Backend


    local function new_observed()
        return {
            active = false,
            minigame = false,
            minigame_type = false,
            player = false,
            previous_decode_start_time = false,
        }
    end

    local function new_session()
        return {
            active = false,
            claim_id = 0,
            minigame = false,
            minigame_type = false,
            player = false,
            solver = false,
            startup_release_until = 0,
            status = "idle",
            ready_to_commit = false,
            commit_requested = false,
            commit_sent = false,
            authoritative_complete = false,
            input_active = false,
            stopped_at = 0,
            finalize_started_at = 0,
            finalize_duration = 0,
            previous_decode_start_time = false,
        }
    end

    local function new_public_state()
        return {
            active = false,
            observed = false,
            claim_id = 0,
            minigame_type = false,
            status = "idle",
            stage = 0,
            ready_to_commit = false,
            commit_requested = false,
            commit_sent = false,
            authoritative_complete = false,
            finalize_progress = 0,
            finalize_eta = 0,
        }
    end

    function Backend.new()
        local self = setmetatable({
            _enabled = true,
            _hooks_installed = false,
            _observed = new_observed(),
            _session = new_session(),
            _public = new_public_state(),
            _next_claim_id = 0,
            _last_decode_start = setmetatable({}, { __mode = "k" }),
            _frontend_input = { primary = false, move_x = 0, move_y = 0, look_x = 0, look_y = 0 },
            _cancel_player = false,
            _held_orientation = false,
            _last_orientation = false,
        }, Backend)

        return self
    end

    function Backend:time()
        local time_manager = Managers.time
        if not time_manager or not time_manager.has_timer or not time_manager:has_timer("gameplay") then
            return nil
        end

        return time_manager:time("gameplay")
    end

    function Backend:set_enabled(enabled)
        self._enabled = enabled == true
    end

    function Backend:_is_local_player(player)
        local player_manager = Managers.player
        local local_player = player_manager and player_manager:local_player_safe(1)
        return local_player ~= nil and player == local_player
    end

    function Backend:_store_decode_start(minigame)
        if not minigame then
            return
        end

        local start_time = minigame.start_time and minigame:start_time() or minigame._decode_start_time
        if start_time then
            self._last_decode_start[minigame] = start_time
        end
    end


    function Backend:_observe_start(minigame_type, minigame, player)
        if not self._enabled or not self:_is_local_player(player) then
            return
        end

        if self._session.active then
            self:release()
        end

        local observed = self._observed
        observed.active = true
        observed.minigame = minigame
        observed.minigame_type = minigame_type
        observed.player = player
        observed.previous_decode_start_time = minigame_type == TYPE_DECODE_SYMBOLS
            and self._last_decode_start[minigame]
            or false

        self:_refresh_public(self:time())
    end

    function Backend:_observe_stop(minigame)
        local observed = self._observed
        local session = self._session

        if observed.minigame == minigame or session.minigame == minigame then
            self._cancel_player = false
        end

        local is_decode = observed.active
            and observed.minigame == minigame
            and observed.minigame_type == TYPE_DECODE_SYMBOLS
            or session.active
            and session.minigame == minigame
            and session.minigame_type == TYPE_DECODE_SYMBOLS

        if is_decode then
            self:_store_decode_start(minigame)
        end

        if observed.active and observed.minigame == minigame then
            observed.active = false
            observed.minigame = false
            observed.minigame_type = false
            observed.player = false
            observed.previous_decode_start_time = false
        end

        if session.active and session.minigame == minigame then
            local solver = session.solver
            local solver_complete = solver and solver.authoritative_complete and solver:authoritative_complete()

            if session.authoritative_complete or solver_complete then
                self:mark_authoritative_complete()
                session.stopped_at = self:time() or 0
            else
                self:release()
            end
        end

        self:_refresh_public(self:time())
    end

    function Backend:_observe_complete(minigame)
        local session = self._session
        if not session.active or session.minigame ~= minigame then
            return
        end

        self:mark_authoritative_complete()

        self:_refresh_public(self:time())
    end

    function Backend:_install_minigame_hooks()
        if self._hooks_installed then
            return
        end

        self._hooks_installed = true

        for i = 1, #CLASS_NAMES do
            local class_name = CLASS_NAMES[i]
            local minigame_type = CLASS_TYPES[i]

            mod:hook_safe(class_name, "start", function(minigame, player)
                self:_observe_start(minigame_type, minigame, player)
            end)

            mod:hook_safe(class_name, "stop", function(minigame)
                self:_observe_stop(minigame)
            end)

            mod:hook_safe(class_name, "complete", function(minigame)
                self:_observe_complete(minigame)
            end)
        end

        mod:hook("MinigameDecodeSymbols", "uses_joystick", function(func, minigame)
            local session = self._session
            if mod:get("display_mode") == "auspex"
                and session.active
                and session.input_active
                and session.minigame == minigame then
                return true
            end

            return func(minigame)
        end)
    end


    function Backend:claim(expected_type)
        if not self._enabled then
            return false, "backend_disabled"
        end

        local session = self._session
        if session.active then
            if expected_type and session.minigame_type ~= expected_type then
                return false, "wrong_claimed_minigame_type"
            end

            return true, session.claim_id
        end

        local observed = self._observed
        if not observed.active then
            return false, "no_local_stock_minigame"
        end

        if expected_type and observed.minigame_type ~= expected_type then
            return false, "wrong_observed_minigame_type"
        end

        local solver_class = solvers[observed.minigame_type]
        if not solver_class then
            return false, "unsupported_minigame"
        end

        local now = self:time() or 0
        self._next_claim_id = self._next_claim_id + 1

        session.active = true
        session.claim_id = self._next_claim_id
        session.minigame = observed.minigame
        session.minigame_type = observed.minigame_type
        session.player = observed.player
        session.startup_release_until = now + STARTUP_RELEASE_DURATION
        session.status = "preparing"
        session.ready_to_commit = false
        session.commit_requested = false
        session.commit_sent = false
        session.authoritative_complete = false
        session.input_active = true
        session.stopped_at = 0
        session.finalize_started_at = 0
        session.finalize_duration = 0
        session.previous_decode_start_time = observed.previous_decode_start_time
        session.solver = solver_class.new(self, session)

        self:_refresh_public(now)
        return true, session.claim_id
    end

    function Backend:release(claim_id)
        local session = self._session
        if not session.active then
            return false, "no_claimed_session"
        end
        if claim_id and claim_id ~= session.claim_id then
            return false, "claim_mismatch"
        end

        session.active = false
        session.claim_id = 0
        session.minigame = false
        session.minigame_type = false
        session.player = false
        session.solver = false
        session.startup_release_until = 0
        session.status = "idle"
        session.ready_to_commit = false
        session.commit_requested = false
        session.commit_sent = false
        session.authoritative_complete = false
        session.input_active = false
        session.stopped_at = 0
        session.finalize_started_at = 0
        session.finalize_duration = 0
        session.previous_decode_start_time = false

        local frontend_input = self._frontend_input
        frontend_input.primary = false
        frontend_input.move_x = 0
        frontend_input.move_y = 0
        frontend_input.look_x = 0
        frontend_input.look_y = 0
        self._cancel_player = false
        self._held_orientation = false
        self._last_orientation = false

        self:_refresh_public(self:time())
        return true
    end

    function Backend:reset()
        self:release()

        local observed = self._observed
        observed.active = false
        observed.minigame = false
        observed.minigame_type = false
        observed.player = false
        observed.previous_decode_start_time = false

        self:_refresh_public(self:time())
    end

    function Backend:request_commit(claim_id)
        local session = self._session
        if not session.active then
            return false, "no_claimed_session"
        end
        if claim_id and claim_id ~= session.claim_id then
            return false, "claim_mismatch"
        end

        if session.authoritative_complete or session.commit_requested then
            return true
        end

        local now = self:time() or 0
        session.commit_requested = true
        session.ready_to_commit = false
        session.finalize_started_at = now
        session.status = "finalizing"

        local solver = session.solver
        local estimated_delay = solver and solver.estimated_commit_delay
            and solver:estimated_commit_delay(now)
            or 0

        session.finalize_duration = math_max(
            MIN_FINALIZE_DURATION,
            (estimated_delay or 0) + FINALIZE_ACK_MARGIN
        )

        self:_refresh_public(now)
        return true
    end

    function Backend:mark_commit_sent()
        local session = self._session
        if not session.active or session.commit_sent then
            return
        end

        session.commit_sent = true
        session.status = "committing"
    end

    function Backend:mark_authoritative_complete()
        local session = self._session
        if not session.active then
            return
        end

        session.authoritative_complete = true
        session.ready_to_commit = false
        session.input_active = false
        session.status = "complete"
    end

    function Backend:_finalize_progress(now)
        local session = self._session
        if not session.active or not session.commit_requested then
            return 0
        end

        if session.authoritative_complete then
            return 1
        end

        local solver = session.solver
        if solver and solver.finalize_progress then
            local progress = solver:finalize_progress(now)
            if progress ~= nil then
                return math_min(math_max(progress, 0), FINALIZE_PROGRESS_CAP)
            end
        end

        local duration = session.finalize_duration
        if not now or duration <= 0 then
            return 0
        end

        local progress = (now - session.finalize_started_at) / duration
        return math_min(math_max(progress, 0), FINALIZE_PROGRESS_CAP)
    end

    function Backend:_finalize_eta(now)
        local session = self._session
        if not session.active
            or not session.commit_requested
            or session.commit_sent
            or session.authoritative_complete then
            return 0
        end

        local solver = session.solver
        if solver and solver.estimated_commit_delay then
            return math_max(solver:estimated_commit_delay(now) or 0, 0)
        end

        return 0
    end

    function Backend:_refresh_public(now)
        local public = self._public
        local observed = self._observed
        local session = self._session

        public.observed = observed.active or session.active

        if not session.active then
            public.active = false
            public.claim_id = 0
            public.minigame_type = observed.active and observed.minigame_type or false
            public.status = observed.active and "observed" or "idle"
            public.stage = 0
            public.ready_to_commit = false
            public.commit_requested = false
            public.commit_sent = false
            public.authoritative_complete = false
            public.finalize_progress = 0
            public.finalize_eta = 0
            return
        end

        local solver = session.solver
        local stage = solver and solver.stage and solver:stage() or 0

        public.active = true
        public.claim_id = session.claim_id
        public.minigame_type = session.minigame_type
        public.status = session.status
        public.stage = stage or 0
        public.ready_to_commit = session.ready_to_commit
        public.commit_requested = session.commit_requested
        public.commit_sent = session.commit_sent
        public.authoritative_complete = session.authoritative_complete
        public.finalize_progress = self:_finalize_progress(now)
        public.finalize_eta = self:_finalize_eta(now)
    end

    function Backend:update(dt)
        local session = self._session
        if not self._enabled or not session.active then
            return
        end

        local now = self:time()
        if not now then
            return
        end

        if session.stopped_at > 0 and now - session.stopped_at >= COMPLETE_SNAPSHOT_HOLD then
            self:release()
            return
        end

        local minigame = session.minigame
        if not minigame then
            self:release()
            return
        end

        local solver = session.solver
        if solver and solver.update then
            solver:update(now, dt)
        end

        if solver and solver.authoritative_complete and solver:authoritative_complete() then
            self:mark_authoritative_complete()
        elseif not session.commit_requested then
            session.ready_to_commit = solver and solver.ready_to_commit and solver:ready_to_commit() or false
            session.status = session.ready_to_commit and "ready_to_commit" or "preparing"
        elseif session.commit_sent then
            session.status = "committing"
        else
            session.status = "finalizing"
        end

        self:_refresh_public(now)
    end


    function Backend:request_cancel()
        local session = self._session
        local observed = self._observed
        local player = session.player or observed.player
        local player_manager = Managers.player

        player = player or player_manager and player_manager:local_player_safe(1)
        if not player then
            return false
        end

        self._cancel_player = player
        return true
    end


    function Backend:route_player_input(player, action, original)
        if action == "action_two_pressed" and self._cancel_player == player then
            return true
        end

        local session = self._session
        if not self._enabled
            or not session.active
            or not session.input_active
            or player ~= session.player then
            return original
        end

        local auspex_only = mod:get("display_mode") == "auspex"
        local frontend_input = self._frontend_input

        if action == "action_one_hold" then
            frontend_input.primary = auspex_only and original == true or false
        elseif action == "move" then
            if auspex_only then
                frontend_input.move_x = Vector3.x(original)
                frontend_input.move_y = Vector3.y(original)
            else
                frontend_input.move_x = 0
                frontend_input.move_y = 0
            end
        elseif action == "look_raw" or action == "look_raw_controller" then
            if auspex_only then
                return Vector3(0, 0, 0)
            end

            return original
        end

        if action == "interact_hold" or action == "jump_held" then
            return false
        elseif action ~= "action_one_hold" and action ~= "move" then
            return original
        end

        local solver = session.solver
        if not solver then
            return original
        end

        local time_manager = Managers.time
        local now = time_manager and time_manager:time("gameplay")
        if not now then
            return original
        end

        if action == "action_one_hold" then
            if now < session.startup_release_until then
                return false
            end

            return solver:primary_value(now) == true
        end

        local move_x, move_y = solver:move_value(now)
        return Vector3(move_x or 0, move_y or 0, 0)
    end

    function Backend:route_orientation(player, yaw, pitch, roll)
        local session = self._session
        if not self._enabled
            or not session.active
            or not session.input_active
            or player ~= session.player
            or mod:get("display_mode") ~= "auspex" then
            self._held_orientation = false
            self._last_orientation = false
            return yaw, pitch, roll
        end

        local held = self._held_orientation
        local last = self._last_orientation
        if not held then
            held = { yaw, pitch, roll }
            last = { yaw, pitch }
            self._held_orientation = held
            self._last_orientation = last
            return yaw, pitch, roll
        end

        local delta_yaw = yaw - last[1]
        if delta_yaw > math.pi then
            delta_yaw = delta_yaw - math.pi * 2
        elseif delta_yaw < -math.pi then
            delta_yaw = delta_yaw + math.pi * 2
        end

        local frontend_input = self._frontend_input
        frontend_input.look_x = frontend_input.look_x + delta_yaw
        frontend_input.look_y = frontend_input.look_y + pitch - last[2]
        last[1] = yaw
        last[2] = pitch

        return held[1], held[2], held[3]
    end

    function Backend:take_look()
        local input = self._frontend_input
        local x = input.look_x
        local y = input.look_y
        input.look_x = 0
        input.look_y = 0
        return x, y
    end

    function Backend:frontend_input()
        return self._frontend_input
    end

    function Backend:state()
        self:_refresh_public(self:time())
        return self._public
    end

    local backend = Backend.new()
    backend.types = minigame_settings.types
    backend:_install_minigame_hooks()

    mod:hook_require("scripts/extension_systems/input/player_unit_input_extension", function(PlayerUnitInputExtension)
        mod:hook(PlayerUnitInputExtension, "get", function(func, input_extension, action)
            local value = func(input_extension, action)
            local player = input_extension and input_extension._player
            if not player then
                return value
            end
            return backend:route_player_input(player, action, value)
        end)

        mod:hook(PlayerUnitInputExtension, "get_orientation", function(func, input_extension)
            local yaw, pitch, roll = func(input_extension)
            local player = input_extension and input_extension._player
            if not player then
                return yaw, pitch, roll
            end
            return backend:route_orientation(player, yaw, pitch, roll)
        end)
    end)

    return backend
end)()

return backend
