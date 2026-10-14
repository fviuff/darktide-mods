local mod = get_mod("Riftlance")

local ArmorSettings = require("scripts/settings/damage/armor_settings")
local Attack = require("scripts/utilities/attack/attack")
local AttackSettings = require("scripts/settings/damage/attack_settings")
local BaseTemplateSettings = require("scripts/settings/equipment/weapon_templates/base_template_settings")
local DamageSettings = require("scripts/settings/damage/damage_settings")
local Explosion = require("scripts/utilities/attack/explosion")
local GibbingSettings = require("scripts/settings/gibbing/gibbing_settings")
local HitZone = require("scripts/utilities/attack/hit_zone")
local ImpactEffect = require("scripts/utilities/attack/impact_effect")
local PowerLevelSettings = require("scripts/settings/damage/power_level_settings")
local SurfaceMaterialSettings = require("scripts/settings/surface_material_settings")
local WarpCharge = require("scripts/utilities/warp_charge")

local STAFF = "forcestaff_p3_m1"
local RELEASE = "action_release"     -- has to be an action name the network already knows
local FX = "content/mods/riftlance/"
local BEAM, FLARE = FX .. "riftlance_beam", FX .. "riftlance_flare"
local IMPACT, FLARE_IMPACT = FX .. "riftlance_impact", FX .. "riftlance_flare_impact"
local RIFT, BURST = FX .. "riftlance_rift", FX .. "riftlance_burst"
local BEAM_SOURCE = "fx_left_hand"
local OPEN_HAND = "attack_charge_shoot_lightning"
local HOLD_HAND = "loop"             -- 1p only
local HOLD_AFTER = 0.5
local CLOSE_HAND = "attack_charge_lightning"
local SOUNDS = "wwise/events/riftlance/"
local BEAM_LOOP = SOUNDS .. "play_riftlance_beam_loop"
local RIFT_SOUNDS = {}
for i = 1, 5 do
    RIFT_SOUNDS[i] = SOUNDS .. "play_riftlance_rift_explosion_0" .. i
end
local RANGE = 60
local FLARE_TIME = 0.3               -- matches the flare effect
local RELEASE_TIME = 0.5
local SECONDS_PER_RIFT = 1.5
local MAX_RIFTS = 30
local RIFT_OPEN_STAGGER = 0.03
local RIFT_EXPLODE_AFTER = 0.05
local RIFT_EXPLODE_SPREAD = 0.25
local TICK_TIME = 0.1
-- at power 500 the attack value is the damage
local POWER_LEVEL = 500
local BEAM_DAMAGE, BEAM_STAGGER = 30, 2
local FLARE_DAMAGE, FLARE_STAGGER = 1700, 15
local RIFT_DAMAGE, RIFT_STAGGER = 1000, 20
-- loads with the surge staff, other staffs sounds stall the sound thread
local DAMAGE_TYPE = DamageSettings.damage_types.force_staff_single_target
local BEAM_PERIL = { warp_charge_percent = 0.01 }
local RELEASE_PERIL = { warp_charge_percent = 0.03 }
-- faster hand close, the state machine has it at a fixed speed
local CLOSE_LAYER = 4
local CLOSE_FROM, CLOSE_UNTIL, CLOSE_SPEED = 0.2, 0.55, 2

-- Damage

-- the name is the voidstrike profiles, the network sends profiles by name
local function damage_profile(attack, impact)
    local full = {}

    for _, armor_type in pairs(ArmorSettings.types) do
        full[armor_type] = 1
    end

    return {
        name = "default_bfg",
        ignore_hitzone_multiplier = true,
        ragdoll_push_force = 600,
        stagger_category = "ranged",
        cleave_distribution = { attack = 0.15, impact = 0.15 },
        armor_damage_modifier = { attack = full, impact = full },
        power_distribution = { attack = attack, impact = impact },
        gibbing_power = GibbingSettings.gibbing_power.heavy,
        gibbing_type = GibbingSettings.gibbing_types.warp,
        targets = { default_target = { boost_curve = PowerLevelSettings.boost_curves.default } },
    }
end

local beam_profile = damage_profile(BEAM_DAMAGE, BEAM_STAGGER)
local flare_profile = damage_profile(FLARE_DAMAGE, FLARE_STAGGER)
local rift_profile = damage_profile(RIFT_DAMAGE, RIFT_STAGGER)

