local M = {}

local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local math_sqrt = math.sqrt
local tostring = tostring

local CORNERS = {
    {0,0,0}, {1,0,0}, {0,1,0}, {1,1,0},
    {0,0,1}, {1,0,1}, {0,1,1}, {1,1,1},
}
local EDGES = {
    {1,2}, {3,4}, {5,6}, {7,8},
    {1,3}, {2,4}, {5,7}, {6,8},
    {1,5}, {2,6}, {3,7}, {4,8},
}

local function cell_key(ix, iy, iz)
    return tostring(ix) .. ":" .. tostring(iy) .. ":" .. tostring(iz)
end

local function normalize(x, y, z)
    local l2 = x*x + y*y + z*z
    if l2 <= 1e-12 then return nil end
    local inv = 1 / math_sqrt(l2)
    return x*inv, y*inv, z*inv
end

local function signs_differ(a, b)
    return (a.d < 0 and b.d >= 0) or (b.d < 0 and a.d >= 0)
end

function M.new(volume)
    local self = {
        volume = volume,
        phase = "candidates",
        voxel_index = 1,
        candidate_seen = {},
        candidate_x = {}, candidate_y = {}, candidate_z = {},
        candidate_count = 0,
        candidate_index = 1,
        cell_vx = {}, cell_vy = {}, cell_vz = {},
        corner_values = {},
        face_voxel_index = 1,
        line_seen = {},
        segment_ax = {}, segment_ay = {}, segment_az = {},
        segment_bx = {}, segment_by = {}, segment_bz = {},
        segment_count = 0,
        segment_index = 1,
        done = false,
    }

    local function add_candidate(ix, iy, iz)
        local k = cell_key(ix, iy, iz)
        if self.candidate_seen[k] then return end
        self.candidate_seen[k] = true
        local n = self.candidate_count + 1
        self.candidate_count = n
        self.candidate_x[n], self.candidate_y[n], self.candidate_z[n] = ix, iy, iz
    end

    -- only cells touching a sign-changing grid edge can possibly need a dual vertex
    local function add_incident_cells(axis, ix, iy, iz)
        if axis == 1 then
            for dy = -1, 0 do for dz = -1, 0 do add_candidate(ix, iy + dy, iz + dz) end end
        elseif axis == 2 then
            for dx = -1, 0 do for dz = -1, 0 do add_candidate(ix + dx, iy, iz + dz) end end
        else
            for dx = -1, 0 do for dy = -1, 0 do add_candidate(ix + dx, iy + dy, iz) end end
        end
    end

    local function build_cell(ix, iy, iz)
        local size = volume.size
        local values = self.corner_values
        local has_neg, has_pos, all_observed = false, false, true
        for i = 1, 8 do
            local o = CORNERS[i]
            local v = volume:get(ix + o[1], iy + o[2], iz + o[3])
            if v and v.w > 0 then
                values[i] = v
                if v.d < 0 then has_neg = true else has_pos = true end
            else
                values[i] = false
                all_observed = false
            end
        end

        if not (has_neg and has_pos) then return end

        local ox, oy, oz = ix * size, iy * size, iz * size

        -- trilinear gradient is nicer than fused normals but only safe when all 8 corners exist
        local function field_gradient(x, y, z)
            if not all_observed then return nil end
            local x0, y0, z0 = 1-x, 1-y, 1-z
            local d000,d100,d010,d110 = values[1].d,values[2].d,values[3].d,values[4].d
            local d001,d101,d011,d111 = values[5].d,values[6].d,values[7].d,values[8].d
            local gx = y0*z0*(d100-d000) + y*z0*(d110-d010)
                + y0*z*(d101-d001) + y*z*(d111-d011)
            local gy = x0*z0*(d010-d000) + x*z0*(d110-d100)
                + x0*z*(d011-d001) + x*z*(d111-d101)
            local gz = x0*y0*(d001-d000) + x*y0*(d101-d100)
                + x0*y*(d011-d010) + x*y*(d111-d110)
            return normalize(gx, gy, gz)
        end

        local r00,r01,r02,r03 = 0,0,0,0
        local r11,r12,r13 = 0,0,0
        local r22,r23 = 0,0
        local mx,my,mz,count = 0,0,0,0

        -- tiny inline qr accumulator, avoids carrying a whole matrix object per cell
        local function add_qef_row(a0, a1, a2, b)
            local rr = math_sqrt(r00*r00 + a0*a0)
            if rr > 1e-15 then
                local c, sg = r00/rr, a0/rr
                r00 = rr
                local n01 = c*r01 + sg*a1
                local n02 = c*r02 + sg*a2
                local n03 = c*r03 + sg*b
                a1 = -sg*r01 + c*a1
                a2 = -sg*r02 + c*a2
                b = -sg*r03 + c*b
                r01,r02,r03 = n01,n02,n03
            end

            rr = math_sqrt(r11*r11 + a1*a1)
            if rr > 1e-15 then
                local c, sg = r11/rr, a1/rr
                r11 = rr
                local n12 = c*r12 + sg*a2
                local n13 = c*r13 + sg*b
                a2 = -sg*r12 + c*a2
                b = -sg*r13 + c*b
                r12,r13 = n12,n13
            end

            rr = math_sqrt(r22*r22 + a2*a2)
            if rr > 1e-15 then
                local c, sg = r22/rr, a2/rr
                r22 = rr
                r23 = c*r23 + sg*b
            end
        end

        for ei = 1, #EDGES do
            local edge = EDGES[ei]
            local va, vb = values[edge[1]], values[edge[2]]
            if va and vb and signs_differ(va, vb) then
                local ca, cb = CORNERS[edge[1]], CORNERS[edge[2]]
                local denom = va.d - vb.d
                local t = math_abs(denom) > 1e-12 and (va.d / denom) or 0.5
                t = math_max(0, math_min(1, t))
                local lx = ca[1] + (cb[1] - ca[1]) * t
                local ly = ca[2] + (cb[2] - ca[2]) * t
                local lz = ca[3] + (cb[3] - ca[3]) * t
                local px, py, pz = lx * size, ly * size, lz * size
                local nx = va.nx + (vb.nx - va.nx) * t
                local ny = va.ny + (vb.ny - va.ny) * t
                local nz = va.nz + (vb.nz - va.nz) * t
                nx, ny, nz = normalize(nx, ny, nz)
                if not nx then nx, ny, nz = field_gradient(lx, ly, lz) end
                if nx then
                    local rhs = nx*px + ny*py + nz*pz
                    add_qef_row(nx, ny, nz, rhs)
                    mx, my, mz, count = mx + px, my + py, mz + pz, count + 1
                end
            end
        end
        if count == 0 then return end
        mx, my, mz = mx/count, my/count, mz/count

        -- weak pull toward the mean crossing point so flat/underconstrained cells dont shoot off
        local anchor = math_sqrt(1e-3 * count)
        add_qef_row(anchor, 0, 0, anchor*mx)
        add_qef_row(0, anchor, 0, anchor*my)
        add_qef_row(0, 0, anchor, anchor*mz)

        local x,y,z
        if math_abs(r00) > 1e-12 and math_abs(r11) > 1e-12 and math_abs(r22) > 1e-12 then
            z = r23 / r22
            y = (r13 - r12*z) / r11
            x = (r03 - r01*y - r02*z) / r00
        else
            x,y,z = mx,my,mz
        end
        -- not pure qef anymore but keeping the point inside its own cell prevents giant spikes
        x, y, z = math_max(0, math_min(size, x)), math_max(0, math_min(size, y)), math_max(0, math_min(size, z))
        local ck = cell_key(ix,iy,iz)
        self.cell_vx[ck], self.cell_vy[ck], self.cell_vz[ck] = ox+x, oy+y, oz+z
    end

    local function add_segment(k1, k2)
        local ax, ay, az = self.cell_vx[k1], self.cell_vy[k1], self.cell_vz[k1]
        local bx, by, bz = self.cell_vx[k2], self.cell_vy[k2], self.cell_vz[k2]
        if ax == nil or bx == nil then return end
        local lk = k1 < k2 and (k1 .. "|" .. k2) or (k2 .. "|" .. k1)
        if self.line_seen[lk] then return end
        self.line_seen[lk] = true
        local n = self.segment_count + 1
        self.segment_count = n
        self.segment_ax[n], self.segment_ay[n], self.segment_az[n] = ax, ay, az
        self.segment_bx[n], self.segment_by[n], self.segment_bz[n] = bx, by, bz
    end

    local function emit_quad(axis, ix, iy, iz)
        local k1,k2,k3,k4
        if axis == 1 then
            k1=cell_key(ix,iy-1,iz-1); k2=cell_key(ix,iy,iz-1)
            k3=cell_key(ix,iy,iz);     k4=cell_key(ix,iy-1,iz)
        elseif axis == 2 then
            k1=cell_key(ix-1,iy,iz-1); k2=cell_key(ix,iy,iz-1)
            k3=cell_key(ix,iy,iz);     k4=cell_key(ix-1,iy,iz)
        else
            k1=cell_key(ix-1,iy-1,iz); k2=cell_key(ix,iy-1,iz)
            k3=cell_key(ix,iy,iz);     k4=cell_key(ix-1,iy,iz)
        end

        local ks={k1,k2,k3,k4}
        for qi=1,4 do
            local qa=ks[qi]
            local qb=ks[qi==4 and 1 or qi+1]
            if self.cell_vx[qa] ~= nil and self.cell_vx[qb] ~= nil then add_segment(qa,qb) end
        end
    end

    function self:step(max_items)
        if self.done then return 0 end
        local budget = math_max(1, math.floor(max_items or 1))
        local used = 0
        local list = volume.voxel_list

        if self.phase == "candidates" then
            while self.voxel_index <= #list and used < budget do
                local v = list[self.voxel_index]
                self.voxel_index = self.voxel_index + 1
                if v then
                    local nx = volume:get(v.ix+1,v.iy,v.iz)
                    local ny = volume:get(v.ix,v.iy+1,v.iz)
                    local nz = volume:get(v.ix,v.iy,v.iz+1)
                    if nx and signs_differ(v,nx) then add_incident_cells(1,v.ix,v.iy,v.iz) end
                    if ny and signs_differ(v,ny) then add_incident_cells(2,v.ix,v.iy,v.iz) end
                    if nz and signs_differ(v,nz) then add_incident_cells(3,v.ix,v.iy,v.iz) end
                end
                used = used + 1
            end
            if self.voxel_index > #list then self.phase = "cells" end
        end

        if self.phase == "cells" then
            while self.candidate_index <= self.candidate_count and used < budget do
                local i = self.candidate_index
                self.candidate_index = i + 1
                build_cell(self.candidate_x[i], self.candidate_y[i], self.candidate_z[i])
                used = used + 1
            end
            if self.candidate_index > self.candidate_count then

                self.candidate_seen = {}
                self.candidate_x, self.candidate_y, self.candidate_z = {}, {}, {}
                self.phase = "faces"
            end
        end

        if self.phase == "faces" then
            while self.face_voxel_index <= #list and used < budget do
                local v = list[self.face_voxel_index]
                self.face_voxel_index = self.face_voxel_index + 1
                if v then
                    local nx = volume:get(v.ix+1,v.iy,v.iz)
                    local ny = volume:get(v.ix,v.iy+1,v.iz)
                    local nz = volume:get(v.ix,v.iy,v.iz+1)
                    if nx and signs_differ(v,nx) then emit_quad(1,v.ix,v.iy,v.iz) end
                    if ny and signs_differ(v,ny) then emit_quad(2,v.ix,v.iy,v.iz) end
                    if nz and signs_differ(v,nz) then emit_quad(3,v.ix,v.iy,v.iz) end
                end
                used = used + 1
            end
            if self.face_voxel_index > #list then
                self.phase = "done"
                self.done = true
                self.line_seen = {}
            end
        end
        return used
    end

    function self:is_done() return self.done end

    function self:next_segment()
        if self.segment_index > self.segment_count then return nil end
        local i = self.segment_index
        local ax, ay, az = self.segment_ax[i], self.segment_ay[i], self.segment_az[i]
        local bx, by, bz = self.segment_bx[i], self.segment_by[i], self.segment_bz[i]
        self.segment_ax[i], self.segment_ay[i], self.segment_az[i] = nil, nil, nil
        self.segment_bx[i], self.segment_by[i], self.segment_bz[i] = nil, nil, nil

        if i >= self.segment_count then

            self.segment_ax, self.segment_ay, self.segment_az = {}, {}, {}
            self.segment_bx, self.segment_by, self.segment_bz = {}, {}, {}
            self.segment_count, self.segment_index = 0, 1
        else
            self.segment_index = i + 1
        end
        return ax, ay, az, bx, by, bz
    end

    function self:segments_remaining()
        return math_max(0, self.segment_count - self.segment_index + 1)
    end

    function self:clear()
        self.candidate_seen = {}; self.candidate_x = {}; self.candidate_y = {}; self.candidate_z = {}
        self.cell_vx = {}; self.cell_vy = {}; self.cell_vz = {}; self.corner_values = {}; self.line_seen = {}
        self.segment_ax = {}; self.segment_ay = {}; self.segment_az = {}
        self.segment_bx = {}; self.segment_by = {}; self.segment_bz = {}
        self.done = true
    end

    return self
end

return M
