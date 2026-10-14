-- MIT lua-vector adaptation

local M = {}

local math_abs = math.abs
local math_acos = math.acos
local math_atan = math.atan
local math_cos = math.cos
local math_max = math.max
local math_min = math.min
local math_sin = math.sin
local math_sqrt = math.sqrt
local math_pi = math.pi
local pcall = pcall
local rawget = rawget
local setmetatable = setmetatable
local tostring = tostring
local type = type

local EPS = 1e-12
M.EPSILON = EPS

-- atan2 fallback
local math_atan2 = math.atan2 or function(y, x)
    if x > 0 then return math_atan(y / x) end
    if x < 0 then return math_atan(y / x) + (y >= 0 and math_pi or -math_pi) end
    if y > 0 then return math_pi * 0.5 end
    if y < 0 then return -math_pi * 0.5 end
    return 0
end

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end
M.clamp = clamp

function M.lerp(a, b, t)
    return a + (b - a) * t
end

function M.smoothstep(a, b, x)
    if a == b then return x < a and 0 or 1 end
    local t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
end

function M.is_finite(x)
    return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

function M.is_finite3(x, y, z)
    return M.is_finite(x) and M.is_finite(y) and M.is_finite(z)
end

-- vec3
function M.length_squared(x, y, z)
    return x * x + y * y + z * z
end

function M.length(x, y, z)
    return math_sqrt(x * x + y * y + z * z)
end

function M.normalize(x, y, z, epsilon)
    local len2 = x * x + y * y + z * z
    if len2 <= (epsilon or EPS) then return nil end
    local inv = 1 / math_sqrt(len2)
    return x * inv, y * inv, z * inv
end

