// steam html callback bridge

void *operator new(usize, void *p) noexcept { return p; }

using SteamAPICall = u64;
using SteamBrowser = u32;

static constexpr SteamBrowser INVALID_STEAM_BROWSER = 0u;
static constexpr i32 STEAM_HTML_CALLBACK_BASE = 4500;

enum SteamHtmlCallback : i32 {
    STEAM_HTML_BROWSER_READY = STEAM_HTML_CALLBACK_BASE + 1,
    STEAM_HTML_NEEDS_PAINT = STEAM_HTML_CALLBACK_BASE + 2,
    STEAM_HTML_START_REQUEST = STEAM_HTML_CALLBACK_BASE + 3,
    STEAM_HTML_CLOSE_BROWSER = STEAM_HTML_CALLBACK_BASE + 4,
    STEAM_HTML_URL_CHANGED = STEAM_HTML_CALLBACK_BASE + 5,
    STEAM_HTML_FINISHED_REQUEST = STEAM_HTML_CALLBACK_BASE + 6,
    STEAM_HTML_CHANGED_TITLE = STEAM_HTML_CALLBACK_BASE + 8,
    STEAM_HTML_JS_ALERT = STEAM_HTML_CALLBACK_BASE + 14,
    STEAM_HTML_JS_CONFIRM = STEAM_HTML_CALLBACK_BASE + 15,
    STEAM_HTML_FILE_OPEN = STEAM_HTML_CALLBACK_BASE + 16,
    STEAM_HTML_NEW_WINDOW = STEAM_HTML_CALLBACK_BASE + 21,
    STEAM_HTML_BROWSER_RESTARTED = STEAM_HTML_CALLBACK_BASE + 27,
};

#pragma pack(push, 8)
struct SteamHtmlBrowserReady {
    SteamBrowser browser;
};

struct SteamHtmlNeedsPaint {
    SteamBrowser browser;
    const char *bgra;
    u32 width;
    u32 height;
    u32 update_x;
    u32 update_y;
    u32 update_width;
    u32 update_height;
    u32 scroll_x;
    u32 scroll_y;
    float page_scale;
    u32 page_serial;
};

struct SteamHtmlStartRequest {
    SteamBrowser browser;
    const char *url;
    const char *target;
    const char *post_data;
    bool redirect;
};

struct SteamHtmlCloseBrowser {
    SteamBrowser browser;
};

struct SteamHtmlUrlChanged {
    SteamBrowser browser;
    const char *url;
    const char *post_data;
    bool redirect;
    const char *page_title;
    bool new_navigation;
};

struct SteamHtmlFinishedRequest {
    SteamBrowser browser;
    const char *url;
    const char *page_title;
};

struct SteamHtmlChangedTitle {
    SteamBrowser browser;
    const char *title;
};

struct SteamHtmlJsDialog {
    SteamBrowser browser;
    const char *message;
};

struct SteamHtmlFileOpen {
    SteamBrowser browser;
    const char *title;
    const char *initial_file;
};

struct SteamHtmlNewWindow {
    SteamBrowser browser;
    const char *url;
    u32 x;
    u32 y;
    u32 width;
    u32 height;
    SteamBrowser ignored_new_browser;
};

struct SteamHtmlBrowserRestarted {
    SteamBrowser browser;
    SteamBrowser old_browser;
};
#pragma pack(pop)

static_assert(sizeof(SteamHtmlBrowserReady) == 4u);
static_assert(sizeof(SteamHtmlNeedsPaint) == 56u);
static_assert(sizeof(SteamHtmlStartRequest) == 40u);
static_assert(sizeof(SteamHtmlCloseBrowser) == 4u);
static_assert(sizeof(SteamHtmlUrlChanged) == 48u);
static_assert(sizeof(SteamHtmlFinishedRequest) == 24u);
static_assert(sizeof(SteamHtmlChangedTitle) == 16u);
static_assert(sizeof(SteamHtmlJsDialog) == 16u);
static_assert(sizeof(SteamHtmlFileOpen) == 24u);
static_assert(sizeof(SteamHtmlNewWindow) == 40u);
static_assert(sizeof(SteamHtmlBrowserRestarted) == 8u);

