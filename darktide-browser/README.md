# Darktide Browser

https://www.nexusmods.com/warhammer40kdarktide/mods/1311

The Lua side loads `darktide-browser-runtime.dll` through LuaJIT FFI. The runtime uses Steamworks `ISteamHTMLSurface` for browser rendering and copies browser frames into Darktide D3D12 render targets.

## Lua API

```lua
local browser = get_mod("DarktideBrowser")
local handle, err = browser.create(1280, 720)
if not handle then
    error(err)
end

browser.navigate(handle, "https://example.com")
browser.set_visible(handle, true)
browser.set_focus(handle, true)
```

Lifecycle and state:

```lua
browser.is_ready(handle)
browser.is_visible(handle)
browser.is_loading(handle)
browser.is_render_target_presented(handle)
browser.get_url(handle)
browser.get_title(handle)
browser.get_error(handle)
browser.get_renderer_error()

browser.navigate(handle, url)
browser.reload(handle)
browser.stop(handle)
browser.back(handle)
browser.forward(handle)
browser.set_size(handle, width, height)
browser.set_position(handle, x, y)
browser.set_visible(handle, visible)
browser.set_focus(handle, focused)
browser.execute_javascript(handle, script)
browser.destroy(handle)
```

Render-target output:

```lua
browser.set_render_target(handle, reference_name, x, y, width, height)
browser.clear_render_target(handle)
```

`reference_name` is the name used when the Darktide render target was created. Clear the browser target before destroying the engine render target.

Input:

```lua
browser.mouse_move(handle, x, y)
browser.mouse_button_event(handle, browser.mouse_button.left, true, 1)
browser.mouse_button_event(handle, browser.mouse_button.left, false, 1)
browser.mouse_wheel(handle, delta)
browser.key(handle, virtual_key, down, modifiers, system_key)
browser.char(handle, utf8_text, modifiers)
browser.copy_to_clipboard(handle)
browser.paste_from_clipboard(handle)
```

Modifier bits are alt `1`, control `2`, and shift `4`.