-- keeps the games name, explosions are looked up by name too
local function explosion_template(base_name, changes, removed)
    local ExplosionTemplates = require("scripts/settings/damage/explosion_templates")
    local template = table.clone(ExplosionTemplates[base_name])

    for key, value in pairs(changes) do
        template[key] = value
    end

    for _, key in ipairs(removed) do
        template[key] = nil
    end

    return template
end

local rift_explosion

local function explode(world, physics_world, position, player_unit, template)
    Explosion.create_explosion(world, physics_world, position, Quaternion.identity(), player_unit, template, POWER_LEVEL,
        1, AttackSettings.attack_types.explosion, false, false, nil, nil, nil, nil, nil, nil, nil, true)
end

-- beam hits play their effects without sounds
local SURFACE_FX = {}
local silent_impacts = false
local silent_copies = {}

local function silent(impact_fx)
    if not silent_impacts or type(impact_fx) ~= "table" then
        return impact_fx
    end

    local copy = silent_copies[impact_fx]

    if not copy then
        copy = table.shallow_copy(impact_fx)

        for key in pairs(impact_fx) do
            if type(key) == "string" and string.find(key, "sfx", 1, true) then
                copy[key] = nil
            end
        end
        silent_copies[impact_fx] = copy
    end

    return copy
end

mod:hook("FxSystem", "play_impact_fx", function(func, self, impact_fx, ...)
    return func(self, silent(impact_fx), ...)
end)

mod:hook(ImpactEffect, "surface_impact_fx", function(func, ...)
    local impact_fx, hit_unit, hit_actor = func(...)

    return silent(impact_fx), hit_unit, hit_actor
end)

local function hit(action_or_flare, profile, position, unit, actor, normal, direction)
    local player_unit, physics_world = action_or_flare.player_unit, action_or_flare.physics_world

    silent_impacts = true

    if unit then
        if action_or_flare.is_server then
            local hit_zone = HitZone.get_name(unit, actor)
            local damage, result, efficiency = Attack.execute(unit, profile, "power_level", POWER_LEVEL, "charge_level", 1,
                "hit_world_position", position, "hit_zone_name", hit_zone, "hit_actor", actor, "attacking_unit",
                player_unit, "attack_direction", direction, "attack_type", AttackSettings.attack_types.ranged,
                "damage_type", DAMAGE_TYPE)

            ImpactEffect.play(unit, actor, damage, DAMAGE_TYPE, hit_zone, result, position, normal, direction, player_unit,
                nil, nil, nil, efficiency, profile)
        end
    elseif normal then
        ImpactEffect.play_surface_effect(physics_world, player_unit, position, normal, direction, DAMAGE_TYPE,
            SurfaceMaterialSettings.hit_types.stop, SURFACE_FX)
    end

    silent_impacts = false
end

local sounds_loaded = false

local function play_sound(world, event, position_or_source)
    if sounds_loaded then
        return WwiseWorld.trigger_resource_event(Wwise.wwise_world(world), event, position_or_source)
    end
end

-- Switching

-- the action objects keep these tables, so editing them in place switches live
local LANCE_CROSSHAIR = { crosshair_type = "dot" }
local loaded = false
local original = nil

-- keeps the shots stop_input, without it the inputs get stuck after a release
local function release_action(shoot)
    local release = table.clone(shoot)

    release.kind = "dummy"
    release.riftlance_release = true
    release.anim_event, release.anim_event_3p = CLOSE_HAND, CLOSE_HAND
    release.total_time = RELEASE_TIME
    release.stop_time = nil
    release.running_action_state_to_action_input = nil
    release.allowed_chain_actions = {
        wield = BaseTemplateSettings.generate_wield_chain_actions({ chain_time = 0.3 }),
    }

    return release
end

local function apply()
    local WeaponTemplates = require("scripts/settings/equipment/weapon_templates/weapon_templates")
    local actions = WeaponTemplates[STAFF].actions
    local charge = actions.action_charge
    local lance = loaded and mod:is_enabled() and mod:get("lance") or false

    original = original or {
        chain = charge.allowed_chain_actions.shoot_charged.action_name,
        targeting = charge.targeting_fx,
        crosshair = charge.crosshair,
        sound = charge.charge_effects.looping_sound_alias,
    }
    actions[RELEASE] = actions[RELEASE] or release_action(actions.action_shoot_charged)
    charge.riftlance_beam = lance or nil
    charge.allowed_chain_actions.shoot_charged.action_name = lance and RELEASE or original.chain
    charge.targeting_fx = not lance and original.targeting or nil
    charge.crosshair = lance and LANCE_CROSSHAIR or original.crosshair
    if lance and sounds_loaded then
        charge.charge_effects.looping_sound_alias = nil
    else
        charge.charge_effects.looping_sound_alias = original.sound
    end
