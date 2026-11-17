local mod = get_mod("NPCLook")
local util = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_util")
local PACKAGES = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_packages")
local EquipmentComponent = require("scripts/extension_systems/visual_loadout/equipment_component")
local PlayerCharacterBody = require("scripts/utilities/player_character_body")
local PlayerCharacterConstants = require("scripts/settings/player_character/player_character_constants")

-- Look pieces live in a private equipment copy, the games slots never see them

local Overlay = {}

local CONTROL_KEY = "npclook_control"
local HIDDEN_PREFIX = "npclook_hidden_"

-- On the mod object so a reload can still clean up the old overlays
local overlays = rawget(mod, "npclook_overlays")

if type(overlays) ~= "table" then
    overlays = {}
    rawset(mod, "npclook_overlays", overlays)
end

-- Same units unequip_item deletes, so the lease tracks all of them
local function slot_units(slot)
    local units = {}

    for _, side in ipairs({ "3p", "1p" }) do
        local root = slot["unit_" .. side]

        if root then
            units[#units + 1] = root
        end

        for _, attachments in pairs(slot["attachments_by_unit_" .. side] or {}) do
            for i = 1, #attachments do
                units[#units + 1] = attachments[i]
            end
        end
    end

    return units
end

local function create(ext)
    local unit = ext._unit
    local real_component = ext._equipment_component
    local breed = ext._unit_data_extension:breed()
    -- No extension manager, like the inventory preview
    local component = EquipmentComponent:new(
        real_component._world,
        ext._item_definitions,
        real_component._unit_spawner,
        unit,
        nil,
        nil,
        nil,
        true
    )
    local control_item = {
        hide_slots = {},
    }
    local overlay = {
        ext = ext,
        unit = unit,
        real_equipment = ext._equipment,
        component = component,
        equipment = EquipmentComponent.initialize_equipment(ext._slot_configuration, breed),
        breed_name = breed.name,
        slots = {},
        pending = {},
        hidden = {},
        pseudo = {},
        effective = {},
        neck_locked = false,
        control_item = control_item,
        control = {
            name = CONTROL_KEY,
            equipped = true,
            item = control_item,
        },
    }

    overlays[unit] = overlay

    return overlay
end

local function retire_pending(overlay, slot_name)
    local pending = overlay.pending[slot_name]

    if pending then
        overlay.pending[slot_name] = nil
        PACKAGES.retire(pending)
    end
end

local function unequip(overlay, slot_name)
    local record = overlay.slots[slot_name]

    if not record then
        return
    end

    local slot = overlay.equipment[slot_name]

    overlay.slots[slot_name] = nil
    PACKAGES.bind(record.lease, slot_units(slot))
    pcall(overlay.component.unequip_item, overlay.component, slot)
    PACKAGES.retire(record.lease)
end

local function equip(overlay, slot_name, item, lease)
    local ext = overlay.ext
    local slot = overlay.equipment[slot_name]
    local deform_override_items = item.deform_override_items and table.clone(item.deform_override_items) or {}
    local wrap_deform_item = PlayerCharacterBody.wrap_deform_item_name_from_profile(ext._player:profile())

    -- Same deform list as _equip_item_to_slot
    if wrap_deform_item then
        deform_override_items[#deform_override_items + 1] = wrap_deform_item
    end

    local ok, err = pcall(
        overlay.component.equip_item,
        overlay.component,
        overlay.unit,
        ext._first_person_unit,
        slot,
        item,
        nil,
        deform_override_items,
        overlay.breed_name,
        ext._mission,
        overlay.equipment
    )

    PACKAGES.bind(lease, slot_units(slot))

    if not ok or not slot.unit_3p then
        if slot.item then
            pcall(overlay.component.unequip_item, overlay.component, slot)
        end
        PACKAGES.retire(lease)

        return false, ok and "no unit was spawned" or tostring(err)
    end

    overlay.slots[slot_name] = {
        item = item,
        signature = item.npclook_visual_signature,
        lease = lease,
    }

    return true
end

local function ready_lease(overlay, slot_name, item)
    local pending = overlay.pending[slot_name]

    if pending and (pending.package_manager ~= Managers.package
        or pending.signature ~= item.npclook_visual_signature) then
        retire_pending(overlay, slot_name)
        pending = nil
    end

    if not pending then
        local package_names, dependency_error = PACKAGES.item_dependencies(
            item,
            overlay.ext._item_definitions,
            overlay.ext._mission
        )

        if not package_names then
            return nil, tostring(dependency_error), false
        end

        local lease, lease_error = PACKAGES.acquire(package_names, "Look")

        if not lease then
            return nil, tostring(lease_error), false
        end

        lease.signature = item.npclook_visual_signature

        if item.npclook_raw_unit == true or item.material_override_apply_to_parent == true then
            PACKAGES.use_world_rule(lease)
        end

        overlay.pending[slot_name] = lease
        pending = lease
    end

    local ready, waiting_package = PACKAGES.ready(pending)

    if not ready then
        return nil, string.format("%s is still loading", tostring(waiting_package)), true
    end

    overlay.pending[slot_name] = nil

    return pending
end

local function refresh_visibility(overlay)
    local ext = overlay.ext

    if util.safe_unit_alive(overlay.unit) and type(ext.force_update_item_visibility) == "function" then
        pcall(ext.force_update_item_visibility, ext)
    end
end

local function discard(overlay)
    for slot_name in pairs(overlay.pending) do
        retire_pending(overlay, slot_name)
    end

    for _, record in pairs(overlay.slots) do
        PACKAGES.retire(record.lease)
    end

    overlays[overlay.unit] = nil
end

-- show_profile reruns the pass so profile pieces get lua_visible, off when the character is deleted
function Overlay.clear(unit, show_profile)
    local overlay = overlays[unit]

    if not overlay then
        return
    end

    local order = PlayerCharacterConstants.slot_equip_order or {}

    for i = #order, 1, -1 do
        unequip(overlay, order[i])
    end

    for slot_name in pairs(overlay.slots) do
        unequip(overlay, slot_name)
    end

    table.clear(overlay.hidden)

    if show_profile then
        refresh_visibility(overlay)
    end

    discard(overlay)
end

function Overlay.sync(ext, desired, hidden)
    local unit = ext and ext._unit
    local overlay = overlays[unit]

    if not overlay and next(desired) == nil and next(hidden) == nil then
        return true, 0, 0, nil, false
    end

    overlay = overlay or create(ext)

    local order = PlayerCharacterConstants.slot_equip_order or {}
    local changed, failed = 0, 0
    local first_error
    local loading = false

    -- Old pieces go first, new ones wait for their packages
    for i = #order, 1, -1 do
        local slot_name = order[i]

        if not desired[slot_name] then
            if overlay.slots[slot_name] then
                unequip(overlay, slot_name)
                changed = changed + 1
            end

            retire_pending(overlay, slot_name)
        end
    end

    for i = 1, #order do
        local slot_name = order[i]
        local item = desired[slot_name]
        local current = overlay.slots[slot_name]

        if item and current and current.signature == item.npclook_visual_signature then
            retire_pending(overlay, slot_name)
        elseif item then
            local lease, lease_error, lease_loading = ready_lease(overlay, slot_name, item)

            if lease then
                unequip(overlay, slot_name)

                local ok, equip_error = equip(overlay, slot_name, item, lease)

                if ok then
                    changed = changed + 1
                else
                    failed = failed + 1
                    first_error = first_error or string.format("%s: %s", slot_name, equip_error)
                end
            elseif lease_loading then
                loading = true
            else
                failed = failed + 1
                first_error = first_error or string.format("%s: %s", slot_name, lease_error)
            end
        end
    end

    table.clear(overlay.hidden)

    -- Keep the profile piece until its replacement is in
    for slot_name in pairs(hidden) do
        if not desired[slot_name] or overlay.slots[slot_name] then
            overlay.hidden[slot_name] = true
        end
    end

    if next(overlay.slots) == nil and next(overlay.hidden) == nil and next(overlay.pending) == nil then
        Overlay.clear(unit, true)
    else
        refresh_visibility(overlay)
    end

    return failed == 0 and not loading, changed, failed, first_error, loading
end

function Overlay.matches(ext, desired, hidden)
    local overlay = ext and overlays[ext._unit]
    local slots = overlay and overlay.slots or {}

    for slot_name, item in pairs(desired) do
        if not slots[slot_name] or slots[slot_name].signature ~= item.npclook_visual_signature then
            return false, slot_name
        end
    end

    for slot_name in pairs(slots) do
        if not desired[slot_name] then
            return false, slot_name
        end
    end

    for slot_name in pairs(hidden) do
        if not (overlay and overlay.hidden[slot_name]) then
            return false, slot_name
        end
    end

    for slot_name in pairs(overlay and overlay.hidden or {}) do
        if not hidden[slot_name] then
            return false, slot_name
        end
    end

    return true
end

function Overlay.clear_all(show_profile)
    for unit in pairs(overlays) do
        Overlay.clear(unit, show_profile)
    end
end

-- Characters gone without mark_for_deletion (world teardown)
function Overlay.prune()
    for unit, overlay in pairs(overlays) do
        if not util.safe_unit_alive(unit) then
            for slot_name in pairs(overlay.slots) do
                unequip(overlay, slot_name)
            end

            discard(overlay)
        end
    end
end

function Overlay.for_unit(unit)
    return unit ~= nil and overlays[unit] or nil
end

function Overlay.slot_unit_3p(unit, slot_name)
    local overlay = overlays[unit]
    local slot = overlay and overlay.slots[slot_name] and overlay.equipment[slot_name]

    return slot and slot.unit_3p
end

-- Real equipment with the look swapped in, for the games visibility pass
function Overlay.effective_equipment(equipment, unit_3p, first_person_mode)
    local overlay = unit_3p and overlays[unit_3p]

    if not overlay or overlay.real_equipment ~= equipment then
        return nil
    end

    local effective = overlay.effective
    local hide_slots = overlay.control_item.hide_slots

    table.clear(effective)
    table.clear(hide_slots)

    for slot_name, slot in pairs(equipment) do
        local pseudo = overlay.pseudo[slot_name]
        local hidden = overlay.hidden[slot_name]

        if hidden or pseudo then
            -- No item so hidden pieces drop their masks and neck lock. Shown again stays one more pass for lua_visible
            local key = HIDDEN_PREFIX .. slot_name

            pseudo = pseudo or { name = key }
            pseudo.equipped = false

            -- Respawned profile piece hasnt had lua_hidden yet
            if pseudo.unit_3p ~= slot.unit_3p then
                pseudo.hidden_3p = nil
            end

            if pseudo.unit_1p ~= slot.unit_1p then
                pseudo.hidden_1p = nil
            end

            pseudo.unit_3p = slot.unit_3p
            pseudo.unit_1p = slot.unit_1p
            pseudo.attachments_by_unit_3p = slot.attachments_by_unit_3p
            pseudo.attachments_by_unit_1p = slot.attachments_by_unit_1p
            effective[key] = pseudo
            overlay.pseudo[slot_name] = hidden and pseudo or nil

            if hidden then
                hide_slots[#hide_slots + 1] = key

                local item = slot.equipped and slot.item

                if item and (tonumber(item.stabilize_neck) or 0) > 0 then
                    overlay.neck_locked = true
                end
            end
        end

        if overlay.slots[slot_name] then
            effective[slot_name] = overlay.equipment[slot_name]
        elseif not hidden then
            effective[slot_name] = slot
        end
    end

    for _, record in pairs(overlay.slots) do
        if (tonumber(record.item.stabilize_neck) or 0) > 0 then
            overlay.neck_locked = true
        end
    end

    -- NeckLock only unlocks on 0
    overlay.control_item.stabilize_neck = overlay.neck_locked and 0 or nil

    -- Hidden flags preset so the control slot never sends flow events
    local control = overlay.control

    control.unit_3p = unit_3p
    control.unit_1p = unit_3p
    control.hidden_3p = first_person_mode == true
    control.hidden_1p = first_person_mode ~= true
    effective[CONTROL_KEY] = control

    return effective
end

return Overlay
