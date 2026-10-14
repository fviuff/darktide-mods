local mod = get_mod("WarpEffects")

local PACKS = {
    warpfire = { settings = { "purgatus" } },
    bolt = { settings = { "void_bolt" } },
    assail = { settings = { "assail" } },
    red_lightning = { settings = { "red_lightning" } },
    smite = { settings = { "brain_burst" } },
    trauma = { settings = { "trauma_marker", "trauma_explosion" },
               key = "content/fx/particles/weapons/force_staff/force_staff_explosion_indicator" },
    voidstrike = { settings = { "voidstrike", "voidstrike_explosion" },
                   key = "content/fx/particles/weapons/force_staff/force_staff_projectile_cast_02" },
    inferno = { settings = { "purgatus" },
                key = "content/fx/particles/weapons/flame_staff/psyker_flame_staff_code_control" },
    dome = { settings = { "shield" },
             key = "content/characters/player/human/attachments_combat/psyker_shield/shield_sphere_functional" },
}

-- game effect -> { pack, setting, new effect }
local SWAPS = {}

local function swap(pack, setting, game_name, new_name)
    SWAPS[game_name] = { pack = pack, setting = setting, name = new_name }
end

-- trauma marker, keeps "radius"
swap("trauma", "trauma_marker", "content/fx/particles/weapons/force_staff/force_staff_explosion_indicator",
    "content/mods/warp_fx/trauma/force_staff_explosion_indicator")
swap("trauma", "trauma_marker", "content/fx/particles/weapons/force_staff/3p_force_staff_explosion_indicator",
    "content/mods/warp_fx/trauma/3p_force_staff_explosion_indicator")

-- electrokinetic staff
for _, name in ipairs({
    "force_staff_chainlightning_charging_hands",
    "force_staff_chainlightning_attacking_hands",
    "force_staff_chainlightning_attacking_link_01",
    "force_staff_chainlightning_attacking_link_02",
    "force_staff_chainlightning_attacking_link_03",
    "force_staff_chainlightning_impact_looping",
}) do
    swap("red_lightning", "red_lightning", "content/fx/particles/weapons/force_staff/" .. name,
        "content/mods/warp_fx/red_lightning/" .. name)
end

local PSYKER = "content/mods/warp_fx/psyker/"
local HEX_DOME = PSYKER .. "shield_hex"

-- staffs base shot
swap("bolt", "void_bolt", "content/fx/particles/abilities/psyker_smite_projectile_01",
    PSYKER .. "psyker_smite_projectile_01")
for _, name in ipairs({ "force_impact_01", "force_impact_wall_01" }) do
    swap("bolt", "void_bolt", "content/fx/particles/impacts/weapons/force_staff/" .. name, PSYKER .. name)
end

-- assail
for _, name in ipairs({ "psyker_throwing_knife_idle", "psyker_throwing_knife_trail",
                        "psyker_throwing_knife_trail_critical_strike" }) do
    swap("assail", "assail", "content/fx/particles/abilities/" .. name, PSYKER .. name)
end

-- voidstrike, keeps "charge_level"
for _, name in ipairs({ "psyker_bfg_projectile_charge_01", "psyker_bfg_projectile_charge_done_01", "psyker_bfg_projectile_01" }) do
    swap("voidstrike", "voidstrike", "content/fx/particles/weapons/bfg_staff/" .. name, PSYKER .. name)
end
swap("voidstrike", "voidstrike", "content/fx/particles/weapons/force_staff/force_staff_projectile_cast_02",
    PSYKER .. "force_staff_projectile_cast_02")
-- voidstrike hits use the void bolt hit (the voidstrike pack carries it too)
swap("voidstrike", "voidstrike", "content/fx/particles/abilities/psyker_smite_projectile_impact_01",
    PSYKER .. "force_impact_01")

-- purgatus, keeps "life"
for _, name in ipairs({ "psyker_flame_staff_code_control", "psyker_flame_staff_code_control_3p",
                        "psyker_flame_staff_charge", "psyker_flame_staff_impact_delay" }) do
    swap("inferno", "purgatus", "content/fx/particles/weapons/flame_staff/" .. name, PSYKER .. name)
