local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local line_owner_factory = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/LineObjectOwner")
local nav_cache_factory = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/NavMeshCache")

local api = {}

local math_abs = math.abs
local math_ceil = math.ceil
local math_floor = math.floor
local math_huge = math.huge
local math_max = math.max
local math_min = math.min
local math_sqrt = math.sqrt
local tonumber = tonumber
local tostring = tostring
local pairs = pairs
local LineObject_add_line = LineObject.add_line
local LineObject_dispatch = LineObject.dispatch
local LineObject_reset = LineObject.reset
local Vector3_to_elements = Vector3.to_elements

local EPS = 1e-9
local VERTEX_QUANTIZE = 1000
local EDGE_KEY_BASE = 1048576

local CG_MAX_ITERATIONS = 140
local CG_RELATIVE_TOLERANCE = 1e-6
local RENDER_INTERVAL = 1 / 30

local line_owner = line_owner_factory.new()
local clock = 0

local nav_cache = nav_cache_factory.new()
local nav = nav_cache:data()

local wave_phase = "idle"
local pending_pulse = false
local source_x, source_y, source_z = nil, nil, nil

local candidate_triangles = {}
local candidate_index = 1

local vx, vy, vz = {}, {}, {}
local vertex_key_to_index = {}
local faces = {}
local conn_adj = {}
local conn_edge_seen = {}
local nearest_vertex = nil
local nearest_vertex_d2 = math_huge
local source_face_a, source_face_b, source_face_c = nil, nil, nil
local source_weight_a, source_weight_b, source_weight_c = 1, 0, 0
local source_face_d2 = math_huge

local active = {}
local active_vertices = {}
local active_faces = {}
local active_count = 0
local component_queue = {}
local component_head = 1
local component_tail = 0

local mass = {}
local lap_diag = {}
local weighted_adj = {}
local edge_index_by_key = {}
local edge_a, edge_b, edge_w = {}, {}, {}
local edge_count = 0
local operator_face_index = 1
local mean_edge_sum = 0
local mean_edge_count = 0
local heat_time = 1

local heat_u = {}
local divergence = {}
local phi = {}
local distance = {}
local distance_max = 0
local gradient_face_index = 1

local cg = nil

local wave_age = 0
local wave_next_render = 0

local setting = settings.get

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

local function get_line_object()
    return line_owner:get()
end

local function clear_drawing()
    line_owner:clear()
end
local function current_nav_world()
    local state = Managers.state
    local nav_mesh = state and state.nav_mesh
    return nav_mesh and nav_mesh._nav_world or nil
end

local function player_position()
    local player_manager = Managers.player
    local local_player = player_manager and player_manager:local_player(1)
    local unit = local_player and local_player.player_unit

    if unit and Unit.alive(unit) then
        local position = Unit.world_position(unit, 1)
        return Vector3_to_elements(position)
    end

    return nil
end

local function quantize(v)
    local scaled = v * VERTEX_QUANTIZE
    if scaled >= 0 then
        return math_floor(scaled + 0.5)
    end
    return math_ceil(scaled - 0.5)
end

local function quantized_vertex_key(x, y, z)
    return tostring(quantize(x)) .. ":" .. tostring(quantize(y)) .. ":" .. tostring(quantize(z))
end

local function pair_key(a, b)
    if a > b then a, b = b, a end
    return a * EDGE_KEY_BASE + b
end

local function squared_distance(ax, ay, az, bx, by, bz)
    local dx = ax - bx
    local dy = ay - by
    local dz = az - bz
    return dx * dx + dy * dy + dz * dz
end

local function vector_length(x, y, z)
    return math_sqrt(x * x + y * y + z * z)
end

