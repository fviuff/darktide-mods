-- the engines Lua binding has no participant volume, so the request is built like the engine builds its participant mute (vx_strdup strings, vx_free the old ones, cookie, issue), the sdk frees it after vx_issue_request3

local ffi = Mods.lua.ffi

pcall(ffi.cdef, [[
    char* vx_strdup(const char* s);
    void vx_free(void* p);
    int vx_issue_request3(void* request, int* request_count);
    int vx_req_session_set_participant_volume_for_me_create(void** req);
]])

-- vx_req_session_set_participant_volume_for_me = vx_req_base_t (0x30 bytes), session_handle, participant_uri, int volume
local COOKIE_OFFSET = 0x20
local SESSION_HANDLE_OFFSET = 0x30
local PARTICIPANT_URI_OFFSET = 0x38
local VOLUME_OFFSET = 0x40

local vivox = {}
local sdk
local cookie_counter = 0

local function set_string(base, offset, value)
    local field = ffi.cast("char**", base + offset)

    sdk.vx_free(field[0])
    field[0] = sdk.vx_strdup(value)
end

vivox.load = function()
    if sdk then
        return true
    end

    local ok, library = pcall(ffi.load, "vivoxsdk")

    if not ok then
        return false, tostring(library)
    end

    sdk = library

    return true
end

-- volume 0..100, 50 is normal
vivox.set_participant_volume = function(session_handle, participant_uri, volume)
    if not sdk then
        return false, "vivoxsdk is not loaded"
    end

    local request = ffi.new("void*[1]")

    if sdk.vx_req_session_set_participant_volume_for_me_create(request) ~= 0 or request[0] == nil then
        return false, "could not create the volume request"
    end

    local base = ffi.cast("uint8_t*", request[0])

    cookie_counter = cookie_counter + 1

    set_string(base, COOKIE_OFFSET, "voice_volume_" .. cookie_counter)
    set_string(base, SESSION_HANDLE_OFFSET, session_handle)
    set_string(base, PARTICIPANT_URI_OFFSET, participant_uri)
    ffi.cast("int*", base + VOLUME_OFFSET)[0] = volume

    local result = sdk.vx_issue_request3(request[0], nil)

    if result ~= 0 then
        return false, "vx_issue_request3 returned " .. tostring(result)
    end

    return true
end

return vivox
