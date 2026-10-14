local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local retained_line_chunks = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RetainedLineChunks")
local scan_pattern = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RaycastScanPattern")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")

local api = {}

local math_floor = math.floor
local math_sqrt = math.sqrt
local math_min = math.min
local math_max = math.max
local pcall = pcall
local table_sort = table.sort

local COLLISION_FILTER = "filter_player_character_ballistic_raycast"
local EXPIRE_BUCKET = 0.5
local ANALYSIS_KEY_BASE = 262144
local EPS = 1e-7
local ANALYSIS_COLUMNS_PER_FRAME = 180

local scanning = false
local scan_type = "fov"
local scan_row = 0
local scan_col = 0
local scan_prev_row = nil
local scan_current_row = nil
local scan_context = nil
local pending_scan_kind = nil
local scan_h_res = settings.defaults.h_res
local scan_v_res = settings.defaults.v_res
local scan_h_fov = settings.defaults.h_fov
local scan_v_fov = settings.defaults.v_fov
local scan_max_range = settings.defaults.max_range
local scan_dot_duration = settings.defaults.dot_duration
local scan_mesh_link_distance = settings.defaults.mesh_link_distance
local scan_max_dots = settings.defaults.max_dots
local scan_recycle_oldest = settings.defaults.recycle_oldest
local scan_max_epsilon = settings.defaults.max_epsilon
local scan_min_persistence = settings.defaults.min_persistence
local scan_max_cycles = settings.defaults.max_cycles
local scan_dot_size = settings.defaults.dot_size
local scan_lines_per_dot = settings.defaults.lines_per_dot
local scan_color_scheme = settings.defaults.color_scheme
local scan_line_surface_lift = settings.defaults.line_surface_lift

local line_renderer = retained_line_chunks.new(512)

local dots = {}
local next_dot_id = 1
local edges = {}
local edge_by_key = {}
local triangles = {}
local cycle_segments = {}
local cycle_segment_keys = {}

local clock = 0
local next_expire = math.huge

local function sync_clock(dt)
    if Application and Application.time_since_launch then
        local ok, value = pcall(Application.time_since_launch)
        if ok and type(value) == "number" then
            clock = value
            return
        end
    end
    clock = clock + (dt or 0)
end

local rebuilding = false
local rebuild_stage = 1
local rebuild_index = 1
local rebuild_reanalyse = false

local analysis_phase = "idle"
local analysis_points = {}
local analysis_point_count = 0
local analysis_vertex_by_dot_id = {}
local simplices = {}
local simplex_count = 0
local vertex_index = {}
local edge_index = {}
local reduce_index = 1
local reduced_columns = {}
local pivot_owner = {}
local death_pair = {}
local xor_a = {}
local xor_b = {}
local forest_parent = {}
local forest_rank = {}
local forest_adj = {}
local h1_birth_edge = {}
local intervals = {}
local reset_analysis_tables

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

local function pair_key_ids(a, b)
    local ai = a.id
    local bi = b.id
    if ai > bi then ai, bi = bi, ai end
    return tostring(ai) .. ":" .. tostring(bi)
end

local function analysis_edge_key(a, b)
    if a > b then a, b = b, a end
    return a * ANALYSIS_KEY_BASE + b
end

local COLOR_SCHEMES = {
    classic = function(t)
        return math_floor(40 * (1 - t)), math_floor(255 * (1 - t)), math_floor(60 + 195 * t)
    end,
    mono = function(t)
        local v = math_floor(255 - 215 * t)
        return v, v, v
    end,
    infrared = function(t)
        return math_floor(255 - 175 * t), math_floor(60 * (1 - t)), math_floor(30 * (1 - t))
    end,
    amber = function(t)
        return math_floor(255 - 155 * t), math_floor(170 * (1 - t) + 30), 0
    end,
    toxin = function(t)
        return math_floor(120 * t + 40), 255 - math_floor(155 * t), math_floor(40 * (1 - t))
    end,
    rainbow = function(t)
        local h = t * 4
        local seg = math_floor(h)
        local f = math_floor(255 * (h - seg))
        if seg == 0 then return 255, f, 0
        elseif seg == 1 then return 255 - f, 255, 0
        elseif seg == 2 then return 0, 255, f
        else return 0, 255 - f, 255
        end
    end,
}

