local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")
local math3d = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/StingrayMath")

local api = {}

local math_abs = math.abs
local math_ceil = math.ceil
local math_cos = math.cos
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_pi = math.pi
local math_sin = math.sin
local math_sqrt = math.sqrt
local pairs = pairs
local pcall = pcall
local tostring = tostring

local Vector3_new = Vector3
local Color_new = Color
local World_create_line_object = World.create_line_object
local World_destroy_line_object = World.destroy_line_object
local LineObject_add_line = LineObject.add_line
local LineObject_reset = LineObject.reset
local LineObject_dispatch = LineObject.dispatch

local EPS = 1e-7
local RENDER_INTERVAL = 1 / 30
local SOURCE_PROBE_DISTANCE = 3.0
local SOURCE_FALLBACK_RAYS = 24


local PROPAGATION_CANDIDATES_PER_FRAME = 300
local PROPAGATION_WORK_COST = 30
local PROPAGATION_BUDGET_FRACTION = 0.75
local STROKE_WORK_COST = 4
local TURN_ANGLE = math_pi * 0.17
local CORNER_NORMAL_DOT = 0.985
local SMOOTH_NORMAL_DOT = 0.10
local PATH_CLEARANCE_MIN = 0.018

local line_object = nil
local line_world = nil
local physics_world = nil
local clock = 0
local phase = "idle"

local source_x, source_y, source_z = nil, nil, nil
local source_nx, source_ny, source_nz = 0, 0, 1
local source_t1x, source_t1y, source_t1z = 1, 0, 0
local source_t2x, source_t2y, source_t2z = 0, 1, 0


local frontier = {}
local simulation_step = 0
local expansion_index = 1
local seed_index = 1
local seed_count = 0
local propagation_finished = false

local visited = {}
local next_by_key = {}


local history = {}
local history_capacity = 0


local stroke_revision = 1

local wave_age = 0
local next_render = 0


local cfg_step = 0.25
local cfg_probe = 0.45
local cfg_lift = 0.025
local cfg_radius = 25
local cfg_front_points = 128
local cfg_trails = 4
local cfg_trail_spacing = 0.65
local cfg_cell = 0.25


local function setting(id, fallback)
    local value = settings.get(id)
    if value == nil then return fallback end
    return value
end

local function clear_array(t)
    for i = #t, 1, -1 do
        t[i] = nil
    end
end

