local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget

local factory = {}

local math_abs = math.abs
local math_floor = math.floor
local math_sqrt = math.sqrt
local tonumber = tonumber
local tostring = tostring
local type = type
local pcall = pcall
local pairs = pairs

local BUCKET_CELL_SIZE = 12
local BUCKET_OFFSET = 32768
local BUCKET_STRIDE = 65536
local MAX_VALID_COORDINATE = 100000

local function clear_array(t)
    for i = #t, 1, -1 do t[i] = nil end
end

local function is_valid_coordinate(v)
    return type(v) == "number" and v == v and v > -MAX_VALID_COORDINATE and v < MAX_VALID_COORDINATE
end

local function squared_distance_2d(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return dx * dx + dy * dy
end

local function bucket_key(x, y)
    local cx = math_floor(x / BUCKET_CELL_SIZE)
    local cy = math_floor(y / BUCKET_CELL_SIZE)
    return (cx + BUCKET_OFFSET) * BUCKET_STRIDE + (cy + BUCKET_OFFSET)
end

function factory.new()
    local cache = {}
    local phase = "idle"
    local world = nil
    local tile_count = 0
    local tile_index = 1
    local triangle_index = 1
    local current_tile_triangles = nil

    local data = {
        ax = {}, ay = {}, az = {},
        bx = {}, by = {}, bz = {},
        cx = {}, cy = {}, cz = {},
        mx = {}, my = {}, mz = {},
        radius = {},
        count = 0,
        buckets = {},
    }

    local function reset_data()
        data.count = 0
        clear_array(data.ax); clear_array(data.ay); clear_array(data.az)
        clear_array(data.bx); clear_array(data.by); clear_array(data.bz)
        clear_array(data.cx); clear_array(data.cy); clear_array(data.cz)
        clear_array(data.mx); clear_array(data.my); clear_array(data.mz)
        clear_array(data.radius)
        data.buckets = {}
    end

    function cache:reset()
        phase = "idle"
        world = nil
        tile_count = 0
        tile_index = 1
        triangle_index = 1
        current_tile_triangles = nil
        reset_data()
    end

    function cache:world()
        return world
    end

    function cache:phase()
        return phase
    end

    function cache:data()
        return data
    end

    function cache:begin(nav_world)
        self:reset()
        world = nav_world

        local gw = GwNavWorld
        if not gw
            or type(gw.build_database_visual_representation) ~= "function"
            or type(gw.database_tile_count) ~= "function"
            or type(gw.database_tile_triangle_count) ~= "function"
            or type(gw.database_triangle) ~= "function" then
            phase = "failed"
            mod:warning("Navmesh geodesics: GwNavWorld database API is unavailable.")
            return false
        end

        local ok, err = pcall(function()
            gw.build_database_visual_representation(nav_world)
            tile_count = tonumber(gw.database_tile_count(nav_world)) or 0
        end)

        if not ok or tile_count <= 0 then
            phase = "failed"
            mod:warning("Navmesh geodesics: could not initialize navmesh database: " .. tostring(err or tile_count))
            return false
        end

        tile_index = 1
        triangle_index = 1
        current_tile_triangles = nil
        phase = "extract"
        return true
    end

    local function add_triangle(a, b, c)
        local x1, y1, z1 = a.x, a.y, a.z
        local x2, y2, z2 = b.x, b.y, b.z
        local x3, y3, z3 = c.x, c.y, c.z

        if not (is_valid_coordinate(x1) and is_valid_coordinate(y1) and is_valid_coordinate(z1)
            and is_valid_coordinate(x2) and is_valid_coordinate(y2) and is_valid_coordinate(z2)
            and is_valid_coordinate(x3) and is_valid_coordinate(y3) and is_valid_coordinate(z3)) then
            return
        end

        local i = data.count + 1
        data.count = i
        data.ax[i], data.ay[i], data.az[i] = x1, y1, z1
        data.bx[i], data.by[i], data.bz[i] = x2, y2, z2
        data.cx[i], data.cy[i], data.cz[i] = x3, y3, z3

        local mx = (x1 + x2 + x3) / 3
        local my = (y1 + y2 + y3) / 3
        local mz = (z1 + z2 + z3) / 3
        data.mx[i], data.my[i], data.mz[i] = mx, my, mz

        local r2 = squared_distance_2d(x1, y1, mx, my)
        local candidate = squared_distance_2d(x2, y2, mx, my)
        if candidate > r2 then r2 = candidate end
        candidate = squared_distance_2d(x3, y3, mx, my)
        if candidate > r2 then r2 = candidate end
        data.radius[i] = math_sqrt(r2)

        local key = bucket_key(mx, my)
        local bucket = data.buckets[key]
        if not bucket then
            bucket = {}
            data.buckets[key] = bucket
        end
        bucket[#bucket + 1] = i
    end

    local function extract_chunk(budget)
        local gw = GwNavWorld
        local database_tile_triangle_count = gw.database_tile_triangle_count
        local database_triangle = gw.database_triangle
        local script = Script
        local temp_byte_count = script and script.temp_byte_count
        local set_temp_byte_count = script and script.set_temp_byte_count
        if not set_temp_byte_count then temp_byte_count = nil end

        local remaining = budget
        while remaining > 0 and tile_index <= tile_count and frame_budget.time_available() do
            if current_tile_triangles == nil then
                current_tile_triangles = tonumber(database_tile_triangle_count(world, tile_index)) or 0
                triangle_index = 1
            end

            if triangle_index > current_tile_triangles then
                tile_index = tile_index + 1
                current_tile_triangles = nil
            else
                local temp_size = temp_byte_count and temp_byte_count()
                local ok_triangle, a, b, c = pcall(database_triangle, world, tile_index, triangle_index)

                if temp_size then set_temp_byte_count(temp_size) end
                if not ok_triangle then error(a) end
                if a and b and c then add_triangle(a, b, c) end

                triangle_index = triangle_index + 1
                remaining = remaining - 1
            end
        end
    end

    function cache:update(budget)
        if phase ~= "extract" or budget <= 0 then return end

        local ok, err = pcall(extract_chunk, budget)
        if not ok then
            phase = "failed"
            reset_data()
            mod:warning("Navmesh geodesics: navmesh extraction failed: " .. tostring(err))
            return
        end

        if tile_index > tile_count then
            if data.count > 0 then
                phase = "ready"
            else
                phase = "failed"
                reset_data()
                mod:warning("Navmesh geodesics: navmesh database contained no readable triangles.")
            end
        end
    end

    function cache:collect_candidates(x, y, z, radius, out)
        for i = #out, 1, -1 do out[i] = nil end

        local vertical = radius
        local min_cx = math_floor((x - radius) / BUCKET_CELL_SIZE)
        local max_cx = math_floor((x + radius) / BUCKET_CELL_SIZE)
        local min_cy = math_floor((y - radius) / BUCKET_CELL_SIZE)
        local max_cy = math_floor((y + radius) / BUCKET_CELL_SIZE)

        for cx = min_cx, max_cx do
            local column = (cx + BUCKET_OFFSET) * BUCKET_STRIDE
            for cy = min_cy, max_cy do
                local bucket = data.buckets[column + (cy + BUCKET_OFFSET)]
                if bucket then
                    for j = 1, #bucket do
                        local tri = bucket[j]
                        local dx = data.mx[tri] - x
                        local dy = data.my[tri] - y
                        local reach = radius + data.radius[tri]
                        if dx * dx + dy * dy <= reach * reach
                            and math_abs(data.mz[tri] - z) <= vertical then
                            out[#out + 1] = tri
                        end
                    end
                end
            end
        end
    end

    return cache
end

return factory
