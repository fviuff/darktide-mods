local mod = get_mod("MourningstarPets")

local NavQueries = require("scripts/utilities/nav_queries")

local ASSET_ID = "MourningstarPets:cat"

-- Follow distances are the arbitrator dog's hub ones (companion_dog_hub_actions)
local CLOSE = 1.2          -- where the cat settles next to you
local LEASH = 2.6          -- starts following past this
local LEASH_RESTING = 4.5  -- sitting/lying cats are lazier
local TELEPORT = 15        -- too far or stuck, pop in behind you
local STUCK_TIME = 1.5
local DOG_SPACE = 1.0

-- Ground speed of each gait clip
local GAITS = {
    walk = { speed = 0.78, up = 4, down = nil },
    jog = { speed = 2.24, up = 7, down = 2.8 },
    run = { speed = 5.65, up = nil, down = 5 },
}
local TURN_SPEED = 8
local FACE_OWNER_SPEED = 2

-- Lengths of the one-shot clips, the state machine holds their last pose
local SIT_DOWN = 6.33
local LIE_DOWN = 1.67
local DOZE_OFF = 4.0

local RESTING = { sit_down = true, sit = true, groom = true, lie_down = true, lie = true, doze_off = true, sleep = true }

local cat_unit_name = nil
local loading = false
local cat = nil

-- Name tag, the hub dog nameplate with a bit of height since the cat has no name node

local NAMEPLATE = table.clone(require("scripts/ui/hud/elements/world_markers/templates/world_marker_template_nameplate_companion_hub"))
NAMEPLATE.name = "nameplate_companion_pet"
NAMEPLATE.unit_node = nil
NAMEPLATE.position_offset = { 0, 0, 0.55 }

local function world_markers()
    local hud = Managers.ui and Managers.ui:get_hud()

    return hud and hud:element("HudElementWorldMarkers")
end

-- The hud gets rebuilt on loads and survives mod reloads, so every frame: make sure the live markers element
-- knows the template and still has the marker, otherwise add it again
local function sync_nameplate()
    local name = mod:get("cat_name")
    local markers = world_markers()

    if not cat or not markers or not name or name == "" then
        return
    end

    if cat.marker_element == markers and markers._markers_by_id[cat.marker_id] then
        return
    end

    local player = cat.player
    local data = {
        companion_name = function() return name end,
        slot = function() return player:slot() end,
        peer_id = function() return player:peer_id() end,
    }
    local owner = cat

    markers._marker_templates[NAMEPLATE.name] = NAMEPLATE
    markers:event_add_world_marker_unit(NAMEPLATE.name, cat.unit, function(id)
        owner.marker_id = id
    end, data)
    cat.marker_element = markers
end

local function remove_nameplate()
    if not cat then
        return
    end

    local markers = world_markers()

    if cat.marker_id and cat.marker_element == markers and markers._markers_by_id[cat.marker_id] then
        markers:event_remove_world_marker(cat.marker_id)
    end

    cat.marker_id = nil
    cat.marker_element = nil
end

-- Loading

local function load_cat()
    if cat_unit_name or loading then
        return
    end

    local custom_assets = get_mod("CustomAssets")

    if not custom_assets or not custom_assets.is_api_compatible(1) then
        mod:error("needs CustomAssets")
        return
    end

    loading = true

    custom_assets.acquire(mod, ASSET_ID, function(_, asset, err)
        loading = false

        if err or not asset or not asset.primary then
            mod:error("cat didnt load (%s), run the CustomAssets patcher", tostring(err))
            return
        end

        cat_unit_name = asset.primary.name
    end)
end

-- Ground and movement (nav mesh like the dog, collision if there is no nav mesh)

local function ground(position)
    if cat.nav_world then
        local on_mesh = NavQueries.position_on_mesh(cat.nav_world, position, 0.6, 0.6, cat.traverse_logic)

        if on_mesh then
            return on_mesh
        end
    end

    local hit, hit_position = PhysicsWorld.raycast(cat.physics_world, position + Vector3(0, 0, 0.6), Vector3.down(), 1.5, "closest", "collision_filter", "filter_minion_mover")

    return hit and hit_position or nil
