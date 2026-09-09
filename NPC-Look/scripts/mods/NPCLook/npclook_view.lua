local mod = get_mod("NPCLook")
local util = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_util")
local loc = util.localize

local UIRenderer = require("scripts/managers/ui/ui_renderer")
local UIWidget = require("scripts/managers/ui/ui_widget")
local UIWorkspaceSettings = require("scripts/settings/ui/ui_workspace_settings")
local TextInputPassTemplates = require("scripts/ui/pass_templates/text_input_pass_templates")

local VIEW_NAME = "npclook_studio_view"
local PREVIEW_VIEW_NAME = "npclook_studio_preview_view"
local NONE = loc("generic_none")
local W, H = 1920, 1080
local PAD = 22
local LEFT_X, LEFT_W = PAD, 410
local RIGHT_X, RIGHT_W = W - PAD - 410, 410
local CENTER_X = LEFT_X + LEFT_W + 18
local CENTER_W = RIGHT_X - 18 - CENTER_X
local HEADER_Y = 8
local HEADER_HEIGHT = 56
local HEADER_CONTENT_Y = HEADER_Y + 8
local PREVIEW_HEADER_Y = HEADER_Y
local TOP_Y = 76
local FOOTER_Y = 940
local EXTRA_ACTION_X = CENTER_X + CENTER_W - 420
local VISUAL_PANEL_W = 236
local VISUAL_PANEL_X = EXTRA_ACTION_X - VISUAL_PANEL_W - 8
local VISUAL_PANEL_BOTTOM = 925
local VISUAL_ROW_H = 30
local VISUAL_ROW_GAP = 4
local VISUAL_PANEL_MIN_H = VISUAL_ROW_H

local ITEM_MODES = {
    all = true,
    materials = true,
    nodes = true,
    slot = true,
    units = true,
}
local CAMERA_FOCUS_MODES = {
    full = true,
    head = true,
    legs = true,
    torso = true,
}

local C = {
    transparent = { 0, 0, 0, 0 },
    screen_tint = { 110, 3, 5, 7 },
    panel = { 248, 10, 13, 17 },
    panel_alt = { 238, 17, 21, 27 },
    panel_soft = { 225, 22, 27, 34 },
    line = { 255, 157, 124, 58 },
    line_dim = { 170, 96, 82, 52 },
    text = { 255, 221, 224, 216 },
    dim = { 255, 134, 140, 139 },
    gold = { 255, 255, 207, 112 },
    green = { 255, 132, 222, 151 },
    blue = { 255, 119, 181, 232 },
    red = { 255, 242, 97, 83 },
    button = { 224, 36, 42, 50 },
    button_hover = { 238, 65, 75, 88 },
    selected = { 235, 78, 65, 34 },
    selected_hover = { 245, 104, 84, 42 },
    changed = { 232, 44, 73, 51 },
    hidden = { 232, 78, 31, 31 },
    disabled = { 210, 23, 26, 30 },
}

local function normalized_array(value)
    return type(value) == "table" and value or {}
end

local function normalized_number(value, fallback, minimum, maximum)
    value = tonumber(value)

    if not value or value ~= value or value == math.huge or value == -math.huge then
        value = fallback or 0
    end

    if minimum and value < minimum then
        value = minimum
    end

    if maximum and value > maximum then
        value = maximum
    end

    return value
end

local function close_view_safely(view_name)
    local ui_manager = Managers.ui

    if not ui_manager or type(ui_manager.close_view) ~= "function" then
        return false
    end

    local ok, err = pcall(ui_manager.close_view, ui_manager, view_name)

    if not ok then
        mod:warning("Could not close Studio view %s: %s", tostring(view_name), tostring(err))
    end

    return ok
end

