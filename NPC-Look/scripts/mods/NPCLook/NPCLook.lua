local mod = get_mod("NPCLook")

-- Gameplay and Studio must share the same extra-slot runtime.
local EXTRA_RUNTIME_OWNERSHIP_SCHEMA = 2
local previous_extra_slot_runtime = rawget(mod, "npclook_extra_slot_runtime")
local previous_raw_unit_shutdown = type(rawget(mod, "npclook_raw_units_runtime")) == "table"
    and rawget(mod, "npclook_raw_units_runtime").release_all
    or rawget(mod, "npclook_raw_units_release_autoload")

if previous_extra_slot_runtime then
    local begin_shutdown = previous_extra_slot_runtime.begin_shutdown
    local shutdown = previous_extra_slot_runtime.shutdown
        or previous_extra_slot_runtime.release_all

    if previous_extra_slot_runtime.ownership_schema == EXTRA_RUNTIME_OWNERSHIP_SCHEMA
        and type(shutdown) == "function" then
        if type(begin_shutdown) == "function" then
            pcall(begin_shutdown)
        end

        pcall(shutdown)
    else
        mod:warning("Older visual ownership state was found. Unsafe hot-reload cleanup was skipped; restart Darktide to clear it.")
    end
end

if type(previous_raw_unit_shutdown) == "function" then
    pcall(previous_raw_unit_shutdown)
end

-- Remove obsolete module state retained on the DMF mod object by older builds.
rawset(mod, "npclook_apply_opacity_to_unit", nil)
rawset(mod, "npclook_filter_materials_for_targets", nil)
rawset(mod, "npclook_owned_visual_units", nil)
rawset(mod, "npclook_owned_visual_spawners", nil)
rawset(mod, "npclook_owned_visual_parents", nil)
rawset(mod, "npclook_owned_visual_children", nil)
rawset(mod, "npclook_owned_visual_records", nil)
rawset(mod, "npclook_normalize_opacity", nil)
rawset(mod, "npclook_apply_opacity_to_units", nil)
rawset(mod, "npclook_normalize_materials", nil)
rawset(mod, "npclook_apply_material_entries_to_units", nil)
rawset(mod, "npclook_collect_material_units", nil)
rawset(mod, "npclook_raw_units_release_autoload", nil)
rawset(mod, "npclook_raw_units_runtime", nil)
rawset(mod, "npclook_raw_unit_registry", nil)
rawset(mod, "npclook_raw_overlay_fallbacks", nil)
rawset(mod, "npclook_raw_unit_state", nil)
rawset(mod, "npclook_meshes_runtime", nil)

local INSTANCE_GENERATION = (tonumber(rawget(mod, "npclook_instance_generation")) or 0) + 1
rawset(mod, "npclook_instance_generation", INSTANCE_GENERATION)

local util = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_util")
local RAW_UNITS = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_raw_units")
local MASKS = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_masks")
local CUSTOM_ASSETS = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_custom_assets")
local MESHES = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_meshes")
local loc = util.localize

rawset(mod, "npclook_extra_slot_runtime", nil)
local extra_slot_runtime = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_extra_slots")
local extra_slot_has_update_work = extra_slot_runtime and extra_slot_runtime.has_update_work
local extra_slot_update = extra_slot_runtime and extra_slot_runtime.update
local extra_slot_update_faulted = false

if type(extra_slot_has_update_work) ~= "function" or type(extra_slot_update) ~= "function" then
    mod:warning("Extra-slot runtime update API is incomplete; background slot maintenance is disabled.")
    extra_slot_has_update_work = nil
    extra_slot_update = nil
end

local MasterItems = require("scripts/backend/master_items")
local PlayerUnitVisualLoadoutExtension = require("scripts/extension_systems/visual_loadout/player_unit_visual_loadout_extension")
local EquipmentComponent = require("scripts/extension_systems/visual_loadout/equipment_component")
local MispredictPackageHandler = require("scripts/extension_systems/visual_loadout/mispredict_package_handler")
local ItemPackage = require("scripts/foundation/managers/package/utilities/item_package")
local HumanGameplay = require("scripts/managers/player/player_game_states/human_gameplay")
local PlayerCharacterConstants = require("scripts/settings/player_character/player_character_constants")
local ItemSlotSettings = require("scripts/settings/item/item_slot_settings")
local FixedFrame = require("scripts/utilities/fixed_frame")
local UIUnitSpawner = require("scripts/managers/ui/ui_unit_spawner")
local UnitSpawnerManager = require("scripts/foundation/managers/unit_spawner/unit_spawner_manager")

-- Configuration and state

local SLOT_CONFIG = PlayerCharacterConstants.slot_configuration
local VIEW_CONFIG = {
    studio_name = "npclook_studio_view",
    preview_name = "npclook_studio_preview_view",
    studio_module_path = "NPCLook/scripts/mods/NPCLook/npclook_view",
    preview_module_path = "NPCLook/scripts/mods/NPCLook/npclook_preview_view",
    studio_package = "packages/ui/views/options_view/options_view",
    preview_package = "packages/ui/views/inventory_cosmetics_view/inventory_cosmetics_view",
    studio_level = "content/levels/ui/cosmetics_preview/cosmetics_preview",
}

local _disk = get_mod("DMF"):persistent_table("NPCLook_disk")

if not _disk.io or not _disk.os then
    local dmf = get_mod("DMF")
    _disk.io = dmf.deepcopy(Mods.lua.io)
    _disk.os = dmf.deepcopy(Mods.lua.os)
end

-- No gameplay timer exists while the game is between states.
local function gameplay_time_manager()
    local time_manager = Managers.time

    return time_manager and time_manager:has_timer("gameplay") and time_manager or nil
end

local _look_state = {
    applied = {},
    suppressed = {},
    empty = {},
    extra_anchors = {},
    extra_transforms = {},
    materials = {},
    opacity = {},
    variants = {},
    masks = {},
    meshes = {},
}

local EXTRA_SLOTS = {}
EXTRA_SLOTS.visual_loadout_customization = require("scripts/extension_systems/visual_loadout/utilities/visual_loadout_customization")
EXTRA_SLOTS.profile_utils = require("scripts/utilities/profile_utils")
local _studio_view_registered = false
local _studio_session
local _master_items_cache
local _master_items_cache_version
local _studio_item_catalog
local _bound_player_unit
local _reapply_pending = false
local _vanilla_restore_pending = false
local _reapply_retry = util.new_retry(0.1, 1, 1.6)
local _runtime_reports = {}
local _game_state_ready = gameplay_time_manager() ~= nil
local _live_profile_sync_waiting = false
local _live_package_loads = {}
local _pending_live_package_loads = {}
local _retired_live_package_loads = {}
local _live_package_counter = 0
local _live_package_gameplay_t
local _retained_live_raw_package_cache = {
    package_manager = nil,
    entries = {},
}
local _binding_poll_elapsed = 0
local _startup_cleanup_pending = true
local _startup_cleanup_elapsed = 0
local _startup_cleanup_attempts = 0
local STARTUP_CLEANUP_MAX_ATTEMPTS = 120
local BINDING_POLL_INTERVAL = 0.25
-- Generated units are tracked at equip time; this slower sweep only catches late native respawns.
local PACKAGE_UNIT_REFRESH_INTERVAL = 2
local _package_unit_refresh_elapsed = 0

local function hook_method(target, method_name, callback)
    local method = target and target[method_name]

    if type(method) ~= "function" then
        mod:warning("Compatibility: missing method %s", tostring(method_name))
        return false
    end

    local generation = INSTANCE_GENERATION
    local guarded_callback = function(func, ...)
        if rawget(mod, "npclook_instance_generation") ~= generation then
            return func(...)
        end

        return callback(func, ...)
    end
    local ok, err = pcall(mod.hook, mod, target, method_name, guarded_callback)

    if not ok then
        mod:warning("Compatibility: could not hook %s: %s", tostring(method_name), tostring(err))
        return false
    end

    return true
end

local function hook_module(module_path, method_name, callback)
    local ok, target = pcall(require, module_path)

    if not ok then
        mod:warning("Compatibility: missing module %s", tostring(module_path))
        return false
    end

    return hook_method(target, method_name, callback)
end

local function safe_player_unit(player)
    return player and player.player_unit
end

local function safe_profile(player)
    if not player or type(player.profile) ~= "function" then
        return nil
    end

    local ok, profile = pcall(player.profile, player)

    return ok and profile or nil
end

local function profile_breed_name(profile)
    local archetype = profile and profile.archetype

    return archetype and archetype.breed
end


-- Network.peer_id is unavailable before the connection manager exists.
local function get_local_player()
    local player_manager = Managers.player

    if not player_manager then
        return nil
    end

    local player

    if type(player_manager.local_player_safe) == "function" then
        local ok, resolved_player = pcall(player_manager.local_player_safe, player_manager, 1)

        if ok then
            player = resolved_player
        end
    end

    if player then
        return player
    end

    local human_players = {}

    if type(player_manager.human_players) == "function" then
        local ok, resolved_players = pcall(player_manager.human_players, player_manager)

        if ok and type(resolved_players) == "table" then
            human_players = resolved_players
        end
    end

    for _, human_player in pairs(human_players) do
        if human_player and not human_player.remote then
            return human_player
        end
    end

    return nil
end

local function studio_input_locked(player)
    return _studio_session ~= nil and _studio_session.closing ~= true and player == get_local_player()
end

-- Darktide: scripts/managers/player/player_game_states/human_gameplay.lua
hook_method(HumanGameplay, "_input_active", function(func, self)
    if studio_input_locked(self._player) then
        return false
    end

    return func(self)
end)

local PREFERRED_LOOK_SLOT_ORDER = {
    "slot_gear_head",
    "slot_body_face",
    "slot_body_hair",
    "slot_body_hair_color",
    "slot_body_face_hair",
    "slot_body_face_hair_color",
    "slot_body_face_tattoo",
    "slot_body_face_scar",
    "slot_body_face_makeup",
    "slot_body_eye_color",
    "slot_body_eye_color_secondary",
    "slot_body_skin_color",
    "slot_body_skin_color_secondary",
    "slot_body_skin_discoloration",
    "slot_gear_upperbody",
    "slot_body_torso",
    "slot_body_arms",
    "slot_gear_lowerbody",
    "slot_body_legs",
    "slot_body_tattoo",
    "slot_gear_extra_cosmetic",
    "slot_gear_material_override_decal",
}

local LOOK_SLOTS = {}

for i = 1, #PREFERRED_LOOK_SLOT_ORDER do
    local slot_name = PREFERRED_LOOK_SLOT_ORDER[i]

    if SLOT_CONFIG[slot_name] then
        LOOK_SLOTS[slot_name] = true
    end
end

-- The NPC list includes slots that cannot be equipped directly.
local discovered_slots = {}
for slot_name, config in pairs(ItemSlotSettings) do
    if type(slot_name) == "string" and type(config) == "table" then
        local slot_type = config.slot_type
        local visual = slot_type == "body" or slot_type == "gear" or slot_type == "material"
        local companion = string.find(slot_name, "slot_companion_", 1, true) == 1

        if visual and not companion and not config.ignore_character_spawning and SLOT_CONFIG[slot_name] then
            discovered_slots[#discovered_slots + 1] = slot_name
        end
    end
end

table.sort(discovered_slots)

for i = 1, #discovered_slots do
    LOOK_SLOTS[discovered_slots[i]] = true
end

local NPC_SLOT_REMAP = {
    slot_gear_torso   = "slot_gear_upperbody",
    slot_gear_legs    = "slot_gear_lowerbody",
    slot_gear_arms    = "slot_body_arms",
    slot_gear_head    = "slot_gear_head",
    slot_gear_face    = "slot_body_face",
    slot_body_face    = "slot_body_face",
    slot_body_hair    = "slot_body_hair",
    slot_gear_gloves  = "slot_gear_extra_cosmetic",
    slot_gear_shoes   = "slot_body_tattoo",
}

local OVERFLOW_SLOTS = {
    "slot_body_face_tattoo", "slot_body_face_scar",
    "slot_body_face_makeup", "slot_body_torso",
}

local REPLACE_BODY_SUPPRESS = {
    "slot_body_torso", "slot_body_arms", "slot_body_legs",
    "slot_body_hair", "slot_body_hair_color",
    "slot_body_face_hair", "slot_body_face_hair_color",
    "slot_body_tattoo", "slot_body_face_tattoo",
    "slot_body_face_scar", "slot_body_face_makeup",
    "slot_body_eye_color", "slot_body_eye_color_secondary",
    "slot_body_skin_color", "slot_body_skin_color_secondary",
    "slot_body_skin_discoloration",
}
local REPLACE_GEAR_SLOTS = {
    "slot_gear_head", "slot_gear_upperbody",
    "slot_gear_lowerbody", "slot_gear_extra_cosmetic",
    "slot_gear_material_override_decal",
}

-- Some NPC pieces only fit in spare cosmetic slots.
local OUTFIT_PRESETS = {
    hadron = {
        slot_body_face            = "content/items/characters/player/human/faces/npc_hadron_seven_three_face",
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_hadron_seven_three_arms",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_hadron_seven_three_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_legs/npc_hadron_seven_three_lowerbody",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_arms/npc_hadron_seven_three_hand_left",
        slot_body_tattoo          = "content/items/characters/player/human/gear_attachments/npc_hadron_seven_three_backpack_arm",
    },
    zola = {
        slot_gear_upperbody       = "content/items/characters/player/human/gear_upperbody/zola_upperbody_01",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_lowerbody/zola_lowerbody_01",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_attachments/zola_wound_01",
    },
    morrow = {
        slot_body_face            = "content/items/characters/player/human/faces/face_vin_morrow",
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_vin_morrow_arms",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_vin_morrow_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_legs/npc_vin_morrow_lowerbody",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_hands/npc_vin_morrow_gloves_outfit",
    },
    rannick = {
        slot_body_face            = "content/items/characters/player/human/faces/face_iven_rannick",
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_iven_rannick_arms",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_iven_rannick_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_legs/npc_iven_rannick_pants",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_hands/npc_iven_rannick_gloves",
        slot_body_tattoo          = "content/items/characters/player/human/gear_feet/npc_iven_rannick_boots",
        slot_body_face_tattoo     = "content/items/characters/player/human/gear_attachments/npc_iven_rannick_accessories",
    },
    masozi = {
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_gillia_masozi_arms",
        slot_gear_head            = "content/items/characters/player/human/gear_head/npc_gillia_masozi_helmet",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_gillia_masozi_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_legs/npc_gillia_masozi_pants",
        slot_body_tattoo          = "content/items/characters/player/human/gear_feet/npc_gillia_masozi_boots",
        slot_body_face_scar       = "content/items/characters/player/human/gear_head/npc_gillia_masozi_goggles",
    },
    dukane = {
        slot_body_face            = "content/items/characters/player/human/faces/face_darinda_dukane",
        slot_body_hair            = "content/items/characters/player/human/hair/npc_hair_darinda_dukane",
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_darinda_dukane_arms",
        slot_gear_head            = "content/items/characters/player/human/gear_head/npc_darinda_dukane_cap_01",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_darinda_dukane_jacket",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_lowerbody/npc_darinda_dukane_lowerbody",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_hands/npc_darinda_dukane_gloves",
        slot_body_tattoo          = "content/items/characters/player/human/gear_feet/npc_darinda_dukane_shoes",
        slot_body_face_tattoo     = "content/items/characters/player/human/gear_torso/npc_darinda_dukane_torso",
    },
    proctor = {
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_adamant_proctor_upperbody_arms",
        slot_gear_head            = "content/items/characters/player/human/gear_head/npc_adamant_proctor_headgear",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_adamant_proctor_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_lowerbody/npc_adamant_proctor_lowerbody",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_hands/npc_adamant_proctor_upperbody_gloves",
        slot_body_tattoo          = "content/items/characters/player/human/gear_feet/npc_adamant_proctor_lowerbody_shoes",
        slot_body_face_tattoo     = "content/items/characters/player/human/gear_attachments/npc_adamant_proctor_upperbody_attachment",
    },
    techpriest = {
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_tech_priest_arms",
        slot_gear_head            = "content/items/characters/player/human/gear_head/npc_techpriest_headgear",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_tech_priest_torso",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_lowerbody/npc_tech_priest_lowerbody_set_01",
    },
    techpriest_big = {
        slot_body_arms            = "content/items/characters/player/human/gear_arms/npc_tech_priest_arms",
        slot_gear_head            = "content/items/characters/player/human/gear_head/npc_techpriest_headgear_bigger",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_tech_priest_torso",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_lowerbody/npc_tech_priest_lowerbody_set_01",
    },
    hestia = {
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_hestia_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_legs/npc_hestia_lowerbody",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_hands/npc_hestia_gloves",
        slot_body_tattoo          = "content/items/characters/player/human/gear_feet/npc_hestia_boots",
        slot_body_face_tattoo     = "content/items/characters/player/human/gear_attachments/npc_hestia_arms_decal",
    },
    brahms = {
        slot_body_face            = "content/items/characters/player/human/faces/face_emora_brahms",
        slot_body_hair            = "content/items/characters/player/human/hair/hair_emora_brahms",
        slot_gear_upperbody       = "content/items/characters/player/human/gear_torso/npc_emora_brahms_upperbody",
        slot_gear_lowerbody       = "content/items/characters/player/human/gear_legs/npc_emora_brahms_lowerbody",
        slot_gear_extra_cosmetic  = "content/items/characters/player/human/gear_torso/npc_emora_brahms_cloak",
        slot_body_tattoo          = "content/items/characters/player/human/gear_torso/npc_emora_brahms_fur_collar",
        slot_body_face_tattoo     = "content/items/characters/player/human/gear_torso/npc_emora_brahms_jewlery",
    },
    wolfer = {
        slot_gear_upperbody       = "content/items/characters/minions/chaos_traitor_guard/attachments_gear/wolfer_traitor_version",
        slot_body_tattoo =
            "content/items/characters/minions/chaos_traitor_guard/attachments_base/base_upperbody_wolfer_traitor_version",
        slot_body_hair            = "content/items/characters/minions/chaos_traitor_guard/attachments_base/hair_wolfer",
    },
}

local _originals = {}
local live_visual = {
    managed_slots = {},
}

-- The local player owns the module tables above. Companion mods dress other player
-- units (Pilgrimage bots) through owner records, so their packages, originals and
-- plans never mix with the local look.
live_visual.owners = {
    by_player = {},
    by_unit = {},
    count = 0,
    poll_elapsed = 0,
    local_record = {
        state = _look_state,
        originals = _originals,
        package_loads = _live_package_loads,
        pending_package_loads = _pending_live_package_loads,
        managed_slots = live_visual.managed_slots,
    },
}
live_visual.owners.current = live_visual.owners.local_record
local _counter = 0
local _raw_unit_spawn_warnings = {}
local _raw_overlay_retry_requested = false

local function invalidate_raw_catalog()
    if _studio_item_catalog then
        _studio_item_catalog.units = nil
        _studio_item_catalog.units_loaded = false
    end
end

local function item_cache()
    -- Cache identity covers rebuilds that do not expose a version change.
    local ok_version, version = pcall(MasterItems.get_cached_version)
    version = ok_version and version or nil

    if _master_items_cache and version ~= nil and version == _master_items_cache_version then
        return RAW_UNITS.install(_master_items_cache)
    end

    local ok, cache = pcall(MasterItems.get_cached)

    if not ok or not cache then
        return nil
    elseif _master_items_cache == cache and version == _master_items_cache_version then
        return RAW_UNITS.install(cache)
    end

    _master_items_cache = cache
    _master_items_cache_version = version
    RAW_UNITS.install(cache)
    _studio_item_catalog = nil

    return cache
end

local function item_definition(item_name)
    if type(item_name) ~= "string" or item_name == "" then
        return nil
    end

    local cache = item_cache()

    if not cache then
        return nil
    end

    if CUSTOM_ASSETS.is_material_item_name(item_name) then
        return CUSTOM_ASSETS.ensure_material_item(cache, item_name), item_name
    end

    local normalized = RAW_UNITS.normalize(item_name) or item_name
    local item = rawget(cache, normalized)

    if not item and RAW_UNITS.is_resource(normalized) then
        local added
        item, added = RAW_UNITS.ensure(cache, normalized, CUSTOM_ASSETS.unit_metadata(normalized))

        if added then
            invalidate_raw_catalog()
        end
    end

    return item, normalized
end

local function item_slots(item)
    local slots = item and item.slots

    return type(slots) == "table" and slots or nil
end

local function first_slot(item)
    local slots = item_slots(item)

    return slots and slots[1] or nil
end

local function target_slot_for_item(item)
    local slots = item_slots(item)
    local first = slots and slots[1]

    if not slots then
        return nil, first
    end

    -- NPC item slots and player loadout slots don't line up
    for i = 1, #slots do
        local source_slot = slots[i]
        local remapped_slot = NPC_SLOT_REMAP[source_slot]

        if remapped_slot and SLOT_CONFIG[remapped_slot] then
            return remapped_slot, source_slot
        end
    end

    for i = 1, #slots do
        local source_slot = slots[i]

        if LOOK_SLOTS[source_slot] and SLOT_CONFIG[source_slot] then
            return source_slot, source_slot
        end
    end

    return nil, first
end

local FAMILY_COMPONENT_TOKENS = {
    upperbody = true, lowerbody = true, torso = true, arms = true, arm = true,
    legs = true, pants = true, gloves = true, glove = true, boots = true,
    shoes = true, shoe = true, headgear = true, helmet = true, cap = true,
    face = true, hair = true, hand = true, hands = true, accessories = true,
    accessory = true, attachment = true, attachments = true, decal = true,
    cloak = true, collar = true, wound = true, backpack = true, goggles = true,
}

local function outfit_family_key(item_name)
    local basename = string.lower(string.match(item_name or "", "([^/]+)$") or "")
    local tokens = {}

    for token in string.gmatch(basename, "[^_]+") do
        tokens[#tokens + 1] = token
    end

    if #tokens == 0 then
        return nil
    end

    if tokens[1] == "npc" or tokens[1] == "face" or tokens[1] == "hair" or tokens[1] == "base" then
        table.remove(tokens, 1)
    end

    if tokens[1] == "hair" and #tokens > 2 then
        table.remove(tokens, 1)
    end

    local component_index

    for i = 1, #tokens do
        if FAMILY_COMPONENT_TOKENS[tokens[i]] then
            component_index = i
            break
        end
    end

    if not component_index or component_index <= 1 then
        return nil
    end

    local family_tokens = {}

    for i = 1, component_index - 1 do
        local token = tokens[i]

        if not string.match(token, "^%d+$") then
            family_tokens[#family_tokens + 1] = token
        end
    end

    local key = table.concat(family_tokens, "_")

    return #key >= 3 and key or nil
end

-- Material helpers are installed after slot validation.

-- Catalog rows are cached; item instances are built on selection.
local function studio_item_catalog()
    if _studio_item_catalog then
        return _studio_item_catalog
    end

    local cache = item_cache()

    if not cache then
        return nil
    end

    local catalog = {
        all = {},
        units = nil,
        units_loaded = false,
        by_slot = {},
        families = {},
        family_items = {},
        materials = {},
        texture_slots = {},
        material_slots = {},
    }
    local family_lookup = {}
    local texture_slot_counts = {}
    local material_slot_counts = {}

    local function has_visual_base(item)
        if type(item.base_unit) == "string" and item.base_unit ~= "" then
            return true
        end

        for _, base_unit in pairs(type(item.breed_base_unit) == "table" and item.breed_base_unit or {}) do
            if type(base_unit) == "string" and base_unit ~= "" then
                return true
            end
        end

        return false
    end

    local function count_override_slots(values, field, counts)
        for _, value in pairs(type(values) == "table" and values or {}) do
            local slot = type(value) == "table" and value[field]

            if type(slot) == "string" and slot ~= "" and not string.find(slot, "/", 1, true) then
                counts[slot] = (counts[slot] or 0) + 1
            end
        end
    end

    for item_name, item in pairs(cache) do
        -- Raw units live only in the Units tab and custom overrides only in Assets.
        if item.npclook_raw_unit ~= true and item.npclook_custom_material ~= true then
            if EXTRA_SLOTS.is_material_override_item(item) then
                catalog.materials[#catalog.materials + 1] = {
                    name = item_name,
                    sub = EXTRA_SLOTS.material_override_summary(item),
                    material_override = true,
                }

                -- Custom textures and materials reuse the slot names authored by Fatshark.
                count_override_slots(item.texture_material_overrides, "texture_slot", texture_slot_counts)
                count_override_slots(item.texture_material_overrides, "material_slot", material_slot_counts)
                count_override_slots(item.material_overrides, "material_slot", material_slot_counts)
            end

            local slot_name, source_slot = target_slot_for_item(item)
            local authored_slot = first_slot(item)
            -- Wearable 3D pieces only: no emotes, poses, frames or other UI items.
            local catalog_item = (authored_slot ~= nil or item.base_unit ~= nil)
                and not util.item_is_2d(item, item_name)
                and not string.find(item_name, "/animations/", 1, true)
                and (slot_name ~= nil or has_visual_base(item))

            if catalog_item then
                local entry = {
                    name = item_name,
                    slot = slot_name,
                    source_slot = source_slot or authored_slot,
                }

                catalog.all[#catalog.all + 1] = entry

                if slot_name then
                    local slot_entries = catalog.by_slot[slot_name]

                    if not slot_entries then
                        slot_entries = {}
                        catalog.by_slot[slot_name] = slot_entries
                    end

                    slot_entries[#slot_entries + 1] = entry

                    local family_key = outfit_family_key(item_name)

                    if family_key then
                        local family = family_lookup[family_key]

                        if not family then
                            family = {
                                filter = family_key,
                                item_count = 0,
                                slots = {},
                                items = {},
                            }
                            family_lookup[family_key] = family
                        end

                        family.item_count = family.item_count + 1
                        family.slots[slot_name] = true
                        family.items[#family.items + 1] = item_name
                    end
                end
            end
        end
    end

    local function sort_entries(entries)
        table.sort(entries, function(a, b)
            return a.name < b.name
        end)
    end

    sort_entries(catalog.all)
    sort_entries(catalog.materials)

    local function sorted_slots(counts, destination)
        for slot in pairs(counts) do
            destination[#destination + 1] = slot
        end

        table.sort(destination, function(a, b)
            if counts[a] ~= counts[b] then
                return counts[a] > counts[b]
            end

            return a < b
        end)
    end

    sorted_slots(texture_slot_counts, catalog.texture_slots)
    sorted_slots(material_slot_counts, catalog.material_slots)

    for _, entries in pairs(catalog.by_slot) do
        sort_entries(entries)
    end

    for family_key, family in pairs(family_lookup) do
        local slot_count = 0

        for _ in pairs(family.slots) do
            slot_count = slot_count + 1
        end

        if slot_count >= 2 then
            table.sort(family.items)
            catalog.family_items[family_key] = family.items
            catalog.families[#catalog.families + 1] = {
                filter = family_key,
                item_count = family.item_count,
                slot_count = slot_count,
            }
        end
    end

    table.sort(catalog.families, function(a, b)
        if a.slot_count ~= b.slot_count then
            return a.slot_count > b.slot_count
        end

        if a.item_count ~= b.item_count then
            return a.item_count > b.item_count
        end

        return a.filter < b.filter
    end)

    _studio_item_catalog = catalog

    return catalog
end

local function valid_look_slot(slot_name)
    return LOOK_SLOTS[slot_name] and SLOT_CONFIG[slot_name] ~= nil
end

EXTRA_SLOTS.studio_extra_slot_page_size = 22

mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_materials").install(EXTRA_SLOTS, {
    item_cache = item_cache,
    ensure_item = CUSTOM_ASSETS.ensure_material_item,
    valid_look_slot = valid_look_slot,
    safe_unit_alive = util.safe_unit_alive,
})

MESHES.install({
    normalize_materials = EXTRA_SLOTS.normalize_materials,
    material_item_name = EXTRA_SLOTS.material_item_name,
    material_override_item = function(definitions, item_name)
        return EXTRA_SLOTS.material_override_item(definitions or item_cache() or {}, item_name)
    end,
})

do
    local material_api_ok, material_api_error = extra_slot_runtime.install_material_api(EXTRA_SLOTS)

    if not material_api_ok then
        error("Extra-slot material API installation failed: " .. tostring(material_api_error))
    end
end

local function item_pref_score(name)
    local lower_name = string.lower(name)
    local score = 0

    if string.find(lower_name, "hand_left", 1, true) or string.find(lower_name, "hand_right", 1, true) then
        score = score - 4
    end

    if string.find(lower_name, "_bare", 1, true) or string.find(lower_name, "_pickup", 1, true) then
        score = score - 2
    end

    return score
end

local function fixed_frame_values(ext)
    local fixed_t = tonumber(FixedFrame.get_latest_fixed_time()) or 0
    local step = ext and ext._fixed_time_step

    if not step or step <= 0 then
        step = 1 / 60
    end

    return math.floor(fixed_t / step), fixed_t
end

-- Generated items

-- Darktide: scripts/backend/master_items.lua
local GENERATED_ITEM_EMPTY_TABLE_FIELDS = {
    "hide_slots",
    "hide_slot_groups",
}

local GENERATED_ITEM_EMPTY_STRING_FIELDS = {}

local GENERATED_ITEM_FALSE_FIELDS = {
    "stabilize_neck",
}

local GENERATED_ITEM_ATTACHMENT_DEPTH_LIMIT = 24

local function shallow_copy(source)
    local copy = {}

    for key, value in pairs(source or {}) do
        copy[key] = value
    end

    return copy
end

local clone_attachment_tree

local function configure_generated_item(item, slot_name, item_definitions, cloned_items, depth, mask_state, suppress_parent_events)
    local authored_parent_slots = item.parent_slot_names
    local authored_hide_slots = item.hide_slots
    item.slots = slot_name and { slot_name } or {}

    for i = 1, #GENERATED_ITEM_EMPTY_TABLE_FIELDS do
        item[GENERATED_ITEM_EMPTY_TABLE_FIELDS[i]] = {}
    end

    item.parent_slot_names = type(authored_parent_slots) == "table"
        and shallow_copy(authored_parent_slots) or {}
    item.hide_slots = MASKS.filtered_hide_slots(authored_hide_slots, mask_state)

    for i = 1, #GENERATED_ITEM_EMPTY_STRING_FIELDS do
        item[GENERATED_ITEM_EMPTY_STRING_FIELDS[i]] = ""
    end

    for i = 1, #GENERATED_ITEM_FALSE_FIELDS do
        item[GENERATED_ITEM_FALSE_FIELDS[i]] = false
    end

    MASKS.configure_item(item, mask_state, slot_name ~= nil)
    item.voice_fx_preset = false

    if suppress_parent_events or item.npclook_raw_unit == true then
        item.event_in_parent_state_machine = false
    end

    if slot_name and slot_name ~= "slot_gear_material_override_decal" then
        local preserve_parent_material = extra_slot_runtime.is_parent_material_item(
            slot_name,
            item,
            authored_parent_slots
        )

        if not preserve_parent_material then
            item.material_override_apply_to_parent = false
        end
    end

    item.npclook_generated = true

    if item.npclook_raw_unit ~= true then
        item.is_ui_item_preview = true
    end

    local attachments = item.attachments
    local children = item.children

    if type(attachments) == "table" then
        item.attachments = clone_attachment_tree(attachments, item_definitions, cloned_items, depth + 1, mask_state, suppress_parent_events)
    end

    if type(children) == "table" then
        item.children = clone_attachment_tree(children, item_definitions, cloned_items, depth + 1, mask_state, suppress_parent_events)
    end
end

local function clone_attached_item(item_reference, item_definitions, cloned_items, depth, mask_state, suppress_parent_events)
    local source
    local item_name

    if type(item_reference) == "string" then
        item_name = item_reference
        source = rawget(item_definitions, item_name)
    elseif type(item_reference) == "table" then
        source = item_reference
        item_name = item_reference.name
    end

    if type(source) ~= "table" then
        return item_reference
    end

    local memo_key = item_name or source
    local existing = cloned_items[memo_key]

    if existing == false then
        error(string.format("Generated item attachment cycle at %s", tostring(item_name or "<inline>")))
    elseif existing then
        return existing
    end

    cloned_items[memo_key] = false
    local clone = shallow_copy(source)
    configure_generated_item(clone, nil, item_definitions, cloned_items, depth, mask_state, suppress_parent_events)
    cloned_items[memo_key] = clone

    return clone
end

clone_attachment_tree = function(tree, item_definitions, cloned_items, depth, mask_state, suppress_parent_events)
    if next(tree) == nil then
        return {}
    elseif depth > GENERATED_ITEM_ATTACHMENT_DEPTH_LIMIT then
        error(string.format("Generated item attachments exceed %d levels", GENERATED_ITEM_ATTACHMENT_DEPTH_LIMIT))
    end

    local clone = {}

    for key, value in pairs(tree) do
        if type(value) == "table" then
            local entry = shallow_copy(value)

            if value.item ~= nil then
                entry.item = clone_attached_item(value.item, item_definitions, cloned_items, depth, mask_state, suppress_parent_events)
            end

            if type(value.children) == "table" then
                entry.children = clone_attachment_tree(
                    value.children,
                    item_definitions,
                    cloned_items,
                    depth + 1,
                    mask_state,
                    suppress_parent_events
                )
            end

            clone[key] = entry
        else
            clone[key] = value
        end
    end

    return clone
end

local function item_package_dependencies(item, item_definitions, mission)
    local dependencies = {}
    local ok, err = pcall(
        ItemPackage.compile_item_instance_dependencies,
        item,
        item_definitions,
        dependencies,
        mission
    )

    if not ok then
        return nil, err
    end

    for package_name in pairs(dependencies) do
        if type(package_name) ~= "string" or package_name == "" then
            return nil, string.format("%s has an empty package reference", tostring(item and item.name or "item"))
        end
    end

    return dependencies
end

local GENERATED_VISUAL_OVERRIDE_FIELDS = {
    "hide_slots",
    "hide_slot_groups",
    "parent_slot_names",
    "mask_hair_item",
    "mask_facial_hair_item",
    "mask_hair_override",
    "mask_face_item",
    "mask_face_accessory_item",
    "hide_eyebrows",
    "hide_beard",
    "mask_torso_item",
    "mask_arms_item",
    "mask_legs_item",
    "material_override_apply_to_parent",
    "stabilize_neck",
    "voice_fx_preset",
    "event_in_parent_state_machine",
}

local function clone_generated_override_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}

    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy

    for key, child in pairs(value) do
        copy[key] = clone_generated_override_value(child, seen)
    end

    return copy
end

local function persist_generated_visual_overrides(item)
    local gear = type(item) == "table" and item.gear
    local master_data = type(gear) == "table" and gear.masterDataInstance

    if type(master_data) ~= "table" then
        return
    end

    local overrides = type(master_data.overrides) == "table"
        and shallow_copy(master_data.overrides) or {}

    for i = 1, #GENERATED_VISUAL_OVERRIDE_FIELDS do
        local field = GENERATED_VISUAL_OVERRIDE_FIELDS[i]
        local value = rawget(item, field)

        if value ~= nil then
            overrides[field] = clone_generated_override_value(value)
        end
    end

    master_data.overrides = overrides
end

local function make_item_instance(slot_name, item_name, material_overrides, variant_state, mask_state, opacity, mesh_state)
    local cache = item_cache()
    local master_item = item_definition(item_name)

    if not master_item then
        mod:error("missing item: %s", tostring(item_name))
        return nil
    elseif util.item_is_2d(master_item, item_name) then
        return nil
    end

    local item
    local preview_error

    if master_item.npclook_raw_unit == true then
        item = shallow_copy(master_item)
        item.npclook_raw_definition = nil
    else
        -- Some NPC items bypass the usual UI build path.
        local ok_ui, ui_item_or_error = pcall(MasterItems.get_ui_item_instance, master_item)

        if ok_ui then
            item = ui_item_or_error
        else
            preview_error = ui_item_or_error
        end
    end

    if not item then
        _counter = _counter + 1

        local gear = {
            masterDataInstance = { id = item_name },
        }
        local gear_id = string.format("npclook_%d_%s", _counter, slot_name)
        local ok_instance, protected_or_error = pcall(MasterItems.get_item_instance, gear, gear_id)

        if not ok_instance or not protected_or_error then
            mod:error("Could not create item instance for %s: %s", tostring(item_name), tostring(protected_or_error))
            return nil
        end

        local ok_preview, result = pcall(MasterItems.create_preview_item_instance, protected_or_error)

        if ok_preview then
            item = result
        else
            preview_error = result
        end
    end

    if not item then
        mod:error("Could not create mutable item for %s: %s", tostring(item_name), tostring(preview_error))
        return nil
    end

    item.npclook_source_item_name = item_name

    local available_masks = MASKS.available_fields(master_item, cache, slot_name)
    local normalized_masks = MASKS.normalize_state(mask_state, item_name, available_masks)
    local cloned_items = {}
    local root_item_name = item.name

    if root_item_name then
        cloned_items[root_item_name] = false
    end

    local configured, configure_error = pcall(
        configure_generated_item,
        item,
        slot_name,
        cache,
        cloned_items,
        0,
        normalized_masks,
        master_item.npclook_raw_unit == true
    )

    if not configured then
        mod:error("Could not configure generated item %s: %s", tostring(item_name), tostring(configure_error))
        return nil
    end

    MASKS.configure_effective_item(item, master_item, cache, slot_name, normalized_masks)
    persist_generated_visual_overrides(item)

    local normalized_variants = RAW_UNITS.normalize_variant_state(variant_state, item_name)
    item.npclook_raw_variant_state = normalized_variants
    item.npclook_raw_variant_signature = RAW_UNITS.variant_signature(normalized_variants)
    item.npclook_mask_state = normalized_masks
    item.npclook_mask_signature = MASKS.signature(normalized_masks)
    item.npclook_opacity = util.normalize_opacity(opacity)
    item.npclook_mesh_state = MESHES.normalize_state(mesh_state, item_name)
    item.npclook_mesh_signature = MESHES.signature(item.npclook_mesh_state)
    MESHES.add_package_dependencies(item, item.npclook_mesh_state, cache)

    local custom_materials = EXTRA_SLOTS.normalize_materials(material_overrides)

    if #custom_materials > 0 then
        local authored_overrides = type(item.material_override_items) == "table"
            and table.clone(item.material_override_items) or {}
        item.npclook_authored_material_overrides = authored_overrides
        item.npclook_custom_material_overrides = custom_materials
        item.material_override_items = table.clone(authored_overrides)

        for i = 1, #custom_materials do
            local override_name = EXTRA_SLOTS.material_item_name(custom_materials[i])

            if override_name then
                item.material_override_items[#item.material_override_items + 1] = override_name
            end
        end

        item.npclook_combined_material_overrides = item.material_override_items
        item.npclook_material_signature = table.concat(custom_materials, "\31")
    end

    local _, dependency_error = item_package_dependencies(item, cache, nil)

    if dependency_error then
        mod:error("Could not resolve generated item package dependencies: %s", tostring(dependency_error))
        return nil
    end

    return item
end

live_visual.signature_fields = {
    "name",
    "base_unit",
    "breed_base_unit",
    "attach_node",
    "wielded_attach_node",
    "unwielded_attach_node",
    "attachments",
    "children",
    "material_override_items",
    "material_override_apply_to_parent",
    "hide_slots",
    "hide_slot_groups",
    "parent_slot_names",
    "hide_eyebrows",
    "hide_beard",
    "stabilize_neck",
    "mask_facial_hair_item",
    "mask_hair_item",
    "mask_hair_override",
    "mask_torso_item",
    "mask_arms_item",
    "mask_legs_item",
    "mask_face_item",
    "mask_face_accessory_item",
    "deform_override_items",
    "npclook_raw_variant_signature",
    "npclook_mask_signature",
    "npclook_opacity",
    "npclook_mesh_signature",
}

live_visual.stable_value = function(value, depth, seen)
    local value_type = type(value)

    if value == nil then
        return "nil"
    elseif value_type == "string" then
        return "s:" .. value
    elseif value_type == "number" or value_type == "boolean" then
        return value_type .. ":" .. tostring(value)
    elseif value_type ~= "table" then
        return value_type .. ":" .. tostring(value)
    elseif depth > GENERATED_ITEM_ATTACHMENT_DEPTH_LIMIT then
        return "<depth>"
    elseif seen[value] then
        return "<cycle>"
    end

    seen[value] = true
    local keys = table.keys(value)

    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    local parts = {}

    for i = 1, #keys do
        local key = keys[i]
        parts[#parts + 1] = tostring(key) .. "=" .. live_visual.stable_value(value[key], depth + 1, seen)
    end

    seen[value] = nil

    return "{" .. table.concat(parts, ",") .. "}"
end

live_visual.item_signature = function(item)
    if not item then
        return "0"
    end

    local parts = {}

    for i = 1, #live_visual.signature_fields do
        local field = live_visual.signature_fields[i]
        parts[#parts + 1] = field .. "=" .. live_visual.stable_value(item[field], 0, {})
    end

    return table.concat(parts, "|")
end

local function visual_extension(player_unit)
    if not util.safe_unit_alive(player_unit) then
        return nil
    end

    return ScriptUnit.has_extension(player_unit, "visual_loadout_system")
end

local function schedule_reapply()
    local owner = live_visual.owners.current

    if owner ~= live_visual.owners.local_record then
        owner.reapply_pending = true
        return
    end

    if not next(_look_state.applied)
        and not next(_look_state.suppressed)
        and not next(_look_state.empty)
        and not next(_look_state.extra_anchors)
        and not next(_look_state.materials)
        and not next(_look_state.variants)
        and not next(_look_state.masks)
        and not next(_look_state.meshes)
        and not next(_look_state.opacity) then
        return
    end

    if not _reapply_pending then
        util.reset_retry(_reapply_retry)
        _reapply_pending = true
    end
end

mod.npclook_schedule_reapply = schedule_reapply

-- Generated items use the mod-managed package path.

-- Darktide: scripts/extension_systems/visual_loadout/equipment_component.lua
hook_method(EquipmentComponent, "_slot_is_loaded", function(func, self, slot)
    local item = slot and slot.item

    if item and item.npclook_generated == true then
        return true
    end

    return func(self, slot)
end)

-- Dependent visual slots can be nested below their top-level owner.
-- Darktide: scripts/utilities/profile_utils.lua
function EXTRA_SLOTS.find_visual_item_for_slot(visual_loadout, slot_name)
    if type(visual_loadout) ~= "table" or type(slot_name) ~= "string" then
        return nil
    end

    if type(visual_loadout[slot_name]) == "table" then
        return visual_loadout[slot_name], visual_loadout, slot_name,
            visual_loadout[slot_name], visual_loadout, slot_name
    end

    local seen_items = {}
    local seen_trees = {}
    local visit_item
    local visit_tree

    visit_tree = function(tree)
        if type(tree) ~= "table" or seen_trees[tree] then
            return nil
        end

        seen_trees[tree] = true

        -- Check direct children before descending into an unordered attachment tree.
        for key, attachment in pairs(tree) do
            if key == slot_name and type(attachment) == "table"
                and type(attachment.item) == "table" then
                return attachment.item, attachment, "item"
            end
        end

        for _, attachment in pairs(tree) do
            if type(attachment) == "table" then
                local item, owner, owner_key = visit_item(attachment.item)

                if item then
                    return item, owner, owner_key
                end

                item, owner, owner_key = visit_tree(attachment.children)

                if item then
                    return item, owner, owner_key
                end
            end
        end

        return nil
    end

    visit_item = function(item)
        if type(item) ~= "table" or seen_items[item] then
            return nil
        end

        seen_items[item] = true

        local found, owner, owner_key = visit_tree(item.attachments)

        if found then
            return found, owner, owner_key
        end

        return visit_tree(item.children)
    end

    for root_key, item in pairs(visual_loadout) do
        local found, owner, owner_key = visit_item(item)

        if found then
            return found, owner, owner_key, item, visual_loadout, root_key
        end
    end

    return nil
end

function EXTRA_SLOTS.copy_generated_material_metadata(source_item, visual_item)
    if type(source_item) ~= "table" or type(visual_item) ~= "table" then
        return visual_item
    end

    local expected_scope_count = #EXTRA_SLOTS.collect_generated_material_scopes(source_item)

    if expected_scope_count == 0 then
        return visual_item
    end

    local function copy_fields(source, target)
        if type(source.npclook_custom_material_overrides) ~= "table" then
            return 0
        end

        target.npclook_generated = source.npclook_generated == true
        target.npclook_authored_material_overrides = source.npclook_authored_material_overrides
        target.npclook_custom_material_overrides = source.npclook_custom_material_overrides
        target.npclook_combined_material_overrides = source.npclook_combined_material_overrides
        target.npclook_material_signature = source.npclook_material_signature
        target.material_override_items = source.npclook_combined_material_overrides
            or source.material_override_items

        return 1
    end

    local copied_item_pairs = {}
    local copied_tree_pairs = {}
    local copy_item

    local function pair_seen(lookup, source, target)
        local targets = lookup[source]

        if targets and targets[target] then
            return true
        end

        if not targets then
            targets = {}
            lookup[source] = targets
        end

        targets[target] = true

        return false
    end

    local function copy_tree(source_tree, target_tree)
        if type(source_tree) ~= "table" or type(target_tree) ~= "table"
            or pair_seen(copied_tree_pairs, source_tree, target_tree) then
            return 0
        end

        local copied = 0

        for key, source_attachment in pairs(source_tree) do
            local target_attachment = target_tree[key]

            if type(source_attachment) == "table" and type(target_attachment) == "table" then
                if type(source_attachment.item) == "table" and type(target_attachment.item) == "table" then
                    copied = copied + copy_item(source_attachment.item, target_attachment.item)
                end

                copied = copied + copy_tree(source_attachment.children, target_attachment.children)
            end
        end

        return copied
    end

    copy_item = function(source, target)
        if type(source) ~= "table" or type(target) ~= "table"
            or pair_seen(copied_item_pairs, source, target) then
            return 0
        end

        local copied = copy_fields(source, target)

        copied = copied + copy_tree(source.attachments, target.attachments)
        copied = copied + copy_tree(source.children, target.children)

        return copied
    end

    local ok_copy, copied = pcall(copy_item, source_item, visual_item)

    if ok_copy and copied >= expected_scope_count then
        return visual_item
    end

    local ok_instance, mutable_item = pcall(MasterItems.create_preview_item_instance, visual_item)

    if ok_instance and type(mutable_item) == "table" then
        copied_item_pairs = {}
        copied_tree_pairs = {}

        local ok_mutable, mutable_copied = pcall(copy_item, source_item, mutable_item)

        if ok_mutable and mutable_copied >= expected_scope_count then
            return mutable_item
        end
    end

    return visual_item
end

local GENERATED_VISUAL_STATE_FIELDS = {
    "is_ui_item_preview",
    "hide_slots",
    "hide_slot_groups",
    "parent_slot_names",
    "material_override_apply_to_parent",
    "stabilize_neck",
    "voice_fx_preset",
    "event_in_parent_state_machine",
    "npclook_source_item_name",
    "npclook_opacity",
    "npclook_mesh_state",
    "npclook_mesh_signature",
}

local function generated_visual_value(value)
    return type(value) == "table" and shallow_copy(value) or value
end

local function apply_generated_visual_state(source_item, visual_item)
    if type(source_item) ~= "table" or source_item.npclook_generated ~= true
        or type(visual_item) ~= "table" then
        return visual_item
    end

    for i = 1, #GENERATED_VISUAL_STATE_FIELDS do
        local field = GENERATED_VISUAL_STATE_FIELDS[i]

        rawset(visual_item, field, generated_visual_value(source_item[field]))
    end

    rawset(visual_item, "npclook_generated", true)

    return visual_item
end

local function apply_generated_mask_state(source_item, visual_item)
    local state = type(source_item) == "table" and source_item.npclook_mask_state

    if type(visual_item) ~= "table" or type(state) ~= "table" then
        return visual_item
    end

    MASKS.configure_item(visual_item, state, true)
    rawset(visual_item, "npclook_mask_state", state)
    rawset(visual_item, "npclook_mask_signature", source_item.npclook_mask_signature)

    return visual_item
end

function EXTRA_SLOTS.copy_generated_visual_tree_state(source_item, visual_item)
    local seen = {}
    local copy_item

    local function copy_tree(source_tree, visual_tree)
        if type(source_tree) ~= "table" or type(visual_tree) ~= "table" then
            return
        end

        for key, source_attachment in pairs(source_tree) do
            local visual_attachment = visual_tree[key]

            if type(source_attachment) == "table" and type(visual_attachment) == "table" then
                copy_item(source_attachment.item, visual_attachment.item)
                copy_tree(source_attachment.children, visual_attachment.children)
            end
        end
    end

    copy_item = function(source, visual)
        if type(source) ~= "table" or type(visual) ~= "table" then
            return
        end

        local visual_seen = seen[source]

        if visual_seen and visual_seen[visual] then
            return
        elseif not visual_seen then
            visual_seen = {}
            seen[source] = visual_seen
        end

        visual_seen[visual] = true

        for i = 1, #GENERATED_VISUAL_OVERRIDE_FIELDS do
            local field = GENERATED_VISUAL_OVERRIDE_FIELDS[i]
            local value = rawget(source, field)

            if value ~= nil then
                rawset(visual, field, clone_generated_override_value(value))
            end
        end

        apply_generated_visual_state(source, visual)
        apply_generated_mask_state(source, visual)
        copy_tree(source.attachments, visual.attachments)
        copy_tree(source.children, visual.children)
    end

    copy_item(source_item, visual_item)

    return visual_item
end

local function generated_visual_item(item)
    if type(item) ~= "table" or item.npclook_generated ~= true then
        return nil
    end

    local has_visual_base = type(item.base_unit) == "string" and item.base_unit ~= ""

    if not has_visual_base and type(item.breed_base_unit) == "table" then
        for _, base_unit in pairs(item.breed_base_unit) do
            if type(base_unit) == "string" and base_unit ~= "" then
                has_visual_base = true
                break
            end
        end
    end

    local gear = item.gear
    local master_data = type(gear) == "table" and gear.masterDataInstance
    local item_id = item.gear_id

    if not has_visual_base or type(master_data) ~= "table" or item_id == nil then
        return nil
    end

    return {
        item = item,
        gear = gear,
        item_id = item_id,
    }
end

-- Keep generated overrides intact while ProfileUtils assembles dependent slots.
hook_method(EXTRA_SLOTS.profile_utils, "generate_visual_item", function(func, item)
    return generated_visual_item(item) or func(item)
end)

live_visual.loadout_has_generated_items = function(loadout)
    for _, item in pairs(loadout) do
        if type(item) == "table" and item.npclook_generated == true then
            return true
        end
    end

    return false
end

-- Preserve generated metadata on the visual items produced by ProfileUtils.
hook_method(EXTRA_SLOTS.profile_utils, "generate_visual_loadout", function(func, loadout, ...)
    local visual_loadout = func(loadout, ...)

    -- Portraits and UI characters without a look skip the tree walk.
    if type(loadout) == "table" and type(visual_loadout) == "table"
        and live_visual.loadout_has_generated_items(loadout) then
        for slot_name, source_item in pairs(loadout) do
            local visual_item, owner, owner_key, visual_root, root_owner, root_key =
                EXTRA_SLOTS.find_visual_item_for_slot(visual_loadout, slot_name)

            if visual_item and owner and owner_key then
                local copied_item = EXTRA_SLOTS.copy_generated_material_metadata(
                    source_item,
                    visual_item
                )

                copied_item = apply_generated_visual_state(source_item, copied_item)
                copied_item = apply_generated_mask_state(source_item, copied_item)

                if type(source_item) == "table" and type(copied_item) == "table"
                    and source_item.npclook_raw_unit == true then
                    local variant_state = RAW_UNITS.normalize_variant_state(
                        source_item.npclook_raw_variant_state,
                        source_item.name
                    )
                    local ok_metadata = pcall(function()
                        copied_item.npclook_raw_variant_state = variant_state
                        copied_item.npclook_raw_variant_signature = source_item.npclook_raw_variant_signature
                    end)

                    if not ok_metadata then
                        local mutable_item = shallow_copy(copied_item)
                        mutable_item.npclook_raw_variant_state = variant_state
                        mutable_item.npclook_raw_variant_signature = source_item.npclook_raw_variant_signature
                        copied_item = mutable_item
                    end
                end

                owner[owner_key] = copied_item

                if visual_root ~= visual_item and visual_root and root_owner and root_key then
                    root_owner[root_key] = apply_generated_mask_state(source_item, visual_root)
                end
            end
        end
    end

    return visual_loadout
end)

live_visual.apply_slot_meshes = function(slot, item, item_definitions)
    local state = type(item) == "table" and item.npclook_mesh_state

    if state then
        MESHES.apply(MESHES.slot_scoped_units(slot, item.name), state, item_definitions or item_cache())
    end
end

function EXTRA_SLOTS.apply_custom_materials_to_slot(slot, item)
    return EXTRA_SLOTS.apply_generated_material_scopes_to_slot(
        slot,
        item,
        item_cache() or {},
        nil,
        "normal slot " .. tostring(slot and slot.name or item and item.name or "unknown")
    )
end

local function reset_slot_runtime_fields(slot)
    slot.equipped = false
    slot.item = nil
    slot.unit_3p = nil
    slot.unit_1p = nil
    slot.item_unit_3p = nil
    slot.item_unit_1p = nil
    slot.parent_unit_3p = nil
    slot.parent_unit_1p = nil
    slot.attachments_by_unit_3p = nil
    slot.attachments_by_unit_1p = nil
    slot.attachment_id_lookup_3p = nil
    slot.attachment_id_lookup_1p = nil
    slot.attachment_map_by_unit_3p = nil
    slot.attachment_map_by_unit_1p = nil
    slot.item_name_by_unit_3p = nil
    slot.item_name_by_unit_1p = nil
    slot.attachment_spawn_status = nil
    slot.item_loaded = nil
    slot.equipped_t = nil
    slot.deform_override_items = nil
    slot.breed_name = nil
    slot.owner_unit_3p = nil
    slot.hidden_3p = nil
    slot.hidden_1p = nil
    slot.cached_nodes = {}
end

local function clean_failed_slot(equipment_component, slot)
    if type(slot) ~= "table" then
        return
    end

    local spawned = {
        unit_3p = slot.unit_3p,
        unit_1p = slot.unit_1p,
        item_unit_3p = slot.item_unit_3p,
        item_unit_1p = slot.item_unit_1p,
        attachments_by_unit_3p = slot.attachments_by_unit_3p,
        attachments_by_unit_1p = slot.attachments_by_unit_1p,
        attachment_map_by_unit_3p = slot.attachment_map_by_unit_3p,
        attachment_map_by_unit_1p = slot.attachment_map_by_unit_1p,
    }

    if equipment_component and type(equipment_component.unequip_item) == "function"
        and slot.equipped and slot.item then
        pcall(equipment_component.unequip_item, equipment_component, slot)
    end

    pcall(
        extra_slot_runtime.destroy_equipment_slot,
        spawned,
        equipment_component and equipment_component._unit_spawner
    )

    reset_slot_runtime_fields(slot)
end

local function report_raw_spawn_failure(equipment_component, slot, item, err, loading)
    local unit_name = tostring(item and (item.base_unit or item.name) or "unknown")

    clean_failed_slot(equipment_component, slot)

    if loading then
        schedule_reapply()
        return
    end

    RAW_UNITS.force_overlay_spawn(item)
    _raw_overlay_retry_requested = true
    live_visual.plan = nil
    live_visual.plan_signature = nil
    schedule_reapply()

    if _studio_session and _studio_session.closing ~= true then
        _studio_session.preview_revision = (_studio_session.preview_revision or 0) + 1
        _studio_session.preview_cache = nil
    end

    if not _raw_unit_spawn_warnings[unit_name] then
        _raw_unit_spawn_warnings[unit_name] = true
        mod:info("Raw unit %s switched to the visual overlay path: %s", unit_name, tostring(err))
    end
end

local _generated_spawn_warnings = {}

local function report_generated_spawn_failure(equipment_component, slot, item, err)
    local slot_name = tostring(slot and slot.name or "unknown")
    local item_name = tostring(item and (item.name or item.npclook_source_item_name) or "unknown")
    local key = slot_name .. "\31" .. item_name
    local message = tostring(err or "no visual root unit was spawned")

    clean_failed_slot(equipment_component, slot)

    if _generated_spawn_warnings[key] ~= message then
        _generated_spawn_warnings[key] = message
        mod:warning(
            "Skipped generated item %s in %s because its visual root could not be spawned: %s",
            item_name,
            slot_name,
            message
        )
    end
end

local VisualLoadoutCustomization = EXTRA_SLOTS.visual_loadout_customization

local function destroy_named_actor(unit, actor_name)
    if not util.safe_unit_alive(unit) then
        return
    end

    local ok_actor, actor_id = pcall(Unit.find_actor, unit, actor_name)

    if ok_actor and actor_id then
        pcall(Unit.destroy_actor, unit, actor_id)
    end
end

local function apply_deform_overrides(slot_unit, parent_unit, overrides, item_definitions)
    if not util.safe_unit_alive(slot_unit) or type(overrides) ~= "table" then
        return
    end

    for _, override_item in pairs(overrides) do
        VisualLoadoutCustomization.apply_material_override_item(
            slot_unit,
            parent_unit,
            false,
            override_item,
            false,
            item_definitions
        )
    end
end

local function spawn_generated_player_item_units(
        self,
        slot,
        unit_3p,
        unit_1p,
        attach_settings,
        optional_mission_template,
        optional_equipment)
    local item = slot.item
    local skip_attachments = slot.item_loaded ~= true

    slot.attachment_spawn_status = skip_attachments and "waiting_for_load" or "fully_spawned"

    local missing_root

    if self:_should_spawn_3p(unit_3p, slot, item) then
        self:_fill_attach_settings_3p(unit_3p, attach_settings, slot)

        local item_unit_3p
        local attachment_units_3p
        local unit_attachment_id_3p
        local unit_attachment_name_3p
        local item_name_by_unit_3p
        local bind_pose_3p
        local attachment_bind_poses_3p

        if skip_attachments then
            item_unit_3p = VisualLoadoutCustomization.spawn_base_unit(
                item,
                attach_settings,
                unit_3p,
                optional_mission_template
            )
        else
            item_unit_3p,
                attachment_units_3p,
                bind_pose_3p,
                unit_attachment_id_3p,
                unit_attachment_name_3p,
                attachment_bind_poses_3p,
                item_name_by_unit_3p = VisualLoadoutCustomization.spawn_item(
                    item,
                    attach_settings,
                    unit_3p,
                    true,
                    false,
                    true,
                    optional_mission_template,
                    optional_equipment
                )
        end

        slot.unit_3p = item_unit_3p
        slot.attachments_by_unit_3p = attachment_units_3p
        slot.attachment_id_lookup_3p = unit_attachment_id_3p
        slot.attachment_map_by_unit_3p = unit_attachment_name_3p
        slot.item_name_by_unit_3p = item_name_by_unit_3p

        if util.safe_unit_alive(item_unit_3p) then
            destroy_named_actor(item_unit_3p, "dynamic")
            destroy_named_actor(item_unit_3p, "smart_tagging")

            if slot.hide_unit_in_slot then
                Unit.set_unit_visibility(item_unit_3p, false, true)
            end

            apply_deform_overrides(
                item_unit_3p,
                unit_3p,
                slot.deform_override_items,
                attach_settings.item_definitions
            )
        else
            missing_root = string.format(
                "3p spawn returned nil for base unit %s",
                tostring(util.item_base_unit(item, slot.breed_name) or "<none>")
            )
        end
    end

    if self:_should_spawn_1p(unit_1p, item, slot) then
        self:_fill_attach_settings_1p(unit_1p, attach_settings, slot)

        local item_unit_1p
        local attachments_by_unit_1p
        local unit_attachment_id_1p
        local unit_attachment_name_1p
        local item_name_by_unit_1p
        local bind_pose_1p
        local attachment_bind_poses_1p

        if skip_attachments then
            item_unit_1p = VisualLoadoutCustomization.spawn_base_unit(
                item,
                attach_settings,
                unit_1p,
                optional_mission_template
            )
        else
            item_unit_1p,
                attachments_by_unit_1p,
                bind_pose_1p,
                unit_attachment_id_1p,
                unit_attachment_name_1p,
                attachment_bind_poses_1p,
                item_name_by_unit_1p = VisualLoadoutCustomization.spawn_item(
                    item,
                    attach_settings,
                    unit_1p,
                    true,
                    false,
                    true,
                    optional_mission_template,
                    nil
                )
        end

        slot.unit_1p = item_unit_1p
        slot.attachments_by_unit_1p = attachments_by_unit_1p
        slot.attachment_id_lookup_1p = unit_attachment_id_1p
        slot.attachment_map_by_unit_1p = unit_attachment_name_1p
        slot.item_name_by_unit_1p = item_name_by_unit_1p

        if util.safe_unit_alive(item_unit_1p) then
            destroy_named_actor(item_unit_1p, "dynamic")
            destroy_named_actor(item_unit_1p, "smart_tagging")
            pcall(
                Unit.set_shader_pass_flag_for_meshes_in_unit_and_childs,
                unit_1p,
                "custom_fov",
                true
            )
            apply_deform_overrides(
                item_unit_1p,
                unit_1p,
                slot.deform_override_items,
                attach_settings.item_definitions
            )
        else
            slot.unit_1p = nil
            slot.attachments_by_unit_1p = nil
            slot.attachment_id_lookup_1p = nil
            slot.attachment_map_by_unit_1p = nil
            slot.item_name_by_unit_1p = nil
        end
    end

    return missing_root == nil, missing_root
end

hook_method(EquipmentComponent, "_spawn_player_item_units", function(
        func,
        self,
        slot,
        unit_3p,
        unit_1p,
        attach_settings,
        optional_mission_template,
        optional_equipment)
    local item = slot and slot.item

    if not item or item.npclook_generated ~= true then
        return func(
            self,
            slot,
            unit_3p,
            unit_1p,
            attach_settings,
            optional_mission_template,
            optional_equipment
        )
    end

    if item.npclook_raw_unit ~= true
        and util.item_base_unit(item, slot and slot.breed_name) == nil
        and item.base_unit_1p == nil then
        clean_failed_slot(self, slot)
        return
    end

    if item.npclook_raw_unit == true then
        local package_ready = slot and slot.item_loaded == true
            or RAW_UNITS.package_ready(item, Managers.package)
        local ready, raw_error, loading = RAW_UNITS.ensure_ready(
            item,
            package_ready,
            Managers.package
        )

        if not ready then
            report_raw_spawn_failure(self, slot, item, raw_error, loading)
            return
        end

        _raw_unit_spawn_warnings[tostring(item.base_unit or item.name or "unknown")] = nil
    end

    local material_scopes = EXTRA_SLOTS.collect_generated_material_scopes(item)

    if #material_scopes > 0 then
        EXTRA_SLOTS.set_generated_material_scope_lists(material_scopes, false)
    end

    local ok_spawn, spawned, spawn_error = pcall(
        spawn_generated_player_item_units,
        self,
        slot,
        unit_3p,
        unit_1p,
        attach_settings,
        optional_mission_template,
        optional_equipment
    )

    if #material_scopes > 0 then
        EXTRA_SLOTS.set_generated_material_scope_lists(material_scopes, true)
    end

    if not ok_spawn or not spawned then
        local err = ok_spawn and spawn_error or spawned

        if item.npclook_raw_unit == true then
            report_raw_spawn_failure(self, slot, item, err, false)
        else
            report_generated_spawn_failure(self, slot, item, err)
        end

        return
    end

    _generated_spawn_warnings[
        tostring(slot and slot.name or "unknown")
            .. "\31" .. tostring(item.name or item.npclook_source_item_name or "unknown")
    ] = nil

    if item.npclook_raw_unit == true then
        pcall(extra_slot_runtime.neutralize_equipment_slot, slot, item, self._unit_spawner)
        pcall(RAW_UNITS.apply_variants_to_slot, slot, item)
    end

    if #material_scopes > 0 then
        EXTRA_SLOTS.apply_custom_materials_to_slot(slot, item)
    end

    util.apply_opacity_to_units(live_visual.capture_slot_units(slot), item.npclook_opacity)
    live_visual.apply_slot_meshes(slot, item, attach_settings and attach_settings.item_definitions)
end)

-- Prediction packages

local prediction = {
    direct_unloads = setmetatable({}, { __mode = "k" }),
    slot_records = setmetatable({}, { __mode = "k" }),
}

function prediction.item_queue(storage, handler, item, create)
    local item_queues = storage[handler]

    if not item_queues and create then
        item_queues = setmetatable({}, { __mode = "k" })
        storage[handler] = item_queues
    end

    local queue = item_queues and item_queues[item]

    if not queue and create then
        queue = {}
        item_queues[item] = queue
    end

    return queue, item_queues
end

function prediction.queue(storage, handler, item, value)
    if not handler or not item or not value then
        return
    end

    local queue = prediction.item_queue(storage, handler, item, true)

    queue[#queue + 1] = value
end

function prediction.take(storage, handler, item)
    local queue, item_queues = prediction.item_queue(storage, handler, item, false)

    if not queue or #queue == 0 then
        return nil
    end

    local value = table.remove(queue, 1)

    if #queue == 0 then
        item_queues[item] = nil
    end

    if next(item_queues) == nil then
        storage[handler] = nil
    end

    return value
end

function prediction.package_names(handler, item)
    local dependencies, dependency_error = item_package_dependencies(
        item,
        handler and handler._item_definitions,
        handler and handler._mission
    )

    if not dependencies then
        return nil, dependency_error
    end

    local package_names = table.keys(dependencies)

    table.sort(package_names)

    return package_names
end

function prediction.begin_capture(handler, item)
    local package_names = prediction.package_names(handler, item)

    if not package_names then
        return nil
    end

    local loaded_by_package = handler and handler._loaded_packages
    local before = {}

    for i = 1, #package_names do
        local package_name = package_names[i]
        local loaded_packages = loaded_by_package and loaded_by_package[package_name]

        before[package_name] = type(loaded_packages) == "table" and #loaded_packages or 0
    end

    return {
        before = before,
        item_name = item.name,
        package_manager = Managers.package,
        package_names = package_names,
    }
end

function prediction.finish_capture(handler, context)
    if not context then
        return nil
    end

    local loaded_by_package = handler and handler._loaded_packages
    local record = {
        item_name = context.item_name,
        package_manager = context.package_manager,
        packages = {},
    }

    for i = 1, #context.package_names do
        local package_name = context.package_names[i]
        local loaded_packages = loaded_by_package and loaded_by_package[package_name]
        local first_new_index = context.before[package_name] + 1

        if type(loaded_packages) ~= "table" or first_new_index > #loaded_packages then
            return nil
        end

        for load_index = first_new_index, #loaded_packages do
            record.packages[#record.packages + 1] = {
                load_id = loaded_packages[load_index],
                package_name = package_name,
            }
        end
    end

    return record
end

function prediction.records(handler, create)
    local records = prediction.slot_records[handler]

    if not records and create then
        records = {}
        prediction.slot_records[handler] = records
    end

    return records
end

function prediction.set_slot_record(handler, slot_name, record)
    if not handler or not slot_name then
        return
    end

    local records = prediction.records(handler, true)

    records[slot_name] = record
end

function prediction.clear_handler(handler)
    if handler then
        prediction.slot_records[handler] = nil
    end
end

function prediction.claim_record_load_ids(claimed, record)
    for i = 1, #(record and record.packages or {}) do
        claimed[record.packages[i].load_id] = true
    end
end

function prediction.claimed_load_ids(handler, records)
    local claimed = {}

    for _, record in pairs(records or {}) do
        prediction.claim_record_load_ids(claimed, record)
    end

    local item_queues = prediction.direct_unloads[handler]

    for _, queue in pairs(item_queues or {}) do
        for i = 1, #queue do
            prediction.claim_record_load_ids(claimed, queue[i].record)
        end
    end

    return claimed
end

function prediction.record_is_live(handler, record)
    local loaded_by_package = handler and handler._loaded_packages

    if type(loaded_by_package) ~= "table" or type(record) ~= "table" then
        return false
    end

    for i = 1, #(record.packages or {}) do
        local package = record.packages[i]
        local load_ids = loaded_by_package[package.package_name]
        local found = false

        for load_index = 1, #(load_ids or {}) do
            if load_ids[load_index] == package.load_id then
                found = true
                break
            end
        end

        if not found then
            return false
        end
    end

    return true
end

function prediction.bootstrap(ext)
    local handler = ext and ext._mispredict_package_handler
    local equipment = ext and ext._equipment
    local slot_configuration = ext and ext._slot_configuration
    local loaded_by_package = handler and handler._loaded_packages

    if type(equipment) ~= "table" or type(slot_configuration) ~= "table"
        or type(loaded_by_package) ~= "table" then
        return
    end

    local records = prediction.records(handler, true)

    for slot_name, record in pairs(records) do
        local slot = equipment[slot_name]
        local item = slot and slot.equipped and slot.item

        if not item or record.item_name ~= item.name
            or not prediction.record_is_live(handler, record) then
            records[slot_name] = nil
        end
    end

    local claimed = prediction.claimed_load_ids(handler, records)
    local available = {}

    for package_name, load_ids in pairs(loaded_by_package) do
        if type(load_ids) == "table" then
            local unclaimed = {}

            for i = 1, #load_ids do
                if not claimed[load_ids[i]] then
                    unclaimed[#unclaimed + 1] = load_ids[i]
                end
            end

            available[package_name] = unclaimed
        end
    end

    local cursors = {}
    local equip_order = PlayerCharacterConstants.slot_equip_order

    for i = 1, #equip_order do
        local slot_name = equip_order[i]
        local slot = equipment[slot_name]
        local item = slot and slot.equipped and slot.item
        local config = slot_configuration[slot_name]
        local current = records[slot_name]

        if not current and item and item.npclook_generated ~= true
            and config and config.mispredict_packages then
            local package_names = prediction.package_names(handler, item)
            local packages = {}
            local next_cursors = {}
            local complete = package_names ~= nil

            for package_index = 1, #(package_names or {}) do
                local package_name = package_names[package_index]
                local cursor = (cursors[package_name] or 0) + 1
                local load_id = available[package_name] and available[package_name][cursor]

                if load_id == nil then
                    complete = false
                    break
                end

                next_cursors[package_name] = cursor
                packages[#packages + 1] = {
                    load_id = load_id,
                    package_name = package_name,
                }
            end

            if complete then
                for package_name, cursor in pairs(next_cursors) do
                    cursors[package_name] = cursor
                end

                records[slot_name] = {
                    item_name = item.name,
                    package_manager = Managers.package,
                    packages = packages,
                }
            end
        end
    end
end

function prediction.pending_count(handler, item)
    local pending_unloads = handler and handler._pending_unloads
    local count = 0

    for _, items in pairs(pending_unloads or {}) do
        for i = 1, #items do
            if rawequal(items[i], item) then
                count = count + 1
            end
        end
    end

    return count
end

function prediction.prepare_direct_unload(ext, slot_name, item)
    if not item or item.npclook_generated == true then
        return nil
    end

    local handler = ext and ext._mispredict_package_handler
    local slot_configuration = ext and ext._slot_configuration
    local slot_config = slot_configuration and slot_configuration[slot_name]

    if not handler or not slot_config or not slot_config.mispredict_packages then
        return nil
    end

    local records = prediction.records(handler, false)
    local record = records and records[slot_name]

    if not record or record.item_name ~= item.name
        or not prediction.record_is_live(handler, record) then
        prediction.bootstrap(ext)
        records = prediction.records(handler, false)
        record = records and records[slot_name]
    end

    return {
        handler = handler,
        item = item,
        item_name = item.name,
        record = record,
        slot_name = slot_name,
    }
end

function prediction.commit_direct_unload(marker)
    if not marker then
        return
    end

    local records = prediction.records(marker.handler, false)

    if records then
        records[marker.slot_name] = nil
    end

    prediction.queue(prediction.direct_unloads, marker.handler, marker.item, marker)
end

function prediction.release_record(handler, record)
    local loaded_by_package = handler and handler._loaded_packages
    local package_manager = record and (record.package_manager or Managers.package)

    if type(loaded_by_package) ~= "table" or not package_manager then
        return
    end

    for i = 1, #(record.packages or {}) do
        local package = record.packages[i]
        local loaded_packages = loaded_by_package[package.package_name]
        local found_index

        if type(loaded_packages) == "table" then
            for load_index = #loaded_packages, 1, -1 do
                if loaded_packages[load_index] == package.load_id then
                    found_index = load_index
                    break
                end
            end
        end

        if found_index then
            table.remove(loaded_packages, found_index)
            pcall(package_manager.release, package_manager, package.load_id)

            if table.is_empty(loaded_packages) then
                loaded_by_package[package.package_name] = nil
            end
        end
    end
end

function prediction.final_unload_item(handler, item)
    if type(item) ~= "table" then
        return item
    end

    local dependencies = item_package_dependencies(
        item,
        handler and handler._item_definitions,
        handler and handler._mission
    )
    local loaded_by_package = handler and handler._loaded_packages

    if type(dependencies) ~= "table" or type(loaded_by_package) ~= "table" then
        return item
    end

    local filtered_dependencies = {}
    local filtered = false

    for package_name in pairs(dependencies) do
        local loaded_packages = loaded_by_package[package_name]

        if type(loaded_packages) == "table" and #loaded_packages > 0 then
            filtered_dependencies[package_name] = true
        else
            filtered = true
        end
    end

    if not filtered then
        return item
    end

    -- Darktide's delayed unload assumes every compiled dependency has a matching load stack.
    -- Preserve every valid native release, but omit only absent stacks before vanilla indexes them.
    -- The proxy deliberately has no name or attachment data, so the dependency compiler cannot
    -- rebuild the missing master-item dependency set.
    return {
        resource_dependencies = filtered_dependencies,
    }
end

-- Darktide: scripts/extension_systems/visual_loadout/mispredict_package_handler.lua
hook_method(MispredictPackageHandler, "item_equipped", function(func, self, item)
    if item and item.npclook_generated == true then
        return
    end

    return func(self, item)
end)

-- Darktide: scripts/extension_systems/visual_loadout/mispredict_package_handler.lua
hook_method(MispredictPackageHandler, "item_unequipped", function(func, self, item, fixed_frame)
    if item and item.npclook_generated == true then
        return
    end

    return func(self, item, fixed_frame)
end)

-- Darktide: scripts/extension_systems/visual_loadout/mispredict_package_handler.lua
hook_method(MispredictPackageHandler, "_unload_item_packages", function(func, self, item)
    if item and item.npclook_generated == true then
        return
    end

    local marker = prediction.take(prediction.direct_unloads, self, item)

    if marker then
        prediction.release_record(self, marker.record)
        return
    end

    return func(self, prediction.final_unload_item(self, item))
end)

local LIVE_PACKAGE_RELEASE_DELAY = 2

-- A live package record owns every visual unit created while that record is active.
-- Its release delay starts only after those exact units have been destroyed.
live_visual.track_package_units = function(record, units, unit_spawner)
    if type(record) ~= "table" or type(units) ~= "table" then
        return
    end

    local tracked_units = record.tracked_units
    local tracked_lookup = record.tracked_unit_lookup

    if type(tracked_units) ~= "table" then
        tracked_units = {}
        record.tracked_units = tracked_units
    end

    if type(tracked_lookup) ~= "table" then
        tracked_lookup = {}
        record.tracked_unit_lookup = tracked_lookup
    end

    for i = 1, #units do
        local unit = units[i]

        if unit and not tracked_lookup[unit] then
            tracked_lookup[unit] = true
            tracked_units[#tracked_units + 1] = unit
        end
    end

    if unit_spawner then
        record.unit_spawner = unit_spawner
    end
end

live_visual.package_units_destroyed = function(record)
    local tracked_units = record and record.tracked_units

    if type(tracked_units) ~= "table" or #tracked_units == 0 then
        return true
    end

    local tracked_lookup = record.tracked_unit_lookup

    for i = #tracked_units, 1, -1 do
        local unit = tracked_units[i]

        if not util.safe_unit_alive(unit) then
            if type(tracked_lookup) == "table" then
                tracked_lookup[unit] = nil
            end

            table.remove(tracked_units, i)
        end
    end

    return #tracked_units == 0
end

live_visual.clear_package_unit_tracking = function(record)
    if type(record) ~= "table" then
        return
    end

    if type(record.tracked_units) == "table" then
        table.clear(record.tracked_units)
    end

    if type(record.tracked_unit_lookup) == "table" then
        table.clear(record.tracked_unit_lookup)
    end

    record.unit_spawner = nil
end

live_visual.transfer_package_units = function(source, destination)
    if type(source) ~= "table" or type(destination) ~= "table" then
        return
    end

    live_visual.track_package_units(destination, source.tracked_units or {}, source.unit_spawner)
    live_visual.clear_package_unit_tracking(source)
end

local function retained_live_raw_package_entries(package_manager)
    local cache = _retained_live_raw_package_cache

    if cache.package_manager ~= package_manager then
        -- The old PackageManager owns retained raw packages.
        cache.package_manager = package_manager
        cache.entries = {}
    end

    return cache.entries
end

local function refresh_live_package_record(record)
    if not record then
        return false
    end

    if type(record.package_entries) == "table" then
        for i = 1, #(record.package_names or {}) do
            local entry = record.package_entries[i]

            if not entry or entry.ready ~= true then
                record.ready = false
                record.waiting_package = record.package_names[i]
                return false
            end
        end

        record.ready = true
        record.waiting_package = nil
        return true
    end

    if record.loading_complete ~= true then
        record.ready = false
        return false
    end

    for i = 1, #(record.load_ids or {}) do
        local load_id = record.load_ids[i]

        if not record.loaded_ids[load_id] then
            record.ready = false
            record.waiting_package = record.package_names[i]
            return false
        end
    end

    record.ready = true
    record.waiting_package = nil
    return true
end

local function release_live_package_record(record)
    if not record or record.released == true then
        return true
    end

    if type(record.package_entries) == "table" then
        local seen = {}

        for i = 1, #record.package_entries do
            local entry = record.package_entries[i]

            if type(entry) == "table" and not seen[entry] then
                seen[entry] = true
                entry.references = math.max((tonumber(entry.references) or 1) - 1, 0)
            end
        end

        table.clear(record.package_entries)
        live_visual.clear_package_unit_tracking(record)
        record.released = true
        record.release_queued = nil
        return true
    elseif type(record.load_ids) ~= "table" then
        live_visual.clear_package_unit_tracking(record)
        record.released = true
        record.release_queued = nil
        return true
    end

    -- Shared raw packages stay with their PackageManager.
    if record.persistent == true then
        table.clear(record.load_ids)
        table.clear(record.loaded_ids or {})
        live_visual.clear_package_unit_tracking(record)
        record.released = true
        record.release_queued = nil
        return true
    end

    local package_manager = record.package_manager

    if not package_manager then
        table.clear(record.load_ids)
        live_visual.clear_package_unit_tracking(record)
        record.released = true
        record.release_queued = nil
        return true
    elseif package_manager._shutdown_has_started == true then
        if package_manager ~= Managers.package then
            table.clear(record.load_ids)
            live_visual.clear_package_unit_tracking(record)
            record.released = true
            record.release_queued = nil
            return true
        end

        return false
    end

    local release = package_manager.release

    if type(release) ~= "function" then
        if package_manager ~= Managers.package then
            table.clear(record.load_ids)
            live_visual.clear_package_unit_tracking(record)
            record.released = true
            record.release_queued = nil
            return true
        end

        return false
    end

    for i = #record.load_ids, 1, -1 do
        local load_id = record.load_ids[i]
        local ok, err = pcall(release, package_manager, load_id)

        if ok then
            table.remove(record.load_ids, i)
        else
            util.report_once(record, "release_error", err, function(message)
                mod:warning("Could not release a retired cosmetic package reference: %s", message)
            end)

            if package_manager ~= Managers.package then
                table.remove(record.load_ids, i)
            end
        end
    end

    local released = #record.load_ids == 0

    if released then
        live_visual.clear_package_unit_tracking(record)
        record.released = true
        record.release_queued = nil
    end

    return released
end

local function queue_live_package_release(record, delay)
    if not record or record.released == true then
        return
    end

    local release_delay = delay == nil and LIVE_PACKAGE_RELEASE_DELAY or math.max(tonumber(delay) or 0, 0)

    if record.raw_unit then
        release_delay = math.max(release_delay, LIVE_PACKAGE_RELEASE_DELAY)
    end

    record.cancelled = true
    record.release_delay = math.max(tonumber(record.release_delay) or 0, release_delay)

    if record.release_queued == true then
        return
    end

    record.release_queued = true
    _retired_live_package_loads[#_retired_live_package_loads + 1] = record
end

local function retire_live_slot_packages(slot_name, delay)
    local record = _live_package_loads[slot_name]

    if record then
        _live_package_loads[slot_name] = nil
        queue_live_package_release(record, delay)
    end

    local pending_record = _pending_live_package_loads[slot_name]

    if pending_record then
        _pending_live_package_loads[slot_name] = nil
        queue_live_package_release(pending_record, delay)
    end
end

local function retire_all_live_slot_packages(delay)
    local slots = {}

    for slot_name in pairs(_live_package_loads) do
        slots[slot_name] = true
    end

    for slot_name in pairs(_pending_live_package_loads) do
        slots[slot_name] = true
    end

    local slot_names = table.keys(slots)

    for i = 1, #slot_names do
        retire_live_slot_packages(slot_names[i], delay)
    end
end

-- Count this delay on gameplay time with the rest of teardown.
local function live_package_gameplay_delta()
    local time_manager = gameplay_time_manager()

    if not time_manager then
        _live_package_gameplay_t = nil
        return 0
    end

    local gameplay_t = time_manager:time("gameplay")

    if type(gameplay_t) ~= "number" then
        _live_package_gameplay_t = nil
        return 0
    end

    local previous_t = _live_package_gameplay_t
    _live_package_gameplay_t = gameplay_t

    if not previous_t or gameplay_t < previous_t then
        return 0
    end

    return gameplay_t - previous_t
end

local function update_live_package_releases()
    if #_retired_live_package_loads == 0 then
        _live_package_gameplay_t = nil
        return
    end

    local release_dt = live_package_gameplay_delta()

    for i = #_retired_live_package_loads, 1, -1 do
        local record = _retired_live_package_loads[i]
        local teardown_complete = record.persistent == true or live_visual.package_units_destroyed(record)

        if teardown_complete then
            record.release_delay = math.max((record.release_delay or 0) - release_dt, 0)

            if record.release_delay == 0 and release_live_package_record(record) then
                table.remove(_retired_live_package_loads, i)
            end
        end
    end
end

local function release_all_live_package_records()
    retire_all_live_slot_packages(0)

    for i = #_retired_live_package_loads, 1, -1 do
        local record = _retired_live_package_loads[i]

        if record.raw_unit or record.package_manager == Managers.package then
            -- Hot teardown cannot wait for engine resource references to drain.
            -- Keep the reference until PackageManager itself is destroyed.
            record.persistent = true
        end

        release_live_package_record(record)
        table.remove(_retired_live_package_loads, i)
    end

    _live_package_gameplay_t = nil
end

local function live_package_entry_has_reference(entry)
    if type(entry) ~= "table" then
        return false
    elseif entry.resource_loader_ticket then
        local status = RAW_UNITS.ticket_status(entry.resource_loader_ticket)
        return status == "pending" or status == "loaded"
    end

    return entry.load_id ~= nil
end

local function acquire_live_item_packages(ext, slot_name, item, visual_signature)
    local package_manager = Managers.package
    local load = package_manager and package_manager.load

    if type(load) ~= "function" then
        return nil, loc("error_live_package_manager")
    end

    local item_name = item and item.name
    local pending_record = _pending_live_package_loads[slot_name]

    if pending_record
        and (pending_record.package_manager ~= package_manager
            or pending_record.item_name ~= item_name
            or pending_record.visual_signature ~= visual_signature) then
        _pending_live_package_loads[slot_name] = nil
        queue_live_package_release(pending_record, 0)
        pending_record = nil
    end

    if pending_record then
        refresh_live_package_record(pending_record)

        if pending_record.ready then
            _pending_live_package_loads[slot_name] = nil

            if item and item.npclook_raw_unit == true then
                RAW_UNITS.mark_package_ready(item, package_manager)
            end

            return pending_record
        end

        return nil, loc("error_live_package_not_ready", tostring(pending_record.waiting_package)), true
    end

    local item_definitions = ext and ext._item_definitions or item_cache()
    local mission = ext and ext._mission
    local dependencies, dependency_error = item_package_dependencies(item, item_definitions, mission)

    if not dependencies then
        return nil, loc("error_package_dependencies", tostring(dependency_error))
    end

    local package_names = table.keys(dependencies)
    table.sort(package_names)

    _live_package_counter = _live_package_counter + 1

    local persistent = item and item.npclook_raw_unit == true
        and item.npclook_raw_retain_package ~= false
    local record = {
        item_name = item_name,
        loaded_ids = {},
        load_ids = {},
        package_names = package_names,
        package_manager = package_manager,
        visual_signature = visual_signature,
        persistent = persistent,
        ready = #package_names == 0,
        waiting_package = package_names[1],
        loading_complete = #package_names == 0,
        cancelled = false,
        raw_unit = item and item.npclook_raw_unit == true,
    }
    local reference_name = string.format("NPCLookLiveSlot_%s_%d", tostring(slot_name), _live_package_counter)

    if persistent then
        local retained_entries = retained_live_raw_package_entries(package_manager)
        record.package_entries = {}

        for i = 1, #package_names do
            local package_name = package_names[i]
            local package_entry = retained_entries[package_name]

            if type(package_entry) ~= "table"
                or package_entry.package_manager ~= package_manager
                or package_entry.package_name ~= package_name
                or not live_package_entry_has_reference(package_entry) then
                retained_entries[package_name] = nil
                package_entry = nil
            end

            if not package_entry then
                package_entry = {
                    package_manager = package_manager,
                    package_name = package_name,
                    load_id = nil,
                    ready = false,
                    references = 0,
                    persistent = true,
                }
                retained_entries[package_name] = package_entry

                local function package_loaded(ticket, _, load_error)
                    if retained_live_raw_package_entries(package_manager)[package_name] ~= package_entry then
                        if ticket then
                            RAW_UNITS.release_ticket(ticket)
                        end
                        return
                    elseif load_error then
                        package_entry.error = tostring(load_error)
                        return
                    end

                    package_entry.resource_loader_ticket = ticket
                    package_entry.ready = true

                    if type(mod.npclook_schedule_reapply) == "function" then
                        mod.npclook_schedule_reapply()
                    else
                        schedule_reapply()
                    end

                    -- Retained packages are shared by every owner.
                    for _, owner in pairs(live_visual.owners.by_player) do
                        owner.reapply_pending = true
                    end
                end

                local ticket, load_error = RAW_UNITS.acquire_package(
                    package_name,
                    package_loaded,
                    {
                        prioritize = true,
                        reference_name = reference_name,
                    }
                )

                if not ticket then
                    if retained_entries[package_name] == package_entry then
                        retained_entries[package_name] = nil
                    end

                    release_live_package_record(record)
                    return nil, loc(
                        "error_live_package_acquire",
                        tostring(package_name),
                        tostring(load_error or loc("generic_unknown_error"))
                    )
                end

                package_entry.resource_loader_ticket = ticket
                package_entry.ready = RAW_UNITS.ticket_status(ticket) == "loaded"
            end

            package_entry.references = (tonumber(package_entry.references) or 0) + 1
            record.package_entries[i] = package_entry
        end

        refresh_live_package_record(record)
    else
        -- Callbacks fire outside the owner scope that started the load.
        local pending_loads = _pending_live_package_loads
        local owner = live_visual.owners.current

        local function package_loaded(load_id)
            if record.cancelled or record.loaded_ids[load_id] then
                return
            end

            record.loaded_ids[load_id] = true

            if record.loading_complete then
                local became_ready = refresh_live_package_record(record)

                if became_ready and pending_loads[slot_name] == record then
                    if owner == live_visual.owners.local_record then
                        schedule_reapply()
                    else
                        owner.reapply_pending = true
                    end
                end
            end
        end

        for i = 1, #package_names do
            local package_name = package_names[i]
            local ok_load, load_id = pcall(load, package_manager, package_name, reference_name, package_loaded, true)

            if not ok_load or not load_id then
                record.cancelled = true

                if not release_live_package_record(record) then
                    queue_live_package_release(record, 0)
                end

                return nil, loc("error_live_package_acquire", tostring(package_name), tostring(load_id))
            end

            record.load_ids[#record.load_ids + 1] = load_id
        end

        record.loading_complete = true
        refresh_live_package_record(record)
    end

    if record.ready then
        if persistent then
            RAW_UNITS.mark_package_ready(item, package_manager)
        end

        return record
    end

    _pending_live_package_loads[slot_name] = record

    return nil, loc("error_live_package_not_ready", tostring(record.waiting_package)), true
end

live_visual.capture_slot_units = function(slot)
    if not slot then
        return {}
    end

    local seen = {}
    local ordered = {}
    local protected = {}
    local attachment_maps = {
        slot.attachments_by_unit_3p or {},
        slot.attachments_by_unit_1p or {},
    }

    if slot.parent_unit_3p then
        protected[slot.parent_unit_3p] = true
    end

    if slot.parent_unit_1p then
        protected[slot.parent_unit_1p] = true
    end

    if slot.owner_unit_3p then
        protected[slot.owner_unit_3p] = true
    end

    if slot.use_existing_unit_3p and slot.unit_3p then
        protected[slot.unit_3p] = true
    end

    local function mapped_children(unit)
        local children = {}

        for i = 1, #attachment_maps do
            local mapped = attachment_maps[i][unit]

            if type(mapped) == "table" then
                for _, child in pairs(mapped) do
                    children[#children + 1] = child
                end
            end
        end

        return children
    end

    local function visit(unit)
        if not unit or protected[unit] or seen[unit] then
            return
        end

        seen[unit] = true

        for _, child in pairs(mapped_children(unit)) do
            if child ~= unit then
                visit(child)
            end
        end

        local ok_children, child_units = false, nil

        if util.safe_unit_alive(unit) then
            ok_children, child_units = pcall(Unit.get_child_units, unit)
        end

        if ok_children and type(child_units) == "table" then
            for _, child in pairs(child_units) do
                if child ~= unit then
                    visit(child)
                end
            end
        end

        ordered[#ordered + 1] = unit
    end

    if not slot.use_existing_unit_3p then
        visit(slot.unit_3p)
    end

    visit(slot.unit_1p)

    for i = 1, #attachment_maps do
        for parent, children in pairs(attachment_maps[i]) do
            visit(parent)

            if type(children) == "table" then
                for _, child in pairs(children) do
                    visit(child)
                end
            end
        end
    end

    return ordered
end

live_visual.track_slot_package_units = function(record, ext, slot_name, captured_units)
    if type(record) ~= "table" then
        return
    end

    local equipment_component = ext and ext._equipment_component
    local unit_spawner = equipment_component and equipment_component._unit_spawner
    local slot = ext and ext._equipment and ext._equipment[slot_name]
    local units = captured_units or live_visual.capture_slot_units(slot)

    live_visual.track_package_units(record, units, unit_spawner)
end

live_visual.refresh_active_package_units = function(ext)
    local equipment = ext and ext._equipment

    if type(equipment) ~= "table" then
        return
    end

    for slot_name, record in pairs(_live_package_loads) do
        local slot = equipment[slot_name]
        local item = slot and slot.item

        if type(record) == "table" and type(item) == "table"
            and item.npclook_generated == true
            and item.name == record.item_name
            and item.npclook_visual_signature == record.visual_signature then
            live_visual.package_units_destroyed(record)
            live_visual.track_slot_package_units(record, ext, slot_name)
        end
    end
end

live_visual.flush_slot_unit_spawner = function(unit_spawner)
    if not unit_spawner then
        return
    end

    local flush = unit_spawner.commit_and_remove_pending_units
        or unit_spawner.remove_pending_units

    if type(flush) == "function" then
        pcall(flush, unit_spawner)
    end
end

live_visual.discard_captured_slot_units = function(ext, ordered)
    local unit_spawner = ext and ext._equipment_component and ext._equipment_component._unit_spawner
    local destroy_list = extra_slot_runtime.destroy_unit_list

    if type(destroy_list) == "function" then
        pcall(destroy_list, ordered, unit_spawner)
        return
    end

    local mark_for_deletion = unit_spawner and unit_spawner.mark_for_deletion

    if type(mark_for_deletion) ~= "function" then
        return
    end

    for i = 1, #(ordered or {}) do
        local unit = ordered[i]

        if util.safe_unit_alive(unit) then
            local ok_world, world = pcall(Unit.world, unit)

            if ok_world and world then
                for _ = 1, 16 do
                    pcall(World.unlink_unit, world, unit)
                end
            end

            pcall(mark_for_deletion, unit_spawner, unit)
        end
    end
end

local function discard_orphaned_slot_units(ext, slot, package_record)
    local unit_spawner = ext and ext._equipment_component and ext._equipment_component._unit_spawner
    local ordered = live_visual.capture_slot_units(slot)

    live_visual.track_package_units(package_record, ordered, unit_spawner)
    live_visual.discard_captured_slot_units(ext, ordered)
    live_visual.flush_slot_unit_spawner(unit_spawner)
end

live_visual.clear_slot_scripts = function(ext, slot_name)
    for _, field in ipairs({ "_wieldable_slot_scripts", "_equipped_slot_scripts" }) do
        local by_slot = ext and ext[field]
        local scripts = by_slot and by_slot[slot_name]

        if type(scripts) == "table" then
            for _, script in pairs(scripts) do
                if type(script) == "table" and type(script.destroy) == "function" then
                    pcall(script.destroy, script)
                end
            end

            table.clear(scripts)
            by_slot[slot_name] = nil
        end
    end
end

live_visual.reset_slot_runtime_fields = reset_slot_runtime_fields

local function clear_equipment_slot_record(ext, slot_name, options)
    local slot = ext and ext._equipment and ext._equipment[slot_name]

    if not slot then
        return false, loc("error_visual_slot_unavailable")
    end

    options = type(options) == "table" and options or {}

    local package_record = options.package_record or _live_package_loads[slot_name]

    live_visual.clear_slot_scripts(ext, slot_name)
    discard_orphaned_slot_units(ext, slot, package_record)
    live_visual.reset_slot_runtime_fields(slot)

    if options.preserve_live_packages ~= true then
        retire_live_slot_packages(slot_name)
    end

    return true
end

local function normalize_empty_equipment_slot(ext, slot_name)
    local slot = ext and ext._equipment and ext._equipment[slot_name]

    if not slot then
        return false, loc("error_visual_slot_unavailable")
    end

    if not slot.equipped or slot.item then
        return true, false
    end

    local cleared, clear_error = clear_equipment_slot_record(ext, slot_name)

    return cleared, cleared and true or clear_error
end

local function player_network_ids(player)
    local peer_id
    local local_player_id

    if player and type(player.peer_id) == "function" then
        local ok, value = pcall(player.peer_id, player)
        peer_id = ok and value or nil
    end

    if player and type(player.local_player_id) == "function" then
        local ok, value = pcall(player.local_player_id, player)
        local_player_id = ok and value or nil
    end

    return peer_id, local_player_id
end

local function profile_package_sync_pending(player, ext, plan)
    local peer_id, local_player_id = player_network_ids(player)

    if not peer_id or local_player_id == nil then
        return false
    end

    local profile_manager = Managers.profile_synchronization
    local profile_host = profile_manager and type(profile_manager.synchronizer_host) == "function"
        and profile_manager:synchronizer_host()
    local profile_updates = profile_host and profile_host._profile_updates
    local peer_updates = profile_updates and profile_updates[peer_id]

    if peer_updates and peer_updates[local_player_id] then
        return true
    end

    local package_manager = Managers.package_synchronization
    local package_host = package_manager and type(package_manager.synchronizer_host) == "function"
        and package_manager:synchronizer_host()
    local host_syncs = package_host and package_host._syncs
    local peer_syncs = host_syncs and host_syncs[peer_id]

    if peer_syncs and peer_syncs[local_player_id] then
        return true
    end

    local package_client = package_manager and type(package_manager.synchronizer_client) == "function"
        and package_manager:synchronizer_client()
    package_client = package_client or ext and ext._equipment_component and ext._equipment_component._package_synchronizer_client

    if package_client and type(package_client.alias_loaded) == "function" then
        for slot_name in pairs(plan.affected) do
            if not (plan.overlay_slots and plan.overlay_slots[slot_name]) then
                local ok_loaded, loaded = pcall(package_client.alias_loaded, package_client, peer_id, local_player_id, slot_name)

                if ok_loaded and not loaded then
                    return true
                end
            end
        end
    end

    return false
end

live_visual.stale_unit_fields = {
    "unit_3p",
    "unit_1p",
    "item_unit_3p",
    "item_unit_1p",
    "parent_unit_3p",
    "parent_unit_1p",
    "owner_unit_3p",
}

live_visual.stale_map_fields = {
    { "attachments_by_unit_3p", true },
    { "attachments_by_unit_1p", true },
    { "attachment_id_lookup_3p", false },
    { "attachment_id_lookup_1p", false },
    { "attachment_map_by_unit_3p", false },
    { "attachment_map_by_unit_1p", false },
    { "item_name_by_unit_3p", false },
    { "item_name_by_unit_1p", false },
}

live_visual.prune_dead_unit_map = function(map, nested_values)
    if type(map) ~= "table" then
        return false, false
    end

    local repaired = false

    for key, value in pairs(map) do
        local dead_key = type(key) == "userdata" and not util.safe_unit_alive(key)
        local dead_value = type(value) == "userdata" and not util.safe_unit_alive(value)

        if dead_key or dead_value then
            map[key] = nil
            repaired = true
        elseif nested_values and type(value) == "table" then
            local nested_repaired, has_values = live_visual.prune_dead_unit_map(value, false)
            repaired = nested_repaired or repaired

            if not has_values then
                map[key] = nil
                repaired = true
            end
        end
    end

    return repaired, next(map) ~= nil
end

live_visual.prune_dead_slot_references = function(slot)
    if type(slot) ~= "table" then
        return false
    end

    local repaired = false
    local unit_fields = live_visual.stale_unit_fields

    for i = 1, #unit_fields do
        local field = unit_fields[i]
        local unit = slot[field]

        if unit ~= nil and not util.safe_unit_alive(unit) then
            slot[field] = nil
            repaired = true
        end
    end

    local map_fields = live_visual.stale_map_fields

    for i = 1, #map_fields do
        local field = map_fields[i][1]
        local map = slot[field]

        if type(map) == "table" then
            local map_repaired, has_values = live_visual.prune_dead_unit_map(map, map_fields[i][2])
            repaired = map_repaired or repaired

            if not has_values then
                slot[field] = nil
            end
        end
    end

    if repaired then
        if type(slot.cached_nodes) == "table" then
            table.clear(slot.cached_nodes)
        else
            slot.cached_nodes = {}
        end
    end

    return repaired
end

live_visual.sanitize_visibility_equipment = function(ext)
    local equipment = ext and ext._equipment

    for _, slot in pairs(equipment or {}) do
        live_visual.prune_dead_slot_references(slot)
    end

    return false
end

live_visual.clear_managed_visibility_slots = function(ext)
    local equipment = ext and ext._equipment
    local cleared = false

    for slot_name in pairs(live_visual.managed_slots) do
        local slot = equipment and equipment[slot_name]

        if slot and (slot.item ~= nil
            or slot.unit_3p ~= nil
            or slot.unit_1p ~= nil
            or slot.item_unit_3p ~= nil
            or slot.item_unit_1p ~= nil) then
            clear_equipment_slot_record(ext, slot_name)
            cleared = true
        end
    end

    if cleared then
        live_visual.plan = nil
    end

    return cleared
end

local HEAD_MASK_SOURCE_SLOTS = { "slot_gear_head", "slot_body_face" }
local UPPER_MASK_SOURCE_SLOTS = { "slot_gear_upperbody", "slot_body_torso" }
local LOWER_MASK_SOURCE_SLOTS = { "slot_gear_lowerbody", "slot_body_legs" }

local function equipment_slot_unit(equipment, wanted_slot, first_person)
    local unit_key = first_person and "unit_1p" or "unit_3p"
    local lookup_key = first_person and "attachment_id_lookup_1p" or "attachment_id_lookup_3p"
    local direct_slot = equipment and equipment[wanted_slot]
    local direct_unit = direct_slot and direct_slot[unit_key]

    if util.safe_unit_alive(direct_unit) then
        return direct_unit, direct_slot
    end

    for _, slot in pairs(equipment or {}) do
        local lookup = slot[lookup_key]
        local attachment_unit = type(lookup) == "table" and lookup[wanted_slot]

        if util.safe_unit_alive(attachment_unit) then
            return attachment_unit, slot
        end
    end
end

local function show_slot_unit(slot, unit, first_person)
    if not util.safe_unit_alive(unit) then
        return
    end

    pcall(Unit.set_unit_visibility, unit, true, true)
    pcall(Unit.flow_event, unit, "lua_visible")

    local attachments_key = first_person and "attachments_by_unit_1p" or "attachments_by_unit_3p"
    local attachment_units = slot and slot[attachments_key] and slot[attachments_key][unit]

    for i = 1, #(attachment_units or {}) do
        local attachment_unit = attachment_units[i]

        if util.safe_unit_alive(attachment_unit) then
            pcall(Unit.set_unit_visibility, attachment_unit, true, true)
            pcall(Unit.flow_event, attachment_unit, "lua_visible")
        end
    end

    if slot then
        slot[first_person and "hidden_1p" or "hidden_3p"] = false
    end
end

local function explicit_mask_field(equipment, slot_names, field)
    for i = 1, #slot_names do
        local slot = equipment and equipment[slot_names[i]]
        local item = slot and slot.item
        local state = item and item.npclook_mask_state
        local fields = type(state) == "table" and state.fields

        if type(fields) == "table" and fields[field] ~= nil then
            return fields[field]
        end
    end
end

local function apply_mask_material(target_unit, parent_unit, field, value, item_definitions)
    if not util.safe_unit_alive(target_unit) then
        return
    end

    local mask_item = MASKS.configured_value(field, value)

    if type(mask_item) == "string" and mask_item ~= "" then
        EXTRA_SLOTS.visual_loadout_customization.apply_material_override_item(
            target_unit,
            parent_unit,
            false,
            mask_item,
            false,
            item_definitions
        )
    end
end

live_visual.apply_mask_overrides = function(
        equipment,
        item_definitions,
        unit_3p,
        unit_1p,
        first_person_mode)
    if type(equipment) ~= "table" or type(item_definitions) ~= "table" then
        return
    end

    local first_person = first_person_mode == true
    local parent_unit = first_person and unit_1p or unit_3p

    if not first_person then
        local hair_value = explicit_mask_field(
            equipment,
            HEAD_MASK_SOURCE_SLOTS,
            "mask_hair_item"
        )
        local facial_hair_value = explicit_mask_field(
            equipment,
            HEAD_MASK_SOURCE_SLOTS,
            "mask_facial_hair_item"
        )
        local eyebrow_value = explicit_mask_field(
            equipment,
            HEAD_MASK_SOURCE_SLOTS,
            "hide_eyebrows"
        )
        local face_value = explicit_mask_field(
            equipment,
            HEAD_MASK_SOURCE_SLOTS,
            "mask_face_item"
        )
        local face_accessory_value = explicit_mask_field(
            equipment,
            HEAD_MASK_SOURCE_SLOTS,
            "mask_face_accessory_item"
        )
        local face_unit = equipment_slot_unit(equipment, "slot_body_face", false)

        if hair_value ~= nil then
            local hair_unit, hair_slot = equipment_slot_unit(equipment, "slot_body_hair", false)

            show_slot_unit(hair_slot, hair_unit, false)
            apply_mask_material(face_unit, parent_unit, "mask_hair_item", hair_value, item_definitions)
        end

        if facial_hair_value ~= nil then
            local facial_hair_unit, facial_hair_slot = equipment_slot_unit(
                equipment,
                "slot_body_face_hair",
                false
            )

            show_slot_unit(facial_hair_slot, facial_hair_unit, false)
            apply_mask_material(
                face_unit,
                parent_unit,
                "mask_facial_hair_item",
                facial_hair_value,
                item_definitions
            )
        end

        if face_value ~= nil then
            apply_mask_material(face_unit, parent_unit, "mask_face_item", face_value, item_definitions)
        end

        if face_accessory_value ~= nil then
            apply_mask_material(
                face_unit,
                parent_unit,
                "mask_face_accessory_item",
                face_accessory_value,
                item_definitions
            )
        end

        if eyebrow_value ~= nil and util.safe_unit_alive(face_unit) then
            pcall(Unit.set_visibility, face_unit, "eyebrows", not eyebrow_value, true)
        end
    end

    local torso_value = explicit_mask_field(
        equipment,
        UPPER_MASK_SOURCE_SLOTS,
        "mask_torso_item"
    )
    local arms_value = explicit_mask_field(
        equipment,
        UPPER_MASK_SOURCE_SLOTS,
        "mask_arms_item"
    )
    local legs_value = explicit_mask_field(
        equipment,
        LOWER_MASK_SOURCE_SLOTS,
        "mask_legs_item"
    )

    if torso_value ~= nil and not first_person then
        local torso_unit, torso_slot = equipment_slot_unit(equipment, "slot_body_torso", false)

        show_slot_unit(torso_slot, torso_unit, false)
        apply_mask_material(torso_unit, parent_unit, "mask_torso_item", torso_value, item_definitions)
    end

    if arms_value ~= nil then
        local arms_unit, arms_slot = equipment_slot_unit(equipment, "slot_body_arms", first_person)

        show_slot_unit(arms_slot, arms_unit, first_person)
        apply_mask_material(arms_unit, parent_unit, "mask_arms_item", arms_value, item_definitions)
    end

    if legs_value ~= nil and not first_person then
        local legs_unit, legs_slot = equipment_slot_unit(equipment, "slot_body_legs", false)

        show_slot_unit(legs_slot, legs_unit, false)
        apply_mask_material(legs_unit, parent_unit, "mask_legs_item", legs_value, item_definitions)
    end
end

local function apply_mask_overrides_safe(
        equipment,
        item_definitions,
        unit_3p,
        unit_1p,
        first_person_mode)
    local mask_ok, mask_error = pcall(
        live_visual.apply_mask_overrides,
        equipment,
        item_definitions,
        unit_3p,
        unit_1p,
        first_person_mode
    )

    if not mask_ok and live_visual.mask_fault ~= tostring(mask_error) then
        live_visual.mask_fault = tostring(mask_error)
        mod:error("Mask override application failed: %s", live_visual.mask_fault)
    elseif mask_ok then
        live_visual.mask_fault = nil
    end
end

live_visual.equipment_has_generated_items = function(equipment)
    for _, slot in pairs(equipment or {}) do
        local item = type(slot) == "table" and slot.item

        if type(item) == "table" and item.npclook_generated == true then
            return true
        end
    end

    return false
end

-- Native visibility updates reset opacity hiding and hidden meshes.
local function apply_equipment_visual_state(equipment)
    for _, slot in pairs(equipment or {}) do
        local item = type(slot) == "table" and slot.item

        if type(item) == "table" and item.npclook_generated == true then
            if util.normalize_opacity(item.npclook_opacity) ~= util.opacity_default then
                util.apply_opacity_to_units(
                    live_visual.capture_slot_units(slot),
                    item.npclook_opacity
                )
            end

            if item.npclook_mesh_state then
                MESHES.apply_visibility(MESHES.slot_scoped_units(slot, item.name), item.npclook_mesh_state)
            end
        end
    end
end

hook_method(EquipmentComponent, "update_item_visibility", function(
        func,
        equipment,
        wielded_slot,
        unit_3p,
        unit_1p,
        first_person_mode,
        item_definitions)
    func(
        equipment,
        wielded_slot,
        unit_3p,
        unit_1p,
        first_person_mode,
        item_definitions
    )

    -- Only generated items carry mask and opacity state.
    if not live_visual.equipment_has_generated_items(equipment) then
        return
    end

    apply_mask_overrides_safe(
        equipment,
        item_definitions,
        unit_3p,
        unit_1p,
        first_person_mode
    )
    apply_equipment_visual_state(equipment)
end)

hook_method(PlayerUnitVisualLoadoutExtension, "_update_item_visibility", function(func, self, first_person_mode)
    local owner = live_visual.owners.for_unit(self._unit)

    -- Vanilla characters skip the stale-unit guard entirely.
    if not (owner and next(owner.managed_slots))
        and not extra_slot_runtime.has_units()
        and not live_visual.equipment_has_generated_items(self._equipment) then
        return func(self, first_person_mode)
    end

    live_visual.sanitize_visibility_equipment(self)

    local ok, visibility_error = pcall(func, self, first_person_mode)

    if not ok then
        live_visual.sanitize_visibility_equipment(self)

        -- Only the owner of this unit may clear its slot records and packages.
        if owner then
            live_visual.owners.run(owner, live_visual.clear_managed_visibility_slots, self)
            live_visual.owners.run(owner, schedule_reapply)
        end

        if live_visual.visibility_fault ~= tostring(visibility_error) then
            live_visual.visibility_fault = tostring(visibility_error)
            mod:error("Visibility update recovered from stale equipment units: %s", live_visual.visibility_fault)
        end

        return
    end

    live_visual.visibility_fault = nil

    local active_first_person = type(first_person_mode) == "boolean"
        and first_person_mode or self._is_in_first_person_mode == true

    if self._is_local_unit == true and util.safe_unit_alive(self._unit) then
        pcall(extra_slot_runtime.set_first_person_mode, self._unit, active_first_person)
    end
end)

-- Server correction

local NIL_INVENTORY_VALUE = {}

-- Let vanilla correct only the slots replaced by the mod.
-- Darktide: scripts/extension_systems/visual_loadout/player_unit_visual_loadout_extension.lua
hook_method(PlayerUnitVisualLoadoutExtension, "server_correction_occurred", function(func, self, unit, from_frame)
    if self._is_local_unit ~= true or self._unit ~= unit or unit ~= _bound_player_unit then
        return func(self, unit, from_frame)
    end

    if not next(live_visual.managed_slots) then
        return func(self, unit, from_frame)
    end

    live_visual.sanitize_visibility_equipment(self)

    local inventory = self._inventory_component
    local equipment = self._equipment

    if not inventory or not equipment then
        return func(self, unit, from_frame)
    end

    local saved_inventory = {}
    local unequipped_slot = self.UNEQUIPPED_SLOT or "not_equipped"

    for slot_name in pairs(live_visual.managed_slots) do
        normalize_empty_equipment_slot(self, slot_name)

        if valid_look_slot(slot_name) then
            local slot = equipment[slot_name]
            local item = slot and slot.equipped and slot.item
            local local_item_name = item and item.name or unequipped_slot
            local server_item_name = inventory[slot_name]

            -- Shield managed visual slots, then restore the network value.
            if server_item_name ~= local_item_name then
                saved_inventory[slot_name] = server_item_name == nil
                    and NIL_INVENTORY_VALUE or server_item_name
                inventory[slot_name] = local_item_name
            end
        end
    end

    -- This has to run on the error path too.
    local results = { pcall(func, self, unit, from_frame) }
    local ok = table.remove(results, 1)

    for slot_name, saved in pairs(saved_inventory) do
        inventory[slot_name] = saved == NIL_INVENTORY_VALUE and nil or saved
    end

    prediction.clear_handler(self._mispredict_package_handler)

    if not ok then
        mod:error("Server correction failed: %s", tostring(results[1]))
        return
    end

    return unpack(results)
end)

local function slot_item(ext, slot_name)
    local slot = ext and ext._equipment and ext._equipment[slot_name]

    return slot and slot.item or nil
end

-- NPC Look can intentionally leave a managed visual slot empty while the native
-- profile still contains an item for that slot. During a later profile sync,
-- Darktide calls the normal public unequip path, whose internal implementation
-- assumes slot.item is always present. Treat an already-empty managed slot as
-- an idempotent internal unequip. The public wrapper still updates the native
-- inventory component and sends its normal replication message.
-- Darktide: scripts/extension_systems/visual_loadout/player_unit_visual_loadout_extension.lua
hook_method(PlayerUnitVisualLoadoutExtension, "_unequip_item_from_slot", function(
        func,
        self,
        slot_name,
        from_server_correction_occurred,
        fixed_frame,
        from_destroy)
    if live_visual.owners.managed_slots_for(self)[slot_name] == true then
        local slot = self._equipment and self._equipment[slot_name]

        if type(slot) ~= "table" or type(slot.item) ~= "table" then
            if type(slot) == "table" then
                slot.equipped = false
            end

            return
        end
    end

    return func(
        self,
        slot_name,
        from_server_correction_occurred,
        fixed_frame,
        from_destroy
    )
end)

local function unequip_slot(ext, slot_name, fixed_frame)
    local normalized, normalize_error = normalize_empty_equipment_slot(ext, slot_name)

    if not normalized then
        return false, normalize_error
    end

    local slot = ext and ext._equipment and ext._equipment[slot_name]
    local item = slot and slot.item

    if not item then
        return true
    end

    local prediction_marker = prediction.prepare_direct_unload(ext, slot_name, item)
    local pending_before = prediction_marker
        and prediction.pending_count(prediction_marker.handler, item) or 0

    -- Capture generated descendants that vanilla may omit from its slot map.
    local captured_units = item.npclook_generated == true and live_visual.capture_slot_units(slot) or nil
    local unit_spawner = ext and ext._equipment_component and ext._equipment_component._unit_spawner

    if captured_units then
        live_visual.track_package_units(_live_package_loads[slot_name], captured_units, unit_spawner)
    end

    local ok, err = pcall(ext._unequip_item_from_slot, ext, slot_name, false, fixed_frame, false)
    local pending_after = prediction_marker
        and prediction.pending_count(prediction_marker.handler, item) or pending_before

    if prediction_marker and pending_after > pending_before then
        prediction.commit_direct_unload(prediction_marker)
    end

    if captured_units then
        -- Wait for pending deletion, then remove only surviving units.
        live_visual.flush_slot_unit_spawner(unit_spawner)
        live_visual.discard_captured_slot_units(ext, captured_units)
        live_visual.flush_slot_unit_spawner(unit_spawner)
    end

    if not ok then
        mod:error("Unequip failed for %s: %s", tostring(slot_name), tostring(err))
    end

    return ok, err
end

local function equip_slot(ext, slot_name, item, fixed_t, package_record)
    if not item then
        return false, loc("error_item_nil")
    end

    local equipment_component = ext._equipment_component
    local generated = item.npclook_generated == true
    local handler = not generated and ext._mispredict_package_handler or nil
    local capture = handler and prediction.begin_capture(handler, item) or nil
    local extension_manager = generated and equipment_component and equipment_component._extension_manager
    local from_ui_profile_spawner = generated and equipment_component and equipment_component._from_ui_profile_spawner

    if generated and equipment_component then
        equipment_component._extension_manager = nil
        equipment_component._from_ui_profile_spawner = true
    end

    local ok, err = pcall(ext._equip_item_to_slot, ext, item, slot_name, fixed_t, nil, false)

    if generated and equipment_component then
        equipment_component._extension_manager = extension_manager
        equipment_component._from_ui_profile_spawner = from_ui_profile_spawner
    end

    if ok and handler then
        prediction.set_slot_record(handler, slot_name, prediction.finish_capture(handler, capture))
    elseif not ok then
        clear_equipment_slot_record(ext, slot_name, {
            package_record = package_record,
            preserve_live_packages = true,
        })
        mod:error("Equip failed for %s: %s", tostring(slot_name), tostring(err))
    end

    return ok, err
end

-- Live slots start from the profile visual loadout.
local function snapshot_slot(player_unit, slot_name)
    if _originals[slot_name] ~= nil then
        return
    end

    local ext = visual_extension(player_unit)

    if not ext then
        return
    end

    _originals[slot_name] = slot_item(ext, slot_name) or false
end

live_visual.items_match = function(current, desired, visual_signature)
    if rawequal(current, desired) then
        return true
    elseif not current or not desired or current.name ~= desired.name then
        return false
    elseif desired.npclook_generated == true then
        return current.npclook_generated == true
            and current.npclook_visual_signature == visual_signature
    elseif current.npclook_generated == true then
        return false
    end

    return live_visual.item_signature(current) == visual_signature
end

live_visual.swap_slot = function(ext, slot_name, item, visual_signature, fixed_frame, fixed_t)
    local current = slot_item(ext, slot_name)
    local generated = item and item.npclook_generated == true

    if live_visual.items_match(current, item, visual_signature) then
        local package_record = _live_package_loads[slot_name]
        local package_record_matches = package_record
            and package_record.package_manager == Managers.package
            and package_record.item_name == item.name
            and package_record.visual_signature == visual_signature

        if generated and not package_record_matches then
            local replacement_record, package_error, packages_loading = acquire_live_item_packages(
                ext,
                slot_name,
                item,
                visual_signature
            )

            if not replacement_record then
                return false, false, package_error, packages_loading
            end

            if package_record then
                live_visual.transfer_package_units(package_record, replacement_record)
            else
                live_visual.track_slot_package_units(replacement_record, ext, slot_name)
            end

            retire_live_slot_packages(slot_name)
            _live_package_loads[slot_name] = replacement_record
        elseif not generated and package_record then
            retire_live_slot_packages(slot_name)
        end

        if generated then
            live_visual.track_slot_package_units(_live_package_loads[slot_name], ext, slot_name)

            local equipment = ext._equipment
            EXTRA_SLOTS.apply_custom_materials_to_slot(equipment and equipment[slot_name], item)
            live_visual.apply_slot_meshes(equipment and equipment[slot_name], item)
        end

        return true, false
    end

    if not item then
        return false, false, loc("error_item_nil")
    end

    local package_record
    local previous_package_record = _live_package_loads[slot_name]

    if generated then
        local package_error
        local packages_loading
        package_record, package_error, packages_loading = acquire_live_item_packages(
            ext,
            slot_name,
            item,
            visual_signature
        )

        if not package_record then
            return false, false, package_error, packages_loading
        end
    end

    local unequip_ok, unequip_error = unequip_slot(ext, slot_name, fixed_frame)

    if not unequip_ok then
        if package_record and not release_live_package_record(package_record) then
            queue_live_package_release(package_record, 0)
        end

        return false, false, unequip_error
    end

    local equip_ok, equip_error = equip_slot(ext, slot_name, item, fixed_t, package_record)

    if equip_ok then
        if package_record then
            live_visual.track_slot_package_units(package_record, ext, slot_name)
        end

        retire_live_slot_packages(slot_name)

        if package_record then
            _live_package_loads[slot_name] = package_record
        end

        if generated then
            local equipment = ext._equipment
            EXTRA_SLOTS.apply_custom_materials_to_slot(equipment and equipment[slot_name], item)
            live_visual.apply_slot_meshes(equipment and equipment[slot_name], item)
        end
    else
        if package_record then
            queue_live_package_release(package_record)
        end

        if current then
            local rollback_ok = equip_slot(ext, slot_name, current, fixed_t, previous_package_record)

            if rollback_ok then
                live_visual.track_slot_package_units(previous_package_record, ext, slot_name)
            else
                clear_equipment_slot_record(ext, slot_name)
            end
        else
            clear_equipment_slot_record(ext, slot_name)
        end
    end

    return equip_ok, true, equip_error
end

live_visual.ordered_slots = function(reverse)
    local ordered = {}
    local seen = {}
    local engine_order = PlayerCharacterConstants.slot_equip_order or {}

    for i = 1, #engine_order do
        local slot_name = engine_order[i]

        if valid_look_slot(slot_name) and not seen[slot_name] then
            ordered[#ordered + 1] = slot_name
            seen[slot_name] = true
        end
    end

    local remaining_slots = {}

    for slot_name in pairs(LOOK_SLOTS) do
        if valid_look_slot(slot_name) and not seen[slot_name] then
            remaining_slots[#remaining_slots + 1] = slot_name
        end
    end

    table.sort(remaining_slots)

    for i = 1, #remaining_slots do
        local slot_name = remaining_slots[i]
        ordered[#ordered + 1] = slot_name
        seen[slot_name] = true
    end

    if reverse then
        local reversed = {}

        for i = #ordered, 1, -1 do
            reversed[#reversed + 1] = ordered[i]
        end

        return reversed
    end

    return ordered
end

live_visual.map_signature = function(values)
    local keys = table.keys(values or {})

    table.sort(keys)

    local parts = {}

    for i = 1, #keys do
        local key = keys[i]
        parts[#parts + 1] = tostring(key) .. "=" .. tostring(values[key])
    end

    return table.concat(parts, ",")
end

live_visual.profile_signature = function(profile, look_state)
    local loadout = profile and profile.loadout or {}
    local slots = table.keys(loadout)
    local state = look_state or _look_state
    local parts = {
        tostring(profile and profile.character_id or ""),
        tostring(profile_breed_name(profile) or ""),
        tostring(_master_items_cache_version or ""),
    }

    table.sort(slots)

    for i = 1, #slots do
        local slot_name = slots[i]
        parts[#parts + 1] = slot_name .. "=" .. live_visual.item_signature(loadout[slot_name])
    end

    parts[#parts + 1] = "applied:" .. live_visual.map_signature(state.applied)
    parts[#parts + 1] = "suppressed:" .. live_visual.map_signature(state.suppressed)
    parts[#parts + 1] = "empty:" .. live_visual.map_signature(state.empty)

    return table.concat(parts, "|")
end

live_visual.generate_loadout = function(loadout)
    local ok, visual_loadout = pcall(EXTRA_SLOTS.profile_utils.generate_visual_loadout, loadout)

    if not ok then
        return nil, visual_loadout
    end

    return visual_loadout or {}
end

live_visual.detach_item = function(item)
    if not item then
        return nil
    end

    local ok_preview, preview_item = pcall(MasterItems.create_preview_item_instance, item)

    if ok_preview and preview_item then
        return preview_item
    end

    local ok_ui, ui_item = pcall(MasterItems.get_ui_item_instance, item)

    if ok_ui and ui_item then
        return ui_item
    end

    return nil, preview_item or ui_item
end

local function without_overlay_raw_slots(loadout, applied)
    local result = shallow_copy(loadout or {})

    for slot_name, item_name in pairs(applied or {}) do
        if valid_look_slot(slot_name) then
            local item = item_definition(item_name)

            if RAW_UNITS.use_overlay_spawn(item) then
                result[slot_name] = nil
            end
        end
    end

    return result
end

live_visual.build_plan = function(player)
    local profile = safe_profile(player)

    if not profile then
        return nil, loc("error_local_player_not_ready")
    elseif not item_cache() then
        return nil, loc("error_master_cache_not_ready")
    end

    local signature = live_visual.profile_signature(profile)
        .. "|materials:" .. EXTRA_SLOTS.material_map_signature(_look_state.materials)
        .. "|opacity:" .. live_visual.map_signature(_look_state.opacity)
        .. "|variants:" .. live_visual.map_signature((function()
            local signatures = {}
            for slot_name, value in pairs(_look_state.variants) do
                signatures[slot_name] = RAW_UNITS.variant_signature(value)
            end
            return signatures
        end)())
        .. "|masks:" .. live_visual.map_signature((function()
            local signatures = {}
            for slot_name, value in pairs(_look_state.masks) do
                signatures[slot_name] = MASKS.signature(value)
            end
            return signatures
        end)())
        .. "|meshes:" .. live_visual.map_signature((function()
            local signatures = {}
            for slot_name, value in pairs(_look_state.meshes) do
                signatures[slot_name] = MESHES.signature(value)
            end
            return signatures
        end)())

    if live_visual.plan and live_visual.plan_signature == signature then
        return live_visual.plan
    end

    local source_loadout = profile.loadout or {}
    local desired_loadout = shallow_copy(source_loadout)
    local generated_material_data = {}

    for slot_name in pairs(_look_state.suppressed) do
        if valid_look_slot(slot_name) then
            desired_loadout[slot_name] = nil
        end
    end

    for slot_name in pairs(_look_state.empty) do
        if valid_look_slot(slot_name) then
            desired_loadout[slot_name] = nil
        end
    end

    local slots = live_visual.ordered_slots(false)

    for i = 1, #slots do
        local slot_name = slots[i]
        local source_item = source_loadout[slot_name]
        local source_item_name = type(source_item) == "table" and source_item.name
            or type(source_item) == "string" and source_item or nil
        local item_name = _look_state.applied[slot_name] or source_item_name
        local materials = _look_state.materials[slot_name]

        if item_name
            and not _look_state.suppressed[slot_name]
            and not _look_state.empty[slot_name]
            and (_look_state.applied[slot_name] or #EXTRA_SLOTS.normalize_materials(materials) > 0
                or _look_state.masks[slot_name]
                or _look_state.meshes[slot_name]
                or util.normalize_opacity(_look_state.opacity[slot_name]) ~= util.opacity_default) then
            local item = make_item_instance(
                slot_name,
                item_name,
                materials,
                _look_state.variants[slot_name],
                _look_state.masks[slot_name],
                _look_state.opacity[slot_name],
                _look_state.meshes[slot_name]
            )

            if not item then
                return nil, loc("error_missing_item_slot", tostring(slot_name), tostring(item_name))
            end

            desired_loadout[slot_name] = item

            if item.npclook_custom_material_overrides then
                generated_material_data[slot_name] = {
                    authored = item.npclook_authored_material_overrides,
                    combined = item.npclook_combined_material_overrides,
                    custom = item.npclook_custom_material_overrides,
                    signature = item.npclook_material_signature,
                }
            end
        end
    end

    local visual_desired_loadout = without_overlay_raw_slots(
        desired_loadout,
        _look_state.applied
    )
    local desired_visual_loadout, desired_error = live_visual.generate_loadout(visual_desired_loadout)

    if not desired_visual_loadout then
        return nil, loc("error_visual_apply", tostring(desired_error or loc("generic_unknown_error")))
    end

    local original_visual_loadout, original_error = live_visual.generate_loadout(source_loadout)

    if not original_visual_loadout then
        return nil, loc("error_visual_apply", tostring(original_error or loc("generic_unknown_error")))
    end

    local plan = {
        affected = {},
        desired = desired_visual_loadout,
        desired_signatures = {},
        original = original_visual_loadout,
        original_signatures = {},
        extra_loadout = desired_loadout,
        overlay_slots = {},
    }

    for slot_name, item_name in pairs(_look_state.applied) do
        if valid_look_slot(slot_name) and RAW_UNITS.use_overlay_spawn(item_definition(item_name)) then
            plan.overlay_slots[slot_name] = true
        end
    end

    for i = 1, #slots do
        local slot_name = slots[i]
        local desired_item = desired_visual_loadout[slot_name]
        local original_item = original_visual_loadout[slot_name]
        local desired_signature = live_visual.item_signature(desired_item)
        local original_signature = live_visual.item_signature(original_item)
        local explicit = _look_state.applied[slot_name] ~= nil
            or _look_state.suppressed[slot_name] ~= nil
            or _look_state.empty[slot_name] ~= nil
            or #EXTRA_SLOTS.normalize_materials(_look_state.materials[slot_name]) > 0
            or _look_state.masks[slot_name] ~= nil
            or _look_state.meshes[slot_name] ~= nil
        local affected = explicit or desired_signature ~= original_signature

        plan.desired_signatures[slot_name] = desired_signature
        plan.original_signatures[slot_name] = original_signature
        plan.affected[slot_name] = affected or nil

        if affected and desired_item then
            local detached_item, detach_error = live_visual.detach_item(desired_item)

            if not detached_item then
                return nil, loc("error_visual_apply", tostring(detach_error or loc("generic_unknown_error")))
            end

            detached_item = EXTRA_SLOTS.copy_generated_material_metadata(desired_item, detached_item)
            detached_item = EXTRA_SLOTS.copy_generated_visual_tree_state(desired_item, detached_item)
            detached_item.npclook_raw_variant_state = desired_item.npclook_raw_variant_state
            detached_item.npclook_raw_variant_signature = desired_item.npclook_raw_variant_signature
            detached_item.npclook_mask_state = desired_item.npclook_mask_state
            detached_item.npclook_mask_signature = desired_item.npclook_mask_signature
            -- Detaching rebuilds dependencies from gear data; mesh materials load with the item.
            MESHES.add_package_dependencies(detached_item, desired_item.npclook_mesh_state, item_cache())
            detached_item.npclook_source_item_name = desired_item.npclook_source_item_name or desired_item.name
            detached_item.is_ui_item_preview = true
            detached_item.npclook_generated = true
            detached_item.npclook_visual_signature = desired_signature

            local material_data = generated_material_data[slot_name]

            if material_data then
                detached_item.npclook_authored_material_overrides = material_data.authored
                detached_item.npclook_combined_material_overrides = material_data.combined
                detached_item.npclook_custom_material_overrides = material_data.custom
                detached_item.npclook_material_signature = material_data.signature
                detached_item.material_override_items = material_data.combined
            end

            plan.desired[slot_name] = detached_item
        end
    end

    local previous_plan = live_visual.plan

    if previous_plan then
        for slot_name in pairs(live_visual.managed_slots) do
            if previous_plan.original_signatures[slot_name] ~= plan.original_signatures[slot_name] then
                _originals[slot_name] = plan.original[slot_name] or false
            end
        end
    end

    live_visual.plan = plan
    live_visual.plan_signature = signature

    return plan
end

live_visual.equip_all = function(player, owner)
    local player_unit = safe_player_unit(player)
    local ext = visual_extension(player_unit)

    if not ext then
        return false, 0, 0, loc("error_visual_extension_missing")
    end

    live_visual.sanitize_visibility_equipment(ext)

    local cache = item_cache()

    if not cache then
        return false, 0, 0, loc("error_master_cache_not_ready")
    end

    for slot_name, item_name in pairs(_look_state.applied) do
        if valid_look_slot(slot_name) then
            local item = item_definition(item_name)

            if not item then
                return false, 0, 1, loc("error_missing_item_slot", tostring(slot_name), tostring(item_name))
            elseif util.item_is_2d(item, item_name) then
                return false, 0, 1, loc("error_visual_slot_unavailable")
            end
        end
    end

    if owner then
        if owner.unit ~= player_unit then
            live_visual.owners.unbind_unit(owner)
            owner.unit = player_unit
            live_visual.owners.by_unit[player_unit] = owner
        end
    elseif _bound_player_unit ~= player_unit then
        extra_slot_runtime.clear(0)
        retire_all_live_slot_packages()
        table.clear(_originals)
        table.clear(live_visual.managed_slots)
        live_visual.plan = nil
        live_visual.plan_signature = nil
        _bound_player_unit = player_unit
    end

    local plan, plan_error = live_visual.build_plan(player)

    if not plan then
        return false, 0, 1, plan_error
    end

    if profile_package_sync_pending(player, ext, plan) then
        if not owner then
            _live_profile_sync_waiting = true
        end

        return false, 0, 0, loc("error_local_visual_not_ready"), true
    end

    if not owner then
        _live_profile_sync_waiting = false
    end

    for slot_name in pairs(plan.affected) do
        live_visual.managed_slots[slot_name] = true
    end

    local fixed_frame, fixed_t = fixed_frame_values(ext)
    local equipped_count = 0
    local failed_count = 0
    local first_error
    local loading_error
    local packages_loading = false
    local remove_order = live_visual.ordered_slots(true)

    for i = 1, #remove_order do
        local slot_name = remove_order[i]

        if live_visual.managed_slots[slot_name] then
            snapshot_slot(player_unit, slot_name)

            if not plan.desired[slot_name] then
                local current = slot_item(ext, slot_name)
                local ok, err = unequip_slot(ext, slot_name, fixed_frame)

                if not ok then
                    failed_count = failed_count + 1
                    first_error = first_error or string.format("%s: %s", slot_name, tostring(err))
                else
                    retire_live_slot_packages(slot_name)

                    if current then
                        equipped_count = equipped_count + 1
                    end
                end
            end
        end
    end

    local equip_order = live_visual.ordered_slots(false)

    for i = 1, #equip_order do
        local slot_name = equip_order[i]

        if live_visual.managed_slots[slot_name] then
            local desired_item = plan.desired[slot_name]

            if desired_item then
                snapshot_slot(player_unit, slot_name)
                normalize_empty_equipment_slot(ext, slot_name)

                local target_item = desired_item
                local target_signature = plan.desired_signatures[slot_name]
                local original_item = _originals[slot_name]

                if not plan.affected[slot_name]
                    and original_item
                    and original_item ~= false
                    and live_visual.item_signature(original_item) == target_signature then
                    target_item = original_item
                end

                local ok, changed, err, slot_packages_loading = live_visual.swap_slot(
                    ext,
                    slot_name,
                    target_item,
                    target_signature,
                    fixed_frame,
                    fixed_t
                )

                if ok then
                    if changed then
                        equipped_count = equipped_count + 1
                    end
                elseif slot_packages_loading then
                    packages_loading = true
                    loading_error = loading_error or string.format("%s: %s", slot_name, tostring(err))
                else
                    failed_count = failed_count + 1
                    first_error = first_error or string.format("%s: %s", slot_name, tostring(err))
                end
            end
        end
    end

    if failed_count == 0 and not packages_loading then
        local force_visibility = ext.force_update_item_visibility

        if type(force_visibility) == "function" then
            pcall(force_visibility, ext)
        end

        for slot_name in pairs(live_visual.managed_slots) do
            if not plan.affected[slot_name] then
                local current = slot_item(ext, slot_name)
                local desired_item = plan.desired[slot_name]
                local desired_signature = plan.desired_signatures[slot_name]

                if (not desired_item and not current) or live_visual.items_match(current, desired_item, desired_signature) then
                    live_visual.managed_slots[slot_name] = nil
                    _originals[slot_name] = nil
                    retire_live_slot_packages(slot_name)
                end
            end
        end
    end

    local extra_slots_ok, extra_slots_spawned, extra_slots_failed, extra_slots_error, extra_slots_loading = extra_slot_runtime.sync(
        player_unit,
        ext,
        _look_state.applied,
        _look_state.suppressed,
        _look_state.empty,
        _look_state.extra_anchors,
        _look_state.extra_transforms,
        plan.extra_loadout,
        _look_state.variants,
        _look_state.opacity,
        _look_state.meshes,
        owner
    )
    equipped_count = equipped_count + extra_slots_spawned
    failed_count = failed_count + extra_slots_failed
    packages_loading = packages_loading or extra_slots_loading

    -- A slot that is only loading must not hide the slot that actually failed.
    if (tonumber(extra_slots_failed) or 0) > 0 or not extra_slots_ok and not extra_slots_loading then
        first_error = first_error or extra_slots_error
    else
        loading_error = loading_error or extra_slots_error
    end

    first_error = first_error or loading_error

    return failed_count == 0 and not packages_loading and extra_slots_ok, equipped_count, failed_count, first_error, packages_loading
end

live_visual.matches = function(player)
    local ext = visual_extension(safe_player_unit(player))

    if not ext then
        return false, loc("error_visual_extension_missing")
    end

    live_visual.sanitize_visibility_equipment(ext)

    local plan, plan_error = live_visual.build_plan(player)

    if not plan then
        return false, plan_error
    end

    local slots = live_visual.ordered_slots(false)

    for i = 1, #slots do
        local slot_name = slots[i]

        if plan.affected[slot_name] or live_visual.managed_slots[slot_name] then
            local current = slot_item(ext, slot_name)
            local desired_item = plan.desired[slot_name]
            local desired_signature = plan.desired_signatures[slot_name]

            if desired_item then
                if not live_visual.items_match(current, desired_item, desired_signature) then
                    return false, loc("error_expected_item", slot_name, desired_item.name)
                end
            elseif current then
                return false, loc("error_should_empty", slot_name)
            end
        end
    end

    local extra_slots_match, extra_slots_error = extra_slot_runtime.matches(
        _look_state.applied,
        _look_state.suppressed,
        _look_state.empty,
        _look_state.extra_anchors,
        _look_state.extra_transforms,
        plan.extra_loadout,
        _look_state.variants,
        _look_state.opacity,
        _look_state.meshes
    )

    if not extra_slots_match then
        return false, extra_slots_error
    end

    return true
end

local function restore_slots(player, requested_slots)
    local player_unit = safe_player_unit(player)
    local ext = visual_extension(player_unit)

    if not ext then
        return false
    end

    local fixed_frame, fixed_t = fixed_frame_values(ext)
    local removed = {}
    local restored = true
    local remove_order = live_visual.ordered_slots(true)

    for i = 1, #remove_order do
        local slot_name = remove_order[i]

        if requested_slots[slot_name] and _originals[slot_name] ~= nil then
            local ok = unequip_slot(ext, slot_name, fixed_frame)
            removed[slot_name] = ok == true
            restored = restored and ok == true

            if ok then
                retire_live_slot_packages(slot_name)
            end
        end
    end

    local equip_order = live_visual.ordered_slots(false)

    for i = 1, #equip_order do
        local slot_name = equip_order[i]
        local original_item = _originals[slot_name]

        if removed[slot_name] and original_item and original_item ~= false then
            restored = equip_slot(ext, slot_name, original_item, fixed_t) and restored
        end
    end

    if restored then
        for slot_name in pairs(requested_slots) do
            _originals[slot_name] = nil
            live_visual.managed_slots[slot_name] = nil
        end

        live_visual.plan = nil
        live_visual.plan_signature = nil
    end

    return restored
end

local function direct_restore(player)
    local requested_slots = {}

    extra_slot_runtime.clear(0)

    for slot_name in pairs(_originals) do
        requested_slots[slot_name] = true
    end

    local restored = restore_slots(player, requested_slots)

    if restored then
        table.clear(live_visual.managed_slots)
        live_visual.plan = nil
        live_visual.plan_signature = nil
    end

    return restored
end

local function push_look()
    local player = get_local_player()

    if not player then
        return false, loc("error_no_local_player")
    end

    _raw_overlay_retry_requested = false

    local ok, equipped, failed, err, packages_loading = live_visual.equip_all(player)

    if _raw_overlay_retry_requested and not packages_loading then
        _raw_overlay_retry_requested = false
        extra_slot_runtime.clear(0)
        live_visual.plan = nil
        live_visual.plan_signature = nil
        ok, equipped, failed, err, packages_loading = live_visual.equip_all(player)
    end

    if packages_loading and failed == 0 then
        schedule_reapply()
        return true, nil, true
    end

    if ok then
        ok, err = live_visual.matches(player)
    end

    if ok and type(mod.npclook_refresh_portrait) == "function" then
        local profile = safe_profile(player)
        local archetype = profile and profile.archetype
        _look_state.character_id = profile and profile.character_id or _look_state.character_id
        _look_state.breed = type(archetype) == "table" and archetype.breed or _look_state.breed
        mod.npclook_refresh_portrait()
    end

    return ok, err, false
end

local function invalidate_live_plan()
    live_visual.plan = nil
    live_visual.plan_signature = nil
end

local function repair_visual_after_state_restore()
    extra_slot_runtime.clear(0)
    invalidate_live_plan()

    local ok, err, loading = push_look()

    if not ok and not loading then
        schedule_reapply()
    end

    return ok, err
end

-- Companion owners

function live_visual.owners.bind(owner)
    live_visual.owners.current = owner
    _look_state = owner.state
    _originals = owner.originals
    _live_package_loads = owner.package_loads
    _pending_live_package_loads = owner.pending_package_loads
    live_visual.managed_slots = owner.managed_slots
    live_visual.plan = owner.plan
    live_visual.plan_signature = owner.plan_signature
end

function live_visual.owners.pack(...)
    return { n = select("#", ...), ... }
end

-- Runs fn with the owner's look and live tables bound and returns its pcall results.
function live_visual.owners.run(owner, fn, ...)
    local owners = live_visual.owners
    local previous = owners.current

    if not owner or owner == previous then
        return pcall(fn, ...)
    end

    previous.plan, previous.plan_signature = live_visual.plan, live_visual.plan_signature
    owners.bind(owner)

    local results = owners.pack(pcall(fn, ...))

    owner.plan, owner.plan_signature = live_visual.plan, live_visual.plan_signature
    owners.bind(previous)

    return unpack(results, 1, results.n)
end

function live_visual.owners.for_unit(unit)
    if unit == nil then
        return nil
    elseif unit == _bound_player_unit then
        return live_visual.owners.local_record
    end

    return live_visual.owners.by_unit[unit]
end

live_visual.owners.no_slots = {}

function live_visual.owners.managed_slots_for(ext)
    local owner = ext and live_visual.owners.for_unit(ext._unit)

    return owner and owner.managed_slots or live_visual.owners.no_slots
end

-- Runs inside the owner scope.
function live_visual.owners.unbind_unit(owner)
    if owner.unit ~= nil then
        live_visual.owners.by_unit[owner.unit] = nil
    end

    extra_slot_runtime.clear_context(owner, 0)
    retire_all_live_slot_packages()
    table.clear(_originals)
    table.clear(live_visual.managed_slots)
    live_visual.plan = nil
    live_visual.plan_signature = nil
    owner.unit = nil
end

-- Runs inside the owner scope.
function live_visual.owners.restore_owner(owner)
    local requested_slots = {}

    extra_slot_runtime.clear_context(owner, 0)

    for slot_name in pairs(_originals) do
        requested_slots[slot_name] = true
    end

    local restored = restore_slots(owner.player, requested_slots)
    local ext = visual_extension(owner.unit)
    local force_visibility = ext and ext.force_update_item_visibility

    if type(force_visibility) == "function" then
        pcall(force_visibility, ext)
    end

    return restored
end

-- Deep copy of a look state; companion mods never get the live tables.
function live_visual.owners.snapshot_state(state)
    state = type(state) == "table" and state or {}

    local anchors = {}
    local transforms = {}

    for id, anchor in pairs(type(state.extra_anchors) == "table" and state.extra_anchors or {}) do
        if type(id) == "string" and string.match(id, "^extra_%d+$") and valid_look_slot(anchor) then
            anchors[id] = anchor
            transforms[id] = EXTRA_SLOTS.normalize_transform(
                type(state.extra_transforms) == "table" and state.extra_transforms[id] or nil
            )
        end
    end

    return {
        applied = shallow_copy(type(state.applied) == "table" and state.applied or {}),
        suppressed = shallow_copy(type(state.suppressed) == "table" and state.suppressed or {}),
        empty = shallow_copy(type(state.empty) == "table" and state.empty or {}),
        extra_anchors = anchors,
        extra_transforms = transforms,
        materials = EXTRA_SLOTS.clone_material_map(type(state.materials) == "table" and state.materials or {}),
        opacity = util.clone_opacity_map(type(state.opacity) == "table" and state.opacity or {}),
        variants = RAW_UNITS.clone_variant_map(state.variants),
        masks = MASKS.clone_map(state.masks),
        meshes = MESHES.clone_map(state.meshes),
        character_id = state.character_id,
        breed = state.breed,
    }
end

-- Drops anything a live owner cannot use instead of failing the whole look.
function live_visual.owners.normalize_state(state)
    local result = live_visual.owners.snapshot_state(state)

    local function known_slot(slot_name)
        return valid_look_slot(slot_name) or result.extra_anchors[slot_name] ~= nil
    end

    for slot_name, item_name in pairs(result.applied) do
        local item, normalized_item_name

        if known_slot(slot_name) and type(item_name) == "string" then
            item, normalized_item_name = item_definition(item_name)
        end

        if not item or util.item_is_2d(item, item_name) then
            result.applied[slot_name] = nil
        else
            result.applied[slot_name] = normalized_item_name or item_name
        end
    end

    for _, field in ipairs({ "suppressed", "empty" }) do
        for slot_name, value in pairs(result[field]) do
            if value ~= true or not known_slot(slot_name) then
                result[field][slot_name] = nil
            end
        end
    end

    for _, field in ipairs({ "materials", "opacity", "variants", "meshes" }) do
        for slot_name in pairs(result[field]) do
            if not known_slot(slot_name) then
                result[field][slot_name] = nil
            end
        end
    end

    for slot_name in pairs(result.masks) do
        if not valid_look_slot(slot_name) then
            result.masks[slot_name] = nil
        end
    end

    return result
end

function live_visual.owners.equip(owner)
    local saved_overlay_retry = _raw_overlay_retry_requested
    _raw_overlay_retry_requested = false

    local call_ok, ok, equipped, failed, err, packages_loading = live_visual.owners.run(
        owner,
        live_visual.equip_all,
        owner.player,
        owner
    )

    if call_ok and _raw_overlay_retry_requested and not packages_loading then
        _raw_overlay_retry_requested = false
        extra_slot_runtime.clear_context(owner, 0)
        owner.plan = nil
        owner.plan_signature = nil
        call_ok, ok, equipped, failed, err, packages_loading = live_visual.owners.run(
            owner,
            live_visual.equip_all,
            owner.player,
            owner
        )
    end

    _raw_overlay_retry_requested = saved_overlay_retry

    if not call_ok then
        ok, equipped, failed, err, packages_loading = false, 0, 1, tostring(ok), false
    end

    ok = ok == true
    packages_loading = packages_loading == true
    owner.reapply_pending = not ok

    if ok then
        util.reset_retry(owner.retry)
        util.report_once(owner, "reported_error", nil)
    elseif packages_loading then
        util.defer_retry(owner.retry)
    else
        util.report_once(owner, "reported_error", tostring(err or loc("generic_unknown_error")), function(message)
            mod:warning("Companion look failed: %s", message)
        end)
    end

    return ok, err, packages_loading, tonumber(equipped) or 0, tonumber(failed) or 0
end

function live_visual.owners.apply(player, state)
    local owners = live_visual.owners
    local player_unit = safe_player_unit(player)

    if not player then
        return false, loc("error_no_target_player")
    elseif player == get_local_player() or player_unit ~= nil and player_unit == _bound_player_unit then
        return false, loc("error_target_is_local_player")
    elseif not visual_extension(player_unit) then
        return false, loc("error_visual_extension_missing")
    elseif not item_cache() then
        return false, loc("error_master_cache_not_ready")
    end

    local owner = owners.by_player[player]

    if not owner then
        owner = {
            player = player,
            originals = {},
            package_loads = {},
            pending_package_loads = {},
            managed_slots = {},
            retry = util.new_retry(0.1, 1, 1.6),
        }
        owners.by_player[player] = owner
        owners.count = owners.count + 1
    end

    owner.state = owners.normalize_state(state)
    util.reset_retry(owner.retry)

    return owners.equip(owner)
end

function live_visual.owners.clear(player, restore)
    local owners = live_visual.owners
    local owner = player and owners.by_player[player]

    if not owner then
        return true
    end

    local restored = true

    if restore ~= false and util.safe_unit_alive(owner.unit) then
        local call_ok, result = owners.run(owner, owners.restore_owner, owner)
        restored = call_ok and result == true

        -- Keep the originals and retry with an empty look until the bot is vanilla again.
        if not restored then
            owner.state = owners.normalize_state(nil)
            owner.reapply_pending = true
            util.reset_retry(owner.retry)

            return false
        end
    end

    owners.run(owner, owners.unbind_unit, owner)
    owners.by_player[player] = nil
    owners.count = math.max(owners.count - 1, 0)

    return restored
end

function live_visual.owners.release_all(restore)
    local players = table.keys(live_visual.owners.by_player)

    for i = 1, #players do
        if not live_visual.owners.clear(players[i], restore) then
            live_visual.owners.clear(players[i], false)
        end
    end

    table.clear(live_visual.owners.by_player)
    table.clear(live_visual.owners.by_unit)
    live_visual.owners.count = 0
end

-- Bots respawn with new units; owners follow them while their look is set.
function live_visual.owners.update(dt)
    local owners = live_visual.owners

    if owners.count == 0 then
        return
    end

    owners.poll_elapsed = owners.poll_elapsed + dt

    if owners.poll_elapsed < BINDING_POLL_INTERVAL then
        return
    end

    local elapsed = owners.poll_elapsed
    local ready = _game_state_ready and gameplay_time_manager() ~= nil and item_cache() ~= nil
    owners.poll_elapsed = 0

    for player, owner in pairs(owners.by_player) do
        local player_unit = safe_player_unit(player)
        local alive = util.safe_unit_alive(player_unit)

        if owner.unit ~= nil and (owner.unit ~= player_unit or not alive) then
            owners.run(owner, owners.unbind_unit, owner)
            owner.reapply_pending = true
            util.reset_retry(owner.retry)
        end

        if ready and alive and owner.reapply_pending and util.retry_due(owner.retry, elapsed) then
            local ok, _, packages_loading = owners.equip(owner)

            if ok and not live_visual.has_look_state(owner.state) then
                -- A cleared bot is vanilla again.
                owners.clear(player, false)
            elseif not ok and not packages_loading and util.record_attempt(owner.retry) then
                owner.reapply_pending = false
            end
        end
    end
end

local function best_items_per_slot(matches)
    local selected = {}
    local scores = {}
    local overflow_index = 1

    for i = 1, #matches do
        local match = matches[i]

        if not util.item_is_2d(match.item, match.name) then
            local slot_name = target_slot_for_item(match.item)

            if slot_name then
                local score = item_pref_score(match.name)
                local current_score = scores[slot_name]
                local replace = not selected[slot_name] or current_score == nil or score > current_score
                    or (score == current_score and #match.name < #selected[slot_name])

                if replace then
                    selected[slot_name] = match.name
                    scores[slot_name] = score
                end
            else
                while overflow_index <= #OVERFLOW_SLOTS and selected[OVERFLOW_SLOTS[overflow_index]] do
                    overflow_index = overflow_index + 1
                end

                if overflow_index <= #OVERFLOW_SLOTS then
                    local overflow_slot = OVERFLOW_SLOTS[overflow_index]
                    selected[overflow_slot] = match.name
                    scores[overflow_slot] = item_pref_score(match.name)
                    overflow_index = overflow_index + 1
                end
            end
        end
    end

    return selected
end

local function collect_outfit(preset_name)
    local preset = type(preset_name) == "string" and OUTFIT_PRESETS[string.lower(preset_name)]

    if not preset then
        return nil
    end

    local outfit = {}

    for slot_name, item_name in pairs(preset) do
        local item = item_definition(item_name)

        if item and not util.item_is_2d(item, item_name) then
            outfit[slot_name] = item_name
        end
    end

    return outfit, true
end

mod.npclook_item_cache = item_cache
mod.npclook_item_definition = item_definition

local STUDIO_SLOT_ORDER = {}
local studio_slot_seen = {}

for i = 1, #PREFERRED_LOOK_SLOT_ORDER do
    local slot_name = PREFERRED_LOOK_SLOT_ORDER[i]

    if LOOK_SLOTS[slot_name] and not studio_slot_seen[slot_name] then
        studio_slot_seen[slot_name] = true
        STUDIO_SLOT_ORDER[#STUDIO_SLOT_ORDER + 1] = slot_name
    end
end

local remaining_studio_slots = {}

for slot_name in pairs(LOOK_SLOTS) do
    if not studio_slot_seen[slot_name] then
        remaining_studio_slots[#remaining_studio_slots + 1] = slot_name
    end
end

table.sort(remaining_studio_slots)

for i = 1, #remaining_studio_slots do
    STUDIO_SLOT_ORDER[#STUDIO_SLOT_ORDER + 1] = remaining_studio_slots[i]
end

-- Look codes

local LOOK_CODE_PREFIX = "NPCL"
EXTRA_SLOTS.transform_default = {
    enabled = false,
    deform = true,
    first_person = false,
    animate_first_person = false,
    attach_node = nil,
    px = 0,
    py = 0,
    pz = 0,
    rx = 0,
    ry = 0,
    rz = 0,
    xyz_scale = false,
    scale = 1,
    scale_x = 1,
    scale_y = 1,
    scale_z = 1,
}

function EXTRA_SLOTS.finite_number(value, fallback)
    value = tonumber(value)

    if not value or value ~= value or value == math.huge or value == -math.huge then
        return fallback
    end

    return value
end

function EXTRA_SLOTS.normalize_attach_node(value)
    if type(value) == "string" then
        value = string.gsub(value, "[%c]", "")
        value = string.gsub(value, "^%s+", "")
        value = string.gsub(value, "%s+$", "")

        value = value ~= "" and string.sub(value, 1, 96) or nil

        if value and string.match(value, "^%d+$") then
            local index = tonumber(value)

            return index and index >= 1 and index or nil
        end

        return value
    elseif type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value >= 1 and value == math.floor(value) then
        return value
    end

    return nil
end

function EXTRA_SLOTS.normalize_transform(value)
    value = type(value) == "table" and value or EXTRA_SLOTS.transform_default

    local scale = math.clamp(EXTRA_SLOTS.finite_number(value.scale, 1), -30, 30)
    local xyz_scale = value.xyz_scale == true
    local scale_x = xyz_scale
        and math.clamp(EXTRA_SLOTS.finite_number(value.scale_x, scale), -30, 30) or scale
    local scale_y = xyz_scale
        and math.clamp(EXTRA_SLOTS.finite_number(value.scale_y, scale), -30, 30) or scale
    local scale_z = xyz_scale
        and math.clamp(EXTRA_SLOTS.finite_number(value.scale_z, scale), -30, 30) or scale

    local first_person = value.first_person == true

    return {
        enabled = value.enabled == true,
        deform = value.deform ~= false,
        first_person = first_person,
        animate_first_person = first_person and value.animate_first_person == true,
        attach_node = EXTRA_SLOTS.normalize_attach_node(value.attach_node),
        px = math.clamp(EXTRA_SLOTS.finite_number(value.px, 0), -5, 5),
        py = math.clamp(EXTRA_SLOTS.finite_number(value.py, 0), -5, 5),
        pz = math.clamp(EXTRA_SLOTS.finite_number(value.pz, 0), -5, 5),
        rx = math.clamp(EXTRA_SLOTS.finite_number(value.rx, 0), -180, 180),
        ry = math.clamp(EXTRA_SLOTS.finite_number(value.ry, 0), -180, 180),
        rz = math.clamp(EXTRA_SLOTS.finite_number(value.rz, 0), -180, 180),
        xyz_scale = xyz_scale,
        scale = scale,
        scale_x = scale_x,
        scale_y = scale_y,
        scale_z = scale_z,
        materials = EXTRA_SLOTS.normalize_materials(value),
    }
end

function EXTRA_SLOTS.transform_signature(value)
    local transform = EXTRA_SLOTS.normalize_transform(value)

    local signature = string.format(
        "%s,%s,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f",
        transform.enabled and "1" or "0",
        transform.deform and "1" or "0",
        transform.first_person and "1" or "0",
        transform.animate_first_person and "1" or "0",
        transform.xyz_scale and "1" or "0",
        tostring(transform.attach_node or ""),
        transform.px, transform.py, transform.pz,
        transform.rx, transform.ry, transform.rz,
        transform.scale, transform.scale_x, transform.scale_y, transform.scale_z
    )

    return signature .. "|" .. table.concat(transform.materials, "|")
end

function EXTRA_SLOTS.clone_transforms(source, anchors)
    local result = {}

    for id in pairs(anchors or source or {}) do
        if type(id) == "string" and string.match(id, "^extra_%d+$") then
            result[id] = EXTRA_SLOTS.normalize_transform(source and source[id])
        end
    end

    return result
end

function EXTRA_SLOTS.same_transforms(left, right, anchors)
    local ids = {}

    for id in pairs(anchors or {}) do
        ids[id] = true
    end

    for id in pairs(left or {}) do
        ids[id] = true
    end

    for id in pairs(right or {}) do
        ids[id] = true
    end

    for id in pairs(ids) do
        if EXTRA_SLOTS.transform_signature(left and left[id]) ~= EXTRA_SLOTS.transform_signature(right and right[id]) then
            return false
        end
    end

    return true
end

function EXTRA_SLOTS.restore_transforms(destination, snapshot, anchors)
    table.clear(destination)

    for id in pairs(anchors or snapshot or {}) do
        destination[id] = EXTRA_SLOTS.normalize_transform(snapshot and snapshot[id])
    end
end

function EXTRA_SLOTS.format_transform_number(value)
    local formatted = string.format("%.4f", EXTRA_SLOTS.finite_number(value, 0))
    formatted = string.gsub(formatted, "0+$", "")
    formatted = string.gsub(formatted, "%.$", "")

    return formatted == "-0" and "0" or formatted
end
local LOOK_METADATA_FIELDS = {
    "archetype",
    "breed",
    "gender",
    "body_type",
    "selected_voice",
    "height",
}
local LOOK_METADATA_FIELD_SET = table.set(LOOK_METADATA_FIELDS)

local function has_look_code_prefix(value)
    return value == LOOK_CODE_PREFIX
        or string.sub(value, 1, #LOOK_CODE_PREFIX + 1) == LOOK_CODE_PREFIX .. "|"
end

local function encode_look_token(value)
    return (tostring(value or ""):gsub("([^%w_./%-])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function decode_look_token(value)
    if type(value) ~= "string" then
        return nil
    end

    local search_from = 1

    while true do
        local percent = string.find(value, "%", search_from, true)

        if not percent then
            break
        end

        local hex = string.sub(value, percent + 1, percent + 2)

        if #hex ~= 2 or not string.match(hex, "^%x%x$") then
            return nil
        end

        search_from = percent + 3
    end

    return (string.gsub(value, "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function normalize_look_code(value)
    value = type(value) == "string" and value or ""
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    value = string.gsub(value, "^/npclook_load%s+", "")
    value = string.gsub(value, "^/npclook_import%s+", "")

    if string.sub(value, 1, 1) == '"' and string.sub(value, -1) == '"' then
        value = string.sub(value, 2, -2)
    end

    return value
end

local function look_metadata(player)
    local profile = safe_profile(player or get_local_player()) or {}
    local archetype = type(profile.archetype) == "table" and profile.archetype or {}
    local metadata = {}
    local candidates = {
        archetype = archetype.name,
        breed = archetype.breed,
        gender = profile.gender,
        body_type = profile.body_type,
        selected_voice = profile.selected_voice,
        height = profile.height,
    }

    for i = 1, #LOOK_METADATA_FIELDS do
        local key = LOOK_METADATA_FIELDS[i]
        local value = candidates[key]
        local value_type = type(value)

        if value_type == "string" or value_type == "number" or value_type == "boolean" then
            metadata[key] = tostring(value)
        end
    end

    return metadata
end

local function encode_look_code(applied, suppressed, empty, metadata, extra_anchors, extra_transforms, materials, variants, masks, opacity, meshes)
    local segments = { LOOK_CODE_PREFIX }
    local metadata_keys = table.keys(metadata or {})

    table.sort(metadata_keys)

    for i = 1, #metadata_keys do
        local key = metadata_keys[i]
        segments[#segments + 1] = "M:" .. encode_look_token(key) .. "=" .. encode_look_token(metadata[key])
    end

    for i = 1, #STUDIO_SLOT_ORDER do
        local slot_name = STUDIO_SLOT_ORDER[i]

        if suppressed and suppressed[slot_name] == true then
            segments[#segments + 1] = "H:" .. encode_look_token(slot_name)
        elseif empty and empty[slot_name] == true then
            segments[#segments + 1] = "E:" .. encode_look_token(slot_name)
        else
            local item_name = applied and applied[slot_name]

            if type(item_name) == "string" and item_name ~= "" then
                segments[#segments + 1] = "I:" .. encode_look_token(slot_name) .. "=" .. encode_look_token(item_name)
            else
                segments[#segments + 1] = "E:" .. encode_look_token(slot_name)
            end
        end
    end

    for i = 1, #STUDIO_SLOT_ORDER do
        local slot_name = STUDIO_SLOT_ORDER[i]
        local slot_materials = EXTRA_SLOTS.normalize_materials(materials and materials[slot_name])

        if #slot_materials > 0 then
            local segment = "Y:" .. encode_look_token(slot_name) .. "="

            for j = 1, #slot_materials do
                segment = segment .. (j > 1 and "," or "") .. encode_look_token(slot_materials[j])
            end

            segments[#segments + 1] = segment
        end
    end

    for _, id in ipairs(EXTRA_SLOTS.ids(extra_anchors)) do
        local anchor = extra_anchors[id]
        local item_name = type(applied and applied[id]) == "string" and applied[id] or ""
        local state = suppressed and suppressed[id] and "H" or empty and empty[id] and "E" or item_name ~= "" and "I" or "E"
        local transform = EXTRA_SLOTS.normalize_transform(extra_transforms and extra_transforms[id])
        segments[#segments + 1] = "X:" .. encode_look_token(id)
            .. "=" .. encode_look_token(anchor) .. "," .. state .. "," .. encode_look_token(item_name)
            .. "," .. (transform.enabled and "1" or "0")
            .. "," .. (transform.deform and "1" or "0")
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.px)
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.py)
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.pz)
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.rx)
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.ry)
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.rz)
            .. "," .. EXTRA_SLOTS.format_transform_number(transform.scale)

        if transform.first_person then
            segments[#segments] = segments[#segments] .. ",@1p:1"
        end

        if transform.animate_first_person then
            segments[#segments] = segments[#segments] .. ",@1pa:1"
        end

        if transform.xyz_scale then
            segments[#segments] = segments[#segments]
                .. ",@xyz:" .. EXTRA_SLOTS.format_transform_number(transform.scale_x)
                .. ":" .. EXTRA_SLOTS.format_transform_number(transform.scale_y)
                .. ":" .. EXTRA_SLOTS.format_transform_number(transform.scale_z)
        end

        if transform.attach_node then
            segments[#segments] = segments[#segments]
                .. ",@node:" .. encode_look_token(transform.attach_node)
        end

        for i = 1, #transform.materials do
            segments[#segments] = segments[#segments] .. "," .. encode_look_token(transform.materials[i])
        end
    end

    local opacity_slots = table.keys(opacity or {})
    table.sort(opacity_slots)

    for i = 1, #opacity_slots do
        local slot_name = opacity_slots[i]
        local value = util.normalize_opacity(opacity[slot_name])
        local valid_slot = valid_look_slot(slot_name)
            or type(extra_anchors and extra_anchors[slot_name]) == "string"

        if valid_slot and value ~= util.opacity_default then
            segments[#segments + 1] = "O:" .. encode_look_token(slot_name)
                .. "=" .. tostring(value)
        end
    end

    local variant_slots = table.keys(variants or {})
    table.sort(variant_slots)

    for i = 1, #variant_slots do
        local slot_name = variant_slots[i]
        local item_name = type(applied and applied[slot_name]) == "string" and applied[slot_name] or nil
        local valid_slot = valid_look_slot(slot_name) or type(extra_anchors and extra_anchors[slot_name]) == "string"
        local state_value = valid_slot and item_name
            and RAW_UNITS.normalize_variant_state(variants[slot_name], item_name) or nil

        if state_value then
            local family_names = table.keys(state_value.families)
            local group_names = table.keys(state_value.visibility)
            table.sort(family_names)
            table.sort(group_names)

            for family_index = 1, #family_names do
                local family_name = family_names[family_index]
                segments[#segments + 1] = "F:" .. encode_look_token(slot_name)
                    .. "=" .. encode_look_token(item_name)
                    .. "," .. encode_look_token(family_name)
                    .. "," .. encode_look_token(state_value.families[family_name])
            end

            for group_index = 1, #group_names do
                local group_name = group_names[group_index]
                segments[#segments + 1] = "G:" .. encode_look_token(slot_name)
                    .. "=" .. encode_look_token(item_name)
                    .. "," .. encode_look_token(group_name)
                    .. "," .. (state_value.visibility[group_name] and "1" or "0")
            end
        end
    end

    local mask_slots = table.keys(masks or {})
    table.sort(mask_slots)

    for i = 1, #mask_slots do
        local slot_name = mask_slots[i]
        local item_name = valid_look_slot(slot_name)
            and type(applied and applied[slot_name]) == "string" and applied[slot_name] or nil
        local state_value = item_name and MASKS.normalize_state(masks[slot_name], item_name) or nil
        local field_names = state_value and table.keys(state_value.fields) or {}
        table.sort(field_names)

        for field_index = 1, #field_names do
            local field_name = field_names[field_index]
            local field_value = state_value.fields[field_name]
            local encoded_value

            if type(field_value) == "boolean" then
                encoded_value = field_value and "b1" or "b0"
            elseif type(field_value) == "string" and field_value ~= "" then
                encoded_value = "s:" .. encode_look_token(field_value)
            end

            if encoded_value then
                segments[#segments + 1] = "K:" .. encode_look_token(slot_name)
                    .. "=" .. encode_look_token(item_name)
                    .. "," .. encode_look_token(field_name)
                    .. "," .. encoded_value
            end
        end
    end

    local mesh_slots = table.keys(meshes or {})
    table.sort(mesh_slots)

    for i = 1, #mesh_slots do
        local slot_name = mesh_slots[i]
        local item_name = type(applied and applied[slot_name]) == "string" and applied[slot_name] or nil
        local valid_slot = valid_look_slot(slot_name) or type(extra_anchors and extra_anchors[slot_name]) == "string"

        -- Inherited native pieces keep their own item name.
        if not item_name and valid_look_slot(slot_name) and type(meshes[slot_name]) == "table" then
            item_name = type(meshes[slot_name].item_name) == "string" and meshes[slot_name].item_name or nil
        end

        local state_value = valid_slot and item_name and MESHES.normalize_state(meshes[slot_name], item_name) or nil

        if state_value then
            local prefix = "W:" .. encode_look_token(slot_name) .. "=" .. encode_look_token(item_name)
            local hidden_keys = table.keys(state_value.hidden)
            local material_keys = table.keys(state_value.materials)
            table.sort(hidden_keys)
            table.sort(material_keys)

            -- Hidden meshes share one segment per slot.
            if #hidden_keys > 0 then
                local segment = prefix .. ",h"

                for key_index = 1, #hidden_keys do
                    segment = segment .. "," .. encode_look_token(hidden_keys[key_index])
                end

                segments[#segments + 1] = segment
            end

            for key_index = 1, #material_keys do
                local key = material_keys[key_index]
                local segment = prefix .. ",m," .. encode_look_token(key)

                for entry_index = 1, #state_value.materials[key] do
                    segment = segment .. "," .. encode_look_token(state_value.materials[key][entry_index])
                end

                segments[#segments + 1] = segment
            end
        end
    end

    return table.concat(segments, "|")
end

local function decode_look_code(value)
    local code = normalize_look_code(value)

    if code == "" then
        return nil, nil, nil, loc("error_code_empty")
    elseif string.find(code, "||", 1, true) or string.sub(code, -1) == "|" then
        return nil, nil, nil, loc("error_code_malformed")
    end

    local cache = item_cache()

    if not cache then
        return nil, nil, nil, loc("error_master_cache_not_ready")
    end

    local applied = {}
    local suppressed = {}
    local empty = {}
    local metadata = {}
    local extra_anchors = {}
    local extra_transforms = {}
    local materials = {}
    local variants = {}
    local masks = {}
    local opacity = {}
    local meshes = {}
    local seen_mesh_keys = {}
    local count = 0
    local segment_count = 0
    local first = true
    local seen_slots = {}
    local seen_material_slots = {}
    local seen_variant_families = {}
    local seen_variant_groups = {}
    local seen_mask_fields = {}
    local seen_opacity_slots = {}
    local seen_metadata = {}

    for segment in string.gmatch(code, "[^|]+") do
        segment_count = segment_count + 1

        if segment_count > 1 + #STUDIO_SLOT_ORDER * 2 + #LOOK_METADATA_FIELDS + 4096 then
            return nil, nil, nil, loc("error_code_too_many")
        end

        if first then
            first = false
            if segment ~= LOOK_CODE_PREFIX then
                return nil, nil, nil, loc("error_code_version")
            end
        else
            local kind = string.sub(segment, 1, 2)
            local payload = string.sub(segment, 3)

            if kind == "M:" then
                local separator = string.find(payload, "=", 1, true)

                if not separator then
                    return nil, nil, nil, loc("error_code_metadata")
                end

                local key = decode_look_token(string.sub(payload, 1, separator - 1))
                local metadata_value = decode_look_token(string.sub(payload, separator + 1))

                if not key or not LOOK_METADATA_FIELD_SET[key] or metadata_value == nil then
                    return nil, nil, nil, loc("error_code_metadata_invalid")
                elseif seen_metadata[key] then
                    return nil, nil, nil, loc("error_code_duplicate", key)
                end

                seen_metadata[key] = true
                metadata[key] = metadata_value
            elseif kind == "H:" or kind == "E:" then
                local slot_name = decode_look_token(payload)

                if not slot_name or not valid_look_slot(slot_name) then
                    return nil, nil, nil, loc("error_code_slot")
                elseif seen_slots[slot_name] then
                    return nil, nil, nil, loc("error_code_duplicate", slot_name)
                end

                seen_slots[slot_name] = true

                if kind == "H:" then
                    suppressed[slot_name] = true
                else
                    empty[slot_name] = true
                end

                count = count + 1
            elseif kind == "I:" then
                local separator = string.find(payload, "=", 1, true)

                if not separator then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local slot_name = decode_look_token(string.sub(payload, 1, separator - 1))
                local item_name = decode_look_token(string.sub(payload, separator + 1))
                local item, normalized_item_name = item_definition(item_name)

                if not slot_name or not valid_look_slot(slot_name) then
                    return nil, nil, nil, loc("error_code_slot")
                elseif not item_name or not item then
                    return nil, nil, nil, loc("error_code_missing_item", tostring(item_name or loc("error_code_invalid_encoding")))
                elseif seen_slots[slot_name] then
                    return nil, nil, nil, loc("error_code_duplicate", slot_name)
                end

                seen_slots[slot_name] = true
                applied[slot_name] = normalized_item_name or item_name
                count = count + 1
            elseif kind == "Y:" then
                local equals = string.find(payload, "=", 1, true)

                if not equals then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local slot_name = decode_look_token(string.sub(payload, 1, equals - 1))
                local material_payload = string.sub(payload, equals + 1)
                local slot_materials = {}

                if not slot_name or not valid_look_slot(slot_name) then
                    return nil, nil, nil, loc("error_code_slot")
                elseif seen_material_slots[slot_name] then
                    return nil, nil, nil, loc("error_code_duplicate", slot_name)
                end

                for encoded_material in string.gmatch(material_payload .. ",", "(.-),") do
                    local material_entry = decode_look_token(encoded_material)
                    local material_name, material_target = EXTRA_SLOTS.material_entry_parts(material_entry)
                    local material_item = material_name and EXTRA_SLOTS.material_override_item(cache, material_name)

                    if not material_item or not EXTRA_SLOTS.is_material_override_item(material_item) then
                        return nil, nil, nil, loc("error_code_missing_item", tostring(material_name or loc("error_code_invalid_encoding")))
                    end

                    slot_materials[#slot_materials + 1] = EXTRA_SLOTS.material_entry(material_name, material_target)
                end

                if #slot_materials == 0 or #slot_materials > 32 then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                seen_material_slots[slot_name] = true
                materials[slot_name] = EXTRA_SLOTS.normalize_materials(slot_materials)
            elseif kind == "X:" then
                local equals = string.find(payload, "=", 1, true)

                if not equals then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local fields = {}
                local field_payload = string.sub(payload, equals + 1)

                for field in string.gmatch(field_payload .. ",", "(.-),") do
                    fields[#fields + 1] = field
                end

                if #fields ~= 3 and #fields ~= 10 and #fields ~= 11 and #fields < 12 then
                    return nil, nil, nil, loc("error_code_item_entry")
                elseif #fields > 45 then
                    return nil, nil, nil, loc("error_code_too_many")
                end

                local id = decode_look_token(string.sub(payload, 1, equals - 1))
                local anchor = decode_look_token(fields[1])
                local state = fields[2]
                local item_name = decode_look_token(fields[3])
                local transform

                if #fields >= 12 then
                    if (fields[4] ~= "0" and fields[4] ~= "1")
                        or (fields[5] ~= "0" and fields[5] ~= "1") then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    for i = 6, 12 do
                        if EXTRA_SLOTS.finite_number(fields[i], nil) == nil then
                            return nil, nil, nil, loc("error_code_item_entry")
                        end
                    end

                    local materials = {}
                    local attach_node
                    local first_person = false
                    local animate_first_person = false
                    local xyz_scale = false
                    local scale_x
                    local scale_y
                    local scale_z

                    for i = 13, #fields do
                        if fields[i] == "@1p:1" then
                            first_person = true
                        elseif fields[i] == "@1pa:1" then
                            animate_first_person = true
                        elseif string.sub(fields[i], 1, 5) == "@xyz:" then
                            if xyz_scale then
                                return nil, nil, nil, loc("error_code_item_entry")
                            end

                            local x, y, z = string.match(fields[i], "^@xyz:([^:]+):([^:]+):([^:]+)$")

                            if EXTRA_SLOTS.finite_number(x, nil) == nil
                                or EXTRA_SLOTS.finite_number(y, nil) == nil
                                or EXTRA_SLOTS.finite_number(z, nil) == nil then
                                return nil, nil, nil, loc("error_code_item_entry")
                            end

                            xyz_scale = true
                            scale_x = x
                            scale_y = y
                            scale_z = z
                        elseif string.sub(fields[i], 1, 6) == "@node:" then
                            if attach_node ~= nil then
                                return nil, nil, nil, loc("error_code_item_entry")
                            end

                            attach_node = EXTRA_SLOTS.normalize_attach_node(
                                decode_look_token(string.sub(fields[i], 7))
                            )

                            if not attach_node then
                                return nil, nil, nil, loc("error_code_item_entry")
                            end
                        else
                            local material_entry = decode_look_token(fields[i])
                            local material_name, material_target = EXTRA_SLOTS.material_entry_parts(material_entry)
                            local material_item = material_name and EXTRA_SLOTS.material_override_item(cache, material_name)

                            if not material_item or not EXTRA_SLOTS.is_material_override_item(material_item) then
                                return nil, nil, nil, loc(
                                    "error_code_missing_item",
                                    tostring(material_name or loc("error_code_invalid_encoding"))
                                )
                            end

                            materials[#materials + 1] = EXTRA_SLOTS.material_entry(material_name, material_target)
                        end
                    end

                    transform = EXTRA_SLOTS.normalize_transform({
                        enabled = fields[4] == "1",
                        deform = fields[5] == "1",
                        first_person = first_person,
                        animate_first_person = animate_first_person,
                        attach_node = attach_node,
                        px = fields[6], py = fields[7], pz = fields[8],
                        rx = fields[9], ry = fields[10], rz = fields[11], scale = fields[12],
                        xyz_scale = xyz_scale,
                        scale_x = scale_x or fields[12],
                        scale_y = scale_y or fields[12],
                        scale_z = scale_z or fields[12],
                        materials = materials,
                    })
                elseif #fields == 11 then
                    if fields[4] ~= "0" and fields[4] ~= "1" then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    for i = 5, 11 do
                        if EXTRA_SLOTS.finite_number(fields[i], nil) == nil then
                            return nil, nil, nil, loc("error_code_item_entry")
                        end
                    end

                    transform = EXTRA_SLOTS.normalize_transform({
                        enabled = fields[4] == "1",
                        -- Legacy 11-field look codes used the rigid root-link mode.
                        deform = false,
                        px = fields[5], py = fields[6], pz = fields[7],
                        rx = fields[8], ry = fields[9], rz = fields[10], scale = fields[11],
                    })
                elseif #fields == 10 then
                    for i = 4, 10 do
                        if EXTRA_SLOTS.finite_number(fields[i], nil) == nil then
                            return nil, nil, nil, loc("error_code_item_entry")
                        end
                    end

                    -- Legacy 10-field look codes always used the rigid transform mode.
                    transform = EXTRA_SLOTS.normalize_transform({
                        enabled = true,
                        deform = false,
                        px = fields[4], py = fields[5], pz = fields[6],
                        rx = fields[7], ry = fields[8], rz = fields[9], scale = fields[10],
                    })
                else
                    transform = EXTRA_SLOTS.normalize_transform(nil)
                end

                local item, normalized_item_name

                if item_name and item_name ~= "" then
                    item, normalized_item_name = item_definition(item_name)
                end

                if not id or not string.match(id, "^extra_%d+$") or not valid_look_slot(anchor) then
                    return nil, nil, nil, loc("error_code_slot")
                elseif seen_slots[id] then
                    return nil, nil, nil, loc("error_code_duplicate", id)
                elseif state ~= "I" and state ~= "H" and state ~= "E" then
                    return nil, nil, nil, loc("error_code_item_entry")
                elseif item_name == nil or (item_name ~= "" and not item) then
                    return nil, nil, nil, loc("error_code_missing_item", tostring(item_name or loc("error_code_invalid_encoding")))
                elseif (state == "I" and item_name == "") or (state ~= "I" and item_name ~= "") then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                seen_slots[id] = true
                extra_anchors[id] = anchor
                extra_transforms[id] = transform

                if state == "I" then
                    applied[id] = normalized_item_name or item_name
                elseif state == "H" then
                    suppressed[id] = true
                else
                    empty[id] = true
                end

                count = count + 1
            elseif kind == "O:" then
                local equals = string.find(payload, "=", 1, true)

                if not equals then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local slot_name = decode_look_token(string.sub(payload, 1, equals - 1))
                local raw_value = tonumber(string.sub(payload, equals + 1))
                local valid_slot = slot_name and (valid_look_slot(slot_name)
                    or string.match(slot_name, "^extra_%d+$"))

                if not valid_slot or raw_value == nil or raw_value ~= math.floor(raw_value)
                    or raw_value < 0 or raw_value > util.opacity_default then
                    return nil, nil, nil, loc("error_code_item_entry")
                elseif seen_opacity_slots[slot_name] then
                    return nil, nil, nil, loc("error_code_duplicate", slot_name)
                end

                seen_opacity_slots[slot_name] = true

                if raw_value ~= util.opacity_default then
                    opacity[slot_name] = raw_value
                end
            elseif kind == "F:" or kind == "G:" then
                local equals = string.find(payload, "=", 1, true)

                if not equals then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local slot_name = decode_look_token(string.sub(payload, 1, equals - 1))
                local fields = {}

                for field in string.gmatch(string.sub(payload, equals + 1) .. ",", "(.-),") do
                    fields[#fields + 1] = field
                end

                if #fields ~= 3 then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local item_name = decode_look_token(fields[1])
                local key_name = decode_look_token(fields[2])
                local setting_value = kind == "F:" and decode_look_token(fields[3]) or fields[3]
                local valid_slot = slot_name and (valid_look_slot(slot_name) or string.match(slot_name, "^extra_%d+$"))
                local item, normalized_item_name = item_definition(item_name)

                if not valid_slot or not item_name or not item or item.npclook_raw_unit ~= true
                    or not key_name or key_name == "" or setting_value == nil then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                item_name = normalized_item_name or item_name
                local state_value = variants[slot_name]

                if not state_value then
                    state_value = RAW_UNITS.normalize_variant_state(nil, item_name)
                    variants[slot_name] = state_value
                elseif state_value.item_name ~= item_name then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                if kind == "F:" then
                    local duplicate_key = slot_name .. "\31" .. key_name
                    local family_found = false
                    local option_found = false

                    if seen_variant_families[duplicate_key] then
                        return nil, nil, nil, loc("error_code_duplicate", key_name)
                    end

                    for _, family in ipairs(item.npclook_raw_variant_families or {}) do
                        if tostring(family.name or "") == key_name then
                            family_found = true

                            for _, option in ipairs(family.options or {}) do
                                if tostring(type(option) == "table" and option.name or option) == setting_value then
                                    option_found = true
                                    break
                                end
                            end

                            break
                        end
                    end

                    if not family_found or not option_found then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    seen_variant_families[duplicate_key] = true
                    state_value.families[key_name] = setting_value
                else
                    local duplicate_key = slot_name .. "\31" .. key_name
                    local group_found = false

                    if seen_variant_groups[duplicate_key] or (setting_value ~= "0" and setting_value ~= "1") then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    for _, group in ipairs(item.npclook_raw_visibility_groups or {}) do
                        if tostring(type(group) == "table" and group.name or group) == key_name then
                            group_found = true
                            break
                        end
                    end

                    if not group_found then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    seen_variant_groups[duplicate_key] = true
                    state_value.visibility[key_name] = setting_value == "1"
                end
            elseif kind == "K:" then
                local equals = string.find(payload, "=", 1, true)

                if not equals then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local slot_name = decode_look_token(string.sub(payload, 1, equals - 1))
                local fields = {}

                for field in string.gmatch(string.sub(payload, equals + 1) .. ",", "(.-),") do
                    fields[#fields + 1] = field
                end

                if #fields ~= 2 and #fields ~= 3 then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                if not EXTRA_SLOTS.is_slot(slot_name, extra_anchors) then
                    local item_name = decode_look_token(fields[1])
                    local field_name = decode_look_token(fields[2])
                    local setting_value = fields[3] or "0"
                    local valid_slot = valid_look_slot(slot_name)
                    local mask_slot = slot_name
                    local item, normalized_item_name = item_definition(item_name)
                    local available = item and MASKS.available_fields(item, cache, mask_slot) or {}
                    local field_found = false

                    for i = 1, #available do
                        if available[i] == field_name then
                            field_found = true
                            break
                        end
                    end

                    local duplicate_key = tostring(slot_name) .. "\31" .. tostring(field_name)
                    local decoded_value
                    local authored = false

                    if setting_value == "0" or setting_value == "b0" then
                        decoded_value = false
                    elseif setting_value == "1" then
                        authored = true
                    elseif setting_value == "b1" then
                        decoded_value = true
                    elseif string.sub(setting_value, 1, 2) == "s:" then
                        decoded_value = decode_look_token(string.sub(setting_value, 3))
                    else
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    if not valid_slot or not item or not field_found or seen_mask_fields[duplicate_key]
                        or (not authored and not MASKS.option_matches(field_name, decoded_value, item, cache, mask_slot)) then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    item_name = normalized_item_name or item_name
                    local state_value = masks[slot_name]

                    if state_value and state_value.item_name ~= item_name then
                        return nil, nil, nil, loc("error_code_item_entry")
                    end

                    state_value = state_value or MASKS.normalize_state(nil, item_name, available)
                    state_value.fields[field_name] = authored and nil or decoded_value
                    masks[slot_name] = next(state_value.fields) and state_value or nil
                    seen_mask_fields[duplicate_key] = true
                end
            elseif kind == "W:" then
                local equals = string.find(payload, "=", 1, true)

                if not equals then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                local slot_name = decode_look_token(string.sub(payload, 1, equals - 1))
                local fields = {}

                for field in string.gmatch(string.sub(payload, equals + 1) .. ",", "(.-),") do
                    fields[#fields + 1] = field
                end

                local item_name = decode_look_token(fields[1])
                local mode = fields[2]
                local key = decode_look_token(fields[3])
                local valid_slot = slot_name and (valid_look_slot(slot_name) or string.match(slot_name, "^extra_%d+$"))
                local item, normalized_item_name = item_definition(item_name)
                local duplicate_key = tostring(slot_name) .. "\31" .. tostring(mode)
                    .. (mode == "m" and "\31" .. tostring(key) or "")

                if not valid_slot or not item or not MESHES.valid_key(key) or seen_mesh_keys[duplicate_key]
                    or (mode == "h" and #fields > 258) or (mode == "m" and (#fields < 4 or #fields > 35))
                    or (mode ~= "h" and mode ~= "m") then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                item_name = normalized_item_name or item_name

                local state_value = meshes[slot_name]

                if state_value and state_value.item_name ~= item_name then
                    return nil, nil, nil, loc("error_code_item_entry")
                end

                state_value = state_value or { item_name = item_name, hidden = {}, materials = {} }

                if mode == "h" then
                    for field_index = 3, #fields do
                        local hidden_key = decode_look_token(fields[field_index])

                        if not MESHES.valid_key(hidden_key) then
                            return nil, nil, nil, loc("error_code_item_entry")
                        end

                        state_value.hidden[hidden_key] = true
                    end
                else
                    local entries = {}

                    for field_index = 4, #fields do
                        local material_entry = decode_look_token(fields[field_index])
                        local material_name, material_target = EXTRA_SLOTS.material_entry_parts(material_entry)
                        local material_item = material_name and EXTRA_SLOTS.material_override_item(cache, material_name)

                        if not material_item or not EXTRA_SLOTS.is_material_override_item(material_item) then
                            return nil, nil, nil, loc("error_code_missing_item", tostring(material_name or loc("error_code_invalid_encoding")))
                        end

                        entries[#entries + 1] = EXTRA_SLOTS.material_entry(material_name, material_target)
                    end

                    state_value.materials[key] = entries
                end

                seen_mesh_keys[duplicate_key] = true
                meshes[slot_name] = state_value
            else
                return nil, nil, nil, loc("error_code_unknown_entry")
            end
        end

        if count > #STUDIO_SLOT_ORDER + 512 then
            return nil, nil, nil, loc("error_code_too_many")
        end
    end

    if first then
        return nil, nil, nil, loc("error_code_empty")
    end

    for slot_name in pairs(masks) do
        if extra_anchors[slot_name] then
            masks[slot_name] = nil
        end
    end

    for slot_name, state_value in pairs(variants) do
        if not valid_look_slot(slot_name) and not extra_anchors[slot_name] then
            return nil, nil, nil, loc("error_code_slot")
        elseif applied[slot_name] ~= state_value.item_name then
            return nil, nil, nil, loc("error_code_item_entry")
        end
    end

    for slot_name, state_value in pairs(masks) do
        if not valid_look_slot(slot_name) and not extra_anchors[slot_name] then
            return nil, nil, nil, loc("error_code_slot")
        elseif applied[slot_name] ~= state_value.item_name then
            return nil, nil, nil, loc("error_code_item_entry")
        end
    end

    for slot_name in pairs(opacity) do
        if not valid_look_slot(slot_name) and not extra_anchors[slot_name] then
            return nil, nil, nil, loc("error_code_slot")
        end
    end

    for slot_name, state_value in pairs(meshes) do
        if not valid_look_slot(slot_name) and not extra_anchors[slot_name] then
            return nil, nil, nil, loc("error_code_slot")
        elseif applied[slot_name] ~= state_value.item_name
            and (applied[slot_name] ~= nil or not valid_look_slot(slot_name)) then
            return nil, nil, nil, loc("error_code_item_entry")
        end

        meshes[slot_name] = MESHES.normalize_state(state_value, state_value.item_name)
    end

    return applied, suppressed, empty, count, metadata, extra_anchors, extra_transforms, materials, variants, masks, opacity, meshes
end

-- Player presets

local PLAYER_PRESETS = mod:io_dofile("NPCLook/scripts/mods/NPCLook/npclook_presets").new({
    mod = mod,
    disk = _disk,
    loc = loc,
    has_look_code_prefix = has_look_code_prefix,
})

PLAYER_PRESETS.initialize()

local STUDIO_SLOT_LABELS = {
    slot_gear_head = loc("slot_head"),
    slot_body_face = loc("slot_face"),
    slot_body_hair = loc("slot_hair"),
    slot_body_hair_color = loc("slot_hair_color"),
    slot_body_face_hair = loc("slot_facial_hair"),
    slot_body_face_hair_color = loc("slot_facial_hair_color"),
    slot_body_face_tattoo = loc("slot_face_tattoo"),
    slot_body_face_scar = loc("slot_face_scar"),
    slot_body_face_makeup = loc("slot_makeup"),
    slot_body_eye_color = loc("slot_eyes"),
    slot_body_eye_color_secondary = loc("slot_secondary_eyes"),
    slot_body_skin_color = loc("slot_skin"),
    slot_body_skin_color_secondary = loc("slot_secondary_skin"),
    slot_body_skin_discoloration = loc("slot_skin_detail"),
    slot_gear_upperbody = loc("slot_upperbody"),
    slot_body_torso = loc("slot_torso_base"),
    slot_body_arms = loc("slot_arms"),
    slot_gear_lowerbody = loc("slot_lowerbody"),
    slot_body_legs = loc("slot_legs_base"),
    slot_body_tattoo = loc("slot_body_aux"),
    slot_gear_extra_cosmetic = loc("slot_gear_aux"),
    slot_gear_material_override_decal = loc("slot_material_decal"),
}

for slot_name in pairs(LOOK_SLOTS) do
    if not STUDIO_SLOT_LABELS[slot_name] then
        STUDIO_SLOT_LABELS[slot_name] = loc("slot_unmapped", slot_name)
    end
end

local CAMERA_FOCUS_LABELS = {
    full = loc("ui_camera_full"),
    head = loc("ui_camera_head"),
    torso = loc("ui_camera_torso"),
    legs = loc("ui_camera_legs"),
}

local LIBRARY_MODE_LABELS = {
    all = loc("ui_mode_all"),
    slot = loc("ui_mode_slot"),
    units = loc("ui_mode_units"),
    materials = loc("ui_mode_materials"),
    nodes = loc("ui_mode_nodes"),
    assets = loc("ui_mode_assets"),
}

local function clone_string_map(source)
    local result = {}

    for key, value in pairs(source or {}) do
        result[key] = value
    end

    return result
end

function EXTRA_SLOTS.ids(anchors)
    local ids = {}

    for id, anchor in pairs(anchors or {}) do
        if type(id) == "string" and valid_look_slot(anchor) then
            ids[#ids + 1] = id
        end
    end

    table.sort(ids, function(left, right)
        return (tonumber(string.match(left, "(%d+)$")) or 0) < (tonumber(string.match(right, "(%d+)$")) or 0)
    end)

    return ids
end

function EXTRA_SLOTS.is_slot(slot_name, anchors)
    return type(slot_name) == "string" and valid_look_slot(anchors and anchors[slot_name])
end

function EXTRA_SLOTS.anchor(slot_name, anchors)
    return EXTRA_SLOTS.is_slot(slot_name, anchors) and anchors[slot_name] or slot_name
end

function EXTRA_SLOTS.next_id(anchors)
    local highest = 0

    for id in pairs(anchors or {}) do
        highest = math.max(highest, tonumber(string.match(id, "^extra_(%d+)$")) or 0)
    end

    return string.format("extra_%06d", highest + 1)
end

function EXTRA_SLOTS.slot_order(anchors)
    local order = {}

    for i = 1, #STUDIO_SLOT_ORDER do
        order[#order + 1] = STUDIO_SLOT_ORDER[i]
    end

    for _, id in ipairs(EXTRA_SLOTS.ids(anchors)) do
        order[#order + 1] = id
    end

    return order
end

function EXTRA_SLOTS.label(slot_name, anchors)
    local anchor = anchors and anchors[slot_name]

    if not anchor then
        return STUDIO_SLOT_LABELS[slot_name] or slot_name
    end

    local index = 0

    for _, id in ipairs(EXTRA_SLOTS.ids(anchors)) do
        if anchors[id] == anchor then
            index = index + 1

            if id == slot_name then
                break
            end
        end
    end

    return string.format("%s +%d", STUDIO_SLOT_LABELS[anchor] or anchor, index)
end

local function profile_matches_active_character(profile)
    local local_profile = safe_profile(get_local_player())
    local character_id = local_profile and local_profile.character_id or _look_state.character_id

    return character_id and profile and profile.character_id == character_id
end

local function same_string_map(left, right)
    if rawequal(left, right) then
        return true
    end

    for key, value in pairs(left or {}) do
        if right == nil or right[key] ~= value then
            return false
        end
    end

    for key, value in pairs(right or {}) do
        if left == nil or left[key] ~= value then
            return false
        end
    end

    return true
end

local function restore_string_map(destination, snapshot)
    table.clear(destination)

    for key, value in pairs(snapshot or {}) do
        destination[key] = value
    end
end

local function current_look_state(player)
    player = player or get_local_player()

    if not player then
        return nil, nil, nil, nil, nil, nil, loc("error_no_local_player")
    end

    local profile = safe_profile(player) or {}
    local profile_loadout = type(profile.loadout) == "table" and profile.loadout or {}
    local visual_loadout = type(profile.visual_loadout) == "table" and profile.visual_loadout or {}
    local ext = visual_extension(safe_player_unit(player))
    local applied = {}
    local suppressed = {}
    local empty = {}

    for i = 1, #STUDIO_SLOT_ORDER do
        local slot_name = STUDIO_SLOT_ORDER[i]

        if _look_state.suppressed[slot_name] == true then
            suppressed[slot_name] = true
        elseif _look_state.empty[slot_name] == true then
            empty[slot_name] = true
        else
            local item_name = _look_state.applied[slot_name]

            if type(item_name) ~= "string" then
                local live_item = slot_item(ext, slot_name)
                    or profile_loadout[slot_name]
                    or visual_loadout[slot_name]

                if type(live_item) == "string" then
                    item_name = live_item
                else
                    item_name = live_item and live_item.name or nil
                end
            end

            if type(item_name) == "string" and item_name ~= "" then
                applied[slot_name] = item_name
            else
                empty[slot_name] = true
            end
        end
    end

    for _, id in ipairs(EXTRA_SLOTS.ids(_look_state.extra_anchors)) do
        if _look_state.suppressed[id] == true then
            suppressed[id] = true
        elseif _look_state.empty[id] == true then
            empty[id] = true
        elseif type(_look_state.applied[id]) == "string" then
            applied[id] = _look_state.applied[id]
        else
            empty[id] = true
        end
    end

    return applied, suppressed, empty, clone_string_map(_look_state.extra_anchors),
        EXTRA_SLOTS.clone_transforms(_look_state.extra_transforms, _look_state.extra_anchors),
        EXTRA_SLOTS.clone_material_map(_look_state.materials)
end

local function merged_look_state(player, applied, suppressed, empty, extra_anchors, extra_transforms, materials)
    local merged_applied, merged_suppressed, merged_empty, merged_anchors,
        merged_transforms, merged_materials, err = current_look_state(player)

    if not merged_applied then
        return nil, nil, nil, nil, nil, nil, err
    end

    merged_anchors = clone_string_map(extra_anchors or merged_anchors)
    merged_transforms = EXTRA_SLOTS.clone_transforms(extra_transforms or merged_transforms, merged_anchors)
    merged_materials = EXTRA_SLOTS.clone_material_map(materials or merged_materials)

    for id in pairs(_look_state.extra_anchors) do
        if not merged_anchors[id] then
            merged_applied[id] = nil
            merged_suppressed[id] = nil
            merged_empty[id] = nil
            merged_transforms[id] = nil
        end
    end

    for _, id in ipairs(EXTRA_SLOTS.ids(merged_anchors)) do
        merged_applied[id] = nil
        merged_suppressed[id] = nil

        if not (applied and applied[id])
            and not (suppressed and suppressed[id])
            and not (empty and empty[id]) then
            merged_empty[id] = true
        else
            merged_empty[id] = nil
        end
    end

    for slot_name, is_empty in pairs(empty or {}) do
        if is_empty == true and (valid_look_slot(slot_name) or EXTRA_SLOTS.is_slot(slot_name, merged_anchors)) then
            merged_applied[slot_name] = nil
            merged_suppressed[slot_name] = nil
            merged_empty[slot_name] = true
        end
    end

    for slot_name, hidden in pairs(suppressed or {}) do
        if hidden == true and (valid_look_slot(slot_name) or EXTRA_SLOTS.is_slot(slot_name, merged_anchors)) then
            merged_applied[slot_name] = nil
            merged_empty[slot_name] = nil
            merged_suppressed[slot_name] = true
        end
    end

    for slot_name, item_name in pairs(applied or {}) do
        if (valid_look_slot(slot_name) or EXTRA_SLOTS.is_slot(slot_name, merged_anchors)) and type(item_name) == "string" then
            merged_applied[slot_name] = item_name
            merged_suppressed[slot_name] = nil
            merged_empty[slot_name] = nil
        end
    end

    return merged_applied, merged_suppressed, merged_empty, merged_anchors, merged_transforms, merged_materials
end

local function copy_to_clipboard(value)
    local clipboard = rawget(_G, "Clipboard")
    local put = clipboard and clipboard.put

    if type(put) ~= "function" then
        return false
    end

    local ok, copied = pcall(put, value)

    return ok and copied ~= false
end

mod.npclook_export_code = function(applied, suppressed, empty, extra_anchors, extra_transforms, materials, variants, masks, opacity, meshes)
    local player = get_local_player()

    if applied == nil and suppressed == nil and empty == nil then
        local current_applied, current_suppressed, current_empty, current_anchors,
            current_transforms, current_materials, err = current_look_state(player)

        if not current_applied then
            return nil, err
        end

        applied = current_applied
        suppressed = current_suppressed
        empty = current_empty
        extra_anchors = current_anchors
        extra_transforms = current_transforms
        materials = current_materials
        variants = _look_state.variants
        masks = _look_state.masks
        opacity = _look_state.opacity
        meshes = _look_state.meshes
    end

    return encode_look_code(
        applied or {},
        suppressed or {},
        empty or {},
        look_metadata(player),
        extra_anchors or {},
        extra_transforms or {},
        materials or {},
        variants or {},
        masks or {},
        opacity or {},
        meshes or {}
    )
end

live_visual.has_look_state = function(state)
    return type(state) == "table" and (
        next(state.applied or {}) ~= nil
        or next(state.suppressed or {}) ~= nil
        or next(state.empty or {}) ~= nil
        or next(state.extra_anchors or {}) ~= nil
        or next(state.materials or {}) ~= nil
        or next(state.variants or {}) ~= nil
        or next(state.masks or {}) ~= nil
        or next(state.meshes or {}) ~= nil
        or next(state.opacity or {}) ~= nil
    )
end

live_visual.has_active_look = function()
    return live_visual.has_look_state(_look_state)
end

live_visual.clear_look_intent = function()
    _reapply_pending = false
    _vanilla_restore_pending = false
    _raw_overlay_retry_requested = false
    util.reset_retry(_reapply_retry)
    util.report_once(_runtime_reports, "reapply", nil)

    table.clear(_look_state.applied)
    table.clear(_look_state.suppressed)
    table.clear(_look_state.empty)
    table.clear(_look_state.extra_anchors)
    table.clear(_look_state.extra_transforms)
    table.clear(_look_state.materials)
    table.clear(_look_state.variants)
    table.clear(_look_state.masks)
    table.clear(_look_state.meshes)
    table.clear(_look_state.opacity)
    _look_state.character_id = nil
    _look_state.breed = nil

    extra_slot_runtime.clear(0)
    invalidate_live_plan()
end

live_visual.clear_foreign_active_look = function(character_id)
    character_id = character_id ~= nil and tostring(character_id) or nil

    if not live_visual.has_active_look() then
        return true
    end

    local active_character_id = _look_state.character_id ~= nil
        and tostring(_look_state.character_id) or nil

    if active_character_id and active_character_id == character_id then
        return true
    end

    live_visual.clear_look_intent()
    table.clear(_originals)
    table.clear(live_visual.managed_slots)

    if type(mod.npclook_refresh_portrait) == "function" then
        pcall(mod.npclook_refresh_portrait)
    end

    return true
end

live_visual.add_look_to_loadout = function(source_loadout, state)
    source_loadout = source_loadout or {}
    state = state or {}

    local applied = state.applied or {}
    local suppressed = state.suppressed or {}
    local empty = state.empty or {}
    local materials_by_slot = state.materials or {}
    local opacity_by_slot = state.opacity or {}
    local variants = state.variants or {}
    local masks = state.masks or {}
    local meshes = state.meshes or {}
    local loadout = shallow_copy(source_loadout)

    for slot_name in pairs(suppressed) do
        loadout[slot_name] = nil
    end

    for slot_name in pairs(empty) do
        loadout[slot_name] = nil
    end

    for i = 1, #STUDIO_SLOT_ORDER do
        local slot_name = STUDIO_SLOT_ORDER[i]
        local source_item = source_loadout[slot_name]
        local source_item_name = type(source_item) == "table" and source_item.name
            or type(source_item) == "string" and source_item or nil
        local item_name = applied[slot_name] or source_item_name
        local materials = materials_by_slot[slot_name]
        local item = item_name
            and not suppressed[slot_name]
            and not empty[slot_name]
            and (applied[slot_name] or #EXTRA_SLOTS.normalize_materials(materials) > 0
                or masks[slot_name]
                or meshes[slot_name]
                or util.normalize_opacity(opacity_by_slot[slot_name]) ~= util.opacity_default)
            and make_item_instance(
                slot_name,
                item_name,
                materials,
                variants[slot_name],
                masks[slot_name],
                opacity_by_slot[slot_name],
                meshes[slot_name]
            ) or nil

        if item then
            loadout[slot_name] = item
        end
    end

    return without_overlay_raw_slots(loadout, applied)
end

live_visual.look_profile_signature = function(profile, state)
    state = state or {}

    return live_visual.profile_signature(profile, state)
        .. "|materials:" .. EXTRA_SLOTS.material_map_signature(state.materials or {})
        .. "|opacity:" .. live_visual.map_signature(state.opacity or {})
        .. "|variants:" .. live_visual.map_signature((function()
            local signatures = {}

            for slot_name, value in pairs(state.variants or {}) do
                signatures[slot_name] = RAW_UNITS.variant_signature(value)
            end

            return signatures
        end)())
        .. "|masks:" .. live_visual.map_signature((function()
            local signatures = {}

            for slot_name, value in pairs(state.masks or {}) do
                signatures[slot_name] = MASKS.signature(value)
            end

            return signatures
        end)())
        .. "|meshes:" .. live_visual.map_signature((function()
            local signatures = {}

            for slot_name, value in pairs(state.meshes or {}) do
                signatures[slot_name] = MESHES.signature(value)
            end

            return signatures
        end)())
        .. "|extra_anchors:" .. live_visual.map_signature(state.extra_anchors or {})
        .. "|extra_transforms:" .. live_visual.map_signature((function()
            local signatures = {}

            for id in pairs(state.extra_anchors or {}) do
                signatures[id] = EXTRA_SLOTS.transform_signature(
                    state.extra_transforms and state.extra_transforms[id]
                )
            end

            return signatures
        end)())
end

live_visual.profile_with_look = function(profile, state)
    if type(profile) ~= "table" then
        return profile
    end

    local source_profile = profile.npclook_source_profile or profile

    if not live_visual.has_look_state(state) then
        return source_profile
    end

    local signature = live_visual.look_profile_signature(source_profile, state)

    if profile.npclook_active_look_signature == signature then
        return profile
    end

    local copy = shallow_copy(source_profile)
    local applied = state.applied or {}
    local suppressed = state.suppressed or {}
    local empty = state.empty or {}
    local extra_anchors = state.extra_anchors or {}
    local extra_transforms = state.extra_transforms or {}
    local variants = state.variants or {}

    copy.loadout = live_visual.add_look_to_loadout(source_profile.loadout or {}, state)
    copy.npclook_extra_slots = extra_slot_runtime.preview_items(
        applied,
        suppressed,
        empty,
        extra_anchors,
        extra_transforms,
        profile_breed_name(source_profile),
        copy.loadout,
        variants,
        state.opacity or {},
        state.meshes or {}
    )
    copy.npclook_source_profile = source_profile
    copy.npclook_active_look_signature = signature

    return copy
end

live_visual.profile_with_active_look = function(profile)
    return live_visual.profile_with_look(profile, _look_state)
end

live_visual.loadout_profile_cache = {}
live_visual.loadout_profile_warnings = {}

live_visual.invalidate_loadout_profile_cache = function()
    table.clear(live_visual.loadout_profile_cache)
    table.clear(live_visual.loadout_profile_warnings)
end

live_visual.decoded_profile_look = function(preset)
    local name = preset and preset.name
    local code = preset and preset.code

    if type(name) ~= "string" or type(code) ~= "string" then
        return nil
    end

    local cached = live_visual.loadout_profile_cache[name]

    if cached and cached.code == code then
        return cached.state
    end

    local applied, suppressed, empty, count_or_error, _, extra_anchors,
        extra_transforms, materials, variants, masks, opacity, meshes = decode_look_code(code)

    if not applied then
        if live_visual.loadout_profile_warnings[name] ~= code then
            live_visual.loadout_profile_warnings[name] = code
            mod:warning(
                "Could not prepare pinned preset %s for a UI character: %s",
                name,
                tostring(count_or_error)
            )
        end

        return nil
    end

    local state = {
        applied = applied,
        suppressed = suppressed,
        empty = empty,
        extra_anchors = extra_anchors or {},
        extra_transforms = extra_transforms or {},
        materials = materials or {},
        opacity = opacity or {},
        variants = variants or {},
        masks = masks or {},
        meshes = meshes or {},
    }

    live_visual.loadout_profile_cache[name] = {
        code = code,
        state = state,
    }

    return state
end

local LOADOUT_PRESETS = mod:io_dofile(
    "NPCLook/scripts/mods/NPCLook/npclook_loadout_presets"
).new({
    mod = mod,
    loc = loc,
    preset_store = PLAYER_PRESETS,
    get_local_player = get_local_player,
    has_active_look = live_visual.has_active_look,
    active_look_character_id = function()
        return _look_state.character_id ~= nil and tostring(_look_state.character_id) or nil
    end,
    clear_foreign_look = live_visual.clear_foreign_active_look,
    reset_look = function()
        local ok, _, changed = mod.npclook_reset_all()

        return ok == true, ok == true and nil or loc("error_slot_restore"), changed ~= false
    end,
    import_code = function(code)
        return mod.npclook_import_code(code)
    end,
    game_ready = function()
        local player = get_local_player()
        local player_unit = player and safe_player_unit(player)

        return _game_state_ready
            and not _startup_cleanup_pending
            and visual_extension(player_unit) ~= nil
    end,
    invalidate_profile_cache = live_visual.invalidate_loadout_profile_cache,
    hook_method = hook_method,
    button_visible = function()
        return mod:get("loadout_button_visible") ~= false
    end,
    button_position = function()
        return mod:get("loadout_button_x"), mod:get("loadout_button_y")
    end,
})

live_visual.profile_with_selected_look = function(profile)
    if type(profile) ~= "table" then
        return profile
    end

    -- Companion mods decorate their own profiles.
    if profile.npclook_external_look == true then
        return profile
    end

    local source_profile = profile.npclook_source_profile or profile
    local selection, preset = LOADOUT_PRESETS.profile_selection(source_profile)

    if selection == "default" then
        return source_profile
    elseif selection == "preset" then
        local state = live_visual.decoded_profile_look(preset)

        return state and live_visual.profile_with_look(source_profile, state) or source_profile
    elseif profile_matches_active_character(source_profile) then
        return live_visual.profile_with_active_look(source_profile)
    end

    return source_profile
end

live_visual.studio_profile_loader_reference_prefix = "UICharacterProfilePackageLoader_NPCLookStudioPreviewView"
live_visual._studio_loader_guard_fallback_reported = false

live_visual.studio_preview_package_cache = function(package_manager)
    local cache = rawget(mod, "npclook_studio_preview_package_cache")

    if type(cache) ~= "table" then
        cache = {
            manager = package_manager,
            package_ids = {},
            reported_errors = {},
        }
        rawset(mod, "npclook_studio_preview_package_cache", cache)
    elseif cache.manager ~= package_manager then
        cache.manager = package_manager
        cache.package_ids = {}
        cache.reported_errors = {}
    else
        cache.package_ids = type(cache.package_ids) == "table" and cache.package_ids or {}
        cache.reported_errors = type(cache.reported_errors) == "table" and cache.reported_errors or {}
    end

    return cache
end

live_visual.is_studio_profile_loader = function(profile_loader)
    local reference_name = profile_loader and profile_loader._reference_name
    local prefix = live_visual.studio_profile_loader_reference_prefix

    return type(reference_name) == "string"
        and string.sub(reference_name, 1, #prefix) == prefix
end

-- A Studio UICharacterProfilePackageLoader must never become the final owner of a
-- package while its preview units can still hold engine resource references. Adopt
-- one native loader ID per package into the manager-lifetime Studio cache and only
-- release duplicate IDs while that retained owner is still present.
-- Darktide: scripts/managers/ui/ui_character_profile_package_loader.lua
hook_module(
    "scripts/managers/ui/ui_character_profile_package_loader",
    "_unload_packages",
    function(func, self, packages_to_unload)
        if not live_visual.is_studio_profile_loader(self)
            or type(packages_to_unload) ~= "table"
            or #packages_to_unload == 0 then
            return func(self, packages_to_unload)
        end

        local package_manager = Managers.package
        local load_call_data = package_manager and package_manager._load_call_data

        if not package_manager or type(load_call_data) ~= "table" then
            -- Releasing without being able to prove another retained owner exists is
            -- the unsafe operation. Leave these IDs owned by PackageManager instead.
            table.clear(packages_to_unload)

            if not live_visual._studio_loader_guard_fallback_reported then
                live_visual._studio_loader_guard_fallback_reported = true
                mod:warning("Studio package release guard retained native loader packages because PackageManager ownership data was unavailable.")
            end

            return
        end

        local cache = live_visual.studio_preview_package_cache(package_manager)
        local retained_ids = cache.package_ids
        local duplicate_ids = {}

        for i = 1, #packages_to_unload do
            local load_id = packages_to_unload[i]
            local load_data = load_call_data[load_id]
            local package_name = load_data and load_data.package_name

            if package_name then
                local retained_id = retained_ids[package_name]
                local retained_data = retained_id and load_call_data[retained_id]
                local retained_is_valid = retained_id == load_id
                    or (retained_data and retained_data.package_name == package_name)

                if retained_is_valid then
                    if retained_id ~= load_id then
                        duplicate_ids[#duplicate_ids + 1] = load_id
                    end
                else
                    retained_ids[package_name] = load_id
                end
            end
        end

        table.clear(packages_to_unload)

        if #duplicate_ids > 0 then
            return func(self, duplicate_ids)
        end
    end
)

-- Only spawners that own extra units need a forced deletion flush.
local function clear_ui_profile_extra_slots(profile_spawner)
    profile_spawner._npclook_extra_slots_ready = nil

    if not extra_slot_runtime.has_context(profile_spawner) then
        return
    end

    extra_slot_runtime.clear_context(profile_spawner, 0)

    local unit_spawner = profile_spawner._unit_spawner
    local flush = unit_spawner and (
        unit_spawner.commit_and_remove_pending_units
        or unit_spawner.remove_pending_units
    )

    if type(flush) == "function" then
        pcall(flush, unit_spawner)
    end
end

-- Apply character-specific pinned looks at the shared UI profile-spawner boundary.
-- Darktide: scripts/managers/ui/ui_profile_spawner.lua
hook_module("scripts/managers/ui/ui_profile_spawner", "spawn_profile", function(func, self, profile, ...)
    clear_ui_profile_extra_slots(self)

    if self._reference_name ~= "NPCLookStudioPreviewView" then
        profile = live_visual.profile_with_selected_look(profile)
    end

    return func(self, profile, ...)
end)

-- Darktide: scripts/ui/views/inventory_background_view/inventory_background_view.lua
hook_module(
    "scripts/ui/views/inventory_background_view/inventory_background_view",
    "_spawn_profile",
    function(func, self, profile, ...)
        if self._preview_player == get_local_player() then
            profile = live_visual.profile_with_selected_look(profile)
        end

        return func(self, profile, ...)
    end
)

-- Darktide: scripts/ui/views/inventory_cosmetics_view/inventory_cosmetics_view.lua
hook_module("scripts/ui/views/inventory_cosmetics_view/inventory_cosmetics_view", "init", function(func, self, settings, context)
    func(self, settings, context)

    if self._preview_player == get_local_player() and self._presentation_profile then
        self._presentation_profile = live_visual.profile_with_selected_look(self._presentation_profile)
    end
end)

-- Darktide: scripts/ui/portrait_ui.lua
hook_module("scripts/ui/portrait_ui", "load_profile_portrait", function(func, self, profile, ...)
    profile = live_visual.profile_with_selected_look(profile)

    return func(self, profile, ...)
end)

-- Darktide: scripts/ui/portrait_ui.lua
hook_module("scripts/ui/portrait_ui", "profile_updated", function(func, self, profile, ...)
    profile = live_visual.profile_with_selected_look(profile)

    return func(self, profile, ...)
end)

live_visual.sync_ui_profile_extra_slots = function(profile_spawner)
    local spawn_data = profile_spawner and profile_spawner._character_spawn_data
    local profile = spawn_data and spawn_data.profile
    local entries = profile and profile.npclook_extra_slots
    local unit_3p = spawn_data and spawn_data.unit_3p
    local character_hidden = profile_spawner and (profile_spawner._visible == false
        or profile_spawner._character_toggle_state == false)

    if type(entries) ~= "table" or #entries == 0 then
        profile_spawner._npclook_extra_slots_ready = true

        if extra_slot_runtime.has_context(profile_spawner) then
            extra_slot_runtime.clear_context(profile_spawner, 0)
        end

        return
    elseif character_hidden or not util.safe_unit_alive(unit_3p) then
        extra_slot_runtime.clear_context(profile_spawner, 0)
        profile_spawner._npclook_extra_slots_ready = true
        return
    elseif spawn_data.is_ready ~= true then
        profile_spawner._npclook_extra_slots_ready = false
        return
    end

    local _, _, _, _, packages_loading = extra_slot_runtime.sync_context(profile_spawner, unit_3p, {
        world = profile_spawner._world,
        unit_spawner = profile_spawner._unit_spawner,
        item_definitions = profile_spawner._item_definitions,
        mission = profile_spawner._mission_template,
        breed_name = spawn_data.breed_name,
        from_ui_profile_spawner = true,
        force_highest_lod_step = profile_spawner._force_highest_lod_step == true,
        context_label = profile_spawner._reference_name or profile_spawner.__class_name,
    }, entries)

    profile_spawner._npclook_extra_slots_ready = not packages_loading
end

-- Sync extras on independent UI characters.
-- Darktide: scripts/managers/ui/ui_profile_spawner.lua
local function sync_after_ui_profile_update(profile_spawner, ...)
    live_visual.sync_ui_profile_extra_slots(profile_spawner)

    return ...
end

hook_module("scripts/managers/ui/ui_profile_spawner", "update", function(func, self, dt, t, input_service)
    return sync_after_ui_profile_update(self, func(self, dt, t, input_service))
end)

-- Keep UI profiles pending until their extra slots are ready.
-- Darktide: scripts/managers/ui/ui_profile_spawner.lua
hook_module("scripts/managers/ui/ui_profile_spawner", "spawned", function(func, self, ...)
    local spawned = func(self, ...)
    local spawn_data = self._character_spawn_data
    local profile = spawn_data and spawn_data.profile
    local entries = profile and profile.npclook_extra_slots

    if spawned and type(entries) == "table" and #entries > 0
        and self._npclook_extra_slots_ready ~= true then
        return false
    end

    return spawned
end)

-- Darktide: scripts/managers/ui/ui_profile_spawner.lua
hook_module("scripts/managers/ui/ui_profile_spawner", "_despawn_current_character_profile", function(func, self, ...)
    clear_ui_profile_extra_slots(self)

    return func(self, ...)
end)

-- Darktide: scripts/managers/ui/ui_profile_spawner.lua
hook_module("scripts/managers/ui/ui_profile_spawner", "destroy", function(func, self, ...)
    clear_ui_profile_extra_slots(self)

    return func(self, ...)
end)

local function prepare_npclook_unit_deletion(unit_spawner, unit)
    local needs_prepare = extra_slot_runtime.needs_deletion_prepare

    if type(needs_prepare) ~= "function" or not needs_prepare(unit) then
        return true
    end

    extra_slot_runtime.clear_parent_unit(unit, 0)

    return extra_slot_runtime.prepare_unit_deletion(unit_spawner, unit) ~= false
end

-- Clear linked extras before a UI character is queued for deletion.
hook_method(UIUnitSpawner, "mark_for_deletion", function(func, self, unit, ...)
    if not prepare_npclook_unit_deletion(self, unit) then
        return
    end

    return func(self, unit, ...)
end)

-- Since 1.13 the gameplay spawner spawns MasterItems entries by name. Raw units are
-- registered under their own unit resource and would keep spawning themselves.
-- Darktide: scripts/foundation/managers/unit_spawner/unit_spawner_manager.lua
hook_method(UnitSpawnerManager, "spawn_unit", function(func, self, unit_or_item_name, ...)
    local cache = type(unit_or_item_name) == "string" and MasterItems.get_cached() or nil
    local item = cache and rawget(cache, unit_or_item_name)

    if type(item) ~= "table" or item.npclook_raw_unit ~= true or item.base_unit ~= unit_or_item_name then
        return func(self, unit_or_item_name, ...)
    end

    local unit = World.spawn_unit_ex(self._world, unit_or_item_name, nil, ...)

    Unit.set_data(unit, "unit_name", unit_or_item_name)

    return unit
end)

-- Clear linked extras at the live-unit deletion boundary.
hook_method(UnitSpawnerManager, "mark_for_deletion", function(func, self, unit, ...)
    if unit == _bound_player_unit then
        live_visual.refresh_active_package_units(visual_extension(unit))
    elseif live_visual.owners.by_unit[unit] then
        live_visual.owners.run(
            live_visual.owners.by_unit[unit],
            live_visual.refresh_active_package_units,
            visual_extension(unit)
        )
    end

    if not prepare_npclook_unit_deletion(self, unit) then
        return
    end

    return func(self, unit, ...)
end)

local ScriptWorld = require("scripts/foundation/utilities/script_world")

-- Apply extra-slot pose corrections immediately before each world renders.
hook_method(ScriptWorld, "render", function(func, world)
    extra_slot_runtime.update_pose(world)

    return func(world)
end)

mod.npclook_refresh_portrait = function()
    local player = get_local_player()
    local profile = safe_profile(player)
    local ui_manager = Managers.ui

    if profile and ui_manager and type(ui_manager.event_player_profile_character_appearance_update) == "function" then
        ui_manager:event_player_profile_character_appearance_update(profile)
    end
end

mod.npclook_preset_names = function()
    local names = {}

    for name in pairs(OUTFIT_PRESETS) do
        names[#names + 1] = name
    end

    table.sort(names)

    return names
end

mod.npclook_inspect_item = function(item_name)
    local item, normalized_item_name = item_definition(item_name)
    item_name = normalized_item_name or item_name

    if not item then
        return nil
    end

    local variant_families = {}

    for _, family in ipairs(item.npclook_raw_variant_families or {}) do
        local options = {}

        for _, option in ipairs(family.options or {}) do
            options[#options + 1] = {
                name = tostring(type(option) == "table" and option.name or option),
            }
        end

        variant_families[#variant_families + 1] = {
            name = tostring(family.name or "variant"),
            options = options,
        }
    end

    local visibility_groups = {}

    for _, group in ipairs(item.npclook_raw_visibility_groups or {}) do
        visibility_groups[#visibility_groups + 1] = tostring(type(group) == "table" and group.name or group)
    end

    return {
        name = item_name,
        slots = item.slots,
        hide_slots = item.hide_slots,
        base_unit = item.base_unit,
        variant_families = variant_families,
        visibility_groups = visibility_groups,
        mesh_count = item.npclook_raw_mesh_count,
        estimated_variant_combinations = item.npclook_raw_estimated_variant_combinations,
        unit_category = item.npclook_raw_category_label,
        package_source = item.npclook_raw_package_source_label,
        package_name = item.npclook_raw_package,
        package_members = item.npclook_raw_package_members,
        package_count = item.npclook_raw_package_count,
        membership_count = item.npclook_raw_membership_count,
        variant_parse_failure = item.npclook_raw_variant_parse_failure,
    }
end

mod.npclook_state_snapshot = function()
    return {
        applied = clone_string_map(_look_state.applied),
        suppressed = clone_string_map(_look_state.suppressed),
        empty = clone_string_map(_look_state.empty),
        extra_anchors = clone_string_map(_look_state.extra_anchors),
        extra_transforms = EXTRA_SLOTS.clone_transforms(_look_state.extra_transforms, _look_state.extra_anchors),
        materials = EXTRA_SLOTS.clone_material_map(_look_state.materials),
        variants = RAW_UNITS.clone_variant_map(_look_state.variants),
        masks = MASKS.clone_map(_look_state.masks),
        opacity = util.clone_opacity_map(_look_state.opacity),
        meshes = MESHES.clone_map(_look_state.meshes),
        preset_names = mod.npclook_preset_names(),
    }
end

local function suppress_missing_slots(applied, suppressed, empty, slots)
    for i = 1, #slots do
        local slot_name = slots[i]

        if not applied[slot_name] and valid_look_slot(slot_name) then
            suppressed[slot_name] = true

            if empty then
                empty[slot_name] = nil
            end
        end
    end
end

mod.npclook_refresh_look = function()
    if not get_local_player() then
        return false, loc("error_no_local_player")
    end

    return push_look()
end

mod.npclook_reset_all = function()
    local player = get_local_player()

    if not player then
        return false, loc("error_no_local_player")
    end

    -- Loadout pins reconcile on every sync; a vanilla character needs no restore or portrait refresh.
    if not live_visual.has_active_look()
        and next(_originals) == nil
        and next(live_visual.managed_slots) == nil
        and not _vanilla_restore_pending
        and not _reapply_pending
        and not extra_slot_runtime.has_units() then
        return true, nil, false
    end

    live_visual.clear_look_intent()

    local restored = direct_restore(player)

    if not restored then
        _vanilla_restore_pending = true
        util.reset_retry(_reapply_retry)
    else
        table.clear(_originals)
        table.clear(live_visual.managed_slots)
    end

    mod.npclook_refresh_portrait()

    return true, restored and nil or loc("error_slot_restore"), true
end

-- Studio session

-- One session feeds both views.

local STUDIO_ITEM_PAGE_SIZE = 8
local STUDIO_SEARCH_MAX_LENGTH = 256
local STUDIO_SOURCE_PAGE_SIZE = 9
local STUDIO_HISTORY_LIMIT = 32
local STUDIO_PREVIEW_ITEM_CACHE_LIMIT = 64

-- Keep late helpers in one table so the chunk stays below Lua's local limit.
local INTERNAL = {}

INTERNAL.attachment_node_library = {
    { name = "root_point", label = "ROOT" },
    { name = "j_hips", label = "HIPS" },
    { name = "j_spine", label = "SPINE" },
    { name = "j_spine1", label = "SPINE 1" },
    { name = "j_spine2", label = "SPINE 2 / CHEST" },
    { name = "j_neck", label = "NECK" },
    { name = "j_head", label = "HEAD" },
    { name = "j_leftshoulder", label = "LEFT SHOULDER" },
    { name = "j_leftarm", label = "LEFT UPPER ARM" },
    { name = "j_leftforearm", label = "LEFT FOREARM" },
    { name = "j_lefthand", label = "LEFT HAND" },
    { name = "j_rightshoulder", label = "RIGHT SHOULDER" },
    { name = "j_rightarm", label = "RIGHT UPPER ARM" },
    { name = "j_rightforearm", label = "RIGHT FOREARM" },
    { name = "j_righthand", label = "RIGHT HAND" },
    { name = "j_leftupleg", label = "LEFT THIGH" },
    { name = "j_leftleg", label = "LEFT SHIN" },
    { name = "j_leftfoot", label = "LEFT FOOT" },
    { name = "j_lefttoebase", label = "LEFT TOE" },
    { name = "j_rightupleg", label = "RIGHT THIGH" },
    { name = "j_rightleg", label = "RIGHT SHIN" },
    { name = "j_rightfoot", label = "RIGHT FOOT" },
    { name = "j_righttoebase", label = "RIGHT TOE" },
    { name = "ap_head", label = "HEAD ATTACHMENT" },
    { name = "ap_chest", label = "CHEST ATTACHMENT" },
    { name = "ap_backpack", label = "BACKPACK ATTACHMENT" },
    { name = "ap_hips", label = "HIP ATTACHMENT" },
    { name = "ap_left_hand", label = "LEFT HAND ATTACHMENT" },
    { name = "ap_right_hand", label = "RIGHT HAND ATTACHMENT" },
}

function INTERNAL.display_token(value)
    local token = string.match(value or "", "([^/]+)$") or tostring(value or "")

    return string.gsub(token, "_", " ")
end

function INTERNAL.clamp_page(page, count, page_size)
    local page_count = math.max(1, math.ceil(count / page_size))

    return math.clamp(page or 1, 1, page_count), page_count
end

function INTERNAL.signed_delta(value, fallback)
    value = tonumber(value)

    if value == nil then
        return fallback or 0
    elseif value < 0 then
        return -1
    elseif value > 0 then
        return 1
    end

    return 0
end

function INTERNAL.page_slice(entries, page, page_size)
    local result = {}
    local first = (page - 1) * page_size + 1
    local last = math.min(#entries, first + page_size - 1)

    for index = first, last do
        result[#result + 1] = entries[index]
    end

    return result
end

function INTERNAL.replace_suppression(applied, suppressed, empty)
    suppress_missing_slots(applied, suppressed, empty, REPLACE_BODY_SUPPRESS)
    suppress_missing_slots(applied, suppressed, empty, REPLACE_GEAR_SLOTS)
end

function INTERNAL.cached_preview_item(session, slot_name, item_name, materials, variant_state, mask_state, opacity, mesh_state)
    local key = slot_name .. "|" .. item_name .. "|" .. EXTRA_SLOTS.material_list_signature(materials)
        .. "|" .. RAW_UNITS.variant_signature(variant_state)
        .. "|" .. MASKS.signature(mask_state)
        .. "|O:" .. tostring(util.normalize_opacity(opacity))
        .. "|W:" .. MESHES.signature(mesh_state)
    local item = session.preview_items[key]
    local order = session.preview_item_order

    -- Hits move to the back so pieces still on the preview are never rebuilt.
    if item then
        for i = #order, 1, -1 do
            if order[i] == key then
                table.remove(order, i)
                break
            end
        end

        order[#order + 1] = key

        return item
    end

    item = make_item_instance(slot_name, item_name, materials, variant_state, mask_state, opacity, mesh_state)

    if not item then
        return nil
    end

    session.preview_items[key] = item
    order[#order + 1] = key

    if #order > STUDIO_PREVIEW_ITEM_CACHE_LIMIT then
        local expired_key = table.remove(order, 1)
        session.preview_items[expired_key] = nil
    end

    return item
end

function INTERNAL.preview_loadout_signature(loadout)
    local slots = {}

    for slot_name in pairs(loadout or {}) do
        slots[#slots + 1] = slot_name
    end

    table.sort(slots)

    for i = 1, #slots do
        local slot_name = slots[i]
        slots[i] = slot_name .. "=" .. live_visual.item_signature(loadout[slot_name])
    end

    return table.concat(slots, "\31")
end

function INTERNAL.build_state_loadout(player, applied, suppressed, empty, materials, variants, masks, opacity, meshes, session)
    local profile = safe_profile(player)

    if not profile then
        return nil
    end

    local source_loadout = profile.loadout or {}
    local loadout = shallow_copy(source_loadout)

    for slot_name in pairs(suppressed or {}) do
        loadout[slot_name] = nil
    end

    for slot_name in pairs(empty or {}) do
        loadout[slot_name] = nil
    end

    for i = 1, #STUDIO_SLOT_ORDER do
        local slot_name = STUDIO_SLOT_ORDER[i]
        local source_item = source_loadout[slot_name]
        local source_item_name = type(source_item) == "table" and source_item.name
            or type(source_item) == "string" and source_item or nil
        local item_name = applied and applied[slot_name] or source_item_name
        local slot_materials = materials and materials[slot_name]
        local master_item = item_definition(item_name)
        local item

        if master_item and not util.item_is_2d(master_item, item_name)
            and not (suppressed and suppressed[slot_name])
            and not (empty and empty[slot_name])
            and ((applied and applied[slot_name]) or #EXTRA_SLOTS.normalize_materials(slot_materials) > 0
                or type(masks) == "table" and masks[slot_name]
                or type(meshes) == "table" and meshes[slot_name]
                or util.normalize_opacity(type(opacity) == "table" and opacity[slot_name]) ~= util.opacity_default) then
            item = INTERNAL.cached_preview_item(session, slot_name, item_name, slot_materials,
                type(variants) == "table" and variants[slot_name],
                type(masks) == "table" and masks[slot_name],
                type(opacity) == "table" and opacity[slot_name],
                type(meshes) == "table" and meshes[slot_name])
        end

        if item then
            loadout[slot_name] = item
        end
    end

    return without_overlay_raw_slots(loadout, applied)
end

function INTERNAL.build_preview_extra_slots(player, applied, suppressed, empty, extra_anchors, extra_transforms, loadout, variants, opacity, meshes)
    local profile = safe_profile(player)

    return extra_slot_runtime.preview_items(
        applied,
        suppressed,
        empty,
        extra_anchors,
        extra_transforms,
        profile_breed_name(profile),
        loadout,
        variants,
        opacity,
        meshes
    )
end

function INTERNAL.source_blueprint(session)
    local source_name = session.selected_source

    if not source_name or session.source_kind == "player" then
        return nil, false
    end

    local cache_key = string.format("%s|%s", session.source_kind or "preset", source_name)
    local cached = session.source_blueprints[cache_key]

    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local outfit

    if session.source_kind == "family" then
        -- Family names overlap, so require an exact match.
        local catalog = studio_item_catalog()
        local cache = item_cache()
        local item_names = catalog and catalog.family_items and catalog.family_items[source_name]
        local matches = {}

        for i = 1, #(item_names or {}) do
            local item_name = item_names[i]
            local item = item_definition(item_name)

            if item then
                matches[#matches + 1] = { name = item_name, item = item }
            end
        end

        if #matches > 0 then
            outfit = best_items_per_slot(matches)
        end
    else
        outfit = collect_outfit(source_name)
    end

    session.source_blueprints[cache_key] = outfit or false

    return outfit
end

function INTERNAL.preview_has_attachment_cycle(player, applied, suppressed, empty)
    local profile = safe_profile(player)
    local cache = item_cache()

    if not profile or not cache then
        return false
    end

    local visual_items = {}
    local breed_name = profile_breed_name(profile)

    local function add_item(slot_name, value)
        local item_name = type(value) == "string" and value or value and value.name
        local item = item_name and item_definition(item_name) or value

        if util.item_has_visual_base(item, breed_name) then
            visual_items[slot_name] = item
        end
    end

    for slot_name, item in pairs(profile.loadout or {}) do
        add_item(slot_name, item)
    end

    for slot_name, item_name in pairs(applied or {}) do
        if valid_look_slot(slot_name) then
            add_item(slot_name, item_name)
        end
    end

    for slot_name in pairs(suppressed or {}) do
        visual_items[slot_name] = nil
    end

    for slot_name in pairs(empty or {}) do
        visual_items[slot_name] = nil
    end

    local hidden_slots = {}

    for _, item in pairs(visual_items) do
        for i = 1, #(item.hide_slots or {}) do
            hidden_slots[item.hide_slots[i]] = true
        end
    end

    for slot_name in pairs(hidden_slots) do
        visual_items[slot_name] = nil
    end

    local visiting = {}
    local visited = {}

    local function visits_parent(slot_name)
        if visiting[slot_name] then
            return true
        elseif visited[slot_name] or not visual_items[slot_name] then
            return false
        end

        visiting[slot_name] = true

        local item = visual_items[slot_name]
        local slot_settings = ItemSlotSettings[slot_name]
        local parent_slots = slot_settings and slot_settings.forced_parent_slot_names or item.parent_slot_names

        for i = 1, #(parent_slots or {}) do
            local parent_slot = parent_slots[i]

            if visual_items[parent_slot] and visits_parent(parent_slot) then
                return true
            end
        end

        visiting[slot_name] = nil
        visited[slot_name] = true

        return false
    end

    for slot_name in pairs(visual_items) do
        if visits_parent(slot_name) then
            return true
        end
    end

    return false
end

function INTERNAL.studio_item_is_applicable(session, item_name)
    if session.item_mode == "assets" and CUSTOM_ASSETS.parse_entry_id(item_name) then
        local engine_type = CUSTOM_ASSETS.parse_entry_id(item_name)

        return (valid_look_slot(session.selected_slot)
            or EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors))
            and #INTERNAL.asset_slot_options(engine_type) > 0
    end

    if session.item_mode == "nodes" then
        return INTERNAL.attachment_node_available(session, item_name)
    elseif session.item_mode == "materials" then
        local item = item_definition(item_name)
        return (valid_look_slot(session.selected_slot)
            or EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors))
            and EXTRA_SLOTS.is_material_override_item(item)
    end

    local profile = safe_profile(session.player)
    local breed_name = profile_breed_name(profile)
    local is_extra_slot = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)
    local cache_key = table.concat({
        tostring(breed_name or ""),
        tostring(session.selected_slot or ""),
        tostring(item_name or ""),
    }, "\31")
    local cached = session.item_applicability_cache[cache_key]

    if cached ~= nil then
        return cached
    end

    local item = item_definition(item_name)
    local applicable = type(item) == "table" and not util.item_is_2d(item, item_name)
    local raw_unit = applicable and item.npclook_raw_unit == true

    if raw_unit then
        local resource = item.base_unit or item.name
        applicable = RAW_UNITS.is_resource(resource) and RAW_UNITS.resource_loadable(resource)
    elseif applicable and is_extra_slot then
        applicable = util.item_has_visual_base(item, breed_name)
    end

    session.item_applicability_cache[cache_key] = applicable

    return applicable
end

function INTERNAL.preview_candidate_is_safe(session, item_name)
    if session.item_mode == "nodes" then
        return INTERNAL.attachment_node_available(session, item_name)
    elseif session.item_mode == "materials"
        or session.item_mode == "assets" and CUSTOM_ASSETS.parse_entry_id(item_name) then
        return INTERNAL.studio_item_is_applicable(session, item_name)
    end

    if not INTERNAL.studio_item_is_applicable(session, item_name) then
        return false
    end

    local applied = clone_string_map(session.applied)
    local suppressed = clone_string_map(session.suppressed)
    local empty = clone_string_map(session.empty)
    local slot_name = session.selected_slot

    applied[slot_name] = item_name
    suppressed[slot_name] = nil
    empty[slot_name] = nil

    return not INTERNAL.preview_has_attachment_cycle(session.player, applied, suppressed, empty)
end

function INTERNAL.history_snapshot(session)
    return {
        applied = clone_string_map(session.applied),
        suppressed = clone_string_map(session.suppressed),
        empty = clone_string_map(session.empty),
        extra_anchors = clone_string_map(session.extra_anchors),
        extra_transforms = EXTRA_SLOTS.clone_transforms(session.extra_transforms, session.extra_anchors),
        materials = EXTRA_SLOTS.clone_material_map(session.materials),
        variants = RAW_UNITS.clone_variant_map(session.variants),
        masks = MASKS.clone_map(session.masks),
        opacity = util.clone_opacity_map(session.opacity),
        meshes = MESHES.clone_map(session.meshes),
    }
end

function INTERNAL.push_history(session, snapshot)
    session.history[#session.history + 1] = snapshot

    if #session.history > STUDIO_HISTORY_LIMIT then
        table.remove(session.history, 1)
    end

    table.clear(session.redo)
end

function INTERNAL.history_state_matches(session, snapshot)
    return same_string_map(session.applied, snapshot and snapshot.applied)
        and same_string_map(session.suppressed, snapshot and snapshot.suppressed)
        and same_string_map(session.empty, snapshot and snapshot.empty)
        and same_string_map(session.extra_anchors, snapshot and snapshot.extra_anchors)
        and EXTRA_SLOTS.same_transforms(session.extra_transforms, snapshot and snapshot.extra_transforms, session.extra_anchors)
        and EXTRA_SLOTS.same_material_maps(session.materials, snapshot and snapshot.materials)
        and RAW_UNITS.same_variant_maps(session.variants, snapshot and snapshot.variants)
        and MASKS.same_maps(session.masks, snapshot and snapshot.masks)
        and MESHES.same_maps(session.meshes, snapshot and snapshot.meshes)
        and util.same_opacity_maps(session.opacity, snapshot and snapshot.opacity)
end

function INTERNAL.record_history_change(session, previous)
    if INTERNAL.history_state_matches(session, previous) then
        return false
    end

    INTERNAL.push_history(session, previous)

    return true
end

function INTERNAL.restore_history_snapshot(session, snapshot)
    restore_string_map(session.applied, snapshot and snapshot.applied)
    restore_string_map(session.suppressed, snapshot and snapshot.suppressed)
    restore_string_map(session.empty, snapshot and snapshot.empty)
    restore_string_map(session.extra_anchors, snapshot and snapshot.extra_anchors)
    EXTRA_SLOTS.restore_transforms(session.extra_transforms, snapshot and snapshot.extra_transforms, session.extra_anchors)
    EXTRA_SLOTS.restore_material_map(session.materials, snapshot and snapshot.materials)
    session.variants = RAW_UNITS.clone_variant_map(snapshot and snapshot.variants)
    session.masks = MASKS.clone_map(snapshot and snapshot.masks)
    session.opacity = util.clone_opacity_map(snapshot and snapshot.opacity)
    session.meshes = MESHES.clone_map(snapshot and snapshot.meshes)
    table.clear(session.detected_material_slots)
    session.material_target = nil

    if not valid_look_slot(session.selected_slot) and not EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors) then
        session.selected_slot = "slot_gear_upperbody"
        session.slot_page = 1
    end

    session.source_preview = nil
    session.preview_item = nil
    session.preview_material_item = nil
end

function INTERNAL.studio_dirty_count(session)
    local count = 0

    for _, slot_name in ipairs(EXTRA_SLOTS.slot_order(session.extra_anchors)) do
        if session.applied[slot_name] ~= session.live_applied[slot_name]
            or session.suppressed[slot_name] ~= session.live_suppressed[slot_name]
            or session.empty[slot_name] ~= session.live_empty[slot_name]
            or session.extra_anchors[slot_name] ~= session.live_extra_anchors[slot_name]
            or (EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)
                and EXTRA_SLOTS.transform_signature(session.extra_transforms[slot_name])
                    ~= EXTRA_SLOTS.transform_signature(session.live_extra_transforms[slot_name]))
            or (valid_look_slot(slot_name)
                and EXTRA_SLOTS.material_list_signature(session.materials[slot_name])
                    ~= EXTRA_SLOTS.material_list_signature(session.live_materials[slot_name]))
            or RAW_UNITS.variant_signature(session.variants[slot_name])
                ~= RAW_UNITS.variant_signature(session.live_variants[slot_name])
            or MASKS.signature(session.masks[slot_name])
                ~= MASKS.signature(session.live_masks[slot_name])
            or MESHES.signature(session.meshes[slot_name])
                ~= MESHES.signature(session.live_meshes[slot_name])
            or util.normalize_opacity(session.opacity[slot_name])
                ~= util.normalize_opacity(session.live_opacity[slot_name]) then
            count = count + 1
        end
    end

    for slot_name in pairs(session.live_extra_anchors) do
        if not session.extra_anchors[slot_name] then
            count = count + 1
        end
    end

    return count
end

function INTERNAL.stage_outfit(session, outfit, replace)
    if not outfit or not next(outfit) then
        return false, loc("error_outfit_no_pieces")
    end

    local previous = INTERNAL.history_snapshot(session)
    local staged_count = 0

    for slot_name, item_name in pairs(outfit) do
        local item, normalized_item_name = item_definition(item_name)
        item_name = normalized_item_name or item_name

        if valid_look_slot(slot_name) and item and not util.item_is_2d(item, item_name) then
            local current_item = session.applied[slot_name]
                or INTERNAL.original_item_name(INTERNAL.session_source_loadout(session), slot_name)

            if current_item ~= item_name then
                session.materials[slot_name] = nil
                session.variants[slot_name] = nil
                session.masks[slot_name] = nil
                session.meshes[slot_name] = nil
            end

            session.applied[slot_name] = item_name
            session.suppressed[slot_name] = nil
            session.empty[slot_name] = nil
            staged_count = staged_count + 1
        end
    end

    if staged_count == 0 then
        return false, loc("error_outfit_no_pieces")
    end

    if replace then
        INTERNAL.replace_suppression(session.applied, session.suppressed, session.empty)
    end

    session.source_preview = nil
    session.preview_item = nil
    INTERNAL.record_history_change(session, previous)

    return true
end

function INTERNAL.effective_preview_state(session)
    local applied = clone_string_map(session.applied)
    local suppressed = clone_string_map(session.suppressed)
    local empty = clone_string_map(session.empty)

    if session.source_preview then
        local outfit = INTERNAL.source_blueprint(session)

        if outfit then
            local cache = item_cache() or {}

            for slot_name, item_name in pairs(outfit) do
                local item = item_definition(item_name)

                if valid_look_slot(slot_name) and item and not util.item_is_2d(item, item_name) then
                    applied[slot_name] = item_name
                    suppressed[slot_name] = nil
                    empty[slot_name] = nil
                end
            end

            if session.source_preview == "replace" then
                INTERNAL.replace_suppression(applied, suppressed, empty)
            end
        end
    end

    if session.preview_item then
        local slot_name = session.selected_slot
        local previous_item = applied[slot_name]
        local previous_suppressed = suppressed[slot_name]
        local previous_empty = empty[slot_name]

        applied[session.selected_slot] = session.preview_item
        suppressed[session.selected_slot] = nil
        empty[session.selected_slot] = nil

        if INTERNAL.preview_has_attachment_cycle(session.player, applied, suppressed, empty) then
            applied[slot_name] = previous_item
            suppressed[slot_name] = previous_suppressed
            empty[slot_name] = previous_empty
            session.preview_item = nil
            session.feedback = loc("feedback_preview_attachment_cycle")
        end
    end

    return applied, suppressed, empty
end

function INTERNAL.original_item_name(source_loadout, slot_name)
    local item = source_loadout and source_loadout[slot_name]

    return item and item.name
end

-- The native loadout follows the live profile, which can change while Studio is open.
function INTERNAL.session_source_loadout(session)
    local profile = session and safe_profile(session.player)

    return profile and profile.loadout or nil
end

function INTERNAL.selected_visual_item_name(session)
    if not session then
        return nil
    end

    if session.item_mode ~= "materials" and session.item_mode ~= "nodes" and session.selected_item
        and not INTERNAL.selected_asset_material(session) then
        return session.selected_item
    end

    local slot_name = session.selected_slot

    if session.suppressed[slot_name] or session.empty[slot_name] then
        return nil
    end

    return session.applied[slot_name]
        or INTERNAL.original_item_name(INTERNAL.session_source_loadout(session), slot_name)
end

function EXTRA_SLOTS.material_list_with_preview(materials, preview_item, target)
    local list = EXTRA_SLOTS.normalize_materials(materials)
    local entry = EXTRA_SLOTS.material_entry(preview_item, target)

    if not entry then
        return list
    end

    local index

    for i = 1, #list do
        if list[i] == entry then
            index = i
            break
        end
    end

    if index then
        table.remove(list, index)
    else
        list[#list + 1] = entry
    end

    return EXTRA_SLOTS.normalize_materials(list)
end

-- The material the user last clicked, while it is still the selected library row.
function INTERNAL.clicked_preview_material(session)
    local preview_item = session.preview_material_item

    if type(preview_item) ~= "string" or preview_item == "" then
        return nil
    elseif session.item_mode == "assets" then
        if not INTERNAL.selected_asset_material(session)
            or preview_item ~= INTERNAL.asset_material_item(session, session.selected_item) then
            return nil
        end
    elseif session.item_mode ~= "materials" or preview_item ~= session.selected_item then
        return nil
    end

    local slot_name = session.selected_slot

    if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        return nil
    end

    return preview_item
end

-- A selected mesh previews the material on that mesh only.
function EXTRA_SLOTS.selected_preview_material_item(session)
    if INTERNAL.mesh_material_mode(session) then
        return nil
    end

    return INTERNAL.clicked_preview_material(session)
end

function INTERNAL.selected_preview_mesh_material(session)
    if not INTERNAL.mesh_material_mode(session) then
        return nil
    end

    local preview_item = INTERNAL.clicked_preview_material(session)
    local override = preview_item and EXTRA_SLOTS.material_override_item(item_cache() or {}, preview_item)

    return MESHES.supports_override(override) and preview_item or nil
end

function INTERNAL.effective_preview_meshes(session)
    local preview_item = INTERNAL.selected_preview_mesh_material(session)

    if not preview_item then
        return session.meshes
    end

    local state, slot_name = INTERNAL.selected_mesh_state(session, true)

    if not state then
        return session.meshes
    end

    local meshes = MESHES.clone_map(session.meshes)
    state = MESHES.clone_state(state) or {
        item_name = state.item_name,
        hidden = {},
        materials = {},
    }
    state.materials[session.selected_mesh] = EXTRA_SLOTS.material_list_with_preview(
        state.materials[session.selected_mesh],
        preview_item,
        nil
    )
    meshes[slot_name] = MESHES.normalize_state(state, state.item_name)

    return meshes
end

-- A clicked piece previews visibly even when its slot is hidden.
function INTERNAL.effective_preview_opacity(session)
    local slot_name = session.selected_slot

    if not session.preview_item or util.normalize_opacity(session.opacity[slot_name]) ~= 0 then
        return session.opacity
    end

    local opacity = util.clone_opacity_map(session.opacity)
    local entry = session.hidden_opacity_restore[slot_name]
    local restore = type(entry) == "table" and entry.item_name == session.preview_item
        and util.normalize_opacity(entry.opacity) or util.opacity_default

    opacity[slot_name] = restore ~= 0 and restore ~= util.opacity_default and restore or nil

    return opacity
end

function EXTRA_SLOTS.effective_preview_material_state(session)
    local preview_item = EXTRA_SLOTS.selected_preview_material_item(session)
    local slot_name = session.selected_slot
    local preview_node = session.item_mode == "nodes"
        and EXTRA_SLOTS.normalize_attach_node(session.preview_attach_node) or nil
    local is_extra_slot = EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)

    if is_extra_slot and (preview_item or preview_node) then
        local transforms = EXTRA_SLOTS.clone_transforms(session.extra_transforms, session.extra_anchors)
        local transform = EXTRA_SLOTS.normalize_transform(transforms[slot_name])

        if preview_item then
            transform.materials = EXTRA_SLOTS.material_list_with_preview(
                transform.materials,
                preview_item,
                session.material_target
            )
        end

        if preview_node then
            transform.attach_node = preview_node
        end

        transforms[slot_name] = EXTRA_SLOTS.normalize_transform(transform)

        return session.materials, transforms
    elseif not preview_item then
        return session.materials, session.extra_transforms
    end

    local materials = EXTRA_SLOTS.clone_material_map(session.materials)
    local list = EXTRA_SLOTS.material_list_with_preview(
        materials[slot_name],
        preview_item,
        session.material_target
    )
    materials[slot_name] = #list > 0 and list or nil

    return materials, session.extra_transforms
end

function INTERNAL.preview_visual_signature(session)
    local applied, suppressed, empty = INTERNAL.effective_preview_state(session)
    local effective_materials, effective_extra_transforms = EXTRA_SLOTS.effective_preview_material_state(session)
    local effective_opacity = INTERNAL.effective_preview_opacity(session)
    local effective_meshes = INTERNAL.effective_preview_meshes(session)
    local profile = safe_profile(session.player)
    local source_loadout = profile and profile.loadout or {}
    local signature = {}

    for i, slot_name in ipairs(EXTRA_SLOTS.slot_order(session.extra_anchors)) do

        if suppressed[slot_name] or empty[slot_name] then
            signature[i] = "0"
        elseif type(applied[slot_name]) == "string" then
            signature[i] = "A" .. applied[slot_name]
                .. (EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)
                    and "|" .. EXTRA_SLOTS.transform_signature(effective_extra_transforms[slot_name])
                    or "|M:" .. EXTRA_SLOTS.material_list_signature(effective_materials[slot_name]))
        elseif EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
            signature[i] = "0|" .. EXTRA_SLOTS.transform_signature(effective_extra_transforms[slot_name])
        else
            local item_name = INTERNAL.original_item_name(source_loadout, slot_name)
            signature[i] = (item_name and "I" .. item_name or "0")
                .. "|M:" .. EXTRA_SLOTS.material_list_signature(effective_materials[slot_name])
        end

        signature[i] = signature[i]
            .. "|V:" .. RAW_UNITS.variant_signature(session.variants[slot_name])
            .. "|K:" .. MASKS.signature(session.masks[slot_name])
            .. "|O:" .. tostring(util.normalize_opacity(effective_opacity[slot_name]))
            .. "|W:" .. MESHES.signature(effective_meshes[slot_name])
    end

    return table.concat(signature, "\31")
end

function INTERNAL.selected_source_entries(session, catalog)
    if session.source_kind == "player" then
        local entries = {}

        for i = 1, #PLAYER_PRESETS.items do
            local preset = PLAYER_PRESETS.items[i]
            entries[#entries + 1] = {
                id = preset.name,
                label = string.upper(preset.name),
                sub = loc("ui_source_player_preset"),
            }
        end

        return entries
    elseif session.source_kind == "family" then
        local entries = {}

        for i = 1, #(catalog.families or {}) do
            local family = catalog.families[i]
            entries[#entries + 1] = {
                id = family.filter,
                label = string.upper(INTERNAL.display_token(family.filter)),
                sub = loc("ui_source_family_summary", family.item_count, family.slot_count),
            }
        end

        return entries
    end

    local entries = {}
    local names = mod.npclook_preset_names()

    for i = 1, #names do
        entries[#entries + 1] = {
            id = names[i],
            label = string.upper(INTERNAL.display_token(names[i])),
            sub = loc("ui_source_curated"),
        }
    end

    return entries
end

function INTERNAL.node_library_available(session)
    local slot_name = session and session.selected_slot

    if not EXTRA_SLOTS.is_slot(slot_name, session and session.extra_anchors) then
        return false
    end

    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[slot_name])

    return transform.enabled == true and transform.deform == false
end

function INTERNAL.attachment_node_entries(session)
    if not INTERNAL.node_library_available(session) then
        return {}
    end

    local player_unit = safe_player_unit(session.player)
    local can_validate = util.safe_unit_alive(player_unit)
    local scene_graph_count

    if can_validate and type(Unit.num_scene_graph_items) == "function" then
        local ok_count, count = pcall(Unit.num_scene_graph_items, player_unit)

        if ok_count and type(count) == "number" and count >= 1 then
            scene_graph_count = math.floor(count)
        end
    end

    local entries = {}
    local seen = {}

    local function append(name, label, node_index)
        name = EXTRA_SLOTS.normalize_attach_node(name)

        if not name or seen[name] then
            return
        end

        local available = true

        if can_validate and type(name) == "string" then
            local ok, has_node = pcall(Unit.has_node, player_unit, name)
            available = ok and has_node == true
        elseif can_validate and type(name) == "number" and scene_graph_count then
            available = name >= 1 and name <= scene_graph_count
        end

        if available then
            seen[name] = true
            entries[#entries + 1] = {
                name = name,
                node = node_index,
                label = label or string.upper(INTERNAL.display_token(tostring(name))),
                sub = tostring(name),
            }
        end
    end

    local current = EXTRA_SLOTS.normalize_transform(
        session.extra_transforms[session.selected_slot]
    ).attach_node

    -- Preserve the reference behavior of keeping the active anchor visible even
    -- when it is not part of the returned bone list. Numeric anchors created by
    -- newer builds remain selectable for saved-look compatibility.
    if type(current) == "number" then
        append(current, string.format("NODE %03d", current), current)
    else
        append(current, current and string.upper(INTERNAL.display_token(current)))
    end

    -- The reference Studio exposed the rig's real named bones. Cache the
    -- resource-backed result per live player unit so Studio list refreshes do not
    -- repeatedly query skeleton metadata. This remains outside gameplay/render
    -- pose-copy paths.
    local cached_bones = session._npclook_attachment_node_bones

    if session._npclook_attachment_node_bones_unit ~= player_unit then
        cached_bones = nil
        session._npclook_attachment_node_bones = nil
        session._npclook_attachment_node_bones_unit = player_unit
    end

    if cached_bones == nil and can_validate and type(Unit.bones) == "function" then
        local ok_bones, bones = pcall(Unit.bones, player_unit)

        if ok_bones and type(bones) == "table" then
            cached_bones = {}

            for i = 1, #bones do
                local name = bones[i]

                if type(name) == "string" and name ~= "" then
                    local node_index
                    local ok_node, node = pcall(Unit.node, player_unit, name)

                    if ok_node and type(node) == "number" then
                        node_index = node
                    end

                    cached_bones[#cached_bones + 1] = {
                        name = name,
                        node = node_index,
                    }
                end
            end

            session._npclook_attachment_node_bones = cached_bones
        end
    end

    for i = 1, #(cached_bones or {}) do
        local bone = cached_bones[i]
        append(bone.name, nil, bone.node)
    end

    -- Keep the curated named anchors as a fallback while the local rig is not
    -- ready or if a build does not expose Unit.bones.
    for i = 1, #INTERNAL.attachment_node_library do
        local entry = INTERNAL.attachment_node_library[i]
        append(entry.name, entry.label)
    end

    return entries
end

function INTERNAL.attachment_node_available(session, node_name)
    node_name = EXTRA_SLOTS.normalize_attach_node(node_name)

    if not node_name then
        return false
    end

    local entries = INTERNAL.attachment_node_entries(session)

    for i = 1, #entries do
        if entries[i].name == node_name then
            return true
        end
    end

    return false
end

local ASSET_TYPE_LABEL_KEYS = {
    unit = "ui_asset_unit",
    texture = "ui_asset_texture",
    material = "ui_asset_material",
}

function INTERNAL.asset_entries(session)
    if session.asset_entries then
        return session.asset_entries
    end

    local entries = {}
    local assets = CUSTOM_ASSETS.entries()

    for i = 1, #assets do
        local asset = assets[i]

        entries[#entries + 1] = {
            name = CUSTOM_ASSETS.entry_id(asset),
            label = asset.label,
            sub = loc(ASSET_TYPE_LABEL_KEYS[asset.engine_type] or "ui_asset_unit"),
            variant_search = asset.name,
        }
    end

    session.asset_entries = entries

    return entries
end

-- Lua cannot list a material's variables, so common shader names and typed names come first.
INTERNAL.asset_texture_slot_suggestions = {
    "texture_map",
    "diffuse_map",
    "normal",
    "mask",
    "detail",
    "noise",
    "gradient_map",
    "flow_map",
    "distortion_map",
    "effect_mask",
    "effect_gradient",
    "color_transition_mask",
    "fur_color_gradient",
}

INTERNAL.typed_asset_slots = {
    texture = {},
    material = {},
}
INTERNAL.typed_asset_slot_revision = 0

function INTERNAL.asset_slot_options(engine_type)
    local catalog = studio_item_catalog()

    if not catalog then
        return {}
    end

    local key = engine_type == "material" and "material" or "texture"
    local cached = catalog.asset_slot_options and catalog.asset_slot_options[key]

    if cached and cached.revision == INTERNAL.typed_asset_slot_revision then
        return cached.options
    end

    local options = {}
    local seen = {}

    local function add_all(values)
        for i = 1, #(values or {}) do
            local value = values[i]

            if type(value) == "string" and value ~= "" and not seen[value] then
                seen[value] = true
                options[#options + 1] = value
            end
        end
    end

    add_all(INTERNAL.typed_asset_slots[key])

    if key == "texture" then
        add_all(INTERNAL.asset_texture_slot_suggestions)
        add_all(catalog.texture_slots)
    else
        add_all(catalog.material_slots)
    end

    catalog.asset_slot_options = catalog.asset_slot_options or {}
    catalog.asset_slot_options[key] = {
        revision = INTERNAL.typed_asset_slot_revision,
        options = options,
    }

    return options
end

function INTERNAL.selected_asset_slot(session, engine_type)
    local options = INTERNAL.asset_slot_options(engine_type)
    local index = session.asset_slot_index[engine_type] or 1

    index = math.clamp(index, 1, math.max(#options, 1))
    session.asset_slot_index[engine_type] = index

    return options[index], index, #options
end

-- Custom textures and materials apply through a synthetic override item per material slot.
function INTERNAL.asset_material_item(session, entry_id)
    local engine_type, resource = CUSTOM_ASSETS.parse_entry_id(entry_id)

    if not engine_type then
        return nil
    end

    local material_slot = INTERNAL.selected_asset_slot(session, engine_type)
    local item_name = CUSTOM_ASSETS.material_item_name(engine_type, material_slot, resource)
    local cache = item_cache()

    if not item_name or not cache or not CUSTOM_ASSETS.ensure_material_item(cache, item_name) then
        return nil
    end

    return item_name
end

function INTERNAL.selected_asset_material(session)
    if session.item_mode ~= "assets" then
        return nil
    end

    return CUSTOM_ASSETS.parse_entry_id(session.selected_item)
end

function INTERNAL.raw_item_entries(session, catalog)
    if session.item_mode == "nodes" then
        return INTERNAL.attachment_node_entries(session)
    elseif session.item_mode == "materials" then
        return (valid_look_slot(session.selected_slot)
            or EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)) and (catalog.materials or {}) or {}
    elseif session.item_mode == "all" then
        return catalog.all or {}
    elseif session.item_mode == "assets" then
        return INTERNAL.asset_entries(session)
    elseif session.item_mode == "units" then
        if not RAW_UNITS.available() then
            return {}
        elseif not catalog.units_loaded then
            catalog.units = RAW_UNITS.catalog_entries()
            catalog.units_loaded = true
        end

        return catalog.units or {}
    end

    local slot_name = EXTRA_SLOTS.anchor(session.selected_slot, session.extra_anchors)

    return catalog.by_slot and catalog.by_slot[slot_name] or {}
end

function INTERNAL.truncate_search_query(value)
    if type(value) ~= "string" then
        return ""
    end

    if Utf8 and type(Utf8.string_length) == "function" and type(Utf8.sub_string) == "function"
        and Utf8.string_length(value) > STUDIO_SEARCH_MAX_LENGTH then
        return Utf8.sub_string(value, 1, STUDIO_SEARCH_MAX_LENGTH)
    end

    return string.sub(value, 1, STUDIO_SEARCH_MAX_LENGTH)
end

function INTERNAL.normalize_search_query(value)
    value = type(value) == "string" and string.lower(value) or ""
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    value = string.gsub(value, "%s+", " ")

    return value
end

function INTERNAL.search_terms(query)
    local terms = {}

    for term in string.gmatch(query, "%S+") do
        terms[#terms + 1] = term
    end

    return terms
end

function INTERNAL.item_search_text(entry)
    local slot_name = entry.slot or entry.source_slot
    local slot_label = slot_name and (STUDIO_SLOT_LABELS[slot_name] or slot_name) or ""
    local value = string.lower(table.concat({
        tostring(entry.name or ""),
        tostring(entry.label or ""),
        INTERNAL.display_token(entry.name or ""),
        tostring(slot_name or ""),
        tostring(slot_label),
        tostring(entry.sub or ""),
        tostring(entry.variant_search or ""),
    }, " "))

    return value
end

function INTERNAL.selected_item_entries(session, catalog)
    local entries = INTERNAL.raw_item_entries(session, catalog)
    local query = INTERNAL.normalize_search_query(session.item_search)
    local raw_path = session.item_mode == "units" and RAW_UNITS.normalize(session.item_search) or nil
    local raw_entry

    if raw_path and RAW_UNITS.is_resource(raw_path) then
        local item, added = RAW_UNITS.ensure(item_cache(), raw_path)

        if item then
            raw_entry = {
                name = raw_path,
                label = item.npclook_raw_label,
                sub = item.npclook_raw_category_label or loc("ui_raw_unit_path"),
            }

            if added then
                invalidate_raw_catalog()
            end
        end
    end

    if query == "" then
        return entries
    end

    local cache_key = table.concat({
        session.item_mode or "slot",
        session.selected_slot or "",
        session.source_kind or "",
        session.selected_source or "",
        query,
    }, "\31")

    if session.item_search_cache_key == cache_key and session.item_search_results then
        return session.item_search_results
    end

    local terms = INTERNAL.search_terms(query)
    local filtered = {}

    if raw_entry then
        filtered[#filtered + 1] = raw_entry
    end

    for i = 1, #entries do
        local entry = entries[i]
        -- Entries are rebuilt with the catalog, so their search text is computed once.
        local haystack = entry.search_text or INTERNAL.item_search_text(entry)
        entry.search_text = haystack
        local matches = true

        for j = 1, #terms do
            if not string.find(haystack, terms[j], 1, true) then
                matches = false
                break
            end
        end

        if matches and (not raw_entry or entry.name ~= raw_entry.name) then
            filtered[#filtered + 1] = entry
        end
    end

    session.item_search_cache_key = cache_key
    session.item_search_results = filtered

    return filtered
end

function INTERNAL.begin_studio_session(player)
    player = player or get_local_player()

    if not player then
        return false, loc("error_local_player_not_ready")
    end

    if _studio_session then
        local owners = type(_studio_session.view_owners) == "table"
            and _studio_session.view_owners or {}

        if _studio_session.closing == true and next(owners) == nil then
            INTERNAL.finalize_studio_session(_studio_session)
        else
            return false, loc("error_bridge_not_ready")
        end
    end

    PLAYER_PRESETS.initialize()

    local live = mod.npclook_state_snapshot()
    local preset_names = live.preset_names or {}
    local selected_source = preset_names[1]

    for i = 1, #preset_names do
        if preset_names[i] == "rannick" then
            selected_source = "rannick"
            break
        end
    end

    _studio_session = {
        player = player,
        applied = clone_string_map(live.applied),
        suppressed = clone_string_map(live.suppressed),
        empty = clone_string_map(live.empty),
        live_applied = clone_string_map(live.applied),
        live_suppressed = clone_string_map(live.suppressed),
        live_empty = clone_string_map(live.empty),
        extra_anchors = clone_string_map(live.extra_anchors),
        live_extra_anchors = clone_string_map(live.extra_anchors),
        extra_transforms = EXTRA_SLOTS.clone_transforms(live.extra_transforms, live.extra_anchors),
        live_extra_transforms = EXTRA_SLOTS.clone_transforms(live.extra_transforms, live.extra_anchors),
        materials = EXTRA_SLOTS.clone_material_map(live.materials),
        live_materials = EXTRA_SLOTS.clone_material_map(live.materials),
        variants = RAW_UNITS.clone_variant_map(live.variants),
        live_variants = RAW_UNITS.clone_variant_map(live.variants),
        masks = MASKS.clone_map(live.masks),
        live_masks = MASKS.clone_map(live.masks),
        meshes = MESHES.clone_map(live.meshes),
        live_meshes = MESHES.clone_map(live.meshes),
        studio_tab = "look",
        selected_mesh = nil,
        mesh_page = 1,
        mesh_inventory = {},
        opacity = util.clone_opacity_map(live.opacity),
        live_opacity = util.clone_opacity_map(live.opacity),
        hidden_opacity_restore = INTERNAL.hidden_opacity_restore,
        asset_slot_index = {},
        asset_entries = nil,
        selected_slot = "slot_gear_upperbody",
        slot_page = 1,
        selected_item = nil,
        preview_item = nil,
        preview_material_item = nil,
        preview_attach_node = nil,
        node_skeleton_visible = false,
        material_target = nil,
        variant_family_index = 1,
        visibility_group_index = 1,
        variant_control_mode = "families",
        visual_options_mode = "variants",
        detected_material_slots = {},
        item_mode = "slot",
        item_page = 1,
        item_search = "",
        item_search_cache_key = nil,
        item_search_results = nil,
        source_kind = "preset",
        source_page = 1,
        selected_source = selected_source,
        source_preview = nil,
        history = {},
        redo = {},
        preview_items = {},
        preview_item_order = {},
        source_blueprints = {},
        item_applicability_cache = {},
        camera_focus = nil,
        inspect_mode = false,
        camera_reset_revision = 0,
        preview_input = nil,
        preview_revision = 1,
        view_owners = {},
        closing = false,
        feedback = loc("feedback_initial"),
    }

    return true
end

mod.npclook_commit_state = function(applied, suppressed, empty, extra_anchors, extra_transforms, materials, variants, masks, opacity, meshes)
    local player = get_local_player()

    if not player then
        return false, loc("error_no_local_player")
    end

    local cache = item_cache()

    if not cache then
        return false, loc("error_master_cache_not_ready")
    end

    local profile = safe_profile(player)
    local breed_name = profile_breed_name(profile)
    local validated_applied = {}
    local validated_suppressed = {}
    local validated_empty = {}
    local validated_extra_anchors = {}
    local validated_extra_transforms = {}
    local validated_materials = EXTRA_SLOTS.clone_material_map(materials or _look_state.materials)
    local validated_variants = RAW_UNITS.clone_variant_map(variants or _look_state.variants)
    local validated_masks = MASKS.clone_map(masks or _look_state.masks)
    local validated_opacity = util.clone_opacity_map(opacity or _look_state.opacity)
    local validated_meshes = MESHES.clone_map(meshes or _look_state.meshes)
    local native_loadout = profile and profile.loadout or {}

    -- Inherited native pieces can carry masks and mesh edits without an explicit override.
    local function committed_item_name(slot_name)
        local item_name = validated_applied[slot_name]

        if item_name or not valid_look_slot(slot_name) then
            return item_name
        end

        local native_item = native_loadout[slot_name]

        return type(native_item) == "table" and native_item.name or type(native_item) == "string" and native_item or nil
    end

    for id, anchor in pairs(extra_anchors or _look_state.extra_anchors) do

        if type(id) ~= "string" or not string.match(id, "^extra_%d+$") or not valid_look_slot(anchor) then
            return false, loc("error_invalid_slot_value", tostring(id))
        end

        validated_extra_anchors[id] = anchor
        validated_extra_transforms[id] = EXTRA_SLOTS.normalize_transform((extra_transforms or _look_state.extra_transforms)[id])
    end

    if #EXTRA_SLOTS.ids(validated_extra_anchors) > 512 then
        return false, loc("error_code_too_many")
    end

    for slot_name in pairs(validated_opacity) do
        if not valid_look_slot(slot_name)
            and not EXTRA_SLOTS.is_slot(slot_name, validated_extra_anchors) then
            return false, loc("error_invalid_slot_value", tostring(slot_name))
        end
    end

    for slot_name, item_name in pairs(applied or {}) do
        local is_extra_slot = EXTRA_SLOTS.is_slot(slot_name, validated_extra_anchors)
        local item, normalized_item_name

        if type(item_name) == "string" then
            item, normalized_item_name = item_definition(item_name)
        end

        if not valid_look_slot(slot_name) and not is_extra_slot then
            return false, loc("error_invalid_slot_value", tostring(slot_name))
        elseif not item then
            return false, loc("error_missing_item", tostring(item_name))
        elseif util.item_is_2d(item, item_name) then
            return false, loc("error_visual_slot_unavailable")
        elseif is_extra_slot and item.npclook_raw_unit ~= true
            and not util.item_has_visual_base(item, breed_name) then
            return false, loc("error_visual_slot_unavailable")
        end

        validated_applied[slot_name] = normalized_item_name or item_name
    end

    for slot_name, state_value in pairs(validated_variants) do
        local item_name = validated_applied[slot_name]
        local item = item_name and item_definition(item_name)

        if not item or item.npclook_raw_unit ~= true or state_value.item_name ~= item_name then
            validated_variants[slot_name] = nil
        else
            local metadata = RAW_UNITS.variant_metadata(item)
            local allowed_families = {}
            local allowed_groups = {}

            for _, family in ipairs(metadata and metadata.variant_families or {}) do
                local options = {}
                for _, option in ipairs(family.options or {}) do
                    options[tostring(type(option) == "table" and option.name or option)] = true
                end
                allowed_families[tostring(family.name or "")] = options
            end

            for _, group in ipairs(metadata and metadata.visibility_groups or {}) do
                allowed_groups[tostring(type(group) == "table" and group.name or group)] = true
            end

            for family_name, option_name in pairs(state_value.families) do
                if not (allowed_families[family_name] and allowed_families[family_name][option_name]) then
                    state_value.families[family_name] = nil
                end
            end

            for group_name in pairs(state_value.visibility) do
                if not allowed_groups[group_name] then
                    state_value.visibility[group_name] = nil
                end
            end
        end
    end

    for slot_name, state_value in pairs(validated_masks) do
        if not valid_look_slot(slot_name) then
            validated_masks[slot_name] = nil
        else
            local item_name = committed_item_name(slot_name)
            local item = item_name and item_definition(item_name)
            local available = item and MASKS.available_fields(item, cache, slot_name) or {}
            local normalized = item and MASKS.normalize_state(state_value, item_name, available) or nil
            local valid_overrides = normalized ~= nil

            if valid_overrides then
                for field, value in pairs(normalized.fields) do
                    if not MASKS.option_matches(field, value, item, cache, slot_name) then
                        valid_overrides = false
                        break
                    end
                end
            end

            if not normalized or not valid_overrides
                or state_value.item_name ~= item_name or next(normalized.fields) == nil then
                validated_masks[slot_name] = nil
            else
                validated_masks[slot_name] = normalized
            end
        end
    end

    for slot_name, state_value in pairs(validated_meshes) do
        if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, validated_extra_anchors)
            or state_value.item_name ~= committed_item_name(slot_name) then
            validated_meshes[slot_name] = nil
        end
    end

    for slot_name, hidden in pairs(suppressed or {}) do
        if hidden == true then
            if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, validated_extra_anchors) then
                return false, loc("error_invalid_hidden_slot", tostring(slot_name))
            end

            validated_applied[slot_name] = nil
            validated_empty[slot_name] = nil
            validated_suppressed[slot_name] = true
        end
    end

    for slot_name, is_empty in pairs(empty or {}) do
        if is_empty == true then
            if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, validated_extra_anchors) then
                return false, loc("error_invalid_empty_slot", tostring(slot_name))
            end

            validated_applied[slot_name] = nil
            validated_suppressed[slot_name] = nil
            validated_empty[slot_name] = true
        end
    end

    if same_string_map(validated_applied, _look_state.applied)
        and same_string_map(validated_suppressed, _look_state.suppressed)
        and same_string_map(validated_empty, _look_state.empty)
        and same_string_map(validated_extra_anchors, _look_state.extra_anchors)
        and EXTRA_SLOTS.same_transforms(validated_extra_transforms, _look_state.extra_transforms, validated_extra_anchors)
        and EXTRA_SLOTS.same_material_maps(validated_materials, _look_state.materials)
        and RAW_UNITS.same_variant_maps(validated_variants, _look_state.variants)
        and MASKS.same_maps(validated_masks, _look_state.masks)
        and MESHES.same_maps(validated_meshes, _look_state.meshes)
        and util.same_opacity_maps(validated_opacity, _look_state.opacity) then
        local current_ok = live_visual.matches(player)

        if current_ok then
            return true
        end

        local reapplied, reapply_error = push_look()

        return reapplied, reapply_error
    end

    local previous_applied = clone_string_map(_look_state.applied)
    local previous_suppressed = clone_string_map(_look_state.suppressed)
    local previous_empty = clone_string_map(_look_state.empty)
    local previous_extra_anchors = clone_string_map(_look_state.extra_anchors)
    local previous_extra_transforms = EXTRA_SLOTS.clone_transforms(_look_state.extra_transforms, _look_state.extra_anchors)
    local previous_materials = EXTRA_SLOTS.clone_material_map(_look_state.materials)
    local previous_variants = RAW_UNITS.clone_variant_map(_look_state.variants)
    local previous_masks = MASKS.clone_map(_look_state.masks)
    local previous_opacity = util.clone_opacity_map(_look_state.opacity)
    local previous_meshes = MESHES.clone_map(_look_state.meshes)

    local removed_slots = {}

    for slot_name in pairs(_originals) do
        if not validated_applied[slot_name] and not validated_suppressed[slot_name]
            and not validated_empty[slot_name] and not validated_materials[slot_name]
            and not validated_masks[slot_name]
            and not validated_meshes[slot_name]
            and util.normalize_opacity(validated_opacity[slot_name]) == util.opacity_default then
            removed_slots[slot_name] = true
        end
    end

    if next(removed_slots) and not restore_slots(player, removed_slots) then
        restore_string_map(_look_state.applied, previous_applied)
        restore_string_map(_look_state.suppressed, previous_suppressed)
        restore_string_map(_look_state.empty, previous_empty)
        restore_string_map(_look_state.extra_anchors, previous_extra_anchors)
        EXTRA_SLOTS.restore_transforms(_look_state.extra_transforms, previous_extra_transforms, previous_extra_anchors)
        EXTRA_SLOTS.restore_material_map(_look_state.materials, previous_materials)
        _look_state.variants = RAW_UNITS.clone_variant_map(previous_variants)
        _look_state.masks = MASKS.clone_map(previous_masks)
        _look_state.opacity = util.clone_opacity_map(previous_opacity)
        _look_state.meshes = MESHES.clone_map(previous_meshes)
        repair_visual_after_state_restore()
        return false, loc("error_restore_removed")
    end

    restore_string_map(_look_state.applied, validated_applied)
    restore_string_map(_look_state.suppressed, validated_suppressed)
    restore_string_map(_look_state.empty, validated_empty)
    restore_string_map(_look_state.extra_anchors, validated_extra_anchors)
    EXTRA_SLOTS.restore_transforms(_look_state.extra_transforms, validated_extra_transforms, validated_extra_anchors)
    EXTRA_SLOTS.restore_material_map(_look_state.materials, validated_materials)
    _look_state.variants = RAW_UNITS.clone_variant_map(validated_variants)
    _look_state.masks = MASKS.clone_map(validated_masks)
    _look_state.opacity = util.clone_opacity_map(validated_opacity)
    _look_state.meshes = MESHES.clone_map(validated_meshes)

    local applied_ok, apply_error = push_look()

    if applied_ok then
        _reapply_pending = false
        util.reset_retry(_reapply_retry)
        util.report_once(_runtime_reports, "reapply", nil)
        return true
    end

    restore_string_map(_look_state.applied, previous_applied)
    restore_string_map(_look_state.suppressed, previous_suppressed)
    restore_string_map(_look_state.empty, previous_empty)
    restore_string_map(_look_state.extra_anchors, previous_extra_anchors)
    EXTRA_SLOTS.restore_transforms(_look_state.extra_transforms, previous_extra_transforms, previous_extra_anchors)
    EXTRA_SLOTS.restore_material_map(_look_state.materials, previous_materials)
    _look_state.variants = RAW_UNITS.clone_variant_map(previous_variants)
    _look_state.masks = MASKS.clone_map(previous_masks)
    _look_state.opacity = util.clone_opacity_map(previous_opacity)
    _look_state.meshes = MESHES.clone_map(previous_meshes)
    repair_visual_after_state_restore()

    return false, loc("error_visual_apply", tostring(apply_error or loc("generic_unknown_error")))
end

mod.npclook_import_code = function(code)
    local applied, suppressed, empty, count_or_error, _, extra_anchors, extra_transforms,
        materials, variants, masks, opacity, meshes = decode_look_code(code)

    if not applied then
        return false, count_or_error
    end

    local ok, err = mod.npclook_commit_state(
        applied, suppressed, empty, extra_anchors, extra_transforms, materials, variants, masks, opacity, meshes
    )

    if not ok then
        return false, err
    end

    return true, count_or_error
end

local studio_preview_snapshot

function INTERNAL.finalize_studio_session(session)
    if not session or session ~= _studio_session then
        return _studio_session == nil
    end

    session.preview_input = nil
    _studio_session = nil
    _studio_item_catalog = nil
    RAW_UNITS.release_transient_cache()
    CUSTOM_ASSETS.release_cache()

    return true
end

function INTERNAL.studio_attach_view(view_name)
    local session = _studio_session

    if not session or session.closing == true then
        return false
    end

    view_name = type(view_name) == "string" and view_name or nil

    if not view_name or view_name == "" then
        return false
    end

    session.view_owners = type(session.view_owners) == "table" and session.view_owners or {}
    session.view_owners[view_name] = true

    return true
end

function INTERNAL.studio_detach_view(view_name)
    local session = _studio_session

    if not session then
        return true
    end

    local owners = type(session.view_owners) == "table" and session.view_owners or {}
    session.view_owners = owners

    if type(view_name) == "string" then
        owners[view_name] = nil
    end

    if session.closing == true and next(owners) == nil then
        return INTERNAL.finalize_studio_session(session)
    end

    return true
end

function INTERNAL.finish_studio_session(force)
    local session = _studio_session

    if not session then
        return true
    end

    session.preview_input = nil
    session.closing = true

    local owners = type(session.view_owners) == "table" and session.view_owners or {}
    session.view_owners = owners

    if force == true or next(owners) == nil then
        return INTERNAL.finalize_studio_session(session)
    end

    return true
end

function INTERNAL.studio_view_attached(view_name)
    local session = _studio_session
    local owners = session and session.view_owners

    return type(owners) == "table" and owners[view_name] == true
end

function INTERNAL.studio_session_available()
    return _studio_session ~= nil
end

function INTERNAL.studio_session_closing()
    return _studio_session ~= nil and _studio_session.closing == true
end

function EXTRA_SLOTS.selected_materials(session)
    local slot_name = session.selected_slot

    if EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        return EXTRA_SLOTS.normalize_transform(session.extra_transforms[slot_name]).materials
    end

    return EXTRA_SLOTS.normalize_materials(session.materials[slot_name])
end

function EXTRA_SLOTS.set_selected_materials(session, materials)
    local slot_name = session.selected_slot

    if EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[slot_name])
        transform.materials = materials
        session.extra_transforms[slot_name] = EXTRA_SLOTS.normalize_transform(transform)
    elseif valid_look_slot(slot_name) then
        local normalized = EXTRA_SLOTS.normalize_materials(materials)
        session.materials[slot_name] = #normalized > 0 and normalized or nil
    end
end

local STUDIO_MESH_PAGE_SIZE = 11

-- A mesh selection only targets the slot it was made on.
function INTERNAL.mesh_material_mode(session)
    return session.studio_tab == "meshes" and type(session.selected_mesh) == "string"
        and session.selected_mesh_slot == session.selected_slot
end

function INTERNAL.selected_mesh_state(session, create)
    local slot_name = session.selected_slot
    local item_name = INTERNAL.slot_visual_item_name(session, slot_name)

    if not item_name then
        return nil, slot_name
    end

    local state = MESHES.normalize_state(session.meshes[slot_name], item_name)

    if not state and create then
        state = {
            item_name = item_name,
            hidden = {},
            materials = {},
        }
    end

    return state, slot_name, item_name
end

function INTERNAL.store_mesh_state(session, slot_name, state)
    session.meshes[slot_name] = state and MESHES.normalize_state(state, state.item_name) or nil
end

-- Materials shown and toggled for the current target: one mesh in the Meshes tab, else the slot.
function INTERNAL.active_materials(session)
    if INTERNAL.mesh_material_mode(session) then
        local state = INTERNAL.selected_mesh_state(session, false)

        return state and table.clone(state.materials[session.selected_mesh] or {}) or {}
    end

    return EXTRA_SLOTS.selected_materials(session)
end

function INTERNAL.active_material_entry(session, material_item)
    return EXTRA_SLOTS.material_entry(
        material_item,
        not INTERNAL.mesh_material_mode(session) and session.material_target or nil
    )
end

function INTERNAL.set_active_materials(session, materials)
    if not INTERNAL.mesh_material_mode(session) then
        EXTRA_SLOTS.set_selected_materials(session, materials)
        return true
    end

    local state, slot_name = INTERNAL.selected_mesh_state(session, true)

    if not state then
        return false
    end

    state.materials[session.selected_mesh] = EXTRA_SLOTS.normalize_materials(materials)
    INTERNAL.store_mesh_state(session, slot_name, state)

    return true
end

function EXTRA_SLOTS.report_mesh_inventory(slot_name, rows)
    local session = _studio_session

    if not session or session.closing == true or (not valid_look_slot(slot_name)
        and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)) then
        return false
    end

    local result = {}

    for i = 1, math.min(#(rows or {}), 512) do
        local row = rows[i]

        if type(row) == "table" and MESHES.valid_key(row.key) then
            result[#result + 1] = {
                key = row.key,
                scope = tostring(row.scope or "root"),
                index = tonumber(row.index) or 1,
                material_count = tonumber(row.material_count) or 0,
            }
        end
    end

    session.mesh_inventory[slot_name] = result

    return true
end

function INTERNAL.mesh_label(key)
    local scope, index = MESHES.key_parts(key)

    if not scope then
        return nil
    end

    local scope_label = scope == "root" and loc("ui_mesh_base") or string.upper(INTERNAL.display_token(scope))

    return string.format("%s %02d  %s", loc("ui_mesh"), index, scope_label)
end

function INTERNAL.mesh_rows(session)
    local inventory = session.mesh_inventory[session.selected_slot] or {}
    local state = INTERNAL.selected_mesh_state(session, false)

    session.mesh_page, session.mesh_page_count = INTERNAL.clamp_page(session.mesh_page, #inventory, STUDIO_MESH_PAGE_SIZE)

    local rows = {}

    for _, entry in ipairs(INTERNAL.page_slice(inventory, session.mesh_page, STUDIO_MESH_PAGE_SIZE)) do
        local hidden = state and state.hidden[entry.key] == true
        local overrides = state and #(state.materials[entry.key] or {}) or 0

        rows[#rows + 1] = {
            id = entry.key,
            label = INTERNAL.mesh_label(entry.key),
            sub = loc("ui_mesh_details", entry.material_count, overrides),
            selected = session.selected_mesh == entry.key,
            hidden = hidden,
        }
    end

    return rows, #inventory
end

function INTERNAL.studio_snapshot()
    local session = _studio_session

    if not session or session.closing == true then
        return nil, loc("error_snapshot_bridge")
    end

    local player = get_local_player()

    if not player then
        return nil, loc("error_local_player_not_ready")
    end

    session.player = player

    if (session.item_mode == "units" or session.item_mode == "assets") and not RAW_UNITS.available()
        or session.item_mode == "assets" and not CUSTOM_ASSETS.available() then
        session.item_mode = "slot"
        session.item_page = 1
        session.item_search_cache_key = nil
        session.item_search_results = nil
        session.feedback = loc("feedback_units_require_resource_loader")
    elseif session.item_mode == "nodes" and not INTERNAL.node_library_available(session) then
        session.item_mode = "slot"
        session.item_page = 1
        session.selected_item = nil
        session.preview_attach_node = nil
        session.node_skeleton_visible = false
        session.item_search_cache_key = nil
        session.item_search_results = nil
        session.feedback = loc("feedback_nodes_unavailable")
    end

    local catalog = studio_item_catalog()

    if not catalog then
        return nil, loc("error_master_cache_not_ready")
    end

    local item_entries = INTERNAL.selected_item_entries(session, catalog)
    session.item_page, session.item_page_count = INTERNAL.clamp_page(session.item_page, #item_entries, STUDIO_ITEM_PAGE_SIZE)
    local visible_items = INTERNAL.page_slice(item_entries, session.item_page, STUDIO_ITEM_PAGE_SIZE)
    local item_rows = {}

    for i = 1, #visible_items do
        local entry = visible_items[i]
        local slot_hint = session.item_mode == "slot" and entry.slot and (STUDIO_SLOT_LABELS[entry.slot] or entry.slot)
            or tostring(entry.sub or "")
        local selected = session.selected_item == entry.name

        if session.item_mode == "nodes" then
            local current_node = EXTRA_SLOTS.normalize_transform(
                session.extra_transforms[session.selected_slot]
            ).attach_node
            selected = selected or current_node == entry.name
        elseif session.item_mode == "materials" or session.item_mode == "assets" and CUSTOM_ASSETS.parse_entry_id(entry.name) then
            local material_item = session.item_mode == "materials" and entry.name
                or INTERNAL.asset_material_item(session, entry.name)
            local material_entry = INTERNAL.active_material_entry(session, material_item)
            local applied_material = material_entry
                and table.contains(INTERNAL.active_materials(session), material_entry)
            selected = selected or applied_material
            slot_hint = applied_material and loc("ui_material_applied", slot_hint) or slot_hint
        end

        item_rows[#item_rows + 1] = {
            id = entry.name,
            label = entry.label or INTERNAL.display_token(entry.name),
            sub = slot_hint,
            slot = entry.slot,
            selected = selected,
            applicable = INTERNAL.studio_item_is_applicable(session, entry.name),
        }
    end

    local source_entries = INTERNAL.selected_source_entries(session, catalog)
    session.source_page, session.source_page_count = INTERNAL.clamp_page(session.source_page, #source_entries, STUDIO_SOURCE_PAGE_SIZE)
    local visible_sources = INTERNAL.page_slice(source_entries, session.source_page, STUDIO_SOURCE_PAGE_SIZE)

    for i = 1, #visible_sources do
        visible_sources[i].selected = session.selected_source == visible_sources[i].id
    end

    local profile = safe_profile(player)
    local source_loadout = profile and profile.loadout or {}
    local original_slots = {}
    local extra_slots = {}
    local slot_order = EXTRA_SLOTS.slot_order(session.extra_anchors)

    for i = 1, #slot_order do
        local slot_name = slot_order[i]
        local is_extra = EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)
        local item_name = session.applied[slot_name]
        local hidden = INTERNAL.slot_is_hidden(session, slot_name)
        local empty = session.empty[slot_name] == true
        local inherited = not is_extra and INTERNAL.original_item_name(source_loadout, slot_name) or nil
        local display_name = item_name or inherited
        local item_label = loc("generic_empty")
        local changed = session.applied[slot_name] ~= session.live_applied[slot_name]
            or session.suppressed[slot_name] ~= session.live_suppressed[slot_name]
            or session.empty[slot_name] ~= session.live_empty[slot_name]
            or session.extra_anchors[slot_name] ~= session.live_extra_anchors[slot_name]
            or (is_extra and EXTRA_SLOTS.transform_signature(session.extra_transforms[slot_name])
                ~= EXTRA_SLOTS.transform_signature(session.live_extra_transforms[slot_name]))
            or (not is_extra and EXTRA_SLOTS.material_list_signature(session.materials[slot_name])
                ~= EXTRA_SLOTS.material_list_signature(session.live_materials[slot_name]))
            or RAW_UNITS.variant_signature(session.variants[slot_name])
                ~= RAW_UNITS.variant_signature(session.live_variants[slot_name])
            or MASKS.signature(session.masks[slot_name])
                ~= MASKS.signature(session.live_masks[slot_name])
            or MESHES.signature(session.meshes[slot_name])
                ~= MESHES.signature(session.live_meshes[slot_name])
            or util.normalize_opacity(session.opacity[slot_name])
                ~= util.normalize_opacity(session.live_opacity[slot_name])

        if hidden then
            item_label = loc("generic_hidden")
        elseif not empty and display_name then
            item_label = INTERNAL.display_token(display_name)
        end

        local slot_entry = {
            id = slot_name,
            label = EXTRA_SLOTS.label(slot_name, session.extra_anchors),
            item = display_name,
            item_label = item_label,
            hidden = hidden,
            empty = empty,
            changed = changed,
            selected = slot_name == session.selected_slot,
            inherited = not is_extra and not hidden and not empty and item_name == nil,
        }

        if is_extra then
            extra_slots[#extra_slots + 1] = slot_entry
        else
            original_slots[#original_slots + 1] = slot_entry
        end
    end

    local extra_page_size = EXTRA_SLOTS.studio_extra_slot_page_size
    local extra_page_count = math.ceil(#extra_slots / extra_page_size)
    session.slot_page_count = math.max(1, 1 + extra_page_count)
    session.slot_page = math.clamp(session.slot_page or 1, 1, session.slot_page_count)

    local slots

    if session.slot_page == 1 then
        slots = original_slots
    else
        slots = INTERNAL.page_slice(extra_slots, session.slot_page - 1, extra_page_size)
    end

    local selected_details = session.item_mode ~= "nodes"
        and session.selected_item and mod.npclook_inspect_item(session.selected_item) or nil
    local source_outfit = INTERNAL.source_blueprint(session)
    local source_slots = {}

    for slot_name, item_name in pairs(source_outfit or {}) do
        source_slots[#source_slots + 1] = {
            slot = slot_name,
            slot_label = STUDIO_SLOT_LABELS[slot_name] or slot_name,
            item = item_name,
            item_label = INTERNAL.display_token(item_name),
        }
    end

    table.sort(source_slots, function(a, b)
        return a.slot_label < b.slot_label
    end)

    local selected_source_label = loc("generic_none")

    if session.selected_source then
        if session.source_kind == "player" then
            selected_source_label = string.upper(session.selected_source)
        else
            selected_source_label = string.upper(INTERNAL.display_token(session.selected_source))
        end
    end

    local detected_targets = session.detected_material_slots[session.selected_slot] or {}
    local material_targets = { EXTRA_SLOTS.material_target_all }

    for i = 1, #detected_targets do
        material_targets[#material_targets + 1] = detected_targets[i]
    end

    if session.selected_mesh_slot ~= session.selected_slot then
        session.selected_mesh = nil
        session.selected_mesh_slot = nil
        session.mesh_page = 1
    end

    local selected_materials = INTERNAL.active_materials(session)
    local mesh_rows, mesh_count

    if session.studio_tab == "meshes" then
        mesh_rows, mesh_count = INTERNAL.mesh_rows(session)
    end

    local selected_material_displays = {}

    for i = 1, #selected_materials do
        selected_material_displays[i] = EXTRA_SLOTS.material_display(selected_materials[i])
    end

    local selected_visual_name = INTERNAL.selected_visual_item_name(session)
    local selected_variant_name = selected_visual_name
    local selected_variant_item = selected_variant_name and item_definition(selected_variant_name)
    local selected_variant_state = RAW_UNITS.normalize_variant_state(
        session.variants[session.selected_slot],
        selected_variant_name
    )
    local variant_families = selected_variant_item and selected_variant_item.npclook_raw_variant_families or {}
    local visibility_groups = selected_variant_item and selected_variant_item.npclook_raw_visibility_groups or {}
    session.variant_family_index = math.clamp(session.variant_family_index or 1, 1, math.max(#variant_families, 1))
    session.visibility_group_index = math.clamp(session.visibility_group_index or 1, 1, math.max(#visibility_groups, 1))
    local selected_family = variant_families[session.variant_family_index]
    local selected_group = visibility_groups[session.visibility_group_index]
    local selected_family_name = selected_family and tostring(selected_family.name or "") or nil
    local selected_group_name = selected_group
        and tostring(type(selected_group) == "table" and selected_group.name or selected_group)
        or nil
    local selected_mask_name = selected_visual_name
    local selected_mask_item = selected_mask_name and item_definition(selected_mask_name)
    local mask_rows = {}

    local selected_mask_slot = session.selected_slot

    if selected_mask_item and valid_look_slot(selected_mask_slot) then
        local rows = MASKS.rows(
            selected_mask_item,
            item_cache(),
            selected_mask_slot,
            session.masks[session.selected_slot]
        )

        for i = 1, #rows do
            local row = rows[i]

            mask_rows[i] = {
                can_toggle = row.can_toggle,
                enabled = row.enabled,
                field = row.field,
                field_label = loc(MASKS.field_label_key(row.field)),
                option_count = row.option_count,
                value_label = row.value_label,
            }
        end
    end

    local can_edit_variants = selected_variant_item ~= nil and selected_variant_item.npclook_raw_unit == true
        and (#variant_families > 0 or #visibility_groups > 0)
    local can_edit_masks = #mask_rows > 0

    if session.variant_control_mode == "visibility" and #visibility_groups == 0 then
        session.variant_control_mode = "families"
    elseif session.variant_control_mode ~= "visibility" and #variant_families == 0
        and #visibility_groups > 0 then
        session.variant_control_mode = "visibility"
    end

    if session.visual_options_mode == "masks" and not can_edit_masks then
        session.visual_options_mode = "variants"
    elseif session.visual_options_mode ~= "masks" and not can_edit_variants and can_edit_masks then
        session.visual_options_mode = "masks"
    end

    return {
        slots = slots,
        selected_slot = session.selected_slot,
        selected_slot_label = EXTRA_SLOTS.label(session.selected_slot, session.extra_anchors),
        selected_opacity = util.normalize_opacity(session.opacity[session.selected_slot]),
        selected_hidden = INTERNAL.slot_is_hidden(session, session.selected_slot),
        clipboard_label = INTERNAL.slot_clipboard and INTERNAL.slot_clipboard.label or nil,
        studio_tab = session.studio_tab,
        mesh_rows = mesh_rows,
        mesh_count = mesh_count or 0,
        mesh_page = session.mesh_page,
        mesh_page_count = session.mesh_page_count or 1,
        selected_mesh = session.selected_mesh,
        mesh_target_label = INTERNAL.mesh_material_mode(session) and INTERNAL.mesh_label(session.selected_mesh) or nil,
        has_mesh_state = session.meshes[session.selected_slot] ~= nil,
        can_edit_meshes = INTERNAL.slot_visual_item_name(session, session.selected_slot) ~= nil,
        all_hidden = INTERNAL.all_slots_hidden(session),
        can_toggle_extra_first_person = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors),
        can_toggle_extra_first_person_animation = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)
            and EXTRA_SLOTS.normalize_transform(session.extra_transforms[session.selected_slot]).first_person,
        can_toggle_extra_transform = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors),
        can_edit_extra_transform = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)
            and EXTRA_SLOTS.normalize_transform(session.extra_transforms[session.selected_slot]).enabled,
        can_toggle_extra_transform_deform = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)
            and EXTRA_SLOTS.normalize_transform(session.extra_transforms[session.selected_slot]).enabled,
        can_toggle_extra_xyz_scale = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)
            and EXTRA_SLOTS.normalize_transform(session.extra_transforms[session.selected_slot]).enabled,
        selected_extra_transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[session.selected_slot]),
        can_use_nodes = INTERNAL.node_library_available(session),
        node_mode = session.item_mode == "nodes",
        node_skeleton_visible = session.item_mode == "nodes" and session.node_skeleton_visible == true,
        selected_attach_node = EXTRA_SLOTS.normalize_transform(
            session.extra_transforms[session.selected_slot]
        ).attach_node,
        preview_attach_node = EXTRA_SLOTS.normalize_attach_node(session.preview_attach_node)
            or EXTRA_SLOTS.normalize_transform(session.extra_transforms[session.selected_slot]).attach_node,
        slot_page = session.slot_page,
        slot_page_count = session.slot_page_count,
        can_remove_extra_slot = EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors),
        can_remove_all_extra_slots = #EXTRA_SLOTS.ids(session.extra_anchors) > 0,
        items = item_rows,
        item_mode = session.item_mode,
        can_use_units = RAW_UNITS.available(),
        can_use_assets = RAW_UNITS.available() and CUSTOM_ASSETS.available(),
        asset_material_selected = INTERNAL.selected_asset_material(session) ~= nil,
        asset_slot_label = (function()
            local engine_type = INTERNAL.selected_asset_material(session)

            if not engine_type then
                return nil
            end

            local material_slot, index, count = INTERNAL.selected_asset_slot(session, engine_type)

            return material_slot and string.format("%s %d/%d: %s",
                loc(engine_type == "material" and "ui_asset_material_slot" or "ui_asset_texture_slot"),
                index, count, material_slot) or loc("ui_asset_no_slots")
        end)(),
        item_page = session.item_page,
        item_page_count = session.item_page_count,
        item_result_count = #item_entries,
        item_search = session.item_search or "",
        selected_item = session.selected_item,
        selected_item_applicable = session.selected_item ~= nil
            and INTERNAL.studio_item_is_applicable(session, session.selected_item),
        selected_details = selected_details,
        can_edit_variants = can_edit_variants,
        can_edit_masks = can_edit_masks,
        can_switch_visual_options = can_edit_variants and can_edit_masks,
        visual_options_mode = session.visual_options_mode == "masks" and "masks" or "variants",
        can_switch_variant_controls = #variant_families > 0 and #visibility_groups > 0,
        variant_control_mode = session.variant_control_mode == "visibility"
            and "visibility" or "families",
        mask_rows = mask_rows,
        variant_family_count = #variant_families,
        variant_family_index = session.variant_family_index,
        variant_family_name = selected_family_name,
        variant_family_options = selected_family and selected_family.options or {},
        variant_family_value = selected_family_name and selected_variant_state.families[selected_family_name] or nil,
        visibility_group_count = #visibility_groups,
        visibility_group_index = session.visibility_group_index,
        visibility_group_name = selected_group_name,
        visibility_group_value = selected_group_name and selected_variant_state.visibility[selected_group_name] or nil,
        show_authored_slots = session.item_mode == "slot",
        material_mode = session.item_mode == "materials",
        selected_materials = selected_material_displays,
        material_targets = material_targets,
        material_target = session.material_target or EXTRA_SLOTS.material_target_all,
        material_target_label = type(session.material_target) == "string" and session.material_target ~= ""
            and EXTRA_SLOTS.material_target_label(session.material_target)
            or loc("ui_material_target_all"),
        can_pick_materials = valid_look_slot(session.selected_slot)
            or EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors),
        sources = visible_sources,
        source_kind = session.source_kind,
        source_page = session.source_page,
        source_page_count = session.source_page_count,
        selected_source = session.selected_source,
        selected_source_label = selected_source_label,
        source_slots = source_slots,
        source_preview = session.source_preview,
        dirty_count = INTERNAL.studio_dirty_count(session),
        can_undo = #session.history > 0,
        can_redo = #session.redo > 0,
        inspect_mode = session.inspect_mode == true,
        camera_focus = session.camera_focus,
        feedback = session.feedback,
    }
end

function INTERNAL.stage_slot_state(session, state)
    local slot_name = session.selected_slot

    if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    session.variants[slot_name] = nil
    session.masks[slot_name] = nil
    session.meshes[slot_name] = nil
    session.opacity[slot_name] = nil
    session.applied[slot_name] = nil
    session.suppressed[slot_name] = state == "hidden" and true or nil
    session.empty[slot_name] = state == "empty" and true or nil
    session.preview_item = nil
    session.preview_material_item = nil
    session.preview_attach_node = nil
    INTERNAL.record_history_change(session, previous)

    return true
end

local STUDIO_ACTIONS = {}

STUDIO_ACTIONS.camera_focus = function(session, action)
    local camera = CAMERA_FOCUS_LABELS[action.camera] and action.camera or "full"
    session.camera_focus = camera
    session.feedback = loc("feedback_camera_focus", CAMERA_FOCUS_LABELS[camera])
end

STUDIO_ACTIONS.toggle_inspect = function(session)
    session.inspect_mode = not session.inspect_mode
    session.preview_input = nil
    session.camera_reset_revision = (session.camera_reset_revision or 0) + 1
    session.feedback = session.inspect_mode and loc("feedback_inspect_on") or loc("feedback_inspect_off")
end

STUDIO_ACTIONS.reset_camera = function(session)
    session.camera_reset_revision = (session.camera_reset_revision or 0) + 1
    session.feedback = loc("feedback_camera_reset")
end

STUDIO_ACTIONS.cycle_item = function(session, action)
    local catalog = studio_item_catalog()
    local entries = catalog and INTERNAL.selected_item_entries(session, catalog) or {}
    local count = #entries

    if count == 0 then
        session.feedback = loc("feedback_no_library_pieces")
        return
    end

    local current_index = 0

    for i = 1, count do
        if entries[i].name == session.selected_item then
            current_index = i
            break
        end
    end

    local step = INTERNAL.signed_delta(action.delta, 1)
    local next_index = ((current_index - 1 + step) % count) + 1
    local entry = entries[next_index]
    session.selected_item = entry.name
    session.source_preview = nil
    session.item_page = math.ceil(next_index / STUDIO_ITEM_PAGE_SIZE)

    if session.item_mode == "materials" then
        session.preview_material_item = entry.name
        session.preview_item = nil
        session.feedback = loc("feedback_selected_material", INTERNAL.display_token(entry.name))
        return
    elseif session.item_mode == "assets" and CUSTOM_ASSETS.parse_entry_id(entry.name) then
        session.preview_material_item = INTERNAL.asset_material_item(session, entry.name)
        session.preview_item = nil
        session.feedback = loc("feedback_selected_material", INTERNAL.display_token(entry.name))
        return
    end

    session.preview_material_item = nil

    if not INTERNAL.studio_item_is_applicable(session, entry.name) then
        session.preview_item = nil
        session.feedback = loc("error_visual_slot_unavailable")
    elseif INTERNAL.preview_candidate_is_safe(session, entry.name) then
        session.preview_item = entry.name
        session.feedback = loc("feedback_previewing_item", INTERNAL.display_token(entry.name))
    else
        session.preview_item = nil
        session.feedback = loc("feedback_preview_attachment_cycle")
    end
end

STUDIO_ACTIONS.set_search = function(session, action)
    local query = INTERNAL.truncate_search_query(action.query)

    if query ~= session.item_search then
        session.item_search = query
        session.item_search_cache_key = nil
        session.item_search_results = nil
        session.item_page = 1
        session.feedback = query == "" and loc("feedback_search_clear") or loc("feedback_searching", query)
    end
end

STUDIO_ACTIONS.select_slot = function(session, action)
    if not valid_look_slot(action.slot) and not EXTRA_SLOTS.is_slot(action.slot, session.extra_anchors) then
        return false
    end

    session.selected_slot = action.slot
    session.selected_mesh = nil
    session.mesh_page = 1
    session.camera_focus = nil
    session.preview_item = nil
    session.preview_material_item = nil
    session.preview_attach_node = nil
    session.material_target = nil
    session.selected_item = nil
    session.variant_family_index = 1
    session.visibility_group_index = 1
    session.variant_control_mode = "families"

    session.item_applicability_cache = {}

    if session.item_mode == "nodes" and not INTERNAL.node_library_available(session) then
        session.item_mode = "slot"
        session.node_skeleton_visible = false
        session.item_page = 1
    end

    session.feedback = loc("feedback_selected_item", EXTRA_SLOTS.label(action.slot, session.extra_anchors))
end

STUDIO_ACTIONS.slot_page = function(session, action)
    session.slot_page = session.slot_page + INTERNAL.signed_delta(action.delta)
end

STUDIO_ACTIONS.set_opacity = function(session, action)
    local slot_name = session.selected_slot

    if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    local value = util.normalize_opacity(action.value)
    local previous = INTERNAL.history_snapshot(session)
    session.opacity[slot_name] = value ~= util.opacity_default and value or nil
    session.preview_item = nil
    session.preview_material_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_opacity_set", value)
end

-- The slot clipboard outlives preset loads and Studio sessions until the mod reloads.
INTERNAL.slot_clipboard = nil

function INTERNAL.capture_slot(session, slot_name)
    local is_extra = EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)
    local anchor = EXTRA_SLOTS.anchor(slot_name, session.extra_anchors)

    if not valid_look_slot(anchor) then
        return nil, loc("feedback_select_destination")
    end

    local hidden = session.suppressed[slot_name] == true
    local item_name = not hidden and INTERNAL.slot_visual_item_name(session, slot_name) or nil

    if not item_name and not hidden then
        return nil, loc("feedback_clone_slot_empty")
    end

    local transform = is_extra and EXTRA_SLOTS.normalize_transform(session.extra_transforms[slot_name]) or nil
    local materials = is_extra and transform.materials or EXTRA_SLOTS.normalize_materials(session.materials[slot_name])

    return {
        source_slot = slot_name,
        source_is_extra = is_extra,
        anchor = anchor,
        label = EXTRA_SLOTS.label(slot_name, session.extra_anchors),
        item_name = item_name,
        hidden = hidden,
        transform = transform,
        materials = materials,
        variants = item_name and session.variants[slot_name]
            and RAW_UNITS.normalize_variant_state(session.variants[slot_name], item_name) or nil,
        masks = not is_extra and item_name and session.masks[slot_name]
            and MASKS.clone_state(session.masks[slot_name]) or nil,
        opacity = session.opacity[slot_name],
        hidden_opacity_restore = session.hidden_opacity_restore[slot_name],
        meshes = item_name and session.meshes[slot_name]
            and MESHES.normalize_state(session.meshes[slot_name], item_name) or nil,
    }
end

function INTERNAL.clipboard_item_usable(session, clip)
    if not clip.item_name then
        return true
    end

    local item = item_definition(clip.item_name)
    local breed_name = profile_breed_name(safe_profile(session.player))

    if not item then
        return false, loc("feedback_clone_slot_empty")
    elseif util.item_is_2d(item, clip.item_name)
        or item.npclook_raw_unit ~= true and not util.item_has_visual_base(item, breed_name) then
        return false, loc("error_visual_slot_unavailable")
    end

    return true
end

function INTERNAL.write_clip_to_slot(session, slot_name, clip)
    local is_extra = EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)

    session.applied[slot_name] = clip.item_name
    session.suppressed[slot_name] = clip.hidden and true or nil
    session.empty[slot_name] = not clip.item_name and not clip.hidden and true or nil
    session.variants[slot_name] = clip.variants and RAW_UNITS.normalize_variant_state(clip.variants, clip.item_name) or nil
    session.opacity[slot_name] = clip.opacity
    session.hidden_opacity_restore[slot_name] = clip.hidden_opacity_restore
    session.meshes[slot_name] = clip.meshes and MESHES.normalize_state(clip.meshes, clip.item_name) or nil

    if is_extra then
        local transform = clip.transform and EXTRA_SLOTS.normalize_transform(clip.transform)
            or EXTRA_SLOTS.normalize_transform(session.extra_transforms[slot_name])

        transform.materials = EXTRA_SLOTS.normalize_materials(clip.materials)
        session.extra_transforms[slot_name] = EXTRA_SLOTS.normalize_transform(transform)
        session.masks[slot_name] = nil
    else
        local materials = EXTRA_SLOTS.normalize_materials(clip.materials)
        session.materials[slot_name] = #materials > 0 and materials or nil
        -- Mask fields are authored per slot.
        session.masks[slot_name] = clip.masks and clip.source_slot == slot_name
            and MASKS.clone_state(clip.masks) or nil
    end
end

function INTERNAL.paste_clip_as_extra(session, clip)
    local usable, usable_error = INTERNAL.clipboard_item_usable(session, clip)

    if not usable then
        session.feedback = usable_error
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local id = EXTRA_SLOTS.next_id(session.extra_anchors)

    session.extra_anchors[id] = clip.anchor
    session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(clip.transform)
    INTERNAL.write_clip_to_slot(session, id, clip)

    if INTERNAL.preview_has_attachment_cycle(session.player, session.applied, session.suppressed, session.empty) then
        INTERNAL.restore_history_snapshot(session, previous)
        session.feedback = loc("feedback_preview_attachment_cycle")
        return false
    end

    session.selected_slot = id
    session.slot_page = 1 + math.ceil(#EXTRA_SLOTS.ids(session.extra_anchors) / EXTRA_SLOTS.studio_extra_slot_page_size)
    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.selected_item = nil
    session.variant_family_index = 1
    session.visibility_group_index = 1
    session.variant_control_mode = "families"
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)

    return true, id
end

STUDIO_ACTIONS.clone_slot = function(session)
    local clip, clip_error = INTERNAL.capture_slot(session, session.selected_slot)

    if not clip then
        session.feedback = clip_error
        return false
    end

    local ok, id = INTERNAL.paste_clip_as_extra(session, clip)

    if not ok then
        return false
    end

    session.feedback = loc("feedback_slot_cloned", EXTRA_SLOTS.label(id, session.extra_anchors))
end

STUDIO_ACTIONS.copy_slot = function(session)
    local clip, clip_error = INTERNAL.capture_slot(session, session.selected_slot)

    if not clip then
        session.feedback = clip_error
        return false
    end

    INTERNAL.slot_clipboard = clip
    session.feedback = loc("feedback_slot_copied", clip.label)
end

STUDIO_ACTIONS.paste_slot_extra = function(session)
    local clip = INTERNAL.slot_clipboard

    if not clip then
        session.feedback = loc("feedback_clipboard_empty")
        return false
    end

    local ok, id = INTERNAL.paste_clip_as_extra(session, clip)

    if not ok then
        return false
    end

    session.feedback = loc("feedback_slot_pasted", EXTRA_SLOTS.label(id, session.extra_anchors))
end

STUDIO_ACTIONS.paste_slot_into = function(session)
    local clip = INTERNAL.slot_clipboard
    local slot_name = session.selected_slot

    if not clip then
        session.feedback = loc("feedback_clipboard_empty")
        return false
    elseif not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    local usable, usable_error = INTERNAL.clipboard_item_usable(session, clip)

    if not usable then
        session.feedback = usable_error
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    INTERNAL.write_clip_to_slot(session, slot_name, clip)

    if INTERNAL.preview_has_attachment_cycle(session.player, session.applied, session.suppressed, session.empty) then
        INTERNAL.restore_history_snapshot(session, previous)
        session.feedback = loc("feedback_preview_attachment_cycle")
        return false
    end

    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.selected_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_slot_pasted", EXTRA_SLOTS.label(slot_name, session.extra_anchors))
end

STUDIO_ACTIONS.add_extra_slot = function(session)
    local anchor = EXTRA_SLOTS.anchor(session.selected_slot, session.extra_anchors)

    if not valid_look_slot(anchor) then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local id = EXTRA_SLOTS.next_id(session.extra_anchors)
    session.extra_anchors[id] = anchor
    session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(nil)
    session.empty[id] = true
    session.selected_slot = id
    session.slot_page = 1 + math.ceil(#EXTRA_SLOTS.ids(session.extra_anchors) / EXTRA_SLOTS.studio_extra_slot_page_size)
    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.selected_item = nil
    session.variant_family_index = 1
    session.visibility_group_index = 1
    session.variant_control_mode = "families"
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_slot_added", EXTRA_SLOTS.label(id, session.extra_anchors))
end

STUDIO_ACTIONS.remove_extra_slot = function(session)
    local id = session.selected_slot
    local anchor = session.extra_anchors[id]

    if not anchor then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    session.extra_anchors[id] = nil
    session.extra_transforms[id] = nil
    session.materials[id] = nil
    session.variants[id] = nil
    session.masks[id] = nil
    session.meshes[id] = nil
    session.opacity[id] = nil
    session.detected_material_slots[id] = nil
    session.applied[id] = nil
    session.suppressed[id] = nil
    session.empty[id] = nil
    session.selected_slot = anchor
    session.slot_page = 1
    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.selected_item = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_slot_removed")
end

STUDIO_ACTIONS.remove_all_extra_slots = function(session)
    local ids = EXTRA_SLOTS.ids(session.extra_anchors)

    if #ids == 0 then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local selected_anchor = session.extra_anchors[session.selected_slot]

    for i = 1, #ids do
        local id = ids[i]
        session.extra_anchors[id] = nil
        session.extra_transforms[id] = nil
        session.materials[id] = nil
        session.variants[id] = nil
        session.masks[id] = nil
        session.meshes[id] = nil
        session.opacity[id] = nil
        session.detected_material_slots[id] = nil
        session.applied[id] = nil
        session.suppressed[id] = nil
        session.empty[id] = nil
    end

    if selected_anchor then
        session.selected_slot = selected_anchor
        session.preview_item = nil
        session.preview_material_item = nil
        session.material_target = nil
        session.selected_item = nil
    end

    session.slot_page = 1
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_slots_removed", #ids)
end

STUDIO_ACTIONS.set_extra_transform = function(session, action)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local field = action.field
    local allowed = {
        px = true, py = true, pz = true,
        rx = true, ry = true, rz = true,
        scale = true, scale_x = true, scale_y = true, scale_z = true,
    }

    if not allowed[field] or EXTRA_SLOTS.finite_number(action.value, nil) == nil then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
    transform[field] = action.value
    session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(transform)
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_transform_updated")
end

STUDIO_ACTIONS.adjust_extra_transform = function(session, action)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local field = action.field
    local allowed = {
        px = true, py = true, pz = true,
        rx = true, ry = true, rz = true,
        scale = true, scale_x = true, scale_y = true, scale_z = true,
    }

    if not allowed[field] then
        return false
    end

    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
    local current = EXTRA_SLOTS.finite_number(
        transform[field],
        EXTRA_SLOTS.transform_default[field]
    )
    local delta = EXTRA_SLOTS.finite_number(action.delta, 0)
    local next_value = current + delta

    if field == "scale" or field == "scale_x" or field == "scale_y" or field == "scale_z" then
        next_value = math.clamp(next_value, -30, 30)

        if next_value == current then
            return false
        end
    end

    local previous = INTERNAL.history_snapshot(session)
    transform[field] = next_value
    session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(transform)
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_transform_updated")
end

STUDIO_ACTIONS.reset_extra_transform = function(session)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local current = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
    local transform = EXTRA_SLOTS.normalize_transform(nil)
    transform.enabled = current.enabled
    transform.deform = current.deform
    transform.first_person = current.first_person
    transform.animate_first_person = current.animate_first_person
    transform.xyz_scale = current.xyz_scale
    transform.attach_node = current.attach_node
    transform.materials = current.materials
    session.extra_transforms[id] = transform
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_transform_reset")
end

STUDIO_ACTIONS.toggle_extra_first_person = function(session)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
    transform.first_person = not transform.first_person
    session.extra_transforms[id] = transform
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_first_person_updated")
end

STUDIO_ACTIONS.toggle_extra_first_person_animation = function(session)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])

    if not transform.first_person then
        return false
    end

    transform.animate_first_person = not transform.animate_first_person
    session.extra_transforms[id] = transform
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_animate_first_person_updated")
end

STUDIO_ACTIONS.toggle_extra_transform = function(session)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
    transform.enabled = not transform.enabled
    session.extra_transforms[id] = transform
    session.preview_item = nil
    session.preview_attach_node = nil
    session.source_preview = nil

    if session.item_mode == "nodes" and not INTERNAL.node_library_available(session) then
        session.item_mode = "slot"
        session.selected_item = nil
        session.node_skeleton_visible = false
        session.item_page = 1
    end
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_transform_updated")
end

STUDIO_ACTIONS.toggle_extra_xyz_scale = function(session)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])

    if transform.xyz_scale then
        transform.scale = transform.scale_z
        transform.xyz_scale = false
    else
        transform.scale_x = transform.scale
        transform.scale_y = transform.scale
        transform.scale_z = transform.scale
        transform.xyz_scale = true
    end

    session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(transform)
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_transform_updated")
end

STUDIO_ACTIONS.toggle_extra_transform_deform = function(session)
    local id = session.selected_slot

    if not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_extra_slot_select")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
    transform.deform = not transform.deform
    session.extra_transforms[id] = transform
    session.preview_item = nil
    session.preview_attach_node = nil
    session.source_preview = nil

    if session.item_mode == "nodes" and not INTERNAL.node_library_available(session) then
        session.item_mode = "slot"
        session.selected_item = nil
        session.node_skeleton_visible = false
        session.item_page = 1
    end
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_extra_transform_updated")
end

function INTERNAL.selected_variant_item_and_state(session)
    local item_name = INTERNAL.selected_visual_item_name(session)
    local item = item_name and item_definition(item_name)

    if not item or item.npclook_raw_unit ~= true then
        return nil
    end

    local state_value = RAW_UNITS.normalize_variant_state(
        session.variants[session.selected_slot],
        item_name
    )
    state_value.item_name = item_name

    return item, state_value, item_name
end

function INTERNAL.stage_variant_preview(session, state_value, item_name)
    local previous = INTERNAL.history_snapshot(session)
    session.variants[session.selected_slot] = state_value
    session.preview_item = item_name
    session.preview_material_item = nil
    INTERNAL.record_history_change(session, previous)
    session.item_search_cache_key = nil
    return true
end

STUDIO_ACTIONS.cycle_variant_family = function(session, action)
    local item = INTERNAL.selected_variant_item_and_state(session)
    local count = item and #(item.npclook_raw_variant_families or {}) or 0

    if count == 0 then
        return false
    end

    session.variant_family_index = ((session.variant_family_index or 1) - 1
        + INTERNAL.signed_delta(action.delta, 1)) % count + 1

    return true
end

STUDIO_ACTIONS.cycle_variant_option = function(session, action)
    local item, state_value = INTERNAL.selected_variant_item_and_state(session)
    local families = item and item.npclook_raw_variant_families or {}
    local family_index = math.clamp(session.variant_family_index or 1, 1, math.max(#families, 1))
    local family = families[family_index]

    if not family then
        return false
    end

    local family_name = tostring(family.name or "")
    local options = family.options or {}
    local current = state_value.families[family_name]
    local current_index = 0

    for i = 1, #options do
        local option = options[i]
        local option_name = tostring(type(option) == "table" and option.name or option)

        if option_name == current then
            current_index = i
            break
        end
    end

    local option_count = #options + 1
    local next_index = (current_index + INTERNAL.signed_delta(action.delta, 1)) % option_count

    if next_index == 0 then
        state_value.families[family_name] = nil
    else
        local option = options[next_index]

        state_value.families[family_name] = tostring(type(option) == "table" and option.name or option)
    end

    return INTERNAL.stage_variant_preview(session, state_value, state_value.item_name)
end

STUDIO_ACTIONS.cycle_visibility_group = function(session, action)
    local item = INTERNAL.selected_variant_item_and_state(session)
    local count = item and #(item.npclook_raw_visibility_groups or {}) or 0

    if count == 0 then
        return false
    end

    session.visibility_group_index = ((session.visibility_group_index or 1) - 1
        + INTERNAL.signed_delta(action.delta, 1)) % count + 1

    return true
end

STUDIO_ACTIONS.cycle_visibility_value = function(session, action)
    local item, state_value = INTERNAL.selected_variant_item_and_state(session)
    local groups = item and item.npclook_raw_visibility_groups or {}
    local group_index = math.clamp(session.visibility_group_index or 1, 1, math.max(#groups, 1))
    local group = groups[group_index]

    if not group then
        return false
    end

    local name = tostring(type(group) == "table" and group.name or group)
    local current = state_value.visibility[name]
    local current_index = current == nil and 1 or current == true and 2 or 3
    local next_index = (current_index - 1 + INTERNAL.signed_delta(action.delta, 1)) % 3 + 1

    if next_index == 1 then
        state_value.visibility[name] = nil
    elseif next_index == 2 then
        state_value.visibility[name] = true
    else
        state_value.visibility[name] = false
    end

    return INTERNAL.stage_variant_preview(session, state_value, state_value.item_name)
end

STUDIO_ACTIONS.cycle_visual_options_mode = function(session)
    session.visual_options_mode = session.visual_options_mode == "masks" and "variants" or "masks"
    return true
end

STUDIO_ACTIONS.cycle_variant_control_mode = function(session)
    session.variant_control_mode = session.variant_control_mode == "visibility"
        and "families" or "visibility"
    return true
end

function INTERNAL.selected_mask_item_and_state(session)
    local mask_slot = session.selected_slot

    if not valid_look_slot(mask_slot) then
        return nil
    end

    local item_name = INTERNAL.selected_visual_item_name(session)
    local item = item_name and item_definition(item_name)
    local fields = item and MASKS.available_fields(item, item_cache(), mask_slot) or {}

    if not item or #fields == 0 then
        return nil
    end

    local state_value = MASKS.normalize_state(session.masks[mask_slot], item_name, fields)

    return item, state_value, item_name, mask_slot
end

local function stage_mask_state(session, item_name, state_value, previous)
    session.masks[session.selected_slot] = state_value
    session.preview_item = item_name
    session.preview_material_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)

    return true
end

STUDIO_ACTIONS.toggle_mask_field = function(session, action)
    local item, state_value, item_name, mask_slot = INTERNAL.selected_mask_item_and_state(session)

    if not item or type(action.field) ~= "string" then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local next_state = MASKS.toggle_field(
        item,
        item_cache(),
        mask_slot,
        state_value,
        action.field
    )

    return stage_mask_state(session, item_name, next_state, previous)
end

STUDIO_ACTIONS.cycle_mask_value = function(session, action)
    local item, state_value, item_name, mask_slot = INTERNAL.selected_mask_item_and_state(session)

    if not item or type(action.field) ~= "string" then
        return false
    end

    local next_state, changed = MASKS.cycle_field(
        item,
        item_cache(),
        mask_slot,
        state_value,
        action.field,
        INTERNAL.signed_delta(action.delta, 1)
    )

    if not changed then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)

    return stage_mask_state(session, item_name, next_state, previous)
end

STUDIO_ACTIONS.item_mode = function(session, action)
    if (action.mode == "units" or action.mode == "assets") and not RAW_UNITS.available() then
        session.feedback = loc("feedback_units_require_resource_loader")
        return false
    elseif action.mode == "assets" and not CUSTOM_ASSETS.available() then
        session.feedback = loc("feedback_assets_unavailable")
        return false
    elseif action.mode == "nodes" and not INTERNAL.node_library_available(session) then
        session.feedback = loc("feedback_nodes_unavailable")
        return false
    end

    session.item_mode = action.mode == "materials"
        and (valid_look_slot(session.selected_slot) or EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors))
        and "materials"
        or action.mode == "nodes" and "nodes"
        or action.mode == "all" and "all"
        or action.mode == "units" and "units"
        or action.mode == "assets" and "assets"
        or "slot"
    session.selected_item = nil
    session.preview_item = nil
    session.preview_attach_node = nil
    session.node_skeleton_visible = session.item_mode == "nodes" and session.node_skeleton_visible == true
    session.variant_family_index = 1
    session.visibility_group_index = 1
    session.variant_control_mode = "families"
    session.preview_material_item = nil
    session.item_page = 1

    if session.item_mode == "nodes" then
        session.item_search = ""
    end

    session.item_search_cache_key = nil
    session.item_search_results = nil
    session.feedback = loc("feedback_library_mode", LIBRARY_MODE_LABELS[session.item_mode] or LIBRARY_MODE_LABELS.slot)
end

STUDIO_ACTIONS.cycle_asset_slot = function(session, action)
    local engine_type = INTERNAL.selected_asset_material(session)
    local options = engine_type and INTERNAL.asset_slot_options(engine_type) or {}

    if #options <= 1 then
        return false
    end

    local _, index = INTERNAL.selected_asset_slot(session, engine_type)

    session.asset_slot_index[engine_type] = (index - 1 + INTERNAL.signed_delta(action.delta, 1)) % #options + 1
    session.preview_material_item = INTERNAL.asset_material_item(session, session.selected_item)
    session.feedback = loc("feedback_asset_slot", tostring(options[session.asset_slot_index[engine_type]]))
end

-- The search box doubles as the slot name field for custom textures and materials.
STUDIO_ACTIONS.type_asset_slot = function(session)
    local engine_type = INTERNAL.selected_asset_material(session)
    local value = string.lower(string.gsub(tostring(session.item_search or ""), "^%s*(.-)%s*$", "%1"))

    if not engine_type then
        return false
    elseif value == "" or #value > 96 or not string.match(value, "^[%w_]+$") then
        session.feedback = loc("feedback_asset_slot_type_hint")
        return false
    end

    local key = engine_type == "material" and "material" or "texture"
    local typed = INTERNAL.typed_asset_slots[key]

    for i = #typed, 1, -1 do
        if typed[i] == value then
            table.remove(typed, i)
        end
    end

    table.insert(typed, 1, value)

    while #typed > 16 do
        table.remove(typed)
    end

    INTERNAL.typed_asset_slot_revision = INTERNAL.typed_asset_slot_revision + 1
    session.asset_slot_index[engine_type] = 1
    session.preview_material_item = INTERNAL.asset_material_item(session, session.selected_item)
    session.feedback = loc("feedback_asset_slot", value)
end

STUDIO_ACTIONS.studio_tab = function(session, action)
    local tab = action.tab == "meshes" and "meshes" or "look"

    session.studio_tab = tab
    session.selected_mesh = nil
    session.mesh_page = 1
    session.preview_material_item = nil

    -- The Meshes tab pairs with a material library.
    if tab == "meshes" and session.item_mode ~= "materials" and session.item_mode ~= "assets"
        and (valid_look_slot(session.selected_slot) or EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors)) then
        session.item_mode = "materials"
        session.selected_item = nil
        session.preview_item = nil
        session.item_page = 1
        session.item_search_cache_key = nil
        session.item_search_results = nil
    end

    session.feedback = tab == "meshes" and loc("feedback_meshes_tab") or loc("feedback_look_tab")
end

STUDIO_ACTIONS.mesh_page = function(session, action)
    session.mesh_page = (session.mesh_page or 1) + INTERNAL.signed_delta(action.delta)
end

STUDIO_ACTIONS.select_mesh = function(session, action)
    if not MESHES.valid_key(action.mesh) then
        return false
    end

    session.selected_mesh = (session.selected_mesh ~= action.mesh
        or session.selected_mesh_slot ~= session.selected_slot) and action.mesh or nil
    session.selected_mesh_slot = session.selected_slot
    session.preview_material_item = nil
    session.feedback = session.selected_mesh and loc("feedback_mesh_selected") or loc("feedback_mesh_cleared")
end

STUDIO_ACTIONS.toggle_mesh_hidden = function(session, action)
    if not MESHES.valid_key(action.mesh) then
        return false
    end

    local state, slot_name = INTERNAL.selected_mesh_state(session, true)

    if not state then
        session.feedback = loc("feedback_hide_nothing")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    local hidden = not state.hidden[action.mesh]

    state.hidden[action.mesh] = hidden or nil
    INTERNAL.store_mesh_state(session, slot_name, state)
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = hidden and loc("feedback_mesh_hidden") or loc("feedback_mesh_shown")
end

STUDIO_ACTIONS.reset_meshes = function(session)
    local slot_name = session.selected_slot

    if not session.meshes[slot_name] then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    session.meshes[slot_name] = nil
    session.preview_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_meshes_reset")
end

STUDIO_ACTIONS.item_page = function(session, action)
    session.item_page = session.item_page + INTERNAL.signed_delta(action.delta)
end

STUDIO_ACTIONS.cycle_material_target = function(session, action)
    local detected = session.detected_material_slots[session.selected_slot] or {}
    local options = { EXTRA_SLOTS.material_target_all }

    for i = 1, #detected do
        options[#options + 1] = detected[i]
    end

    local current = session.material_target or EXTRA_SLOTS.material_target_all
    local current_index = 1

    for i = 1, #options do
        if options[i] == current then
            current_index = i
            break
        end
    end

    local next_index = ((current_index - 1 + INTERNAL.signed_delta(action.delta, 1)) % #options) + 1
    local target = options[next_index]

    session.material_target = target ~= EXTRA_SLOTS.material_target_all and target or nil
    session.feedback = loc(
        "feedback_material_target",
        session.material_target and EXTRA_SLOTS.material_target_label(session.material_target)
            or loc("ui_material_target_all")
    )
end

STUDIO_ACTIONS.select_item = function(session, action)
    if session.item_mode == "nodes" then
        local node_name = EXTRA_SLOTS.normalize_attach_node(action.item)

        if not node_name or not INTERNAL.attachment_node_available(session, node_name) then
            return false
        end

        session.selected_item = node_name
        session.preview_attach_node = node_name
        session.preview_item = nil
        session.preview_material_item = nil
        session.source_preview = nil
        session.feedback = loc("feedback_previewing_node", node_name)
        return
    elseif session.item_mode == "assets" and CUSTOM_ASSETS.parse_entry_id(action.item) then
        session.selected_item = action.item
        session.source_preview = nil
        session.preview_item = nil
        session.preview_material_item = INTERNAL.asset_material_item(session, action.item)
        session.feedback = session.preview_material_item
            and loc("feedback_selected_material", INTERNAL.display_token(action.item))
            or loc("feedback_asset_slot_missing")
        return
    elseif type(action.item) ~= "string" or not item_definition(action.item) then
        return false
    end

    session.selected_item = action.item
    session.source_preview = nil
    session.variant_family_index = 1
    session.visibility_group_index = 1
    session.variant_control_mode = "families"

    if session.item_mode == "materials" then
        session.preview_material_item = action.item
        session.preview_item = nil
        session.feedback = loc("feedback_selected_material", INTERNAL.display_token(action.item))
        return
    end

    session.preview_material_item = nil

    if not INTERNAL.studio_item_is_applicable(session, action.item) then
        session.preview_item = nil
        session.feedback = loc("error_visual_slot_unavailable")
    elseif INTERNAL.preview_candidate_is_safe(session, action.item) then
        session.preview_item = action.item
        session.feedback = loc("feedback_previewing_item", INTERNAL.display_token(action.item))
    else
        session.preview_item = nil
        session.feedback = loc("feedback_preview_attachment_cycle")
    end
end

STUDIO_ACTIONS.wear_item = function(session)
    if session.item_mode == "nodes" then
        local id = session.selected_slot
        local node_name = EXTRA_SLOTS.normalize_attach_node(session.selected_item)

        if not INTERNAL.node_library_available(session) then
            session.feedback = loc("feedback_nodes_unavailable")
            return false
        elseif not node_name or not INTERNAL.attachment_node_available(session, node_name) then
            session.feedback = loc("feedback_select_node")
            return false
        end

        local previous = INTERNAL.history_snapshot(session)
        local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])
        transform.attach_node = node_name
        session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(transform)
        session.preview_attach_node = nil
        session.source_preview = nil
        INTERNAL.record_history_change(session, previous)
        session.feedback = loc("feedback_node_attached", node_name)
        return
    elseif session.item_mode == "materials" or INTERNAL.selected_asset_material(session) then
        local id = session.selected_slot
        local material_item = session.item_mode == "materials" and session.selected_item
            or INTERNAL.asset_material_item(session, session.selected_item)

        if not valid_look_slot(id) and not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
            session.feedback = loc("feedback_select_destination")
            return false
        elseif not material_item or not INTERNAL.studio_item_is_applicable(session, session.selected_item) then
            session.feedback = loc("feedback_select_material")
            return false
        elseif INTERNAL.mesh_material_mode(session)
            and not MESHES.supports_override(EXTRA_SLOTS.material_override_item(item_cache() or {}, material_item)) then
            session.feedback = loc("feedback_mesh_material_unsupported")
            return false
        end

        local previous = INTERNAL.history_snapshot(session)
        local slot_materials = INTERNAL.active_materials(session)
        local selected_entry = INTERNAL.active_material_entry(session, material_item)
        local index

        for i = 1, #slot_materials do
            if slot_materials[i] == selected_entry then
                index = i
                break
            end
        end

        if index then
            table.remove(slot_materials, index)
            session.feedback = loc("feedback_material_removed", EXTRA_SLOTS.material_display(selected_entry))
        else
            slot_materials[#slot_materials + 1] = selected_entry
            session.feedback = loc("feedback_material_applied", EXTRA_SLOTS.material_display(selected_entry))
        end

        if not INTERNAL.set_active_materials(session, slot_materials) then
            session.feedback = loc("feedback_select_piece")
            return false
        end

        session.preview_item = nil
        session.preview_material_item = nil
        session.source_preview = nil
        session.item_search_cache_key = nil
        INTERNAL.record_history_change(session, previous)
        return
    end

    if not session.selected_item then
        session.feedback = loc("feedback_select_piece")
        return
    elseif not valid_look_slot(session.selected_slot) and not EXTRA_SLOTS.is_slot(session.selected_slot, session.extra_anchors) then
        session.feedback = loc("feedback_select_destination")
        return
    elseif not INTERNAL.studio_item_is_applicable(session, session.selected_item) then
        session.feedback = loc("error_visual_slot_unavailable")
        return
    elseif not INTERNAL.preview_candidate_is_safe(session, session.selected_item) then
        session.feedback = loc("feedback_preview_attachment_cycle")
        return
    end

    local previous = INTERNAL.history_snapshot(session)
    local previous_item = session.applied[session.selected_slot]
        or INTERNAL.original_item_name(INTERNAL.session_source_loadout(session), session.selected_slot)

    if previous_item ~= session.selected_item then
        -- Component targets do not carry across cosmetic replacements.
        EXTRA_SLOTS.set_selected_materials(
            session,
            EXTRA_SLOTS.filter_materials_for_targets(EXTRA_SLOTS.selected_materials(session), {})
        )
    end

    session.applied[session.selected_slot] = session.selected_item
    session.suppressed[session.selected_slot] = nil

    -- A freshly worn piece should be visible.
    if util.normalize_opacity(session.opacity[session.selected_slot]) == 0 then
        INTERNAL.set_slot_hidden(session, session.selected_slot, false)
    end

    local selected_item = item_definition(session.selected_item)
    local variant_state = session.variants[session.selected_slot]
    if not selected_item or selected_item.npclook_raw_unit ~= true
        or type(variant_state) ~= "table" or variant_state.item_name ~= session.selected_item then
        session.variants[session.selected_slot] = nil
    end

    local mask_state = session.masks[session.selected_slot]
    if not selected_item or type(mask_state) ~= "table" or mask_state.item_name ~= session.selected_item then
        session.masks[session.selected_slot] = nil
    end

    local mesh_state = session.meshes[session.selected_slot]
    if type(mesh_state) ~= "table" or mesh_state.item_name ~= session.selected_item then
        session.meshes[session.selected_slot] = nil
    end

    session.empty[session.selected_slot] = nil
    session.preview_item = nil
    session.preview_material_item = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_wore_piece", EXTRA_SLOTS.label(session.selected_slot, session.extra_anchors))
end

STUDIO_ACTIONS.reset_attach_node = function(session)
    local id = session.selected_slot

    if not INTERNAL.node_library_available(session) then
        session.feedback = loc("feedback_nodes_unavailable")
        return false
    end

    local transform = EXTRA_SLOTS.normalize_transform(session.extra_transforms[id])

    if not transform.attach_node then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    transform.attach_node = nil
    session.extra_transforms[id] = EXTRA_SLOTS.normalize_transform(transform)
    session.selected_item = nil
    session.preview_attach_node = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_node_reset")
end

STUDIO_ACTIONS.toggle_node_skeleton = function(session)
    if not INTERNAL.node_library_available(session) then
        session.feedback = loc("feedback_nodes_unavailable")
        return false
    end

    session.node_skeleton_visible = not session.node_skeleton_visible
    session.feedback = session.node_skeleton_visible
        and loc("feedback_node_skeleton_on") or loc("feedback_node_skeleton_off")
end

STUDIO_ACTIONS.clear_materials = function(session)
    local id = session.selected_slot

    if not valid_look_slot(id) and not EXTRA_SLOTS.is_slot(id, session.extra_anchors) then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    if #INTERNAL.active_materials(session) == 0 then
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    INTERNAL.set_active_materials(session, {})
    session.preview_item = nil
    session.preview_material_item = nil
    session.source_preview = nil
    session.item_search_cache_key = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_materials_cleared")
end

function INTERNAL.slot_visual_item_name(session, slot_name)
    if session.empty[slot_name] then
        return nil
    end

    return session.applied[slot_name]
        or not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)
            and INTERNAL.original_item_name(INTERNAL.session_source_loadout(session), slot_name)
        or nil
end

function INTERNAL.slot_is_hidden(session, slot_name)
    return session.suppressed[slot_name] == true
        or util.normalize_opacity(session.opacity[slot_name]) == 0
end

-- Hiding drops a piece to 0% opacity so it keeps its masks, materials and transform.
-- Kept across Studio sessions; entries only restore onto the piece they were hidden on.
INTERNAL.hidden_opacity_restore = {}

function INTERNAL.set_slot_hidden(session, slot_name, hidden)
    if not hidden then
        if session.suppressed[slot_name] then
            -- Codes from older builds removed the piece instead.
            session.suppressed[slot_name] = nil
        end

        if util.normalize_opacity(session.opacity[slot_name]) == 0 then
            local entry = session.hidden_opacity_restore[slot_name]
            local restore = type(entry) == "table"
                and entry.item_name == INTERNAL.slot_visual_item_name(session, slot_name)
                and util.normalize_opacity(entry.opacity) or util.opacity_default
            session.opacity[slot_name] = restore ~= 0 and restore ~= util.opacity_default and restore or nil
        end

        session.hidden_opacity_restore[slot_name] = nil

        return true
    elseif INTERNAL.slot_is_hidden(session, slot_name) or not INTERNAL.slot_visual_item_name(session, slot_name) then
        return false
    end

    session.hidden_opacity_restore[slot_name] = {
        item_name = INTERNAL.slot_visual_item_name(session, slot_name),
        opacity = session.opacity[slot_name],
    }
    session.opacity[slot_name] = 0

    return true
end

STUDIO_ACTIONS.hide_slot = function(session)
    local slot_name = session.selected_slot

    if not valid_look_slot(slot_name) and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    local hidden = INTERNAL.slot_is_hidden(session, slot_name)

    if not hidden and not INTERNAL.slot_visual_item_name(session, slot_name) then
        session.feedback = loc("feedback_hide_nothing")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)
    INTERNAL.set_slot_hidden(session, slot_name, not hidden)
    session.preview_item = nil
    session.preview_material_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = hidden and loc("feedback_shown_slot") or loc("feedback_hidden_slot")
end

STUDIO_ACTIONS.empty_slot = function(session)
    if INTERNAL.stage_slot_state(session, "empty") then
        session.feedback = loc("feedback_empty_slot")
    end
end

STUDIO_ACTIONS.restore_slot = function(session)
    local slot_name = session.selected_slot
    local is_extra_slot = EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)

    if not valid_look_slot(slot_name) and not is_extra_slot then
        session.feedback = loc("feedback_select_destination")
        return false
    end

    local previous = INTERNAL.history_snapshot(session)

    if is_extra_slot and not session.live_extra_anchors[slot_name] then
        session.applied[slot_name] = nil
        session.suppressed[slot_name] = nil
        session.empty[slot_name] = nil
        session.extra_anchors[slot_name] = nil
        session.extra_transforms[slot_name] = nil
        session.materials[slot_name] = nil
        session.variants[slot_name] = nil
        session.masks[slot_name] = nil
        session.meshes[slot_name] = nil
        session.opacity[slot_name] = nil
        session.detected_material_slots[slot_name] = nil
        session.selected_slot = "slot_gear_upperbody"
        session.slot_page = 1
    else
        session.applied[slot_name] = session.live_applied[slot_name]
        session.suppressed[slot_name] = session.live_suppressed[slot_name]
        session.empty[slot_name] = session.live_empty[slot_name]

        if is_extra_slot then
            session.extra_anchors[slot_name] = session.live_extra_anchors[slot_name]
            session.extra_transforms[slot_name] = EXTRA_SLOTS.normalize_transform(session.live_extra_transforms[slot_name])
        else
            local live_materials = EXTRA_SLOTS.normalize_materials(session.live_materials[slot_name])
            session.materials[slot_name] = #live_materials > 0 and live_materials or nil
        end

        session.variants[slot_name] = session.live_variants[slot_name]
            and RAW_UNITS.normalize_variant_state(session.live_variants[slot_name]) or nil
        session.masks[slot_name] = session.live_masks[slot_name]
            and MASKS.clone_state(session.live_masks[slot_name]) or nil
        session.meshes[slot_name] = MESHES.clone_state(session.live_meshes[slot_name])
        session.opacity[slot_name] = session.live_opacity[slot_name]
    end

    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = loc("feedback_restored_slot")

    return true
end

STUDIO_ACTIONS.source_kind = function(session, action)
    session.source_kind = action.source_kind == "family" and "family"
        or action.source_kind == "player" and "player"
        or "preset"
    session.source_page = 1
    session.selected_source = nil
    session.source_preview = nil

end

STUDIO_ACTIONS.source_page = function(session, action)
    session.source_page = session.source_page + INTERNAL.signed_delta(action.delta)
end

STUDIO_ACTIONS.select_source = function(session, action)
    if type(action.source) ~= "string" then
        return false
    end

    session.selected_source = action.source
    session.source_preview = nil
    session.preview_item = nil
    session.item_mode = "slot"
    session.item_page = 1
    session.feedback = loc("feedback_selected_source", string.upper(INTERNAL.display_token(action.source)))
end

STUDIO_ACTIONS.preview_source = function(session, action)
    if not session.selected_source then
        session.feedback = loc("feedback_select_source")
        return
    end

    local mode = action.replace and "replace" or "layer"
    session.source_preview = session.source_preview == mode and nil or mode
    session.preview_item = nil

    if not session.source_preview then
        session.feedback = loc("feedback_source_preview_clear")
    elseif action.replace then
        session.feedback = loc("feedback_source_preview_replace")
    else
        session.feedback = loc("feedback_source_preview_add")
    end
end

STUDIO_ACTIONS.stage_source = function(session, action)
    local outfit = INTERNAL.source_blueprint(session)
    local ok, err = INTERNAL.stage_outfit(session, outfit, action.replace == true)
    session.feedback = ok and (action.replace and loc("feedback_source_replaced") or loc("feedback_source_layered")) or tostring(err)
end

function INTERNAL.all_slots_hidden(session)
    local found = false

    for _, slot_name in ipairs(EXTRA_SLOTS.slot_order(session.extra_anchors)) do
        if INTERNAL.slot_visual_item_name(session, slot_name) or session.suppressed[slot_name] then
            found = true

            if not INTERNAL.slot_is_hidden(session, slot_name) then
                return false
            end
        end
    end

    return found
end

STUDIO_ACTIONS.full_hide = function(session)
    local previous = INTERNAL.history_snapshot(session)
    local hide = not INTERNAL.all_slots_hidden(session)

    for _, slot_name in ipairs(EXTRA_SLOTS.slot_order(session.extra_anchors)) do
        if valid_look_slot(slot_name) or EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors) then
            INTERNAL.set_slot_hidden(session, slot_name, hide)
        end
    end

    session.preview_item = nil
    session.preview_material_item = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)
    session.feedback = hide and loc("feedback_full_hide") or loc("feedback_full_show")
end

STUDIO_ACTIONS.undo = function(session)
    local snapshot = table.remove(session.history)

    if snapshot then
        session.redo[#session.redo + 1] = INTERNAL.history_snapshot(session)
        INTERNAL.restore_history_snapshot(session, snapshot)
        session.feedback = loc("feedback_undo")
    end
end

STUDIO_ACTIONS.redo = function(session)
    local snapshot = table.remove(session.redo)

    if snapshot then
        session.history[#session.history + 1] = INTERNAL.history_snapshot(session)
        INTERNAL.restore_history_snapshot(session, snapshot)
        session.feedback = loc("feedback_redo")
    end
end

STUDIO_ACTIONS.revert_stage = function(session)
    restore_string_map(session.applied, session.live_applied)
    restore_string_map(session.suppressed, session.live_suppressed)
    restore_string_map(session.empty, session.live_empty)
    restore_string_map(session.extra_anchors, session.live_extra_anchors)
    EXTRA_SLOTS.restore_transforms(session.extra_transforms, session.live_extra_transforms, session.extra_anchors)
    EXTRA_SLOTS.restore_material_map(session.materials, session.live_materials)
    session.variants = RAW_UNITS.clone_variant_map(session.live_variants)
    session.masks = MASKS.clone_map(session.live_masks)
    session.opacity = util.clone_opacity_map(session.live_opacity)
    session.meshes = MESHES.clone_map(session.live_meshes)
    session.selected_slot = "slot_gear_upperbody"
    session.slot_page = 1
    table.clear(session.history)
    table.clear(session.redo)
    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.source_preview = nil
    session.feedback = loc("feedback_reverted")
end

function INTERNAL.stage_look_code(session, code)
    local imported_applied, imported_suppressed, imported_empty, count_or_error, _,
        imported_anchors, imported_transforms, imported_materials, imported_variants, imported_masks, imported_opacity,
        imported_meshes = decode_look_code(code)

    if not imported_applied then
        return false, count_or_error
    end

    local cache = item_cache() or {}

    for _, item_name in pairs(imported_applied) do
        local item = item_definition(item_name)

        if item and util.item_is_2d(item, item_name) then
            return false, loc("error_visual_slot_unavailable")
        end
    end

    local previous = INTERNAL.history_snapshot(session)
    restore_string_map(session.applied, imported_applied)
    restore_string_map(session.suppressed, imported_suppressed)
    restore_string_map(session.empty, imported_empty)
    restore_string_map(session.extra_anchors, imported_anchors)
    EXTRA_SLOTS.restore_transforms(session.extra_transforms, imported_transforms, imported_anchors)
    EXTRA_SLOTS.restore_material_map(session.materials, imported_materials)
    session.variants = RAW_UNITS.clone_variant_map(imported_variants)
    session.masks = MASKS.clone_map(imported_masks)
    session.opacity = util.clone_opacity_map(imported_opacity)
    session.meshes = MESHES.clone_map(imported_meshes)
    session.selected_slot = "slot_gear_upperbody"
    session.slot_page = 1
    session.preview_item = nil
    session.preview_material_item = nil
    session.material_target = nil
    session.source_preview = nil
    INTERNAL.record_history_change(session, previous)

    return true, count_or_error or 0
end

STUDIO_ACTIONS.import_code = function(session, action)
    local ok, count_or_error = INTERNAL.stage_look_code(session, action.code)
    session.feedback = ok and loc("feedback_imported", count_or_error) or loc("feedback_import_failed", tostring(count_or_error))
end

STUDIO_ACTIONS.save_player_preset = function(session, action)
    local name = PLAYER_PRESETS.normalize_name(action.name)

    if name == "" then
        session.feedback = loc("feedback_preset_name_required")
        return
    end

    local applied, suppressed, empty, extra_anchors, extra_transforms, materials, export_error = merged_look_state(
        session.player,
        session.applied,
        session.suppressed,
        session.empty,
        session.extra_anchors,
        session.extra_transforms,
        session.materials
    )

    if not applied then
        session.feedback = loc("feedback_export_failed", tostring(export_error))
        return
    end

    local previous_presets = PLAYER_PRESETS.clone()
    local index = PLAYER_PRESETS.index(name)
    local code = encode_look_code(
        applied,
        suppressed,
        empty,
        look_metadata(session.player),
        extra_anchors,
        extra_transforms,
        materials,
        session.variants,
        session.masks,
        session.opacity,
        session.meshes
    )

    if index then
        PLAYER_PRESETS.items[index].name = name
        PLAYER_PRESETS.items[index].code = code
    else
        PLAYER_PRESETS.items[#PLAYER_PRESETS.items + 1] = { name = name, code = code }
    end

    PLAYER_PRESETS.sort()

    local saved, save_error = PLAYER_PRESETS.write()

    if not saved then
        PLAYER_PRESETS.items = previous_presets
        session.feedback = loc("feedback_preset_save_failed", tostring(save_error))
        return
    end

    session.selected_source = name
    session.source_page = math.ceil((PLAYER_PRESETS.index(name) or 1) / STUDIO_SOURCE_PAGE_SIZE)
    session.feedback = loc("feedback_preset_saved", name)
    LOADOUT_PRESETS.presets_changed()
end

STUDIO_ACTIONS.load_player_preset = function(session)
    local index = session.selected_source and PLAYER_PRESETS.index(session.selected_source)
    local preset = index and PLAYER_PRESETS.items[index]

    if not preset then
        session.feedback = loc("feedback_select_player_preset")
        return
    end

    local ok, count_or_error = INTERNAL.stage_look_code(session, preset.code)
    session.feedback = ok
        and loc("feedback_preset_loaded", preset.name, count_or_error)
        or loc("feedback_import_failed", tostring(count_or_error))
end

STUDIO_ACTIONS.delete_player_preset = function(session)
    local index = session.selected_source and PLAYER_PRESETS.index(session.selected_source)
    local preset = index and PLAYER_PRESETS.items[index]

    if not preset then
        session.feedback = loc("feedback_select_player_preset")
        return
    end

    local previous_presets = PLAYER_PRESETS.clone()
    table.remove(PLAYER_PRESETS.items, index)

    local saved, save_error = PLAYER_PRESETS.write()

    if not saved then
        PLAYER_PRESETS.items = previous_presets
        session.feedback = loc("feedback_preset_delete_failed", tostring(save_error))
        return
    end

    session.selected_source = nil
    session.source_preview = nil
    session.feedback = loc("feedback_preset_deleted", preset.name)
    LOADOUT_PRESETS.preset_deleted(preset.name)
end

STUDIO_ACTIONS.copy_code = function(session)
    local applied, suppressed, empty, extra_anchors, extra_transforms, materials, export_error = merged_look_state(
        session.player,
        session.applied,
        session.suppressed,
        session.empty,
        session.extra_anchors,
        session.extra_transforms,
        session.materials
    )

    if not applied then
        session.feedback = loc("feedback_export_failed", tostring(export_error))
        return
    end

    local code = encode_look_code(
        applied,
        suppressed,
        empty,
        look_metadata(session.player),
        extra_anchors,
        extra_transforms,
        materials,
        session.variants,
        session.masks,
        session.opacity,
        session.meshes
    )
    session.feedback = copy_to_clipboard(code) and loc("feedback_export_copied") or loc("feedback_clipboard_unavailable")
end

STUDIO_ACTIONS.commit = function(session)
    local ok, err = mod.npclook_commit_state(
        session.applied,
        session.suppressed,
        session.empty,
        session.extra_anchors,
        session.extra_transforms,
        session.materials,
        session.variants,
        session.masks,
        session.opacity,
        session.meshes
    )

    if not ok then
        session.feedback = loc("feedback_apply_failed", tostring(err or loc("generic_unknown")))
        return
    end

    restore_string_map(session.live_applied, session.applied)
    restore_string_map(session.live_suppressed, session.suppressed)
    restore_string_map(session.live_empty, session.empty)
    restore_string_map(session.live_extra_anchors, session.extra_anchors)
    EXTRA_SLOTS.restore_transforms(session.live_extra_transforms, session.extra_transforms, session.extra_anchors)
    EXTRA_SLOTS.restore_material_map(session.live_materials, session.materials)
    session.live_variants = RAW_UNITS.clone_variant_map(session.variants)
    session.live_masks = MASKS.clone_map(session.masks)
    session.live_opacity = util.clone_opacity_map(session.opacity)
    session.live_meshes = MESHES.clone_map(session.meshes)
    table.clear(session.history)
    table.clear(session.redo)
    session.preview_item = nil
    session.preview_material_item = nil
    session.source_preview = nil
    session.feedback = loc("feedback_applied")
end

STUDIO_ACTIONS.reset_player = function(session)
    if not mod.npclook_reset_all() then
        session.feedback = loc("feedback_reset_failed")
        return
    end

    table.clear(session.applied)
    table.clear(session.suppressed)
    table.clear(session.empty)
    table.clear(session.extra_anchors)
    table.clear(session.extra_transforms)
    table.clear(session.materials)
    table.clear(session.live_applied)
    table.clear(session.live_suppressed)
    table.clear(session.live_empty)
    table.clear(session.live_extra_anchors)
    table.clear(session.live_extra_transforms)
    table.clear(session.live_materials)
    table.clear(session.variants)
    table.clear(session.live_variants)
    table.clear(session.masks)
    table.clear(session.live_masks)
    table.clear(session.opacity)
    table.clear(session.live_opacity)
    table.clear(session.meshes)
    table.clear(session.live_meshes)
    table.clear(session.detected_material_slots)
    session.material_target = nil
    session.selected_slot = "slot_gear_upperbody"
    session.slot_page = 1
    table.clear(session.history)
    table.clear(session.redo)
    session.preview_item = nil
    session.preview_material_item = nil
    session.source_preview = nil
    session.feedback = loc("feedback_reset")
end

STUDIO_ACTIONS.refresh_player = function(session)
    local ok, err = mod.npclook_refresh_look()
    session.feedback = ok and loc("feedback_refreshed") or loc("feedback_refresh_failed", tostring(err or loc("generic_unknown")))
end

function INTERNAL.studio_action(action)
    local session = _studio_session
    local handler = type(action) == "table" and STUDIO_ACTIONS[action.kind]

    if not session or session.closing == true or not handler then
        return false
    end

    local previous_preview_revision = session.preview_revision
    local previous_preview_signature = INTERNAL.preview_visual_signature(session)
    if handler(session, action) == false then
        return false
    end

    session.preview_revision = INTERNAL.preview_visual_signature(session) ~= previous_preview_signature
        and previous_preview_revision + 1
        or previous_preview_revision


    return true
end

studio_preview_snapshot = function()
    local session = _studio_session

    if not session or session.closing == true then
        return nil, loc("error_snapshot_bridge")
    end

    local player = get_local_player() or session.player

    if not player then
        return nil, loc("error_local_player_not_ready")
    end

    session.player = player

    if session.preview_cache_revision ~= session.preview_revision or not session.preview_cache then
        local effective_applied, effective_suppressed, effective_empty = INTERNAL.effective_preview_state(session)

        if INTERNAL.preview_has_attachment_cycle(player, effective_applied, effective_suppressed, effective_empty) then
            session.feedback = loc("feedback_preview_attachment_cycle")
            return nil
        end

        local effective_materials, effective_extra_transforms = EXTRA_SLOTS.effective_preview_material_state(session)
        local effective_opacity = INTERNAL.effective_preview_opacity(session)
        local effective_meshes = INTERNAL.effective_preview_meshes(session)
        local preview_loadout = INTERNAL.build_state_loadout(
            player,
            effective_applied,
            effective_suppressed,
            effective_empty,
            effective_materials,
            session.variants,
            session.masks,
            effective_opacity,
            effective_meshes,
            session
        )

        session.preview_cache = {
            player = player,
            preview_loadout = preview_loadout,
            preview_loadout_signature = INTERNAL.preview_loadout_signature(preview_loadout),
            preview_extra_slots = INTERNAL.build_preview_extra_slots(
                player,
                effective_applied,
                effective_suppressed,
                effective_empty,
                session.extra_anchors,
                effective_extra_transforms,
                preview_loadout,
                session.variants,
                effective_opacity,
                effective_meshes
            ),
            preview_revision = session.preview_revision,
            selected_slot = session.selected_slot,
            mesh_tab = session.studio_tab == "meshes",
            camera_focus = session.camera_focus,
            inspect_mode = session.inspect_mode == true,
            camera_reset_revision = session.camera_reset_revision or 0,
            node_skeleton_visible = session.item_mode == "nodes"
                and session.node_skeleton_visible == true,
            preview_attach_node = session.item_mode == "nodes"
                and (EXTRA_SLOTS.normalize_attach_node(session.preview_attach_node)
                    or EXTRA_SLOTS.normalize_transform(
                        effective_extra_transforms[session.selected_slot]
                    ).attach_node)
                or nil,
        }
        session.preview_cache_revision = session.preview_revision
    else
        session.preview_cache.player = player
        session.preview_cache.selected_slot = session.selected_slot
        session.preview_cache.mesh_tab = session.studio_tab == "meshes"
        session.preview_cache.camera_focus = session.camera_focus
        session.preview_cache.inspect_mode = session.inspect_mode == true
        session.preview_cache.camera_reset_revision = session.camera_reset_revision or 0
        session.preview_cache.node_skeleton_visible = session.item_mode == "nodes"
            and session.node_skeleton_visible == true
        session.preview_cache.preview_attach_node = session.item_mode == "nodes"
            and (EXTRA_SLOTS.normalize_attach_node(session.preview_attach_node)
                or EXTRA_SLOTS.normalize_transform(
                    session.extra_transforms[session.selected_slot]
                ).attach_node)
            or nil
    end

    return session.preview_cache
end

function EXTRA_SLOTS.report_detected_material_slots(slot_name, slots, authoritative)
    local session = _studio_session

    if not session or session.closing == true or (not valid_look_slot(slot_name)
        and not EXTRA_SLOTS.is_slot(slot_name, session.extra_anchors)) then
        return false
    end

    local result = {}
    local seen = {}

    for i = 1, math.min(#(slots or {}), 128) do
        local target = EXTRA_SLOTS.normalize_material_target(slots[i])

        if target and not seen[target] then
            seen[target] = true
            result[#result + 1] = target
        end
    end

    -- The detector orders actual spawned item components by their display label.
    session.detected_material_slots[slot_name] = result

    if session.selected_slot == slot_name and authoritative == true then
        local previous_materials = EXTRA_SLOTS.selected_materials(session)
        local filtered_materials = EXTRA_SLOTS.filter_materials_for_targets(previous_materials, result)

        if EXTRA_SLOTS.material_list_signature(previous_materials)
            ~= EXTRA_SLOTS.material_list_signature(filtered_materials) then
            EXTRA_SLOTS.set_selected_materials(session, filtered_materials)
            session.item_search_cache_key = nil
            session.preview_revision = (session.preview_revision or 0) + 1
        end
    end

    if session.selected_slot == slot_name and session.material_target and not seen[session.material_target] then
        session.material_target = nil
        session.preview_revision = (session.preview_revision or 0) + 1
    end

    return true
end

mod.npclook_view_api = {
    begin = INTERNAL.begin_studio_session,
    active = function()
        return _studio_session ~= nil and _studio_session.closing ~= true
    end,
    available = INTERNAL.studio_session_available,
    closing = INTERNAL.studio_session_closing,
    attach_view = INTERNAL.studio_attach_view,
    detach_view = INTERNAL.studio_detach_view,
    view_attached = INTERNAL.studio_view_attached,
    snapshot = INTERNAL.studio_snapshot,
    preview_snapshot = studio_preview_snapshot,
    item_cache = item_cache,
    material_targets_from_item_maps = EXTRA_SLOTS.material_targets_from_item_maps,
    report_material_slots = EXTRA_SLOTS.report_detected_material_slots,
    report_mesh_inventory = EXTRA_SLOTS.report_mesh_inventory,
    preview_input = function()
        local session = _studio_session

        return session and session.closing ~= true and session.preview_input or nil
    end,
    set_preview_input = function(input_service)
        local session = _studio_session

        if session and session.closing ~= true then
            session.preview_input = input_service
        end
    end,
    action = INTERNAL.studio_action,
    finish = INTERNAL.finish_studio_session,
}

function INTERNAL.register_studio_view(view_name, module_path, class_name, view_settings, view_options)
    package.loaded[module_path] = nil

    local view_class = mod:io_dofile(module_path)

    if type(view_class) ~= "table" then
        error(string.format("Could not load view class %s", tostring(class_name)))
    end

    package.preload[module_path] = function()
        return view_class
    end

    mod:register_view({
        view_name = view_name,
        view_settings = view_settings,
        view_transitions = {},
        view_options = view_options or {
            close_all = false,
            close_previous = false,
            close_transition_time = nil,
            transition_time = nil,
        },
    })
end

function INTERNAL.ensure_studio_view_registered()
    if _studio_view_registered then
        return true
    end

    if not EXTRA_SLOTS.preview_view_registered then
        local preview_ok, preview_error = xpcall(function()
            INTERNAL.register_studio_view(VIEW_CONFIG.preview_name, VIEW_CONFIG.preview_module_path, "NPCLookStudioPreviewView", {
                init_view_function = function()
                    return true
                end,
                class = "NPCLookStudioPreviewView",
                disable_game_world = false,
                display_name = loc("view_preview_name"),
                game_world_blur = 0.7,
                load_always = true,
                load_in_hub = true,
                package = VIEW_CONFIG.preview_package,
                path = VIEW_CONFIG.preview_module_path,
                state_bound = true,
                use_transition_ui = false,
                allow_hud = false,
                levels = {
                    VIEW_CONFIG.studio_level,
                },
            })
        end, util.traceback)

        if not preview_ok then
            mod:error("Preview view registration failed: %s", tostring(preview_error))
            return false
        end

        EXTRA_SLOTS.preview_view_registered = true
    end

    if not EXTRA_SLOTS.studio_view_registered then
        local studio_ok, studio_error = xpcall(function()
            INTERNAL.register_studio_view(VIEW_CONFIG.studio_name, VIEW_CONFIG.studio_module_path, "NPCLookStudioView", {
                init_view_function = function()
                    return true
                end,
                class = "NPCLookStudioView",
                disable_game_world = false,
                display_name = loc("view_studio_name"),
                game_world_blur = 0,
                load_always = true,
                load_in_hub = true,
                package = VIEW_CONFIG.studio_package,
                path = VIEW_CONFIG.studio_module_path,
                state_bound = true,
                use_transition_ui = false,
                allow_hud = false,
            })
        end, util.traceback)

        if not studio_ok then
            mod:error("Studio view registration failed: %s", tostring(studio_error))
            return false
        end

        EXTRA_SLOTS.studio_view_registered = true
    end

    _studio_view_registered = true

    return true
end

function INTERNAL.view_is_active(ui_manager, view_name)
    if not ui_manager or type(ui_manager.view_active) ~= "function" then
        return false
    end

    local ok, active = pcall(ui_manager.view_active, ui_manager, view_name)

    return ok and active == true
end

function INTERNAL.close_view_safely(ui_manager, view_name)
    if not INTERNAL.view_is_active(ui_manager, view_name) or type(ui_manager.close_view) ~= "function" then
        return true
    end

    local ok, err = pcall(ui_manager.close_view, ui_manager, view_name)

    if not ok then
        mod:warning("Could not close view %s: %s", tostring(view_name), tostring(err))
    end

    return ok
end

function INTERNAL.close_studio_views(ui_manager)
    if not ui_manager then
        return
    end

    INTERNAL.close_view_safely(ui_manager, VIEW_CONFIG.preview_name)
    INTERNAL.close_view_safely(ui_manager, VIEW_CONFIG.studio_name)
end

function INTERNAL.open_registered_view(ui_manager, view_name, context)
    -- UIManager rejects opens while UI packages are changing
    local ok, opened_or_error = pcall(
        ui_manager.open_view,
        ui_manager,
        view_name,
        nil,
        false,
        false,
        nil,
        context
    )

    return ok and opened_or_error ~= false, opened_or_error
end

function INTERNAL.open_studio()
    local player = get_local_player()
    local ui_manager = Managers.ui

    if not player or not ui_manager or not INTERNAL.ensure_studio_view_registered() then
        return false
    end

    if INTERNAL.view_is_active(ui_manager, VIEW_CONFIG.studio_name)
        or INTERNAL.view_is_active(ui_manager, VIEW_CONFIG.preview_name) then
        INTERNAL.close_studio_views(ui_manager)
        return true
    end

    local begin_call_ok, begin_ok = pcall(mod.npclook_view_api.begin, player)

    if not begin_call_ok or not begin_ok then
        mod:error("Studio session setup failed: %s", tostring(begin_ok or "session setup was refused"))
        return false
    end

    local context = {
        player = player,
        preview_view_name = VIEW_CONFIG.preview_name,
    }

    local preview_ok, preview_error = INTERNAL.open_registered_view(ui_manager, VIEW_CONFIG.preview_name, context)

    if not preview_ok then
        pcall(mod.npclook_view_api.finish, true)
        mod:error("Studio preview failed to open: %s", tostring(preview_error))
        return false
    end

    local overlay_ok, overlay_error = INTERNAL.open_registered_view(ui_manager, VIEW_CONFIG.studio_name, context)

    if not overlay_ok then
        INTERNAL.close_studio_views(ui_manager)
        pcall(mod.npclook_view_api.finish)
        mod:error("Studio failed to open: %s", tostring(overlay_error))
        return false
    end

    return true
end

mod.npclook_open_studio = INTERNAL.open_studio

mod:command("npclook_ui", loc("command_open"), function()
    if not get_local_player() then
        mod:echo(loc("error_local_player_not_ready"))
        return
    end

    INTERNAL.open_studio()
end)

-- Lifecycle and reapply

-- The player unit is recreated between hub and mission.
function INTERNAL.reset_unit_binding()
    if util.safe_unit_alive(_bound_player_unit) then
        live_visual.refresh_active_package_units(visual_extension(_bound_player_unit))
    end

    extra_slot_runtime.clear(0)
    retire_all_live_slot_packages()
    table.clear(_originals)
    table.clear(live_visual.managed_slots)
    live_visual.plan = nil
    live_visual.plan_signature = nil
    _bound_player_unit = nil
end

function INTERNAL.cleanup_stale_npclook_visuals(player, player_unit)
    local ext = visual_extension(player_unit)
    local profile = safe_profile(player)

    if not ext or not profile or not item_cache() then
        return false, loc("error_local_visual_not_ready")
    end

    local equipment_component = ext._equipment_component
    local unit_spawner = equipment_component and equipment_component._unit_spawner
    local cleanup_children = extra_slot_runtime.cleanup_owned_parent_children

    if type(cleanup_children) == "function" then
        pcall(cleanup_children, player_unit, unit_spawner)
        pcall(cleanup_children, ext._first_person_unit, unit_spawner)
    end

    local equipment = ext._equipment
    local stale_slots = {}

    if type(equipment) == "table" then
        for slot_name, slot in pairs(equipment) do
            if valid_look_slot(slot_name) and type(slot) == "table"
                and type(slot.item) == "table" and slot.item.npclook_generated == true then
                stale_slots[slot_name] = true
            end
        end
    end

    if next(stale_slots) == nil then
        live_visual.flush_slot_unit_spawner(unit_spawner)
        return true
    end

    local desired_loadout, loadout_error = live_visual.generate_loadout(profile.loadout or {})

    if not desired_loadout then
        return false, loadout_error
    end

    local fixed_frame, fixed_t = fixed_frame_values(ext)
    local remove_order = live_visual.ordered_slots(true)

    for i = 1, #remove_order do
        local slot_name = remove_order[i]

        if stale_slots[slot_name] then
            local ok, err = unequip_slot(ext, slot_name, fixed_frame)

            if not ok then
                return false, err
            end
        end
    end

    live_visual.flush_slot_unit_spawner(unit_spawner)

    local equip_order = live_visual.ordered_slots(false)

    for i = 1, #equip_order do
        local slot_name = equip_order[i]
        local item = stale_slots[slot_name] and desired_loadout[slot_name]

        if item then
            local ok, err = equip_slot(ext, slot_name, item, fixed_t)

            if not ok then
                return false, err
            end
        end
    end

    live_visual.flush_slot_unit_spawner(unit_spawner)

    if type(ext.force_update_item_visibility) == "function" then
        pcall(ext.force_update_item_visibility, ext)
    end

    mod.npclook_refresh_portrait()

    return true
end

function INTERNAL.reapply_failed(err)
    if util.record_attempt(_reapply_retry) then
        _reapply_pending = false
        _vanilla_restore_pending = false
        mod:warning("Stopped reapplying the look after %d attempts: %s", util.RETRY_LIMIT, tostring(err or "unknown error"))
    end

    return false, err
end

function INTERNAL.run_reapply(player, player_unit)
    player = player or get_local_player()
    player_unit = player_unit or player and safe_player_unit(player)

    if not player or not util.safe_unit_alive(player_unit) or not visual_extension(player_unit) then
        return INTERNAL.reapply_failed(loc("error_local_visual_not_ready"))
    end

    if _vanilla_restore_pending then
        local restored = direct_restore(player)

        if restored then
            _vanilla_restore_pending = false
            table.clear(_originals)
            table.clear(live_visual.managed_slots)
            util.reset_retry(_reapply_retry)
            util.report_once(_runtime_reports, "reapply", nil)
            mod.npclook_refresh_portrait()
            return true
        end

        return INTERNAL.reapply_failed(loc("error_slot_restore"))
    end

    local ok, err, packages_loading = push_look()

    if packages_loading then
        _reapply_pending = _live_profile_sync_waiting
        util.defer_retry(_reapply_retry)
        util.report_once(_runtime_reports, "reapply", nil)
        return true
    end

    if ok then
        _reapply_pending = false
        util.reset_retry(_reapply_retry)
        util.report_once(_runtime_reports, "reapply", nil)
        return true
    end

    return INTERNAL.reapply_failed(err)
end

-- Companion mod API (Pilgrimage). States are plain copies; pass them back unchanged.

mod.npclook_api_version = 1

mod.npclook_current_state = function()
    return live_visual.owners.snapshot_state(live_visual.owners.local_record.state)
end

mod.npclook_decode_look = function(code)
    if not item_cache() then
        return nil, loc("error_master_cache_not_ready")
    end

    local applied, suppressed, empty, count_or_error, _, extra_anchors,
        extra_transforms, materials, variants, masks, opacity, meshes = decode_look_code(code)

    if not applied then
        return nil, count_or_error
    end

    return live_visual.owners.snapshot_state({
        applied = applied,
        suppressed = suppressed,
        empty = empty,
        extra_anchors = extra_anchors,
        extra_transforms = extra_transforms,
        materials = materials,
        variants = variants,
        masks = masks,
        opacity = opacity,
        meshes = meshes,
    })
end

mod.npclook_add_look_to_loadout = function(source_loadout, state)
    if type(source_loadout) ~= "table" or not item_cache() then
        return source_loadout
    end

    return live_visual.add_look_to_loadout(
        source_loadout,
        live_visual.owners.normalize_state(state or live_visual.owners.local_record.state)
    )
end

-- Marked profiles keep their look; the local look and loadout pins skip them.
mod.npclook_profile_with_look = function(profile, state)
    if type(profile) ~= "table" or not item_cache() then
        return profile
    end

    local source_profile = profile.npclook_source_profile or profile
    local decorated = live_visual.profile_with_look(
        source_profile,
        live_visual.owners.normalize_state(state or live_visual.owners.local_record.state)
    )

    if decorated == source_profile then
        decorated = shallow_copy(source_profile)
        decorated.npclook_source_profile = source_profile
    end

    decorated.npclook_external_look = true

    return decorated
end

-- Returns ok, error, packages_loading, equipped, failed. A look that is still loading
-- counts as accepted and finishes on its own.
mod.npclook_apply_active_look_to_bot_unit = function(player, state)
    local ok, err, packages_loading, equipped, failed = live_visual.owners.apply(
        player,
        state or live_visual.owners.local_record.state
    )

    return ok or packages_loading, err, packages_loading, equipped or 0, failed or 0
end

mod.npclook_apply_active_look_to_player = function(player)
    if player ~= nil and player == get_local_player() then
        local ok, err, packages_loading = push_look()

        return ok or packages_loading == true, err, packages_loading == true, 0, 0
    end

    return mod.npclook_apply_active_look_to_bot_unit(player, nil)
end

mod.npclook_clear_bot_look = function(player)
    return live_visual.owners.clear(player, true)
end

mod.update = function(dt)
    dt = math.max(tonumber(dt) or 0, 0)
    update_live_package_releases()


    if _startup_cleanup_pending and _game_state_ready then
        _startup_cleanup_elapsed = _startup_cleanup_elapsed + dt

        if _startup_cleanup_elapsed >= BINDING_POLL_INTERVAL then
            _startup_cleanup_elapsed = 0
            _startup_cleanup_attempts = _startup_cleanup_attempts + 1

            local cleanup_player = get_local_player()
            local cleanup_unit = cleanup_player and safe_player_unit(cleanup_player)

            if cleanup_player and util.safe_unit_alive(cleanup_unit) then
                local ok_cleanup = INTERNAL.cleanup_stale_npclook_visuals(cleanup_player, cleanup_unit)

                if ok_cleanup then
                    _startup_cleanup_pending = false
                    _startup_cleanup_attempts = 0
                end
            end

            if _startup_cleanup_pending
                and _startup_cleanup_attempts >= STARTUP_CLEANUP_MAX_ATTEMPTS then
                _startup_cleanup_pending = false
                _startup_cleanup_attempts = 0
                schedule_reapply()
            end
        end
    end

    if not extra_slot_update_faulted and extra_slot_has_update_work then
        local ok_work, has_work = pcall(extra_slot_has_update_work)

        if not ok_work then
            extra_slot_update_faulted = true
            mod:error("Extra-slot maintenance failed and was disabled for this game state: %s", tostring(has_work))
        elseif has_work then
            local ok_update, update_error = pcall(extra_slot_update, dt)

            if not ok_update then
                extra_slot_update_faulted = true
                pcall(extra_slot_runtime.clear, 0)
                mod:error("Extra-slot maintenance failed and was disabled for this game state: %s", tostring(update_error))
            end
        end
    end

    LOADOUT_PRESETS.update(dt)
    live_visual.owners.update(dt)

    local active_look = live_visual.has_active_look()
    local reapply_due = (_reapply_pending or _vanilla_restore_pending) and _game_state_ready
        and not _startup_cleanup_pending
        and gameplay_time_manager() ~= nil
        and util.retry_due(_reapply_retry, dt)

    if active_look then
        _binding_poll_elapsed = _binding_poll_elapsed + math.max(dt, 0)
    else
        _binding_poll_elapsed = 0
    end

    local player
    local player_unit
    local binding_poll_due = active_look
        and (_binding_poll_elapsed >= BINDING_POLL_INTERVAL or reapply_due)

    if binding_poll_due then
        _binding_poll_elapsed = 0
        player = get_local_player()
        player_unit = player and safe_player_unit(player)

        _package_unit_refresh_elapsed = _package_unit_refresh_elapsed + BINDING_POLL_INTERVAL

        if player_unit == _bound_player_unit and _package_unit_refresh_elapsed >= PACKAGE_UNIT_REFRESH_INTERVAL then
            _package_unit_refresh_elapsed = 0
            live_visual.refresh_active_package_units(visual_extension(player_unit))
        end

        if player_unit ~= _bound_player_unit then
            INTERNAL.reset_unit_binding()
            _bound_player_unit = player_unit
            schedule_reapply()
        end
    end

    if reapply_due then
        INTERNAL.run_reapply(player, player_unit)
    end
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "loadout_button_visible" or setting_id == "loadout_button_x"
        or setting_id == "loadout_button_y" then
        LOADOUT_PRESETS.settings_changed()
    end
end

mod.on_game_state_changed = function(status, state_name)
    local ui_manager = Managers.ui

    if ui_manager then
        INTERNAL.close_studio_views(ui_manager)
    end

    INTERNAL.finish_studio_session()
    _binding_poll_elapsed = 0
    _startup_cleanup_elapsed = 0
    _startup_cleanup_attempts = 0

    -- StateGameplay exits after the local unit is already gone.
    if status == "exit" and state_name == "StateGameplay" then
        _game_state_ready = false
        live_visual.owners.release_all(false)

        if next(_look_state.applied)
            or next(_look_state.suppressed)
            or next(_look_state.empty)
            or next(_look_state.extra_anchors)
            or next(_look_state.materials)
            or next(_look_state.variants)
            or next(_look_state.masks)
            or next(_look_state.meshes)
            or next(_look_state.opacity) then
            _reapply_pending = true
        end

        return
    end

    if state_name ~= "GameplayStateRun" then
        return
    end

    _game_state_ready = status == "enter"

    if type(LOADOUT_PRESETS.game_state_changed) == "function" then
        LOADOUT_PRESETS.game_state_changed(status, state_name)
    end

    if _game_state_ready then
        extra_slot_update_faulted = false
        _startup_cleanup_pending = true
        _startup_cleanup_elapsed = 0
        _startup_cleanup_attempts = 0
        util.reset_retry(_reapply_retry)
        schedule_reapply()
    else
        live_visual.owners.release_all(false)
        extra_slot_runtime.release_all()
        _bound_player_unit = nil

        if next(_look_state.applied)
            or next(_look_state.suppressed)
            or next(_look_state.empty)
            or next(_look_state.extra_anchors)
            or next(_look_state.materials)
            or next(_look_state.variants)
            or next(_look_state.masks)
            or next(_look_state.meshes)
            or next(_look_state.opacity) then
            _reapply_pending = true
        end
    end
end

function INTERNAL.shut_down()
    local function shutdown_step(label, fn, ...)
        if type(fn) ~= "function" then
            return true
        end

        local ok, err = pcall(fn, ...)

        if not ok then
            mod:warning("Shutdown step failed (%s): %s", tostring(label), tostring(err))
        end

        return ok
    end

    if rawget(mod, "npclook_instance_generation") == INSTANCE_GENERATION then
        rawset(mod, "npclook_instance_generation", INSTANCE_GENERATION + 1)
    end

    -- Stop package retirement before closing views, restoring base slots, or
    -- destroying extra units. DMF continues running PackageManager during reload.
    shutdown_step("begin extra-slot shutdown", extra_slot_runtime.begin_shutdown)

    local player = get_local_player()
    local player_unit = player and safe_player_unit(player)
    local ext = visual_extension(player_unit)
    local ui_manager = Managers.ui

    if ui_manager then
        shutdown_step("close Studio views", INTERNAL.close_studio_views, ui_manager)
    end

    shutdown_step("finish Studio session", INTERNAL.finish_studio_session)
    shutdown_step("restore companion looks", live_visual.owners.release_all, true)

    local has_extra_units = false

    if type(extra_slot_runtime.has_units) == "function" then
        local ok, result = pcall(extra_slot_runtime.has_units)
        has_extra_units = ok and result == true
    end

    if player and (next(_originals) or has_extra_units) then
        shutdown_step("restore live look", direct_restore, player)
    else
        shutdown_step("clear extra slots", extra_slot_runtime.clear, 0)
    end

    if ext then
        shutdown_step("sanitize live visibility", live_visual.sanitize_visibility_equipment, ext)
    end

    shutdown_step("stop loadout presets", LOADOUT_PRESETS.shutdown)
    shutdown_step("destroy extra-slot runtime", extra_slot_runtime.shutdown)
    shutdown_step("release raw-unit tickets", RAW_UNITS.release_all)
    shutdown_step("release live package records", release_all_live_package_records)

    table.clear(_originals)
    table.clear(live_visual.managed_slots)
    live_visual.plan = nil
    live_visual.plan_signature = nil
    table.clear(_look_state.applied)
    table.clear(_look_state.suppressed)
    table.clear(_look_state.empty)
    table.clear(_look_state.extra_anchors)
    table.clear(_look_state.extra_transforms)
    table.clear(_look_state.materials)
    table.clear(_look_state.variants)
    table.clear(_look_state.masks)
    table.clear(_look_state.meshes)
    table.clear(_look_state.opacity)
    table.clear(_raw_unit_spawn_warnings)
    table.clear(_generated_spawn_warnings)
    table.clear(_runtime_reports)
    _look_state.character_id = nil
    _look_state.breed = nil
    shutdown_step("refresh portrait", mod.npclook_refresh_portrait)

    _bound_player_unit = nil
    _reapply_pending = false
    _vanilla_restore_pending = false
    _live_profile_sync_waiting = false
    _binding_poll_elapsed = 0
    _startup_cleanup_pending = false
    _startup_cleanup_elapsed = 0
    util.reset_retry(_reapply_retry)
end

mod.on_unload = function(exit_game)
    if not exit_game then
        INTERNAL.shut_down()
    end
end