local function reset_local_solve(keep_drawing)
    wave_phase = "idle"
    pending_pulse = false
    source_x, source_y, source_z = nil, nil, nil
    clear_array(candidate_triangles)
    candidate_index = 1

    clear_array(vx); clear_array(vy); clear_array(vz)
    clear_map(vertex_key_to_index)
    clear_array(faces)
    clear_array(conn_adj)
    clear_map(conn_edge_seen)
    nearest_vertex = nil
    nearest_vertex_d2 = math_huge
    source_face_a, source_face_b, source_face_c = nil, nil, nil
    source_weight_a, source_weight_b, source_weight_c = 1, 0, 0
    source_face_d2 = math_huge

    clear_map(active)
    clear_array(active_vertices)
    clear_array(active_faces)
    active_count = 0
    clear_array(component_queue)
    component_head = 1
    component_tail = 0

    clear_array(mass)
    clear_array(lap_diag)
    clear_array(weighted_adj)
    clear_map(edge_index_by_key)
    clear_array(edge_a); clear_array(edge_b); clear_array(edge_w)
    edge_count = 0
    operator_face_index = 1
    mean_edge_sum = 0
    mean_edge_count = 0
    heat_time = 1

    clear_array(heat_u)
    clear_array(divergence)
    clear_array(phi)
    clear_map(distance)
    distance_max = 0
    gradient_face_index = 1
    cg = nil
    api._pending_heat_rhs = nil

    wave_age = 0
    wave_next_render = 0

    if not keep_drawing then
        clear_drawing()
    end
end

local function add_patch_vertex(x, y, z)
    local key = quantized_vertex_key(x, y, z)
    local existing = vertex_key_to_index[key]
    if existing then return existing end

    local i = #vx + 1
    vx[i], vy[i], vz[i] = x, y, z
    vertex_key_to_index[key] = i
    conn_adj[i] = {}

    local d2 = squared_distance(x, y, z, source_x, source_y, source_z)
    if d2 < nearest_vertex_d2 then
        nearest_vertex_d2 = d2
        nearest_vertex = i
    end

    return i
end

local function closest_point_barycentric(px, py, pz, a, b, c)
    local ax, ay, az = vx[a], vy[a], vz[a]
    local bx, by, bz = vx[b], vy[b], vz[b]
    local cx, cy, cz = vx[c], vy[c], vz[c]
    local abx, aby, abz = bx - ax, by - ay, bz - az
    local acx, acy, acz = cx - ax, cy - ay, cz - az
    local apx, apy, apz = px - ax, py - ay, pz - az
    local d1 = abx * apx + aby * apy + abz * apz
    local d2 = acx * apx + acy * apy + acz * apz
    if d1 <= 0 and d2 <= 0 then return ax, ay, az, 1, 0, 0 end

    local bpx, bpy, bpz = px - bx, py - by, pz - bz
    local d3 = abx * bpx + aby * bpy + abz * bpz
    local d4 = acx * bpx + acy * bpy + acz * bpz
    if d3 >= 0 and d4 <= d3 then return bx, by, bz, 0, 1, 0 end

    local vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0 then
        local v = d1 / (d1 - d3)
        return ax + v * abx, ay + v * aby, az + v * abz, 1 - v, v, 0
    end

    local cpx, cpy, cpz = px - cx, py - cy, pz - cz
    local d5 = abx * cpx + aby * cpy + abz * cpz
    local d6 = acx * cpx + acy * cpy + acz * cpz
    if d6 >= 0 and d5 <= d6 then return cx, cy, cz, 0, 0, 1 end

    local vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0 then
        local w = d2 / (d2 - d6)
        return ax + w * acx, ay + w * acy, az + w * acz, 1 - w, 0, w
    end

    local va = d3 * d6 - d5 * d4
    if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
        local bcx, bcy, bcz = cx - bx, cy - by, cz - bz
        local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return bx + w * bcx, by + w * bcy, bz + w * bcz, 0, 1 - w, w
    end

    local denom = 1 / (va + vb + vc)
    local v = vb * denom
    local w = vc * denom
    local u = 1 - v - w
    return u * ax + v * bx + w * cx, u * ay + v * by + w * cy, u * az + v * bz + w * cz, u, v, w
end

local function consider_source_face(a, b, c)
    local qx, qy, qz, wa, wb, wc = closest_point_barycentric(source_x, source_y, source_z, a, b, c)
    local d2 = squared_distance(qx, qy, qz, source_x, source_y, source_z)
    if d2 < source_face_d2 then
        source_face_d2 = d2
        source_face_a, source_face_b, source_face_c = a, b, c
        source_weight_a, source_weight_b, source_weight_c = wa, wb, wc
    end
end

