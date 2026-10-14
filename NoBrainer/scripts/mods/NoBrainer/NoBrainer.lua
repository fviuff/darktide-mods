local mod = get_mod("NoBrainer")

local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")
local frame_budget = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/FrameBudget")
mod._nb_frame_budget = frame_budget

local homology = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/HomologyScanner")
local wavefront = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/GeodesicWavefront")
local heat_method = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/GeodesicHeatMethod")
local ball_pivot = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/GeodesicBallPivotMesh")
local tsdf_dual = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/TsdfDualContourMapper")
local point_cloud = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/PointCloudLab")
local procedural = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/ProceduralMathLab")
local gamma = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/GammaController")

local modes = {
    homology = homology,
    wavefront = wavefront,
    heat_method = heat_method,
    ball_pivot = ball_pivot,
    tsdf_dual = tsdf_dual,
    gabriel_graph = point_cloud,
    pca_curvature = point_cloud,
    ransac_planes = point_cloud,
    mls_implicit = point_cloud,
    spectral_graph = point_cloud,
    procedural_math = procedural,
}

local function valid_mode(value)
    return modes[value] and value or "homology"
end

local active_mode = valid_mode(settings.mode())

local function active_mapper()
    return modes[active_mode] or homology
end

local function deactivate_mode(mode)
    if mode == "homology" then
        homology.hide()
    elseif mode == "tsdf_dual" then
        tsdf_dual.hide()
    elseif mode == "procedural_math" then
        procedural.hide()
    elseif point_cloud.is_mode(mode) then
        point_cloud.hide()
    elseif mode == "wavefront" then
        wavefront.reset_all(false)
    elseif mode == "heat_method" then
        heat_method.reset_all(false)
    elseif mode == "ball_pivot" then
        ball_pivot.reset_all(false)
    end
end

local function switch_mode(next_mode)
    next_mode = valid_mode(next_mode)
    if next_mode == active_mode then return end

    deactivate_mode(active_mode)
    active_mode = next_mode

    if active_mode == "homology" then
        homology.show()
    elseif active_mode == "tsdf_dual" then
        tsdf_dual.show()
    elseif point_cloud.is_mode(active_mode) then
        point_cloud.show(active_mode)
    elseif active_mode == "procedural_math" then
        procedural.show()
    end
end

function mod.update(dt)
    if not mod:is_enabled() then return end
    frame_budget.begin_frame(dt)
    active_mapper().update(dt)
end

local function ui_active()
    local ui = Managers.ui
    return ui and ui:active_top_view() ~= nil or false
end

function mod.nb_scan()
    if ui_active() then return end
    active_mapper().trigger("fov")
end

function mod.nb_radial_scan()
    if ui_active() then return end
    active_mapper().trigger("radial")
end

function mod.nb_clear()
    if ui_active() then return end
    active_mapper().clear()
end

function mod.on_setting_changed(setting_id)
    if setting_id == "analysis_mode" then
        switch_mode(settings.mode())
    elseif setting_id == "darkness_enabled" or setting_id == "gamma_level" then
        gamma.apply()
    end
end

function mod.on_enabled()
    active_mode = valid_mode(settings.mode())
    homology.reset_all(false)
    wavefront.reset_all(false)
    heat_method.reset_all(false)
    ball_pivot.reset_all(false)
    tsdf_dual.reset_all(false)
    if active_mode ~= "homology" then homology.hide() end
    if active_mode ~= "tsdf_dual" then tsdf_dual.hide() end
    if point_cloud.is_mode(active_mode) then point_cloud.show(active_mode) else point_cloud.hide() end
    if active_mode ~= "procedural_math" then procedural.hide() end
    gamma.apply()
end

function mod.on_disabled()
    frame_budget.reset()
    gamma.restore()
    homology.destroy()
    wavefront.reset_all(false)
    heat_method.reset_all(false)
    ball_pivot.reset_all(false)
    tsdf_dual.reset_all(false)
    point_cloud.destroy()
    procedural.destroy()
end

function mod.on_game_state_changed(status, state_name)
    homology.on_game_state_changed(status, state_name)
    wavefront.on_game_state_changed(status, state_name)
    heat_method.on_game_state_changed(status, state_name)
    ball_pivot.on_game_state_changed(status, state_name)
    tsdf_dual.on_game_state_changed(status, state_name)
    point_cloud.on_game_state_changed(status, state_name)
    procedural.on_game_state_changed(status, state_name)
    if state_name == "StateGameplay" and status == "exit" then
        frame_budget.reset()
    end
end
