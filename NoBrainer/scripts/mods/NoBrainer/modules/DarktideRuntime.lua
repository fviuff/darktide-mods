local mod = get_mod("NoBrainer")
local math3d = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/StingrayMath")

local M = {}

local pcall = pcall
local tonumber = tonumber
local math_sqrt = math.sqrt

local Managers_ref = Managers
local PhysicsWorld_raycast = PhysicsWorld.raycast
local World_physics_world = World.physics_world
local Matrix4x4_translation = Matrix4x4.translation
local Matrix4x4_rotation = Matrix4x4.rotation
local Matrix4x4_forward = Matrix4x4.forward
local Matrix4x4_right = Matrix4x4.right
local Matrix4x4_up = Matrix4x4.up
local Quaternion_forward = Quaternion and Quaternion.forward
local Quaternion_right = Quaternion and Quaternion.right
local Quaternion_up = Quaternion and Quaternion.up
local Unit_alive = Unit.alive
local Unit_world_position = Unit.world_position

local safe_elements = math3d.from_engine


local function current_world()
    local manager = Managers_ref.world
    if not manager or not manager.world then return nil end
    local ok, world = pcall(manager.world, manager, "level_world")
    return ok and world or nil
end
M.current_world = current_world

function M.physics_world(world)
    world = world or current_world()
    if not world then return nil end
    local ok, pw = pcall(World_physics_world, world)
    if ok then return pw end
    return nil
end

local function local_player()
    local manager = Managers_ref.player
    if not manager or not manager.local_player then return nil end
    local ok, player = pcall(manager.local_player, manager, 1)
    return ok and player or nil
end

local function camera_pose()
    local player = local_player()
    if not player then return nil end
    local state = Managers_ref.state
    local camera_manager = state and state.camera
    if not camera_manager then return nil end
    local viewport_name = player.viewport_name
    if not viewport_name then return nil end
    if camera_manager.has_viewport then
        local ok_view, has_view = pcall(camera_manager.has_viewport, camera_manager, viewport_name)
        if not ok_view or not has_view then return nil end
    end
    if not camera_manager.camera_pose then return nil end
    local ok, pose = pcall(camera_manager.camera_pose, camera_manager, viewport_name)
    return ok and pose or nil
end

function M.camera_frame()
    local pose = camera_pose()
    if not pose then return nil end

    local ok_o, origin = pcall(Matrix4x4_translation, pose)
    if not ok_o or not origin then return nil end

    -- camera basis moved around a bit, quaternion path first then matrix path as fallback
    local forward, right, up
    local ok_r, rotation = false, nil
    if Matrix4x4_rotation then ok_r, rotation = pcall(Matrix4x4_rotation, pose) end
    if ok_r and rotation and Quaternion_forward and Quaternion_right and Quaternion_up then
        local ok_f, f = pcall(Quaternion_forward, rotation)
        local ok_x, r = pcall(Quaternion_right, rotation)
        local ok_u, u = pcall(Quaternion_up, rotation)
        if ok_f and ok_x and ok_u then forward, right, up = f, r, u end
    end

    if not forward and Matrix4x4_forward and Matrix4x4_right and Matrix4x4_up then
        local ok_f, f = pcall(Matrix4x4_forward, pose)
        local ok_x, r = pcall(Matrix4x4_right, pose)
        local ok_u, u = pcall(Matrix4x4_up, pose)
        if ok_f and ok_x and ok_u then forward, right, up = f, r, u end
    end
    if not forward then return nil end

    local ox, oy, oz = safe_elements(origin)
    local fx, fy, fz = safe_elements(forward)
    local rx, ry, rz = safe_elements(right)
    local ux, uy, uz = safe_elements(up)
    if not ox or not fx or not rx or not ux then return nil end

    return {
        ox = ox, oy = oy, oz = oz,
        fx = fx, fy = fy, fz = fz,
        rx = rx, ry = ry, rz = rz,
        ux = ux, uy = uy, uz = uz,
    }
end

