local mod = get_mod("NoBrainer")
local frame_budget = mod._nb_frame_budget
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local scan_pattern = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RaycastScanPattern")
local builders = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/PointCloudAlgorithmBuilder")
local retained = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/RetainedLineChunks")
local runtime = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DarktideRuntime")

local api = {}

local floor,max,sqrt = math.floor,math.max,math.sqrt
local tostring=tostring
local LINES_PER_CHUNK=512
local RAY_WORK_COST=10
local BUILD_WORK_COST=4

local point_modes={gabriel_graph=true,pca_curvature=true,ransac_planes=true,mls_implicit=true,spectral_graph=true}
local mode_names={
    gabriel_graph="Gabriel Proximity Graph",
    pca_curvature="PCA Surface Variation Frames",
    ransac_planes="RANSAC Structural Planes",
    mls_implicit="IMLS Oriented Surface",
    spectral_graph="Spectral Graph Field",
}
local current_mode="gabriel_graph"
local points={x={},y={},z={},nx={},ny={},nz={},count=0}
local point_hash={}
local point_hash_cell=0.30
local world_owner=nil
local visible=retained.new(LINES_PER_CHUNK)
local build_renderer=nil
local builder=nil
local publish_pending=false
local pending_line=false
local pl_style,pl_ax,pl_ay,pl_az,pl_bx,pl_by,pl_bz=nil,nil,nil,nil,nil,nil,nil

local scan_active=false
local scan_kind="fov"
local scan_context=nil
local scan_row,scan_col=0,0
local scan_changed=false
local last_raycast_hits=0

local function current_world() return runtime.current_world() end
local function runtime_warning(text)
    if mod.warning then pcall(mod.warning, mod, "[NoBrainer] " .. text) end
end
local function hkey(ix,iy,iz) return tostring(ix)..":"..tostring(iy)..":"..tostring(iz) end
local function palette_rgb(which)
    local c=settings.get("pc_color")
    if which==3 then return 235,235,235 end
    if c=="amber" then
        if which==2 then return 70,220,255 end
        return 255,180,45
    elseif c=="white" then
        if which==2 then return 255,180,45 end
        return 230,230,230
    elseif c=="toxin" then
        if which==2 then return 255,180,45 end
        return 90,235,110
    end
    if which==2 then return 255,180,45 end
    return 70,220,255
end

local function refresh_hash_cell() point_hash_cell=max(0.04,settings.number("pc_sample_spacing")) end
local function clear_points()
    points={x={},y={},z={},nx={},ny={},nz={},count=0};point_hash={};refresh_hash_cell()
end

