local mod = get_mod("VoiceVolume")
local vivox = mod:io_dofile("VoiceVolume/scripts/mods/VoiceVolume/vivox")
local ChatManagerConstants = require("scripts/foundation/managers/chat/chat_manager_constants")
local ContentList = require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup_content_list")
local Blueprints = require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup_blueprints")
local PopupStyles = require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup_styles")
local ButtonPassTemplates = require("scripts/ui/pass_templates/button_pass_templates")
local SliderPassTemplates = require("scripts/ui/pass_templates/slider_pass_templates")

local ffi = Mods.lua.ffi
local disk_io = Mods.lua.io
local disk_os = Mods.lua.os

local CONNECTED = ChatManagerConstants.ChannelConnectionState.CONNECTED
-- Vivox participant volume: 0..100, 50 = normal. Vivox advises staying within +25 of normal
-- (shit in db, right? so log scaling)
local NORMAL_VOLUME = 50
local MAX_VOLUME = 75
local SAVE_DELAY = 1
local VOLUME_RESPONSE = "resp_session_set_participant_volume_for_me"

local loaded, load_error = vivox.load()

if not loaded then
    mod:error(load_error)
end

-- Saved volumes

pcall(ffi.cdef, [[
    int CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
]])

local kernel32 = ffi.load("kernel32")
local appdata = disk_os.getenv("APPDATA")
local folder = appdata and appdata .. "\\Fatshark\\Darktide\\VoiceVolume"
local file_path = folder and folder .. "\\volumes.json"

-- account id -> volume
local volumes = {}
local save_timer

local function load_volumes()
    if not file_path then
        return
    end

    local file = disk_io.open(file_path, "r")

    if not file then
        return
    end

    local content = file:read("*a")

    file:close()

    local ok, decoded = pcall(cjson.decode, content)

    if not ok or type(decoded) ~= "table" then
        mod:error("could not read " .. file_path)

        return
    end

    for account_id, volume in pairs(decoded) do
        if type(volume) == "number" then
            volumes[account_id] = math.clamp(math.round(volume), 0, MAX_VOLUME)
        end
    end
end

local function save_volumes()
    if not file_path then
        return
    end

    kernel32.CreateDirectoryA(folder, nil)

    local temporary_path = file_path .. ".tmp"
    local file = disk_io.open(temporary_path, "w")

    if not file then
        mod:error("could not write " .. temporary_path)

        return
    end

    file:write(next(volumes) and cjson.encode(volumes) or "{}")
    file:close()
    disk_os.remove(file_path)
    disk_os.rename(temporary_path, file_path)
end

load_volumes()

mod.update = function(dt)
    if save_timer then
        save_timer = save_timer - dt

        if save_timer <= 0 then
            save_timer = nil

            save_volumes()
        end
    end
end

mod.on_unload = function()
    if save_timer then
        save_timer = nil

        save_volumes()
    end
end

local function saved_volume(account_id)
    return account_id and volumes[account_id] or NORMAL_VOLUME
end

-- Applying volumes

local function chat_sessions()
    local chat_manager = Managers.chat

    return chat_manager and chat_manager:sessions()
end

local function send(session_handle, participant_uri, volume)
    local ok, error_message = vivox.set_participant_volume(session_handle, participant_uri, volume)

    if not ok then
        mod:info("%s (%s)", error_message, participant_uri)
    end
end

-- normal volumes are left alone unless forced
local function apply_participant(session_handle, participant_uri, participant, force)
    if participant.is_current_user or not participant.account_id then
        return
    end

    local volume = saved_volume(participant.account_id)

    if force or volume ~= NORMAL_VOLUME then
        send(session_handle, participant_uri, volume)
    end
end

local function apply_session(session_handle, session, force)
    if session.session_media_state ~= CONNECTED then
        return
    end

    for participant_uri, participant in pairs(session.participants) do
        apply_participant(session_handle, participant_uri, participant, force)
    end
end

local function apply_all(force)
    local sessions = chat_sessions()

    if not sessions then
        return
    end

    for session_handle, session in pairs(sessions) do
        apply_session(session_handle, session, force)
    end
end

local function set_player_volume(account_id, volume)
    volumes[account_id] = volume ~= NORMAL_VOLUME and volume or nil

    save_timer = SAVE_DELAY

    local sessions = chat_sessions()

    if not sessions then
        return
    end

    for session_handle, session in pairs(sessions) do
        if session.session_media_state == CONNECTED then
            for participant_uri, participant in pairs(session.participants) do
                if participant.account_id == account_id and not participant.is_current_user then
                    send(session_handle, participant_uri, volume)
                end
            end
        end
    end
end