function M.player_position()
    local player = local_player()
    local unit = player and player.player_unit
    if not unit or not Unit_alive(unit) then return nil end
    local ok, position = pcall(Unit_world_position, unit, 1)
    if not ok or not position then return nil end
    return safe_elements(position)
end

function M.radial_origin()
    local player = local_player()
    local unit = player and player.player_unit
    if unit and Unit_alive(unit) then
        local ok, position = pcall(Unit_world_position, unit, 1)
        if ok and position then
            local x, y, z = safe_elements(position)
            if x then return x, y, z + 1.2 end
        end
    end
    local frame = M.camera_frame()
    if frame then return frame.ox, frame.oy, frame.oz end
    return nil
end

local vector = math3d.to_engine

local function raycast_numeric(physics_world, ox, oy, oz, dx, dy, dz, max_range, collision_filter, orient_toward_origin)
    if not physics_world then return nil end
    local dl2 = dx*dx + dy*dy + dz*dz
    if dl2 <= 1e-20 then return nil end
    local inv = 1 / math_sqrt(dl2)
    dx, dy, dz = dx*inv, dy*inv, dz*inv

    local origin = vector(ox, oy, oz)
    local direction = vector(dx, dy, dz)
    if not origin or not direction then return nil end

    local ok, hit, position, hit_distance, normal
    if collision_filter then
        ok, hit, position, hit_distance, normal = pcall(
            PhysicsWorld_raycast,
            physics_world,
            origin,
            direction,
            max_range,
            "closest", "types", "both", "collision_filter", collision_filter
        )
    else
        ok, hit, position, hit_distance, normal = pcall(
            PhysicsWorld_raycast,
            physics_world,
            origin,
            direction,
            max_range,
            "closest", "types", "statics"
        )
    end
    if not ok or not hit or not position then return nil end

    local px, py, pz = safe_elements(position)
    if not px then return nil end

    local hx, hy, hz = px-ox, py-oy, pz-oz
    local projected = hx*dx + hy*dy + hz*dz
    -- engine hit distance has not always been trustworthy here, projection is the sane fallback
    local distance = tonumber(hit_distance)
    if not distance or distance <= 1e-6 then distance = projected end
    if distance <= 1e-6 then distance = math_sqrt(hx*hx + hy*hy + hz*hz) end
    if distance <= 1e-6 or distance > max_range + 0.25 then return nil end

    local nx, ny, nz = safe_elements(normal)
    if not nx then
        nx, ny, nz = -dx, -dy, -dz
    else
        local nl2 = nx*nx + ny*ny + nz*nz
        if nl2 <= 1e-20 then
            nx, ny, nz = -dx, -dy, -dz
        else
            local ni = 1 / math_sqrt(nl2)
            nx, ny, nz = nx*ni, ny*ni, nz*ni
            if orient_toward_origin ~= false and dx*nx + dy*ny + dz*nz > 0 then
                nx, ny, nz = -nx, -ny, -nz
            end
        end
    end

    return px, py, pz, distance, nx, ny, nz, dx, dy, dz
end

function M.raycast_static(physics_world, ox, oy, oz, dx, dy, dz, max_range, orient_toward_origin)
    return raycast_numeric(
        physics_world, ox, oy, oz, dx, dy, dz, max_range, nil, orient_toward_origin
    )
end

function M.raycast_filtered(physics_world, ox, oy, oz, dx, dy, dz, max_range, collision_filter, orient_toward_origin)
    if not collision_filter or collision_filter == "" then return nil end
    return raycast_numeric(
        physics_world, ox, oy, oz, dx, dy, dz, max_range, collision_filter, orient_toward_origin
    )
end

function M.visual_anchor(distance)
    distance = tonumber(distance) or 4
    local frame = M.camera_frame()
    if frame then
        return frame.ox + frame.fx*distance,
            frame.oy + frame.fy*distance,
            frame.oz + frame.fz*distance,
            frame
    end
    local x, y, z = M.radial_origin()
    if x then return x, y, z, nil end
    return nil
end

return M