local function add_point(x,y,z,nx,ny,nz)
    local cap=max(32,floor(settings.number("pc_max_points")))
    if points.count>=cap then return false end
    local c=point_hash_cell
    local ix,iy,iz=floor(x/c),floor(y/c),floor(z/c)
    local min2=c*c
    for dx=-1,1 do for dy=-1,1 do for dz=-1,1 do
        local b=point_hash[hkey(ix+dx,iy+dy,iz+dz)]
        if b then for q=1,#b do
            local j=b[q];local px,py,pz=points.x[j]-x,points.y[j]-y,points.z[j]-z
            if px*px+py*py+pz*pz < min2 then return false end
        end end
    end end end
    local n=points.count+1;points.count=n
    points.x[n],points.y[n],points.z[n]=x,y,z
    points.nx[n],points.ny[n],points.nz[n]=nx,ny,nz
    local k=hkey(ix,iy,iz);local b=point_hash[k];if not b then b={};point_hash[k]=b end;b[#b+1]=n
    return true
end

local function cancel_build()
    builder=nil;publish_pending=false;pending_line=false
    if build_renderer then build_renderer:clear() end
    build_renderer=nil
end
local function start_build()
    cancel_build()
    if points.count<3 or not point_modes[current_mode] then visible:clear();return end
    builder=builders.new(current_mode,points,settings.number("pc_scale"))
    build_renderer=retained.new(LINES_PER_CHUNK)
end
local function stop_scan(build_partial)
    local changed=scan_changed
    scan_active=false;scan_context=nil;scan_row,scan_col=0,0;scan_changed=false
    if build_partial and changed then start_build() end
end

local function reset_state(clear_cloud)
    stop_scan(false);cancel_build();visible:clear()
    if clear_cloud then clear_points() end
end

local function advance_pixel(hr,vr)
    scan_col=scan_col+1
    if scan_col>=hr then scan_col=0;scan_row=scan_row+1 end
    if scan_row>=vr then
        local changed=scan_changed
        scan_active=false;scan_context=nil;scan_row,scan_col=0,0;scan_changed=false
        if changed then
            start_build()
        elseif last_raycast_hits == 0 then
            runtime_warning("Point-cloud scan received zero static collision hits. Check ray range / current world before tuning the algorithm.")
        end
    end
end

local function scan_step()
    local world=current_world();if not world then return end
    local pw=runtime.physics_world(world);if not pw then return end
    local hr=max(1,floor(settings.number("h_res")));local vr=max(1,floor(settings.number("v_res")))
    local hf,vf=settings.number("h_fov"),settings.number("v_fov")
    local range=max(0.1,settings.number("max_range"))
    local ox,oy,oz=scan_pattern.origin_components(scan_context)
    if not ox then stop_scan(false); return end
    local budget=frame_budget.claim_items(RAY_WORK_COST)
    while scan_active and budget>0 and frame_budget.time_available() do
        local dx,dy,dz=scan_pattern.direction_components(scan_kind,scan_row,scan_col,hr,vr,hf,vf,scan_context)
        if not dx then stop_scan(false); return end
        local x,y,z,_,nx,ny,nz=runtime.raycast_static(pw,ox,oy,oz,dx,dy,dz,range)
        if x then
            last_raycast_hits=last_raycast_hits+1
            if add_point(x,y,z,nx,ny,nz) then scan_changed=true end
        end
        advance_pixel(hr,vr);budget=budget-1
    end
end

local function submit_pending_line()
    if not pending_line then return true end
    if not frame_budget.take_draw(1) then return false end
    local r,g,b=palette_rgb(pl_style)
    local ok=build_renderer:add_line_rgb_xyz(r,g,b,pl_ax,pl_ay,pl_az,pl_bx,pl_by,pl_bz)
    if not ok then frame_budget.refund_draw(1);return false end
    pending_line=false;return true
end

local function try_publish()
    if not publish_pending or not build_renderer then return end
    local count=build_renderer:line_count()
    if count==0 and points.count>0 then
        runtime_warning((mode_names[current_mode] or current_mode).." had "..tostring(points.count).." samples but produced zero lines. Increase Feature / neighborhood scale or rescan a denser surface.")
    end
    if count>0 and not build_renderer:dispatch() then return end
    visible:clear()
    if count>0 then visible=build_renderer else build_renderer:clear() end
    build_renderer=nil;builder=nil;publish_pending=false
end

local function build_step()
    if publish_pending then try_publish();return end
    if not builder or not build_renderer then return end
    if not submit_pending_line() then return end
    local budget=frame_budget.claim_items(BUILD_WORK_COST)
    while budget>0 and builder and frame_budget.time_available() do
        local kind,a,b,c,d,e,f,g=builder:resume();budget=budget-1
        if kind=="line" then
            pl_style,pl_ax,pl_ay,pl_az,pl_bx,pl_by,pl_bz=a,b,c,d,e,f,g;pending_line=true
            if not submit_pending_line() then return end
        elseif kind=="error" then
            mod:error("[NoBrainer] point-cloud algorithm failed: "..tostring(a))
            cancel_build();return
        elseif kind=="done" then
            publish_pending=true;try_publish();return
        end
    end
end

function api.is_mode(mode) return point_modes[mode] == true end
local function activate(mode)
    if not point_modes[mode] then return end
    current_mode=mode
    if points.count>0 then start_build() else visible:clear() end
end
function api.hide() cancel_build();visible:clear();stop_scan(false) end
function api.show(mode)
    activate(mode or current_mode)
end

function api.trigger(kind)
    local world=current_world();if not world then runtime_warning("Point-cloud scan cannot start: level_world is unavailable.");return end
    if not runtime.physics_world(world) then runtime_warning("Point-cloud scan cannot start: physics world is unavailable.");return end
    if world_owner and world_owner~=world then reset_state(true) end
    world_owner=world
    cancel_build();refresh_hash_cell()
    scan_kind=kind=="radial" and "radial" or "fov"
    scan_context=scan_pattern.context(scan_kind);if not scan_context then runtime_warning("Point-cloud scan cannot start: camera/player scan origin is unavailable.");return end
    scan_row,scan_col=0,0;scan_changed=false;last_raycast_hits=0;scan_active=true
end
function api.update(_dt)
    local world=current_world()
    if world_owner and world_owner~=world then reset_state(true);world_owner=world;return end
    if not world then return end
    world_owner=world
    if scan_active then scan_step() end
    build_step()
end
function api.clear() reset_state(true) end
function api.reset_all(clear_cloud) reset_state(clear_cloud==true) end
function api.destroy() reset_state(true);world_owner=nil end


function api.on_game_state_changed(status,state_name)
    if state_name=="StateGameplay" and status=="exit" then api.destroy() end
end


return api