using SteamHtmlAccessorFn = void *(STDCALL *)();
using SteamHtmlInitFn = bool (STDCALL *)(void *);
using SteamHtmlShutdownFn = bool (STDCALL *)(void *);
using SteamHtmlCreateBrowserFn = SteamAPICall (STDCALL *)(void *, const char *, const char *);
using SteamHtmlRemoveBrowserFn = void (STDCALL *)(void *, SteamBrowser);
using SteamHtmlLoadUrlFn = void (STDCALL *)(void *, SteamBrowser, const char *, const char *);
using SteamHtmlSetSizeFn = void (STDCALL *)(void *, SteamBrowser, u32, u32);
using SteamHtmlSimpleBrowserFn = void (STDCALL *)(void *, SteamBrowser);
using SteamHtmlAllowStartRequestFn = void (STDCALL *)(void *, SteamBrowser, bool);
using SteamHtmlJsDialogResponseFn = void (STDCALL *)(void *, SteamBrowser, bool);
using SteamHtmlFileDialogResponseFn = void (STDCALL *)(void *, SteamBrowser, const char **);
using SteamHtmlSetBackgroundModeFn = void (STDCALL *)(void *, SteamBrowser, bool);
using SteamHtmlSetKeyFocusFn = void (STDCALL *)(void *, SteamBrowser, bool);
using SteamHtmlExecuteJavascriptFn = void (STDCALL *)(void *, SteamBrowser, const char *);
using SteamHtmlMouseMoveFn = void (STDCALL *)(void *, SteamBrowser, i32, i32);
using SteamHtmlMouseButtonFn = void (STDCALL *)(void *, SteamBrowser, i32);
using SteamHtmlMouseWheelFn = void (STDCALL *)(void *, SteamBrowser, i32);
using SteamHtmlKeyDownFn = void (STDCALL *)(void *, SteamBrowser, u32, u32, bool);
using SteamHtmlKeyUpFn = void (STDCALL *)(void *, SteamBrowser, u32, u32);
using SteamHtmlKeyCharFn = void (STDCALL *)(void *, SteamBrowser, u32, u32);
using SteamRegisterCallbackFn = void (STDCALL *)(void *, i32);
using SteamUnregisterCallbackFn = void (STDCALL *)(void *);
using SteamRegisterCallResultFn = void (STDCALL *)(void *, SteamAPICall);
using SteamUnregisterCallResultFn = void (STDCALL *)(void *, SteamAPICall);

struct SteamHtmlFns {
    SteamHtmlAccessorFn accessor;
    SteamHtmlInitFn init;
    SteamHtmlShutdownFn shutdown;
    SteamHtmlCreateBrowserFn create_browser;
    SteamHtmlRemoveBrowserFn remove_browser;
    SteamHtmlLoadUrlFn load_url;
    SteamHtmlSetSizeFn set_size;
    SteamHtmlSimpleBrowserFn stop_load;
    SteamHtmlSimpleBrowserFn reload;
    SteamHtmlSimpleBrowserFn go_back;
    SteamHtmlSimpleBrowserFn go_forward;
    SteamHtmlAllowStartRequestFn allow_start;
    SteamHtmlJsDialogResponseFn js_dialog_response;
    SteamHtmlFileDialogResponseFn file_dialog_response;
    SteamHtmlSetBackgroundModeFn set_background_mode;
    SteamHtmlSetKeyFocusFn set_key_focus;
    SteamHtmlExecuteJavascriptFn execute_javascript;
    SteamHtmlMouseMoveFn mouse_move;
    SteamHtmlMouseButtonFn mouse_up;
    SteamHtmlMouseButtonFn mouse_down;
    SteamHtmlMouseButtonFn mouse_double_click;
    SteamHtmlMouseWheelFn mouse_wheel;
    SteamHtmlKeyDownFn key_down;
    SteamHtmlKeyUpFn key_up;
    SteamHtmlKeyCharFn key_char;
    SteamHtmlSimpleBrowserFn copy_to_clipboard;
    SteamHtmlSimpleBrowserFn paste_from_clipboard;
    SteamRegisterCallbackFn register_callback;
    SteamUnregisterCallbackFn unregister_callback;
    SteamRegisterCallResultFn register_call_result;
    SteamUnregisterCallResultFn unregister_call_result;
};

static SteamHtmlFns g_steam_html_fns{};
static void *g_steam_html_iface = nullptr;
static bool g_steam_html_initialized = false;
static bool g_steam_html_callbacks_registered = false;
static char g_steam_html_error[512]{};

