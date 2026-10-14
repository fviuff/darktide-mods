local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")
local retained_line_chunks = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RetainedLineChunks")
local builder = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/ProceduralMathBuilder")

local api = {}

local LINES_PER_CHUNK = 512
local WORK_PER_LINE = 2

local visible_renderer = retained_line_chunks.new(LINES_PER_CHUNK)
local build_renderer = nil
local co = nil
local phase = 0
local world_owner = nil
local last_lines = 0

local cfg_pattern = settings.defaults.proc_pattern
local cfg_scale = settings.defaults.proc_scale
local cfg_detail = settings.defaults.proc_detail
local cfg_distance = settings.defaults.proc_distance
local cfg_color = settings.defaults.proc_color

local function current_world() return runtime.current_world() end

local function refresh_config()
    cfg_pattern = settings.get("proc_pattern")
    cfg_scale = math.max(0.1, settings.number("proc_scale"))
    cfg_detail = math.max(0.5, math.min(4, settings.number("proc_detail")))
    cfg_distance = math.max(1, settings.number("proc_distance"))
    cfg_color = settings.get("proc_color")
end

local function palette_rgb()
    if cfg_color == "amber" then return 255,180,45 end
    if cfg_color == "white" then return 230,230,230 end
    if cfg_color == "toxin" then return 90,235,110 end
    return 70,220,255
end

local function destroy_build()
    co = nil
    if build_renderer then build_renderer:clear() end
    build_renderer = nil
end

local function world_point(ax, ay, az, frame, x, y, z)
    local s = cfg_scale
    if frame then

        return ax + s*(frame.rx*x + frame.ux*y + frame.fx*z),
            ay + s*(frame.ry*x + frame.uy*y + frame.fy*z),
            az + s*(frame.rz*x + frame.uz*y + frame.fz*z)
    end
    return ax+s*x, ay+s*y, az+s*z
end

local anchor_x, anchor_y, anchor_z, anchor_frame

local function start_build(randomize)
    local world = current_world()
    if not world then
        return false
    end
    if world_owner and world_owner ~= world then
        visible_renderer:clear()
        destroy_build()
    end
    world_owner = world
    refresh_config()
    if randomize then phase = phase + 1 end

    local x,y,z,frame = runtime.visual_anchor(cfg_distance)
    if not x then
        return false
    end
    anchor_x,anchor_y,anchor_z,anchor_frame=x,y,z,frame

    destroy_build()
    build_renderer = retained_line_chunks.new(LINES_PER_CHUNK)
    co = builder.new(cfg_pattern, cfg_detail, phase)
    return true
end

local function finish_build()
    if not build_renderer then return end
    last_lines = build_renderer:line_count()
    if last_lines > 0 and not build_renderer:dispatch() then return false end
    visible_renderer:clear()
    if last_lines > 0 then
        visible_renderer = build_renderer
    else
        build_renderer:clear()
    end
    build_renderer=nil
    co=nil
    return true
end

local function build_step()
    if not co then
        if build_renderer and build_renderer:has_pending_dispatch() then finish_build() end
        return
    end

    local max_items = nil
    if frame_budget.draw_limited() then max_items = math.floor(frame_budget.draw_remaining()) end
    local items = frame_budget.claim_items(WORK_PER_LINE, max_items)
    if items <= 0 then return end
    local r,g,b = palette_rgb()
    for _=1,items do
        if not frame_budget.time_available() then return end
        if coroutine.status(co)=="dead" then
            finish_build()
            return
        end
        if not frame_budget.take_draw(1) then return end
        local ok,ax,ay,az,bx,by,bz = coroutine.resume(co)
        if not ok then
            frame_budget.refund_draw(1)
            if mod.error then mod:error("Equation / Geometry Visualizer failed: %s", tostring(ax)) end
            destroy_build()
            return
        end
        if ax == nil then
            frame_budget.refund_draw(1)
            finish_build()
            return
        end
        local awx,awy,awz=world_point(anchor_x,anchor_y,anchor_z,anchor_frame,ax,ay,az)
        local bwx,bwy,bwz=world_point(anchor_x,anchor_y,anchor_z,anchor_frame,bx,by,bz)
        if not build_renderer:add_line_rgb_xyz(r,g,b,awx,awy,awz,bwx,bwy,bwz) then
            frame_budget.refund_draw(1)
            return
        end
    end
end

function api.trigger(kind)
    start_build(kind=="radial")
end

function api.update(_dt)
    local world=current_world()
    if world_owner and world_owner~=world then
        visible_renderer:clear(); destroy_build(); world_owner=world
        return
    end
    if not world then return end
    world_owner=world
    build_step()
end

function api.clear()
    destroy_build(); visible_renderer:clear(); last_lines=0
end

function api.hide()
    destroy_build(); visible_renderer:clear()
end

function api.show()

end

function api.reset_all(_keep_drawing)
    api.clear(); world_owner=nil
end

function api.destroy() api.reset_all(false) end


function api.on_game_state_changed(status,state_name)
    if state_name=="StateGameplay" and status=="exit" then api.reset_all(false) end
end


return api