local function clear_map(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local function refresh_config()
    cfg_step = math_max(0.08, setting("heat_step_length", 0.25))
    cfg_probe = math_max(cfg_step * 0.65, setting("heat_probe_distance", 0.45))
    cfg_lift = math_max(setting("heat_surface_lift", 0.025), PATH_CLEARANCE_MIN)
    cfg_radius = math_max(1, setting("heat_radius", 25))
    cfg_front_points = math_floor(math_max(24, math_min(256, setting("heat_front_points", 128))))
    cfg_trails = math_floor(math_max(1, setting("heat_trails", 4)))
    cfg_trail_spacing = math_max(0.05, setting("heat_trail_spacing", 0.65))

    local scale = math_sqrt(96 / cfg_front_points)
    scale = math_max(0.68, math_min(1.35, scale))
    cfg_cell = cfg_step * scale
end

local function normalize(x, y, z)
    return math3d.normalize(x, y, z, EPS)
end

local dot = math3d.dot
local cross = math3d.cross
local squared_distance = math3d.squared_distance

local function tangent_basis(nx, ny, nz)
    return math3d.tangent_basis(nx, ny, nz, EPS)
end

local function clean_tangent(dx, dy, dz, nx, ny, nz)
    return math3d.clean_tangent(dx, dy, dz, nx, ny, nz, EPS)
end

local function transport_direction(dx, dy, dz, n1x, n1y, n1z, n2x, n2y, n2z)
    return math3d.transport_direction(dx, dy, dz, n1x, n1y, n1z, n2x, n2y, n2z, EPS)
end


local function destroy_line_object()
    if line_object and line_world then
        pcall(LineObject_reset, line_object)
        pcall(LineObject_dispatch, line_world, line_object)
        if World_destroy_line_object then
            pcall(World_destroy_line_object, line_world, line_object)
        end
    end
    line_object = nil
    line_world = nil
end

local function get_context()
    local world = runtime.current_world()
    if not world then return nil, nil, nil end
    if line_world and line_world ~= world then destroy_line_object() end
    if not line_object then
        local ok, object = pcall(World_create_line_object, world)
        if not ok or not object then return nil, world, nil end
        line_object = object
        line_world = world
    end
    physics_world = runtime.physics_world(world)
    return line_object, world, physics_world
end

local function clear_drawing()
    if line_object and line_world then
        pcall(LineObject_reset, line_object)
        pcall(LineObject_dispatch, line_world, line_object)
    end
end

local function player_position()
    return runtime.player_position()
end

local function raycast(px, py, pz, dx, dy, dz, distance)
    if not physics_world or distance <= 0 then return nil end
    return runtime.raycast_static(physics_world, px, py, pz, dx, dy, dz, distance, false)
end


local function rotate_tangent(dx, dy, dz, nx, ny, nz, angle)
    if math_abs(angle) <= EPS then
        return dx, dy, dz
    end

    local sx, sy, sz = cross(nx, ny, nz, dx, dy, dz)
    sx, sy, sz = normalize(sx, sy, sz)
    if not sx then
        return dx, dy, dz
    end

    local ca = math_cos(angle)
    local sa = math_sin(angle)
    return normalize(
        dx * ca + sx * sa,
        dy * ca + sy * sa,
        dz * ca + sz * sa
    )
end

local function find_source_surface(px, py, pz)
    local hx, hy, hz, _, nx, ny, nz = raycast(px, py, pz + 0.8, 0, 0, -1, SOURCE_PROBE_DISTANCE)
    if hx then
        return hx, hy, hz, nx, ny, nz
    end

    local best_d2 = math.huge
    local bx, by, bz, bnx, bny, bnz
    local golden = math_pi * (3 - math_sqrt(5))

    for i = 0, SOURCE_FALLBACK_RAYS - 1 do
        local z = 1 - 2 * ((i + 0.5) / SOURCE_FALLBACK_RAYS)
        local r = math_sqrt(math_max(0, 1 - z * z))
        local a = i * golden
        local dx = math_cos(a) * r
        local dy = math_sin(a) * r
        local dz = z
        local qx, qy, qz, _, qnx, qny, qnz = raycast(px, py, pz, dx, dy, dz, SOURCE_PROBE_DISTANCE)
        if qx then
            local d2 = squared_distance(px, py, pz, qx, qy, qz)
            if d2 < best_d2 then
                best_d2 = d2
                bx, by, bz = qx, qy, qz
                bnx, bny, bnz = qnx, qny, qnz
            end
        end
    end

    return bx, by, bz, bnx, bny, bnz
end


local function path_is_clear(px, py, pz, nx, ny, nz, qx, qy, qz, qnx, qny, qnz)
    local lift = cfg_lift
    local sx = px + nx * lift * 1.6
    local sy = py + ny * lift * 1.6
    local sz = pz + nz * lift * 1.6
    local ex = qx + qnx * lift * 1.6
    local ey = qy + qny * lift * 1.6
    local ez = qz + qnz * lift * 1.6
    local dx, dy, dz = ex - sx, ey - sy, ez - sz
    local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
    if distance <= 0.03 then
        return true
    end

    local _, _, _, hit_distance = raycast(sx, sy, sz, dx, dy, dz, distance)
    if not hit_distance then
        return true
    end


    local margin = math_max(0.035, distance * 0.12)
    return hit_distance >= distance - margin
end

local function project_smooth_target(tx, ty, tz, nx, ny, nz, probe, px, py, pz, dx, dy, dz)
    local ox = tx + nx * probe * 0.58
    local oy = ty + ny * probe * 0.58
    local oz = tz + nz * probe * 0.58
    local hx, hy, hz, _, hnx, hny, hnz = raycast(ox, oy, oz, -nx, -ny, -nz, probe * 1.18)
    if not hx then
        return nil
    end

    if dot(nx, ny, nz, hnx, hny, hnz) < SMOOTH_NORMAL_DOT then
        return nil
    end

    local mvx, mvy, mvz = hx - px, hy - py, hz - pz
    if dot(mvx, mvy, mvz, dx, dy, dz) <= 0.02 then
        return nil
    end

    return hx, hy, hz, hnx, hny, hnz
end

local function project_corner_target(tx, ty, tz, nx, ny, nz, probe)
    local ox = tx + nx * probe * 0.55
    local oy = ty + ny * probe * 0.55
    local oz = tz + nz * probe * 0.55
    local hx, hy, hz, _, hnx, hny, hnz = raycast(ox, oy, oz, -nx, -ny, -nz, probe * 1.12)
    if hx then
        return hx, hy, hz, hnx, hny, hnz
    end
    return nil
end


local function surface_move(node, requested_dx, requested_dy, requested_dz)
    local step = cfg_step
    local probe = cfg_probe
    local lift = cfg_lift

    local px, py, pz = node.x, node.y, node.z
    local nx, ny, nz = node.nx, node.ny, node.nz
    local dx, dy, dz = clean_tangent(requested_dx, requested_dy, requested_dz, nx, ny, nz)
    if not dx then
        return nil
    end


    local fx, fy, fz, fd, fnx, fny, fnz = raycast(
        px + nx * lift * 1.7,
        py + ny * lift * 1.7,
        pz + nz * lift * 1.7,
        dx, dy, dz,
        step * 1.04
    )

    if fx and fd < step * 0.96 then
        local normal_change = dot(nx, ny, nz, fnx, fny, fnz)


        if normal_change < CORNER_NORMAL_DOT then
            local ndx, ndy, ndz = transport_direction(dx, dy, dz, nx, ny, nz, fnx, fny, fnz)
            local remain = step - math_max(fd, 0)
            if remain < step * 0.18 then
                remain = step * 0.18
            end

            local tx = fx + ndx * remain
            local ty = fy + ndy * remain
            local tz = fz + ndz * remain
            local qx, qy, qz, qnx, qny, qnz = project_corner_target(tx, ty, tz, fnx, fny, fnz, probe)

            if qx then
                local second_clear = path_is_clear(fx, fy, fz, fnx, fny, fnz, qx, qy, qz, qnx, qny, qnz)
                if second_clear then
                    local total_d2 = squared_distance(px, py, pz, qx, qy, qz)
                    if total_d2 <= (step + probe * 0.55) * (step + probe * 0.55) then
                        local fdx, fdy, fdz = transport_direction(ndx, ndy, ndz, fnx, fny, fnz, qnx, qny, qnz)
                        return qx, qy, qz, qnx, qny, qnz, fdx, fdy, fdz
                    end
                end
            end
        end

        return nil
    end


    local tx = px + dx * step
    local ty = py + dy * step
    local tz = pz + dz * step
    local qx, qy, qz, qnx, qny, qnz = project_smooth_target(tx, ty, tz, nx, ny, nz, probe, px, py, pz, dx, dy, dz)

    if qx then
        local max_move = step + probe * 0.38
        if squared_distance(px, py, pz, qx, qy, qz) <= max_move * max_move
            and path_is_clear(px, py, pz, nx, ny, nz, qx, qy, qz, qnx, qny, qnz) then
            local ndx, ndy, ndz = transport_direction(dx, dy, dz, nx, ny, nz, qnx, qny, qnz)
            return qx, qy, qz, qnx, qny, qnz, ndx, ndy, ndz
        end
    end


    local sx, sy, sz = cross(nx, ny, nz, dx, dy, dz)
    sx, sy, sz = normalize(sx, sy, sz)
    if not sx then
        return nil
    end

    local ox = tx + nx * lift * 2.0
    local oy = ty + ny * lift * 2.0
    local oz = tz + nz * lift * 2.0
    local best_d2 = math.huge
    local bx, by, bz, bnx, bny, bnz

    local function consider(vx, vy, vz)
        local hx, hy, hz, _, hnx, hny, hnz = raycast(ox, oy, oz, vx, vy, vz, probe * 1.10)
        if hx then
            local similarity = dot(nx, ny, nz, hnx, hny, hnz)
            local d2 = squared_distance(tx, ty, tz, hx, hy, hz)
            if similarity < CORNER_NORMAL_DOT and similarity > -0.65
                and d2 < best_d2
                and d2 <= probe * probe then
                best_d2 = d2
                bx, by, bz = hx, hy, hz
                bnx, bny, bnz = hnx, hny, hnz
            end
        end
    end

    consider(-nx, -ny, -nz)
    consider(-nx - 0.55 * dx, -ny - 0.55 * dy, -nz - 0.55 * dz)
    consider(-nx + 0.30 * sx, -ny + 0.30 * sy, -nz + 0.30 * sz)
    consider(-nx - 0.30 * sx, -ny - 0.30 * sy, -nz - 0.30 * sz)

    if bx then
        local ndx, ndy, ndz = transport_direction(dx, dy, dz, nx, ny, nz, bnx, bny, bnz)
        local move_d2 = squared_distance(px, py, pz, bx, by, bz)
        local max_move = step + probe * 0.55
        if move_d2 <= max_move * max_move then
            return bx, by, bz, bnx, bny, bnz, ndx, ndy, ndz
        end
    end

    return nil
end


local function dominant_normal_bucket(nx, ny, nz)
    local ax = math_abs(nx)
    local ay = math_abs(ny)
    local az = math_abs(nz)
    if ax >= ay and ax >= az then
        return nx >= 0 and 1 or 2
    elseif ay >= az then
        return ny >= 0 and 3 or 4
    end
    return nz >= 0 and 5 or 6
end

local function front_cell_size()
    return cfg_cell
end

local function surface_key(x, y, z, nx, ny, nz)
    local cell = front_cell_size()
    local qx = math_floor(x / cell + 0.5)
    local qy = math_floor(y / cell + 0.5)
    local qz = math_floor(z / cell + 0.5)
    local nb = dominant_normal_bucket(nx, ny, nz)
    return tostring(qx) .. ":" .. tostring(qy) .. ":" .. tostring(qz) .. ":" .. tostring(nb)
end

local function ensure_history_capacity()
    local required = math_ceil(((cfg_trails - 1) * cfg_trail_spacing) / cfg_step) + 8
    if required < 10 then required = 10 end

    if required == history_capacity then
        return
    end

    history_capacity = required
    clear_array(history)
    for slot = 1, history_capacity do
        history[slot] = { step = -1, nodes = nil }
    end
end

local function store_layer(step_index, nodes)
    ensure_history_capacity()
    local slot = history[(step_index % history_capacity) + 1]
    slot.step = step_index
    slot.nodes = nodes
end

local function get_layer(step_index)
    if history_capacity <= 0 or step_index < 0 then
        return nil
    end
    local slot = history[(step_index % history_capacity) + 1]
    if slot and slot.step == step_index then
        return slot.nodes
    end
    return nil
end

local function reset_next_layer()
    clear_map(next_by_key)
end

local function candidate_score(parent, dx, dy, dz, nx, ny, nz)
    if not parent.dx then
        return 0
    end
    return dot(parent.dx, parent.dy, parent.dz, dx, dy, dz)
        + 0.20 * dot(parent.nx, parent.ny, parent.nz, nx, ny, nz)
end

local function accept_candidate(parent, next_step, x, y, z, nx, ny, nz, dx, dy, dz)
    if next_step * cfg_step > cfg_radius + cfg_step * 0.75 then
        return
    end

    local key = surface_key(x, y, z, nx, ny, nz)
    local prior = visited[key]
    if prior and prior < next_step then
        return
    end

    local score = candidate_score(parent, dx, dy, dz, nx, ny, nz)
    local existing = next_by_key[key]
    if existing and existing.score >= score then
        return
    end

    next_by_key[key] = {
        x = x, y = y, z = z,
        nx = nx, ny = ny, nz = nz,
        dx = dx, dy = dy, dz = dz,
        score = score,
        key = key,
    }
end

local function emit_direction(parent, next_step, dx, dy, dz)
    local x, y, z, nx, ny, nz, ndx, ndy, ndz = surface_move(parent, dx, dy, dz)
    if x then
        accept_candidate(parent, next_step, x, y, z, nx, ny, nz, ndx, ndy, ndz)
    end
end

local function commit_next_layer()
    local committed = {}
    for key, node in pairs(next_by_key) do
        visited[key] = simulation_step + 1
        node.score = nil
        node.key = nil
        committed[#committed + 1] = node
    end

    simulation_step = simulation_step + 1
    frontier = committed
    expansion_index = 1
    reset_next_layer()
    store_layer(simulation_step, frontier)

    if #frontier == 0 then
        propagation_finished = true
    end
end

local function process_seed(budget)
    local used = 0
    local next_step = 1

    while seed_index <= seed_count and used < budget do
        local angle = 2 * math_pi * (seed_index - 1) / seed_count
        local ca = math_cos(angle)
        local sa = math_sin(angle)
        local dx = source_t1x * ca + source_t2x * sa
        local dy = source_t1y * ca + source_t2y * sa
        local dz = source_t1z * ca + source_t2z * sa

        local source = frontier[1]
        emit_direction(source, next_step, dx, dy, dz)
        seed_index = seed_index + 1
        used = used + 1
    end

    if seed_index > seed_count then
        commit_next_layer()
        phase = propagation_finished and "running" or "expanding"
    end

    return used
end

local function process_expansion(budget)
    local used = 0
    local next_step = simulation_step + 1

    while expansion_index <= #frontier and used + 3 <= budget do
        local node = frontier[expansion_index]
        expansion_index = expansion_index + 1

        local lx, ly, lz = rotate_tangent(node.dx, node.dy, node.dz, node.nx, node.ny, node.nz, -TURN_ANGLE)
        local rx, ry, rz = rotate_tangent(node.dx, node.dy, node.dz, node.nx, node.ny, node.nz, TURN_ANGLE)

        emit_direction(node, next_step, node.dx, node.dy, node.dz)
        emit_direction(node, next_step, lx, ly, lz)
        emit_direction(node, next_step, rx, ry, rz)
        used = used + 3
    end

    if expansion_index > #frontier then
        commit_next_layer()
    end

    return used
end

local function initialize_wave_from_source()
    clear_map(visited)
    reset_next_layer()
    clear_array(frontier)
    clear_array(history)
    history_capacity = 0

    local source = {
        x = source_x, y = source_y, z = source_z,
        nx = source_nx, ny = source_ny, nz = source_nz,
        dx = nil, dy = nil, dz = nil,
    }

    frontier[1] = source
    simulation_step = 0
    expansion_index = 1
    seed_count = cfg_front_points
    seed_index = 1
    propagation_finished = false
    visited[surface_key(source_x, source_y, source_z, source_nx, source_ny, source_nz)] = 0
    ensure_history_capacity()
    store_layer(0, frontier)

    wave_age = 0
    next_render = 0
    phase = "seeding"
end

local function propagate_toward(target_step)
    if propagation_finished then return end
    local budget = PROPAGATION_CANDIDATES_PER_FRAME
    if frame_budget then
        local cap = math_floor(frame_budget.limit() * PROPAGATION_BUDGET_FRACTION / PROPAGATION_WORK_COST)
        cap = math_max(1, math_min(PROPAGATION_CANDIDATES_PER_FRAME, cap))
        budget = frame_budget.claim_items(PROPAGATION_WORK_COST, cap)
    end
    while budget > 0 and simulation_step < target_step and not propagation_finished do
        if frame_budget and not frame_budget.time_available() then break end
        local used
        if phase == "seeding" then
            used = process_seed(budget)
        else
            used = process_expansion(budget)
        end
        if not used or used <= 0 then break end
        budget = budget - used
    end
end

local function palette_color(trail_index, trail_count)
    local t = trail_count > 1 and (trail_index / (trail_count - 1)) or 0
    local palette = setting("heat_color", "cyan")

    if palette == "amber" then
        return Color_new(math_floor(255 - 65 * t), math_floor(180 - 105 * t), math_floor(45 - 25 * t))
    elseif palette == "white" then
        local v = math_floor(255 - 135 * t)
        return Color_new(v, v, v)
    elseif palette == "toxin" then
        return Color_new(math_floor(105 - 45 * t), math_floor(255 - 105 * t), math_floor(125 - 55 * t))
    end

    return Color_new(math_floor(80 - 35 * t), math_floor(235 - 105 * t), math_floor(255 - 85 * t))
end

local function clipped_stroke_length(px, py, pz, nx, ny, nz, tx, ty, tz, requested)
    if requested <= 0 then return 0 end
    local ox = px + nx * cfg_lift * 1.7
    local oy = py + ny * cfg_lift * 1.7
    local oz = pz + nz * cfg_lift * 1.7
    local _, _, _, hit_distance = raycast(ox, oy, oz, tx, ty, tz, requested)
    if not hit_distance then return requested end
    return math_max(0, math_min(requested, hit_distance - 0.015))
end

local function ensure_stroke(node, half)
    if node.stroke_revision == stroke_revision then return node.stroke_valid end
    if not node.dx then
        node.stroke_revision = stroke_revision
        node.stroke_valid = false
        return false
    end
    if frame_budget and not frame_budget.take(STROKE_WORK_COST) then return nil end
    node.stroke_revision = stroke_revision
    node.stroke_valid = false
    local tx, ty, tz = cross(node.nx, node.ny, node.nz, node.dx, node.dy, node.dz)
    tx, ty, tz = normalize(tx, ty, tz)
    if not tx then return false end
    local left = clipped_stroke_length(node.x, node.y, node.z, node.nx, node.ny, node.nz, -tx, -ty, -tz, half)
    local right = clipped_stroke_length(node.x, node.y, node.z, node.nx, node.ny, node.nz, tx, ty, tz, half)
    if left + right <= 0.035 then return false end
    node.stroke_tx, node.stroke_ty, node.stroke_tz = tx, ty, tz
    node.stroke_left, node.stroke_right = left, right
    node.stroke_valid = true
    return true
end

local function prepare_front_layer(nodes, half)
    if not nodes or #nodes == 0 then return true, 0 end
    local lines = 0
    for i = 1, #nodes do
        local ready = ensure_stroke(nodes[i], half)
        if ready == nil then return false, 0 end
        if ready then lines = lines + 1 end
    end
    return true, lines
end

local function draw_front_layer(lo, nodes, color)
    if not nodes or #nodes == 0 then return 0 end
    local lift = math_max(cfg_lift, 0)
    local lines = 0
    for i = 1, #nodes do
        local node = nodes[i]
        if node.stroke_revision == stroke_revision and node.stroke_valid then
            local tx, ty, tz = node.stroke_tx, node.stroke_ty, node.stroke_tz
            local left, right = node.stroke_left, node.stroke_right
            local cx = node.x + node.nx * lift
            local cy = node.y + node.ny * lift
            local cz = node.z + node.nz * lift
            LineObject_add_line(
                lo, color,
                Vector3_new(cx - tx * left, cy - ty * left, cz - tz * left),
                Vector3_new(cx + tx * right, cy + ty * right, cz + tz * right)
            )
            lines = lines + 1
        end
    end
    return lines
end

local function draw_source_ring(lo, color)
    if not source_x then return end
    local radius = math_min(0.12, cfg_step * 0.42)
    local lift = math_max(cfg_lift, 0)
    local segments = 16
    local px, py, pz
    for i = 0, segments do
        local angle = 2 * math_pi * i / segments
        local ca, sa = math_cos(angle), math_sin(angle)
        local x = source_x + source_t1x * ca * radius + source_t2x * sa * radius + source_nx * lift
        local y = source_y + source_t1y * ca * radius + source_t2y * sa * radius + source_ny * lift
        local z = source_z + source_t1z * ca * radius + source_t2z * sa * radius + source_nz * lift
        if px then
            LineObject_add_line(lo, color, Vector3_new(px, py, pz), Vector3_new(x, y, z))
        end
        px, py, pz = x, y, z
    end
end

local function render_wave()
    local lo, world = get_context()
    if not lo or not world then return end
    local speed = math_max(0.1, setting("heat_speed", 7))
    local requested_head = math_min(cfg_radius, wave_age * speed)
    local computed_head = simulation_step * cfg_step
    local head = math_min(requested_head, computed_head)
    local half = math_max(0.045, front_cell_size() * 0.68)
    local items = {}
    local available_lines = frame_budget and frame_budget.draw_remaining() or math.huge
    local reserved_lines = 0
    for trail = 0, cfg_trails - 1 do
        local level = head - trail * cfg_trail_spacing
        if level >= 0 then
            local color = palette_color(trail, cfg_trails)
            local step_index = math_floor(level / cfg_step + 0.5)
            local nodes = step_index > 0 and get_layer(step_index) or nil
            local count
            if step_index <= 0 then
                count = 16
            else
                local ready
                ready, count = prepare_front_layer(nodes, half)
                if not ready then return end
            end
            if count > 0 then
                if reserved_lines + count > available_lines then
                    if #items == 0 then return end
                    break
                end
                items[#items + 1] = { nodes = nodes, color = color, source = step_index <= 0, count = count }
                reserved_lines = reserved_lines + count
            end
        end
    end
    if reserved_lines > 0 and frame_budget and not frame_budget.take_draw(reserved_lines) then return end
    LineObject_reset(lo)
    for i = 1, #items do
        local item = items[i]
        if item.source then draw_source_ring(lo, item.color) else draw_front_layer(lo, item.nodes, item.color) end
    end
    LineObject_dispatch(world, lo)
end

local function stop_wave(clear_visual)
    phase = "idle"
    wave_age = 0
    next_render = 0
    simulation_step = 0
    expansion_index = 1
    seed_index = 1
    seed_count = 0
    propagation_finished = false
    clear_array(frontier)
    clear_map(visited)
    reset_next_layer()
    clear_array(history)
    history_capacity = 0
    if clear_visual then clear_drawing() end
end

function api.trigger()
    local lo, world, pw = get_context()
    if not lo or not world or not pw then return end
    local px, py, pz = player_position()
    if not px then return end
    clear_drawing()
    refresh_config()
    local x, y, z, nx, ny, nz = find_source_surface(px, py, pz)
    if not x then
        phase = "idle"
        return
    end
    source_x, source_y, source_z = x, y, z
    source_nx, source_ny, source_nz = nx, ny, nz
    source_t1x, source_t1y, source_t1z, source_t2x, source_t2y, source_t2z = tangent_basis(nx, ny, nz)
    initialize_wave_from_source()
end

function api.update(dt)
    clock = clock + dt
    if phase == "idle" then return end
    local lo, world, pw = get_context()
    if not lo or not world or not pw then return end
    wave_age = wave_age + dt
    local speed = math_max(0.1, setting("heat_speed", 7))
    local target_step = math_ceil(cfg_radius / cfg_step)
    propagate_toward(target_step)
    if clock >= next_render then
        render_wave()
        next_render = clock + RENDER_INTERVAL
    end
    local available_end = propagation_finished and (simulation_step * cfg_step) or cfg_radius
    local tail = wave_age * speed - (cfg_trails - 1) * cfg_trail_spacing
    if tail > math_min(cfg_radius, available_end) and (propagation_finished or simulation_step * cfg_step >= cfg_radius) then
        if setting("heat_loop", false) then
            initialize_wave_from_source()
        else
            stop_wave(true)
        end
    end
end


function api.clear()
    stop_wave(true)
end

function api.reset_all(keep_drawing)
    stop_wave(not keep_drawing)
    physics_world = nil
end

function api.on_game_state_changed(status, state_name)
    if state_name == "StateGameplay" and status == "exit" then
        stop_wave(false)
        physics_world = nil
        destroy_line_object()
    end
end

return api