static void steam_html_set_error(const char *text) {
    copy_cstr(g_steam_html_error, sizeof(g_steam_html_error), text ? text : "");
}

static const char *steam_html_error() {
    return g_steam_html_error;
}

class SteamCallbackBase {
public:
    SteamCallbackBase() : flags_(0), callback_(0) {}
    virtual void Run(void *) {}
    virtual void Run(void *, bool, SteamAPICall) {}
    virtual i32 GetCallbackSizeBytes() { return 0; }

    u8 flags_;
    i32 callback_;
};

static_assert(sizeof(SteamCallbackBase) == 16u);

static void steam_html_dispatch(i32 kind, i32 user, void *param, bool io_failure, SteamAPICall call);

class SteamCallbackThunk : public SteamCallbackBase {
public:
    SteamCallbackThunk(i32 size_bytes, i32 kind, i32 user)
        : size_bytes_(size_bytes), kind_(kind), user_(user) {
        callback_ = kind;
    }

    void Run(void *param) override {
        steam_html_dispatch(kind_, user_, param, false, 0u);
    }

    void Run(void *param, bool io_failure, SteamAPICall call) override {
        steam_html_dispatch(kind_, user_, param, io_failure, call);
    }

    i32 GetCallbackSizeBytes() override {
        return size_bytes_;
    }

private:
    i32 size_bytes_;
    i32 kind_;
    i32 user_;
};

static constexpr i32 STEAM_CALLBACK_COUNT = 10;
static constexpr i32 STEAM_CALLBACK_KINDS[STEAM_CALLBACK_COUNT] = {
    STEAM_HTML_NEEDS_PAINT,
    STEAM_HTML_START_REQUEST,
    STEAM_HTML_CLOSE_BROWSER,
    STEAM_HTML_URL_CHANGED,
    STEAM_HTML_FINISHED_REQUEST,
    STEAM_HTML_CHANGED_TITLE,
    STEAM_HTML_JS_ALERT,
    STEAM_HTML_JS_CONFIRM,
    STEAM_HTML_FILE_OPEN,
    STEAM_HTML_NEW_WINDOW,
};
static constexpr i32 STEAM_CALLBACK_SIZES[STEAM_CALLBACK_COUNT] = {
    static_cast<i32>(sizeof(SteamHtmlNeedsPaint)),
    static_cast<i32>(sizeof(SteamHtmlStartRequest)),
    static_cast<i32>(sizeof(SteamHtmlCloseBrowser)),
    static_cast<i32>(sizeof(SteamHtmlUrlChanged)),
    static_cast<i32>(sizeof(SteamHtmlFinishedRequest)),
    static_cast<i32>(sizeof(SteamHtmlChangedTitle)),
    static_cast<i32>(sizeof(SteamHtmlJsDialog)),
    static_cast<i32>(sizeof(SteamHtmlJsDialog)),
    static_cast<i32>(sizeof(SteamHtmlFileOpen)),
    static_cast<i32>(sizeof(SteamHtmlNewWindow)),
};

alignas(SteamCallbackThunk) static u8 g_steam_callback_storage[STEAM_CALLBACK_COUNT][sizeof(SteamCallbackThunk)]{};
static SteamCallbackThunk *g_steam_callbacks[STEAM_CALLBACK_COUNT]{};
alignas(SteamCallbackThunk) static u8 g_steam_restart_storage[sizeof(SteamCallbackThunk)]{};
static SteamCallbackThunk *g_steam_restart_callback = nullptr;
alignas(SteamCallbackThunk) static u8 g_steam_ready_storage[MAX_BROWSERS][sizeof(SteamCallbackThunk)]{};
static SteamCallbackThunk *g_steam_ready_results[MAX_BROWSERS]{};

static BrowserState *steam_browser_by_handle(SteamBrowser handle) {
    if (!handle) {
        return nullptr;
    }

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (atomic_load_u32(&browser.used) &&
            !atomic_load_u32(&browser.destroy_pending) &&
            browser.steam_browser == handle) {
            return &browser;
        }
    }

    return nullptr;
}