-- Vivox keeps volume per channel so it is sent again when someone joins channel or audio connects
mod:hook_safe(CLASS.ChatManager, "_handle_event", function(self, message)
    local event = message.event

    if event ~= Vivox.EventType_PARTICIPANT_ADDED and event ~= Vivox.EventType_MEDIA_STREAM_UPDATED then
        return
    end

    local session_handle = message.session_handle
    local session = self._sessions[session_handle]

    if not session or session.session_media_state ~= CONNECTED then
        return
    end

    if event == Vivox.EventType_MEDIA_STREAM_UPDATED then
        apply_session(session_handle, session, false)
    else
        local participant = session.participants[message.participant_uri]

        if participant then
            apply_participant(session_handle, message.participant_uri, participant, false)
        end
    end
end)

-- the game sends unknown Vivox errors to its crash reporting, a volume request for someone who just left isnt a crash
mod:hook(CLASS.ChatManager, "_handle_response_error", function(func, self, message)
    if message.response_type_string == VOLUME_RESPONSE then
        mod:info("Vivox %s (%s)", tostring(message.response_error_string), tostring(message.response_status_code))

        return
    end

    return func(self, message)
end)

mod.on_enabled = function()
    apply_all(false)
end

mod.on_disabled = function()
    local sessions = chat_sessions()

    if not sessions then
        return
    end

    for session_handle, session in pairs(sessions) do
        if session.session_media_state == CONNECTED then
            for participant_uri, participant in pairs(session.participants) do
                if not participant.is_current_user and saved_volume(participant.account_id) ~= NORMAL_VOLUME then
                    send(session_handle, participant_uri, NORMAL_VOLUME)
                end
            end
        end
    end
end

-- Popup slider
-- same slider as the options menu, the popup has no exclusive focus so the confirm to edit part lives in update

local SLIDER_WIDTH = PopupStyles.column_width
local SLIDER_HEIGHT = ButtonPassTemplates.list_button_default_height
local SLIDER_AREA_WIDTH = 200

local function slider_value_from_volume(volume)
    return math.clamp(volume / MAX_VOLUME, 0, 1)
end

local function volume_from_slider_value(slider_value)
    return math.clamp(math.round((slider_value or 0) * MAX_VOLUME), 0, MAX_VOLUME)
end

-- one step is about 1 dB and +10 dB sounds twice as loud
local function volume_text(volume)
    return string.format("%d%%", math.round(100 * 2 ^ ((volume - NORMAL_VOLUME) / 10)))
end

Blueprints.voice_volume_slider = {
    size = {
        SLIDER_WIDTH,
        SLIDER_HEIGHT,
    },
    pass_template = SliderPassTemplates.settings_value_slider(SLIDER_WIDTH, SLIDER_HEIGHT, SLIDER_AREA_WIDTH, true),
    init = function(parent, widget, context)
        local content = widget.content
        local slider_value = slider_value_from_volume(context.volume)

        content.text = mod:localize("voice_volume")
        content.step_size = 1 / MAX_VOLUME
        content.slider_value = slider_value
        content.previous_slider_value = slider_value
        content.value_text = volume_text(context.volume)
        content.voice_volume_account_id = context.account_id
        content.voice_volume = context.volume
    end,
    update = function(parent, widget)
        local content = widget.content
        local hotspot = content.hotspot
        local using_gamepad = not parent._using_cursor_navigation

        if content.exclusive_focus and not (using_gamepad and hotspot.is_focused) then
            content.exclusive_focus = false
        elseif hotspot.on_pressed and using_gamepad then
            content.exclusive_focus = not content.exclusive_focus
        end

        local slider_value = content.slider_value

        if slider_value == content.previous_slider_value then
            return
        end

        content.previous_slider_value = slider_value

        local volume = volume_from_slider_value(slider_value)

        if volume ~= content.voice_volume then
            content.voice_volume = volume
            content.value_text = volume_text(volume)

            set_player_volume(content.voice_volume_account_id, volume)
        end
    end,
}

local menu_items = {}

mod:hook(ContentList, "from_player_info", function(func, parent, player_info)
    local items, num_items = func(parent, player_info)

    if player_info:is_own_player() or player_info:is_blocked() then
        return items, num_items
    end

    local account_id = player_info:account_id()

    if not account_id or account_id == "" then
        return items, num_items
    end

    local mute_voice_label = Localize("loc_social_menu_mute_voice")
    local insert_after = num_items

    for i = 1, num_items do
        if items[i].label == mute_voice_label then
            insert_after = i
        end
    end

    table.clear(menu_items)

    for i = 1, insert_after do
        menu_items[#menu_items + 1] = items[i]
    end

    menu_items[#menu_items + 1] = {
        blueprint = "voice_volume_slider",
        label = "voice_volume_slider",
        account_id = account_id,
        volume = saved_volume(account_id),
    }

    for i = insert_after + 1, num_items do
        menu_items[#menu_items + 1] = items[i]
    end

    return menu_items, num_items + 1
end)