end

mod:command("riftlance", mod:localize("command_riftlance"), function()
    mod:set("lance", not mod:get("lance"))
    apply()
    mod:echo(mod:localize(mod:get("lance") and "now_lance" or "now_surge"))
end)

mod.on_all_mods_loaded = function()
    -- no sfx, the rifts play their own
    rift_explosion = explosion_template("default_force_staff_demolition", {
        radius = 3.25,
        close_radius = 1.75,
        scalable_radius = false,
        static_power_level = POWER_LEVEL,
        damage_profile = rift_profile,
        close_damage_profile = rift_profile,
        scalable_vfx = { { min_radius = 0, radius_variable_name = "radius", effects = { BURST } } },
    }, { "min_radius", "min_close_radius", "sfx" })

    local custom_assets = get_mod("CustomAssets")

    if not custom_assets or not custom_assets.is_api_compatible(1) then
        mod:error("needs CustomAssets")
        return
    end

    custom_assets.acquire(mod, "Riftlance:riftlance", function(_, asset, err)
        if err or not asset then
            mod:error("riftlance didnt load (%s), see the CustomAssets log", tostring(err))
            return
        end

        loaded = true
        apply()
    end)
    custom_assets.acquire(mod, "Riftlance:riftlance_sounds", function(_, asset, err)
        if err or not asset then
            mod:error("riftlance_sounds didnt load (%s), see the CustomAssets log", tostring(err))
            return
        end

        sounds_loaded = true
        apply()
    end)
end

mod.on_enabled = apply
mod.on_disabled = apply

mod.on_unload = function()
    loaded = false
    sounds_loaded = false
    apply()

    local custom_assets = get_mod("CustomAssets")

    if custom_assets then
        custom_assets.release_owner(mod)
    end
end

-- Beam placement

local beams = {}          -- charge action -> beam
local released = nil      -- last ended beam, picked up by the release
local flares = {}
local rifts = {}
local closing = {}

local function effect_variables(world, name)
    return {
        length = World.find_particles_variable(world, name, "length"),
        start = World.find_particles_variable(world, name, "start"),
        finish = World.find_particles_variable(world, name, "end"),
    }
end

local function spawn_beam(world, effect_name, impact_name)
    return {
        effect = World.create_particles(world, effect_name, Vector3.zero()),
        impact = World.create_particles(world, impact_name, Vector3.zero()),
        variables = effect_variables(world, effect_name),
    }
end

-- lightning stretches along +y by "length", the core ray goes from "start" to "end"
local function place(world, beam, origin, target)
    local direction, length = Vector3.direction_length(target - origin)

    if length < 0.01 then
        return
    end

    local variables = beam.variables

    World.move_particles(world, beam.effect, origin, Quaternion.look(direction))
    World.set_particles_variable(world, beam.effect, variables.length, Vector3(length, 1, 1))
    World.set_particles_variable(world, beam.effect, variables.start, origin)
    World.set_particles_variable(world, beam.effect, variables.finish, target)
    World.move_particles(world, beam.impact, target, Quaternion.look(-direction))
end

local function hand_position(source_unit, source_node, fallback)
    if source_unit and Unit.alive(source_unit) then
        return Unit.world_position(source_unit, source_node)
    end

    return fallback
end

-- afro hit zones are skipped, hitting them crashed the ragdoll
local AFRO = HitZone.hit_zone_names.afro

local function aim(player_unit, physics_world, first_person)
    local from, direction = first_person.position, Quaternion.forward(first_person.rotation)
    local hits = PhysicsWorld.raycast(physics_world, from, direction, RANGE, "all", "types", "both", "max_hits", 32,
        "collision_filter", "filter_player_character_shooting_raycast")

    if hits then
        local side_system = Managers.state.extension:system("side_system")

        for i = 1, #hits do
            local found = hits[i]
            local actor = found.actor or found[4]
            local unit = actor and Actor.unit(actor)

            if unit ~= player_unit then
                local position, normal = found.position or found[1], found.normal or found[3]

                if not (unit and HEALTH_ALIVE[unit]) then
                    return position, nil, actor, normal, direction
                elseif side_system:is_enemy(player_unit, unit) then
                    local hit_zone = HitZone.get_name(unit, actor)

                    if hit_zone and hit_zone ~= AFRO then
                        return position, unit, actor, normal, direction
                    end
                end
            end
        end
    end

    return from + direction * RANGE, nil, nil, nil, direction