static bool steam_html_resolve() {
    if (g_steam_html_iface) {
        return true;
    }

    WCHAR steam_name[] = L"steam_api64.dll";
    HMODULE steam = find_loaded_module(steam_name);

    if (!steam) {
        steam_html_set_error("steam_api64.dll is not loaded");
        return false;
    }

#define STEAM_RESOLVE(field, type, name) do { \
    g_steam_html_fns.field = reinterpret_cast<type>(get_proc(steam, name)); \
    if (!g_steam_html_fns.field) { \
        steam_html_set_error("missing Steam HTML export: " name); \
        return false; \
    } \
} while (0)

    STEAM_RESOLVE(accessor, SteamHtmlAccessorFn, "SteamAPI_SteamHTMLSurface_v005");
    STEAM_RESOLVE(init, SteamHtmlInitFn, "SteamAPI_ISteamHTMLSurface_Init");
    STEAM_RESOLVE(shutdown, SteamHtmlShutdownFn, "SteamAPI_ISteamHTMLSurface_Shutdown");
    STEAM_RESOLVE(create_browser, SteamHtmlCreateBrowserFn, "SteamAPI_ISteamHTMLSurface_CreateBrowser");
    STEAM_RESOLVE(remove_browser, SteamHtmlRemoveBrowserFn, "SteamAPI_ISteamHTMLSurface_RemoveBrowser");
    STEAM_RESOLVE(load_url, SteamHtmlLoadUrlFn, "SteamAPI_ISteamHTMLSurface_LoadURL");
    STEAM_RESOLVE(set_size, SteamHtmlSetSizeFn, "SteamAPI_ISteamHTMLSurface_SetSize");
    STEAM_RESOLVE(stop_load, SteamHtmlSimpleBrowserFn, "SteamAPI_ISteamHTMLSurface_StopLoad");
    STEAM_RESOLVE(reload, SteamHtmlSimpleBrowserFn, "SteamAPI_ISteamHTMLSurface_Reload");
    STEAM_RESOLVE(go_back, SteamHtmlSimpleBrowserFn, "SteamAPI_ISteamHTMLSurface_GoBack");
    STEAM_RESOLVE(go_forward, SteamHtmlSimpleBrowserFn, "SteamAPI_ISteamHTMLSurface_GoForward");
    STEAM_RESOLVE(allow_start, SteamHtmlAllowStartRequestFn, "SteamAPI_ISteamHTMLSurface_AllowStartRequest");
    STEAM_RESOLVE(js_dialog_response, SteamHtmlJsDialogResponseFn, "SteamAPI_ISteamHTMLSurface_JSDialogResponse");
    STEAM_RESOLVE(file_dialog_response, SteamHtmlFileDialogResponseFn, "SteamAPI_ISteamHTMLSurface_FileLoadDialogResponse");
    STEAM_RESOLVE(set_background_mode, SteamHtmlSetBackgroundModeFn, "SteamAPI_ISteamHTMLSurface_SetBackgroundMode");
    STEAM_RESOLVE(set_key_focus, SteamHtmlSetKeyFocusFn, "SteamAPI_ISteamHTMLSurface_SetKeyFocus");
    STEAM_RESOLVE(execute_javascript, SteamHtmlExecuteJavascriptFn, "SteamAPI_ISteamHTMLSurface_ExecuteJavascript");
    STEAM_RESOLVE(mouse_move, SteamHtmlMouseMoveFn, "SteamAPI_ISteamHTMLSurface_MouseMove");
    STEAM_RESOLVE(mouse_up, SteamHtmlMouseButtonFn, "SteamAPI_ISteamHTMLSurface_MouseUp");
    STEAM_RESOLVE(mouse_down, SteamHtmlMouseButtonFn, "SteamAPI_ISteamHTMLSurface_MouseDown");
    STEAM_RESOLVE(mouse_double_click, SteamHtmlMouseButtonFn, "SteamAPI_ISteamHTMLSurface_MouseDoubleClick");
    STEAM_RESOLVE(mouse_wheel, SteamHtmlMouseWheelFn, "SteamAPI_ISteamHTMLSurface_MouseWheel");
    STEAM_RESOLVE(key_down, SteamHtmlKeyDownFn, "SteamAPI_ISteamHTMLSurface_KeyDown");
    STEAM_RESOLVE(key_up, SteamHtmlKeyUpFn, "SteamAPI_ISteamHTMLSurface_KeyUp");
    STEAM_RESOLVE(key_char, SteamHtmlKeyCharFn, "SteamAPI_ISteamHTMLSurface_KeyChar");
    STEAM_RESOLVE(copy_to_clipboard, SteamHtmlSimpleBrowserFn, "SteamAPI_ISteamHTMLSurface_CopyToClipboard");
    STEAM_RESOLVE(paste_from_clipboard, SteamHtmlSimpleBrowserFn, "SteamAPI_ISteamHTMLSurface_PasteFromClipboard");
    STEAM_RESOLVE(register_callback, SteamRegisterCallbackFn, "SteamAPI_RegisterCallback");
    STEAM_RESOLVE(unregister_callback, SteamUnregisterCallbackFn, "SteamAPI_UnregisterCallback");
    STEAM_RESOLVE(register_call_result, SteamRegisterCallResultFn, "SteamAPI_RegisterCallResult");
    STEAM_RESOLVE(unregister_call_result, SteamUnregisterCallResultFn, "SteamAPI_UnregisterCallResult");