local function distance_rgb(t)
    local scheme = COLOR_SCHEMES[scan_color_scheme] or COLOR_SCHEMES.classic
    return scheme(t)
end

local function lifted_dot_position(dot, lift)
    local x, y, z = dot.x, dot.y, dot.z
    if lift > 0 and dot.ox then
        local dx = dot.ox - x
        local dy = dot.oy - y
        local dz = dot.oz - z
        local len2 = dx * dx + dy * dy + dz * dz
        if len2 > EPS then
            local s = lift / math_sqrt(len2)
            x = x + dx * s
            y = y + dy * s
            z = z + dz * s
        end
    end
    return x, y, z
end

local function add_dot_lines(dot)
    local r = scan_dot_size / 1000
    local num_lines = math_floor(scan_lines_per_dot)
    local cr,cg,cb = distance_rgb(dot.dist_t)
    local x,y,z = dot.x,dot.y,dot.z

    line_renderer:add_line_rgb_xyz(cr,cg,cb, x, y, z-r, x, y, z+r)
    if num_lines >= 2 then
        line_renderer:add_line_rgb_xyz(cr,cg,cb, x-r, y, z, x+r, y, z)
    end
    if num_lines >= 3 then
        line_renderer:add_line_rgb_xyz(cr,cg,cb, x, y-r, z, x, y+r, z)
    end
end

local function add_mesh_line(edge)
    local lift = math_max(scan_line_surface_lift, 0)
    local ax,ay,az = lifted_dot_position(edge.a, lift)
    local bx,by,bz = lifted_dot_position(edge.b, lift)
    local cr,cg,cb = distance_rgb((edge.a.dist_t + edge.b.dist_t) * 0.5)
    line_renderer:add_line_rgb_xyz(cr,cg,cb, ax,ay,az,bx,by,bz)
end

local function add_cycle_line(segment)
    local lift = math_max(scan_line_surface_lift, 0) + 0.025
    local ax,ay,az = lifted_dot_position(segment.a, lift)
    local bx,by,bz = lifted_dot_position(segment.b, lift)
    local cr,cg,cb
    if segment.censored then
        cr,cg,cb = 220,120,255
    elseif segment.strong then
        cr,cg,cb = 255,245,170
    else
        cr,cg,cb = 255,155,45
    end
    line_renderer:add_line_rgb_xyz(cr,cg,cb, ax,ay,az,bx,by,bz)
end