local function normalize_snapshot(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}

    local sources = {}

    for i, entry in ipairs(normalized_array(snapshot.sources)) do
        if type(entry) == "table" then
            sources[#sources + 1] = {
                id = entry.id,
                label = tostring(entry.label or entry.id or loc("generic_source") .. " " .. tostring(i)),
                sub = tostring(entry.sub or ""),
                selected = entry.selected == true,
            }
        end
    end

    local source_slots = {}

    for _, entry in ipairs(normalized_array(snapshot.source_slots)) do
        if type(entry) == "table" then
            source_slots[#source_slots + 1] = {
                slot_label = tostring(entry.slot_label or entry.slot or loc("generic_slot")),
                item_label = tostring(entry.item_label or entry.item or string.lower(NONE)),
            }
        end
    end

    local items = {}

    for i, entry in ipairs(normalized_array(snapshot.items)) do
        if type(entry) == "table" then
            items[#items + 1] = {
                id = entry.id,
                slot = entry.slot,
                label = tostring(entry.label or entry.id or loc("generic_item") .. " " .. tostring(i)),
                sub = tostring(entry.sub or ""),
                selected = entry.selected == true,
                applicable = entry.applicable ~= false,
            }
        end
    end

    local slots = {}

    for _, entry in ipairs(normalized_array(snapshot.slots)) do
        if type(entry) == "table" and type(entry.id) == "string" then
            slots[#slots + 1] = {
                id = entry.id,
                label = tostring(entry.label or entry.id),
                item_label = tostring(entry.item_label or string.lower(NONE)),
                selected = entry.selected == true,
                changed = entry.changed == true,
                hidden = entry.hidden == true,
                empty = entry.empty == true,
                inherited = entry.inherited == true,
            }
        end
    end

    snapshot.sources = sources
    snapshot.source_slots = source_slots
    snapshot.items = items
    snapshot.slots = slots
    if type(snapshot.selected_details) == "table" then
        snapshot.selected_details = {
            name = tostring(snapshot.selected_details.name or ""),
            slots = normalized_array(snapshot.selected_details.slots),
            hide_slots = normalized_array(snapshot.selected_details.hide_slots),
            base_unit = snapshot.selected_details.base_unit,
            variant_families = normalized_array(snapshot.selected_details.variant_families),
            visibility_groups = normalized_array(snapshot.selected_details.visibility_groups),
            mesh_count = tonumber(snapshot.selected_details.mesh_count),
            estimated_variant_combinations = tonumber(snapshot.selected_details.estimated_variant_combinations),
            unit_category = snapshot.selected_details.unit_category,
            package_source = snapshot.selected_details.package_source,
            package_name = snapshot.selected_details.package_name,
            package_members = tonumber(snapshot.selected_details.package_members),
            package_count = tonumber(snapshot.selected_details.package_count),
            membership_count = tonumber(snapshot.selected_details.membership_count),
            variant_parse_failure = snapshot.selected_details.variant_parse_failure,
        }
    else
        snapshot.selected_details = nil
    end
    snapshot.selected_opacity = normalized_number(snapshot.selected_opacity, 100, 0, 100)
    snapshot.can_edit_variants = snapshot.can_edit_variants == true
    snapshot.variant_family_count = normalized_number(snapshot.variant_family_count, 0, 0)
    snapshot.variant_family_index = normalized_number(snapshot.variant_family_index, 1, 1)
    snapshot.variant_family_name = snapshot.variant_family_name
    snapshot.variant_family_options = normalized_array(snapshot.variant_family_options)
    snapshot.variant_family_value = snapshot.variant_family_value
    snapshot.visibility_group_count = normalized_number(snapshot.visibility_group_count, 0, 0)
    snapshot.visibility_group_index = normalized_number(snapshot.visibility_group_index, 1, 1)
    snapshot.visibility_group_name = snapshot.visibility_group_name
    snapshot.visibility_group_value = snapshot.visibility_group_value
    snapshot.can_edit_masks = snapshot.can_edit_masks == true
    snapshot.can_switch_visual_options = snapshot.can_switch_visual_options == true
    snapshot.visual_options_mode = snapshot.visual_options_mode == "masks" and "masks" or "variants"
    snapshot.can_switch_variant_controls = snapshot.can_switch_variant_controls == true
    snapshot.variant_control_mode = snapshot.variant_control_mode == "visibility"
        and "visibility" or "families"
    local mask_rows = {}

    for i, row in ipairs(normalized_array(snapshot.mask_rows)) do
        if type(row) == "table" and type(row.field) == "string" then
            mask_rows[#mask_rows + 1] = {
                can_toggle = row.can_toggle == true,
                enabled = row.enabled == true,
                field = row.field,
                field_label = tostring(row.field_label or row.field),
                option_count = normalized_number(row.option_count, 0, 0),
                value_label = tostring(row.value_label or loc("ui_mask_off")),
            }
        end
    end

    snapshot.mask_rows = mask_rows
    snapshot.source_page = normalized_number(snapshot.source_page, 1, 1)
    snapshot.source_page_count = normalized_number(snapshot.source_page_count, 1, 1)
    snapshot.item_page = normalized_number(snapshot.item_page, 1, 1)
    snapshot.item_page_count = normalized_number(snapshot.item_page_count, 1, 1)
    snapshot.item_result_count = normalized_number(snapshot.item_result_count, #items, 0)
    snapshot.item_search = tostring(snapshot.item_search or "")
    snapshot.dirty_count = normalized_number(snapshot.dirty_count, 0, 0)
    snapshot.slot_page = normalized_number(snapshot.slot_page, 1, 1)
    snapshot.slot_page_count = normalized_number(snapshot.slot_page_count, 1, 1)
    snapshot.can_remove_extra_slot = snapshot.can_remove_extra_slot == true
    snapshot.can_toggle_extra_first_person = snapshot.can_toggle_extra_first_person == true
    snapshot.can_toggle_extra_first_person_animation = snapshot.can_toggle_extra_first_person_animation == true
    snapshot.can_toggle_extra_transform = snapshot.can_toggle_extra_transform == true
    snapshot.can_edit_extra_transform = snapshot.can_edit_extra_transform == true
    snapshot.can_toggle_extra_transform_deform = snapshot.can_toggle_extra_transform_deform == true
    snapshot.can_toggle_extra_xyz_scale = snapshot.can_toggle_extra_xyz_scale == true
    local transform = type(snapshot.selected_extra_transform) == "table" and snapshot.selected_extra_transform or {}
    local uniform_scale = normalized_number(transform.scale, 1, -30, 30)

    snapshot.selected_extra_transform = {
        enabled = transform.enabled == true,
        deform = transform.deform ~= false,
        first_person = transform.first_person == true,
        animate_first_person = transform.first_person == true
            and transform.animate_first_person == true,
        px = normalized_number(transform.px, 0, -5, 5),
        py = normalized_number(transform.py, 0, -5, 5),
        pz = normalized_number(transform.pz, 0, -5, 5),
        rx = normalized_number(transform.rx, 0, -180, 180),
        ry = normalized_number(transform.ry, 0, -180, 180),
        rz = normalized_number(transform.rz, 0, -180, 180),
        xyz_scale = transform.xyz_scale == true,
        scale = uniform_scale,
        scale_x = normalized_number(transform.scale_x, uniform_scale, -30, 30),
        scale_y = normalized_number(transform.scale_y, uniform_scale, -30, 30),
        scale_z = normalized_number(transform.scale_z, uniform_scale, -30, 30),
        attach_node = type(transform.attach_node) == "string" and transform.attach_node or nil,
        materials = normalized_array(transform.materials),
    }
    snapshot.selected_item_applicable = snapshot.selected_item_applicable == true
    snapshot.can_remove_all_extra_slots = snapshot.can_remove_all_extra_slots == true
    snapshot.selected_slot_label = tostring(snapshot.selected_slot_label or snapshot.selected_slot or NONE)
    snapshot.selected_source_label = tostring(snapshot.selected_source_label or NONE)
    snapshot.feedback = tostring(snapshot.feedback or "")
    snapshot.source_kind = snapshot.source_kind == "family" and "family"
        or snapshot.source_kind == "player" and "player"
        or "preset"
    snapshot.item_mode = ITEM_MODES[snapshot.item_mode] and snapshot.item_mode or "slot"
    snapshot.can_use_units = snapshot.can_use_units == true
    snapshot.can_use_nodes = snapshot.can_use_nodes == true
    snapshot.node_mode = snapshot.node_mode == true
    snapshot.node_skeleton_visible = snapshot.node_skeleton_visible == true
    snapshot.selected_attach_node = type(snapshot.selected_attach_node) == "string"
        and snapshot.selected_attach_node or nil
    snapshot.preview_attach_node = type(snapshot.preview_attach_node) == "string"
        and snapshot.preview_attach_node or snapshot.selected_attach_node
    snapshot.material_mode = snapshot.material_mode == true
    snapshot.selected_materials = normalized_array(snapshot.selected_materials)
    snapshot.material_targets = normalized_array(snapshot.material_targets)
    snapshot.material_target = tostring(snapshot.material_target or "")
    snapshot.material_target_label = tostring(snapshot.material_target_label or loc("ui_material_target_all"))
    snapshot.can_pick_materials = snapshot.can_pick_materials == true
    snapshot.show_authored_slots = snapshot.show_authored_slots == true
    snapshot.can_undo = snapshot.can_undo == true
    snapshot.can_redo = snapshot.can_redo == true
    snapshot.inspect_mode = snapshot.inspect_mode == true
    snapshot.camera_focus = CAMERA_FOCUS_MODES[snapshot.camera_focus]
        and snapshot.camera_focus
        or nil
    return snapshot
end

-- Widget definitions

local function rule_definition()
    return UIWidget.create_definition({
        {
            pass_type = "rect",
            style_id = "bg",
            style = {
                color = C.line,
                size = { 10, 1 },
                offset = { 0, 0, 3 },
            },
        },
    }, "panel")
end

local function label_definition()
    return UIWidget.create_definition({
        {
            pass_type = "text",
            style_id = "text",
            value_id = "label",
            value = "",
            style = {
                font_size = 16,
                font_type = "machine_medium",
                text_horizontal_alignment = "left",
                text_vertical_alignment = "center",
                text_color = C.text,
                drop_shadow = true,
                offset = { 0, 0, 5 },
                size = { 10, 10 },
            },
            change_function = function(content, style)
                style.text_color = content._color or C.text
            end,
        },
    }, "panel")
end

local TRANSFORM_FIELDS = {
    {
        field = "px", label = "X", x = CENTER_X + 178, y = 827,
        width = 142, input_x = CENTER_X + 225, input_width = 66,
        delta = 0.01, decimals = 4,
    },
    {
        field = "py", label = "Y", x = CENTER_X + 326, y = 827,
        width = 142, input_x = CENTER_X + 373, input_width = 66,
        delta = 0.01, decimals = 4,
    },
    {
        field = "pz", label = "Z", x = CENTER_X + 474, y = 827,
        width = 142, input_x = CENTER_X + 521, input_width = 66,
        delta = 0.01, decimals = 4,
    },
    {
        field = "rx", label = "RX", x = CENTER_X + 178, y = 858,
        width = 132, input_x = CENTER_X + 228, input_width = 54,
        delta = 5, decimals = 3,
    },
    {
        field = "ry", label = "RY", x = CENTER_X + 316, y = 858,
        width = 132, input_x = CENTER_X + 366, input_width = 54,
        delta = 5, decimals = 3,
    },
    {
        field = "rz", label = "RZ", x = CENTER_X + 454, y = 858,
        width = 132, input_x = CENTER_X + 504, input_width = 54,
        delta = 5, decimals = 3,
    },
    {
        field = "scale", label = "S", x = CENTER_X + 592, y = 858,
        width = 138, input_x = CENTER_X + 639, input_width = 62,
        delta = 0.05, decimals = 4, scale_mode = "uniform",
    },
    {
        field = "scale_x", label = "X", x = CENTER_X + 592, y = 796,
        width = 138, input_x = CENTER_X + 639, input_width = 62,
        decimals = 4, scale_mode = "xyz",
    },
    {
        field = "scale_y", label = "Y", x = CENTER_X + 592, y = 827,
        width = 138, input_x = CENTER_X + 639, input_width = 62,
        decimals = 4, scale_mode = "xyz",
    },
    {
        field = "scale_z", label = "Z", x = CENTER_X + 592, y = 858,
        width = 138, input_x = CENTER_X + 639, input_width = 62,
        decimals = 4, scale_mode = "xyz",
    },
}

local TRANSFORM_INPUT_PASSES = table.clone(TextInputPassTemplates.simple_input_field)

table.append(TRANSFORM_INPUT_PASSES, {
    {
        pass_type = "logic",
        value = function(pass, ui_renderer, ui_style, content, position, size)
            local styles = ui_style.parent
            local display_style = styles and styles.display_text
            local caret_style = styles and styles.input_caret

            if not display_style or not caret_style then
                return
            end

            local text = tostring(content.display_text or "")
            local _, _, _, text_caret = UIRenderer.text_size(
                ui_renderer,
                text,
                display_style.font_type,
                display_style.font_size
            )
            local text_width = text_caret and text_caret[1] or 0
            local target_offset = math.max(3, math.floor((size[1] - text_width) * 0.5))
            local previous_offset = display_style.offset and display_style.offset[1] or 0
            local delta = target_offset - previous_offset

            display_style.offset[1] = target_offset
            caret_style.offset[1] = (caret_style.offset[1] or 0) + delta

            local selection_style = styles.selection

            if selection_style and selection_style.offset and content.selected_text then
                selection_style.offset[1] = (selection_style.offset[1] or 0) + delta
            end
        end,
    },
})

local function transform_input_definition(x, y, width)
    return UIWidget.create_definition(
        TRANSFORM_INPUT_PASSES,
        "panel",
        {
            input_text = "",
            display_text = "",
            placeholder_text = "0",
            max_length = 16,
            hotspot = {
                use_is_focused = true,
            },
        },
        { width, 26 },
        {
            focused = { color = C.gold },
            background = { color = C.panel_alt },
            baseline = { color = C.line_dim },
            display_text = {
                font_type = "machine_medium",
                font_size = 11,
                text_color = C.text,
                text_horizontal_alignment = "left",
                offset = { 3, 0, 2 },
                size_addition = { -6, 0 },
            },
            active_placeholder = {
                font_type = "machine_medium",
                font_size = 11,
                text_color = C.dim,
                text_horizontal_alignment = "center",
                offset = { 3, 0, 2 },
                size_addition = { -6, 0 },
            },
            input_caret = { color = C.gold },
            selection = { color = { 120, 157, 124, 58 } },
            limit_text = { visible = false },
        },
        { offset = { x, y, 24 } }
    )
end

local function button_definition()
    return UIWidget.create_definition({
        {
            pass_type = "hotspot",
            content_id = "hotspot",
            style_id = "hotspot",
            style = {
                size = { 10, 10 },
                offset = { 0, 0, 6 },
            },
        },
        {
            pass_type = "rect",
            style_id = "line",
            style = {
                color = C.line_dim,
                size = { 10, 10 },
                offset = { 0, 0, 2 },
            },
        },
        {
            pass_type = "rect",
            style_id = "fill",
            style = {
                color = C.button,
                size = { 8, 8 },
                offset = { 1, 1, 3 },
            },
            change_function = function(content, style)
                if content.disabled then
                    style.color = C.disabled
                elseif content._hidden then
                    style.color = content.hotspot.is_hover and C.red or C.hidden
                elseif content._selected then
                    style.color = content.hotspot.is_hover and C.selected_hover or C.selected
                elseif content._changed then
                    style.color = content.hotspot.is_hover and C.button_hover or C.changed
                elseif content.hotspot.is_hover then
                    style.color = C.button_hover
                else
                    style.color = content._fill or C.button
                end
            end,
        },
        {
            pass_type = "text",
            style_id = "title",
            value_id = "label",
            value = "",
            style = {
                font_size = 15,
                font_type = "machine_medium",
                text_horizontal_alignment = "left",
                text_vertical_alignment = "center",
                text_color = C.text,
                drop_shadow = true,
                offset = { 8, 2, 5 },
                size = { 10, 24 },
            },
            change_function = function(content, style)
                style.text_color = content.disabled and C.dim or (content._title_color or C.text)
            end,
        },
        {
            pass_type = "text",
            style_id = "sub",
            value_id = "sub",
            value = "",
            style = {
                font_size = 12,
                font_type = "machine_medium",
                text_horizontal_alignment = "left",
                text_vertical_alignment = "center",
                text_color = C.dim,
                drop_shadow = true,
                offset = { 8, 24, 5 },
                size = { 10, 22 },
            },
            change_function = function(content, style)
                style.text_color = content.disabled and C.dim or (content._sub_color or C.dim)
            end,
        },
    }, "panel")
end

local Definitions = {
    scenegraph_definition = {
        screen = UIWorkspaceSettings.screen,
        panel = {
            parent = "screen",
            vertical_alignment = "center",
            horizontal_alignment = "center",
            size = { W, H },
            position = { 0, 0, 100 },
        },
    },
    widget_definitions = {
        frame = UIWidget.create_definition({
            {
                pass_type = "rect",
                style_id = "screen_tint",
                style = {
                    color = C.screen_tint,
                    size = { W, H },
                    offset = { 0, 0, 0 },
                },
            },
            {
                pass_type = "rect",
                style_id = "header",
                style = {
                    color = C.panel,
                    size = { W - PAD * 2, HEADER_HEIGHT },
                    offset = { PAD, HEADER_Y, 1 },
                },
            },
            {
                pass_type = "rect",
                style_id = "left",
                style = {
                    color = C.panel,
                    size = { LEFT_W, 844 },
                    offset = { LEFT_X, TOP_Y, 1 },
                },
            },
            {
                pass_type = "rect",
                style_id = "right",
                style = {
                    color = C.panel,
                    size = { RIGHT_W, 844 },
                    offset = { RIGHT_X, TOP_Y, 1 },
                },
            },
            {
                pass_type = "rect",
                style_id = "center_top",
                style = {
                    color = C.panel_soft,
                    size = { CENTER_W, HEADER_HEIGHT },
                    offset = { CENTER_X, PREVIEW_HEADER_Y, 2 },
                },
            },
            {
                pass_type = "rect",
                style_id = "visual_panel",
                style = {
                    color = C.panel,
                    size = { VISUAL_PANEL_W, VISUAL_PANEL_MIN_H },
                    offset = { VISUAL_PANEL_X, VISUAL_PANEL_BOTTOM - VISUAL_PANEL_MIN_H, 1 },
                    visible = false,
                },
            },
            {
                pass_type = "rect",
                style_id = "footer",
                style = {
                    color = C.panel,
                    size = { W - PAD * 2, 116 },
                    offset = { PAD, FOOTER_Y, 1 },
                },
            },
            {
                pass_type = "rect",
                style_id = "left_line",
                style = {
                    color = C.line,
                    size = { LEFT_W, 2 },
                    offset = { LEFT_X, TOP_Y, 2 },
                },
            },
            {
                pass_type = "rect",
                style_id = "right_line",
                style = {
                    color = C.line,
                    size = { RIGHT_W, 2 },
                    offset = { RIGHT_X, TOP_Y, 2 },
                },
            },
            {
                pass_type = "rect",
                style_id = "footer_line",
                style = {
                    color = C.line,
                    size = { W - PAD * 2, 2 },
                    offset = { PAD, FOOTER_Y, 2 },
                },
            },
        }, "panel"),
        search_input = UIWidget.create_definition(
            TextInputPassTemplates.simple_input_field,
            "panel",
            {
                input_text = "",
                display_text = "",
                placeholder_text = loc("ui_search_placeholder"),
                max_length = 80,
                hotspot = {
                    use_is_focused = true,
                },
            },
            { 324, 36 },
            {
                focused = {
                    color = C.gold,
                },
                background = {
                    color = C.panel_alt,
                },
                baseline = {
                    color = C.line,
                },
                display_text = {
                    font_type = "machine_medium",
                    font_size = 14,
                    text_color = C.text,
                    offset = { 8, 0, 2 },
                    size_addition = { -16, 0 },
                },
                active_placeholder = {
                    font_type = "machine_medium",
                    font_size = 13,
                    text_color = C.dim,
                    offset = { 8, 0, 2 },
                    size_addition = { -16, 0 },
                },
                input_caret = {
                    color = C.gold,
                },
                selection = {
                    color = { 120, 157, 124, 58 },
                },
                limit_text = {
                    visible = false,
                },
            },
            {
                offset = { RIGHT_X + 14, TOP_Y + 92, 20 },
            }
        ),
        preset_name_input = UIWidget.create_definition(
            TextInputPassTemplates.simple_input_field,
            "panel",
            {
                input_text = "",
                display_text = "",
                placeholder_text = loc("ui_preset_name_placeholder"),
                max_length = 48,
                hotspot = {
                    use_is_focused = true,
                },
            },
            { 240, 36 },
            {
                focused = {
                    color = C.gold,
                },
                background = {
                    color = C.panel_alt,
                },
                baseline = {
                    color = C.line,
                },
                display_text = {
                    font_type = "machine_medium",
                    font_size = 13,
                    text_color = C.text,
                    offset = { 8, 0, 2 },
                    size_addition = { -16, 0 },
                },
                active_placeholder = {
                    font_type = "machine_medium",
                    font_size = 12,
                    text_color = C.dim,
                    offset = { 8, 0, 2 },
                    size_addition = { -16, 0 },
                },
                input_caret = {
                    color = C.gold,
                },
                selection = {
                    color = { 120, 157, 124, 58 },
                },
                limit_text = {
                    visible = false,
                },
            },
            {
                offset = { LEFT_X + 16, TOP_Y + 744, 20 },
            }
        ),
        look_code_input = UIWidget.create_definition(
            TextInputPassTemplates.simple_input_field,
            "panel",
            {
                input_text = "",
                display_text = "",
                placeholder_text = loc("ui_look_code_placeholder"),
                max_length = 24000,
                hotspot = {
                    use_is_focused = true,
                },
            },
            { 1170, 32 },
            {
                focused = {
                    color = C.gold,
                },
                background = {
                    color = C.panel_alt,
                },
                baseline = {
                    color = C.line,
                },
                display_text = {
                    font_type = "machine_medium",
                    font_size = 12,
                    text_color = C.text,
                    offset = { 8, 0, 2 },
                    size_addition = { -16, 0 },
                },
                active_placeholder = {
                    font_type = "machine_medium",
                    font_size = 12,
                    text_color = C.dim,
                    offset = { 8, 0, 2 },
                    size_addition = { -16, 0 },
                },
                input_caret = {
                    color = C.gold,
                },
                selection = {
                    color = { 120, 157, 124, 58 },
                },
                limit_text = {
                    visible = false,
                },
            },
            {
                offset = { PAD + 132, FOOTER_Y + 65, 20 },
            }
        ),
        opacity_input = transform_input_definition(
            VISUAL_PANEL_X - 86,
            895,
            70
        ),
        rebuild_error = UIWidget.create_definition({
            {
                pass_type = "rect",
                style_id = "backdrop",
                style = {
                    color = { 252, 8, 2, 2 },
                    size = { W - PAD * 2, H - 120 },
                    offset = { PAD, 72, 900 },
                },
                visibility_function = function(content)
                    return type(content) == "table" and content.show == true
                end,
            },
            {
                pass_type = "rect",
                style_id = "border",
                style = {
                    color = C.red,
                    size = { W - PAD * 2 - 32, H - 152 },
                    offset = { PAD + 16, 88, 901 },
                },
                visibility_function = function(content)
                    return type(content) == "table" and content.show == true
                end,
            },
            {
                pass_type = "rect",
                style_id = "inner",
                style = {
                    color = { 255, 18, 10, 10 },
                    size = { W - PAD * 2 - 36, H - 156 },
                    offset = { PAD + 18, 90, 902 },
                },
                visibility_function = function(content)
                    return type(content) == "table" and content.show == true
                end,
            },
            {
                pass_type = "text",
                style_id = "title",
                value_id = "title",
                value = loc("ui_studio_error"),
                style = {
                    font_size = 30,
                    font_type = "machine_medium",
                    text_horizontal_alignment = "center",
                    text_vertical_alignment = "center",
                    text_color = C.red,
                    drop_shadow = true,
                    size = { W - PAD * 2 - 80, 60 },
                    offset = { PAD + 40, 118, 905 },
                },
                visibility_function = function(content)
                    return type(content) == "table" and content.show == true
                end,
            },
            {
                pass_type = "text",
                style_id = "body",
                value_id = "body",
                value = "",
                style = {
                    font_size = 17,
                    font_type = "machine_medium",
                    text_horizontal_alignment = "left",
                    text_vertical_alignment = "top",
                    text_color = C.text,
                    drop_shadow = true,
                    size = { W - PAD * 2 - 120, H - 330 },
                    offset = { PAD + 60, 200, 905 },
                },
                visibility_function = function(content)
                    return type(content) == "table" and content.show == true
                end,
            },
            {
                pass_type = "text",
                style_id = "hint",
                value_id = "hint",
                value = loc("ui_error_hint"),
                style = {
                    font_size = 16,
                    font_type = "machine_medium",
                    text_horizontal_alignment = "center",
                    text_vertical_alignment = "center",
                    text_color = C.gold,
                    drop_shadow = true,
                    size = { W - PAD * 2 - 80, 42 },
                    offset = { PAD + 40, H - 160, 905 },
                },
                visibility_function = function(content)
                    return type(content) == "table" and content.show == true
                end,
            },
        }, "panel", {
            show = false,
            title = loc("ui_studio_error"),
            body = "",
            hint = loc("ui_error_hint"),
        }),
    },
}

for i = 1, #TRANSFORM_FIELDS do
    local spec = TRANSFORM_FIELDS[i]
    Definitions.widget_definitions["transform_" .. spec.field .. "_input"] = transform_input_definition(
        spec.input_x, spec.y, spec.input_width
    )
end

local POOL_DEFINITIONS = {
    rule = rule_definition,
    label = label_definition,
    button = button_definition,
}

local NPCLookStudioView = class("NPCLookStudioView", "BaseView")

NPCLookStudioView.init = function(self, settings, context)
    NPCLookStudioView.super.init(self, Definitions, settings, context)

    self._pass_draw = true
    self._pass_input = false
    self._context = context or {}
    self._preview_player = self._context.player
    self._actions = {}
    self._used = {}
    self._pool_widgets = { rule = {}, label = {}, button = {} }
    self._snapshot = nil
    self._session_attached = false
    self._last_rebuild_error = nil
    self._ui_failed = false
    self._rebuild_retry = util.new_retry()
    self._last_search_text = ""
    self._last_transform_text = {}
    self._transform_input_slot = nil
    self._focused_transform_field = nil
    self._opacity_input_slot = nil

    for i = 1, #TRANSFORM_FIELDS do
        local widget = self._widgets_by_name and self._widgets_by_name["transform_" .. TRANSFORM_FIELDS[i].field .. "_input"]

        if widget then
            widget.visible = false
        end
    end

    local opacity_input = self._widgets_by_name and self._widgets_by_name.opacity_input

    if opacity_input then
        opacity_input.visible = false
    end

    local preset_name_input = self._widgets_by_name and self._widgets_by_name.preset_name_input

    if preset_name_input then
        preset_name_input.visible = false
    end
end

NPCLookStudioView._api = function(self)
    local current_mod = get_mod and get_mod("NPCLook")

    return current_mod and current_mod.npclook_view_api
end

NPCLookStudioView._widget = function(self, name)
    return self._widgets_by_name and self._widgets_by_name[name]
end

NPCLookStudioView._input_content = function(self, widget_name)
    local widget = self:_widget(widget_name)
    local content = widget and widget.content

    return type(content) == "table" and content or nil
end

NPCLookStudioView._deactivate_input = function(self, content)
    if type(content) ~= "table" then
        return
    end

    content.is_writing = false
    content.console_is_writing = nil
    content.selected_text = nil
    content._selection_start = nil
    content._selection_end = nil
    content._is_selecting = nil

    local hotspot = content.hotspot

    if type(hotspot) == "table" then
        hotspot.is_selected = false
        hotspot.is_focused = false
        hotspot.on_pressed = false
    end
end

NPCLookStudioView._stop_all_inputs = function(self)
    self:_deactivate_input(self:_input_content("search_input"))
    self:_deactivate_input(self:_input_content("look_code_input"))
    self:_deactivate_input(self:_input_content("preset_name_input"))
    self:_deactivate_input(self:_input_content("opacity_input"))
    self:_stop_transform_inputs()
end

NPCLookStudioView._input_was_pressed = function(self, content)
    local hotspot = type(content) == "table" and content.hotspot or nil

    return content and content.is_writing and type(hotspot) == "table" and hotspot.on_pressed == true
end

NPCLookStudioView._input_hotspot_hovered = function(self)
    local names = { "search_input", "look_code_input", "preset_name_input", "opacity_input" }

    for i = 1, #TRANSFORM_FIELDS do
        names[#names + 1] = "transform_" .. TRANSFORM_FIELDS[i].field .. "_input"
    end

    for i = 1, #names do
        local content = self:_input_content(names[i])
        local hotspot = content and content.hotspot

        if type(hotspot) == "table" and (hotspot.is_hover or hotspot.on_pressed) then
            return true
        end
    end

    return false
end

NPCLookStudioView._set_input_text = function(self, widget_name, value, stop_writing)
    local content = self:_input_content(widget_name)

    if not content then
        return false
    end

    value = tostring(value or "")
    content.input_text = value
    content.display_text = value
    content.selected_text = nil
    content._selection_start = nil
    content._selection_end = nil
    content.caret_position = Utf8 and Utf8.string_length and Utf8.string_length(value) + 1 or #value + 1
    content.force_caret_update = true

    if stop_writing then
        self:_deactivate_input(content)
    end

    return true
end

NPCLookStudioView._set_search_text = function(self, value, stop_writing)
    local changed = self:_set_input_text("search_input", value, stop_writing)

    if changed then
        self._last_search_text = tostring(value or "")
    end

    return changed
end

NPCLookStudioView._sync_opacity_input = function(self, snapshot, visible)
    local widget = self:_widget("opacity_input")
    local content = widget and widget.content

    visible = visible == true and snapshot ~= nil

    if widget then
        widget.visible = visible
    end

    if not content then
        return
    elseif not visible then
        self:_deactivate_input(content)
        self._opacity_input_slot = nil
        return
    end

    local slot = snapshot.selected_slot
    local slot_changed = slot ~= self._opacity_input_slot
    self._opacity_input_slot = slot

    if slot_changed or not content.is_writing then
        local value = normalized_number(snapshot.selected_opacity, 100, 0, 100)
        value = math.floor(value + 0.5)
        self:_set_input_text("opacity_input", tostring(value), slot_changed)
    end
end

NPCLookStudioView._commit_opacity_input = function(self, api)
    local content = self:_input_content("opacity_input")

    if not content or not content.is_writing then
        return false
    end

    local current = normalized_number(self._snapshot and self._snapshot.selected_opacity, 100, 0, 100)
    local value = tonumber(tostring(content.input_text or ""))

    self:_deactivate_input(content)

    if not value or value ~= value or value == math.huge or value == -math.huge then
        self:_set_input_text(
            "opacity_input",
            tostring(math.floor(current + 0.5)),
            true
        )
        return false
    end

    value = math.floor(normalized_number(value, current, 0, 100) + 0.5)
    self:_set_input_text("opacity_input", tostring(value), true)

    if value ~= math.floor(current + 0.5) then
        self:_dispatch_action(api, { kind = "set_opacity", value = value })
        return true
    end

    return false
end

NPCLookStudioView._cancel_opacity_input = function(self)
    local content = self:_input_content("opacity_input")

    if not content or not content.is_writing then
        return false
    end

    local current = normalized_number(self._snapshot and self._snapshot.selected_opacity, 100, 0, 100)

    self:_set_input_text(
        "opacity_input",
        tostring(math.floor(current + 0.5)),
        true
    )

    return true
end

NPCLookStudioView._transform_input_content = function(self, field)
    return self:_input_content("transform_" .. tostring(field) .. "_input")
end

NPCLookStudioView._format_transform_input = function(self, value, decimals)
    local formatted = string.format("%." .. tostring(decimals or 4) .. "f", tonumber(value) or 0)
    formatted = string.gsub(formatted, "0+$", "")
    formatted = string.gsub(formatted, "%.$", "")

    return formatted == "-0" and "0" or formatted
end

NPCLookStudioView._set_transform_input = function(self, spec, value, stop_writing)
    local text = self:_format_transform_input(value, spec.decimals)
    local changed = self:_set_input_text("transform_" .. spec.field .. "_input", text, stop_writing)

    if changed then
        self._last_transform_text[spec.field] = text
    end

    return changed
end

NPCLookStudioView._sync_transform_inputs = function(self, snapshot, visible)
    visible = visible == true and snapshot and snapshot.can_edit_extra_transform == true
    local slot = visible and snapshot.selected_slot or nil
    local slot_changed = slot ~= self._transform_input_slot

    self._transform_input_slot = slot

    local xyz_scale = visible and snapshot.selected_extra_transform.xyz_scale == true

    for i = 1, #TRANSFORM_FIELDS do
        local spec = TRANSFORM_FIELDS[i]
        local widget = self:_widget("transform_" .. spec.field .. "_input")
        local content = widget and widget.content
        local field_visible = visible
            and (spec.scale_mode == nil
                or spec.scale_mode == "xyz" and xyz_scale
                or spec.scale_mode == "uniform" and not xyz_scale)

        if widget then
            widget.visible = field_visible
        end

        if type(content) == "table" then
            if not field_visible then
                self:_deactivate_input(content)
            elseif slot_changed or not content.is_writing then
                self:_set_transform_input(spec, snapshot.selected_extra_transform[spec.field], slot_changed)
            end
        end
    end
end

NPCLookStudioView._active_transform_input = function(self)
    local active = {}
    local pressed
    local remembered

    for i = 1, #TRANSFORM_FIELDS do
        local spec = TRANSFORM_FIELDS[i]
        local content = self:_transform_input_content(spec.field)

        if content and content.is_writing then
            local entry = { spec = spec, content = content }
            active[#active + 1] = entry

            local hotspot = content.hotspot

            if type(hotspot) == "table" and hotspot.on_pressed then
                pressed = entry
            elseif spec.field == self._focused_transform_field then
                remembered = entry
            end
        end
    end

    local chosen = pressed or remembered or active[1]

    if not chosen then
        self._focused_transform_field = nil
        return nil, nil
    end

    for i = 1, #active do
        local entry = active[i]

        if entry ~= chosen then
            self:_deactivate_input(entry.content)
        end
    end

    self._focused_transform_field = chosen.spec.field

    return chosen.spec, chosen.content
end

NPCLookStudioView._stop_transform_inputs = function(self)
    for i = 1, #TRANSFORM_FIELDS do
        self:_deactivate_input(self:_transform_input_content(TRANSFORM_FIELDS[i].field))
    end

    self._focused_transform_field = nil
end

NPCLookStudioView._dispatch_action = function(self, api, action)
    if not api or type(api.action) ~= "function" then
        return false
    end

    local ok, handled = pcall(api.action, action)

    if not ok then
        mod:error("Studio action failed: %s", tostring(handled))
        return false
    end

    return handled ~= false
end

NPCLookStudioView._submit_look_code = function(self, api)
    local content = self:_input_content("look_code_input")
    local code = content and tostring(content.input_text or "") or ""

    if code == "" then
        return false
    end

    self:_dispatch_action(api, { kind = "import_code", code = code })

    if content then
        self:_deactivate_input(content)
    end

    return true
end

NPCLookStudioView._set_rebuild_error = function(self, message)
    local widget = self:_widget("rebuild_error")

    if not widget then
        return false
    end

    local content = widget.content

    if type(content) ~= "table" then
        return false
    end

    widget.visible = true
    content.show = true
    content.title = loc("ui_studio_error")
    content.body = tostring(message or loc("generic_unknown_error"))
    content.hint = loc("ui_error_hint")

    return true
end

NPCLookStudioView._clear_rebuild_error = function(self)
    local widget = self:_widget("rebuild_error")
    local content = widget and widget.content

    if type(content) == "table" then
        content.show = false
    end
end

NPCLookStudioView._reset_pools = function(self)
    self._used = { rule = 0, label = 0, button = 0 }
    self._actions = {}

    for _, pool in pairs(self._pool_widgets) do
        for i = 1, #pool do
            local widget = pool[i]
            widget.visible = false

            if widget.content.hotspot then
                widget.content.hotspot.on_pressed = false
                widget.content.hotspot.on_released = false
            end
        end
    end
end

NPCLookStudioView._take = function(self, pool_name)
    local index = self._used[pool_name] + 1
    local pool = self._pool_widgets[pool_name]
    local widget = pool[index]

    if not widget then
        local name = pool_name .. "_" .. index
        widget = self:_create_widget(name, POOL_DEFINITIONS[pool_name]())
        pool[index] = widget
        self._widgets[#self._widgets + 1] = widget
    end

    widget.visible = true
    self._used[pool_name] = index

    return widget
end

NPCLookStudioView._rule = function(self, x, y, width, color)
    local widget = self:_take("rule")
    local style = widget.style.bg

    style.offset[1], style.offset[2] = x, y
    style.size[1], style.size[2] = width, 1
    style.color = color or C.line_dim

    return true
end

NPCLookStudioView._text = function(self, text, x, y, width, height, size, color, alignment)
    local widget = self:_take("label")
    local content = widget.content
    local style = widget.style.text

    content.label = tostring(text or "")
    content._color = color or C.text
    style.offset[1], style.offset[2] = x, y
    style.size[1], style.size[2] = width, height
    style.font_size = size or 16
    style.text_horizontal_alignment = alignment or "left"

    return true
end

NPCLookStudioView._button = function(self, label, sub, x, y, width, height, action, state)
    local widget = self:_take("button")
    local content = widget.content

    state = type(state) == "table" and state or {}

    content.label = tostring(label or "")
    content.sub = tostring(sub or "")
    content._action = action
    content._selected = state.selected == true
    content._changed = state.changed == true
    content._hidden = state.hidden == true
    content._fill = state.fill
    content._title_color = state.title_color
    content._sub_color = state.sub_color
    content.disabled = state.disabled == true

    local hotspot = widget.style.hotspot
    local line = widget.style.line
    local fill = widget.style.fill
    local title = widget.style.title
    local sub_style = widget.style.sub
    local text_inset = state.compact and 2 or 8

    hotspot.offset[1], hotspot.offset[2] = x, y
    hotspot.size[1], hotspot.size[2] = width, height
    line.offset[1], line.offset[2] = x, y
    line.size[1], line.size[2] = width, height
    fill.offset[1], fill.offset[2] = x + 1, y + 1
    fill.size[1], fill.size[2] = math.max(width - 2, 0), math.max(height - 2, 0)
    title.offset[1], title.offset[2] = x + text_inset, y + (height <= 34 and 0 or 2)
    title.size[1], title.size[2] = math.max(width - text_inset * 2, 0), height <= 34 and height or math.min(26, height * 0.48)
    title.text_horizontal_alignment = state.align or "left"
    title.font_size = state.font_size or 15
    sub_style.offset[1], sub_style.offset[2] = x + text_inset, y + math.max(18, height * 0.45)
    sub_style.size[1], sub_style.size[2] = math.max(width - text_inset * 2, 0), math.max(0, height * 0.48)
    sub_style.text_horizontal_alignment = state.align or "left"
    sub_style.font_size = state.sub_size or 12

    if height <= 34 then
        content.sub = ""
    end

    if action and not content.disabled then
        self._actions = type(self._actions) == "table" and self._actions or {}
        self._actions[#self._actions + 1] = widget
    end

    return true
end

NPCLookStudioView._selector_row = function(self, label, y, left_action, right_action, state)
    state = type(state) == "table" and state or {}

    local x = VISUAL_PANEL_X
    local arrow_w = 30
    local gap = 4
    local toggle_w = state.toggle_action and 30 or 0
    local toggle_gap = toggle_w > 0 and gap or 0
    local center_x = x + arrow_w + gap
    local center_w = VISUAL_PANEL_W - arrow_w * 2 - gap * 2 - toggle_gap - toggle_w
    local toggle_x = center_x + center_w + gap
    local right_x = toggle_w > 0 and toggle_x + toggle_w + gap or toggle_x

    self:_button("<", "", x, y, arrow_w, VISUAL_ROW_H, left_action, {
        align = "center",
        compact = true,
        disabled = state.left_disabled == true,
        font_size = 13,
    })
    self:_text(
        label,
        center_x,
        y,
        center_w,
        VISUAL_ROW_H,
        state.font_size or 9,
        state.title_color or C.text,
        "center"
    )

    if state.toggle_action then
        self:_button(
            state.toggle_label or "X",
            "",
            toggle_x,
            y,
            toggle_w,
            VISUAL_ROW_H,
            state.toggle_action,
            {
                align = "center",
                compact = true,
                font_size = 12,
                disabled = state.toggle_disabled == true,
                title_color = state.toggle_enabled and C.green or C.dim,
            }
        )
    end

    self:_button(">", "", right_x, y, arrow_w, VISUAL_ROW_H, right_action, {
        align = "center",
        compact = true,
        disabled = state.right_disabled == true,
        font_size = 13,
    })

    if state.mode_action then
        self:_button(
            state.mode_label or "M",
            "",
            x - 34,
            y,
            30,
            VISUAL_ROW_H,
            state.mode_action,
            {
                align = "center",
                compact = true,
                font_size = 8,
                title_color = C.gold,
            }
        )
    end
end

local function details_text(details, show_authored_slots)
    if not details then
        return loc("ui_details_select_piece")
    end

    local rows = {
        tostring(details.name or ""),
        loc("ui_details_base_unit", tostring(details.base_unit or string.lower(NONE))),
    }

    if show_authored_slots then
        local slots = {}

        for i = 1, #(details.slots or {}) do
            slots[#slots + 1] = tostring(details.slots[i])
        end

        rows[#rows + 1] = loc("ui_details_authored_slots", #slots > 0 and table.concat(slots, ", ") or string.lower(NONE))
    end

    if #(details.hide_slots or {}) > 0 then
        rows[#rows + 1] = loc("ui_details_hide_ignored")
    end

    if type(details.unit_category) == "string" and details.unit_category ~= "" then
        rows[#rows + 1] = loc("ui_details_unit_type", details.unit_category)
    end

    if type(details.package_source) == "string" and details.package_source ~= "" then
        rows[#rows + 1] = loc("ui_details_package_source", details.package_source)
    end

    if type(details.package_name) == "string" and details.package_name ~= "" then
        rows[#rows + 1] = loc("ui_details_package", details.package_name)
    end

    if tonumber(details.package_count) and details.package_count > 0 then
        rows[#rows + 1] = loc("ui_details_package_count", tonumber(details.package_count))
    end

    if tonumber(details.membership_count) and details.membership_count > 0 then
        rows[#rows + 1] = loc("ui_details_membership_count", tonumber(details.membership_count))
    end

    if tonumber(details.package_members) and details.package_members > 0 then
        rows[#rows + 1] = loc("ui_details_package_members", tonumber(details.package_members))
    end

    if type(details.variant_parse_failure) == "string" and details.variant_parse_failure ~= "" then
        rows[#rows + 1] = loc("ui_details_variant_parse_failure", details.variant_parse_failure)
    end

    if tonumber(details.mesh_count) then
        rows[#rows + 1] = loc("ui_details_mesh_count", tonumber(details.mesh_count))
    end

    if #(details.variant_families or {}) > 0 then
        local names = {}
        for _, family in ipairs(details.variant_families) do
            names[#names + 1] = tostring(type(family) == "table" and family.name or family)
        end
        rows[#rows + 1] = loc("ui_details_variant_families", table.concat(names, ", "))
    end

    if tonumber(details.estimated_variant_combinations)
        and details.estimated_variant_combinations > 0 then
        rows[#rows + 1] = loc(
            "ui_details_variant_combinations",
            tonumber(details.estimated_variant_combinations)
        )
    end

    if #(details.visibility_groups or {}) > 0 then
        rows[#rows + 1] = loc(
            "ui_details_visibility_groups",
            table.concat(details.visibility_groups, ", ")
        )
    end

    return table.concat(rows, "\n")
end

-- Layout

local function source_preview_text(snapshot)
    local rows = {}

    for i = 1, math.min(#(snapshot.source_slots or {}), 7) do
        local row = snapshot.source_slots[i]
        rows[#rows + 1] = tostring(row.slot_label or loc("generic_slot")) .. ": " .. tostring(row.item_label or string.lower(NONE))
    end

    if #(snapshot.source_slots or {}) > 7 then
        rows[#rows + 1] = loc("ui_source_more_slots", #snapshot.source_slots - 7)
    end

    if #rows == 0 then
        return loc("ui_source_select")
    end

    return table.concat(rows, "\n")
end

NPCLookStudioView._apply_frame_mode = function(self, inspect_mode)
    local frame = self:_widget("frame")
    local style = frame and frame.style

    if type(style) ~= "table" then
        return false
    end

    local normal_only = {
        "left",
        "right",
        "center_top",
        "visual_panel",
        "left_line",
        "right_line",
    }

    for i = 1, #normal_only do
        local pass_style = style[normal_only[i]]

        if type(pass_style) == "table" then
            pass_style.visible = not inspect_mode
        end
    end

    if type(style.screen_tint) == "table" and type(style.screen_tint.color) == "table" then
        style.screen_tint.color[1] = inspect_mode and 72 or C.screen_tint[1]
    end

    if type(style.header) == "table" then
        style.header.visible = true
        style.header.color = inspect_mode and { 220, 10, 13, 17 } or C.panel
    end

    if type(style.footer) == "table" then
        style.footer.visible = true
        style.footer.color = inspect_mode and { 220, 10, 13, 17 } or C.panel
    end

    if type(style.footer_line) == "table" then
        style.footer_line.visible = true
    end

    for _, widget_name in ipairs({ "search_input", "preset_name_input", "look_code_input" }) do
        local input_widget = self:_widget(widget_name)

        if input_widget then
            input_widget.visible = not inspect_mode

            if inspect_mode then
                local content = input_widget.content

                if type(content) == "table" then
                    self:_deactivate_input(content)
                end
            end
        end
    end

    return true
end

NPCLookStudioView._rebuild_inspect = function(self, snapshot)
    self:_text(loc("ui_inspect_title"), PAD + 18, HEADER_CONTENT_Y, 470, 36, 27, C.gold)

    local dirty_text = snapshot.dirty_count > 0 and loc("ui_staged_changes", snapshot.dirty_count) or loc("ui_stage_matches")
    local return_x = W - 238
    local dirty_width = 400
    local dirty_x = return_x - dirty_width - 24

    self:_text(dirty_text, dirty_x, HEADER_CONTENT_Y, dirty_width, 36, 20, snapshot.dirty_count > 0 and C.gold or C.green, "right")
    self:_button(
        loc("ui_return"),
        "",
        return_x,
        HEADER_Y + 7,
        126,
        34,
        { kind = "toggle_inspect" },
        { align = "center", font_size = 12 }
    )
    self:_button(loc("ui_close"), "", W - 96, HEADER_Y + 7, 52, 34, { kind = "_close" }, { align = "center", font_size = 18 })

    local camera_x = W * 0.5 - 250
    self:_button(
        loc("ui_camera_full"),
        "",
        camera_x,
        88,
        82,
        34,
        { kind = "_camera", camera = "full" },
        { align = "center", selected = snapshot.camera_focus == "full" }
    )
    self:_button(
        loc("ui_camera_head"),
        "",
        camera_x + 88,
        88,
        82,
        34,
        { kind = "_camera", camera = "head" },
        { align = "center", selected = snapshot.camera_focus == "head" }
    )
    self:_button(
        loc("ui_camera_torso"),
        "",
        camera_x + 176,
        88,
        82,
        34,
        { kind = "_camera", camera = "torso" },
        { align = "center", selected = snapshot.camera_focus == "torso" }
    )
    self:_button(
        loc("ui_camera_legs"),
        "",
        camera_x + 264,
        88,
        82,
        34,
        { kind = "_camera", camera = "legs" },
        { align = "center", selected = snapshot.camera_focus == "legs" }
    )
    self:_button(
        loc("ui_reset_camera"),
        "",
        camera_x + 352,
        88,
        148,
        34,
        { kind = "reset_camera" },
        { align = "center", font_size = 11 }
    )

    local selected_name = snapshot.selected_details and snapshot.selected_details.name
    local preview_label

    for i = 1, #(snapshot.items or {}) do
        local item = snapshot.items[i]

        if item.selected then
            preview_label = item.label
            break
        end
    end

    if not preview_label or preview_label == "" then
        preview_label = selected_name or (snapshot.selected_item and tostring(snapshot.selected_item)) or loc("ui_staged_outfit")
    end

    self:_text(loc("ui_previewing"), PAD + 24, FOOTER_Y + 13, 220, 24, 13, C.dim)
    self:_text(string.upper(tostring(preview_label)), PAD + 24, FOOTER_Y + 38, 560, 34, 18, C.gold)
    self:_text(loc("ui_destination", tostring(snapshot.selected_slot_label)), PAD + 24, FOOTER_Y + 72, 560, 24, 12, C.dim)

    self:_button(
        loc("ui_previous_piece"),
        "",
        W * 0.5 - 420,
        FOOTER_Y + 25,
        160,
        38,
        { kind = "cycle_item", delta = -1 },
        { align = "center", font_size = 11 }
    )
    self:_button(
        loc("ui_next_piece"),
        "",
        W * 0.5 - 254,
        FOOTER_Y + 25,
        160,
        38,
        { kind = "cycle_item", delta = 1 },
        { align = "center", font_size = 11 }
    )
    self:_button(
        loc("ui_wear"),
        "",
        W * 0.5 - 78,
        FOOTER_Y + 25,
        150,
        38,
        { kind = "wear_item" },
        {
            align = "center",
            font_size = 12,
            disabled = snapshot.selected_item == nil or not snapshot.selected_item_applicable,
        }
    )
    self:_button(
        loc("ui_empty_slot"),
        "",
        W * 0.5 + 78,
        FOOTER_Y + 25,
        132,
        38,
        { kind = "empty_slot" },
        { align = "center", font_size = 11 }
    )
    self:_button(
        loc("ui_hide_slot"),
        "",
        W * 0.5 + 216,
        FOOTER_Y + 25,
        116,
        38,
        { kind = "hide_slot" },
        {
            align = "center",
            font_size = 11,
            title_color = C.red,
        }
    )

    self:_button(loc("ui_apply_player"), "", W - PAD - 214, FOOTER_Y + 25, 192, 42, { kind = "commit" }, {
        align = "center",
        font_size = 14,
        title_color = snapshot.dirty_count > 0 and C.gold or C.green,
    })
    self:_text(snapshot.feedback or "", W * 0.5 - 430, FOOTER_Y + 72, 860, 24, 12, C.text, "center")

end

NPCLookStudioView._open_preset_confirmation = function(self, action, name)
    if type(action) ~= "table" then
        return false
    end

    self._preset_confirmation = {
        action = action,
        name = tostring(name or ""),
    }
    self:_stop_all_inputs()

    return true
end

NPCLookStudioView._clear_preset_confirmation = function(self)
    self._preset_confirmation = nil
end

NPCLookStudioView._rebuild_preset_confirmation = function(self)
    local confirmation = self._preset_confirmation

    if not confirmation then
        return
    end

    for i = 1, #(self._actions or {}) do
        local widget = self._actions[i]

        if widget and widget.content then
            widget.content.disabled = true
        end
    end

    for _, widget_name in ipairs({ "search_input", "preset_name_input", "look_code_input" }) do
        local input_widget = self:_widget(widget_name)

        if input_widget then
            input_widget.visible = false
        end
    end

    local action = confirmation.action
    local deleting = action.kind == "delete_player_preset"
    local panel_w = 520
    local panel_h = 190
    local panel_x = math.floor((W - panel_w) * 0.5)
    local panel_y = math.floor((H - panel_h) * 0.5)
    local message = deleting
        and loc("ui_preset_delete_confirm", confirmation.name)
        or loc("ui_preset_save_confirm", confirmation.name)

    self:_button("", "", panel_x, panel_y, panel_w, panel_h, nil, {
        disabled = true,
        fill = C.panel,
    })
    self:_text(loc("ui_preset_confirm_title"), panel_x + 24, panel_y + 20, panel_w - 48, 34, 22, C.gold, "center")
    self:_text(message, panel_x + 30, panel_y + 67, panel_w - 60, 48, 15, C.text, "center")
    self:_button(
        loc("ui_cancel"),
        "",
        panel_x + 62,
        panel_y + 132,
        170,
        36,
        { kind = "_cancel_preset_confirmation" },
        { align = "center", font_size = 13 }
    )
    self:_button(
        loc("ui_confirm"),
        "",
        panel_x + panel_w - 232,
        panel_y + 132,
        170,
        36,
        { kind = "_confirm_preset_confirmation" },
        { align = "center", font_size = 13, title_color = deleting and C.red or C.gold }
    )
end

NPCLookStudioView._rebuild_safe = function(self)
    -- _rebuild clears the dynamic widgets, not the error panel
    local ok, err = xpcall(function()
        self:_rebuild()
    end, util.traceback)

    if ok then
        self._ui_failed = false
        util.reset_retry(self._rebuild_retry)
        util.report_once(self, "_last_rebuild_error", nil)
        self:_clear_rebuild_error()
        return true
    end

    local message = tostring(err or loc("generic_unknown_error"))
    self._ui_failed = true
    util.record_attempt(self._rebuild_retry)
    self:_reset_pools()

    local overlay_ok = self:_set_rebuild_error(message)

    util.report_once(self, "_last_rebuild_error", message, function(new_message)
        mod:error("Studio rebuild failed: %s", new_message)

        if not overlay_ok then
            mod:echo(loc("error_see_console", "rebuild the studio"))
        end
    end)

    return false
end

NPCLookStudioView._rebuild = function(self)
    self:_reset_pools()

    local snapshot = self._snapshot

    if not snapshot then
        self:_apply_frame_mode(false)
        self:_sync_transform_inputs({}, false)
        self:_sync_opacity_input(nil, false)

        local preset_name_input = self:_widget("preset_name_input")

        if preset_name_input then
            preset_name_input.visible = false
        end

        self:_text(loc("ui_studio_title"), PAD + 18, HEADER_CONTENT_Y, 520, 34, 26, C.gold)
        self:_text(loc("error_bridge_not_ready"), PAD + 18, 92, 600, 34, 17, C.red)
        return
    end

    self:_apply_frame_mode(snapshot.inspect_mode)
    self:_sync_transform_inputs(snapshot, not snapshot.inspect_mode)
    self:_sync_opacity_input(snapshot, not snapshot.inspect_mode)

    local frame = self:_widget("frame")
    local frame_style = frame and frame.style
    local show_mask_controls = not snapshot.inspect_mode
        and snapshot.visual_options_mode == "masks"
        and snapshot.can_edit_masks
    local show_variant_controls = not snapshot.inspect_mode
        and not show_mask_controls
        and snapshot.can_edit_variants
    local visual_row_count = show_mask_controls and #snapshot.mask_rows
        or show_variant_controls and (snapshot.can_switch_variant_controls and 3 or 2)
        or 0
    local visual_panel_height = visual_row_count > 0
        and visual_row_count * VISUAL_ROW_H + (visual_row_count - 1) * VISUAL_ROW_GAP
        or VISUAL_PANEL_MIN_H
    local visual_panel_y = VISUAL_PANEL_BOTTOM - visual_panel_height

    if type(frame_style) == "table" then
        local panel_style = frame_style.visual_panel

        if type(panel_style) == "table" then
            panel_style.visible = visual_row_count > 0
            panel_style.offset[1] = VISUAL_PANEL_X
            panel_style.offset[2] = visual_panel_y
            panel_style.size[1] = VISUAL_PANEL_W
            panel_style.size[2] = visual_panel_height
        end
    end

    if snapshot.inspect_mode then
        self:_rebuild_inspect(snapshot)
        return
    end

    local preset_name_input = self:_widget("preset_name_input")

    if preset_name_input then
        preset_name_input.visible = snapshot.source_kind == "player"
    end

    local search_input = self:_widget("search_input")

    if search_input then
        search_input.visible = true

        local search_content = search_input.content

        if type(search_content) == "table" then
            search_content.placeholder_text = snapshot.node_mode
                and loc("ui_search_nodes_placeholder")
                or loc("ui_search_placeholder")
        end
    end

    self:_text(loc("ui_studio_title"), PAD + 18, HEADER_CONTENT_Y, 520, 36, 27, C.gold)

    local dirty_text = snapshot.dirty_count > 0 and loc("ui_staged_changes", snapshot.dirty_count) or loc("ui_stage_matches")
    local dirty_color = snapshot.dirty_count > 0 and C.gold or C.green

    self:_text(dirty_text, RIGHT_X + 16, HEADER_CONTENT_Y, RIGHT_W - 112, 36, 21, dirty_color, "right")
    self:_button(loc("ui_close"), "", W - 96, HEADER_Y + 7, 52, 34, { kind = "_close" }, { align = "center", font_size = 18 })

    -- Outfit column
    self:_text(loc("ui_outfit_sources"), LEFT_X + 16, TOP_Y + 14, LEFT_W - 32, 28, 20, C.gold)
    self:_button(
        loc("ui_presets"),
        "",
        LEFT_X + 16,
        TOP_Y + 50,
        84,
        32,
        { kind = "source_kind", source_kind = "preset" },
        {
            selected = snapshot.source_kind == "preset",
            align = "center",
            font_size = 11,
        }
    )
    self:_button(
        loc("ui_npc_families"),
        "",
        LEFT_X + 106,
        TOP_Y + 50,
        114,
        32,
        { kind = "source_kind", source_kind = "family" },
        {
            selected = snapshot.source_kind == "family",
            align = "center",
            font_size = 10,
        }
    )
    self:_button(
        loc("ui_player_presets"),
        "",
        LEFT_X + 226,
        TOP_Y + 50,
        86,
        32,
        { kind = "source_kind", source_kind = "player" },
        {
            selected = snapshot.source_kind == "player",
            align = "center",
            font_size = 10,
        }
    )
    self:_button(
        loc("ui_previous_page"),
        "",
        LEFT_X + 318,
        TOP_Y + 50,
        24,
        32,
        { kind = "source_page", delta = -1 },
        { align = "center", compact = true }
    )
    self:_text(loc("ui_page", snapshot.source_page, snapshot.source_page_count), LEFT_X + 344, TOP_Y + 50, 30, 32, 11, C.dim, "center")
    self:_button(
        loc("ui_next_page"),
        "",
        LEFT_X + 378,
        TOP_Y + 50,
        20,
        32,
        { kind = "source_page", delta = 1 },
        { align = "center", compact = true }
    )

    local source_y = TOP_Y + 92

    for i = 1, #(snapshot.sources or {}) do
        local source = snapshot.sources[i]
        self:_button(source.label, source.sub, LEFT_X + 14, source_y, LEFT_W - 28, 56,
            { kind = "select_source", source = source.id },
            { selected = source.selected, title_color = source.selected and C.gold or C.text })
        source_y = source_y + 61
    end

    if snapshot.source_kind == "player" and #(snapshot.sources or {}) == 0 then
        self:_text(loc("ui_no_player_presets"), LEFT_X + 16, source_y + 20, LEFT_W - 32, 34, 14, C.dim, "center")
    end

    local source_action_y = TOP_Y + 652

    self:_rule(LEFT_X + 16, source_action_y - 8, LEFT_W - 32)
    self:_text(snapshot.selected_source_label or NONE, LEFT_X + 16, source_action_y, LEFT_W - 32, 25, 17, C.gold)

    if snapshot.source_kind == "player" then
        self:_text(loc("ui_player_preset_help"), LEFT_X + 16, source_action_y + 30, LEFT_W - 32, 48, 12, C.dim)
        self:_button(
            loc("ui_save_player_preset"),
            "",
            LEFT_X + 262,
            TOP_Y + 744,
            128,
            36,
            { kind = "_save_player_preset" },
            { align = "center", font_size = 10 }
        )
        self:_button(
            loc("ui_load_player_preset"),
            "",
            LEFT_X + 16,
            TOP_Y + 792,
            180,
            36,
            { kind = "load_player_preset" },
            {
                align = "center",
                font_size = 11,
                disabled = snapshot.selected_source == nil,
            }
        )
        self:_button(
            loc("ui_delete_player_preset"),
            "",
            LEFT_X + 202,
            TOP_Y + 792,
            188,
            36,
            { kind = "delete_player_preset" },
            {
                align = "center",
                font_size = 11,
                title_color = C.red,
                disabled = snapshot.selected_source == nil,
            }
        )
    else
        self:_text(source_preview_text(snapshot), LEFT_X + 16, source_action_y + 28, LEFT_W - 32, 110, 12, C.dim)
        self:_button(
            loc("ui_preview_layer"),
            "",
            LEFT_X + 16,
            TOP_Y + 792,
            118,
            34,
            { kind = "preview_source", replace = false },
            {
                selected = snapshot.source_preview == "layer",
                align = "center",
                font_size = 12,
            }
        )
        self:_button(
            loc("ui_preview_replace"),
            "",
            LEFT_X + 140,
            TOP_Y + 792,
            132,
            34,
            { kind = "preview_source", replace = true },
            {
                selected = snapshot.source_preview == "replace",
                align = "center",
                font_size = 12,
            }
        )
        self:_button(
            loc("ui_layer_stage"),
            "",
            LEFT_X + 278,
            TOP_Y + 792,
            112,
            34,
            { kind = "stage_source", replace = false },
            { align = "center", font_size = 12 }
        )
        self:_button(
            loc("ui_replace_stage"),
            "",
            LEFT_X + 278,
            TOP_Y + 832,
            112,
            34,
            { kind = "stage_source", replace = true },
            {
                align = "center",
                font_size = 12,
                title_color = C.red,
            }
        )
    end

    -- Library column
    self:_text(loc("ui_piece_library"), RIGHT_X + 16, TOP_Y + 14, RIGHT_W - 32, 28, 20, C.gold)

    local library_status = loc("ui_results", snapshot.item_result_count)

    self:_text(library_status, RIGHT_X + 200, TOP_Y + 14, 198, 28, 11, C.dim, "right")
    self:_button(
        loc("ui_mode_slot"),
        "",
        RIGHT_X + 16,
        TOP_Y + 50,
        52,
        32,
        { kind = "item_mode", mode = "slot" },
        {
            selected = snapshot.item_mode == "slot",
            align = "center",
            font_size = 9,
        }
    )
    self:_button(
        loc("ui_mode_all"),
        "",
        RIGHT_X + 72,
        TOP_Y + 50,
        42,
        32,
        { kind = "item_mode", mode = "all" },
        {
            selected = snapshot.item_mode == "all",
            align = "center",
            font_size = 9,
        }
    )
    self:_button(
        loc("ui_mode_units"),
        "",
        RIGHT_X + 118,
        TOP_Y + 50,
        58,
        32,
        { kind = "item_mode", mode = "units" },
        {
            selected = snapshot.item_mode == "units",
            align = "center",
            font_size = 8,
            disabled = not snapshot.can_use_units,
        }
    )
    self:_button(
        loc("ui_mode_materials"),
        "",
        RIGHT_X + 180,
        TOP_Y + 50,
        70,
        32,
        { kind = "item_mode", mode = "materials" },
        {
            selected = snapshot.item_mode == "materials",
            align = "center",
            font_size = 8,
            disabled = not snapshot.can_pick_materials,
        }
    )
    self:_button(
        loc("ui_mode_nodes"),
        "",
        RIGHT_X + 254,
        TOP_Y + 50,
        48,
        32,
        { kind = "item_mode", mode = "nodes" },
        {
            selected = snapshot.item_mode == "nodes",
            align = "center",
            font_size = 8,
            disabled = not snapshot.can_use_nodes,
        }
    )
    self:_button(
        loc("ui_previous_page"),
        "",
        RIGHT_X + 308,
        TOP_Y + 50,
        26,
        32,
        { kind = "item_page", delta = -1 },
        { align = "center", compact = true }
    )
    self:_text(loc("ui_page", snapshot.item_page, snapshot.item_page_count), RIGHT_X + 336, TOP_Y + 50, 34, 32, 11, C.dim, "center")
    self:_button(
        loc("ui_next_page"),
        "",
        RIGHT_X + 372,
        TOP_Y + 50,
        26,
        32,
        { kind = "item_page", delta = 1 },
        { align = "center", compact = true }
    )
    self:_button(loc("ui_close"), "", RIGHT_X + 344, TOP_Y + 92, 54, 36, { kind = "_clear_search" }, {
        align = "center",
        font_size = 14,
        disabled = snapshot.item_search == "",
    })

    local item_y = TOP_Y + 136

    if #(snapshot.items or {}) == 0 then
        self:_text(loc("ui_no_matching_pieces"), RIGHT_X + 14, item_y + 16, RIGHT_W - 28, 36, 15, C.dim, "center")
    end

    for i = 1, #(snapshot.items or {}) do
        local item = snapshot.items[i]
        self:_button(item.label, item.sub, RIGHT_X + 14, item_y, RIGHT_W - 28, 56,
            { kind = "select_item", item = item.id },
            {
                selected = item.selected,
                title_color = not item.applicable and C.dim or item.selected and C.gold or C.text,
                sub_color = not item.applicable and C.dim or nil,
            })
        item_y = item_y + 61
    end

    if snapshot.material_mode then
        self:_text(loc("ui_material_target"), RIGHT_X + 16, TOP_Y + 624, 52, 24, 10, C.dim)
        self:_button(
            loc("ui_previous_page"),
            "",
            RIGHT_X + 72,
            TOP_Y + 622,
            26,
            26,
            { kind = "cycle_material_target", delta = -1 },
            {
                align = "center",
                compact = true,
                disabled = #(snapshot.material_targets or {}) <= 1,
            }
        )
        self:_text(snapshot.material_target_label, RIGHT_X + 102, TOP_Y + 624, 258, 24, 10, C.gold, "center")
        self:_button(
            loc("ui_next_page"),
            "",
            RIGHT_X + 364,
            TOP_Y + 622,
            28,
            26,
            { kind = "cycle_material_target", delta = 1 },
            {
                align = "center",
                compact = true,
                disabled = #(snapshot.material_targets or {}) <= 1,
            }
        )
        self:_button(
            loc("ui_toggle_material"),
            "",
            RIGHT_X + 16,
            TOP_Y + 652,
            180,
            36,
            { kind = "wear_item" },
            {
                align = "center",
                font_size = 10,
                disabled = snapshot.selected_item == nil or not snapshot.selected_item_applicable,
            }
        )
        self:_button(
            loc("ui_clear_materials"),
            "",
            RIGHT_X + 202,
            TOP_Y + 652,
            190,
            36,
            { kind = "clear_materials" },
            {
                align = "center",
                font_size = 10,
                title_color = C.red,
                disabled = #(snapshot.selected_materials or {}) == 0,
            }
        )
    elseif snapshot.node_mode then
        self:_button(
            loc("ui_use_node"),
            "",
            RIGHT_X + 16,
            TOP_Y + 652,
            118,
            36,
            { kind = "wear_item" },
            {
                align = "center",
                font_size = 9,
                disabled = snapshot.selected_item == nil or not snapshot.selected_item_applicable,
            }
        )
        self:_button(
            loc("ui_node_default"),
            "",
            RIGHT_X + 140,
            TOP_Y + 652,
            118,
            36,
            { kind = "reset_attach_node" },
            {
                align = "center",
                font_size = 9,
                disabled = snapshot.selected_attach_node == nil,
            }
        )
        self:_button(
            loc("ui_node_skeleton"),
            "",
            RIGHT_X + 264,
            TOP_Y + 652,
            128,
            36,
            { kind = "toggle_node_skeleton" },
            {
                align = "center",
                font_size = 8,
                selected = snapshot.node_skeleton_visible,
            }
        )
    else
        self:_button(
            loc("ui_wear"),
            "",
            RIGHT_X + 16,
            TOP_Y + 652,
            92,
            36,
            { kind = "wear_item" },
            {
                align = "center",
                font_size = 11,
                disabled = snapshot.selected_item == nil or not snapshot.selected_item_applicable,
            }
        )
        self:_button(
            loc("ui_empty"),
            "",
            RIGHT_X + 114,
            TOP_Y + 652,
            82,
            36,
            { kind = "empty_slot" },
            { align = "center", font_size = 11 }
        )
        self:_button(
            loc("ui_hide"),
            "",
            RIGHT_X + 202,
            TOP_Y + 652,
            82,
            36,
            { kind = "hide_slot" },
            {
                align = "center",
                font_size = 11,
                title_color = C.red,
            }
        )
        self:_button(
            loc("ui_restore"),
            "",
            RIGHT_X + 290,
            TOP_Y + 652,
            102,
            36,
            { kind = "restore_slot" },
            { align = "center", font_size = 10 }
        )
        self:_button(
            loc("ui_clone_slot"),
            "",
            RIGHT_X + 290,
            TOP_Y + 700,
            102,
            32,
            { kind = "clone_slot" },
            { align = "center", font_size = 9 }
        )
    end
    self:_rule(RIGHT_X + 16, TOP_Y + 700, RIGHT_W - 150)
    local selected_heading = snapshot.material_mode
        and loc("ui_selected_materials")
        or snapshot.node_mode and loc("ui_selected_node")
        or loc("ui_selected_piece")
    local selected_materials = snapshot.selected_materials or {}
    local details = snapshot.material_mode
        and (#selected_materials > 0
            and table.concat(selected_materials, "\n")
            or loc("ui_no_material_overrides"))
        or snapshot.node_mode and (snapshot.preview_attach_node or loc("ui_node_default"))
        or details_text(snapshot.selected_details, snapshot.show_authored_slots)

    self:_text(selected_heading, RIGHT_X + 16, TOP_Y + 710, RIGHT_W - 150, 22, 15, C.gold)
    self:_text(details, RIGHT_X + 16, TOP_Y + 735, RIGHT_W - 150, 165, 11, C.dim)

    if show_mask_controls then
        local row_y = visual_panel_y

        for i = 1, #snapshot.mask_rows do
            local row = snapshot.mask_rows[i]
            local option_disabled = not row.enabled or row.option_count <= 1
            local mode_action = i == #snapshot.mask_rows and snapshot.can_switch_visual_options
                and { kind = "cycle_visual_options_mode" } or nil
            local label = string.format("%s: %s", row.field_label, row.value_label)

            self:_selector_row(
                label,
                row_y,
                { kind = "cycle_mask_value", field = row.field, delta = -1 },
                { kind = "cycle_mask_value", field = row.field, delta = 1 },
                {
                    left_disabled = option_disabled,
                    mode_action = mode_action,
                    mode_label = "V",
                    right_disabled = option_disabled,
                    title_color = row.enabled and C.green or C.dim,
                    toggle_action = { kind = "toggle_mask_field", field = row.field },
                    toggle_disabled = not row.can_toggle,
                    toggle_enabled = row.enabled,
                    toggle_label = row.enabled and "X" or "",
                }
            )
            row_y = row_y + VISUAL_ROW_H + VISUAL_ROW_GAP
        end
    elseif show_variant_controls then
        local row_y = visual_panel_y
        local visual_mode_action = snapshot.can_switch_visual_options
            and { kind = "cycle_visual_options_mode" } or nil

        if snapshot.can_switch_variant_controls then
            local mode_label = snapshot.variant_control_mode == "visibility"
                and loc("ui_visibility_group") or loc("ui_variant_family")
            local mode_action = { kind = "cycle_variant_control_mode" }

            self:_selector_row(mode_label, row_y, mode_action, mode_action, {
                title_color = C.gold,
            })
            row_y = row_y + VISUAL_ROW_H + VISUAL_ROW_GAP
        end

        if snapshot.variant_control_mode ~= "visibility"
            and snapshot.variant_family_count > 0 then
            local family_disabled = snapshot.variant_family_count <= 1

            self:_selector_row(
                tostring(snapshot.variant_family_name or NONE),
                row_y,
                { kind = "cycle_variant_family", delta = -1 },
                { kind = "cycle_variant_family", delta = 1 },
                {
                    left_disabled = family_disabled,
                    right_disabled = family_disabled,
                    title_color = C.gold,
                }
            )
            row_y = row_y + VISUAL_ROW_H + VISUAL_ROW_GAP
            self:_selector_row(
                tostring(snapshot.variant_family_value or loc("ui_variant_authored_default")),
                row_y,
                { kind = "cycle_variant_option", delta = -1 },
                { kind = "cycle_variant_option", delta = 1 },
                {
                    mode_action = visual_mode_action,
                    mode_label = "M",
                    title_color = C.text,
                }
            )
        elseif snapshot.visibility_group_count > 0 then
            local group_disabled = snapshot.visibility_group_count <= 1
            local group_state = snapshot.visibility_group_value == nil
                and loc("ui_variant_authored_default")
                or snapshot.visibility_group_value and loc("ui_variant_on") or loc("ui_variant_off")

            self:_selector_row(
                tostring(snapshot.visibility_group_name or NONE),
                row_y,
                { kind = "cycle_visibility_group", delta = -1 },
                { kind = "cycle_visibility_group", delta = 1 },
                {
                    left_disabled = group_disabled,
                    right_disabled = group_disabled,
                    title_color = C.gold,
                }
            )
            row_y = row_y + VISUAL_ROW_H + VISUAL_ROW_GAP
            self:_selector_row(
                tostring(group_state),
                row_y,
                { kind = "cycle_visibility_value", delta = -1 },
                { kind = "cycle_visibility_value", delta = 1 },
                {
                    mode_action = visual_mode_action,
                    mode_label = "M",
                    title_color = C.text,
                }
            )
        end
    end

    -- Preview / staged slots
    self:_text(loc("ui_character_preview"), CENTER_X + 18, PREVIEW_HEADER_Y + 10, 280, 34, 20, C.gold)
    self:_text(loc("ui_selected_slot", tostring(snapshot.selected_slot_label)), CENTER_X + 300, PREVIEW_HEADER_Y + 10, 310, 34, 16, C.text)
    self:_button(
        loc("ui_inspect"),
        "",
        CENTER_X + CENTER_W - 404,
        PREVIEW_HEADER_Y + 11,
        86,
        30,
        { kind = "toggle_inspect" },
        {
            align = "center",
            font_size = 11,
            title_color = C.gold,
        }
    )
    self:_button(
        loc("ui_camera_full"),
        "",
        CENTER_X + CENTER_W - 310,
        PREVIEW_HEADER_Y + 11,
        64,
        30,
        { kind = "_camera", camera = "full" },
        {
            align = "center",
            font_size = 12,
            selected = snapshot.camera_focus == "full",
        }
    )
    self:_button(
        loc("ui_camera_head"),
        "",
        CENTER_X + CENTER_W - 240,
        PREVIEW_HEADER_Y + 11,
        64,
        30,
        { kind = "_camera", camera = "head" },
        {
            align = "center",
            font_size = 12,
            selected = snapshot.camera_focus == "head",
        }
    )
    self:_button(
        loc("ui_camera_torso"),
        "",
        CENTER_X + CENTER_W - 170,
        PREVIEW_HEADER_Y + 11,
        64,
        30,
        { kind = "_camera", camera = "torso" },
        {
            align = "center",
            font_size = 12,
            selected = snapshot.camera_focus == "torso",
        }
    )
    self:_button(
        loc("ui_camera_legs"),
        "",
        CENTER_X + CENTER_W - 100,
        PREVIEW_HEADER_Y + 11,
        64,
        30,
        { kind = "_camera", camera = "legs" },
        {
            align = "center",
            font_size = 12,
            selected = snapshot.camera_focus == "legs",
        }
    )

    local slot_entries = snapshot.slots or {}
    local slot_count = #slot_entries
    local left_count = math.ceil(slot_count * 0.5)
    local extra_page = (snapshot.slot_page or 1) > 1
    local vertical_span = extra_page and 580 or 660

    for i = 1, slot_count do
        local slot = slot_entries[i]
        local is_left = i <= left_count
        local row = is_left and i or (i - left_count)
        local row_count = is_left and left_count or math.max(slot_count - left_count, 1)
        local spacing = row_count > 1 and math.min(extra_page and 62 or 70, vertical_span / (row_count - 1)) or 70
        local button_height = extra_page
            and math.max(42, math.min(58, spacing - 5))
            or math.max(60, math.min(70, spacing - 5))
        local position = {
            is_left and 450 or 1250,
            145 + (row - 1) * spacing,
        }

        local state = {
            selected = slot.selected,
            changed = slot.changed,
            hidden = slot.hidden,
            title_color = slot.hidden and C.red or slot.changed and C.gold or slot.inherited and C.green or C.text,
            sub_color = slot.hidden and C.red or C.dim,
            font_size = button_height < 50 and 11 or 13,
            sub_size = button_height < 50 and 9 or 10,
        }
        self:_button(slot.label, slot.item_label, position[1], position[2], 220, button_height,
            { kind = "select_slot", slot = slot.id }, state)
    end

    if snapshot.can_edit_extra_transform then
        local xyz_scale = snapshot.selected_extra_transform.xyz_scale == true

        self:_text(loc("ui_extra_transform"), CENTER_X + 178, 798, 170, 24, 12, C.gold)
        self:_button(loc("ui_extra_transform_reset"), "", CENTER_X + 330, 797, 82, 24,
            { kind = "reset_extra_transform" },
            { align = "center", compact = true, font_size = 8, title_color = C.red })

        for i = 1, #TRANSFORM_FIELDS do
            local spec = TRANSFORM_FIELDS[i]
            local field_visible = spec.scale_mode == nil
                or spec.scale_mode == "xyz" and xyz_scale
                or spec.scale_mode == "uniform" and not xyz_scale

            if field_visible then
                if spec.scale_mode == "xyz" then
                    self:_text(spec.label, spec.x + 16, spec.y, spec.input_x - spec.x - 18, 26, 10, C.dim, "center")
                else
                    self:_button("-", "", spec.x, spec.y, 26, 26,
                        { kind = "adjust_extra_transform", field = spec.field, delta = -spec.delta },
                        { align = "center", compact = true, font_size = 14 })
                    self:_text(spec.label, spec.x + 28, spec.y, spec.input_x - spec.x - 30, 26, 10, C.dim, "center")
                    self:_button("+", "", spec.x + spec.width - 26, spec.y, 26, 26,
                        { kind = "adjust_extra_transform", field = spec.field, delta = spec.delta },
                        { align = "center", compact = true, font_size = 14 })
                end
            end
        end
    end
    self:_text(loc("ui_opacity_label"), VISUAL_PANEL_X - 186, 895, 96, 30, 10, C.dim, "right")

    self:_button(loc("ui_previous_page"), "", CENTER_X + 18, 895, 30, 30,
        { kind = "slot_page", delta = -1 }, { align = "center", compact = true, disabled = snapshot.slot_page_count <= 1 })
    self:_text(string.format("%d / %d", snapshot.slot_page, snapshot.slot_page_count), CENTER_X + 54, 895, 70, 30, 11, C.dim, "center")
    self:_button(loc("ui_next_page"), "", CENTER_X + 130, 895, 30, 30,
        { kind = "slot_page", delta = 1 }, { align = "center", compact = true, disabled = snapshot.slot_page_count <= 1 })
    self:_button(
        loc("ui_remove_all_extra_slots"),
        "",
        EXTRA_ACTION_X,
        895,
        132,
        30,
        { kind = "remove_all_extra_slots" },
        {
            align = "center",
            font_size = 10,
            title_color = C.red,
            disabled = not snapshot.can_remove_all_extra_slots,
        }
    )
    self:_button(loc("ui_add_extra_slot"), "", CENTER_X + CENTER_W - 282, 895, 126, 30,
        { kind = "add_extra_slot" }, { align = "center", font_size = 11 })

    if snapshot.can_toggle_extra_xyz_scale then
        local xyz_scale = snapshot.selected_extra_transform.xyz_scale == true
        self:_button(xyz_scale and "X" or "", "", CENTER_X + CENTER_W - 282, 834, 24, 24,
            { kind = "toggle_extra_xyz_scale" },
            { align = "center", compact = true, font_size = 11, selected = xyz_scale })
        self:_text(loc("ui_extra_xyz_scale"), CENTER_X + CENTER_W - 252, 834, 120, 24, 9,
            xyz_scale and C.gold or C.dim, "left")
    end

    if snapshot.can_toggle_extra_first_person_animation then
        local animation_enabled = snapshot.selected_extra_transform.animate_first_person == true
        self:_button(animation_enabled and "X" or "", "", CENTER_X + CENTER_W - 150, 804, 24, 24,
            { kind = "toggle_extra_first_person_animation" },
            { align = "center", compact = true, font_size = 11, selected = animation_enabled })
        self:_text(loc("ui_extra_animate_first_person"), CENTER_X + CENTER_W - 120, 804, 120, 24, 8,
            animation_enabled and C.gold or C.dim, "left")
    end

    if snapshot.can_toggle_extra_first_person then
        local first_person_enabled = snapshot.selected_extra_transform.first_person == true
        self:_button(first_person_enabled and "X" or "", "", CENTER_X + CENTER_W - 150, 834, 24, 24,
            { kind = "toggle_extra_first_person" },
            { align = "center", compact = true, font_size = 11, selected = first_person_enabled })
        self:_text(loc("ui_extra_first_person"), CENTER_X + CENTER_W - 120, 834, 120, 24, 9,
            first_person_enabled and C.gold or C.dim, "left")
    end

    if snapshot.can_toggle_extra_transform then
        local transform_enabled = snapshot.selected_extra_transform.enabled == true
        self:_button(transform_enabled and "X" or "", "", CENTER_X + CENTER_W - 282, 864, 24, 24,
            { kind = "toggle_extra_transform" },
            { align = "center", compact = true, font_size = 11, selected = transform_enabled })
        self:_text(loc("ui_extra_transform"), CENTER_X + CENTER_W - 252, 864, 96, 24, 9,
            transform_enabled and C.gold or C.dim, "left")
    end

    if snapshot.can_toggle_extra_transform_deform then
        local deform_enabled = snapshot.selected_extra_transform.deform ~= false
        self:_button(deform_enabled and "X" or "", "", CENTER_X + CENTER_W - 150, 864, 24, 24,
            { kind = "toggle_extra_transform_deform" },
            { align = "center", compact = true, font_size = 11, selected = deform_enabled })
        self:_text(loc("ui_extra_transform_deform"), CENTER_X + CENTER_W - 120, 864, 120, 24, 9,
            deform_enabled and C.gold or C.dim, "left")
    end

    self:_button(
        loc("ui_remove_extra_slot"),
        "",
        CENTER_X + CENTER_W - 150,
        895,
        132,
        30,
        { kind = "remove_extra_slot" },
        {
            align = "center",
            font_size = 10,
            title_color = C.red,
            disabled = not snapshot.can_remove_extra_slot,
        }
    )

    -- Bottom bar
    local by = FOOTER_Y + 18

    self:_button(
        loc("ui_undo"),
        "",
        PAD + 18,
        by,
        82,
        34,
        { kind = "undo" },
        { align = "center", disabled = not snapshot.can_undo }
    )
    self:_button(
        loc("ui_redo"),
        "",
        PAD + 106,
        by,
        82,
        34,
        { kind = "redo" },
        { align = "center", disabled = not snapshot.can_redo }
    )
    self:_button(
        loc("ui_revert_stage"),
        "",
        PAD + 194,
        by,
        126,
        34,
        { kind = "revert_stage" },
        { align = "center", font_size = 12 }
    )
    self:_button(
        loc("ui_full_hide"),
        "",
        PAD + 326,
        by,
        104,
        34,
        { kind = "full_hide" },
        {
            align = "center",
            font_size = 12,
            title_color = C.red,
        }
    )

    self:_text(snapshot.feedback or "", PAD + 458, by, 590, 34, 14, C.text, "center")

    self:_button(
        loc("ui_refresh_live"),
        "",
        W - PAD - 458,
        by,
        116,
        34,
        { kind = "refresh_player" },
        { align = "center", font_size = 12 }
    )
    self:_button(
        loc("ui_reset_player"),
        "",
        W - PAD - 336,
        by,
        116,
        34,
        { kind = "reset_player" },
        {
            align = "center",
            font_size = 12,
            title_color = C.red,
        }
    )
    self:_button(
        loc("ui_apply_player"),
        "",
        W - PAD - 214,
        by,
        192,
        34,
        { kind = "commit" },
        {
            align = "center",
            font_size = 14,
            title_color = snapshot.dirty_count > 0 and C.gold or C.green,
        }
    )

    self:_text(loc("ui_look_code"), PAD + 20, FOOTER_Y + 65, 100, 32, 12, C.gold)
    self:_button(
        loc("ui_load_stage"),
        "",
        PAD + 1320,
        FOOTER_Y + 65,
        120,
        32,
        { kind = "_load_code" },
        { align = "center", font_size = 11 }
    )
    self:_button(
        loc("ui_copy_stage"),
        "",
        PAD + 1446,
        FOOTER_Y + 65,
        120,
        32,
        { kind = "copy_code" },
        { align = "center", font_size = 11 }
    )
    self:_text(loc("ui_look_code_help"), PAD + 1572, FOOTER_Y + 65, 300, 32, 11, C.dim, "right")
    self:_rebuild_preset_confirmation()
end

NPCLookStudioView._refresh_snapshot = function(self)
    local api = self:_api()

    if not api or type(api.snapshot) ~= "function" then
        self._snapshot = normalize_snapshot(self._snapshot)
        self._snapshot.feedback = loc("error_bridge_not_ready")
        return false, loc("error_snapshot_bridge")
    end

    if type(api.available) == "function" then
        local available_ok, available = pcall(api.available)

        if available_ok and available ~= true then
            util.report_once(self, "_last_snapshot_error", nil)
            self._snapshot = normalize_snapshot(self._snapshot)
            return false, loc("error_snapshot_bridge")
        end
    end

    if type(api.closing) == "function" then
        local closing_ok, closing = pcall(api.closing)

        if closing_ok and closing == true then
            util.report_once(self, "_last_snapshot_error", nil)
            self._snapshot = normalize_snapshot(self._snapshot)
            return false, loc("error_snapshot_bridge")
        end
    end

    -- This can race MasterItems refreshing after a character swap.
    local ok, snapshot_or_error, returned_error = pcall(api.snapshot)

    if not ok or type(snapshot_or_error) ~= "table" then
        local message = tostring(returned_error or snapshot_or_error or "Snapshot returned no data")
        self._snapshot = normalize_snapshot(self._snapshot)
        self._snapshot.feedback = loc("feedback_snapshot_failed", message)

        util.report_once(self, "_last_snapshot_error", message, function()
            mod:error("Studio snapshot failed")
        end)

        return false, message
    end

    util.report_once(self, "_last_snapshot_error", nil)
    local snapshot = normalize_snapshot(snapshot_or_error)
    self._snapshot = snapshot

    local search_content = self:_input_content("search_input")

    if not search_content or not search_content.is_writing then
        self:_set_search_text(snapshot.item_search, false)
    end

    return true
end

NPCLookStudioView.on_enter = function(self)
    NPCLookStudioView.super.on_enter(self)
    self:_clear_rebuild_error()

    local ok, err = xpcall(function()
        local api = self:_api()

        if not api or type(api.snapshot) ~= "function" then
            error("Snapshot bridge unavailable")
        end

        local active = type(api.active) == "function" and api.active()

        if not active then
            if type(api.begin) ~= "function" then
                error("Session bridge unavailable")
            end

            local begin_ok = api.begin(self._preview_player)

            if not begin_ok then
                error("Session setup was refused")
            end
        end

        if type(api.attach_view) ~= "function" or api.attach_view(VIEW_NAME) ~= true then
            error("Studio session ownership unavailable")
        end

        self._session_attached = true
        self:_refresh_snapshot()
        self:_rebuild_safe()
    end, util.traceback)

    if not ok then
        self:_reset_pools()
        self:_set_rebuild_error(err)
        mod:error("Studio startup failed: %s", tostring(err))
    end
end

NPCLookStudioView.update = function(self, dt, t, input_service)
    local api = self:_api()

    if api and type(api.set_preview_input) == "function" then
        local input_ok, input_error = pcall(
            api.set_preview_input,
            self._snapshot and self._snapshot.inspect_mode and input_service or nil
        )

        util.report_once(
            self,
            "_preview_input_bridge_error",
            not input_ok and tostring(input_error) or nil,
            function(message)
                mod:error("Studio preview input bridge failed: %s", message)
            end
        )
    end

    local search_content = self:_input_content("search_input")
    local look_code_content = self:_input_content("look_code_input")
    local preset_name_content = self:_input_content("preset_name_input")
    local opacity_content = self:_input_content("opacity_input")
    local pressed_global

    if self:_input_was_pressed(search_content) then
        pressed_global = search_content
        self:_deactivate_input(look_code_content)
        self:_deactivate_input(preset_name_content)
        self:_deactivate_input(opacity_content)
        self:_stop_transform_inputs()
    elseif self:_input_was_pressed(look_code_content) then
        pressed_global = look_code_content
        self:_deactivate_input(search_content)
        self:_deactivate_input(preset_name_content)
        self:_deactivate_input(opacity_content)
        self:_stop_transform_inputs()
    elseif self:_input_was_pressed(preset_name_content) then
        pressed_global = preset_name_content
        self:_deactivate_input(search_content)
        self:_deactivate_input(look_code_content)
        self:_deactivate_input(opacity_content)
        self:_stop_transform_inputs()
    elseif self:_input_was_pressed(opacity_content) then
        pressed_global = opacity_content
        self:_deactivate_input(search_content)
        self:_deactivate_input(look_code_content)
        self:_deactivate_input(preset_name_content)
        self:_stop_transform_inputs()
    end

    local transform_spec, transform_content = self:_active_transform_input()
    local search_text = search_content and tostring(search_content.input_text or "") or ""

    if transform_content then
        self:_deactivate_input(search_content)
        self:_deactivate_input(look_code_content)
        self:_deactivate_input(preset_name_content)
        self:_deactivate_input(opacity_content)
    elseif not pressed_global then
        if opacity_content and opacity_content.is_writing then
            self:_deactivate_input(search_content)
            self:_deactivate_input(look_code_content)
            self:_deactivate_input(preset_name_content)
            self:_stop_transform_inputs()
        elseif look_code_content and look_code_content.is_writing then
            self:_deactivate_input(search_content)
            self:_deactivate_input(preset_name_content)
            self:_deactivate_input(opacity_content)
            self:_stop_transform_inputs()
        elseif preset_name_content and preset_name_content.is_writing then
            self:_deactivate_input(search_content)
            self:_deactivate_input(look_code_content)
            self:_deactivate_input(opacity_content)
            self:_stop_transform_inputs()
        elseif search_content and search_content.is_writing then
            self:_deactivate_input(look_code_content)
            self:_deactivate_input(preset_name_content)
            self:_deactivate_input(opacity_content)
            self:_stop_transform_inputs()
        end
    end

    if input_service and input_service:get("left_pressed") and not self:_input_hotspot_hovered() then
        local opacity_changed = self:_commit_opacity_input(api)
        self:_stop_all_inputs()
        transform_spec, transform_content = nil, nil

        if opacity_changed then
            self:_refresh_snapshot()
            self:_rebuild_safe()
        end
    end

    if transform_spec and transform_content then
        local transform_text = tostring(transform_content.input_text or "")

        if transform_text ~= self._last_transform_text[transform_spec.field] then
            self._last_transform_text[transform_spec.field] = transform_text
            local transform_value = tonumber(transform_text)

            if transform_value then
                self:_dispatch_action(api, {
                    kind = "set_extra_transform",
                    field = transform_spec.field,
                    value = transform_value,
                })
                self:_refresh_snapshot()
                self:_rebuild_safe()
            end
        end
    end

    if search_content and search_text ~= self._last_search_text then
        self._last_search_text = search_text

        self:_dispatch_action(api, { kind = "set_search", query = search_text })

        self:_refresh_snapshot()
        self:_rebuild_safe()
    end

    if self._ui_failed
        and self._rebuild_retry.attempts < util.RETRY_LIMIT
        and util.retry_due(self._rebuild_retry, dt) then
        self:_refresh_snapshot()
        self:_rebuild_safe()
    end

    if self._preset_confirmation and input_service and input_service:get("confirm_pressed") then
        local confirmation = self._preset_confirmation

        self:_clear_preset_confirmation()
        self:_dispatch_action(api, confirmation.action)

        if confirmation.action.kind == "delete_player_preset" then
            self:_set_input_text("preset_name_input", "", true)
        end

        self:_refresh_snapshot()
        self:_rebuild_safe()

        return NPCLookStudioView.super.update(self, dt, t, input_service)
    end

    if input_service and input_service:get("confirm_pressed") then
        if opacity_content and opacity_content.is_writing then
            local opacity_changed = self:_commit_opacity_input(api)

            if opacity_changed then
                self:_refresh_snapshot()
            end

            self:_rebuild_safe()
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif transform_content then
            self:_deactivate_input(transform_content)
            self:_refresh_snapshot()
            self:_rebuild_safe()
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif look_code_content and look_code_content.is_writing then
            self:_submit_look_code(api)
            self:_refresh_snapshot()
            self:_rebuild_safe()
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif preset_name_content and preset_name_content.is_writing
            and self._snapshot and self._snapshot.source_kind == "player" then
            local name = tostring(preset_name_content.input_text or "")

            self:_deactivate_input(preset_name_content)
            self:_open_preset_confirmation({
                kind = "save_player_preset",
                name = name,
            }, name)
            self:_rebuild_safe()

            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif search_content and search_content.is_writing then
            self:_deactivate_input(search_content)
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        end
    end

    if input_service and input_service:get("back") then
        if self._preset_confirmation then
            self:_clear_preset_confirmation()
            self:_rebuild_safe()

            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif opacity_content and opacity_content.is_writing then
            self:_cancel_opacity_input()
            self:_rebuild_safe()
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif transform_content then
            self:_deactivate_input(transform_content)
            self:_refresh_snapshot()
            self:_rebuild_safe()
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif look_code_content and look_code_content.is_writing then
            self:_deactivate_input(look_code_content)
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif preset_name_content and preset_name_content.is_writing then
            self:_deactivate_input(preset_name_content)
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif search_content and search_content.is_writing then
            self:_deactivate_input(search_content)
            return NPCLookStudioView.super.update(self, dt, t, input_service)
        elseif self._snapshot and self._snapshot.inspect_mode then
            self:_dispatch_action(api, { kind = "toggle_inspect" })
            self:_refresh_snapshot()
            self:_rebuild_safe()
        else
            close_view_safely(VIEW_NAME)
        end

        return NPCLookStudioView.super.update(self, dt, t, input_service)
    end

    local clicked

    for i = 1, #(self._actions or {}) do
        local widget = self._actions[i]
        local content = widget and widget.content
        local hotspot = type(content) == "table" and content.hotspot or nil

        if type(hotspot) == "table" and hotspot.on_pressed then
            hotspot.on_pressed = false

            if not content.disabled then
                clicked = content._action
                break
            end
        end
    end

    if clicked then
        local opacity_changed = self:_commit_opacity_input(api)

        if opacity_changed then
            self:_refresh_snapshot()
        end

        if search_content then
            self:_deactivate_input(search_content)
        end

        if look_code_content then
            self:_deactivate_input(look_code_content)
        end

        if preset_name_content then
            self:_deactivate_input(preset_name_content)
        end

        if opacity_content then
            self:_deactivate_input(opacity_content)
        end

        self:_stop_transform_inputs()

        if clicked.kind == "_cancel_preset_confirmation" then
            self:_clear_preset_confirmation()
            self:_rebuild_safe()
        elseif clicked.kind == "_confirm_preset_confirmation" then
            local confirmation = self._preset_confirmation

            self:_clear_preset_confirmation()

            if confirmation then
                self:_dispatch_action(api, confirmation.action)

                if confirmation.action.kind == "delete_player_preset" then
                    self:_set_input_text("preset_name_input", "", true)
                end
            end

            self:_refresh_snapshot()
            self:_rebuild_safe()
        elseif clicked.kind == "_close" then
            close_view_safely(VIEW_NAME)
        elseif clicked.kind == "_load_code" then
            self:_submit_look_code(api)
            self:_refresh_snapshot()
            self:_rebuild_safe()
        elseif clicked.kind == "_clear_search" then
            self:_set_search_text("", false)

            self:_dispatch_action(api, { kind = "set_search", query = "" })

            self:_refresh_snapshot()
            self:_rebuild_safe()
        elseif clicked.kind == "_camera" then
            self:_dispatch_action(api, { kind = "camera_focus", camera = clicked.camera })
            self:_refresh_snapshot()
            self:_rebuild_safe()
        elseif clicked.kind == "_save_player_preset" then
            local name = preset_name_content and tostring(preset_name_content.input_text or "") or ""

            self:_open_preset_confirmation({
                kind = "save_player_preset",
                name = name,
            }, name)
            self:_rebuild_safe()
        elseif clicked.kind == "delete_player_preset" then
            local name = self._snapshot and self._snapshot.selected_source or ""

            self:_open_preset_confirmation(clicked, name)
            self:_rebuild_safe()
        else
            self:_dispatch_action(api, clicked)

            if clicked.kind == "select_source" and self._snapshot and self._snapshot.source_kind == "player" then
                self:_set_input_text("preset_name_input", clicked.source, true)
            end

            self:_refresh_snapshot()
            self:_rebuild_safe()
        end
    end

    return NPCLookStudioView.super.update(self, dt, t, input_service)
end

NPCLookStudioView.draw = function(self, dt, t, input_service, layer)
    local ok, err = xpcall(function()
        NPCLookStudioView.super.draw(self, dt, t, input_service, layer)
    end, util.traceback)

    if ok then
        util.report_once(self, "_last_draw_error", nil)
        return
    end

    local message = tostring(err or loc("generic_unknown_error"))
    util.report_once(self, "_last_draw_error", message, function(new_message)
        mod:error("Studio draw failed: %s", new_message)
    end)
    self:_set_rebuild_error(message)

    xpcall(function()
        local render_settings = self._render_settings or {}
        local render_scale = self._render_scale or 1
        render_settings.start_layer = layer or 1
        render_settings.scale = render_scale
        render_settings.inverse_scale = render_scale ~= 0 and 1 / render_scale or 1

        UIRenderer.begin_pass(self._ui_renderer, self._ui_scenegraph, input_service, dt, render_settings)

        local frame = self:_widget("frame")
        local rebuild_error = self:_widget("rebuild_error")

        if frame then
            UIWidget.draw(frame, self._ui_renderer)
        end
        if rebuild_error then
            UIWidget.draw(rebuild_error, self._ui_renderer)
        end

        UIRenderer.end_pass(self._ui_renderer)
    end, util.traceback)
end

NPCLookStudioView.on_exit = function(self)
    local function cleanup(label, fn, ...)
        if type(fn) ~= "function" then
            return true
        end

        local ok, err = pcall(fn, ...)

        if not ok then
            mod:warning("Studio cleanup failed (%s): %s", tostring(label), tostring(err))
        end

        return ok
    end

    local api = self:_api()

    if api then
        cleanup("release preview input", api.set_preview_input, nil)

        if self._session_attached then
            cleanup("detach studio session", api.detach_view, VIEW_NAME)
            self._session_attached = false
        end
    end

    local ui_manager = Managers.ui
    local preview_name = self._context and self._context.preview_view_name or PREVIEW_VIEW_NAME

    if ui_manager and preview_name and type(ui_manager.view_active) == "function" then
        local ok, active = pcall(ui_manager.view_active, ui_manager, preview_name)

        if ok and active then
            cleanup("close preview", ui_manager.close_view, ui_manager, preview_name)
        end
    end

    if api then
        cleanup("finish session", api.finish)
    end

    NPCLookStudioView.super.on_exit(self)
end

return NPCLookStudioView