function M.dot(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

function M.cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx
end

function M.add(ax, ay, az, bx, by, bz)
    return ax + bx, ay + by, az + bz
end

function M.subtract(ax, ay, az, bx, by, bz)
    return ax - bx, ay - by, az - bz
end

function M.scale(x, y, z, s)
    return x * s, y * s, z * s
end

function M.squared_distance(ax, ay, az, bx, by, bz)
    local dx = ax - bx
    local dy = ay - by
    local dz = az - bz
    return dx * dx + dy * dy + dz * dz
end

function M.distance(ax, ay, az, bx, by, bz)
    return math_sqrt(M.squared_distance(ax, ay, az, bx, by, bz))
end

function M.lerp3(ax, ay, az, bx, by, bz, t)
    return ax + (bx - ax) * t,
        ay + (by - ay) * t,
        az + (bz - az) * t
end

function M.project(vx, vy, vz, nx, ny, nz)
    local d = vx * nx + vy * ny + vz * nz
    return nx * d, ny * d, nz * d
end

function M.reject(vx, vy, vz, nx, ny, nz)
    local d = vx * nx + vy * ny + vz * nz
    return vx - nx * d, vy - ny * d, vz - nz * d
end

function M.reflect(vx, vy, vz, nx, ny, nz)
    local d2 = 2 * (vx * nx + vy * ny + vz * nz)
    return vx - nx * d2, vy - ny * d2, vz - nz * d2
end

function M.tangent_basis(nx, ny, nz, epsilon)
    local rx, ry, rz
    if math_abs(nz) < 0.85 then
        rx, ry, rz = 0, 0, 1
    else
        rx, ry, rz = 1, 0, 0
    end

    local t1x, t1y, t1z = M.cross(nx, ny, nz, rx, ry, rz)
    t1x, t1y, t1z = M.normalize(t1x, t1y, t1z, epsilon)
    if not t1x then return 1, 0, 0, 0, 1, 0 end

    local t2x, t2y, t2z = M.cross(nx, ny, nz, t1x, t1y, t1z)
    t2x, t2y, t2z = M.normalize(t2x, t2y, t2z, epsilon)
    return t1x, t1y, t1z, t2x, t2y, t2z
end

function M.clean_tangent(dx, dy, dz, nx, ny, nz, epsilon)
    local dn = M.dot(dx, dy, dz, nx, ny, nz)
    return M.normalize(dx - nx * dn, dy - ny * dn, dz - nz * dn, epsilon)
end

-- Rodrigues transport
function M.transport_direction(dx, dy, dz, n1x, n1y, n1z, n2x, n2y, n2z, epsilon)
    local ax, ay, az = M.cross(n1x, n1y, n1z, n2x, n2y, n2z)
    local s2 = ax * ax + ay * ay + az * az
    local c = math_max(-1, math_min(1, M.dot(n1x, n1y, n1z, n2x, n2y, n2z)))
    local rx, ry, rz = dx, dy, dz

    if s2 > (epsilon or EPS) then
        local s = math_sqrt(s2)
        ax, ay, az = ax / s, ay / s, az / s
        local cx, cy, cz = M.cross(ax, ay, az, dx, dy, dz)
        local ad = M.dot(ax, ay, az, dx, dy, dz)
        rx = dx * c + cx * s + ax * ad * (1 - c)
        ry = dy * c + cy * s + ay * ad * (1 - c)
        rz = dz * c + cz * s + az * ad * (1 - c)
    end

    rx, ry, rz = M.clean_tangent(rx, ry, rz, n2x, n2y, n2z, epsilon)
    if rx then return rx, ry, rz end

    local t1x, t1y, t1z, t2x, t2y, t2z = M.tangent_basis(n2x, n2y, n2z, epsilon)
    local d1 = M.dot(dx, dy, dz, t1x, t1y, t1z)
    local d2 = M.dot(dx, dy, dz, t2x, t2y, t2z)
    if math_abs(d2) > math_abs(d1) then
        if d2 < 0 then t2x, t2y, t2z = -t2x, -t2y, -t2z end
        return t2x, t2y, t2z
    end
    if d1 < 0 then t1x, t1y, t1z = -t1x, -t1y, -t1z end
    return t1x, t1y, t1z
end

-- quaternions
function M.quat_identity()
    return 0, 0, 0, 1
end

function M.quat_normalize(x, y, z, w)
    local len2 = x*x + y*y + z*z + w*w
    if len2 <= EPS then return 0, 0, 0, 1 end
    local inv = 1 / math_sqrt(len2)
    return x*inv, y*inv, z*inv, w*inv
end

function M.quat_mul(ax, ay, az, aw, bx, by, bz, bw)
    return aw*bx + ax*bw + ay*bz - az*by,
        aw*by - ax*bz + ay*bw + az*bx,
        aw*bz + ax*by - ay*bx + az*bw,
        aw*bw - ax*bx - ay*by - az*bz
end

function M.quat_axis_angle(ax, ay, az, angle)
    ax, ay, az = M.normalize(ax, ay, az)
    if not ax then return 0, 0, 0, 1 end
    local half = angle * 0.5
    local s = math_sin(half)
    return ax*s, ay*s, az*s, math_cos(half)
end

function M.quat_rotate(qx, qy, qz, qw, vx, vy, vz)
    local tx = 2 * (qy*vz - qz*vy)
    local ty = 2 * (qz*vx - qx*vz)
    local tz = 2 * (qx*vy - qy*vx)
    return vx + qw*tx + qy*tz - qz*ty,
        vy + qw*ty + qz*tx - qx*tz,
        vz + qw*tz + qx*ty - qy*tx
end

function M.quat_slerp(ax, ay, az, aw, bx, by, bz, bw, t)
    local d = ax*bx + ay*by + az*bz + aw*bw
    if d < 0 then
        bx, by, bz, bw = -bx, -by, -bz, -bw
        d = -d
    end
    if d > 0.9995 then
        return M.quat_normalize(
            ax + (bx-ax)*t,
            ay + (by-ay)*t,
            az + (bz-az)*t,
            aw + (bw-aw)*t
        )
    end
    d = clamp(d, -1, 1)
    local theta = math_acos(d)
    local s = math_sin(theta)
    if math_abs(s) <= EPS then return ax, ay, az, aw end
    local wa = math_sin((1-t)*theta) / s
    local wb = math_sin(t*theta) / s
    return ax*wa + bx*wb, ay*wa + by*wb, az*wa + bz*wb, aw*wa + bw*wb
end

-- vector/matrix API
local vector_methods = {}
vector_methods.__index = vector_methods
local Matrix, Vector

function vector_methods:scale(k)
    return Vector(self.x*k, self.y*k, self.z*k)
end
function vector_methods:dot(b) return self.x*b.x + self.y*b.y + self.z*b.z end
function vector_methods:cross(b)
    return Vector(self.y*b.z-self.z*b.y, self.z*b.x-self.x*b.z, self.x*b.y-self.y*b.x)
end
function vector_methods:azimuth() return math_atan2(self.y, self.x) end
function vector_methods:add(b) return Vector(self.x+b.x, self.y+b.y, self.z+b.z) end
function vector_methods:length() return math_sqrt(self.x*self.x+self.y*self.y+self.z*self.z) end
function vector_methods:length_squared() return self.x*self.x+self.y*self.y+self.z*self.z end
function vector_methods:transform(m)
    return Vector(
        m[1][1]*self.x+m[1][2]*self.y+m[1][3]*self.z+m[1][4],
        m[2][1]*self.x+m[2][2]*self.y+m[2][3]*self.z+m[2][4],
        m[3][1]*self.x+m[3][2]*self.y+m[3][3]*self.z+m[3][4]
    )
end
function vector_methods:rotate(angle)
    local c, s = math_cos(angle), math_sin(angle)
    return Vector(self.x*c-self.y*s, self.x*s+self.y*c, self.z)
end
function vector_methods:rotateX(angle)
    local c, s = math_cos(angle), math_sin(angle)
    return Vector(self.x, self.y*c-self.z*s, self.y*s+self.z*c)
end
function vector_methods:rotateY(angle)
    local c, s = math_cos(angle), math_sin(angle)
    return Vector(self.x*c+self.z*s, self.y, -self.x*s+self.z*c)
end
vector_methods.rotateZ = vector_methods.rotate
function vector_methods:angleBetween(other)
    local den = self:length() * other:length()
    if den <= EPS then return 0 end
    return math_acos(clamp(self:dot(other)/den, -1, 1))
end
function vector_methods:unitVector()
    local l = self:length()
    if l <= EPS then return Vector(0,0,0) end
    return self:scale(1/l)
end
function vector_methods:lerp(other, t)
    return Vector(
        self.x + (other.x-self.x)*t,
        self.y + (other.y-self.y)*t,
        self.z + (other.z-self.z)*t
    )
end
function vector_methods.__mul(a,b)
    if type(a)=="number" then return b:scale(a) end
    if type(b)=="number" then return a:scale(b) end
    return nil
end
function vector_methods.__div(a,b)
    if type(b)=="number" then return a:scale(1/b) end
    return nil
end
function vector_methods.__add(a,b)
    if getmetatable(a)==vector_methods and getmetatable(b)==vector_methods then return a:add(b) end
end
function vector_methods.__unm(v) return v:scale(-1) end
function vector_methods.__sub(a,b)
    if getmetatable(a)==vector_methods and getmetatable(b)==vector_methods then return a:add(-b) end
end
function vector_methods.__eq(a,b) return a.x==b.x and a.y==b.y and a.z==b.z end
function vector_methods.__tostring(v) return "("..v.x..", "..v.y..", "..v.z..")" end
function vector_methods.__concat(a,b) return tostring(a)..tostring(b) end

Vector = function(x,y,z)
    return setmetatable({x=x or 0,y=y or 0,z=z or 0}, vector_methods)
end
M.Vector = Vector
M.P = Vector

local matrix_methods = {}
matrix_methods.__index = matrix_methods
function matrix_methods.__mul(a,b)
    if type(a)=="number" then return b:scale(a) end
    if type(b)=="number" then return a:scale(b) end
    local m={{0,0,0,0},{0,0,0,0},{0,0,0,0},{0,0,0,0}}
    for i=1,4 do
        for j=1,4 do
            local sum=0
            for k=1,4 do sum=sum+a[i][k]*b[k][j] end
            m[i][j]=sum
        end
    end
    return Matrix(m)
end
function matrix_methods:scale(k)
    return Matrix{{k,0,0,0},{0,k,0,0},{0,0,k,0},{0,0,0,1}}*self
end
function matrix_methods:translate(v)
    return Matrix{{1,0,0,v.x or 0},{0,1,0,v.y or 0},{0,0,1,v.z or 0},{0,0,0,1}}*self
end
function matrix_methods:rotateX(angle)
    local s,c=math_sin(angle),math_cos(angle)
    return Matrix{{1,0,0,0},{0,c,-s,0},{0,s,c,0},{0,0,0,1}}*self
end
function matrix_methods:rotateY(angle)
    local s,c=math_sin(angle),math_cos(angle)
    return Matrix{{c,0,s,0},{0,1,0,0},{-s,0,c,0},{0,0,0,1}}*self
end
function matrix_methods:rotateZ(angle)
    local s,c=math_sin(angle),math_cos(angle)
    return Matrix{{c,-s,0,0},{s,c,0,0},{0,0,1,0},{0,0,0,1}}*self
end
function matrix_methods:rotate(angles)
    if type(angles)=="number" then return self:rotateZ(angles) end
    local m=self
    for i=1,#angles.axis do
        local axis=string.sub(angles.axis,i,i)
        local a=angles[i]
        if axis=="x" then m=m:rotateX(a)
        elseif axis=="y" then m=m:rotateY(a)
        elseif axis=="z" then m=m:rotateZ(a) end
    end
    return m
end
Matrix = function(m)
    return setmetatable(m or {{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,0,0,1}}, matrix_methods)
end
M.Matrix = Matrix

function M.Polar(r,angle)
    return Vector(math_cos(angle)*r, math_sin(angle)*r, 0)
end
function M.Spherical(r,right_ascension,declination)
    return Vector(
        r*math_cos(declination)*math_cos(right_ascension),
        r*math_cos(declination)*math_sin(right_ascension),
        r*math_sin(declination)
    )
end

-- Stingray boundary
local engine_vector3 = rawget(_G, "Vector3")
local engine_to_elements = engine_vector3 and engine_vector3.to_elements

function M.to_engine(x, y, z)
    if not engine_vector3 then return nil end
    local ok, v = pcall(engine_vector3, x, y, z)
    return ok and v or nil
end

function M.from_engine(v)
    if not v or not engine_to_elements then return nil end
    local ok, x, y, z = pcall(engine_to_elements, v)
    if not ok or not M.is_finite3(x, y, z) then return nil end
    return x, y, z
end

return M
