local mod = get_mod("Cursed")

local CameraManager = require("scripts/managers/camera/camera_manager")
local Promise        = require("scripts/foundation/utilities/promise")
local MasterItems    = require("scripts/backend/master_items")
local ItemPackage    = require("scripts/foundation/managers/package/utilities/item_package")

-- FONT
local UIFonts   = require("scripts/managers/ui/ui_fonts")
local font_data = UIFonts.data_by_type("machine_medium")
local FONT_PATH = font_data.path

-- CONSTANTS
local UI_W = 1920
local UI_H = 1080

local COLLISION_FILTER      = "filter_player_character_ballistic_raycast"
local LIDAR_EXPIRE_BUCKET   = 0.5
local LIDAR_RADIAL_MIN_P    = math.rad(-85)
local LIDAR_RADIAL_MAX_P    = math.rad(85)

-- SETTING HELPER
local function s(id, fallback)
	local v = mod:get(id)
	if v == nil then return fallback end
	return v
end

-- MASTER STATE
local master_active = false
local gui_warned    = false

-- SCREENSAVER
local SS_BASE_FONT   = 32
local SS_OUTLINE     = 2
local SS_PULSE_SPEED = 3
local SS_PULSE_AMT   = 4
local SS_BOUND_W     = 360
local SS_BOUND_H     = 50

local SS_TEXTS = {
	"wake up", "wake up", "wake up", "wake up",
	"i see you", "BEHIND YOU", "DONT TRUST THEM", "watching",
	"they know", "run", "not safe", "GET OUT", "too late",
	"lying to you", "dont look back", "already inside",
	"nowhere to hide", "ITS WATCHING", "close your eyes",
	"BEHIND YOU", "do you see it",
	"dont blink", "right here", "look away",
	"not alone", "can you hear it",
}

local SS_COLORS = {
	{ 0, 255, 60 },    -- green
	{ 60, 180, 255 },  -- teal
	{ 220, 180, 50 },  -- gold
	{ 255, 200, 100 }, -- amber
	{ 255, 80, 80 },   -- red
	{ 255, 255, 255 }, -- white
}

local ss_bouncers    = {}
local ss_initialized = false

local function ss_random_sign()
	return math.random() > 0.5 and 1 or -1
end

