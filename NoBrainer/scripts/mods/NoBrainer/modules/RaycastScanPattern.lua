local mod = get_mod("NoBrainer")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")

local M = {}
local math_cos, math_max, math_pi, math_sin, math_tan, math_sqrt = math.cos, math.max, math.pi, math.sin, math.tan, math.sqrt
local RADIAL_MIN_PITCH = math.rad(-85)
local RADIAL_MAX_PITCH = math.rad(85)

function M.context(kind)
    if kind == "radial" then
        local ox, oy, oz = runtime.radial_origin()
        return ox and {ox=ox, oy=oy, oz=oz} or nil
    end
    return runtime.camera_frame()
end

function M.origin_components(context)
    if not context then return nil end
    return context.ox, context.oy, context.oz
end


function M.direction_components(kind,row,col,h_res,v_res,h_fov_deg,v_fov_deg,context)
    if not context then return nil end
    if kind == "radial" then
        local v_den = math_max(v_res-1,1)
        local pitch = RADIAL_MIN_PITCH + (RADIAL_MAX_PITCH-RADIAL_MIN_PITCH)*(row/v_den)
        local yaw = 2*math_pi*(col/h_res)
        local cp = math_cos(pitch)
        return cp*math_cos(yaw), cp*math_sin(yaw), math_sin(pitch)
    end

    local v_den = math_max(v_res-1,1)
    local h_den = math_max(h_res-1,1)
    local vt = 2*(row/v_den)-1
    local ht = 2*(col/h_den)-1
    local hs = ht*math_tan(math.rad(h_fov_deg)*0.5)
    local vs = -vt*math_tan(math.rad(v_fov_deg)*0.5)
    local x = context.fx + context.rx*hs + context.ux*vs
    local y = context.fy + context.ry*hs + context.uy*vs
    local z = context.fz + context.rz*hs + context.uz*vs
    local l2=x*x+y*y+z*z
    if l2<=1e-20 then return context.fx,context.fy,context.fz end
    local inv=1/math_sqrt(l2)
    return x*inv,y*inv,z*inv
end


return M
