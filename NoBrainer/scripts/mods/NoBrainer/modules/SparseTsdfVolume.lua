local M = {}

local math_abs = math.abs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_sqrt = math.sqrt
local tostring = tostring

local function key(ix, iy, iz)
    return tostring(ix) .. ":" .. tostring(iy) .. ":" .. tostring(iz)
end

function M.new(voxel_size, truncation, max_voxels)
    local self = {
        size = math_max(0.02, tonumber(voxel_size) or 0.35),
        mu = math_max(0.02, tonumber(truncation) or 0.70),
        max_voxels = math_max(8, math_floor(tonumber(max_voxels) or 60000)),
        voxels = {},
        voxel_list = {},
        count = 0,
        ray_serial = 0,
    }

    function self:get(ix, iy, iz)
        return self.voxels[key(ix, iy, iz)]
    end

    function self:clear()
        self.voxels = {}
        self.voxel_list = {}
        self.count = 0
        self.ray_serial = 0
    end

    local function update_vertex(ix, iy, iz, signed, nx, ny, nz, weight, ray_id)
        local k = key(ix, iy, iz)
        local v = self.voxels[k]
        if v and v.last_ray == ray_id then return false end
        if not v then
            if self.count >= self.max_voxels then return false end
            v = { ix = ix, iy = iy, iz = iz, d = 0, w = 0, nx = 0, ny = 0, nz = 0 }
            self.voxels[k] = v
            self.count = self.count + 1
            self.voxel_list[self.count] = v
        end
        v.last_ray = ray_id

        local old_w = v.w
        -- stop one repeatedly hit wall from getting effectively infinite confidence
        local add_w = math_min(weight, math_max(0, 32 - old_w))
        if add_w <= 0 then return false end
        local new_w = old_w + add_w
        v.d = (v.d * old_w + signed * add_w) / new_w
        v.nx = (v.nx * old_w + nx * add_w) / new_w
        v.ny = (v.ny * old_w + ny * add_w) / new_w
        v.nz = (v.nz * old_w + nz * add_w) / new_w
        v.w = new_w
        return true
    end

    function self:integrate_ray(ox, oy, oz, dx, dy, dz, hit_distance, nx, ny, nz)
        local distance = tonumber(hit_distance)
        if not distance or distance <= 0 then return false end

        local len = math_sqrt(dx * dx + dy * dy + dz * dz)
        if len <= 1e-9 then return false end
        dx, dy, dz = dx / len, dy / len, dz / len

        local nlen = math_sqrt(nx * nx + ny * ny + nz * nz)
        if nlen <= 1e-9 then
            nx, ny, nz = -dx, -dy, -dz
        else
            nx, ny, nz = nx / nlen, ny / nlen, nz / nlen

            -- keep normals facing back toward the ray source or the tsdf sign flips between hits
            if dx * nx + dy * ny + dz * nz > 0 then
                nx, ny, nz = -nx, -ny, -nz
            end
        end

        local incidence = math_abs(dx * nx + dy * ny + dz * nz)
        local weight = math_max(0.15, incidence)
        local size, mu = self.size, self.mu
        local start_t = math_max(0, distance - mu)
        local end_t = distance + mu
        local step = size * 0.65
        local lateral_limit2 = (size * 0.95) * (size * 0.95)

        self.ray_serial = self.ray_serial + 1
        local ray_id = self.ray_serial
        local changed = false

        -- splat around the actual hit too because the stepping below can hop over voxel corners
        local hx, hy, hz = ox + dx*distance, oy + dy*distance, oz + dz*distance
        local cix = math_floor(hx / size + 0.5)
        local ciy = math_floor(hy / size + 0.5)
        local ciz = math_floor(hz / size + 0.5)
        for ax = cix - 1, cix + 1 do
            local vx = ax * size
            for ay = ciy - 1, ciy + 1 do
                local vy = ay * size
                for az = ciz - 1, ciz + 1 do
                    local vz = az * size
                    local sx, sy, sz = vx-hx, vy-hy, vz-hz
                    local plane_sdf = sx*nx + sy*ny + sz*nz
                    if math_abs(plane_sdf) <= mu then

                        local radial2 = sx*sx + sy*sy + sz*sz - plane_sdf*plane_sdf
                        local support = size * 1.55
                        if radial2 <= support*support then
                            if update_vertex(ax, ay, az, plane_sdf/mu, nx, ny, nz, weight, ray_id) then
                                changed = true
                            end
                        end
                    end
                end
            end
        end

        -- and fill the narrow band along the ray, hit-only splats leave annoying little holes
        local t = start_t
        while t <= end_t + 1e-6 do
            local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
            local ix, iy, iz = math_floor(px / size), math_floor(py / size), math_floor(pz / size)

            for ax = ix, ix + 1 do
                local vx = ax * size
                for ay = iy, iy + 1 do
                    local vy = ay * size
                    for az = iz, iz + 1 do
                        local vz = az * size
                        local rx, ry, rz = vx - ox, vy - oy, vz - oz
                        local projected = rx * dx + ry * dy + rz * dz
                        local lx, ly, lz = rx - projected * dx, ry - projected * dy, rz - projected * dz
                        if lx * lx + ly * ly + lz * lz <= lateral_limit2 then
                            local sdf = distance - projected
                            if math_abs(sdf) <= mu then
                                if update_vertex(ax, ay, az, sdf / mu, nx, ny, nz, weight, ray_id) then
                                    changed = true
                                end
                            end
                        end
                    end
                end
            end
            t = t + step
        end
        return changed
    end

    return self
end

return M