local function ss_build()
	local count    = s("screensaver_count", 8)
	local speed_m  = s("screensaver_speed_mult", 100) / 100
	local min_spd  = 100 * speed_m
	local max_spd  = 280 * speed_m

	ss_bouncers = {}
	for i = 1, count do
		ss_bouncers[i] = {
			text      = SS_TEXTS[math.random(#SS_TEXTS)],
			x         = math.random(50, UI_W - SS_BOUND_W - 50),
			y         = math.random(50, UI_H - SS_BOUND_H - 50),
			vx        = math.random(math.floor(min_spd), math.floor(max_spd)) * ss_random_sign(),
			vy        = math.random(math.floor(min_spd), math.floor(max_spd)) * ss_random_sign(),
			color_idx = ((i - 1) % #SS_COLORS) + 1,
			phase     = math.random() * math.pi * 2,
		}
	end
	ss_initialized = true
end

local function ss_update_and_render(gui, dt, scale)
	if not s("screensaver_enabled", true) then return end
	if not ss_initialized then ss_build() end

	local opacity = math.floor(s("screensaver_opacity", 70) / 100 * 255)
	local outline = Color(opacity, 0, 0, 0)

	for _, b in ipairs(ss_bouncers) do
		-- Physics
		b.x = b.x + b.vx * dt
		b.y = b.y + b.vy * dt

		local bounced = false
		if b.x <= 0 then b.x = 0; b.vx = math.abs(b.vx); bounced = true
		elseif b.x >= UI_W - SS_BOUND_W then b.x = UI_W - SS_BOUND_W; b.vx = -math.abs(b.vx); bounced = true end
		if b.y <= 0 then b.y = 0; b.vy = math.abs(b.vy); bounced = true
		elseif b.y >= UI_H - SS_BOUND_H then b.y = UI_H - SS_BOUND_H; b.vy = -math.abs(b.vy); bounced = true end

		if bounced then
			b.color_idx = (b.color_idx % #SS_COLORS) + 1
			b.text = SS_TEXTS[math.random(#SS_TEXTS)]
		end
		b.phase = b.phase + dt * SS_PULSE_SPEED

		-- Render
		local fs = math.max(SS_BASE_FONT - SS_PULSE_AMT, SS_BASE_FONT + math.sin(b.phase) * SS_PULSE_AMT) * scale
		local px = b.x * scale
		local py = b.y * scale
		local ol = SS_OUTLINE * scale

		local ct = SS_COLORS[b.color_idx]
		local color = Color(opacity, ct[1], ct[2], ct[3])

		-- Outline (4 passes)
		Gui.slug_text(gui, b.text, FONT_PATH, fs, Vector3(px - ol, py, 998), nil, outline)
		Gui.slug_text(gui, b.text, FONT_PATH, fs, Vector3(px + ol, py, 998), nil, outline)
		Gui.slug_text(gui, b.text, FONT_PATH, fs, Vector3(px, py - ol, 998), nil, outline)
		Gui.slug_text(gui, b.text, FONT_PATH, fs, Vector3(px, py + ol, 998), nil, outline)
		Gui.slug_text(gui, b.text, FONT_PATH, fs, Vector3(px, py, 999), nil, color)
	end
end

-- FPS THROTTLE
local THROTTLE_FONT   = 120
local THROTTLE_BOUND_W = 800
local THROTTLE_BOUND_H = 150

local thr = {
	showing  = false,
	timer    = 0,
	elapsed  = 0,
	next_at  = 0,
}

local function thr_init()
	thr.showing = false
	thr.timer   = 0
	thr.elapsed = 0
	thr.next_at = math.random(s("throttle_min_delay", 30), s("throttle_max_delay", 120))
end

local function thr_cleanup()
	if thr.showing then
		Application.set_time_step_policy("throttle", 0)
	end
	thr.showing = false
end

local function thr_update_and_render(gui, dt, scale)
	if not s("throttle_enabled", true) then
		if thr.showing then
			Application.set_time_step_policy("throttle", 0)
			thr.showing = false
		end
		return
	end

	if thr.showing then
		thr.timer = thr.timer - dt
		if thr.timer <= 0 then
			thr.showing = false
			Application.set_time_step_policy("throttle", 0)
			thr.elapsed = 0
			thr.next_at = math.random(s("throttle_min_delay", 30), s("throttle_max_delay", 120))
		else
			Application.set_time_step_policy("throttle", s("throttle_fps", 15))

			-- Render warning text (ARGB color order)
			local cx = (UI_W - THROTTLE_BOUND_W) / 2 * scale
			local cy = (UI_H - THROTTLE_BOUND_H) / 2 * scale
			local fs = THROTTLE_FONT * scale
			local ol = SS_OUTLINE * scale
			local col     = Color(255, 255, 0, 0)
			local out_col = Color(255, 0, 0, 0)

			Gui.slug_text(gui, "THROTTLING FPS", FONT_PATH, fs, Vector3(cx - ol, cy, 998), nil, out_col)
			Gui.slug_text(gui, "THROTTLING FPS", FONT_PATH, fs, Vector3(cx + ol, cy, 998), nil, out_col)
			Gui.slug_text(gui, "THROTTLING FPS", FONT_PATH, fs, Vector3(cx, cy - ol, 998), nil, out_col)
			Gui.slug_text(gui, "THROTTLING FPS", FONT_PATH, fs, Vector3(cx, cy + ol, 998), nil, out_col)
			Gui.slug_text(gui, "THROTTLING FPS", FONT_PATH, fs, Vector3(cx, cy, 999), nil, col)
		end
	else
		thr.elapsed = thr.elapsed + dt
		if thr.elapsed >= thr.next_at then
			thr.showing = true
			thr.timer   = s("throttle_duration", 3)
		end
	end
end

-- DARKNESS FLASH
local dark = {
	active        = false,
	timer         = 0,
	elapsed       = 0,
	next_at       = 0,
	saved_gamma   = nil,
}

local function dark_init()
	dark.active  = false
	dark.timer   = 0
	dark.elapsed = 0
	dark.next_at = math.random(s("darkness_min_delay", 20), s("darkness_max_delay", 90))
end

local function dark_cleanup()
	if dark.active and dark.saved_gamma ~= nil then
		pcall(function()
			Application.set_user_setting("gamma", dark.saved_gamma)
			Application.apply_user_settings()
		end)
	end
	dark.active = false
	dark.saved_gamma = nil
end

local function dark_update(dt)
	if not s("darkness_enabled", false) then
		if dark.active then
			pcall(function()
				Application.set_user_setting("gamma", dark.saved_gamma or 0)
				Application.apply_user_settings()
			end)
			dark.active      = false
			dark.saved_gamma = nil
		end
		return
	end

	if dark.active then
		dark.timer = dark.timer - dt
		if dark.timer <= 0 then
			dark.active = false
			pcall(function()
				Application.set_user_setting("gamma", dark.saved_gamma or 0)
				Application.apply_user_settings()
			end)
			dark.saved_gamma = nil
			dark.elapsed = 0
			dark.next_at = math.random(s("darkness_min_delay", 20), s("darkness_max_delay", 90))
		end
	else
		dark.elapsed = dark.elapsed + dt
		if dark.elapsed >= dark.next_at then
			dark.active = true
			dark.timer  = s("darkness_duration", 5)
			pcall(function()
				dark.saved_gamma = Application.user_setting("gamma") or 0
				Application.set_user_setting("gamma", s("darkness_gamma", -10))
				Application.apply_user_settings()
			end)
		end
	end
end

-- LIDAR
local LIDAR_P = {
	h_res          = 141,
	v_res          = 97,
	h_fov          = 120,
	v_fov          = 90,
	max_range      = 30,
	dot_size       = 20,
	dot_duration   = 15,
	lines_per_dot  = 1,
	rows_per_frame = 1,
	max_dots       = 45502,
}

local lid = {
	scanning     = false,
	scan_type    = "radial",
	scan_row     = 0,
	dots         = {},
	clock        = 0,
	next_expire  = math.huge,
	line_object  = nil,
	line_world   = nil,
	rebuilding   = false,
	rebuild_read = 1,
	rebuild_write = 1,
	rebuild_len  = 0,
	pulse_timer  = 0,
}

local function lidar_rainbow(t)
	local h   = t * 4
	local seg = math.floor(h)
	local f   = math.floor(255 * (h - seg))
	if seg == 0 then     return Color(255, f, 0)
	elseif seg == 1 then return Color(255 - f, 255, 0)
	elseif seg == 2 then return Color(0, 255, f)
	else                 return Color(0, 255 - f, 255) end
end

local function lidar_get_lo()
	local world = Managers.world and Managers.world:world("level_world")
	if not world then return nil, nil end

	if not lid.line_object or lid.line_world ~= world then
		lid.line_object = World.create_line_object(world)
		if not lid.line_object then return nil, nil end
		lid.line_world = world
	end
	return lid.line_object, world
end

local function lidar_add_dot_lines(lo, pos, dist_t, r)
	local color = lidar_rainbow(dist_t)
	LineObject.add_line(lo, color, pos - Vector3(0, 0, r), pos + Vector3(0, 0, r))
end

local function lidar_start_rebuild()
	local lo = lidar_get_lo()
	if not lo then return end

	LineObject.reset(lo)
	lid.rebuilding   = true
	lid.rebuild_read = 1
	lid.rebuild_write = 1
	lid.rebuild_len  = #lid.dots
	lid.next_expire  = math.huge

	-- Instant (non-chunked) rebuild for simplicity
	local dot_r = LIDAR_P.dot_size / 1000

	while lid.rebuild_read <= lid.rebuild_len do
		local dot = lid.dots[lid.rebuild_read]
		if dot.expire > lid.clock then
			lid.dots[lid.rebuild_write] = dot
			lid.rebuild_write = lid.rebuild_write + 1
			lidar_add_dot_lines(lo, dot.pos:unbox(), dot.dist_t, dot_r)
			if dot.expire < lid.next_expire then lid.next_expire = dot.expire end
		end
		lid.rebuild_read = lid.rebuild_read + 1
	end

	-- Trim dead entries
	for i = lid.rebuild_len, lid.rebuild_write, -1 do
		lid.dots[i] = nil
	end

	LineObject.dispatch(lid.line_world, lo)
	lid.rebuilding = false
end

local function lidar_trim_oldest(target)
	local count = #lid.dots
	if count <= target then return end
	local keep = {}
	for i = count - target + 1, count do
		keep[#keep + 1] = lid.dots[i]
	end
	lid.dots = keep
end

local function lidar_get_camera_pose()
	local local_player = Managers.player and Managers.player:local_player(1)
	if not local_player then return nil end
	local cm = Managers.state and Managers.state.camera
	if not cm then return nil end
	local vp = local_player.viewport_name
	if not cm:has_viewport(vp) then return nil end
	return cm:camera_pose(vp)
end

local function lidar_get_radial_origin()
	local lp   = Managers.player and Managers.player:local_player(1)
	local unit = lp and lp.player_unit
	if unit and Unit.alive(unit) then
		return Unit.world_position(unit, 1) + Vector3(0, 0, 1.2)
	end
	local pose = lidar_get_camera_pose()
	return pose and Matrix4x4.translation(pose)
end

local function lidar_scan_rows(num_rows)
	local world = Managers.world and Managers.world:world("level_world")
	local pw    = world and World.physics_world(world)
	if not pw then lid.scanning = false; return end

	local lo = lidar_get_lo()
	if not lo then lid.scanning = false; return end

	if #lid.dots >= LIDAR_P.max_dots then
		lidar_trim_oldest(math.floor(LIDAR_P.max_dots * 0.9))
		lidar_start_rebuild()
		return
	end

	local origin, forward, right, up

	if lid.scan_type == "radial" then
		origin = lidar_get_radial_origin()
		if not origin then lid.scanning = false; return end
	else
		local pose = lidar_get_camera_pose()
		if not pose then lid.scanning = false; return end
		origin  = Matrix4x4.translation(pose)
		local r = Matrix4x4.rotation(pose)
		forward = Quaternion.forward(r)
		right   = Quaternion.right(r)
		up      = Quaternion.up(r)
	end

	local h_res     = LIDAR_P.h_res
	local v_res     = LIDAR_P.v_res
	local h_fov     = math.rad(LIDAR_P.h_fov)
	local v_fov     = math.rad(LIDAR_P.v_fov)
	local max_range = LIDAR_P.max_range
	local dot_r     = LIDAR_P.dot_size / 1000
	local expire    = (math.floor((lid.clock + LIDAR_P.dot_duration) / LIDAR_EXPIRE_BUCKET) + 1) * LIDAR_EXPIRE_BUCKET

	local h_half_tan = math.tan(h_fov / 2)
	local v_half_tan = math.tan(v_fov / 2)
	local rows_done  = 0
	local added      = false

	while lid.scan_row < v_res and rows_done < num_rows do
		for col = 0, h_res - 1 do
			local direction

			if lid.scan_type == "radial" then
				local pitch     = LIDAR_RADIAL_MIN_P + (LIDAR_RADIAL_MAX_P - LIDAR_RADIAL_MIN_P) * (lid.scan_row / (v_res - 1))
				local yaw       = 2 * math.pi * (col / h_res)
				local cos_pitch = math.cos(pitch)
				direction = Vector3(cos_pitch * math.cos(yaw), cos_pitch * math.sin(yaw), math.sin(pitch))
			else
				local v_t = 2 * (lid.scan_row / (v_res - 1)) - 1
				local h_t = 2 * (col / (h_res - 1)) - 1
				direction = Vector3.normalize(forward + right * (h_t * h_half_tan) + up * (-v_t * v_half_tan))
			end

			local ok, hit, hit_pos, hit_dist = pcall(
				PhysicsWorld.raycast, pw, origin, direction, max_range,
				"closest", "types", "both", "collision_filter", COLLISION_FILTER)

			if ok and hit and hit_pos then
				local dist_t = math.min((hit_dist or max_range) / max_range, 1)
				lid.dots[#lid.dots + 1] = { pos = Vector3Box(hit_pos), dist_t = dist_t, expire = expire }
				lidar_add_dot_lines(lo, hit_pos, dist_t, dot_r)
				added = true
				if expire < lid.next_expire then lid.next_expire = expire end
			end
		end
		lid.scan_row = lid.scan_row + 1
		rows_done    = rows_done + 1
	end

	if added then LineObject.dispatch(lid.line_world, lo) end
	if lid.scan_row >= v_res then lid.scanning = false end
end

local function lidar_update(dt)
	if not s("lidar_enabled", false) then
		if lid.scanning or #lid.dots > 0 then
			lidar_cleanup()
		end
		return
	end

	lid.clock = lid.clock + dt

	if lid.rebuilding then return end

	if lid.scanning then
		lidar_scan_rows(LIDAR_P.rows_per_frame)
		return
	end

	if lid.clock >= lid.next_expire then
		lidar_start_rebuild()
		return
	end

	lid.pulse_timer = lid.pulse_timer + dt
	if lid.pulse_timer >= s("lidar_interval", 8) then
		lid.pulse_timer = 0
		lid.scan_type   = s("lidar_mode", "radial")
		lid.scanning    = true
		lid.scan_row    = 0
	end
end

local function lidar_cleanup()
	lid.scanning    = false
	lid.scan_row    = 0
	lid.dots        = {}
	lid.next_expire = math.huge
	lid.rebuilding  = false
	lid.pulse_timer = 0

	if lid.line_object and lid.line_world then
		pcall(function()
			LineObject.reset(lid.line_object)
			LineObject.dispatch(lid.line_world, lid.line_object)
		end)
	end
	lid.line_object = nil
	lid.line_world  = nil
end

-- ZOOM SPASM
local ZOOM_LERP = 0.10

local zm = {
	active     = false,
	timer      = 0,
	elapsed    = 0,
	next_at    = 0,
	multiplier = 1.0,
	target     = 1.0,
}

local function zm_init()
	zm.active  = false
	zm.timer   = 0
	zm.elapsed = 0
	zm.next_at = math.random(s("zoom_min_delay", 15), s("zoom_max_delay", 60))
	zm.target  = 1.0
end

local function zm_cleanup()
	zm.active     = false
	zm.multiplier = 1.0
	zm.target     = 1.0
end

local function zm_tick(dt)
	if not s("zoom_enabled", true) then
		zm.active     = false
		zm.elapsed    = 0
		zm.multiplier = 1.0
		zm.target     = 1.0
		return
	end

	if zm.active then
		zm.timer = zm.timer - dt
		if zm.timer <= 0 then
			zm.active  = false
			zm.target  = 1.0
			zm.elapsed = 0
			zm.next_at = math.random(s("zoom_min_delay", 15), s("zoom_max_delay", 60))
		end
	else
		zm.elapsed = zm.elapsed + dt
		if zm.elapsed >= zm.next_at then
			zm.active = true
			zm.target = 1.0 - (s("zoom_amount", 70) / 100) * 0.9
			zm.timer  = s("zoom_duration", 3)
		end
	end
end

-- HAND FLICKER
local fl = {
	active       = false,
	timer        = 0,
	elapsed      = 0,
	next_at      = 0,
	hands_hidden = false,
}

local function fl_get_fp_unit()
	local player = Managers.player and Managers.player:local_player(1)
	local pu     = player and player.player_unit
	if not pu or not ScriptUnit.has_extension(pu, "first_person_system") then return nil end
	return ScriptUnit.extension(pu, "first_person_system"):first_person_unit()
end

local function fl_set_visible(visible)
	local fp = fl_get_fp_unit()
	if not fp or not Unit.alive(fp) then return end

	if visible then
		Unit.set_shader_pass_flag_for_meshes(fp, "one_bit_alpha", false, true)
		Unit.set_scalar_for_materials(fp, "inv_jitter_alpha", 0, true)
		Unit.set_scalar_for_materials(fp, "alpha_multiplier", 1, true)
		fl.hands_hidden = false
	else
		Unit.set_shader_pass_flag_for_meshes(fp, "one_bit_alpha", true, true)
		Unit.set_scalar_for_materials(fp, "inv_jitter_alpha", 1, true)
		Unit.set_scalar_for_materials(fp, "alpha_multiplier", 0, true)
		fl.hands_hidden = true
	end
end

local function fl_init()
	fl.active  = false
	fl.timer   = 0
	fl.elapsed = 0
	fl.next_at = math.random(s("flicker_min_delay", 20), s("flicker_max_delay", 90))
end

local function fl_cleanup()
	if fl.hands_hidden then
		pcall(fl_set_visible, true)
	end
	fl.active = false
	fl.hands_hidden = false
end

local function fl_update(dt)
	if not s("flicker_enabled", true) then
		if fl.hands_hidden then pcall(fl_set_visible, true) end
		return
	end

	if fl.active then
		fl.timer = fl.timer - dt
		if fl.timer <= 0 then
			fl.active = false
			pcall(fl_set_visible, true)
			fl.elapsed = 0
			fl.next_at = math.random(s("flicker_min_delay", 20), s("flicker_max_delay", 90))
		end
	else
		fl.elapsed = fl.elapsed + dt
		if fl.elapsed >= fl.next_at then
			fl.active = true
			fl.timer  = s("flicker_duration", 2)
			pcall(fl_set_visible, false)
		end
	end
end

-- RAVE AURA
local rave = {
	light_unit      = nil,
	player_unit     = nil,
	spawn_pending   = false,
	spawn_timer     = 0,
	spawn_gen       = 0,
	height_node     = nil,
	loaded_packages = {},
	packages_loaded = false,
	r = 0, g = 0, b = 0,
	r_inv = false, g_inv = false, b_inv = false,
	light_active    = false,
}

local function rave_despawn()
	rave.spawn_gen = rave.spawn_gen + 1

	if rave.light_unit and Unit.alive(rave.light_unit) then
		pcall(function()
			World.destroy_unit(Managers.world:world("level_world"), rave.light_unit)
		end)
	end
	rave.light_unit    = nil
	rave.spawn_pending = false
	rave.spawn_timer   = 0
end

local function rave_configure_light(light_unit)
	local light = Unit.light(light_unit, 1)
	if not light then return end

	Light.set_volumetric_intensity(light, 0.025)
	Light.set_casts_shadows(light, false)
	Light.set_color_filter(light, Vector3(1, 0, 0))
	Light.set_type(light, "omni")
	Light.set_intensity(light, math.clamp(s("rave_intensity", 50), 0, 1000))
	Light.set_falloff_start(light, 0)
	Light.set_falloff_end(light, math.clamp(s("rave_falloff", 8), 1, 100))
	Light.set_enabled(light, true)
end

local function rave_load_packages(item, callback)
	if not item then return end
	if rave.packages_loaded then
		if callback then callback() end
		return
	end

	local deps = ItemPackage.compile_item_instance_dependencies(item, MasterItems.get_cached(), nil, nil)
	local loading = {}
	for pkg, _ in pairs(deps) do
		deps[pkg]     = true
		loading[pkg]  = false
		local load_id = Managers.package:load(pkg, "cursed_rave", function() loading[pkg] = true end, true)
		rave.loaded_packages[pkg] = rave.loaded_packages[pkg] or {}
		table.insert(rave.loaded_packages[pkg], load_id)
	end

	if callback then
		Promise.until_value_is_true(function()
			for _, done in pairs(loading) do
				if not done then return false end
			end
			return true
		end):next(function()
			rave.packages_loaded = true
			callback()
		end)
	end
end

local function rave_spawn()
	rave.spawn_gen = rave.spawn_gen + 1
	local my_gen   = rave.spawn_gen

	if not rave.light_active or not mod:is_enabled() then
		rave.spawn_pending = false
		return
	end
	if not MasterItems.has_data() then
		rave.spawn_pending = false
		return
	end

	local battery = MasterItems.get_item("content/items/luggable/battery_01_luggable")
	local world   = Managers.world:world("level_world")
	local player  = Managers.player:local_player_safe(1)
	if not player then rave.spawn_pending = false; return end

	local pu = player.player_unit
	rave.player_unit = pu
	if not Unit.is_valid(pu) then rave.spawn_pending = false; return end

	local hand_node = Unit.node(pu, "j_lefttoebase")

	rave_load_packages(battery, function()
		if my_gen ~= rave.spawn_gen then return end
		if not rave.light_active or not mod:is_enabled() then rave.spawn_pending = false; return end
		if not Unit.is_valid(pu) then rave.spawn_pending = false; return end

		if rave.light_unit and Unit.alive(rave.light_unit) then
			World.destroy_unit(world, rave.light_unit)
			rave.light_unit = nil
		end

		local pos = Unit.world_position(pu, hand_node)
		local rot = Unit.world_rotation(pu, hand_node)

		rave.light_unit = World.spawn_unit(world, battery.base_unit, pos, rot)
		Unit.set_local_scale(rave.light_unit, 1, Vector3.one() * 0.001)

		-- Cache height node
		local hn = nil
		local ok33 = pcall(Unit.local_position, pu, 33)
		if ok33 then
			hn = 33
		else
			local ok_s, sn = pcall(Unit.node, pu, "j_spine")
			if ok_s then hn = sn end
		end
		rave.height_node = hn

		pcall(rave_configure_light, rave.light_unit)
		rave.spawn_pending = false
	end)
end

local function rave_update(dt)
	if not s("rave_enabled", false) then
		if rave.light_active then
			rave.light_active = false
			rave_despawn()
		end
		return
	end

	if not rave.light_active then
		rave.light_active = true
	end

	-- Colour cycling
	local speed = (s("rave_speed", 100) / 100)
	if rave.r_inv then rave.r = rave.r - dt * speed;       if rave.r <= 0.05 then rave.r_inv = false end
	else               rave.r = rave.r + dt * speed;       if rave.r >= 1    then rave.r_inv = true  end end
	if rave.b_inv then rave.b = rave.b - dt * 0.7 * speed; if rave.b <= 0.05 then rave.b_inv = false end
	else               rave.b = rave.b + dt * 0.7 * speed; if rave.b >= 1    then rave.b_inv = true  end end
	if rave.g_inv then rave.g = rave.g - dt * 0.6 * speed; if rave.g <= 0.05 then rave.g_inv = false end
	else               rave.g = rave.g + dt * 0.6 * speed; if rave.g >= 1    then rave.g_inv = true  end end

	-- Apply colour to light
	if rave.light_unit and Unit.is_valid(rave.light_unit) then
		local light = Unit.light(rave.light_unit, 1)
		if light then
			Light.set_color_filter(light, Vector3(rave.r, rave.g, rave.b))
		end
	end

	-- Spawn timeout safety
	if rave.spawn_pending then
		rave.spawn_timer = rave.spawn_timer + dt
		if rave.spawn_timer > 5 then
			rave.spawn_pending = false
			rave.spawn_timer   = 0
		end
	end

	-- Auto-respawn if needed
	if rave.light_active then
		local player = Managers.player:local_player_safe(1)
		if player then
			local cpu = player.player_unit
			if cpu and Unit.is_valid(cpu) then
				local needs = false
				if cpu ~= rave.player_unit then
					rave_despawn()
					rave.light_active = true -- restore intent after despawn
					needs = true
				elseif rave.light_unit == nil or not Unit.is_valid(rave.light_unit) then
					needs = true
				end
				if needs and not rave.spawn_pending then
					rave.spawn_pending = true
					rave.spawn_timer   = 0
					rave_spawn()
				end
			end
		end
	end

	-- Track position
	if rave.light_unit and rave.player_unit and Unit.is_valid(rave.player_unit) and Unit.is_valid(rave.light_unit) then
		local pp = Unit.local_position(rave.player_unit, 1)
		if rave.height_node then
			pp[3] = pp[3] + Unit.local_position(rave.player_unit, rave.height_node)[3] - 0.25
		end
		Unit.set_local_position(rave.light_unit, 1, pp)
	end
end

local function rave_full_cleanup()
	rave.light_active = false
	rave_despawn()
	for pkg, ids in pairs(rave.loaded_packages) do
		for _, load_id in ipairs(ids) do
			pcall(Managers.package.release, Managers.package, load_id)
		end
	end
	rave.loaded_packages = {}
	rave.packages_loaded = false
end

-- MASTER CLEANUP
local function cleanup_all()
	thr_cleanup()
	dark_cleanup()
	lidar_cleanup()
	zm_cleanup()
	fl_cleanup()
	rave_full_cleanup()
	ss_initialized = false
	ss_bouncers    = {}
end

-- HOOKS

-- Suppress battery collision sound for the rave aura
mod:hook("WwiseWorld", "trigger_resource_event", function(func, self_arg, file_path, ...)
	if file_path == "wwise/events/world/play_phys_metal_hollow_med" then return end
	return func(self_arg, file_path, ...)
end)

-- UIHud: screensaver rendering + FPS throttle text
mod:hook(CLASS.UIHud, "update", function(func, self, dt, t, ...)
	func(self, dt, t, ...)

	if not master_active or not mod:is_enabled() then return end

	-- Acquire gui handle (same approach as the loadfile)
	local gui = nil
	local ui_renderer = rawget(self, "_ui_renderer") or rawget(self, "ui_renderer") or rawget(self, "_renderer")
	if ui_renderer then gui = rawget(ui_renderer, "gui") end

	if not gui then
		local ui_mgr = Managers.ui
		if ui_mgr then
			local mgr_r = rawget(ui_mgr, "_ui_renderer") or rawget(ui_mgr, "ui_renderer")
			if mgr_r then gui = rawget(mgr_r, "gui") end
		end
	end

	if not gui then
		if not gui_warned then gui_warned = true end
		return
	end

	local scale = RESOLUTION_LOOKUP.scale or 1

	pcall(ss_update_and_render, gui, dt, scale)
	pcall(thr_update_and_render, gui, dt, scale)
end)

-- CameraManager: zoom spasm FOV manipulation
mod:hook(CameraManager, "_update_camera_properties", function(original, self, camera, shadow_cull_camera, camera_nodes, camera_data, viewport_name)
	if master_active and mod:is_enabled() and camera_data.vertical_fov then
		zm.multiplier = math.lerp(zm.multiplier, zm.target, ZOOM_LERP)
		if math.abs(zm.multiplier - zm.target) < 0.001 then
			zm.multiplier = zm.target
		end
		camera_data.vertical_fov = camera_data.vertical_fov * zm.multiplier
	end
	original(self, camera, shadow_cull_camera, camera_nodes, camera_data, viewport_name)
end)

-- Respawn rave light on weapon switch
mod:hook_safe("ActionWield", "start", function()
	if rave.light_active and (rave.light_unit == nil or not Unit.is_valid(rave.light_unit)) and not rave.spawn_pending then
		rave.spawn_pending = true
		rave.spawn_timer   = 0
		rave_spawn()
	end
end)

mod:hook_safe("ActionRangedWield", "start", function()
	if rave.light_active and (rave.light_unit == nil or not Unit.is_valid(rave.light_unit)) and not rave.spawn_pending then
		rave.spawn_pending = true
		rave.spawn_timer   = 0
		rave_spawn()
	end
end)

-- UPDATE LOOP
mod.update = function(dt)
	if not mod:is_enabled() or not master_active then return end

	dark_update(dt)
	lidar_update(dt)
	zm_tick(dt)
	fl_update(dt)
	rave_update(dt)
end

-- KEYBIND CALLBACK
mod.toggle_master = function()
	master_active = not master_active

	if master_active then
		-- Initialise timers
		thr_init()
		dark_init()
		zm_init()
		fl_init()
		lid.pulse_timer = 0
		ss_initialized  = false
	else
		cleanup_all()
	end
end

-- LIFECYCLE
mod.on_enabled = function()
	-- Don't auto-activate; wait for the keybind
end

mod.on_disabled = function()
	master_active = false
	cleanup_all()
end

mod.on_game_state_changed = function(status, state_name)
	if state_name == "StateGameplay" and status == "exit" then
		-- Clean up everything on mission exit
		local was_active = master_active
		cleanup_all()
		-- Keep master intent but reset state
		master_active  = was_active
		gui_warned     = false
		if was_active then
			thr_init()
			dark_init()
			zm_init()
			fl_init()
			lid.pulse_timer = 0
			lid.clock       = 0
		end
	end
end

mod.on_setting_changed = function(setting_id)
	-- Rebuild screensaver if count or speed changed while active
	if master_active and (setting_id == "screensaver_count" or setting_id == "screensaver_speed_mult") then
		ss_initialized = false
	end

	-- Live-update rave light properties
	if master_active and rave.light_unit and Unit.is_valid(rave.light_unit) then
		if setting_id == "rave_intensity" or setting_id == "rave_falloff" then
			pcall(rave_configure_light, rave.light_unit)
		end
	end
end
