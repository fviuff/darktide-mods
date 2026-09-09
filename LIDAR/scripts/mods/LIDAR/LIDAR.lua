local mod = get_mod("LIDAR")

local COLLISION_FILTER = "filter_player_character_ballistic_raycast"
local EXPIRE_BUCKET = 0.5
local RADIAL_MIN_PITCH = math.rad(-85)
local RADIAL_MAX_PITCH = math.rad(85)

-- State

local scanning = false
local scan_type = "fov"
local scan_row = 0
local line_object = nil
local line_world = nil
local dots = {}
local clock = 0
local next_expire = math.huge

-- Chunked rebuild state (spreads work over frames to stay inside the engines budget)
-- Prevents crashes?
local rebuilding = false
local rebuild_read = 1
local rebuild_write = 1
local rebuild_len = 0

local auto_pulse_timer = 0

local function setting(id, fallback)
	local value = mod:get(id)
	if value == nil or value == "" then return fallback end
	return value
end

-- Darkness

local function apply_darkness()
	if not setting("darkness_enabled", false) then return end

	Application.set_user_setting("gamma", setting("gamma_level", -10))

	if Application.apply_user_settings then
		pcall(Application.apply_user_settings)
	end
end

-- Camera / player

local function get_camera_pose()
	local local_player = Managers.player and Managers.player:local_player(1)
	if not local_player then return nil end

	local camera_manager = Managers.state and Managers.state.camera
	if not camera_manager then return nil end

	local viewport_name = local_player.viewport_name
	if not camera_manager:has_viewport(viewport_name) then return nil end

	return camera_manager:camera_pose(viewport_name)
end

-- 1.2 works well - see angle.lua
local function get_radial_origin()
	local local_player = Managers.player and Managers.player:local_player(1)
	local unit = local_player and local_player.player_unit

	if unit and Unit.alive(unit) then
		return Unit.world_position(unit, 1) + Vector3(0, 0, 1.2)
	end

	local pose = get_camera_pose()
	return pose and Matrix4x4.translation(pose)
end

-- Drawing

local function get_line_object()
	local world = Managers.world and Managers.world:world("level_world")
	if not world then return nil end

	if not line_object or line_world ~= world then
		line_object = World.create_line_object(world)
		if not line_object then return nil end
		line_world = world
	end

	return line_object, world
end

-- Color schemes: map distance t (0 near, 1 far) to a color
local COLOR_SCHEMES = {
	classic = function(t)
		return Color(math.floor(40 * (1 - t)), math.floor(255 * (1 - t)), math.floor(60 + 195 * t))
	end,
	mono = function(t)
		local v = math.floor(255 - 215 * t)
		return Color(v, v, v)
	end,
	infrared = function(t)
		return Color(math.floor(255 - 175 * t), math.floor(60 * (1 - t)), math.floor(30 * (1 - t)))
	end,
	amber = function(t)
		return Color(math.floor(255 - 155 * t), math.floor(170 * (1 - t) + 30), 0)
	end,
	toxin = function(t)
		return Color(math.floor(120 * t + 40), 255 - math.floor(155 * t), math.floor(40 * (1 - t)))
	end,
	rainbow = function(t)
		-- Hue sweep red -> blue across distance
		local h = t * 4
		local seg = math.floor(h)
		local f = math.floor(255 * (h - seg))
		if seg == 0 then return Color(255, f, 0)
		elseif seg == 1 then return Color(255 - f, 255, 0)
		elseif seg == 2 then return Color(0, 255, f)
		else return Color(0, 255 - f, 255)
		end
	end,
}

local function distance_color(t)
	local scheme = COLOR_SCHEMES[setting("color_scheme", "classic")] or COLOR_SCHEMES.classic
	return scheme(t)
end