#undef STEAM_RESOLVE

    g_steam_html_iface = g_steam_html_fns.accessor();

    if (!g_steam_html_iface) {
        steam_html_set_error("Steam HTML Surface v005 is unavailable");
        return false;
    }

    steam_html_set_error("");
    return true;
}

static void steam_html_register_callbacks() {
    if (g_steam_html_callbacks_registered || !g_steam_html_fns.register_callback) {
        return;
    }

    for (i32 i = 0; i < STEAM_CALLBACK_COUNT; ++i) {
        auto *callback = reinterpret_cast<SteamCallbackThunk *>(g_steam_callback_storage[i]);
        callback = new (callback) SteamCallbackThunk(STEAM_CALLBACK_SIZES[i], STEAM_CALLBACK_KINDS[i], -1);
        g_steam_callbacks[i] = callback;
        g_steam_html_fns.register_callback(callback, STEAM_CALLBACK_KINDS[i]);
    }

    auto *restart = reinterpret_cast<SteamCallbackThunk *>(g_steam_restart_storage);
    restart = new (restart) SteamCallbackThunk(
        static_cast<i32>(sizeof(SteamHtmlBrowserRestarted)),
        STEAM_HTML_BROWSER_RESTARTED,
        -1);
    g_steam_restart_callback = restart;
    g_steam_html_fns.register_callback(restart, STEAM_HTML_BROWSER_RESTARTED);

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        auto *ready = reinterpret_cast<SteamCallbackThunk *>(g_steam_ready_storage[i]);
        ready = new (ready) SteamCallbackThunk(
            static_cast<i32>(sizeof(SteamHtmlBrowserReady)),
            STEAM_HTML_BROWSER_READY,
            i);
        g_steam_ready_results[i] = ready;
    }

    g_steam_html_callbacks_registered = true;
}

static void steam_html_unregister_callbacks() {
    if (!g_steam_html_callbacks_registered) {
        return;
    }

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (browser.steam_create_call && g_steam_ready_results[i] && g_steam_html_fns.unregister_call_result) {
            g_steam_html_fns.unregister_call_result(g_steam_ready_results[i], browser.steam_create_call);
        }

        browser.steam_create_call = 0u;
    }

    if (g_steam_html_fns.unregister_callback) {
        for (i32 i = 0; i < STEAM_CALLBACK_COUNT; ++i) {
            if (g_steam_callbacks[i]) {
                g_steam_html_fns.unregister_callback(g_steam_callbacks[i]);
            }
        }

        if (g_steam_restart_callback) {
            g_steam_html_fns.unregister_callback(g_steam_restart_callback);
        }
    }

    for (i32 i = 0; i < STEAM_CALLBACK_COUNT; ++i) {
        g_steam_callbacks[i] = nullptr;
    }

    g_steam_restart_callback = nullptr;

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        g_steam_ready_results[i] = nullptr;
    }

    g_steam_html_callbacks_registered = false;
}

static bool steam_html_ensure() {
    if (g_steam_html_initialized) {
        return true;
    }

    if (!steam_html_resolve()) {
        return false;
    }

    steam_html_register_callbacks();

    if (!g_steam_html_fns.init(g_steam_html_iface)) {
        steam_html_set_error("ISteamHTMLSurface::Init failed");
        return false;
    }

    g_steam_html_initialized = true;
    steam_html_set_error("");
    return true;
}

static bool steam_html_copy_string(char *dst, usize cap, const char *src) {
    if (!src) {
        return false;
    }

    const usize length = slen(src);

    if (!valid_utf8(src, length)) {
        return false;
    }

    copy_chars(dst, cap, src, length);
    return true;
}

