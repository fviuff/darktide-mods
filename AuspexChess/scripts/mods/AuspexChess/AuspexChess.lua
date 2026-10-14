local mod = get_mod("AuspexChess")

local ROOT = "AuspexChess/scripts/mods/AuspexChess/"
local minigame = mod:io_dofile(ROOT .. "Minigame")

mod.minigame = minigame

local chess = mod:io_dofile(ROOT .. "Chess")
local ChessView = chess.View
local ChessOverlayView = chess.OverlayView

local OVERLAY_VIEW_NAME = "auspex_chess_overlay_view"
local OVERLAY_VIEW_PATH = ROOT .. "overlay"

local ScannerDisplayView = require("scripts/ui/views/scanner_display_view/scanner_display_view")
local ScannerDisplayViewDefinitions = require("scripts/ui/views/scanner_display_view/scanner_display_view_definitions")
local ScannerDisplayViewDefinitionsNone = require("scripts/ui/views/scanner_display_view/scanner_display_view_definitions_none")

local replacements = {
    { type = minigame.types.balance, setting = "balance_replacement" },
    { type = minigame.types.decode_search, setting = "decode_search_replacement" },
    { type = minigame.types.decode_symbols, setting = "decode_symbols_replacement" },
    { type = minigame.types.drill, setting = "drill_replacement" },
}

local replacement_settings = {}
local stock_views = {}
local stock_definitions = {}

for i = 1, #replacements do
    replacement_settings[replacements[i].setting] = true
end

-- scanner views

local function install_scanner_views()
    for i = 1, #replacements do
        local config = replacements[i]
        local minigame_type = config.type

        if stock_views[minigame_type] == nil then
            stock_views[minigame_type] = ScannerDisplayView.MINIGAMES[minigame_type]
            stock_definitions[minigame_type] = ScannerDisplayViewDefinitions[minigame_type]
        end

        if mod:get(config.setting) == "stock" then
            ScannerDisplayView.MINIGAMES[minigame_type] = stock_views[minigame_type]
            ScannerDisplayViewDefinitions[minigame_type] = stock_definitions[minigame_type]
        else
            ScannerDisplayView.MINIGAMES[minigame_type] = ChessView
            local definition = table.clone(ScannerDisplayViewDefinitionsNone.none)
            definition.name = minigame_type
            ScannerDisplayViewDefinitions[minigame_type] = definition
        end
    end
end

local function restore_scanner_views()
    for i = 1, #replacements do
        local minigame_type = replacements[i].type

        if stock_views[minigame_type] then
            ScannerDisplayView.MINIGAMES[minigame_type] = stock_views[minigame_type]
        end

        if stock_definitions[minigame_type] then
            ScannerDisplayViewDefinitions[minigame_type] = stock_definitions[minigame_type]
        end
    end
end


-- overlay

package.preload[OVERLAY_VIEW_PATH] = function()
    return ChessOverlayView
end

mod:register_view({
    view_name = OVERLAY_VIEW_NAME,
    view_settings = {
        init_view_function = function()
            return true
        end,
        state_bound = true,
        path = OVERLAY_VIEW_PATH,
        class = "AuspexChessOverlayView",
        disable_game_world = false,
        load_always = true,
        load_in_hub = true,
        close_on_hotkey_pressed = false,
    },
    view_transitions = {},
    view_options = {
        close_all = false,
        close_previous = false,
    },
})

local debug_seed = 0

local function next_debug_seed()
    debug_seed = debug_seed + 1
    local time = Application and Application.time_since_launch and Application.time_since_launch() or 0
    return math.floor(time * 1000) + debug_seed
end

local function open_debug_puzzle()
    local puzzle, reason = chess.Puzzle.new(next_debug_seed(), {
        difficulty = mod:get("puzzle_difficulty") or "normal",
    })
    if not puzzle then
        mod:echo("AuspexChess could not create chess puzzle %s", tostring(reason))
        return
    end

    local ui = Managers.ui
    if not ui then
        mod:echo("AuspexChess UI manager is unavailable")
        return
    end

    if ui:view_active(OVERLAY_VIEW_NAME) then
        local view = ui:view_instance(OVERLAY_VIEW_NAME)

        if view and not view._owner and view.set_puzzle then
            view:set_puzzle(puzzle)
        else
            mod:echo("AuspexChess puzzle overlay is already open")
        end

        return
    end

    ui:open_view(OVERLAY_VIEW_NAME, nil, nil, nil, nil, {
        puzzle = puzzle,
        debug = true,
    })
end

mod:command("ac_debug_chess", "open a local chess puzzle test view. Or just play for fun ig", open_debug_puzzle)

mod:hook(ScannerDisplayView, "update", function(func, view, dt, t)
    local game = view and view._minigame

    if game and game.__class_name == "AuspexChessView" and mod:get("display_mode") == "auspex" then
        local input_service = Managers.ui and Managers.ui:input_service("Ingame")
        if input_service and input_service:get("menu") then
            game:request_close()
            return false, true
        end
    end

    return func(view, dt, t)
end)

-- lifecycle

install_scanner_views()

function mod.update(dt)
    minigame:update(dt)
end

function mod.on_setting_changed(setting_id)
    if replacement_settings[setting_id] then
        install_scanner_views()
    elseif setting_id == "display_mode" then
        local ui = Managers.ui
        if ui and ui:view_active(OVERLAY_VIEW_NAME) and not ui:is_view_closing(OVERLAY_VIEW_NAME) then
            local view = ui:view_instance(OVERLAY_VIEW_NAME)
            if view and view._owner then
                view._owner._overlay_opened = false
                view._owner = nil
                ui:close_view(OVERLAY_VIEW_NAME)
            end
        end
    end
end

function mod.on_enabled()
    minigame:set_enabled(true)
    install_scanner_views()
end

function mod.on_disabled()
    restore_scanner_views()
    if Managers.ui and Managers.ui:view_active(OVERLAY_VIEW_NAME) then
        Managers.ui:close_view(OVERLAY_VIEW_NAME)
    end
    minigame:set_enabled(false)
    minigame:reset()
end

function mod.on_game_state_changed(status, state_name)
    if status == "exit" and state_name == "StateGameplay" then
        minigame:reset()
    end
end

function mod.on_unload()
    restore_scanner_views()
    if Managers.ui and Managers.ui:view_active(OVERLAY_VIEW_NAME) then
        Managers.ui:close_view(OVERLAY_VIEW_NAME)
    end
    minigame:reset()
end
