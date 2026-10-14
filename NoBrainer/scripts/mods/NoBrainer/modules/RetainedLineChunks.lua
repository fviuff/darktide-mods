local M = {}

local pcall = pcall
local rawget = rawget
local math_floor = math.floor
local math_max = math.max
local World_create_line_object = World.create_line_object
local World_destroy_line_object = World.destroy_line_object
local LineObject_add_line = LineObject.add_line
local LineObject_reset = LineObject.reset
local LineObject_dispatch = LineObject.dispatch
local Vector3_new = rawget(_G, "Vector3")
local Color_new = rawget(_G, "Color")

local DEFAULT_LINE_DURATION = 5000

function M.new(lines_per_chunk, line_duration)
    local self = {
        lines_per_chunk = math_max(32, math_floor(lines_per_chunk or 512)),
        line_duration = math_max(1, tonumber(line_duration) or DEFAULT_LINE_DURATION),
        world = nil,
        objects = {},
        counts = {},
        dirty_from = nil,
        total_lines = 0,
    }

    local function current_world()
        local manager = Managers.world
        if not manager or not manager.world then return nil end
        local ok, world = pcall(manager.world, manager, "level_world")
        return ok and world or nil
    end

    function self:destroy()
        if self.world then
            for i = 1, #self.objects do
                local lo = self.objects[i]
                if lo then
                    pcall(LineObject_reset, lo)
                    pcall(LineObject_dispatch, self.world, lo)
                    if World_destroy_line_object then
                        pcall(World_destroy_line_object, self.world, lo)
                    end
                end
            end
        end
        self.objects = {}
        self.counts = {}
        self.world = nil
        self.dirty_from = nil
        self.total_lines = 0
    end

    function self:clear()
        self:destroy()
    end

    local function acquire_chunk(world)
        local index = #self.objects
        if index == 0 or (self.counts[index] or 0) >= self.lines_per_chunk then
            local ok, lo = pcall(World_create_line_object, world)
            if not ok or not lo then return nil end
            index = index + 1
            self.objects[index] = lo
            self.counts[index] = 0
        end
        return index
    end

    local function add_engine_line(color, a, b, duration)
        local world = current_world()
        if not world then return false end
        if self.world and self.world ~= world then self:destroy() end
        self.world = world

        local index = acquire_chunk(world)
        if not index then return false end

        LineObject_add_line(self.objects[index], color, a, b, duration or self.line_duration)
        self.counts[index] = self.counts[index] + 1
        self.total_lines = self.total_lines + 1
        if not self.dirty_from or index < self.dirty_from then self.dirty_from = index end
        return true
    end

    function self:add_line_rgb_xyz(r, g, b, ax, ay, az, bx, by, bz, duration)
        if not Color_new or not Vector3_new then return false end
        return add_engine_line(
            Color_new(r, g, b),
            Vector3_new(ax, ay, az),
            Vector3_new(bx, by, bz),
            duration
        )
    end

    function self:dispatch()
        if not self.world or not self.dirty_from then return false end
        local first = self.dirty_from
        local failed_from = nil
        self.dirty_from = nil
        for i = first, #self.objects do
            local lo = self.objects[i]
            if lo then
                local ok = pcall(LineObject_dispatch, self.world, lo)
                if not ok and not failed_from then failed_from = i end
            end
        end

        if failed_from then self.dirty_from = failed_from end
        return failed_from == nil
    end

    function self:has_pending_dispatch()
        return self.dirty_from ~= nil
    end

    function self:line_count()
        return self.total_lines
    end

    return self
end

return M
