local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local scan_pattern = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RaycastScanPattern")
local sparse_tsdf = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/SparseTsdfVolume")
local dual_contouring = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DualContouring")
local retained_line_chunks = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RetainedLineChunks")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")

local api = {}

local math_floor = math.floor
local math_max = math.max
local pcall = pcall

local LINES_PER_CHUNK = 512
local RAY_WORK_COST = 12
local EXTRACT_WORK_COST = 2

local volume = nil
local extractor = nil
local visible_renderer = retained_line_chunks.new(LINES_PER_CHUNK)
local build_renderer = nil
local world_owner = nil

local scan_active = false
local scan_kind = "fov"
local scan_context = nil
local scan_row = 0
local scan_col = 0
local scan_changed_volume = false
local last_scan_hits = 0

local cfg_voxel = settings.defaults.tsdf_voxel_size
local cfg_mu = settings.defaults.tsdf_truncation
local cfg_max_voxels = settings.defaults.tsdf_max_voxels
local cfg_color = settings.defaults.tsdf_color

local function palette_rgb()
    if cfg_color == "amber" then return 255,180,45 end
    if cfg_color == "white" then return 230,230,230 end
    if cfg_color == "toxin" then return 90,235,110 end
    return 70,220,255
end

local function current_world() return runtime.current_world() end
local function runtime_warning(text)
    if mod.warning then pcall(mod.warning, mod, "[NoBrainer] " .. text) end
end

local function refresh_config()

    cfg_voxel = math_max(0.02, settings.number("tsdf_voxel_size"))
    cfg_mu = math_max(0.02, settings.number("tsdf_truncation"))
    cfg_max_voxels = math_max(8, math_floor(settings.number("tsdf_max_voxels")))
    cfg_color = settings.get("tsdf_color")
end

local function ensure_volume()
    if not volume then
        refresh_config()
        volume = sparse_tsdf.new(cfg_voxel, cfg_mu, cfg_max_voxels)
    end
    return volume
end

local function cancel_extraction()
    if extractor then extractor:clear() end
    extractor = nil
    if build_renderer then build_renderer:clear() end
    build_renderer = nil
end

local function start_extraction()
    cancel_extraction()
    local v = ensure_volume()
    if v.count <= 0 then
        visible_renderer:clear()
        return
    end
    extractor = dual_contouring.new(v)
    build_renderer = retained_line_chunks.new(LINES_PER_CHUNK)
end

local function stop_scan(extract_partial)
    local had_changes = scan_changed_volume
    scan_active = false
    scan_context = nil
    scan_row, scan_col = 0, 0
    scan_changed_volume = false
    if extract_partial and had_changes then start_extraction() end
end

local function reset_all_state(clear_volume)
    stop_scan(false)
    cancel_extraction()
    visible_renderer:clear()
    if clear_volume and volume then volume:clear() end
    if clear_volume then volume = nil end
end

local function advance_pixel(h_res, v_res)
    scan_col = scan_col + 1
    if scan_col >= h_res then
        scan_col = 0
        scan_row = scan_row + 1
    end
    if scan_row >= v_res then
        scan_active = false
        scan_context = nil
        scan_row, scan_col = 0, 0
        if scan_changed_volume then
            start_extraction()
        elseif last_scan_hits == 0 then
            runtime_warning("TSDF scan received zero static collision hits. Check ray range / current world before tuning reconstruction settings.")
        end
        scan_changed_volume = false
    end
end

