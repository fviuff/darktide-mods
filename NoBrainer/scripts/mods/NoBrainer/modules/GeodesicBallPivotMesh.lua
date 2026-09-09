local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local sampler_factory = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/CollisionSurfaceSampler")
local retained_line_chunks = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RetainedLineChunks")
local math3d = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/StingrayMath")

local api = {}

local math_abs = math.abs
local math_acos = math.acos
local math_ceil = math.ceil
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_pi = math.pi
local math_sqrt = math.sqrt
local pairs = pairs
local tostring = tostring

local dot = math3d.dot
local cross = math3d.cross
local normalize = math3d.normalize
local squared_distance = math3d.squared_distance

local BPA_LINES_PER_CHUNK = 512
local BPA_NEIGHBOR_LIMIT = 48
local BPA_SEED_NEIGHBOR_LIMIT = 14
local BPA_RADIUS_MULTIPLIERS = { 1.00, 1.35, 1.70 }
local BPA_NORMAL_DOT = 0.25

local sampler = sampler_factory.new(frame_budget)
local clock = 0
local sampling_active = false
local wave_age = 0
local sampler_cfg = nil

local cfg_spacing = settings.defaults.bpa_sample_spacing
local cfg_base_radius = settings.defaults.bpa_ball_radius
local cfg_radii = { settings.defaults.bpa_ball_radius, settings.defaults.bpa_ball_radius * 1.35, settings.defaults.bpa_ball_radius * 1.70 }
local cfg_radius_pass = 1
local cfg_radius = settings.defaults.bpa_ball_radius
local cfg_grid_cell = settings.defaults.bpa_ball_radius
local cfg_duration = settings.defaults.bpa_duration
local cfg_color = settings.defaults.bpa_color

local bpa_layers = {}
local bpa_visible_head = 0
local bpa_release_step = 0
local bpa_release_index = 1
local bpa_points = {}
local bpa_point_cells = {}
local bpa_edges = {}
local bpa_blocked_edges = {}
local bpa_boundary_cells = {}
local bpa_front_queue = {}
local bpa_front_head = 1
local bpa_front_tail = 0
local bpa_seed_queue = {}
local bpa_seed_head = 1
local bpa_seed_tail = 0
local bpa_triangle_keys = {}
local bpa_map_ax, bpa_map_ay, bpa_map_az = {}, {}, {}
local bpa_map_bx, bpa_map_by, bpa_map_bz = {}, {}, {}
local bpa_map_queue_index = 1
local bpa_map_queue_tail = 0

local bpa_transition_phase = nil
local bpa_transition_key = nil

local query_ids = {}
local query_d2s = {}

local line_renderer = retained_line_chunks.new(BPA_LINES_PER_CHUNK)
local bpa_map_expire = math.huge
local bpa_has_map = false

local function clear_array(t)
    for i = #t, 1, -1 do t[i] = nil end
end

local function clear_map(t)
    for k in pairs(t) do t[k] = nil end
end

local function refresh_config()
    sampler_cfg = settings.surface_sampler()

    cfg_spacing = math_max(0.05, settings.number("bpa_sample_spacing"))
    cfg_base_radius = math_max(0.10, settings.number("bpa_ball_radius"))

    cfg_radii = {}
    for i = 1, #BPA_RADIUS_MULTIPLIERS do
        cfg_radii[i] = cfg_base_radius * BPA_RADIUS_MULTIPLIERS[i]
    end
    cfg_radius_pass = 1
    cfg_radius = cfg_radii[1]

    cfg_grid_cell = cfg_base_radius

    cfg_duration = math_max(1, settings.number("bpa_duration"))
    cfg_color = settings.get("bpa_color")
end

local function clear_visual()
    line_renderer:clear()
    bpa_has_map = false
    bpa_map_expire = math.huge
end

local function reset_reconstruction(clear_drawing)
    clear_map(bpa_layers)
    bpa_visible_head = 0
    bpa_release_step = 0
    bpa_release_index = 1
    clear_array(bpa_points)
    clear_map(bpa_point_cells)
    clear_map(bpa_edges)
    clear_map(bpa_blocked_edges)
    clear_map(bpa_boundary_cells)
    clear_map(bpa_front_queue)
    bpa_front_head = 1
    bpa_front_tail = 0
    clear_map(bpa_seed_queue)
    bpa_seed_head = 1
    bpa_seed_tail = 0
    clear_map(bpa_triangle_keys)
    clear_array(bpa_map_ax); clear_array(bpa_map_ay); clear_array(bpa_map_az)
    clear_array(bpa_map_bx); clear_array(bpa_map_by); clear_array(bpa_map_bz)
    bpa_map_queue_index = 1
    bpa_map_queue_tail = 0
    bpa_transition_phase = nil
    bpa_transition_key = nil
    cfg_radius_pass = 1
    cfg_radius = cfg_radii[1] or cfg_base_radius
    if clear_drawing then clear_visual() end
