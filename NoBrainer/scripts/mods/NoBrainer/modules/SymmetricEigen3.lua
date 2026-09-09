local M = {}

local abs, sqrt = math.abs, math.sqrt

local function normalize(x, y, z)
    local n2 = x*x + y*y + z*z
    if n2 <= 1e-30 then return 1,0,0 end
    local inv = 1 / sqrt(n2)
    return x*inv, y*inv, z*inv
end

function M.solve(a00, a01, a02, a11, a12, a22)

    -- jacobi is a bit brute force for 3x3 but its tiny and behaves well on nearly flat neighborhoods

    local m00,m01,m02,m11,m12,m22 = a00,a01,a02,a11,a12,a22
    local v00,v01,v02 = 1,0,0
    local v10,v11,v12 = 0,1,0
    local v20,v21,v22 = 0,0,1

    local function rotate(p, q)
        local app, aqq, apq
        if p == 0 and q == 1 then app,aqq,apq = m00,m11,m01
        elseif p == 0 and q == 2 then app,aqq,apq = m00,m22,m02
        else app,aqq,apq = m11,m22,m12 end
        if abs(apq) <= 1e-14 * (abs(app) + abs(aqq) + 1) then return end

        local tau = (aqq - app) / (2 * apq)
        local t
        if tau >= 0 then t = 1 / (tau + sqrt(1 + tau*tau))
        else t = -1 / (-tau + sqrt(1 + tau*tau)) end
        local c = 1 / sqrt(1 + t*t)
        local s = t * c

        if p == 0 and q == 1 then
            local n00 = m00 - t*m01
            local n11 = m11 + t*m01
            local n02 = c*m02 - s*m12
            local n12 = s*m02 + c*m12
            m00,m11,m01,m02,m12 = n00,n11,0,n02,n12
        elseif p == 0 and q == 2 then
            local n00 = m00 - t*m02
            local n22 = m22 + t*m02
            local n01 = c*m01 - s*m12
            local n12 = s*m01 + c*m12
            m00,m22,m02,m01,m12 = n00,n22,0,n01,n12
        else
            local n11 = m11 - t*m12
            local n22 = m22 + t*m12
            local n01 = c*m01 - s*m02
            local n02 = s*m01 + c*m02
            m11,m22,m12,m01,m02 = n11,n22,0,n01,n02
        end

        if p == 0 and q == 1 then
            local a,b = v00,v01; v00,v01 = c*a-s*b, s*a+c*b
            a,b = v10,v11; v10,v11 = c*a-s*b, s*a+c*b
            a,b = v20,v21; v20,v21 = c*a-s*b, s*a+c*b
        elseif p == 0 and q == 2 then
            local a,b = v00,v02; v00,v02 = c*a-s*b, s*a+c*b
            a,b = v10,v12; v10,v12 = c*a-s*b, s*a+c*b
            a,b = v20,v22; v20,v22 = c*a-s*b, s*a+c*b
        else
            local a,b = v01,v02; v01,v02 = c*a-s*b, s*a+c*b
            a,b = v11,v12; v11,v12 = c*a-s*b, s*a+c*b
            a,b = v21,v22; v21,v22 = c*a-s*b, s*a+c*b
        end
    end

    -- hard cap, usually the off diagonals die several sweeps before this
    for _ = 1, 10 do
        rotate(0,1); rotate(0,2); rotate(1,2)
        if abs(m01)+abs(m02)+abs(m12) <= 1e-12*(abs(m00)+abs(m11)+abs(m22)+1) then break end
    end

    local vals = {m00,m11,m22}
    local vecs = {
        {v00,v10,v20},
        {v01,v11,v21},
        {v02,v12,v22},
    }
    for i=1,2 do
        local k=i
        for j=i+1,3 do if vals[j] < vals[k] then k=j end end
        if k ~= i then vals[i],vals[k] = vals[k],vals[i]; vecs[i],vecs[k] = vecs[k],vecs[i] end
    end
    for i=1,3 do
        vecs[i][1],vecs[i][2],vecs[i][3] = normalize(vecs[i][1],vecs[i][2],vecs[i][3])
    end
    return vals[1], vals[2], vals[3],
        vecs[1][1],vecs[1][2],vecs[1][3],
        vecs[2][1],vecs[2][2],vecs[2][3],
        vecs[3][1],vecs[3][2],vecs[3][3]
end

return M