local function add_conn(a, b)
    local key = pair_key(a, b)
    if conn_edge_seen[key] then return end
    conn_edge_seen[key] = true

    local aa = conn_adj[a]
    aa[#aa + 1] = b
    local bb = conn_adj[b]
    bb[#bb + 1] = a
end

local function collect_candidates()
    candidate_index = 1
    nav_cache:collect_candidates(source_x, source_y, source_z, setting("nav_radius"), candidate_triangles)
end

local function begin_patch()
    clear_array(vx); clear_array(vy); clear_array(vz)
    clear_map(vertex_key_to_index)
    clear_array(faces)
    clear_array(conn_adj)
    clear_map(conn_edge_seen)
    nearest_vertex = nil
    nearest_vertex_d2 = math_huge
    source_face_a, source_face_b, source_face_c = nil, nil, nil
    source_weight_a, source_weight_b, source_weight_c = 1, 0, 0
    source_face_d2 = math_huge

    collect_candidates()
    candidate_index = 1

    if #candidate_triangles == 0 then
        wave_phase = "idle"
        clear_drawing()
        return
    end

    wave_phase = "build_patch"
end

local function patch_build_step(budget)
    local remaining = budget
    local radius = setting("nav_radius")
    local radius_with_margin = radius + 2
    local radius2 = radius_with_margin * radius_with_margin

    while candidate_index <= #candidate_triangles and remaining > 0 and frame_budget.time_available() do
        local tri = candidate_triangles[candidate_index]
        candidate_index = candidate_index + 1
        remaining = remaining - 1

        local dx = nav.mx[tri] - source_x
        local dy = nav.my[tri] - source_y
        if dx * dx + dy * dy <= radius2 then
            local a = add_patch_vertex(nav.ax[tri], nav.ay[tri], nav.az[tri])
            local b = add_patch_vertex(nav.bx[tri], nav.by[tri], nav.bz[tri])
            local c = add_patch_vertex(nav.cx[tri], nav.cy[tri], nav.cz[tri])

            if a ~= b and b ~= c and c ~= a then
                faces[#faces + 1] = { a, b, c }
                consider_source_face(a, b, c)
                add_conn(a, b)
                add_conn(b, c)
                add_conn(c, a)
            end
        end
    end

    if candidate_index > #candidate_triangles then
        if not nearest_vertex or #faces == 0 then
            wave_phase = "idle"
            clear_drawing()
            return
        end

        if source_face_a then
            nearest_vertex = source_face_a
            local best_weight = source_weight_a
            if source_weight_b > best_weight then
                nearest_vertex = source_face_b
                best_weight = source_weight_b
            end
            if source_weight_c > best_weight then
                nearest_vertex = source_face_c
            end
        end

        clear_map(active)
        clear_array(active_vertices)
        clear_array(component_queue)
        component_head = 1
        component_tail = 1
        component_queue[1] = nearest_vertex
        active[nearest_vertex] = true
        wave_phase = "component"
    end
end

local function component_step(budget)
    local remaining = budget

    while component_head <= component_tail and remaining > 0 and frame_budget.time_available() do
        local v = component_queue[component_head]
        component_head = component_head + 1
        remaining = remaining - 1

        active_vertices[#active_vertices + 1] = v
        local adj = conn_adj[v]
        for j = 1, #adj do
            local n = adj[j]
            if not active[n] then
                active[n] = true
                component_tail = component_tail + 1
                component_queue[component_tail] = n
            end
        end
    end

    if component_head > component_tail then
        active_count = #active_vertices
        if active_count < 3 then
            wave_phase = "idle"
            clear_drawing()
            return
        end

        clear_array(active_faces)
        for i = 1, #faces do
            local face = faces[i]
            if active[face[1]] and active[face[2]] and active[face[3]] then
                active_faces[#active_faces + 1] = face
            end
        end
        if #active_faces == 0 then
            wave_phase = "idle"
            clear_drawing()
            return
        end

        clear_array(mass)
        clear_array(lap_diag)
        clear_array(weighted_adj)
        clear_map(edge_index_by_key)
        clear_array(edge_a); clear_array(edge_b); clear_array(edge_w)
        edge_count = 0
        operator_face_index = 1
        mean_edge_sum = 0
        mean_edge_count = 0

        for i = 1, #vx do
            mass[i] = 0
            lap_diag[i] = 0
            weighted_adj[i] = {}
        end

        wave_phase = "operator"
    end
end

local function add_weighted_edge(a, b, weight)
    if math_abs(weight) < EPS then return end
    local key = pair_key(a, b)
    local index = edge_index_by_key[key]
    if index then
        edge_w[index] = edge_w[index] + weight
    else
        edge_count = edge_count + 1
        index = edge_count
        edge_index_by_key[key] = index
        edge_a[index] = a
        edge_b[index] = b
        edge_w[index] = weight

        mean_edge_sum = mean_edge_sum + math_sqrt(squared_distance(vx[a], vy[a], vz[a], vx[b], vy[b], vz[b]))
        mean_edge_count = mean_edge_count + 1
    end
end

local function operator_face(face)
    local a, b, c = face[1], face[2], face[3]
    if not (active[a] and active[b] and active[c]) then return end

    local ax, ay, az = vx[a], vy[a], vz[a]
    local bx, by, bz = vx[b], vy[b], vz[b]
    local cx, cy, cz = vx[c], vy[c], vz[c]

    local abx, aby, abz = bx - ax, by - ay, bz - az
    local acx, acy, acz = cx - ax, cy - ay, cz - az
    local nx = aby * acz - abz * acy
    local ny = abz * acx - abx * acz
    local nz = abx * acy - aby * acx
    local area2 = vector_length(nx, ny, nz)
    if area2 < EPS then return end

    -- lumped mass here, dont need anything fancier for the visual solve
    local area = area2 * 0.5
    local third = area / 3
    mass[a] = mass[a] + third
    mass[b] = mass[b] + third
    mass[c] = mass[c] + third

    local bax, bay, baz = ax - bx, ay - by, az - bz
    local bcx, bcy, bcz = cx - bx, cy - by, cz - bz
    local cax, cay, caz = ax - cx, ay - cy, az - cz
    local cbx, cby, cbz = bx - cx, by - cy, bz - cz

    -- cotan weights for the laplacian, area2 is already twice area so this stays cheap
    local cot_a = (abx * acx + aby * acy + abz * acz) / area2
    local cot_b = (bax * bcx + bay * bcy + baz * bcz) / area2
    local cot_c = (cax * cbx + cay * cby + caz * cbz) / area2

    add_weighted_edge(b, c, 0.5 * cot_a)
    add_weighted_edge(a, c, 0.5 * cot_b)
    add_weighted_edge(a, b, 0.5 * cot_c)
end

local function finalize_operator()
    for i = 1, edge_count do
        local a, b, w = edge_a[i], edge_b[i], edge_w[i]
        if active[a] and active[b] and math_abs(w) > EPS then
            local aa = weighted_adj[a]
            aa[#aa + 1] = b
            aa[#aa + 1] = w
            local bb = weighted_adj[b]
            bb[#bb + 1] = a
            bb[#bb + 1] = w
            lap_diag[a] = lap_diag[a] + w
            lap_diag[b] = lap_diag[b] + w
        end
    end

    local mean_edge = mean_edge_count > 0 and (mean_edge_sum / mean_edge_count) or 1
    -- heat method wants t around h squared, mean edge is close enough for these sampled patches
    heat_time = mean_edge * mean_edge

    clear_array(heat_u)
    for i = 1, #vx do heat_u[i] = 0 end

    local rhs = {}
    for i = 1, #vx do rhs[i] = 0 end
    if source_face_a and active[source_face_a] and active[source_face_b] and active[source_face_c] then
        rhs[source_face_a] = mass[source_face_a] * math_max(source_weight_a, 0)
        rhs[source_face_b] = mass[source_face_b] * math_max(source_weight_b, 0)
        rhs[source_face_c] = mass[source_face_c] * math_max(source_weight_c, 0)
    else
        rhs[nearest_vertex] = math_max(mass[nearest_vertex], 1e-5)
    end

    wave_phase = "heat"
    cg = nil

    -- little ugly but this survives the phase switch without making another state table
    api._pending_heat_rhs = rhs
end

local function operator_step(budget)
    local remaining = budget
    while operator_face_index <= #active_faces and remaining > 0 and frame_budget.time_available() do
        operator_face(active_faces[operator_face_index])
        operator_face_index = operator_face_index + 1
        remaining = remaining - 1
    end

    if operator_face_index > #active_faces then
        finalize_operator()
    end
end

local function matrix_heat(x, out)
    for k = 1, active_count do
        local i = active_vertices[k]
        local adjacency = weighted_adj[i]
        local neighbor_sum = 0
        for j = 1, #adjacency, 2 do
            neighbor_sum = neighbor_sum + adjacency[j + 1] * x[adjacency[j]]
        end
        local lx = lap_diag[i] * x[i] - neighbor_sum
        out[i] = mass[i] * x[i] + heat_time * lx
    end
end

local function matrix_poisson(x, out)
    for k = 1, active_count do
        local i = active_vertices[k]
        -- pin one vertex or poisson keeps the constant nullspace and cg gets confused
        if i == nearest_vertex then
            out[i] = x[i]
        else
            local adjacency = weighted_adj[i]
            local neighbor_sum = 0
            for j = 1, #adjacency, 2 do
                local neighbor = adjacency[j]

                if neighbor ~= nearest_vertex then
                    neighbor_sum = neighbor_sum + adjacency[j + 1] * x[neighbor]
                end
            end
            out[i] = lap_diag[i] * x[i] - neighbor_sum
        end
    end
end

-- diagonal preconditioner is boring but enough to keep cg from crawling on bad triangles
local function preconditioner_diagonal(kind, i)
    if kind == "heat" then
        local d = mass[i] + heat_time * lap_diag[i]
        if d > EPS then return d end
        return 1
    end
    if i == nearest_vertex then return 1 end
    local d = lap_diag[i]
    if math_abs(d) > EPS then return math_abs(d) end
    return 1
end

local function initialize_cg(kind, rhs, x)
    local state = {
        kind = kind,
        rhs = rhs,
        x = x,
        r = {},
        z = {},
        p = {},
        ap = {},
        rz = 0,
        rhs_norm2 = 0,
        iterations = 0,
        finished = false,
    }

    local ax = {}
    if kind == "heat" then matrix_heat(x, ax) else matrix_poisson(x, ax) end

    local rz = 0
    local rhs_norm2 = 0
    for k = 1, active_count do
        local i = active_vertices[k]
        local r = rhs[i] - (ax[i] or 0)
        state.r[i] = r
        local z = r / preconditioner_diagonal(kind, i)
        state.z[i] = z
        state.p[i] = z
        state.ap[i] = 0
        rz = rz + r * z
        rhs_norm2 = rhs_norm2 + rhs[i] * rhs[i]
    end

    state.rz = rz
    state.rhs_norm2 = math_max(rhs_norm2, 1)
    if math_abs(rz) < EPS then state.finished = true end
    return state
end

local function cg_step(state, budget)
    if state.finished then return true end

    local tolerance2 = CG_RELATIVE_TOLERANCE * CG_RELATIVE_TOLERANCE * state.rhs_norm2

    for _ = 1, budget do
        if not frame_budget.time_available() then break end
        if state.kind == "heat" then matrix_heat(state.p, state.ap) else matrix_poisson(state.p, state.ap) end

        local p_ap = 0
        for k = 1, active_count do
            local i = active_vertices[k]
            p_ap = p_ap + state.p[i] * state.ap[i]
        end

        if math_abs(p_ap) < EPS then
            state.finished = true
            break
        end

        local alpha = state.rz / p_ap
        local residual2 = 0
        for k = 1, active_count do
            local i = active_vertices[k]
            state.x[i] = state.x[i] + alpha * state.p[i]
            state.r[i] = state.r[i] - alpha * state.ap[i]
            residual2 = residual2 + state.r[i] * state.r[i]
        end

        state.iterations = state.iterations + 1
        if residual2 <= tolerance2 or state.iterations >= CG_MAX_ITERATIONS then
            state.finished = true
            break
        end

        local new_rz = 0
        for k = 1, active_count do
            local i = active_vertices[k]
            local z = state.r[i] / preconditioner_diagonal(state.kind, i)
            state.z[i] = z
            new_rz = new_rz + state.r[i] * z
        end

        if math_abs(state.rz) < EPS then
            state.finished = true
            break
        end

        local beta = new_rz / state.rz
        for k = 1, active_count do
            local i = active_vertices[k]
            state.p[i] = state.z[i] + beta * state.p[i]
        end
        state.rz = new_rz
    end

    return state.finished
end

local function begin_gradient()
    clear_array(divergence)
    for i = 1, #vx do divergence[i] = 0 end
    gradient_face_index = 1
    wave_phase = "gradient"
end

local function gradient_face(face)
    local a, b, c = face[1], face[2], face[3]
    if not (active[a] and active[b] and active[c]) then return end

    local ax, ay, az = vx[a], vy[a], vz[a]
    local bx, by, bz = vx[b], vy[b], vz[b]
    local cx, cy, cz = vx[c], vy[c], vz[c]

    local abx, aby, abz = bx - ax, by - ay, bz - az
    local acx, acy, acz = cx - ax, cy - ay, cz - az
    local nx = aby * acz - abz * acy
    local ny = abz * acx - abx * acz
    local nz = abx * acy - aby * acx
    local n2 = nx * nx + ny * ny + nz * nz
    if n2 < EPS then return end

    local area = 0.5 * math_sqrt(n2)

    local cbx, cby, cbz = cx - bx, cy - by, cz - bz
    local ac_neg_x, ac_neg_y, ac_neg_z = ax - cx, ay - cy, az - cz

    local gax = (ny * cbz - nz * cby) / n2
    local gay = (nz * cbx - nx * cbz) / n2
    local gaz = (nx * cby - ny * cbx) / n2

    local gbx = (ny * ac_neg_z - nz * ac_neg_y) / n2
    local gby = (nz * ac_neg_x - nx * ac_neg_z) / n2
    local gbz = (nx * ac_neg_y - ny * ac_neg_x) / n2

    local gcx = (ny * abz - nz * aby) / n2
    local gcy = (nz * abx - nx * abz) / n2
    local gcz = (nx * aby - ny * abx) / n2

    local gux = heat_u[a] * gax + heat_u[b] * gbx + heat_u[c] * gcx
    local guy = heat_u[a] * gay + heat_u[b] * gby + heat_u[c] * gcy
    local guz = heat_u[a] * gaz + heat_u[b] * gbz + heat_u[c] * gcz
    local glen = vector_length(gux, guy, guz)
    if glen < EPS then return end

    -- only direction matters after heat diffusion, magnitude would just distort the distance solve
    local xx, xy, xz = -gux / glen, -guy / glen, -guz / glen

    divergence[a] = divergence[a] - area * (gax * xx + gay * xy + gaz * xz)
    divergence[b] = divergence[b] - area * (gbx * xx + gby * xy + gbz * xz)
    divergence[c] = divergence[c] - area * (gcx * xx + gcy * xy + gcz * xz)
end

local function gradient_step(budget)
    local remaining = budget
    while gradient_face_index <= #active_faces and remaining > 0 and frame_budget.time_available() do
        gradient_face(active_faces[gradient_face_index])
        gradient_face_index = gradient_face_index + 1
        remaining = remaining - 1
    end

    if gradient_face_index > #active_faces then
        clear_array(phi)
        for i = 1, #vx do phi[i] = 0 end
        divergence[nearest_vertex] = 0
        cg = initialize_cg("poisson", divergence, phi)
        wave_phase = "poisson"
    end
end

local function finalize_distance()
    clear_map(distance)

    local source_value = phi[nearest_vertex] or 0
    if source_face_a and active[source_face_a] and active[source_face_b] and active[source_face_c] then
        source_value = source_weight_a * (phi[source_face_a] or 0)
            + source_weight_b * (phi[source_face_b] or 0)
            + source_weight_c * (phi[source_face_c] or 0)
    end

    local correlation = 0
    for k = 1, active_count do
        local i = active_vertices[k]
        local direct = math_sqrt(squared_distance(vx[i], vy[i], vz[i], source_x, source_y, source_z))
        correlation = correlation + ((phi[i] or 0) - source_value) * direct
    end
    local sign = correlation < 0 and -1 or 1

    local maximum = 0
    for k = 1, active_count do
        local i = active_vertices[k]
        local d = sign * ((phi[i] or 0) - source_value)
        if d < 0 and d > -1e-4 then d = 0 end
        if d < 0 then d = 0 end
        distance[i] = d
        if d > maximum then maximum = d end
    end

    distance_max = math_min(maximum, setting("nav_radius"))
    wave_age = 0
    wave_next_render = 0
    if distance_max <= EPS then
        reset_local_solve(true)
    else
        wave_phase = "ready"
    end
end

local function palette_color(trail_index, trail_count)
    local t = trail_count > 1 and (trail_index / (trail_count - 1)) or 0
    local palette = setting("nav_color")

    if palette == "amber" then
        return Color(math_floor(255 - 80 * t), math_floor(175 - 115 * t), math_floor(35 - 20 * t))
    elseif palette == "white" then
        local v = math_floor(255 - 150 * t)
        return Color(v, v, v)
    elseif palette == "toxin" then
        return Color(math_floor(100 - 55 * t), math_floor(255 - 115 * t), math_floor(120 - 75 * t))
    end

    return Color(math_floor(70 - 40 * t), math_floor(225 - 120 * t), math_floor(255 - 95 * t))
end

local function contour_intersection(level, a, b, lift)
    local da = distance[a]
    local db = distance[b]
    if da == nil or db == nil then return nil end

    if not ((da <= level and level < db) or (db <= level and level < da)) then
        return nil
    end

    local denom = db - da
    if math_abs(denom) < EPS then return nil end
    local t = (level - da) / denom

    return vx[a] + (vx[b] - vx[a]) * t,
        vy[a] + (vy[b] - vy[a]) * t,
        vz[a] + (vz[b] - vz[a]) * t + lift
end

local function draw_contour_level(lo, level, color, lift)
    if level < 0 or level > distance_max then return 0 end
    local count = 0

    for i = 1, #active_faces do
        local face = active_faces[i]
        local a, b, c = face[1], face[2], face[3]
        if active[a] and active[b] and active[c] then
            local da, db, dc = distance[a], distance[b], distance[c]
            if da and db and dc then
                local minimum = math_min(da, math_min(db, dc))
                local maximum = math_max(da, math_max(db, dc))
                if minimum <= level and level <= maximum then
                    local x1, y1, z1 = contour_intersection(level, a, b, lift)
                    local x2, y2, z2 = contour_intersection(level, b, c, lift)
                    local x3, y3, z3 = contour_intersection(level, c, a, lift)

                    local ax, ay, az, bx, by, bz
                    if x1 and x2 then
                        ax, ay, az, bx, by, bz = x1, y1, z1, x2, y2, z2
                    elseif x1 and x3 then
                        ax, ay, az, bx, by, bz = x1, y1, z1, x3, y3, z3
                    elseif x2 and x3 then
                        ax, ay, az, bx, by, bz = x2, y2, z2, x3, y3, z3
                    end

                    if ax then
                        LineObject_add_line(lo, color, Vector3(ax, ay, az), Vector3(bx, by, bz))
                        count = count + 1
                    end
                end
            end
        end
    end

    return count
end

local function count_contour_level(level)
    if level < 0 or level > distance_max then return 0 end
    local count = 0
    for i = 1, #active_faces do
        local face = active_faces[i]
        local a, b, c = face[1], face[2], face[3]
        if active[a] and active[b] and active[c] then
            local da, db, dc = distance[a], distance[b], distance[c]
            if da and db and dc then
                local crossings = 0
                if (da <= level and level < db) or (db <= level and level < da) then crossings = crossings + 1 end
                if (db <= level and level < dc) or (dc <= level and level < db) then crossings = crossings + 1 end
                if (dc <= level and level < da) or (da <= level and level < dc) then crossings = crossings + 1 end
                if crossings >= 2 then count = count + 1 end
            end
        end
    end
    return count
end

local function render_wave()
    local lo, world = get_line_object()
    if not lo then return end

    local speed = math_max(setting("nav_speed"), 0.1)
    local trails = math_floor(math_max(setting("nav_trails"), 1))
    local spacing = math_max(setting("nav_trail_spacing"), 0.05)
    local lift = setting("nav_surface_lift")
    local head = wave_age * speed
    local available_lines = frame_budget.draw_remaining()
    local items = {}
    local reserved_lines = 0

    local count_cost = math_max(1, math_floor(math_max(#active_faces, 1) / 48))

    for trail = 0, trails - 1 do
        local level = head - trail * spacing
        if level >= 0 and level <= distance_max then
            if not frame_budget.take(count_cost) then return end
            local count = count_contour_level(level)
            if count > 0 then
                if reserved_lines + count > available_lines then
                    if #items == 0 then return end
                    break
                end
                items[#items + 1] = { level = level, color = palette_color(trail, trails), count = count }
                reserved_lines = reserved_lines + count
            end
        end
    end

    if reserved_lines > 0 and not frame_budget.take_draw(reserved_lines) then return end

    LineObject_reset(lo)
    local any = false
    for i = 1, #items do
        local item = items[i]
        if draw_contour_level(lo, item.level, item.color, lift) > 0 then any = true end
    end
    LineObject_dispatch(world, lo)

    local tail = head - (trails - 1) * spacing
    if tail > distance_max then
        if setting("nav_loop") then
            wave_age = 0
        else
            if any then
                LineObject_reset(lo)
                LineObject_dispatch(world, lo)
            end

            reset_local_solve(true)
        end
    end
end

function api.trigger()
    local x, y, z = player_position()
    if not x then return end

    reset_local_solve(false)
    source_x, source_y, source_z = x, y, z
    pending_pulse = true

    local world = current_nav_world()
    if not world then
        wave_phase = "wait_nav"
        return
    end

    local nav_phase = nav_cache:phase()
    if nav_cache:world() ~= world or nav_phase == "idle" or nav_phase == "failed" then
        nav_cache:begin(world)
        nav_phase = nav_cache:phase()
    end

    if nav_phase == "ready" then
        pending_pulse = false
        begin_patch()
    elseif nav_phase == "failed" then
        wave_phase = "idle"
        pending_pulse = false
    else
        wave_phase = "wait_nav"
    end
end

function api.update(dt)
    clock = clock + dt

    local world = current_nav_world()
    if world ~= nav_cache:world() then

        local had_pending_pulse = pending_pulse
        if not had_pending_pulse then
            reset_local_solve(false)
        end
        nav_cache:reset()
        if had_pending_pulse and world then nav_cache:begin(world) end
    end

    if nav_cache:phase() == "extract" then
        local budget = frame_budget.claim_items(1)
        if budget > 0 then nav_cache:update(budget) end
    end

    if pending_pulse and nav_cache:phase() == "ready" then
        pending_pulse = false
        begin_patch()
    elseif pending_pulse and nav_cache:phase() == "failed" then

        pending_pulse = false
        wave_phase = "idle"
    end

    if wave_phase == "build_patch" then
        local budget = frame_budget.claim_items(1)
        if budget > 0 then patch_build_step(budget) end
    elseif wave_phase == "component" then
        local budget = frame_budget.claim_items(1)
        if budget > 0 then component_step(budget) end
    elseif wave_phase == "operator" then
        local budget = frame_budget.claim_items(2)
        if budget > 0 then operator_step(budget) end
    elseif wave_phase == "heat" then
        if not cg then
            local rhs = api._pending_heat_rhs
            api._pending_heat_rhs = nil
            cg = initialize_cg("heat", rhs, heat_u)
        end
        local iteration_cost = math_max(8, math_floor(math_max(active_count, 1) / 48))
        local iterations = frame_budget.claim_items(iteration_cost)
        if iterations > 0 and cg_step(cg, iterations) then
            cg = nil
            begin_gradient()
        end
    elseif wave_phase == "gradient" then
        local budget = frame_budget.claim_items(2)
        if budget > 0 then gradient_step(budget) end
    elseif wave_phase == "poisson" then
        local iteration_cost = math_max(8, math_floor(math_max(active_count, 1) / 48))
        local iterations = frame_budget.claim_items(iteration_cost)
        if iterations > 0 and cg_step(cg, iterations) then
            cg = nil
            finalize_distance()
        end
    elseif wave_phase == "ready" then
        wave_age = wave_age + dt
        if clock >= wave_next_render then
            render_wave()
            wave_next_render = clock + RENDER_INTERVAL
        end
    end
end


function api.clear()
    reset_local_solve(false)
    nav_cache:reset()
end

function api.reset_all(keep_drawing)
    reset_local_solve(keep_drawing)
    nav_cache:reset()
    if not keep_drawing then line_owner:destroy() end
end

function api.on_game_state_changed(status, state_name)
    if state_name == "StateGameplay" and status == "exit" then
        reset_local_solve(true)
        nav_cache:reset()
        line_owner:destroy()
    end
end

return api