end

local function edge_key(a, b)
    if a > b then a, b = b, a end
    return tostring(a) .. ":" .. tostring(b)
end

local function triangle_key(a, b, c)
    if a > b then a, b = b, a end
    if b > c then b, c = c, b end
    if a > b then a, b = b, a end
    return tostring(a) .. ":" .. tostring(b) .. ":" .. tostring(c)
end

local function cell_coords(x, y, z)
    return math_floor(x / cfg_grid_cell), math_floor(y / cfg_grid_cell), math_floor(z / cfg_grid_cell)
end

local function cell_key(ix, iy, iz)
    return tostring(ix) .. ":" .. tostring(iy) .. ":" .. tostring(iz)
end

local function mark_seed_dirty(p)
    if p and p.tri_count == 0 and not p.seed_queued then
        p.seed_queued = true
        bpa_seed_tail = bpa_seed_tail + 1
        bpa_seed_queue[bpa_seed_tail] = p.id
    end
end

local function register_boundary(rec)
    local a, b = bpa_points[rec.a], bpa_points[rec.b]
    if not a or not b then return end
    local ix, iy, iz = cell_coords((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5)
    local key = cell_key(ix, iy, iz)
    local bucket = bpa_boundary_cells[key]
    if not bucket then bucket = {}; bpa_boundary_cells[key] = bucket end
    rec.boundary_key = key
    rec.boundary_index = #bucket + 1
    bucket[rec.boundary_index] = rec
end

local function unregister_boundary(rec)
    local key, index = rec and rec.boundary_key, rec and rec.boundary_index
    if not key or not index then return end
    local bucket = bpa_boundary_cells[key]
    if bucket then
        local last_index = #bucket
        local moved = bucket[last_index]
        bucket[last_index] = nil
        if index < last_index then
            bucket[index] = moved
            if moved then moved.boundary_index = index end
        end
        if #bucket == 0 then bpa_boundary_cells[key] = nil end
    end
    rec.boundary_key = nil
    rec.boundary_index = nil
end

local function enqueue_front(rec)
    if rec.count == 1 and not rec.queued then
        rec.queued = true
        bpa_front_tail = bpa_front_tail + 1
        bpa_front_queue[bpa_front_tail] = rec
    end
end

local function wake_local_work(p)
    local cx, cy, cz = cell_coords(p.x, p.y, p.z)
    local wake_radius = cfg_radius * 2
    local wake_r2 = wake_radius * wake_radius
    local wake_span = math_ceil(wake_radius / cfg_grid_cell)
    for ix = cx - wake_span, cx + wake_span do
        for iy = cy - wake_span, cy + wake_span do
            for iz = cz - wake_span, cz + wake_span do
                local key = cell_key(ix, iy, iz)
                local point_bucket = bpa_point_cells[key]
                if point_bucket then
                    for bi = 1, #point_bucket do
                        local q = bpa_points[point_bucket[bi]]
                        if q and q.id ~= p.id and q.tri_count == 0
                            and squared_distance(p.x, p.y, p.z, q.x, q.y, q.z) <= wake_r2 then
                            mark_seed_dirty(q)
                        end
                    end
                end
                local boundary_bucket = bpa_boundary_cells[key]
                if boundary_bucket then
                    for bi = 1, #boundary_bucket do
                        local rec = boundary_bucket[bi]
                        if rec and rec.count == 1 then
                            local a, b = bpa_points[rec.a], bpa_points[rec.b]
                            if a and b then
                                local mx, my, mz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
                                if squared_distance(p.x, p.y, p.z, mx, my, mz) <= wake_r2 then enqueue_front(rec) end
                            end
                        end
                    end
                end
            end
        end
    end
    mark_seed_dirty(p)
end

local function query_nearest_ids(x, y, z, radius, limit)
    local ids, d2s = query_ids, query_d2s
    for i = #ids, 1, -1 do ids[i] = nil; d2s[i] = nil end
    local count = 0
    local cx, cy, cz = cell_coords(x, y, z)
    local span = math_ceil(radius / cfg_grid_cell)
    local r2 = radius * radius

    local function insert(id, d2)
        if count >= limit and d2 >= d2s[count] then return end
        local pos = count + 1
        if pos > limit then pos = limit end
        while pos > 1 and d2 < d2s[pos - 1] do
            if pos <= limit then
                ids[pos] = ids[pos - 1]
                d2s[pos] = d2s[pos - 1]
            end
            pos = pos - 1
        end
        ids[pos], d2s[pos] = id, d2
        if count < limit then count = count + 1 end
        ids[count + 1], d2s[count + 1] = nil, nil
    end

    for ix = cx - span, cx + span do
        for iy = cy - span, cy + span do
            for iz = cz - span, cz + span do
                local bucket = bpa_point_cells[cell_key(ix, iy, iz)]
                if bucket then
                    for bi = 1, #bucket do
                        local id = bucket[bi]
                        local p = bpa_points[id]
                        local d2 = squared_distance(x, y, z, p.x, p.y, p.z)
                        if d2 <= r2 then insert(id, d2) end
                    end
                end
            end
        end
    end
    return ids
end

local function insert_point(sample, step_index)

    local near = query_nearest_ids(sample.x, sample.y, sample.z, cfg_spacing, 8)
    for i = 1, #near do
        local q = bpa_points[near[i]]
        local normal_similarity = dot(sample.nx, sample.ny, sample.nz, q.nx, q.ny, q.nz)
        if normal_similarity > 0.80 then
            local dx, dy, dz = q.x - sample.x, q.y - sample.y, q.z - sample.z
            local normal_gap = math_max(
                math_abs(dot(dx, dy, dz, sample.nx, sample.ny, sample.nz)),
                math_abs(dot(dx, dy, dz, q.nx, q.ny, q.nz))
            )
            if normal_gap <= math_max(sampler_cfg.lift * 4, cfg_spacing * 0.20) then return nil end
        end
    end

    local id = #bpa_points + 1
    local p = {
        id = id,
        x = sample.x, y = sample.y, z = sample.z,
        nx = sample.nx, ny = sample.ny, nz = sample.nz,
        step = step_index or sample.step,
        tri_count = 0,
    }
    bpa_points[id] = p
    local ix, iy, iz = cell_coords(p.x, p.y, p.z)
    local key = cell_key(ix, iy, iz)
    local bucket = bpa_point_cells[key]
    if not bucket then bucket = {}; bpa_point_cells[key] = bucket end
    bucket[#bucket + 1] = id
    wake_local_work(p)
    return id
end

local function capture_layer(step_index, nodes)
    bpa_layers[step_index] = { nodes = nodes or {} }
end

local function palette_rgb()
    if cfg_color == "amber" then return 255, 180, 45 end
    if cfg_color == "white" then return 230, 230, 230 end
    if cfg_color == "toxin" then return 90, 235, 110 end
    return 70, 220, 255
end

local function queue_edge_line(a, b)
    local lift = sampler_cfg.lift
    bpa_map_queue_tail = bpa_map_queue_tail + 1
    local i = bpa_map_queue_tail
    bpa_map_ax[i], bpa_map_ay[i], bpa_map_az[i] =
        a.x + a.nx * lift, a.y + a.ny * lift, a.z + a.nz * lift
    bpa_map_bx[i], bpa_map_by[i], bpa_map_bz[i] =
        b.x + b.nx * lift, b.y + b.ny * lift, b.z + b.nz * lift
end

-- sphere through 3 samples, then pick the center on the normal side we want
local function triangle_ball(a, b, c, preserve_order)
    local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
    local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
    local wx, wy, wz = cross(ux, uy, uz, vx, vy, vz)
    local w2 = wx * wx + wy * wy + wz * wz
    if w2 <= 1e-10 then return nil end

    local tnx, tny, tnz = normalize(wx, wy, wz)
    local anx, any, anz = normalize(a.nx + b.nx + c.nx, a.ny + b.ny + c.ny, a.nz + b.nz + c.nz)
    if not tnx or not anx then return nil end

    if dot(tnx, tny, tnz, anx, any, anz) < 0 then
        if preserve_order then return nil end
        b, c = c, b
        ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
        vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
        wx, wy, wz = cross(ux, uy, uz, vx, vy, vz)
        w2 = wx * wx + wy * wy + wz * wz
        tnx, tny, tnz = normalize(wx, wy, wz)
        if not tnx then return nil end
    end

    if dot(tnx, tny, tnz, a.nx, a.ny, a.nz) < BPA_NORMAL_DOT
        or dot(tnx, tny, tnz, b.nx, b.ny, b.nz) < BPA_NORMAL_DOT
        or dot(tnx, tny, tnz, c.nx, c.ny, c.nz) < BPA_NORMAL_DOT then
        return nil
    end

    local u2 = ux * ux + uy * uy + uz * uz
    local v2 = vx * vx + vy * vy + vz * vz
    local cvwx, cvwy, cvwz = cross(vx, vy, vz, wx, wy, wz)
    local cwux, cwuy, cwuz = cross(wx, wy, wz, ux, uy, uz)
    local inv = 1 / (2 * w2)
    local qx = a.x + (u2 * cvwx + v2 * cwux) * inv
    local qy = a.y + (u2 * cvwy + v2 * cwuy) * inv
    local qz = a.z + (u2 * cvwz + v2 * cwuz) * inv
    local r2 = squared_distance(qx, qy, qz, a.x, a.y, a.z)
    local rho2 = cfg_radius * cfg_radius
    if r2 > rho2 * 1.0005 then return nil end
    local h = math_sqrt(math_max(0, rho2 - r2))
    return a, b, c, qx + tnx * h, qy + tny * h, qz + tnz * h
end

local function empty_ball(cx, cy, cz, ia, ib, ic)
    -- slight shrink so samples numerically sitting on the ball dont reject their own face
    local threshold = cfg_radius - math_max(0.003, cfg_radius * 0.008)
    local threshold2 = threshold * threshold
    local qx, qy, qz = cell_coords(cx, cy, cz)
    local span = math_ceil(cfg_radius / cfg_grid_cell)
    for ix = qx - span, qx + span do
        for iy = qy - span, qy + span do
            for iz = qz - span, qz + span do
                local bucket = bpa_point_cells[cell_key(ix, iy, iz)]
                if bucket then
                    for bi = 1, #bucket do
                        local id = bucket[bi]
                        if id ~= ia and id ~= ib and id ~= ic then
                            local p = bpa_points[id]
                            if squared_distance(cx, cy, cz, p.x, p.y, p.z) < threshold2 then return false end
                        end
                    end
                end
            end
        end
    end
    return true
end

-- a boundary edge can take one more face but only from the other winding
local function edge_capacity_ok(a, b, directed_a, directed_b)
    local rec = bpa_edges[edge_key(a, b)]
    if not rec then return true end
    if rec == true or rec.count >= 2 then return false end
    return rec.a == directed_b and rec.b == directed_a
end

local function new_edge_clear(u, v)
    local key = edge_key(u.id, v.id)
    if bpa_edges[key] then return true end
    if bpa_blocked_edges[key] then return false end
    if sampler:path_is_clear(u.x, u.y, u.z, u.nx, u.ny, u.nz, v.x, v.y, v.z, v.nx, v.ny, v.nz) then
        return true
    end
    bpa_blocked_edges[key] = true
    return false
end

local function new_edges_clear(a, b, c)
    return new_edge_clear(a, b) and new_edge_clear(b, c) and new_edge_clear(c, a)
end

local function add_triangle(a, b, c, cx, cy, cz)
    local tkey = triangle_key(a.id, b.id, c.id)
    if bpa_triangle_keys[tkey] then return false end
    if not edge_capacity_ok(a.id, b.id, a.id, b.id)
        or not edge_capacity_ok(b.id, c.id, b.id, c.id)
        or not edge_capacity_ok(c.id, a.id, c.id, a.id)
        or not new_edges_clear(a, b, c) then
        return false
    end

    bpa_triangle_keys[tkey] = true
    a.tri_count, b.tri_count, c.tri_count = a.tri_count + 1, b.tri_count + 1, c.tri_count + 1

    local function accept_edge(u, v, opposite)
        local key = edge_key(u.id, v.id)
        local rec = bpa_edges[key]
        if not rec then
            rec = {
                key = key, a = u.id, b = v.id, opposite = opposite.id,
                count = 1, cx = cx, cy = cy, cz = cz, queued = false,
            }
            bpa_edges[key] = rec
            register_boundary(rec)
            queue_edge_line(u, v)
            enqueue_front(rec)
        else
            rec.count = rec.count + 1
            rec.queued = false
            rec.cx, rec.cy, rec.cz, rec.opposite = nil, nil, nil, nil
            unregister_boundary(rec)
            bpa_edges[key] = true
        end
    end

    accept_edge(a, b, c)
    accept_edge(b, c, a)
    accept_edge(c, a, b)
    return true
end

local function seed_candidate(p, q, r)
    local a, b, c, cx, cy, cz = triangle_ball(p, q, r, false)
    if not a or not empty_ball(cx, cy, cz, a.id, b.id, c.id) then return false end
    return add_triangle(a, b, c, cx, cy, cz)
end

local function try_seed()
    if #bpa_points < 3 then return false end
    local attempts = 0
    local max_attempts = math_max(1, math_floor(frame_budget.limit() * 0.02))
    while bpa_seed_head <= bpa_seed_tail and attempts < max_attempts and frame_budget.take(3) do
        local id = bpa_seed_queue[bpa_seed_head]
        bpa_seed_queue[bpa_seed_head] = nil
        bpa_seed_head = bpa_seed_head + 1
        local p = bpa_points[id]
        if p then p.seed_queued = false end
        if p and p.tri_count == 0 then
            attempts = attempts + 1
            local ids = query_nearest_ids(p.x, p.y, p.z, cfg_radius * 2, BPA_SEED_NEIGHBOR_LIMIT + 1)
            for i = 1, #ids - 1 do
                local q = bpa_points[ids[i]]
                if q.id ~= p.id then
                    for j = i + 1, #ids do
                        local r = bpa_points[ids[j]]
                        if r.id ~= p.id and seed_candidate(p, q, r) then
                            if bpa_seed_head > bpa_seed_tail then bpa_seed_head, bpa_seed_tail = 1, 0 end
                            return true
                        end
                    end
                end
            end
        end
    end
    if bpa_seed_head > bpa_seed_tail then bpa_seed_head, bpa_seed_tail = 1, 0 end
    return false
end

-- compare ball centers around the shared edge, smallest positive rotation is the next pivot
local function pivot_angle(rec, ncx, ncy, ncz)
    local a, b = bpa_points[rec.a], bpa_points[rec.b]
    local mx, my, mz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
    local u1x, u1y, u1z = normalize(rec.cx - mx, rec.cy - my, rec.cz - mz)
    local u2x, u2y, u2z = normalize(ncx - mx, ncy - my, ncz - mz)
    if not u1x or not u2x then return math.huge end
    local cosine = math_max(-1, math_min(1, dot(u1x, u1y, u1z, u2x, u2y, u2z)))
    local angle = math_acos(cosine)
    local cx, cy, cz = cross(u1x, u1y, u1z, u2x, u2y, u2z)
    local ex, ey, ez = normalize(b.x - a.x, b.y - a.y, b.z - a.z)
    if not ex then return math.huge end
    if dot(cx, cy, cz, ex, ey, ez) < 0 then angle = 2 * math_pi - angle end
    if angle < 1e-5 then return math.huge end
    return angle
end

local function find_pivot_candidate(rec)
    if rec.count ~= 1 or not rec.cx then return nil end
    local pa, pb = bpa_points[rec.a], bpa_points[rec.b]
    local mx, my, mz = (pa.x + pb.x) * 0.5, (pa.y + pb.y) * 0.5, (pa.z + pb.z) * 0.5
    local search_radius = math_sqrt(squared_distance(mx, my, mz, rec.cx, rec.cy, rec.cz)) + cfg_radius
    local ids = query_nearest_ids(mx, my, mz, search_radius, BPA_NEIGHBOR_LIMIT + (cfg_radius_pass - 1) * 16 + 2)
    local best, best_cx, best_cy, best_cz, best_angle = nil, nil, nil, nil, math.huge

    for i = 1, #ids do
        local id = ids[i]
        if id ~= rec.a and id ~= rec.b then
            local pc = bpa_points[id]
            local a, b, c, cx, cy, cz = triangle_ball(pb, pa, pc, true)
            if a and edge_capacity_ok(a.id, b.id, a.id, b.id)
                and edge_capacity_ok(b.id, c.id, b.id, c.id)
                and edge_capacity_ok(c.id, a.id, c.id, a.id)
                and empty_ball(cx, cy, cz, a.id, b.id, c.id) then
                local angle = pivot_angle(rec, cx, cy, cz)
                if angle < best_angle then
                    best, best_cx, best_cy, best_cz, best_angle = pc, cx, cy, cz, angle
                end
            end
        end
    end
    return best, best_cx, best_cy, best_cz
end

local function process_front()
    local scanned = 0
    local max_scanned = math_max(1, math_floor(frame_budget.limit() * 0.18 / 6))
    while bpa_front_head <= bpa_front_tail and scanned < max_scanned and frame_budget.take(6) do
        local rec = bpa_front_queue[bpa_front_head]
        bpa_front_queue[bpa_front_head] = nil
        bpa_front_head = bpa_front_head + 1
        scanned = scanned + 1
        if rec then rec.queued = false end
        if rec and rec.count == 1 then
            local candidate, cx, cy, cz = find_pivot_candidate(rec)
            if candidate then add_triangle(bpa_points[rec.b], bpa_points[rec.a], candidate, cx, cy, cz) end
        end
    end
    if bpa_front_head > bpa_front_tail then bpa_front_head, bpa_front_tail = 1, 0 end
end

local function reactivate_boundary_for_radius(rec)
    if not rec or rec.count ~= 1 or not rec.opposite then return end
    local a = bpa_points[rec.a]
    local b = bpa_points[rec.b]
    local opposite = bpa_points[rec.opposite]
    if not a or not b or not opposite then return end

    local ta, tb, tc, cx, cy, cz = triangle_ball(a, b, opposite, true)
    if ta and empty_ball(cx, cy, cz, ta.id, tb.id, tc.id) then
        rec.cx, rec.cy, rec.cz = cx, cy, cz
        enqueue_front(rec)
    else
        rec.cx, rec.cy, rec.cz = nil, nil, nil
    end
end

-- dont rebuild everything for a larger ball, just wake the boundaries that might continue now
local function begin_next_radius_pass()
    if cfg_radius_pass >= #cfg_radii then return false end
    cfg_radius_pass = cfg_radius_pass + 1
    cfg_radius = cfg_radii[cfg_radius_pass]
    bpa_transition_phase = "edges"
    bpa_transition_key = nil
    return true
end

local function process_radius_transition()
    if not bpa_transition_phase then return end

    local max_items = math_max(1, math_floor(frame_budget.limit() * 0.12 / 2))
    local processed = 0

    while processed < max_items and frame_budget.take(2) do
        local key, rec = next(bpa_edges, bpa_transition_key)
        bpa_transition_key = key
        if key == nil then
            bpa_transition_phase = nil
            bpa_transition_key = nil
            break
        end
        if rec ~= true and rec.count == 1 then
            reactivate_boundary_for_radius(rec)
        end
        processed = processed + 1
    end
end

local function release_points(visible_head)
    local visible_step = math_floor(visible_head / sampler_cfg.step + 0.5)
    local examined = 0
    local max_examined = math_max(1, math_floor(frame_budget.limit() * 0.14 / 2))
    while bpa_release_step <= visible_step and examined < max_examined do
        local layer = bpa_layers[bpa_release_step]
        local batch = layer and layer.nodes or nil
        if not batch or #batch == 0 then
            bpa_layers[bpa_release_step] = nil
            bpa_release_step = bpa_release_step + 1
            bpa_release_index = 1
        else
            while bpa_release_index <= #batch and examined < max_examined do
                if not frame_budget.take(2) then return end
                insert_point(batch[bpa_release_index], bpa_release_step)
                bpa_release_index = bpa_release_index + 1
                examined = examined + 1
            end
            if bpa_release_index > #batch then
                bpa_layers[bpa_release_step] = nil
                bpa_release_step = bpa_release_step + 1
                bpa_release_index = 1
            end
        end
    end
end

local function mapping_caught_up()
    if #bpa_points == 0 and next(bpa_layers) == nil
        and not bpa_transition_phase
        and bpa_front_head > bpa_front_tail and bpa_seed_head > bpa_seed_tail
        and bpa_map_queue_index > bpa_map_queue_tail then
        return true
    end
    local visible_step = math_floor(bpa_visible_head / sampler_cfg.step + 0.5)
    return bpa_release_step > visible_step
        and not bpa_transition_phase
        and cfg_radius_pass >= #cfg_radii
        and bpa_front_head > bpa_front_tail
        and bpa_seed_head > bpa_seed_tail
        and bpa_map_queue_index > bpa_map_queue_tail
end

local function process(visible_head)
    bpa_visible_head = math_max(bpa_visible_head, visible_head or 0)
    release_points(bpa_visible_head)

    if bpa_transition_phase then
        process_radius_transition()
        return
    end

    process_front()
    if bpa_front_head > bpa_front_tail and bpa_seed_head <= bpa_seed_tail then
        try_seed()
    end

    if not sampling_active
        and next(bpa_layers) == nil
        and bpa_front_head > bpa_front_tail
        and bpa_seed_head > bpa_seed_tail
        and cfg_radius_pass < #cfg_radii then
        begin_next_radius_pass()
    end
end

local function flush_lines()

    if bpa_map_queue_index > bpa_map_queue_tail then
        if line_renderer:has_pending_dispatch() then line_renderer:dispatch() end
        return
    end
    local added = 0
    local r, g, bl = palette_rgb()

    while bpa_map_queue_index <= bpa_map_queue_tail do
        if not frame_budget.take_draw(1) then break end
        local i = bpa_map_queue_index
        if not line_renderer:add_line_rgb_xyz(
            r, g, bl,
            bpa_map_ax[i], bpa_map_ay[i], bpa_map_az[i],
            bpa_map_bx[i], bpa_map_by[i], bpa_map_bz[i]
        ) then
            frame_budget.refund_draw(1)
            break
        end
        bpa_map_ax[i], bpa_map_ay[i], bpa_map_az[i] = nil, nil, nil
        bpa_map_bx[i], bpa_map_by[i], bpa_map_bz[i] = nil, nil, nil
        bpa_map_queue_index = i + 1
        added = added + 1
    end

    if added > 0 then
        line_renderer:dispatch()
        bpa_has_map = true
        bpa_map_expire = clock + cfg_duration
    end
    if bpa_map_queue_index > bpa_map_queue_tail then bpa_map_queue_index, bpa_map_queue_tail = 1, 0 end
end
local function stop_sampling()
    sampling_active = false
    wave_age = 0
    sampler:stop()
end

function api.trigger()
    clear_visual()
    reset_reconstruction(false)
    refresh_config()
    wave_age = 0
    sampling_active = sampler:start(sampler_cfg, capture_layer)
end

function api.update(dt)
    clock = clock + dt

    if sampler:world_changed() then
        stop_sampling()
        sampler:reset_world()
        reset_reconstruction(true)
        return
    end

    if sampling_active then
        wave_age = wave_age + dt
        local scan_time = math_max(0.5, settings.number("bpa_scan_time"))
        local scan_t = math_min(wave_age / scan_time, 1)
        local requested_head = sampler_cfg.radius * scan_t
        local lookahead = math_max(cfg_radius, sampler_cfg.step * 4)
        local target_distance = math_min(sampler_cfg.radius, requested_head + lookahead)
        sampler:propagate_toward(math_ceil(target_distance / sampler_cfg.step), 0.48)

        local computed_head = sampler:simulation_step() * sampler_cfg.step
        process(math_min(requested_head, computed_head))

        if wave_age >= scan_time then

            local target_step = math_ceil(sampler_cfg.radius / sampler_cfg.step)
            if sampler:is_finished() or sampler:simulation_step() >= target_step then
                stop_sampling()
                if bpa_has_map then bpa_map_expire = clock + cfg_duration end
            end
        end
    elseif not mapping_caught_up() then
        process(bpa_visible_head)
    end

    flush_lines()

    if not sampling_active and #bpa_points > 0 and mapping_caught_up() then
        reset_reconstruction(false)
    end

    if bpa_has_map and clock >= bpa_map_expire and mapping_caught_up() then
        clear_visual()
        reset_reconstruction(false)
    end
end


function api.clear()
    stop_sampling()
    reset_reconstruction(true)
end

function api.reset_all(keep_drawing)
    stop_sampling()
    sampler:reset_world()
    reset_reconstruction(not keep_drawing)
end

function api.on_game_state_changed(status, state_name)
    if state_name == "StateGameplay" and status == "exit" then
        stop_sampling()
        sampler:reset_world()
        reset_reconstruction(true)
    end
end

return api