local function dot_distance(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math_sqrt(dx * dx + dy * dy + dz * dz)
end

local function get_edge(a, b)
    return edge_by_key[pair_key_ids(a, b)]
end

local function maybe_add_edge(a, b)
    if not a or not b or a == b then return nil, false end

    local key = pair_key_ids(a, b)
    local existing = edge_by_key[key]
    if existing then return existing, false end

    local d = dot_distance(a, b)
    if d > scan_mesh_link_distance then return nil, false end

    local edge = {
        a = a,
        b = b,
        f = d,
        expire = math_min(a.expire, b.expire),
    }
    edges[#edges + 1] = edge
    edge_by_key[key] = edge

    add_mesh_line(edge)
    return edge, true
end

local function maybe_add_triangle(a, b, c)
    if not a or not b or not c then return end
    local e1 = get_edge(a, b)
    local e2 = get_edge(a, c)
    local e3 = get_edge(b, c)
    if not e1 or not e2 or not e3 then return end

    triangles[#triangles + 1] = {
        a = a,
        b = b,
        c = c,
        f = math_max(e1.f, math_max(e2.f, e3.f)),
        expire = math_min(a.expire, math_min(b.expire, c.expire)),
    }
end

local function build_quad(upper_left, upper_right, lower_left, lower_right)
    if not upper_left or not upper_right or not lower_left or not lower_right then return false end

    local added = false
    local _, did_add
    _, did_add = maybe_add_edge(upper_left, upper_right); added = added or did_add
    _, did_add = maybe_add_edge(upper_left, lower_left); added = added or did_add
    _, did_add = maybe_add_edge(upper_right, lower_right); added = added or did_add
    _, did_add = maybe_add_edge(lower_left, lower_right); added = added or did_add

    local d_a = dot_distance(upper_left, lower_right)
    local d_b = dot_distance(upper_right, lower_left)

    if d_a <= d_b then
        local diagonal
        diagonal, did_add = maybe_add_edge(upper_left, lower_right)
        added = added or did_add
        if diagonal then
            maybe_add_triangle(upper_left, upper_right, lower_right)
            maybe_add_triangle(upper_left, lower_left, lower_right)
        end
    else
        local diagonal
        diagonal, did_add = maybe_add_edge(upper_right, lower_left)
        added = added or did_add
        if diagonal then
            maybe_add_triangle(upper_left, upper_right, lower_left)
            maybe_add_triangle(upper_right, lower_left, lower_right)
        end
    end
    return added
end

local function compact_live_geometry()
    local live_dot = {}
    local write = 1
    next_expire = math.huge

    for read = 1, #dots do
        local dot = dots[read]
        if dot.expire > clock then
            dots[write] = dot
            live_dot[dot.id] = true
            write = write + 1
            if dot.expire < next_expire then next_expire = dot.expire end
        end
    end
    for i = #dots, write, -1 do dots[i] = nil end

    clear_map(edge_by_key)
    write = 1
    for read = 1, #edges do
        local e = edges[read]
        if e.expire > clock and live_dot[e.a.id] and live_dot[e.b.id] then
            edges[write] = e
            edge_by_key[pair_key_ids(e.a, e.b)] = e
            write = write + 1
        end
    end
    for i = #edges, write, -1 do edges[i] = nil end

    write = 1
    for read = 1, #triangles do
        local tri = triangles[read]
        if tri.expire > clock and live_dot[tri.a.id] and live_dot[tri.b.id] and live_dot[tri.c.id] then
            triangles[write] = tri
            write = write + 1
        end
    end
    for i = #triangles, write, -1 do triangles[i] = nil end

    clear_map(cycle_segment_keys)
    write = 1
    for read = 1, #cycle_segments do
        local seg = cycle_segments[read]
        if seg.expire > clock and live_dot[seg.a.id] and live_dot[seg.b.id] then
            cycle_segments[write] = seg
            local key = pair_key_ids(seg.a, seg.b)
            cycle_segment_keys[key] = true
            write = write + 1
        end
    end
    for i = #cycle_segments, write, -1 do cycle_segments[i] = nil end

end

local function snapshot_scan_settings()
    scan_h_res = math_max(1, math_floor(setting("h_res")))
    scan_v_res = math_max(1, math_floor(setting("v_res")))
    scan_h_fov = setting("h_fov")
    scan_v_fov = setting("v_fov")
    scan_max_range = math_max(0.1, setting("max_range"))
    scan_dot_duration = math_max(0.1, setting("dot_duration"))
    scan_mesh_link_distance = math_max(0.01, setting("mesh_link_distance"))
    scan_max_dots = math_max(1, math_floor(setting("max_dots")))
    scan_recycle_oldest = setting("recycle_oldest") == true
    scan_max_epsilon = math_max(0, setting("max_epsilon"))
    scan_min_persistence = math_max(0, setting("min_persistence"))
    scan_max_cycles = math_max(0, math_floor(setting("max_cycles")))
    scan_dot_size = math_max(0, setting("dot_size"))
    scan_lines_per_dot = math_max(1, math_floor(setting("lines_per_dot")))
    scan_color_scheme = setting("color_scheme")
    scan_line_surface_lift = math_max(0, setting("line_surface_lift"))
end

local rebuild_step

local function start_rebuild(reanalyse)
    analysis_phase = "idle"
    reset_analysis_tables()
    compact_live_geometry()
    line_renderer:clear()
    rebuilding = true
    rebuild_reanalyse = reanalyse == true
    rebuild_stage = 1
    rebuild_index = 1
end

rebuild_step = function()
    local added = false

    while rebuild_stage <= 3 do
        local list
        local draw
        if rebuild_stage == 1 then
            list = dots
            draw = add_dot_lines
        elseif rebuild_stage == 2 then
            list = edges
            draw = add_mesh_line
        else
            list = cycle_segments
            draw = add_cycle_line
        end

        while rebuild_index <= #list do
            local draw_lines = rebuild_stage == 1 and scan_lines_per_dot or 1
            if not frame_budget.take_draw(draw_lines) then
                if added then line_renderer:dispatch() end
                return
            end
            draw(list[rebuild_index])
            rebuild_index = rebuild_index + 1
            added = true
        end

        if rebuild_index > #list then
            rebuild_stage = rebuild_stage + 1
            rebuild_index = 1
        end
    end

    if added or rebuild_stage > 3 then
        line_renderer:dispatch()
    end

    if rebuild_stage > 3 then
        rebuilding = false
        analysis_phase = "idle"
        if pending_scan_kind then
            local kind = pending_scan_kind
            pending_scan_kind = nil
            snapshot_scan_settings()
            scan_context = scan_pattern.context(kind)
            scanning = scan_context ~= nil
            scan_type = kind
            scan_row = 0
            scan_col = 0
            scan_prev_row = nil
            scan_current_row = nil
        elseif rebuild_reanalyse and #dots >= 4 and #edges >= 3 then
            analysis_phase = "prepare"
        end
        rebuild_reanalyse = false
    end
end

local function expire_oldest_to_target(target)
    local remove = #dots - target
    if remove <= 0 then return end
    for i = 1, remove do
        dots[i].expire = clock
    end
end

local function request_scan(kind)
    if rebuilding then
        pending_scan_kind = kind
        return
    end

    if scanning then
        pending_scan_kind = kind
        return
    end

    snapshot_scan_settings()
    analysis_phase = "idle"
    reset_analysis_tables()
    scan_context = scan_pattern.context(kind)
    if not scan_context then return end
    scanning = true
    scan_type = kind
    scan_row = 0
    scan_col = 0
    scan_prev_row = nil
    scan_current_row = nil
end

local function scan_step()
    local world = runtime.current_world()
    local physics_world = runtime.physics_world(world)
    if not physics_world then return end

    if not scan_context then
        scan_context = scan_pattern.context(scan_type)
        if not scan_context then return end
    end

    local ox, oy, oz = scan_pattern.origin_components(scan_context)
    if not ox then return end
    local h_res = scan_h_res
    local v_res = scan_v_res
    local h_fov = scan_h_fov
    local v_fov = scan_v_fov
    local max_range = scan_max_range
    local duration = scan_dot_duration

    local max_dots = scan_max_dots
    if #dots >= max_dots then
        if scan_recycle_oldest then
            expire_oldest_to_target(math_floor(max_dots * 0.9))
            start_rebuild()
            return
        else
            scanning = false
            analysis_phase = (#dots >= 4 and #edges >= 3) and "prepare" or "idle"
            return
        end
    end

    local expire = (math_floor((clock + duration) / EXPIRE_BUCKET) + 1) * EXPIRE_BUCKET
    local anything_added = false

    while scan_row < v_res do
        local col = scan_col
        local dot_lines = scan_lines_per_dot
        local mesh_line_reserve = (scan_type == "radial" and col == h_res - 1) and 5 or 3
        local draw_reserve = dot_lines + mesh_line_reserve
        if frame_budget.draw_remaining() < draw_reserve then break end
        if not frame_budget.take(8) or not frame_budget.take_draw(draw_reserve) then break end

        if not scan_current_row then scan_current_row = {} end
        local lines_before = line_renderer:line_count()
        local dx, dy, dz = scan_pattern.direction_components(
            scan_type, scan_row, col, h_res, v_res, h_fov, v_fov, scan_context
        )

        local x, y, z, hit_distance
        if dx then
            x, y, z, hit_distance = runtime.raycast_filtered(
                physics_world, ox, oy, oz, dx, dy, dz, max_range, COLLISION_FILTER
            )
        end

        local pixel_added = false
        if x then
            local dist_t = math_min((hit_distance or max_range) / max_range, 1)
            local dot = {
                id = next_dot_id,
                x = x, y = y, z = z,
                ox = ox, oy = oy, oz = oz,
                dist_t = dist_t,
                expire = expire,
            }
            next_dot_id = next_dot_id + 1
            dots[#dots + 1] = dot
            scan_current_row[col + 1] = dot

            add_dot_lines(dot)
            pixel_added = true
            anything_added = true
            if expire < next_expire then next_expire = expire end

            local left = col > 0 and scan_current_row[col] or nil
            local up_dot = scan_prev_row and scan_prev_row[col + 1] or nil
            local up_left = col > 0 and scan_prev_row and scan_prev_row[col] or nil

            local _, edge_added = maybe_add_edge(left, dot)
            pixel_added = pixel_added or edge_added
            _, edge_added = maybe_add_edge(up_dot, dot)
            pixel_added = pixel_added or edge_added
            if up_left and left and up_dot then
                pixel_added = build_quad(up_left, up_dot, left, dot) or pixel_added
            end
        end

        scan_col = scan_col + 1
        if scan_col >= h_res then
            if scan_type == "radial" then
                local first = scan_current_row[1]
                local last = scan_current_row[h_res]
                local _, seam_added = maybe_add_edge(last, first)
                pixel_added = pixel_added or seam_added
                if scan_prev_row then
                    local up_first = scan_prev_row[1]
                    local up_last = scan_prev_row[h_res]
                    if up_first and up_last and first and last then
                        pixel_added = build_quad(up_last, up_first, last, first) or pixel_added
                    end
                end
            end

            scan_prev_row = scan_current_row
            scan_current_row = nil
            scan_col = 0
            scan_row = scan_row + 1
        end

        if pixel_added then anything_added = true end

        local lines_used = line_renderer:line_count() - lines_before
        frame_budget.refund_draw(draw_reserve - lines_used)
    end

    if anything_added then
        line_renderer:dispatch()
    end

    if scan_row >= v_res then
        scanning = false
        scan_context = nil
        scan_col = 0
        scan_prev_row = nil
        scan_current_row = nil
        analysis_phase = (#dots >= 4 and #edges >= 3) and "prepare" or "idle"
        if pending_scan_kind then
            local kind = pending_scan_kind
            pending_scan_kind = nil
            request_scan(kind)
        end
    end
end

reset_analysis_tables = function()
    analysis_point_count = 0
    simplex_count = 0
    reduce_index = 1
    clear_array(analysis_points)
    clear_map(analysis_vertex_by_dot_id)
    clear_array(simplices)
    clear_array(vertex_index)
    clear_map(edge_index)
    clear_array(reduced_columns)
    clear_map(pivot_owner)
    clear_map(death_pair)
    clear_array(forest_parent)
    clear_array(forest_rank)
    clear_array(forest_adj)
    clear_map(h1_birth_edge)
    clear_array(intervals)
end

-- union find is just for knowing if an edge made a new loop or only joined components
local function uf_find(x)
    local p = forest_parent[x]
    while p ~= x do
        local gp = forest_parent[p]
        forest_parent[x] = gp
        x = p
        p = gp
    end
    return x
end

local function uf_union(a, b)
    local ra = uf_find(a)
    local rb = uf_find(b)
    if ra == rb then return false end

    local rank_a = forest_rank[ra]
    local rank_b = forest_rank[rb]
    if rank_a < rank_b then
        forest_parent[ra] = rb
    elseif rank_b < rank_a then
        forest_parent[rb] = ra
    else
        forest_parent[rb] = ra
        forest_rank[ra] = rank_a + 1
    end
    return true
end

local function forest_add_edge(a, b)
    local aa = forest_adj[a]
    if not aa then aa = {}; forest_adj[a] = aa end
    aa[#aa + 1] = b
    local bb = forest_adj[b]
    if not bb then bb = {}; forest_adj[b] = bb end
    bb[#bb + 1] = a
end

local function simplex_less(a, b)
    if a.f ~= b.f then return a.f < b.f end
    if a.dim ~= b.dim then return a.dim < b.dim end
    if a.a ~= b.a then return a.a < b.a end
    if (a.b or 0) ~= (b.b or 0) then return (a.b or 0) < (b.b or 0) end
    return (a.c or 0) < (b.c or 0)
end

local function prepare_analysis()
    reset_analysis_tables()

    for i = 1, #dots do
        local dot = dots[i]
        if dot.expire > clock then
            analysis_point_count = analysis_point_count + 1
            analysis_points[analysis_point_count] = dot
            analysis_vertex_by_dot_id[dot.id] = analysis_point_count
            simplex_count = simplex_count + 1
            simplices[simplex_count] = { dim = 0, f = 0, a = analysis_point_count }
        end
    end

    local max_epsilon = scan_max_epsilon

    for i = 1, #edges do
        local e = edges[i]
        if e.expire > clock and e.f <= max_epsilon + EPS then
            local a = analysis_vertex_by_dot_id[e.a.id]
            local b = analysis_vertex_by_dot_id[e.b.id]
            if a and b then
                simplex_count = simplex_count + 1
                simplices[simplex_count] = { dim = 1, f = e.f, a = a, b = b }
            end
        end
    end

    for i = 1, #triangles do
        local tri = triangles[i]
        if tri.expire > clock and tri.f <= max_epsilon + EPS then
            local a = analysis_vertex_by_dot_id[tri.a.id]
            local b = analysis_vertex_by_dot_id[tri.b.id]
            local c = analysis_vertex_by_dot_id[tri.c.id]
            if a and b and c then
                simplex_count = simplex_count + 1
                simplices[simplex_count] = { dim = 2, f = tri.f, a = a, b = b, c = c }
            end
        end
    end

    if analysis_point_count < 4 or simplex_count <= analysis_point_count then
        analysis_phase = "idle"
        reset_analysis_tables()
        return
    end

    -- lower filtration first and lower dim first so boundaries are already around when needed
    table_sort(simplices, simplex_less)

    for i = 1, analysis_point_count do
        forest_parent[i] = i
        forest_rank[i] = 0
        forest_adj[i] = {}
    end

    for i = 1, simplex_count do
        local s = simplices[i]
        if s.dim == 0 then
            vertex_index[s.a] = i
        elseif s.dim == 1 then
            edge_index[analysis_edge_key(s.a, s.b)] = i
            if uf_union(s.a, s.b) then
                forest_add_edge(s.a, s.b)
            else
                h1_birth_edge[i] = true
            end
        end
    end

    reduce_index = 1
    analysis_phase = "reduce"
end

-- mod 2 coefficients, so xor is the whole column add and duplicates just vanish
local function xor_sorted_into(a, b, out)
    clear_array(out)
    local ia, ib, io = 1, 1, 0
    local na, nb = #a, #b

    while ia <= na and ib <= nb do
        local va, vb = a[ia], b[ib]
        if va < vb then
            io = io + 1; out[io] = va; ia = ia + 1
        elseif vb < va then
            io = io + 1; out[io] = vb; ib = ib + 1
        else
            ia = ia + 1; ib = ib + 1
        end
    end
    while ia <= na do io = io + 1; out[io] = a[ia]; ia = ia + 1 end
    while ib <= nb do io = io + 1; out[io] = b[ib]; ib = ib + 1 end
end

local function copy_array(src)
    local dst = {}
    for i = 1, #src do dst[i] = src[i] end
    return dst
end

local function boundary_of(simplex, out)
    clear_array(out)
    if simplex.dim == 0 then return end

    if simplex.dim == 1 then
        local a = vertex_index[simplex.a]
        local b = vertex_index[simplex.b]
        if a < b then out[1], out[2] = a, b else out[1], out[2] = b, a end
        return
    end

    local e1 = edge_index[analysis_edge_key(simplex.a, simplex.b)]
    local e2 = edge_index[analysis_edge_key(simplex.a, simplex.c)]
    local e3 = edge_index[analysis_edge_key(simplex.b, simplex.c)]
    if not e1 or not e2 or not e3 then return end
    if e1 > e2 then e1, e2 = e2, e1 end
    if e2 > e3 then e2, e3 = e3, e2 end
    if e1 > e2 then e1, e2 = e2, e1 end
    out[1], out[2], out[3] = e1, e2, e3
end

local function reduce_one_column(j)
    local simplex = simplices[j]
    boundary_of(simplex, xor_a)
    local col = xor_a
    local tmp = xor_b

    -- last row is the pivot, keep cancelling it with the column that already owns it
    while #col > 0 do
        local pivot = col[#col]
        local owner = pivot_owner[pivot]
        if not owner then break end
        xor_sorted_into(col, reduced_columns[owner], tmp)
        col, tmp = tmp, col
    end

    if #col == 0 then
        reduced_columns[j] = {}
    else
        local stored = copy_array(col)
        reduced_columns[j] = stored
        local pivot = stored[#stored]
        pivot_owner[pivot] = j
        death_pair[pivot] = j
    end
end

local function reduction_steps(budget)
    local done = 0
    while reduce_index <= simplex_count and done < budget and frame_budget.time_available() do
        reduce_one_column(reduce_index)
        reduce_index = reduce_index + 1
        done = done + 1
    end
    if reduce_index > simplex_count then
        analysis_phase = "extract"
    end
end

local function add_cycle_segment(a_index, b_index, censored, persistence, max_epsilon)
    local a = analysis_points[a_index]
    local b = analysis_points[b_index]
    if not a or not b then return false end

    local key = pair_key_ids(a, b)
    if cycle_segment_keys[key] then return false end

    local seg = {
        a = a,
        b = b,
        expire = math_min(a.expire, b.expire),
        censored = censored,
        strong = persistence >= max_epsilon * 0.18,
    }
    cycle_segments[#cycle_segments + 1] = seg
    cycle_segment_keys[key] = true
    add_cycle_line(seg)
    return true
end

local path_parent = {}
local path_queue = {}

local function draw_fundamental_cycle(edge_simplex, censored, persistence, max_epsilon)
    local start = edge_simplex.a
    local goal = edge_simplex.b
    clear_map(path_parent)
    clear_array(path_queue)

    local head, tail = 1, 1
    path_queue[1] = start
    path_parent[start] = 0

    while head <= tail do
        local v = path_queue[head]
        head = head + 1
        if v == goal then break end
        local adj = forest_adj[v]
        for i = 1, #adj do
            local n = adj[i]
            if path_parent[n] == nil then
                path_parent[n] = v
                tail = tail + 1
                path_queue[tail] = n
            end
        end
    end

    if path_parent[goal] == nil then return end

    local v = goal
    while v ~= start do
        local parent = path_parent[v]
        add_cycle_segment(parent, v, censored, persistence, max_epsilon)
        v = parent
    end
    add_cycle_segment(start, goal, censored, persistence, max_epsilon)
end

local function draw_reduced_cycle(rows, censored, persistence, max_epsilon)
    for i = 1, #rows do
        local simplex = simplices[rows[i]]
        if simplex and simplex.dim == 1 then
            add_cycle_segment(simplex.a, simplex.b, censored, persistence, max_epsilon)
        end
    end
end

local function refresh_result_lifetime()
    local duration = scan_dot_duration
    local expire = (math_floor((clock + duration) / EXPIRE_BUCKET) + 1) * EXPIRE_BUCKET
    next_expire = expire
    for i = 1, #dots do dots[i].expire = expire end
    for i = 1, #edges do edges[i].expire = expire end
    for i = 1, #triangles do triangles[i].expire = expire end
    for i = 1, #cycle_segments do cycle_segments[i].expire = expire end
end

local function extract_cycles()
    clear_array(intervals)
    local min_persistence = scan_min_persistence
    local max_epsilon = scan_max_epsilon

    for birth_i in pairs(h1_birth_edge) do
        local birth = simplices[birth_i]
        local death_i = death_pair[birth_i]
        local persistence
        local censored

        if death_i then
            local death = simplices[death_i]
            if death and death.dim == 2 then
                persistence = death.f - birth.f
                censored = false
            end
        else
            -- it never died inside this scan range, use the cutoff as a display lifetime instead of infinity
            persistence = max_epsilon - birth.f
            censored = true
        end

        if persistence and persistence >= min_persistence then
            intervals[#intervals + 1] = {
                birth_i = birth_i,
                death_i = death_i,
                persistence = persistence,
                censored = censored,
            }
        end
    end

    table_sort(intervals, function(a, b)
        if a.persistence ~= b.persistence then return a.persistence > b.persistence end
        return a.birth_i < b.birth_i
    end)

    local before = #cycle_segments
    local max_cycles = scan_max_cycles
    local count = math_min(#intervals, max_cycles)
    for i = 1, count do
        local interval = intervals[i]
        local birth = simplices[interval.birth_i]
        if interval.death_i then
            draw_reduced_cycle(reduced_columns[interval.death_i], false, interval.persistence, max_epsilon)
        else
            draw_fundamental_cycle(birth, true, interval.persistence, max_epsilon)
        end
    end

    if #cycle_segments > before then
        line_renderer:dispatch()
    end

    refresh_result_lifetime()
    analysis_phase = "idle"
    reset_analysis_tables()
end

function api.update(dt)
    sync_clock(dt)

    if line_renderer:has_pending_dispatch() then line_renderer:dispatch() end

    if rebuilding then
        rebuild_step()
        return
    end

    if scanning then scan_step() end

    if clock >= next_expire and not scanning and analysis_phase == "idle" then
        start_rebuild(true)
        return
    end

    if scanning then return end

    if analysis_phase == "prepare" then
        prepare_analysis()
    elseif analysis_phase == "reduce" then
        local budget = frame_budget.claim_items(1, ANALYSIS_COLUMNS_PER_FRAME)
        if budget > 0 then reduction_steps(budget) end
    elseif analysis_phase == "extract" then
        extract_cycles()
    end
end

function api.trigger(kind)
    request_scan(kind == "radial" and "radial" or "fov")
end

function api.hide()
    sync_clock(0)
    scanning = false
    pending_scan_kind = nil
    rebuilding = false
    rebuild_reanalyse = false
    analysis_phase = "idle"
    scan_row = 0
    scan_col = 0
    scan_prev_row = nil
    scan_current_row = nil
    scan_context = nil
    reset_analysis_tables()
    line_renderer:clear()
end

function api.show()
    sync_clock(0)
    if #dots > 0 and not rebuilding then start_rebuild() end
end

function api.clear()
    scanning = false
    pending_scan_kind = nil
    rebuilding = false
    rebuild_reanalyse = false
    analysis_phase = "idle"
    scan_row = 0
    scan_col = 0
    scan_prev_row = nil
    scan_current_row = nil
    scan_context = nil
    dots = {}
    next_dot_id = 1
    edges = {}
    triangles = {}
    cycle_segments = {}
    clear_map(edge_by_key)
    clear_map(cycle_segment_keys)
    next_expire = math.huge
    reset_analysis_tables()
    line_renderer:clear()
end

function api.reset_all(keep_drawing)
    scanning = false
    pending_scan_kind = nil
    rebuilding = false
    rebuild_reanalyse = false
    analysis_phase = "idle"
    scan_row = 0
    scan_col = 0
    scan_prev_row = nil
    scan_current_row = nil
    scan_context = nil
    dots = {}
    next_dot_id = 1
    edges = {}
    triangles = {}
    cycle_segments = {}
    clear_map(edge_by_key)
    clear_map(cycle_segment_keys)
    next_expire = math.huge
    reset_analysis_tables()
    if not keep_drawing then line_renderer:clear() end
end

function api.on_game_state_changed(status, state_name)
    if state_name == "StateGameplay" and status == "exit" then
        api.reset_all(true)
        line_renderer:destroy()
    end
end

function api.destroy()
    api.reset_all(false)
    line_renderer:destroy()
end

return api
