local mod = get_mod("DarktideBrowser")

if mod._darktide_browser_native then
    return mod._darktide_browser_native
end

local ffi = Mods.lua.ffi

mod:io_dofile("DarktideBrowser/scripts/mods/DarktideBrowser/cdef")

local native = {}
local state = {}

local RUNTIME_PATH = "../mods/DarktideBrowser/bin/darktide-browser-runtime.dll"
local RUNTIME_WINDOWS_PATH = string.gsub(RUNTIME_PATH, "/", "\\")

local function runtime_string(pointer)
    if pointer == nil then
        return nil
    end

    local value = ffi.string(pointer)

    if value == "" then
        return nil
    end

    return value
end

local function load_runtime()
    if state.runtime then
        return state.runtime
    end

    local ok, runtime_or_error = pcall(ffi.load, RUNTIME_WINDOWS_PATH)

    if not ok then
        return nil, tostring(runtime_or_error)
    end

    state.runtime = runtime_or_error
    return state.runtime
end

local function runtime_or_error()
    local runtime = state.runtime

    if not runtime then
        error("DarktideBrowser runtime is not initialized")
    end

    return runtime
end

native.initialize = function()
    local runtime, load_error = load_runtime()

    if not runtime then
        return false, load_error
    end

    if runtime.BrowserRuntime_Start() == 0 then
        return false, runtime_string(runtime.BrowserRuntime_LastError()) or "DarktideBrowser runtime failed to start"
    end

    return true
end

native.last_error = function()
    local runtime = runtime_or_error()
    return runtime_string(runtime.BrowserRuntime_LastError())
end

native.renderer_error = function()
    local runtime = runtime_or_error()
    return runtime_string(runtime.BrowserRuntime_RendererError())
end


native.create = function(width, height)
    local runtime = runtime_or_error()
    local handle = runtime.BrowserRuntime_Create(width, height)

    if handle == 0 then
        return nil, native.last_error() or "DarktideBrowser failed to create browser"
    end

    return handle
end

native.destroy = function(handle)
    return runtime_or_error().BrowserRuntime_Destroy(handle) ~= 0
end

native.is_ready = function(handle)
    return runtime_or_error().BrowserRuntime_IsReady(handle) ~= 0
end

native.is_visible = function(handle)
    return runtime_or_error().BrowserRuntime_IsVisible(handle) ~= 0
end

native.is_loading = function(handle)
    return runtime_or_error().BrowserRuntime_IsLoading(handle) ~= 0
end

native.is_render_target_presented = function(handle)
    return runtime_or_error().BrowserRuntime_IsRenderTargetPresented(handle) ~= 0
end

native.url = function(handle)
    return runtime_string(runtime_or_error().BrowserRuntime_GetUrl(handle))
end

native.title = function(handle)
    return runtime_string(runtime_or_error().BrowserRuntime_GetTitle(handle))
end

native.error = function(handle)
    return runtime_string(runtime_or_error().BrowserRuntime_GetError(handle))
end

local function browser_call(symbol)
    return function(handle, ...)
        local runtime = runtime_or_error()
        return runtime[symbol](handle, ...) ~= 0
    end
end

native.navigate = browser_call("BrowserRuntime_Navigate")
native.reload = browser_call("BrowserRuntime_Reload")
native.stop = browser_call("BrowserRuntime_Stop")
native.back = browser_call("BrowserRuntime_Back")
native.forward = browser_call("BrowserRuntime_Forward")
native.set_size = browser_call("BrowserRuntime_SetSize")
native.set_position = browser_call("BrowserRuntime_SetPosition")
native.set_render_target = browser_call("BrowserRuntime_SetRenderTarget")
native.clear_render_target = browser_call("BrowserRuntime_ClearRenderTarget")
native.set_visible = browser_call("BrowserRuntime_SetVisible")
native.set_focus = browser_call("BrowserRuntime_SetFocus")
native.execute_javascript = browser_call("BrowserRuntime_ExecuteJavascript")
native.mouse_move = browser_call("BrowserRuntime_MouseMove")
native.mouse_button = browser_call("BrowserRuntime_MouseButton")
native.mouse_wheel = browser_call("BrowserRuntime_MouseWheel")
native.key = browser_call("BrowserRuntime_Key")
native.char = browser_call("BrowserRuntime_Char")
native.copy_to_clipboard = browser_call("BrowserRuntime_CopyToClipboard")
native.paste_from_clipboard = browser_call("BrowserRuntime_PasteFromClipboard")

native.shutdown = function()
    if state.runtime then
        state.runtime.BrowserRuntime_Shutdown()
    end
end

mod._darktide_browser_native = native

return native