end

local function beam_points(action, beam)
    local first_person = action._first_person_component
    local origin = hand_position(beam.source_unit, beam.source_node, first_person.position)

    return origin, aim(action._player_unit, action._physics_world, first_person)
end

-- Beam

mod:hook_safe("ActionOverloadChargeTargetFinder", "start", function(self, action_settings, t)
    if not action_settings.riftlance_beam then
        return
    end

    local beam = { start_t = t, next_tick = t + TICK_TIME, opened = false, held = false, player_unit = self._player_unit,
        physics_world = self._physics_world, is_server = self._is_server }

    if self._is_local_unit then
        beam.world = self._world
        beam.source_unit, beam.source_node = self._fx_extension:vfx_spawner_unit_and_node(BEAM_SOURCE)
        beam.visual = spawn_beam(self._world, BEAM, IMPACT)

        if sounds_loaded then
            local wwise_world = Wwise.wwise_world(self._world)
            local source = WwiseWorld.make_auto_source(wwise_world, beam.source_unit, beam.source_node)

            beam.sound = play_sound(self._world, BEAM_LOOP, source)
        end
    end

    beams[self] = beam
end)

mod:hook_safe("ActionOverloadChargeTargetFinder", "fixed_update", function(self, dt, t)
    local beam = beams[self]

    if not beam then
        return
    end

    if not beam.opened then
        beam.opened = true
        self:trigger_anim_event(OPEN_HAND, OPEN_HAND)
    elseif not beam.held and t - beam.start_t >= HOLD_AFTER then
        beam.held = true
        self:trigger_anim_event(HOLD_HAND, nil)
    end

    if t >= beam.next_tick then
        beam.next_tick = t + TICK_TIME

        local position, unit, actor, normal, direction = aim(self._player_unit, self._physics_world,
            self._first_person_component)

        WarpCharge.increase_immediate(t, 1, self._warp_charge_component, BEAM_PERIL, self._player_unit)
        hit(beam, beam_profile, position, unit, actor, normal, direction)
    end
end)

local function remove_visual(world, visual)
    if visual then
        World.destroy_particles(world, visual.effect)
        World.destroy_particles(world, visual.impact)
    end
end

mod:hook_safe("ActionOverloadChargeTargetFinder", "finish", function(self, reason, data, t)
    local beam = beams[self]

    if not beam then
        return
    end

    beams[self] = nil
    remove_visual(beam.world, beam.visual)

    if beam.sound then
        WwiseWorld.stop_event(Wwise.wwise_world(beam.world), beam.sound)
    end

    if beam.target then
        beam.t = t
        released = beam
    end
end)

-- Release

