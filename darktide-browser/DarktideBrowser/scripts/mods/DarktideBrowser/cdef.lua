local ffi = Mods.lua.ffi

if pcall(ffi.typeof, "DarktideBrowserRuntime_CDEF") then
    return true
end

ffi.cdef([[
    typedef unsigned long long DarktideBrowserHandle;

    int BrowserRuntime_Start(void);
    void BrowserRuntime_Shutdown(void);
    const char* BrowserRuntime_LastError(void);
    const char* BrowserRuntime_RendererError(void);

    DarktideBrowserHandle BrowserRuntime_Create(int width, int height);
    int BrowserRuntime_Destroy(DarktideBrowserHandle handle);
    int BrowserRuntime_IsReady(DarktideBrowserHandle handle);
    int BrowserRuntime_IsVisible(DarktideBrowserHandle handle);
    int BrowserRuntime_IsLoading(DarktideBrowserHandle handle);
    int BrowserRuntime_IsRenderTargetPresented(DarktideBrowserHandle handle);
    const char* BrowserRuntime_GetUrl(DarktideBrowserHandle handle);
    const char* BrowserRuntime_GetTitle(DarktideBrowserHandle handle);
    const char* BrowserRuntime_GetError(DarktideBrowserHandle handle);

    int BrowserRuntime_Navigate(DarktideBrowserHandle handle, const char* url);
    int BrowserRuntime_Reload(DarktideBrowserHandle handle);
    int BrowserRuntime_Stop(DarktideBrowserHandle handle);
    int BrowserRuntime_Back(DarktideBrowserHandle handle);
    int BrowserRuntime_Forward(DarktideBrowserHandle handle);
    int BrowserRuntime_SetSize(DarktideBrowserHandle handle, int width, int height);
    int BrowserRuntime_SetPosition(DarktideBrowserHandle handle, int x, int y);
    int BrowserRuntime_SetRenderTarget(DarktideBrowserHandle handle, const char* reference_name, int x, int y, int width, int height);
    int BrowserRuntime_ClearRenderTarget(DarktideBrowserHandle handle);
    int BrowserRuntime_SetVisible(DarktideBrowserHandle handle, int visible);
    int BrowserRuntime_SetFocus(DarktideBrowserHandle handle, int focused);
    int BrowserRuntime_ExecuteJavascript(DarktideBrowserHandle handle, const char* script);

    int BrowserRuntime_MouseMove(DarktideBrowserHandle handle, int x, int y);
    int BrowserRuntime_MouseButton(DarktideBrowserHandle handle, int button, int down, int clicks);
    int BrowserRuntime_MouseWheel(DarktideBrowserHandle handle, int delta);
    int BrowserRuntime_Key(DarktideBrowserHandle handle, unsigned int key, int down, unsigned int modifiers, int system_key);
    int BrowserRuntime_Char(DarktideBrowserHandle handle, const char* text, unsigned int modifiers);
    int BrowserRuntime_CopyToClipboard(DarktideBrowserHandle handle);
    int BrowserRuntime_PasteFromClipboard(DarktideBrowserHandle handle);

    typedef struct { int unused; } DarktideBrowserRuntime_CDEF;
]])

return true
