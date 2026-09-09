local mod = get_mod("NoBrainer")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")
local math3d = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/StingrayMath")

local Factory = {}

local math_abs = math.abs
local math_cos = math.cos
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_pi = math.pi
local math_sin = math.sin
local math_sqrt = math.sqrt
local pairs = pairs
local tostring = tostring

local EPS = 1e-7
local SOURCE_PROBE_DISTANCE = 3.0
local SOURCE_FALLBACK_RAYS = 24
local TURN_ANGLE = math_pi * 0.17
local CORNER_NORMAL_DOT = 0.985
local SMOOTH_NORMAL_DOT = 0.10

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


local function clear_map(t)
    for k in pairs(t) do t[k] = nil end
end

-- very coarse normal bucket keeps opposite sides of thin geometry from sharing visited cells
local function normal_bucket_component(v)
    if v > 0.40 then return 2 end
    if v < -0.40 then return 0 end
    return 1
end

local function normal_bucket(nx, ny, nz)
    return normal_bucket_component(nx) * 9
        + normal_bucket_component(ny) * 3
        + normal_bucket_component(nz)
end

function Factory.new(frame_budget)
    local self = {}

    local physics_world = nil
    local physics_owner_world = nil
    local phase = "idle"

    local cfg = {
        step = 0.25,
        probe = 0.45,
        lift = 0.025,
        radius = 25,
        front_points = 128,
        cell = 0.25,
    }

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
    local on_layer = nil

    local function ensure_context()
        local world = runtime.current_world()
        if not world then
            physics_world = nil
            physics_owner_world = nil
            return nil, nil
        end
        if physics_owner_world ~= world then
            physics_owner_world = world
            physics_world = runtime.physics_world(world)
        elseif not physics_world then
            physics_world = runtime.physics_world(world)
        end
        return world, physics_world
    end

    local function raycast(px, py, pz, dx, dy, dz, distance)
        if not physics_world or distance <= 0 then return nil end
        local hx, hy, hz, hit_distance, nx, ny, nz = runtime.raycast_static(
            physics_world, px, py, pz, dx, dy, dz, distance
        )
        if not hx then return nil end
        return hx, hy, hz, hit_distance, nx, ny, nz
    end

    local player_position = runtime.player_position

    local function rotate_tangent(dx, dy, dz, nx, ny, nz, angle)
        if math_abs(angle) <= EPS then return dx, dy, dz end
        local sx, sy, sz = cross(nx, ny, nz, dx, dy, dz)
        sx, sy, sz = normalize(sx, sy, sz)
        if not sx then return dx, dy, dz end
        local ca = math_cos(angle)
        local sa = math_sin(angle)
        return normalize(dx * ca + sx * sa, dy * ca + sy * sa, dz * ca + sz * sa)
    end

    local function find_source_surface(px, py, pz)
        local hx, hy, hz, _, nx, ny, nz = raycast(px, py, pz + 0.8, 0, 0, -1, SOURCE_PROBE_DISTANCE)
        if hx then return hx, hy, hz, nx, ny, nz end

        local best_d2 = math.huge
        local bx, by, bz, bnx, bny, bnz
        -- fibonacci-ish fallback rays, just trying to find some nearby surface without directional bias
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
        local lift = cfg.lift
        local sx = px + nx * lift * 1.6
        local sy = py + ny * lift * 1.6
        local sz = pz + nz * lift * 1.6
        local ex = qx + qnx * lift * 1.6
        local ey = qy + qny * lift * 1.6
        local ez = qz + qnz * lift * 1.6
        local dx, dy, dz = ex - sx, ey - sy, ez - sz
        local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
        if distance <= 0.03 then return true end
        local _, _, _, hit_distance = raycast(sx, sy, sz, dx, dy, dz, distance)
        if not hit_distance then return true end
        local margin = math_max(0.035, distance * 0.12)
        return hit_distance >= distance - margin
    end

    local function project_smooth_target(tx, ty, tz, nx, ny, nz, probe, px, py, pz, dx, dy, dz)
        local ox = tx + nx * probe * 0.58
        local oy = ty + ny * probe * 0.58
        local oz = tz + nz * probe * 0.58
        local hx, hy, hz, _, hnx, hny, hnz = raycast(ox, oy, oz, -nx, -ny, -nz, probe * 1.18)
        if not hx or dot(nx, ny, nz, hnx, hny, hnz) < SMOOTH_NORMAL_DOT then return nil end
        local mvx, mvy, mvz = hx - px, hy - py, hz - pz
        if dot(mvx, mvy, mvz, dx, dy, dz) <= 0.02 then return nil end
        return hx, hy, hz, hnx, hny, hnz
    end

    local function project_corner_target(tx, ty, tz, nx, ny, nz, probe)
        local ox = tx + nx * probe * 0.55
        local oy = ty + ny * probe * 0.55
        local oz = tz + nz * probe * 0.55
        local hx, hy, hz, _, hnx, hny, hnz = raycast(ox, oy, oz, -nx, -ny, -nz, probe * 1.12)
        if hx then return hx, hy, hz, hnx, hny, hnz end
        return nil
    end

    local function surface_move(node, requested_dx, requested_dy, requested_dz)
        local step, probe, lift = cfg.step, cfg.probe, cfg.lift
        local px, py, pz = node.x, node.y, node.z
        local nx, ny, nz = node.nx, node.ny, node.nz
        local dx, dy, dz = clean_tangent(requested_dx, requested_dy, requested_dz, nx, ny, nz)
        if not dx then return nil end

        local fx, fy, fz, fd, fnx, fny, fnz = raycast(
            px + nx * lift * 1.7,
            py + ny * lift * 1.7,
            pz + nz * lift * 1.7,
            dx, dy, dz,
            step * 1.04
        )

        -- tangent ray hit early means probably a corner, try carrying direction onto the new normal
        if fx and fd < step * 0.96 then
            local normal_change = dot(nx, ny, nz, fnx, fny, fnz)
            if normal_change < CORNER_NORMAL_DOT then
                local ndx, ndy, ndz = transport_direction(dx, dy, dz, nx, ny, nz, fnx, fny, fnz)
                local remain = step - math_max(fd, 0)
                if remain < step * 0.18 then remain = step * 0.18 end
                local tx, ty, tz = fx + ndx * remain, fy + ndy * remain, fz + ndz * remain
                local qx, qy, qz, qnx, qny, qnz = project_corner_target(tx, ty, tz, fnx, fny, fnz, probe)
                if qx and path_is_clear(fx, fy, fz, fnx, fny, fnz, qx, qy, qz, qnx, qny, qnz) then
                    local max_move = step + probe * 0.55
                    if squared_distance(px, py, pz, qx, qy, qz) <= max_move * max_move then
                        local fdx, fdy, fdz = transport_direction(ndx, ndy, ndz, fnx, fny, fnz, qnx, qny, qnz)
                        return qx, qy, qz, qnx, qny, qnz, fdx, fdy, fdz
                    end
                end
            end
            return nil
        end

        local tx, ty, tz = px + dx * step, py + dy * step, pz + dz * step
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
        if not sx then return nil end

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
                    and d2 < best_d2 and d2 <= probe * probe then
                    best_d2 = d2
                    bx, by, bz = hx, hy, hz
                    bnx, bny, bnz = hnx, hny, hnz
                end
            end
        end

        -- ugly fallback fan for concave bits where the straight normal projection misses
        consider(-nx, -ny, -nz)
        consider(-nx - 0.35 * dx, -ny - 0.35 * dy, -nz - 0.35 * dz)
        consider(-nx - 0.75 * dx, -ny - 0.75 * dy, -nz - 0.75 * dz)
        consider(-nx + 0.30 * sx, -ny + 0.30 * sy, -nz + 0.30 * sz)
        consider(-nx - 0.30 * sx, -ny - 0.30 * sy, -nz - 0.30 * sz)
        consider(-nx - 0.45 * dx + 0.28 * sx, -ny - 0.45 * dy + 0.28 * sy, -nz - 0.45 * dz + 0.28 * sz)
        consider(-nx - 0.45 * dx - 0.28 * sx, -ny - 0.45 * dy - 0.28 * sy, -nz - 0.45 * dz - 0.28 * sz)

        if bx then
            local ndx, ndy, ndz = transport_direction(dx, dy, dz, nx, ny, nz, bnx, bny, bnz)
            local max_move = step + probe * 0.55
            if squared_distance(px, py, pz, bx, by, bz) <= max_move * max_move then
                return bx, by, bz, bnx, bny, bnz, ndx, ndy, ndz
            end
        end
        return nil
    end

    local function surface_key(x, y, z, nx, ny, nz)
        local cell = cfg.cell
        local qx = math_floor(x / cell + 0.5)
        local qy = math_floor(y / cell + 0.5)
        local qz = math_floor(z / cell + 0.5)
        return tostring(qx) .. ":" .. tostring(qy) .. ":" .. tostring(qz) .. ":" .. tostring(normal_bucket(nx, ny, nz))
    end


    local function store_layer(step_index, nodes)
        if on_layer then on_layer(step_index, nodes) end
    end

    local function reset_next_layer()
        clear_map(next_by_key)
    end

    -- when two paths quantize to same surface cell keep the one that bends less
    local function candidate_score(parent, dx, dy, dz, nx, ny, nz)
        if not parent.dx then return 0 end
        return dot(parent.dx, parent.dy, parent.dz, dx, dy, dz)
            + 0.20 * dot(parent.nx, parent.ny, parent.nz, nx, ny, nz)
    end

    local function accept_candidate(parent, next_step, x, y, z, nx, ny, nz, dx, dy, dz)
        if next_step * cfg.step > cfg.radius + cfg.step * 0.75 then return end
        local key = surface_key(x, y, z, nx, ny, nz)
        local prior = visited[key]
        if prior and prior < next_step then return end
        local score = candidate_score(parent, dx, dy, dz, nx, ny, nz)
        local existing = next_by_key[key]
        if existing and existing.score >= score then return end
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
        if x then accept_candidate(parent, next_step, x, y, z, nx, ny, nz, ndx, ndy, ndz) end
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
        if #frontier == 0 then propagation_finished = true end
    end

    local function process_seed(budget)
        local used = 0
        local next_step = 1
        while seed_index <= seed_count and used < budget and frame_budget.time_available() do
            local angle = 2 * math_pi * (seed_index - 1) / seed_count
            local ca, sa = math_cos(angle), math_sin(angle)
            local dx = source_t1x * ca + source_t2x * sa
            local dy = source_t1y * ca + source_t2y * sa
            local dz = source_t1z * ca + source_t2z * sa
            emit_direction(frontier[1], next_step, dx, dy, dz)
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
        while expansion_index <= #frontier and used + 3 <= budget and frame_budget.time_available() do
            local node = frontier[expansion_index]
            expansion_index = expansion_index + 1
            local lx, ly, lz = rotate_tangent(node.dx, node.dy, node.dz, node.nx, node.ny, node.nz, -TURN_ANGLE)
            local rx, ry, rz = rotate_tangent(node.dx, node.dy, node.dz, node.nx, node.ny, node.nz, TURN_ANGLE)
            -- forward plus two shallow turns lets the front spread without exploding branch count
            emit_direction(node, next_step, node.dx, node.dy, node.dz)
            emit_direction(node, next_step, lx, ly, lz)
            emit_direction(node, next_step, rx, ry, rz)
            used = used + 3
        end
        if expansion_index > #frontier then commit_next_layer() end
        return used
    end

    local function initialize_wave()
        clear_map(visited)
        reset_next_layer()

        frontier = {}

        local source = {
            x = source_x, y = source_y, z = source_z,
            nx = source_nx, ny = source_ny, nz = source_nz,
            dx = nil, dy = nil, dz = nil,
        }
        frontier[1] = source
        simulation_step = 0
        expansion_index = 1
        seed_count = cfg.front_points
        seed_index = 1
        propagation_finished = false
        visited[surface_key(source_x, source_y, source_z, source_nx, source_ny, source_nz)] = 0
        store_layer(0, frontier)
        phase = "seeding"
    end

    function self:start(config, layer_callback)
        local _, pw = ensure_context()
        if not pw then return false end
        local px, py, pz = player_position()
        if not px then return false end

        cfg.step = config.step
        cfg.probe = config.probe
        cfg.lift = config.lift
        cfg.radius = config.radius
        cfg.front_points = config.front_points
        cfg.cell = config.cell
        on_layer = layer_callback

        local x, y, z, nx, ny, nz = find_source_surface(px, py, pz)
        if not x then
            phase = "idle"
            return false
        end
        source_x, source_y, source_z = x, y, z
        source_nx, source_ny, source_nz = nx, ny, nz
        source_t1x, source_t1y, source_t1z, source_t2x, source_t2y, source_t2z = tangent_basis(nx, ny, nz)
        initialize_wave()
        return true
    end


    function self:propagate_toward(target_step, max_fraction)
        if propagation_finished or phase == "idle" then return end
        local fraction = math_max(0.05, math_min(1, max_fraction or 1))
        local cap = math_max(1, math_floor(frame_budget.limit() * fraction / 8))
        local budget = frame_budget.claim_items(8, cap)
        while budget > 0 and simulation_step < target_step and not propagation_finished do
            local used
            if phase == "seeding" then used = process_seed(budget) else used = process_expansion(budget) end
            if not used or used <= 0 then break end
            budget = budget - used
        end
    end




    function self:path_is_clear(...)
        ensure_context()
        return path_is_clear(...)
    end

    function self:simulation_step() return simulation_step end
    function self:is_finished() return propagation_finished end

    function self:stop()
        phase = "idle"
        simulation_step = 0
        expansion_index = 1
        seed_index = 1
        seed_count = 0
        propagation_finished = false
        frontier = {}
        clear_map(visited)
        reset_next_layer()
        on_layer = nil
    end

    function self:world_changed()
        local world = runtime.current_world()
        return physics_owner_world ~= nil and physics_owner_world ~= world
    end

    function self:reset_world()
        self:stop()
        physics_world = nil
        physics_owner_world = nil
        source_x, source_y, source_z = nil, nil, nil
    end

    return self
end

return Factory