mod:hook_safe("ActionDummy", "start", function(self, action_settings, t)
    if not action_settings.riftlance_release then
        return
    end

    local beam = released

    released = nil

    if not beam or t - beam.t > 0.1 then
        return
    end

    WarpCharge.increase_immediate(t, 1, self._warp_charge_component, RELEASE_PERIL, self._player_unit)

    local world, physics_world, player_unit = self._world, self._physics_world, self._player_unit
    local now = Managers.time:time("gameplay")
    local flare = {
        end_t = now + FLARE_TIME, origin = beam.origin, source_unit = beam.source_unit, source_node = beam.source_node,
        world = world, physics_world = physics_world, player_unit = player_unit,
        first_person = self._first_person_component, is_server = self._is_server,
    }

    local _, unit, actor, normal, direction = aim(player_unit, physics_world, self._first_person_component)

    hit(flare, flare_profile, beam.target:unbox(), unit, actor, normal, direction)

    if self._is_local_unit then
        flare.visual = spawn_beam(world, FLARE, FLARE_IMPACT)
        closing[#closing + 1] = { unit = self._first_person_unit, start_t = now }
    end

    flares[#flares + 1] = flare

    local origin, target = beam.origin:unbox(), beam.target:unbox()
    local direction, distance = Vector3.direction_length(target - origin)
    local count = math.min(1 + math.floor((beam.t - beam.start_t) / SECONDS_PER_RIFT), MAX_RIFTS)

    for i = 1, count do
        local position = target

        if i > 1 then
            local back = math.random() * math.min(4, distance * 0.5)
            local offset = Vector3(math.random() * 2 - 1, math.random() * 2 - 1, (math.random() * 2 - 1) * 0.5)

            position = target - direction * back + offset * 1.4
        end

        local explode_t = now + FLARE_TIME + RIFT_EXPLODE_AFTER + (i > 1 and math.random() * RIFT_EXPLODE_SPREAD or 0)

        rifts[#rifts + 1] = { open_t = now + (i - 1) * RIFT_OPEN_STAGGER, explode_t = explode_t,
            position = Vector3Box(position), world = world, physics_world = physics_world, player_unit = player_unit,
            is_server = self._is_server, is_local = self._is_local_unit }
    end
end)

local function update_flare(flare, now)
    local origin = hand_position(flare.source_unit, flare.source_node, flare.origin:unbox())
    local target = aim(flare.player_unit, flare.physics_world, flare.first_person)
    local visual = flare.visual

    if visual and World.are_particles_playing(flare.world, visual.effect) then
        place(flare.world, visual, origin, target)
    end
end

-- same order the game uses when it restores animations after a correction
local layer_times, layer_animations, layer_states = {}, {}, {}

local function push_layer_time(unit, layer, seconds)
    local times, count = Unit.animation_get_time(unit, layer_times)

    if not times[layer] then
        return nil
    end

    local animations, animation_count = Unit.animation_get_animation(unit, layer_animations)
    local states, state_count = Unit.animation_get_state(unit, layer_states)

    times[layer] = times[layer] + seconds
    Unit.animation_set_time(unit, unpack(times, 1, count))
    Unit.animation_set_animation(unit, unpack(animations, 1, animation_count))
    Unit.animation_set_state(unit, unpack(states, 1, state_count))

    return times[layer]
end

local function update_closing(dt, now)
    for i = #closing, 1, -1 do
        local close = closing[i]
        local time = now - close.start_t
        local clip_time = nil

        if time >= CLOSE_FROM and time < RELEASE_TIME and Unit.alive(close.unit) then
            clip_time = push_layer_time(close.unit, CLOSE_LAYER, dt * (CLOSE_SPEED - 1))
        end

        if time >= RELEASE_TIME or (clip_time and clip_time >= CLOSE_UNTIL) or not Unit.alive(close.unit) then
            table.remove(closing, i)
        end
    end
end

mod.update = function(dt)
    if not mod:is_enabled() then
        return
    end

    for action, beam in pairs(beams) do
        local visual = beam.visual

        if visual then
            local origin, target = beam_points(action, beam)

            place(beam.world, visual, origin, target)

            -- kept for the release
            if beam.target then
                beam.origin:store(origin)
                beam.target:store(target)
            else
                beam.origin, beam.target = Vector3Box(origin), Vector3Box(target)
            end
        end
    end

    if #flares == 0 and #rifts == 0 and #closing == 0 then
        return
    end

    local now = Managers.time:time("gameplay")

    update_closing(dt, now)

    for i = #flares, 1, -1 do
        local flare = flares[i]

        if now >= flare.end_t then
            table.remove(flares, i)
        else
            update_flare(flare, now)
        end
    end

    for i = #rifts, 1, -1 do
        local rift = rifts[i]

        if not rift.opened and now >= rift.open_t then
            rift.opened = true

            if rift.is_local then
                rift.effect = World.create_particles(rift.world, RIFT, rift.position:unbox())
            end
        end

        if rift.opened and now >= rift.explode_t then
            table.remove(rifts, i)

            if rift.effect and World.are_particles_playing(rift.world, rift.effect) then
                World.destroy_particles(rift.world, rift.effect)
            end

            if rift.is_local then
                play_sound(rift.world, RIFT_SOUNDS[math.random(#RIFT_SOUNDS)], rift.position:unbox())
            end

            if rift.is_server and Unit.alive(rift.player_unit) then
                explode(rift.world, rift.physics_world, rift.position:unbox(), rift.player_unit, rift_explosion)
            end
        end
    end
end

mod.on_game_state_changed = function()
    table.clear(beams)
    table.clear(flares)
    table.clear(rifts)
    table.clear(closing)
    released = nil
end