end

local function try_step(from, to)
    if cat.nav_world then
        local can_go, _, projected = NavQueries.ray_can_go(cat.nav_world, from, to, cat.traverse_logic, 0.6, 0.6)

        if projected then
            return can_go and projected or nil
        end
    end

    local step = to - from
    local length = Vector3.length(step)

    if length > 0.001 and PhysicsWorld.raycast(cat.physics_world, from + Vector3(0, 0, 0.25), step / length, length + 0.15, "any", "collision_filter", "filter_minion_mover") then
        return nil
    end

    return ground(to)
end

local function owner_forward()
    return Vector3.normalize(Vector3.flat(Quaternion.forward(Unit.local_rotation(cat.owner, 1))))
end

local function place(position, rotation)
    cat.position:store(position)
    cat.rotation:store(rotation)
    Unit.set_local_position(cat.unit, 1, position)
    Unit.set_local_rotation(cat.unit, 1, rotation)
end

-- The cat faces its local +X
local function yaw_rotation(direction)
    return Quaternion(Vector3.up(), math.atan2(direction.y, direction.x))
end

local function spot_behind_owner()
    local owner_position = Unit.local_position(cat.owner, 1)
    local forward = owner_forward()

    return ground(owner_position - forward * CLOSE) or owner_position, yaw_rotation(forward)
end

local function turn_towards(direction, speed, dt)
    if Vector3.length_squared(direction) < 0.0001 then
        return cat.rotation:unbox()
    end

    return Quaternion.lerp(cat.rotation:unbox(), yaw_rotation(direction), math.min(speed * dt, 1))
end

-- Animation

local function anim(event)
    if cat.event ~= event then
        cat.event = event
        Unit.animation_event(cat.unit, event)
    end
end

local function set_mood(mood, event, duration)
    cat.mood = mood
    cat.mood_t = duration

    if event then
        anim(event)
    end
end

local function rest_update(dt)
    cat.mood_t = cat.mood_t - dt

    if cat.mood_t > 0 then
        return
    end

    local mood = cat.mood

    if mood == "idle" then
        if math.random() < 0.35 then
            set_mood("look", "look", math.random(6, 9))
        else
            set_mood("sit_down", "sit", SIT_DOWN)
        end
    elseif mood == "look" then
        set_mood("idle", "idle", math.random(4, 8))
    elseif mood == "sit_down" or mood == "groom" then
        set_mood("sit", "sit_idle", math.random(8, 16))
    elseif mood == "sit" then
        if math.random() < 0.4 then
            set_mood("groom", "groom", math.random(6, 12))
        else
            set_mood("lie_down", "lie", LIE_DOWN)
        end
    elseif mood == "lie_down" then
        set_mood("lie", "lie_idle", math.random(15, 30))
    elseif mood == "lie" then
        set_mood("doze_off", "sleep", DOZE_OFF)
    elseif mood == "doze_off" then
        set_mood("sleep", "sleep_idle", math.huge)
    end
end

-- Following

local function the_dog()
    local spawner = ScriptUnit.has_extension(cat.owner, "companion_spawner_system")
    local units = spawner and spawner:companion_units()

    return units and units[1]
end

-- Where to settle: next to you on the side the cat is on, the other side if the dog sits there
local function follow_target(owner_position, position)
    local away = Vector3.flat(position - owner_position)

    if Vector3.length_squared(away) < 0.01 then
        away = -owner_forward()
    end

    local target = owner_position + Vector3.normalize(away) * CLOSE
    local dog = the_dog()

    if dog and Unit.alive(dog) then
        local dog_position = Unit.world_position(dog, 1)

        if Vector3.distance(Vector3.flat(dog_position), Vector3.flat(target)) < DOG_SPACE then
            local to_dog = Vector3.flat(dog_position - owner_position)
            local side = Vector3.cross(to_dog, Vector3.up())

            target = owner_position + Vector3.normalize(side) * CLOSE
        end
    end

    return target
end

local function pick_gait(distance)
    local gait = cat.gait or "walk"
    local settings = GAITS[gait]

    if settings.up and distance > settings.up then
        return gait == "walk" and "jog" or "run"
    elseif settings.down and distance < settings.down then
        return gait == "run" and "jog" or "walk"
    end

    return gait
