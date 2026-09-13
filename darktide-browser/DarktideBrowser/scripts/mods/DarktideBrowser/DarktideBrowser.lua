local mod = get_mod("DarktideBrowser")
local native = mod:io_dofile("DarktideBrowser/scripts/mods/DarktideBrowser/native")
local initialized, initialize_error = native.initialize()

if not initialized then
    mod:error(initialize_error)
    error(initialize_error)
end

mod.mouse_button = {
    left = 0,
    right = 1,
    middle = 2,
}

mod.key_modifier = {
    alt = 1,
    control = 2,
    shift = 4,
}

mod.create = native.create
mod.destroy = native.destroy
mod.is_ready = native.is_ready
mod.is_visible = native.is_visible
mod.is_loading = native.is_loading
mod.is_render_target_presented = native.is_render_target_presented
mod.get_url = native.url
mod.get_title = native.title
mod.get_error = native.error
mod.get_renderer_error = native.renderer_error
mod.navigate = native.navigate
mod.reload = native.reload
mod.stop = native.stop
mod.back = native.back
mod.forward = native.forward
mod.set_size = native.set_size
mod.set_position = native.set_position
mod.set_render_target = native.set_render_target
mod.clear_render_target = native.clear_render_target
mod.set_visible = native.set_visible
mod.set_focus = native.set_focus
mod.execute_javascript = native.execute_javascript
mod.mouse_move = native.mouse_move
mod.mouse_button_event = native.mouse_button
mod.mouse_wheel = native.mouse_wheel
mod.key = native.key
mod.char = native.char
mod.copy_to_clipboard = native.copy_to_clipboard
mod.paste_from_clipboard = native.paste_from_clipboard

mod.on_unload = function()
    native.shutdown()
end