local function add_dot_lines(lo, pos, dist_t, r, num_lines)
	local color = distance_color(dist_t)
	LineObject.add_line(lo, color, pos - Vector3(0, 0, r), pos + Vector3(0, 0, r))
	if num_lines >= 2 then
		LineObject.add_line(lo, color, pos - Vector3(r, 0, 0), pos + Vector3(r, 0, 0))
	end
	if num_lines >= 3 then
		LineObject.add_line(lo, color, pos - Vector3(0, r, 0), pos + Vector3(0, r, 0))
	end
end

-- Chunked rebuild

local rebuild_step

local function start_rebuild()
	local lo = get_line_object()
	if not lo then return end

	LineObject.reset(lo)

	rebuilding = true
	rebuild_read = 1
	rebuild_write = 1
	rebuild_len = #dots
	next_expire = math.huge

	-- This works fine
	if not setting("chunked_rebuild", false) then
		rebuild_step(math.huge)
	end
end

rebuild_step = function(chunk)
	local lo, world = get_line_object()
	if not lo then
		rebuilding = false
		return
	end

	local dot_r = setting("dot_size", 5) / 1000
	local num_lines = tonumber(setting("lines_per_dot", 3)) or 3
	local processed = 0

	while rebuild_read <= rebuild_len and processed < chunk do
		local dot = dots[rebuild_read]

		if dot.expire > clock then
			dots[rebuild_write] = dot
			rebuild_write = rebuild_write + 1

			add_dot_lines(lo, dot.pos:unbox(), dot.dist_t, dot_r, num_lines)

			if dot.expire < next_expire then next_expire = dot.expire end
		end

		rebuild_read = rebuild_read + 1
		processed = processed + 1
	end

	LineObject.dispatch(world, lo)

	if rebuild_read > rebuild_len then
		for i = rebuild_len, rebuild_write, -1 do
			dots[i] = nil
		end
		rebuilding = false
	end
end