local function scan_step()
    local world = current_world()
    if not world then return end
    local physics_world = runtime.physics_world(world)
    if not physics_world then return end

    local h_res = math_max(1, math_floor(settings.number("h_res")))
    local v_res = math_max(1, math_floor(settings.number("v_res")))
    local h_fov = settings.number("h_fov")
    local v_fov = settings.number("v_fov")
    local max_range = math_max(0.1, settings.number("max_range"))
    local v = ensure_volume()
    local ox,oy,oz = scan_pattern.origin_components(scan_context)
    if not ox then stop_scan(false); return end

    local budget = frame_budget.claim_items(RAY_WORK_COST)
    while scan_active and budget > 0 and frame_budget.time_available() do
        local dx,dy,dz = scan_pattern.direction_components(scan_kind,scan_row,scan_col,h_res,v_res,h_fov,v_fov,scan_context)
        if not dx then stop_scan(false); return end
        local px,_,_,hit_distance,nx,ny,nz,rdx,rdy,rdz = runtime.raycast_static(physics_world,ox,oy,oz,dx,dy,dz,max_range)
        if px then
            last_scan_hits=last_scan_hits+1
            if v:integrate_ray(ox,oy,oz,rdx,rdy,rdz,hit_distance,nx,ny,nz) then scan_changed_volume=true end
        end
        advance_pixel(h_res,v_res)
        budget=budget-1
    end
end

local function drain_extracted_segments()
    if not extractor or extractor:segments_remaining() <= 0 then return true end
    local r,g,b = palette_rgb()
    while extractor:segments_remaining() > 0 do
        if not frame_budget.take_draw(1) then return false end
        local ax, ay, az, bx, by, bz = extractor:next_segment()
        if not ax then
            frame_budget.refund_draw(1)
            return true
        end
        if not build_renderer:add_line_rgb_xyz(r,g,b, ax, ay, az, bx, by, bz) then
            frame_budget.refund_draw(1)
            return false
        end
    end
    return true
end

local function extraction_step()
    if not extractor then return end

    if not drain_extracted_segments() then return end

    if not extractor:is_done() then
        local max_items = nil
        if frame_budget.draw_limited() then
            max_items = math_max(32, math_floor(frame_budget.draw_remaining()))
        end
        local budget = frame_budget.claim_items(EXTRACT_WORK_COST, max_items)
        if budget > 0 then extractor:step(budget) end
    end

    if not drain_extracted_segments() then return end

    if extractor:is_done() and extractor:segments_remaining() == 0 then

        local line_count = build_renderer:line_count()
        if line_count == 0 and last_scan_hits > 0 then
            runtime_warning("TSDF fused " .. tostring(last_scan_hits) .. " hits into " .. tostring(volume and volume.count or 0) .. " samples but Dual Contouring produced zero lines. Increase truncation distance or reduce voxel size, then rescan.")
        end
        if line_count > 0 and not build_renderer:dispatch() then return end

        visible_renderer:clear()
        if line_count > 0 then
            visible_renderer = build_renderer
        else
            build_renderer:clear()
        end
        build_renderer = nil
        extractor:clear()
        extractor = nil
    end
end

function api.trigger(kind)
    local world = current_world()
    if not world then runtime_warning("TSDF cannot start: level_world is unavailable."); return end
    if not runtime.physics_world(world) then runtime_warning("TSDF cannot start: physics world is unavailable."); return end
    if world_owner and world_owner ~= world then reset_all_state(true) end
    world_owner = world

    refresh_config()
    ensure_volume()
    cancel_extraction()

    scan_kind = kind == "radial" and "radial" or "fov"
    scan_context = scan_pattern.context(scan_kind)
    if not scan_context then runtime_warning("TSDF cannot start: camera/player scan origin is unavailable."); return end
    scan_row, scan_col = 0, 0
    scan_changed_volume = false
    last_scan_hits = 0
    scan_active = true
end

function api.update(_dt)
    local world = current_world()
    if world_owner and world_owner ~= world then
        reset_all_state(true)
        world_owner = world
        return
    end
    if not world then return end
    world_owner = world

    if scan_active then scan_step() end
    extraction_step()
end



function api.hide()

    stop_scan(false)
    cancel_extraction()
    visible_renderer:clear()
end

function api.show()
    if volume and volume.count > 0 then
        start_extraction()
    end
end

function api.clear()
    reset_all_state(true)
end

function api.reset_all(keep_drawing)
    stop_scan(false)
    cancel_extraction()
    if not keep_drawing then visible_renderer:clear() end
    if volume then volume:clear() end
    volume = nil
    world_owner = nil
end

function api.on_game_state_changed(status, state_name)
    if state_name == "StateGameplay" and status == "exit" then
        reset_all_state(true)
        world_owner = nil
    end
end

return api
