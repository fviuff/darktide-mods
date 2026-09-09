local M = {}

local pcall = pcall
local World_create_line_object = World.create_line_object
local World_destroy_line_object = World.destroy_line_object
local LineObject_reset = LineObject.reset
local LineObject_dispatch = LineObject.dispatch

function M.new()
    local owner = {
        object = nil,
        world = nil,
    }

    function owner:get()
        local manager = Managers.world
        if not manager or not manager.world then return nil, nil end
        local ok_world, world = pcall(manager.world, manager, "level_world")
        if not ok_world or not world then return nil, nil end

        if self.world and self.world ~= world then
            self:destroy()
        end

        if not self.object then
            local ok_object, object = pcall(World_create_line_object, world)
            if not ok_object or not object then return nil, nil end
            self.object = object
            self.world = world
        end

        return self.object, world
    end

    function owner:clear()
        if self.object and self.world then
            pcall(LineObject_reset, self.object)
            pcall(LineObject_dispatch, self.world, self.object)
        end
    end

    function owner:destroy()
        if self.object and self.world then
            pcall(LineObject_reset, self.object)
            pcall(LineObject_dispatch, self.world, self.object)
            if World_destroy_line_object then
                pcall(World_destroy_line_object, self.world, self.object)
            end
        end
        self.object = nil
        self.world = nil
    end

    return owner
end

return M