end
-- burning enemies, from any source
swap("warpfire", "purgatus", "content/fx/particles/enemies/buff_warpfire", PSYKER .. "buff_warpfire")

-- telekine dome hits, pop-up and fade
swap("dome", "shield", "content/fx/particles/abilities/psyker_shield_block", PSYKER .. "psyker_shield_block")
for _, name in ipairs({ "protectorate_sphere_shield_init", "protectorate_sphere_shield_fade" }) do
    swap("dome", "shield", "content/fx/particles/abilities/" .. name, PSYKER .. name)
end

-- brain burst: the highlight on the target (only Brain Burst's own, other weapons use the same effect) and the burst,
-- which the game plays as the smite hit's discharge
local SMITE_TARGET = PSYKER .. "smite_target"
local SMITE_FLARE = PSYKER .. "smite_flare"
local SMITE_GHOST = PSYKER .. "smite_ghost"
local SMITE_WARP = PSYKER .. "smite_warp"       -- warp smoke, wisps and pulled streaks around the ghost
local SMITE_FULL = PSYKER .. "smite_full"       -- flash when the charge on a target is full
local SMITE_RIFT = PSYKER .. "smite_rift"       -- the Riftlance's black rift
local SMITE_BURST = PSYKER .. "smite_burst"     -- the rift explosion, shutting faster
local RIFT_HOLD = 0.15                          -- the black rift opens to full size, then explodes
local SOUNDS = "wwise/events/warp_fx/"
local RIFT_SOUNDS = {}
for i = 1, 5 do
    RIFT_SOUNDS[i] = SOUNDS .. "play_warp_fx_rift_explosion_0" .. i
end
-- the Riftlance's beam loop instead of the brain burst charge's heartbeat (hands)
local CHARGE_LOOP = SOUNDS .. "play_warp_fx_smite_charge_loop"
local HEARTBEAT = "wwise/events/weapon/play_psyker_headpop_hands"
local HEARTBEAT_STOP = "wwise/events/weapon/stop_psyker_headpop_hands"
local DISCHARGE = "content/fx/particles/impacts/weapons/force_staff/force_staff_channeling_discharge_01"

local GAME_EXPLOSION = "content/fx/particles/weapons/force_staff/force_staff_explosion"
local RIFT = "content/mods/warp_fx/trauma/rift_explosion"
-- both packs carry the rift
local EXPLOSIONS = {
    default_force_staff_demolition = { pack = "trauma", setting = "trauma_explosion", name = RIFT },
    force_staff_p4_demolition = { pack = "voidstrike", setting = "voidstrike_explosion", name = RIFT },
}

-- skin glow on burning enemies, with the runefire
local WARPFIRE_RAMP = "content/mods/warp_fx/shared/fx_612e95b62b8e2aeb_0f31f016_a9e8948a"
local original_warpfire_ramp

local SHARD_UNIT = "content/weapons/player/ranged/throwing_shard/wpn_throwing_shard_01"
local SHARD_COLOURS = {
    tint_color = { 0.4, 0.04, 0.68 },
    depth_color = { 0.05, 0, 0.08 },
    spot_color = { 0.95, 0.3, 1 },
    edge_color = { 0.12, 0.06, 0.16 },
}

local GAME_MARKERS = {
    ["content/fx/units/weapons/decal_force_staff_explosion_marker"] = true,
    ["content/fx/units/weapons/decal_force_staff_explosion_marker_3p"] = true,
}

local settings = {}

local original_vfx = {}

local custom_assets
local packs_by_key = {}
local forget_level   -- drops what the mod keeps of a level's world (Brain Burst)

local function loaded(pack_name)
    return PACKS[pack_name].state == "on"
end

local function apply_explosions()
    local templates = require("scripts/settings/damage/explosion_templates")

    for template_name, entry in pairs(EXPLOSIONS) do
        local template = templates[template_name]

        if template and template.scalable_vfx then
            original_vfx[template_name] = original_vfx[template_name] or template.scalable_vfx

            local original = original_vfx[template_name]

            if mod:is_enabled() and settings[entry.setting] and loaded(entry.pack) then
                -- other templates can share the games table
                local vfx = table.clone(original)

                for _, vfx_data in ipairs(vfx) do
                    for i, effect_name in ipairs(vfx_data.effects) do
                        if effect_name == GAME_EXPLOSION then
                            vfx_data.effects[i] = entry.name
                        end
                    end
                end

                template.scalable_vfx = vfx
            else
                template.scalable_vfx = original
            end
        end
    end
end

local function warpfire_gradient()
    local AilmentSettings = require("scripts/settings/ailments/ailment_settings")

    for _, data in ipairs(AilmentSettings.effect_templates[AilmentSettings.effects.warpfire].material_textures) do
        if data.slot == "effect_gradient" then
            return data
        end
    end
end

local function apply_warpfire()
    local gradient = warpfire_gradient()

    if not gradient then
        return
    end

    original_warpfire_ramp = original_warpfire_ramp or gradient.resource

    if mod:is_enabled() and settings.purgatus and loaded("warpfire") then
        gradient.resource = WARPFIRE_RAMP
    else
        gradient.resource = original_warpfire_ramp
    end
end

-- "rift" or "ghost" while Brain Burst is replaced
local function smite_style()
    local style = settings.brain_burst

    if mod:is_enabled() and style ~= "off" and loaded("smite") then
        return style
    end
end

local original_targeting_fx = {}

local function apply_smite()
    local actions = require("scripts/settings/equipment/weapon_templates/weapon_templates").psyker_smite.actions

    for action_name, action in pairs(actions) do
        local targeting_fx = original_targeting_fx[action_name] or action.targeting_fx

        if targeting_fx then
            original_targeting_fx[action_name] = targeting_fx

            if smite_style() then
                -- the husk effect (other players' brain burst) stays
                local own = table.clone(targeting_fx)

                own.effect_name = SMITE_TARGET
                action.targeting_fx = own
            else
                action.targeting_fx = targeting_fx
            end
        end
    end
end

local function restore_smite()
    local actions = require("scripts/settings/equipment/weapon_templates/weapon_templates").psyker_smite.actions

    for action_name, targeting_fx in pairs(original_targeting_fx) do
        actions[action_name].targeting_fx = targeting_fx
    end
end

local function apply_tables()
    apply_explosions()
    apply_warpfire()
    apply_smite()
end

-- set while the game plays your brain burst's hit: its discharge becomes the burst
local burst

local function new_name(name)
    if burst and name == DISCHARGE then
        burst.played = true

        return burst.name
    end

    local entry = SWAPS[name]

    if entry and settings[entry.setting] and loaded(entry.pack) then
        return entry.name
    end

    return name
end

-- Loading

local function wanted(pack)
    if not mod:is_enabled() then
        return false
    end

    for _, setting in ipairs(pack.settings) do
        local value = settings[setting]

        if value and value ~= "off" then
            return true
        end
    end

    return false
end

local function game_has_key(pack)
    return pack.key == nil or Managers.package:reference_count(pack.key) > 0
end

local function load_pack(name)
    local pack = PACKS[name]

    if pack.state or not custom_assets or not wanted(pack) then
        return
    end

    pack.state = "loading"

    local ticket, err = custom_assets.acquire(mod, "WarpEffects:" .. name, function(loaded_ticket, asset, load_error)
        if pack.ticket ~= loaded_ticket then
            return
        end

        if load_error or not asset then
            mod:error("%s didnt load (%s), see the CustomAssets log", name, tostring(load_error))
            pack.state, pack.ticket = "failed", nil
            return
        end

        pack.state = "on"
        apply_tables()
    end)

    if not ticket then
        mod:error("%s isnt installed (%s), run the patcher", name, tostring(err))
        pack.state = "failed"
        return
    end

    pack.ticket = ticket
end

local function load_wanted()
    if not custom_assets or not Managers.package then
        return
    end

    for name, pack in pairs(PACKS) do
        if game_has_key(pack) then
            load_pack(name)
        end
    end
end

local function read_settings()
    for _, setting in ipairs({ "trauma_marker", "hide_game_marker", "red_lightning", "void_bolt",
                               "trauma_explosion", "voidstrike_explosion", "assail", "voidstrike", "purgatus", "shield" }) do
        settings[setting] = mod:get(setting) ~= false
    end

    settings.brain_burst = mod:get("brain_burst") or "ghost"
    settings.shield_style = mod:get("shield_style") or "hex"

    apply_tables()
    load_wanted()
end

read_settings()

-- the game loading a key package loads its pack along
mod:hook_safe("PackageManager", "load", function(_, package_name)
    local name = packs_by_key[package_name]

    if name then
        load_pack(name)
    end
end)

-- nothing of the level is left to use a pack now
mod.on_game_state_changed = function(status, state_name)
    if not (status == "exit" and state_name == "StateGameplay") then
        return
    end

    forget_level()

    if not custom_assets then
        return
    end

    for _, pack in pairs(PACKS) do
        if pack.state == "on" and not (wanted(pack) and game_has_key(pack)) then
            custom_assets.release(pack.ticket)
            pack.state, pack.ticket = nil, nil
        end
    end

    apply_tables()
end

mod.on_all_mods_loaded = function()
    custom_assets = get_mod("CustomAssets")

    if not custom_assets or not custom_assets.is_api_compatible(1) then
        mod:error("needs CustomAssets")
        custom_assets = nil
        return
    end

    for name, pack in pairs(PACKS) do
        if pack.key then
            packs_by_key[pack.key] = name
        end
    end

    load_wanted()
end

mod.on_setting_changed = read_settings

mod.on_enabled = function()
    apply_tables()
    load_wanted()
end

mod.on_disabled = apply_tables

mod.on_unload = function()
    local templates = require("scripts/settings/damage/explosion_templates")

    for template_name, original in pairs(original_vfx) do
        templates[template_name].scalable_vfx = original
    end

    local gradient = warpfire_gradient()

    if gradient and original_warpfire_ramp then
        gradient.resource = original_warpfire_ramp
    end

    restore_smite()

    if custom_assets then
        custom_assets.release_owner(mod)
    end
end

-- Swapping

mod:hook(World, "create_particles", function(func, world, name, ...)
    local id = func(world, new_name(name), ...)

    if burst and name == DISCHARGE then
        burst.effect = id
    end

    return id
end)

mod:hook(World, "find_particles_variable", function(func, world, name, ...)
    return func(world, new_name(name), ...)
end)

-- the links keep their own World.create_particles
mod:hook("FxData", "spawn_vfx", function(func, self, world, name, ...)
    return func(self, world, new_name(name), ...)
end)

mod:hook("FxData", "spawn_vfx_world_position", function(func, self, world, source_unit, source_node, target_pos, target_normal, name, ...)
    return func(self, world, source_unit, source_node, target_pos, target_normal, new_name(name), ...)
end)

mod:hook(World, "spawn_unit_ex", function(func, world, unit_name, ...)
    local unit = func(world, unit_name, ...)

    if GAME_MARKERS[unit_name] and settings.hide_game_marker and settings.trauma_marker and loaded("trauma") and
        unit then
        Unit.set_unit_visibility(unit, false, true)
    elseif unit_name == SHARD_UNIT and settings.assail and unit then
        for variable, colour in pairs(SHARD_COLOURS) do
            Unit.set_vector3_for_materials(unit, variable, Vector3(colour[1], colour[2], colour[3]), true)
        end
    end

    return unit
end)

-- Telekine dome

-- the games dome stays for physics, its mesh is hidden under the hex dome
local BRIGHTNESS_VARIABLE = "particle_color"   -- x scales the ramp lookup
local PLATES = 162
local LIFT = 0.3                     -- how far a plate moves out
local FACE, FACE_LIT = 0.12, 1.8
local RIM, RIM_LIT = 0.45, 2.5
local CLEAR = 0.4                    -- brightness of the clearer hexagon dome

local domes = {}

local function remove_dome(extension)
    local entry = domes[extension]

    domes[extension] = nil

    if entry and Unit.alive(entry.unit) then
        local world = Unit.world(entry.unit)

        World.unlink_unit(world, entry.unit)
        World.destroy_unit(world, entry.unit)
    end
end

-- plates light up the further out they are
local function update_dome(entry)
    local dome = entry.unit
    local brightness = settings.shield_style == "clear" and CLEAR or 1

    for i = 1, PLATES do
        local lift = math.min(Vector3.length(Unit.local_position(dome, entry.nodes[i])) / LIFT, 1)
        local face = (FACE * entry.shades[i] + FACE_LIT * lift) * brightness
        local level = entry.levels[i]

        if not level or math.abs(level - face) > 0.01 then
            local rim = (RIM + RIM_LIT * lift) * brightness

            entry.levels[i] = face
            Material.set_vector4(entry.faces[i], BRIGHTNESS_VARIABLE, Color(face, face, face, face))
            Material.set_vector4(entry.rims[i], BRIGHTNESS_VARIABLE, Color(rim, rim, rim, rim))
        end
    end
end

mod:hook_safe("PsykerForceFieldUnitExtension", "init", function(self, extension_init_context, unit)
    if not (self._sphere_shield and settings.shield and loaded("dome")) then
        return
    end

    local world = extension_init_context.world
    local dome = World.spawn_unit_ex(world, HEX_DOME, nil, Unit.world_pose(unit, 1))

    World.link_unit(world, dome, 1, unit, 1)

    for i = 1, Unit.num_meshes(unit) do
        Unit.set_mesh_visibility(unit, i, false)
    end

    local entry = { unit = dome, faces = {}, rims = {}, nodes = {}, shades = {}, levels = {} }

    for i = 1, PLATES do
        entry.faces[i] = Mesh.material(Unit.mesh(dome, "hex_" .. i .. "_p0"), 1)
        entry.rims[i] = Mesh.material(Unit.mesh(dome, "hex_" .. i .. "_rim_p0"), 1)
        entry.nodes[i] = Unit.node(dome, "plate_" .. i)
        entry.shades[i] = 0.8 + math.random() * 0.4
    end

    Unit.enable_animation_state_machine(dome)

    domes[self] = entry
end)

-- the games own life update reaches the hex dome too, it sets it on linked units
mod:hook_safe("PsykerForceFieldUnitExtension", "_update_effects", function(self)
    local entry = domes[self]

    if entry and not self.is_expired and Unit.alive(entry.unit) then
        update_dome(entry)
    end
end)

mod:hook_safe("PsykerForceFieldUnitExtension", "on_death", function(self)
    local entry = domes[self]

    if entry and Unit.alive(entry.unit) then
        Unit.set_unit_visibility(entry.unit, false, true)
    end
end)

-- Brain Burst

local GHOST_DARK = { "ghost_body_p0", "ghost_eyeball_p0", "ghost_lid_p0", "ghost_lens_p0" }   -- alpha blended: opacity_amount
local GHOST_LENS = "ghost_lens_glow_p0"              -- dome material over the lens (only adds red light)
local GHOST_RISE, GHOST_BACK = 1.21, 0.6   -- over the target's head, and behind it seen from you
local GHOST_SCALE_FROM, GHOST_SCALE_TO = 0.63, 0.9
local GHOST_EYE_FROM, GHOST_EYE_TO = 0.5, 4         -- the eye's glow, from a dim red to bright
local GHOST_FADE = 4                        -- per second, in and out
local GHOST_SEEN = 0.15                     -- seconds without a targeting update before it fades
local BURST_FLASH, BURST_TIME = 3, 0.3

local DAMAGE_SMITE = require("scripts/settings/damage/damage_settings").damage_types.smite

local clock = 0
local ghost        -- { world, unit, dark, lens, warp, target, charge, seen, alpha, burst }
local rifts = {}   -- black rifts waiting to explode: { world, effect, position, explode_t }
local flashed      -- the target the full charge flash played on, until the targeting ends
local charge_loop  -- { wwise_world, id }

-- the levels world is going away with everything in it
forget_level = function()
    ghost, rifts, flashed, charge_loop = nil, {}, nil, nil
end

local function smite_actions()
    return require("scripts/settings/equipment/weapon_templates/weapon_templates").psyker_smite.actions
end

local function remove_ghost()
    if ghost and ghost.unit and Unit.alive(ghost.unit) then
        World.destroy_unit(ghost.world, ghost.unit)
    end

    -- the smoke already out drifts off
    if ghost and ghost.warp then
        World.stop_spawning_particles(ghost.world, ghost.warp)
    end

    ghost = nil
end

local function mesh_material(unit, mesh)
    return Unit.has_mesh(unit, mesh) and Mesh.material(Unit.mesh(unit, mesh), 1) or nil
end

local function spawn_ghost(world, position, rotation)
    local unit = World.spawn_unit_ex(world, SMITE_GHOST, nil, Matrix4x4.from_quaternion_position(rotation, position))
    local dark = {}

    for _, mesh in ipairs(GHOST_DARK) do
        dark[#dark + 1] = mesh_material(unit, mesh)
    end

    Unit.set_scalar_for_materials(unit, "psyker_sphere_shield_life", 1, true)
    Unit.enable_animation_state_machine(unit)

    return unit, dark, mesh_material(unit, GHOST_LENS), World.create_particles(world, SMITE_WARP, position)
end

local function head_position(unit)
    local node = Unit.has_node(unit, "j_head") and Unit.node(unit, "j_head") or 1

    return Unit.world_position(unit, node)
end

local function update_ghost(dt)
    local target = ghost.target

    if not Unit.alive(target) then
        ghost.target, target = nil, nil
    end

    local showing = target and not ghost.burst and clock - ghost.seen < GHOST_SEEN
    local charge = ghost.charge
    local alpha = math.clamp(ghost.alpha + (showing and dt or -dt) * GHOST_FADE, 0, 1)
    local flash = 1

    if ghost.burst then
        ghost.burst = ghost.burst + dt
        flash = 1 + BURST_FLASH * math.max(1 - ghost.burst / BURST_TIME, 0)
        alpha = math.max(1 - ghost.burst / BURST_TIME, 0)
    end

    ghost.alpha = alpha

    if alpha <= 0 and not showing then
        remove_ghost()

        return
    end

    local player = Managers.player:local_player(1)
    local player_unit = player and player.player_unit

    if target and player_unit then
        local eye = Unit.world_position(player_unit, 1) + Vector3(0, 0, 1.6)
        local head = head_position(target)
        local away = Vector3.flat(head - eye)

        away = Vector3.length(away) > 0.01 and Vector3.normalize(away) or Vector3(0, 1, 0)

        local position = head + Vector3(0, 0, GHOST_RISE) + away * GHOST_BACK

        ghost.position = Vector3Box(position)
        ghost.rotation = QuaternionBox(Quaternion.look(eye - position, Vector3.up()))
    end

    if not ghost.position then
        return
    end

    if not ghost.unit then
        if not showing then
            remove_ghost()

            return
        end

        ghost.unit, ghost.dark, ghost.lens, ghost.warp = spawn_ghost(ghost.world, ghost.position:unbox(),
            ghost.rotation:unbox())
    end

    local unit = ghost.unit
    local scale = GHOST_SCALE_FROM + (GHOST_SCALE_TO - GHOST_SCALE_FROM) * charge

    Unit.set_local_position(unit, 1, ghost.position:unbox())
    Unit.set_local_rotation(unit, 1, ghost.rotation:unbox())
    Unit.set_local_scale(unit, 1, Vector3(scale, scale, scale))

    if ghost.warp then
        World.move_particles(ghost.world, ghost.warp, ghost.position:unbox())
    end

    for _, material in ipairs(ghost.dark) do
        Material.set_scalar(material, "opacity_amount", alpha)
    end

    if ghost.lens then
        local eye = (GHOST_EYE_FROM + (GHOST_EYE_TO - GHOST_EYE_FROM) * charge * charge) * alpha * flash

        Material.set_vector4(ghost.lens, "particle_color", Color(eye, eye, eye, eye))
    end
end

local function update_rifts()
    for i = #rifts, 1, -1 do
        local rift = rifts[i]

        if clock >= rift.explode_t then
            table.remove(rifts, i)

            local position = rift.position:unbox()

            if rift.effect and World.are_particles_playing(rift.world, rift.effect) then
                World.destroy_particles(rift.world, rift.effect)
            end

            World.create_particles(rift.world, SMITE_BURST, position)
            WwiseWorld.trigger_resource_event(Wwise.wwise_world(rift.world), RIFT_SOUNDS[math.random(#RIFT_SOUNDS)],
                position)
        end
    end
end

mod.update = function(dt)
    clock = clock + dt

    if #rifts > 0 then
        update_rifts()
    end

    if ghost then
        if ghost.unit and not Unit.alive(ghost.unit) then
            ghost = nil
        else
            update_ghost(dt)
        end
    end
end

mod:hook_safe("PsykerSingleTargetEffects", "_update_targeting_effects", function(self)
    if not self._is_local_unit or self._is_husk or self._weapon_actions ~= smite_actions() then
        return
    end

    local style = smite_style()
    local target = style and self._targeting_effect_id and self._action_module_target_finder_component.target_unit_1

    if not target then
        flashed = nil

        return
    end

    local charge = self:_charge_level()

    if charge >= 1 and flashed ~= target then
        flashed = target
        World.create_particles(self._world, SMITE_FULL, head_position(target))
    end

    if style ~= "ghost" then
        return
    end

    if ghost and (ghost.burst or ghost.target ~= target) then
        remove_ghost()
    end

    ghost = ghost or { world = self._world, alpha = 0 }
    ghost.target, ghost.charge, ghost.seen = target, charge, clock
end)

mod:hook(WwiseWorld, "trigger_resource_event", function(func, wwise_world, name, ...)
    if name == HEARTBEAT and smite_style() then
        if charge_loop then
            WwiseWorld.stop_event(charge_loop.wwise_world, charge_loop.id)
        end

        local id, source = func(wwise_world, CHARGE_LOOP, ...)

        charge_loop = { wwise_world = wwise_world, id = id }

        return id, source
    elseif name == HEARTBEAT_STOP and charge_loop then
        WwiseWorld.stop_event(charge_loop.wwise_world, charge_loop.id)
        charge_loop = nil

        return
    end

    return func(wwise_world, name, ...)
end)

mod:hook("ActionDamageTarget", "_deal_damage", function(func, self, charge_level)
    local style = smite_style()
    local player = Managers.player:local_player(1)

    if not style or self._action_settings.damage_type ~= DAMAGE_SMITE or self._player ~= player then
        return func(self, charge_level)
    end

    local world = self._world
    local target = self._action_module_target_finder_component.target_unit_1
    local head = target and Unit.alive(target) and head_position(target)

    burst = { name = SMITE_RIFT }

    local ok, dealt = pcall(func, self, charge_level)
    local played, effect = burst.played, burst.effect

    burst = nil

    if not ok then
        error(dealt)
    end

    if dealt and head then
        if not played then
            effect = World.create_particles(world, SMITE_RIFT, head)
        end

        rifts[#rifts + 1] = { world = world, effect = effect, position = Vector3Box(head), explode_t = clock + RIFT_HOLD }

        if style == "ghost" then
            World.create_particles(world, SMITE_FLARE, head)

            if ghost then
                ghost.burst = 0
            end
        end
    end

    return dealt
end)

mod:hook("PsykerForceFieldUnitExtension", "destroy", function(func, self, ...)
    remove_dome(self)

    return func(self, ...)
end)