static u32 steam_utf8_next(const char *text, usize length, usize *offset) {
    if (!text || !offset || *offset >= length) {
        return 0u;
    }

    usize i = *offset;
    const u8 first = static_cast<u8>(text[i++]);

    if (first < 0x80u) {
        *offset = i;
        return first;
    }

    u32 codepoint = 0u;
    u32 extra = 0u;

    if ((first & 0xe0u) == 0xc0u) {
        codepoint = first & 0x1fu;
        extra = 1u;
    } else if ((first & 0xf0u) == 0xe0u) {
        codepoint = first & 0x0fu;
        extra = 2u;
    } else if ((first & 0xf8u) == 0xf0u) {
        codepoint = first & 0x07u;
        extra = 3u;
    } else {
        *offset = i;
        return 0xfffdu;
    }

    for (u32 j = 0; j < extra && i < length; ++j) {
        const u8 next = static_cast<u8>(text[i++]);

        if ((next & 0xc0u) != 0x80u) {
            *offset = i;
            return 0xfffdu;
        }

        codepoint = (codepoint << 6u) | (next & 0x3fu);
    }

    *offset = i;
    return codepoint ? codepoint : 0xfffdu;
}

static void steam_html_browser_ready(BrowserState &browser, SteamBrowser handle) {
    browser.steam_browser = handle;
    g_steam_html_fns.set_size(
        g_steam_html_iface,
        handle,
        static_cast<u32>(browser.width),
        static_cast<u32>(browser.height));
    g_steam_html_fns.set_background_mode(
        g_steam_html_iface,
        handle,
        atomic_load_u32(&browser.desired_visible) == 0u);
    g_steam_html_fns.set_key_focus(
        g_steam_html_iface,
        handle,
        atomic_load_u32(&browser.desired_focus) != 0u);
    atomic_store_u32(&browser.ready, 1u);

    if (browser.desired_url[0]) {
        atomic_store_u32(&browser.loading, 1u);
        g_steam_html_fns.load_url(g_steam_html_iface, handle, browser.desired_url, nullptr);
    }

    set_error(&browser, "");
    dr_refresh_request();

    if (atomic_load_u32(&browser.desired_visible) && !dr_enable()) {
        set_error(&browser, dr_get_error());
    }
}

static void steam_html_dispatch(i32 kind, i32 user, void *param, bool io_failure, SteamAPICall call) {
    if (!param || !g_steam_html_iface) {
        return;
    }

    if (kind == STEAM_HTML_BROWSER_READY) {
        if (user < 0 || user >= MAX_BROWSERS) {
            return;
        }

        BrowserState &browser = g_browsers[user];

        if (!atomic_load_u32(&browser.used) ||
            atomic_load_u32(&browser.destroy_pending) ||
            !browser.steam_create_call ||
            (call && browser.steam_create_call != call)) {
            return;
        }

        browser.steam_create_call = 0u;

        if (io_failure) {
            set_error(&browser, "Steam HTML CreateBrowser call failed");
            return;
        }

        auto *ready = static_cast<SteamHtmlBrowserReady *>(param);

        if (!ready->browser) {
            set_error(&browser, "Steam HTML returned an invalid browser handle");
            return;
        }

        steam_html_browser_ready(browser, ready->browser);
        return;
    }

    if (kind == STEAM_HTML_BROWSER_RESTARTED) {
        auto *restart = static_cast<SteamHtmlBrowserRestarted *>(param);
        BrowserState *browser = steam_browser_by_handle(restart->old_browser);

        if (!browser || !restart->browser) {
            return;
        }

        steam_html_browser_ready(*browser, restart->browser);
        return;
    }

    const SteamBrowser handle = *static_cast<SteamBrowser *>(param);
    BrowserState *browser = steam_browser_by_handle(handle);

    if (!browser) {
        return;
    }

    switch (kind) {
        case STEAM_HTML_NEEDS_PAINT: {
            auto *paint = static_cast<SteamHtmlNeedsPaint *>(param);

            if (!frame_publish(*browser, reinterpret_cast<const u8 *>(paint->bgra), paint->width, paint->height)) {
                set_error(browser, "Steam HTML paint could not be stored");
            } else {
                set_error(browser, "");
            }
            break;
        }
        case STEAM_HTML_START_REQUEST: {
            auto *request = static_cast<SteamHtmlStartRequest *>(param);
            g_steam_html_fns.allow_start(g_steam_html_iface, request->browser, true);
            atomic_store_u32(&browser->loading, 1u);
            break;
        }
        case STEAM_HTML_CLOSE_BROWSER:
            atomic_store_u32(&browser->desired_visible, 0u);
            dr_refresh_request();
            break;
        case STEAM_HTML_URL_CHANGED: {
            auto *changed = static_cast<SteamHtmlUrlChanged *>(param);
            steam_html_copy_string(browser->url, sizeof(browser->url), changed->url);
            steam_html_copy_string(browser->title, sizeof(browser->title), changed->page_title);
            break;
        }
        case STEAM_HTML_FINISHED_REQUEST: {
            auto *finished = static_cast<SteamHtmlFinishedRequest *>(param);
            steam_html_copy_string(browser->url, sizeof(browser->url), finished->url);
            steam_html_copy_string(browser->title, sizeof(browser->title), finished->page_title);
            atomic_store_u32(&browser->loading, 0u);
            break;
        }
        case STEAM_HTML_CHANGED_TITLE: {
            auto *changed = static_cast<SteamHtmlChangedTitle *>(param);
            steam_html_copy_string(browser->title, sizeof(browser->title), changed->title);
            break;
        }
        case STEAM_HTML_JS_ALERT:
        case STEAM_HTML_JS_CONFIRM:
            g_steam_html_fns.js_dialog_response(g_steam_html_iface, handle, true);
            break;
        case STEAM_HTML_FILE_OPEN:
            g_steam_html_fns.file_dialog_response(g_steam_html_iface, handle, nullptr);
            break;
        case STEAM_HTML_NEW_WINDOW: {
            auto *window = static_cast<SteamHtmlNewWindow *>(param);

            if (browser->popup_policy == POPUP_SAME_BROWSER && window->url && window->url[0]) {
                g_steam_html_fns.load_url(g_steam_html_iface, handle, window->url, nullptr);
            }
            break;
        }
        default:
            break;
    }
}