end

local function follow_update(dt)
    local owner_position = Unit.local_position(cat.owner, 1)
    local position = cat.position:unbox()
    local distance = Vector3.distance(Vector3.flat(owner_position), Vector3.flat(position))

    if distance > TELEPORT or cat.stuck_t > STUCK_TIME then
        local spot, rotation = spot_behind_owner()

        place(spot, rotation)
        cat.stuck_t = 0
        cat.gait = nil
        set_mood("idle", "idle", math.random(5, 10))

        return
    end

    local leash = RESTING[cat.mood] and LEASH_RESTING or LEASH

    if cat.mood ~= "follow" then
        if distance <= leash then
            if cat.mood == "idle" then
                place(position, turn_towards(Vector3.flat(owner_position - position), FACE_OWNER_SPEED, dt))
            end

            rest_update(dt)

            return
        end

        cat.mood = "follow"
    end

    local target = follow_target(owner_position, position)
    local to_target = Vector3.flat(target - position)
    local remaining = Vector3.length(to_target)

    if distance <= CLOSE + 0.1 or remaining < 0.15 then
        cat.gait = nil
        set_mood("idle", "idle", math.random(5, 10))

        return
    end

    cat.gait = pick_gait(distance)
    anim(cat.gait)

    local direction = to_target / remaining
    local step = math.min(GAITS[cat.gait].speed * dt, remaining)
    local moved = try_step(position, position + direction * step)

    if moved then
        cat.stuck_t = 0
        place(moved, turn_towards(direction, TURN_SPEED, dt))
    else
        cat.stuck_t = cat.stuck_t + dt
    end
end

-- Spawning

local function in_mourningstar()
    local game_mode = Managers.state.game_mode

    return game_mode ~= nil and game_mode:game_mode_name() == "hub"
end

local function despawn()
    if not cat then
        return
    end

    remove_nameplate()

    if Unit.alive(cat.unit) then
        local position_lookup = Managers.state.position_lookup

        if position_lookup then
            position_lookup:unregister(cat.unit)
        end

        World.destroy_unit(cat.world, cat.unit)
    end

    cat = nil
end

local function spawn(player)
    local owner = player.player_unit
    local world = Unit.world(owner)
    local nav_mesh = Managers.state.nav_mesh

    cat = {
        player = player,
        owner = owner,
        world = world,
        physics_world = World.physics_world(world),
        nav_world = nav_mesh and nav_mesh:nav_world(),
        traverse_logic = nav_mesh and nav_mesh:client_traverse_logic(),
        position = Vector3Box(),
        rotation = QuaternionBox(),
        stuck_t = 0,
    }

    local position, rotation = spot_behind_owner()

    cat.unit = World.spawn_unit_ex(world, cat_unit_name, nil, position, rotation)
    place(position, rotation)

    -- lets the hud track it like any other unit
    Managers.state.position_lookup:register(cat.unit, position)

    Unit.enable_animation_state_machine(cat.unit)
    cat.event = "idle"
    set_mood("idle", nil, math.random(5, 10))
end

-- Callbacks

mod.update = function(dt)
    -- dmf keeps calling update for a disabled mod
    if not mod:is_enabled() then
        return
    end

    if not cat_unit_name then
        load_cat()
        return
    end

    if cat and not (Unit.alive(cat.owner) and Unit.alive(cat.unit)) then
        despawn()
    end

    if not cat then
        local player = Managers.player and Managers.player:local_player_safe(1)
        local owner = player and player.player_unit

        if owner and Unit.alive(owner) and in_mourningstar() then
            spawn(player)
        end

        return
    end

    follow_update(dt)
    sync_nameplate()
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "cat_name" then
        remove_nameplate()
    end
end

mod.on_disabled = despawn

mod.on_game_state_changed = function(status, state_name)
    if status == "exit" and state_name == "StateGameplay" then
        despawn()
    end
end

mod.on_unload = function()
    despawn()

    local custom_assets = get_mod("CustomAssets")

    if custom_assets then
        custom_assets.release_owner(mod)
    end
end
