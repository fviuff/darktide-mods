local mod = get_mod("NoBrainer")

local api = {}

api.defaults = {
    analysis_mode = "homology",

    global_frame_budget = 12000,
    global_draw_limit_enabled = true,
    global_max_draw_lines = 400,

    darkness_enabled = false,
    gamma_level = -10,

    h_res = 80,
    v_res = 50,
    h_fov = 90,
    v_fov = 60,
    max_range = 30,

    dot_size = 5,
    dot_duration = 15,
    color_scheme = "classic",
    lines_per_dot = 3,
    mesh_link_distance = 4.0,
    line_surface_lift = 0.03,
    max_dots = 35000,
    recycle_oldest = true,

    max_epsilon = 4.0,
    min_persistence = 0.0,
    max_cycles = 12,

    heat_radius = 25,
    heat_front_points = 128,
    heat_step_length = 0.25,
    heat_probe_distance = 0.45,
    heat_surface_lift = 0.025,

    heat_speed = 7,
    heat_trails = 4,
    heat_trail_spacing = 0.65,
    heat_color = "cyan",
    heat_loop = false,

    bpa_sample_spacing = 1.50,
    bpa_ball_radius = 2.25,
    bpa_scan_time = 12,
    bpa_duration = 30,
    bpa_color = "cyan",

    tsdf_voxel_size = 0.35,
    tsdf_truncation = 0.70,
    tsdf_max_voxels = 60000,
    tsdf_color = "cyan",

    pc_max_points = 5000,
    pc_sample_spacing = 0.30,
    pc_scale = 1.50,
    pc_color = "cyan",

    proc_pattern = "lorenz",
    proc_scale = 1.75,
    proc_detail = 1.5,
    proc_distance = 4.5,
    proc_color = "cyan",

    nav_radius = 25,
    nav_speed = 7,
    nav_trails = 4,
    nav_trail_spacing = 0.65,
    nav_surface_lift = 0.025,
    nav_color = "cyan",
    nav_loop = false,
}

function api.get(id, fallback)
    local value = mod:get(id)
    if value == nil or value == "" then
        if fallback ~= nil then return fallback end
        return api.defaults[id]
    end
    return value
end

function api.number(id, fallback)
    local value = tonumber(api.get(id, fallback))
    if value ~= nil then return value end
    return tonumber(fallback) or tonumber(api.defaults[id]) or 0
end

function api.boolean(id, fallback)
    local value = api.get(id, fallback)
    return value == true
end

function api.mode()
    return api.get("analysis_mode")
end

function api.surface_sampler()
    local step = math.max(0.08, api.number("heat_step_length"))
    local front_points = math.floor(math.max(24, math.min(256, api.number("heat_front_points"))))
    local scale = math.sqrt(96 / front_points)
    scale = math.max(0.68, math.min(1.35, scale))

    return {
        radius = math.max(1, api.number("heat_radius")),
        front_points = front_points,
        step = step,

        probe = math.max(0.02, api.number("heat_probe_distance")),
        lift = math.max(0.001, api.number("heat_surface_lift")),
        cell = step * scale,
    }
end

return api