static bool steam_html_create(BrowserState &browser) {
    if (!steam_html_ensure()) {
        set_error(&browser, steam_html_error());
        return false;
    }

    const SteamAPICall call = g_steam_html_fns.create_browser(g_steam_html_iface, "DarktideBrowser", nullptr);

    if (!call) {
        set_error(&browser, "ISteamHTMLSurface::CreateBrowser returned an invalid call handle");
        return false;
    }

    browser.steam_create_call = call;
    browser.steam_browser = INVALID_STEAM_BROWSER;
    browser.steam_frame_sequence = 0u;
    atomic_store_u32(&browser.ready, 0u);
    g_steam_html_fns.register_call_result(g_steam_ready_results[browser.slot], call);
    set_error(&browser, "");
    return true;
}

static void steam_html_destroy(BrowserState &browser) {
    atomic_store_u32(&browser.desired_visible, 0u);
    atomic_store_u32(&browser.ready, 0u);
    atomic_store_u32(&browser.destroy_pending, 1u);

    if (browser.steam_create_call && g_steam_ready_results[browser.slot] && g_steam_html_fns.unregister_call_result) {
        g_steam_html_fns.unregister_call_result(g_steam_ready_results[browser.slot], browser.steam_create_call);
        browser.steam_create_call = 0u;
    }

    if (browser.steam_browser && g_steam_html_iface && g_steam_html_fns.remove_browser) {
        g_steam_html_fns.remove_browser(g_steam_html_iface, browser.steam_browser);
        browser.steam_browser = 0u;
    }
}

static bool steam_html_browser_ready(BrowserState *browser) {
    return browser &&
           atomic_load_u32(&browser->ready) &&
           browser->steam_browser != 0u &&
           !atomic_load_u32(&browser->destroy_pending);
}

static void steam_html_shutdown_all() {
    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (atomic_load_u32(&browser.used) && (browser.steam_browser || browser.steam_create_call)) {
            steam_html_destroy(browser);
        }
    }

    steam_html_unregister_callbacks();

    if (g_steam_html_initialized && g_steam_html_iface && g_steam_html_fns.shutdown) {
        g_steam_html_fns.shutdown(g_steam_html_iface);
    }

    g_steam_html_initialized = false;
    g_steam_html_iface = nullptr;
    memset(&g_steam_html_fns, 0, sizeof(g_steam_html_fns));
}