local function trim_oldest(target)
	local count = #dots
	if count <= target then return end

	local keep = {}
	for i = count - target + 1, count do
		keep[#keep + 1] = dots[i]
	end
	dots = keep
end

-- Scanning (stop frame drop also cool scan)

local function scan_rows(num_rows)
	local world = Managers.world and Managers.world:world("level_world")
	local physics_world = world and World.physics_world(world)
	if not physics_world then
		scanning = false
		return
	end

	local lo = get_line_object()
	if not lo then
		scanning = false
		return
	end

	local max_dots = setting("max_dots", 35000)

	if #dots >= max_dots then
		if setting("recycle_oldest", true) then
			-- Drop to 90% of cap; the chunked rebuild repaints the survivors
			trim_oldest(math.floor(max_dots * 0.9))
			start_rebuild()
			return
		else
			scanning = false
			return
		end
	end

	-- Ray basis
	local origin, forward, right, up

	if scan_type == "radial" then
		origin = get_radial_origin()
		if not origin then
			scanning = false
			return
		end
	else
		local pose = get_camera_pose()
		if not pose then
			scanning = false
			return
		end
		origin = Matrix4x4.translation(pose)
		local cam_rotation = Matrix4x4.rotation(pose)
		forward = Quaternion.forward(cam_rotation)
		right = Quaternion.right(cam_rotation)
		up = Quaternion.up(cam_rotation)
	end

	local h_res = setting("h_res", 80)
	local v_res = setting("v_res", 50)
	local h_fov = math.rad(setting("h_fov", 90))
	local v_fov = math.rad(setting("v_fov", 60))
	local max_range = setting("max_range", 30)
	local duration = setting("dot_duration", 15)
	local dot_r = setting("dot_size", 5) / 1000
	local num_lines = tonumber(setting("lines_per_dot", 3)) or 3

	-- Bucket expiry times so rebuilds happen in batches
	local expire = (math.floor((clock + duration) / EXPIRE_BUCKET) + 1) * EXPIRE_BUCKET

	local h_half_tan = math.tan(h_fov / 2)
	local v_half_tan = math.tan(v_fov / 2)

	local rows_done = 0
	local added = false

	while scan_row < v_res and rows_done < num_rows do
		for col = 0, h_res - 1 do
			local direction

			if scan_type == "radial" then
				-- Bottom up pitch for full 360
				local pitch = RADIAL_MIN_PITCH + (RADIAL_MAX_PITCH - RADIAL_MIN_PITCH) * (scan_row / (v_res - 1))
				local yaw = 2 * math.pi * (col / h_res)
				local cos_pitch = math.cos(pitch)

				direction = Vector3(
					cos_pitch * math.cos(yaw),
					cos_pitch * math.sin(yaw),
					math.sin(pitch)
				)
			else
				local v_t = 2 * (scan_row / (v_res - 1)) - 1
				local h_t = 2 * (col / (h_res - 1)) - 1

				direction = Vector3.normalize(
					forward
					+ right * (h_t * h_half_tan)
					+ up * (-v_t * v_half_tan)
				)
			end

			local ok, hit, hit_position, hit_distance = pcall(
				PhysicsWorld.raycast,
				physics_world, origin, direction, max_range,
				"closest", "types", "both", "collision_filter", COLLISION_FILTER)

			if ok and hit and hit_position then
				local dist_t = math.min((hit_distance or max_range) / max_range, 1)

				dots[#dots + 1] = {
					pos = Vector3Box(hit_position),
					dist_t = dist_t,
					expire = expire,
				}

				add_dot_lines(lo, hit_position, dist_t, dot_r, num_lines)
				added = true

				if expire < next_expire then next_expire = expire end
			end
		end

		scan_row = scan_row + 1
		rows_done = rows_done + 1
	end

	if added then
		LineObject.dispatch(line_world, lo)
	end

	if scan_row >= v_res then
		scanning = false
	end
end

-- Update loop (Could do better to stop crashes maybe)

mod.update = function(dt)
	if not mod:is_enabled() then return end

	clock = clock + dt

	-- Rebuild and scan never run in the same frame; both are temp-vector heavy
	if rebuilding then
		rebuild_step(setting("rebuild_per_frame", 1500))
		return
	end

	if scanning then
		scan_rows(setting("rows_per_frame", 5))
	end

	if clock >= next_expire then
		start_rebuild()
	end

	-- Auto pulse
	if setting("auto_pulse", false) then
		auto_pulse_timer = auto_pulse_timer + dt
		if auto_pulse_timer >= setting("auto_pulse_interval", 6) and not scanning and not rebuilding then
			auto_pulse_timer = 0
			scan_type = setting("auto_pulse_mode", "radial")
			scanning = true
			scan_row = 0
		end
	else
		auto_pulse_timer = 0
	end
end

-- Callbacks

mod.lidar_scan = function()
	if scanning then return end
	scanning = true
	scan_type = "fov"
	scan_row = 0
end

mod.radial_scan = function()
	if scanning then return end
	scanning = true
	scan_type = "radial"
	scan_row = 0
end

mod.on_setting_changed = function(setting_id)
	if setting_id == "darkness_enabled" then
		apply_darkness()
	elseif setting_id == "color_scheme" or setting_id == "lines_per_dot" or setting_id == "dot_size" then
		if #dots > 0 and not rebuilding then
			start_rebuild()
		end
	end
end

local function reset_state()
	scanning = false
	scan_row = 0
	dots = {}
	next_expire = math.huge
	rebuilding = false
	auto_pulse_timer = 0
end

local function clear_all()
	reset_state()
	if line_object and line_world then
		LineObject.reset(line_object)
		LineObject.dispatch(line_world, line_object)
	end
end

mod.on_enabled = function()
	apply_darkness()
end

mod.on_disabled = function()
	clear_all()
end

mod.on_game_state_changed = function(status, state_name)
	if state_name == "StateGameplay" and status == "exit" then
		reset_state()
		line_object = nil
		line_world = nil
	end
end
