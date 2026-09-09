local M = {}

local abs, sin, cos, sqrt, exp, floor, pi = math.abs, math.sin, math.cos, math.sqrt, math.exp, math.floor, math.pi
local TWO_PI = 2 * pi

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function soft(x, scale)
    scale = scale or 1
    return x / (scale + abs(x))
end

local function emit(ax, ay, az, bx, by, bz)
    coroutine.yield(ax, ay, az, bx, by, bz)
end

local function rk4_step(x, y, z, h, deriv)
    local ax, ay, az = deriv(x, y, z)
    local bx, by, bz = deriv(x + ax*h*0.5, y + ay*h*0.5, z + az*h*0.5)
    local cx, cy, cz = deriv(x + bx*h*0.5, y + by*h*0.5, z + bz*h*0.5)
    local dx, dy, dz = deriv(x + cx*h, y + cy*h, z + cz*h)
    local q = h / 6
    return x + (ax + 2*bx + 2*cx + dx)*q,
        y + (ay + 2*by + 2*cy + dy)*q,
        z + (az + 2*bz + 2*cz + dz)*q
end

local function ode_curve(detail, init, h, warmup, steps_per_detail, deriv, map)
    local x, y, z = init[1], init[2], init[3]
    for _ = 1, warmup do
        x, y, z = rk4_step(x, y, z, h, deriv)
    end
    local steps = math.max(64, floor(steps_per_detail * detail))
    local x0, y0, z0 = map(x, y, z)
    for _ = 1, steps do
        x, y, z = rk4_step(x, y, z, h, deriv)
        local x1, y1, z1 = map(x, y, z)
        emit(x0, y0, z0, x1, y1, z1)
        x0, y0, z0 = x1, y1, z1
    end
end

local ODE = {}

ODE.lorenz = function(detail)
    ode_curve(detail, {0.1, 0, 0}, 0.007, 600, 1500, function(x, y, z)
        return 10*(y-x), x*(28-z)-y, x*y-(8/3)*z
    end, function(x, y, z)
        return soft(x, 18), soft(z-25, 18), soft(y, 24)
    end)
end

ODE.rossler = function(detail)
    ode_curve(detail, {0.1, 0, 0}, 0.015, 900, 1500, function(x, y, z)
        return -y-z, x+0.2*y, 0.2+z*(x-5.7)
    end, function(x, y, z)
        return soft(x, 8), soft(z-7, 8), soft(y, 8)
    end)
end

ODE.aizawa = function(detail)
    ode_curve(detail, {0.1, 0, 0}, 0.006, 800, 1700, function(x, y, z)
        local a,b,c,d,e,f = 0.95,0.7,0.6,3.5,0.25,0.1
        return (z-b)*x-d*y,
            d*x+(z-b)*y,
            c+a*z-z*z*z/3-(x*x+y*y)*(1+e*z)+f*z*x*x*x
    end, function(x, y, z)
        return soft(x, 1), soft(z, 1), soft(y, 1)
    end)
end

ODE.thomas = function(detail)
    ode_curve(detail, {0.1, 0, 0}, 0.02, 1200, 1500, function(x, y, z)
        local b = 0.208186
        return sin(y)-b*x, sin(z)-b*y, sin(x)-b*z
    end, function(x, y, z)
        return soft(x, 2.5), soft(y, 2.5), soft(z, 2.5)
    end)
end

ODE.dadras = function(detail)
    ode_curve(detail, {0.1,0.1,0.1}, 0.006, 900, 1700, function(x, y, z)
        local a,b,c,d,e = 3,2.7,1.7,2,9
        return y-a*x+b*y*z, c*y-x*z+z, d*x*y-e*z
    end, function(x, y, z)
        return soft(x, 3), soft(y, 3), soft(z, 3)
    end)
end

ODE.halvorsen = function(detail)
    ode_curve(detail, {-5,0,0}, 0.004, 800, 1700, function(x, y, z)
        local a = 1.4
        return -a*x-4*y-4*z-y*y,
            -a*y-4*z-4*x-z*z,
            -a*z-4*x-4*y-x*x
    end, function(x, y, z)
        return soft(x, 10), soft(y, 10), soft(z, 10)
    end)
end

ODE.chen = function(detail)
    ode_curve(detail, {-0.1,0.5,-0.6}, 0.0018, 1200, 1800, function(x, y, z)
        local a,b,c = 35,3,28
        return a*(y-x), (c-a)*x-x*z+c*y, x*y-b*z
    end, function(x, y, z)
        return soft(x, 22), soft(z-22, 20), soft(y, 22)
    end)
end

ODE.rabinovich = function(detail)
    ode_curve(detail, {-1,0,0.5}, 0.004, 1200, 1900, function(x, y, z)
        local alpha,gamma = 0.14,0.10
        return y*(z-1+x*x)+gamma*x,
            x*(3*z+1-x*x)+gamma*y,
            -2*z*(alpha+x*y)
    end, function(x, y, z)
        return soft(x, 2), soft(z, 1.5), soft(y, 2)
    end)
end

ODE.chua = function(detail)
    ode_curve(detail, {0.7,0,0}, 0.006, 1000, 1800, function(x, y, z)
        local alpha,beta,m0,m1 = 15.6,28,-1.143,-0.714
        local hx = m1*x + 0.5*(m0-m1)*(abs(x+1)-abs(x-1))
        return alpha*(y-x-hx), x-y+z, -beta*y
    end, function(x, y, z)
        return soft(x, 2), soft(z, 4), soft(y, 0.5)
    end)
end

ODE.rikitake = function(detail)
    ode_curve(detail, {0.1,0.2,0.3}, 0.004, 1400, 1800, function(x, y, z)
        local mu,a = 2,5
        return -mu*x+y*z, -mu*y+x*(z-a), 1-x*y
    end, function(x, y, z)
        return soft(x,2), soft(z,5), soft(y,2)
    end)
end

ODE.nose_hoover = function(detail)
    ode_curve(detail, {0,1,0}, 0.008, 1200, 1800, function(x, y, z)
        return y, -x+y*z, 1-y*y
    end, function(x, y, z)
        return soft(x,2), soft(z,2), soft(y,2)
    end)
end

ODE.duffing = function(detail)
    ode_curve(detail, {0.1,0,0}, 0.01, 1500, 1900, function(x, y, z)
        local delta,alpha,beta,gamma,omega = 0.3,-1,1,0.5,1.2
        return y, -delta*y-alpha*x-beta*x*x*x+gamma*cos(z), omega
    end, function(x, y, z)
        return soft(x,1.5), soft(y,1.5), 0.55*sin(z)
    end)
end

local function iterated_curve(detail, warmup, steps_per_detail, x, y, step_fn, map_fn)
    local prev = 0
    for _ = 1, warmup do x, y, prev = step_fn(x, y, prev) end
    local x0,y0,z0 = map_fn(x,y,prev)
    local steps = floor(steps_per_detail * detail)
    for _=1,steps do
        x,y,prev = step_fn(x,y,prev)
        local x1,y1,z1 = map_fn(x,y,prev)
        emit(x0,y0,z0,x1,y1,z1)
        x0,y0,z0=x1,y1,z1
    end
end

local MAP = {}
MAP.de_jong = function(detail, phase)
    local a,b,c,d = -2.24,0.43,-0.65,-2.43
    iterated_curve(detail, 60, 1500, 0.1, 0.1, function(x,y,prev)
        local nx = sin(a*y)-cos(b*x)
        local ny = sin(c*x)-cos(d*y)
        return nx,ny,x
    end, function(x,y,prev) return x*0.48,y*0.48,prev*0.28 + sin(phase)*0.03 end)
end
MAP.clifford = function(detail, phase)
    local a,b,c,d = -1.4,1.6,1.0,0.7
    iterated_curve(detail, 80, 1700, 0.1, 0.1, function(x,y,prev)
        local nx = sin(a*y)+c*cos(a*x)
        local ny = sin(b*x)+d*cos(b*y)
        return nx,ny,x
    end, function(x,y,prev) return x*0.42,y*0.42,prev*0.26 + cos(phase)*0.03 end)
end
MAP.ikeda = function(detail, phase)
    local u = 0.918
    iterated_curve(detail, 80, 1700, 0.1, 0.1, function(x,y,prev)
        local t = 0.4 - 6/(1+x*x+y*y)
        local nx = 1 + u*(x*cos(t)-y*sin(t))
        local ny = u*(x*sin(t)+y*cos(t))
        return nx,ny,x
    end, function(x,y,prev) return soft(x-0.5,1.5),soft(y,1.5),soft(prev,1.5)*0.6 end)
end

local function curve(detail, turns, samples_per_detail, fn)
    local n = math.max(32, floor(samples_per_detail * detail))
    local x0,y0,z0 = fn(0)
    for i=1,n do
        local t = turns * TWO_PI * i/n
        local x1,y1,z1 = fn(t)
        emit(x0,y0,z0,x1,y1,z1)
        x0,y0,z0=x1,y1,z1
    end
end

local PARAM = {}
PARAM.trefoil = function(detail)
    curve(detail,1,900,function(t)
        return (sin(t)+2*sin(2*t))/3, (cos(t)-2*cos(2*t))/3, -sin(3*t)/3
    end)
end
PARAM.torus_knot = function(detail, phase)
    local p,q = 3,7
    curve(detail,1,1200,function(t)
        local r = 0.68 + 0.28*cos(q*t + phase*0.15)
        return r*cos(p*t), r*sin(p*t), 0.28*sin(q*t + phase*0.15)
    end)
end
PARAM.lissajous = function(detail, phase)
    curve(detail,1,1100,function(t)
        return 0.82*sin(3*t+0.2), 0.82*sin(4*t+phase*0.1), 0.82*sin(5*t+0.7)
    end)
end

PARAM.hopf_links = function(detail, phase)
    local fibres = math.max(4, 4*detail)
    local n = math.max(64, floor(160*detail))
    for j=0,fibres-1 do

        local eta = 0.28 + 0.48*((j+0.5)/fibres)
        local delta = TWO_PI*j/fibres + phase*0.11
        local ce,se=cos(eta),sin(eta)
        local function pt(t)
            local xi1=t+delta*0.5
            local xi2=t-delta*0.5
            local x1=ce*cos(xi1); local x2=ce*sin(xi1)
            local x3=se*cos(xi2); local x4=se*sin(xi2)
            local den=1-x4
            return 0.34*x1/den,0.34*x2/den,0.34*x3/den
        end
        local x0,y0,z0=pt(0)
        for i=1,n do
            local x1,y1,z1=pt(TWO_PI*i/n)
            emit(x0,y0,z0,x1,y1,z1)
            x0,y0,z0=x1,y1,z1
        end
    end
end

local SURFACE = {}

local function grid_surface(detail, u_count, v_count, u0,u1,v0,v1, wrap_u, wrap_v, fn)
    local nu = math.max(6, floor(u_count*detail))
    local nv = math.max(4, floor(v_count*detail))
    local function point(i,j)
        local u = u0 + (u1-u0)*(i/nu)
        local v = v0 + (v1-v0)*(j/nv)
        return fn(u,v)
    end
    for j=0,nv do
        local last_i = wrap_u and nu or nu-1
        for i=0,last_i do
            local ni = i+1
            if ni>nu then ni=0 end
            local ax,ay,az=point(i,j); local bx,by,bz=point(ni,j)
            emit(ax,ay,az,bx,by,bz)
        end
    end
    for i=0,nu do
        local last_j = wrap_v and nv or nv-1
        for j=0,last_j do
            local nj=j+1; if nj>nv then nj=0 end
            local ax,ay,az=point(i,j); local bx,by,bz=point(i,nj)
            emit(ax,ay,az,bx,by,bz)
        end
    end
end

SURFACE.mobius = function(detail)
    grid_surface(detail,30,7,0,TWO_PI,-0.38,0.38,true,false,function(u,v)
        local r=0.63 + v*cos(u/2)
        return r*cos(u), r*sin(u), v*sin(u/2)
    end)
end

SURFACE.klein = function(detail)
    grid_surface(detail,30,14,0,TWO_PI,0,TWO_PI,true,true,function(u,v)

        local r = 0.38
        local x = (r + cos(u/2)*sin(v) - sin(u/2)*sin(2*v))*cos(u)
        local y = (r + cos(u/2)*sin(v) - sin(u/2)*sin(2*v))*sin(u)
        local z = sin(u/2)*sin(v) + cos(u/2)*sin(2*v)
        return x*0.72,y*0.72,z*0.45
    end)
end

SURFACE.clifford_torus = function(detail, phase)
    grid_surface(detail,30,16,0,TWO_PI,0,TWO_PI,true,true,function(u,v)

        local x1=cos(u)/sqrt(2); local x2=sin(u)/sqrt(2)
        local x3=cos(v+phase*0.05)/sqrt(2); local x4=sin(v+phase*0.05)/sqrt(2)
        local den=1.18-x4
        return 0.48*x1/den,0.48*x2/den,0.48*x3/den
    end)
end

local function associated_legendre(l,m,x)
    local pmm=1
    if m>0 then
        local somx2=sqrt(math.max(0,1-x*x))
        local fact=1
        for _=1,m do pmm=-pmm*fact*somx2; fact=fact+2 end
    end
    if l==m then return pmm end
    local pmmp1=x*(2*m+1)*pmm
    if l==m+1 then return pmmp1 end
    local pll=0
    for ll=m+2,l do
        pll=((2*ll-1)*x*pmmp1-(ll+m-1)*pmm)/(ll-m)
        pmm,pmmp1=pmmp1,pll
    end
    return pll
end

SURFACE.spherical_harmonic = function(detail, phase)
    local l,m=5,3
    grid_surface(detail,30,15,0,TWO_PI,0,pi,true,false,function(phi,theta)
        local y=associated_legendre(l,m,cos(theta))*cos(m*phi+phase*0.08)/65.5
        local r=0.60+0.22*y
        local st=sin(theta)
        return r*st*cos(phi),r*cos(theta),r*st*sin(phi)
    end)
end

SURFACE.enneper = function(detail)
    grid_surface(detail,20,20,-1.25,1.25,-1.25,1.25,false,false,function(u,v)
        local x=u-u*u*u/3+u*v*v
        local y=v-v*v*v/3+v*u*u
        local z=u*u-v*v
        return x*0.30,y*0.30,z*0.22
    end)
end

SURFACE.helicoid = function(detail)
    grid_surface(detail,28,12,-pi,pi,-1,1,false,false,function(u,v)
        return 0.60*v*cos(u),0.60*v*sin(u),0.16*u
    end)
end

SURFACE.catenoid = function(detail)
    grid_surface(detail,30,12,0,TWO_PI,-1,1,true,false,function(u,v)
        local ch=(exp(v)+exp(-v))*0.5
        return 0.35*ch*cos(u),0.35*v,0.35*ch*sin(u)
    end)
end

SURFACE.roman = function(detail)
    grid_surface(detail,30,15,0,TWO_PI,0,pi,true,false,function(u,v)

        local sv=sin(v)
        local su,cu=sin(u),cos(u)
        local x=sv*sv*sin(2*u)
        local y=sin(2*v)*cu
        local z=sin(2*v)*su
        return 0.48*x,0.48*y,0.48*z
    end)
end

SURFACE.superformula = function(detail, phase)
    local function super(theta,m,n1,n2,n3)
        local a,b=1,1
        local t1=abs(cos(m*theta/4)/a)^n2
        local t2=abs(sin(m*theta/4)/b)^n3
        local s=t1+t2
        if s<1e-9 then return 0 end
        return s^(-1/n1)
    end
    grid_surface(detail,32,16,-pi,pi,-pi/2,pi/2,true,false,function(lon,lat)
        local r1=super(lon+phase*0.02,7,0.3,0.2,1.7)
        local r2=super(lat,3,0.45,1.3,1.3)
        local x=0.48*r1*cos(lon)*r2*cos(lat)
        local y=0.48*r2*sin(lat)
        local z=0.48*r1*sin(lon)*r2*cos(lat)
        return x,y,z
    end)
end

local IMPLICIT = {}

IMPLICIT.gyroid_contours = function(detail, phase)
    local n = math.max(12, floor(10 + 6*detail))
    local slices = math.max(3, floor(3 + detail))
    local lo, hi = -pi, pi
    local step = (hi-lo)/n
    local shift = phase * 0.07

    local function field(x,y,z)
        x,y,z=x+shift,y-shift*0.7,z+shift*0.35
        return sin(x)*cos(y) + sin(y)*cos(z) + sin(z)*cos(x)
    end

    local function interp(a,b,fa,fb)
        local den=fa-fb
        local t
        if abs(den)>1e-12 then t=fa/den else t=0.5 end
        t=clamp(t,0,1)
        return a+(b-a)*t
    end

    local function edge_point(edge,x0,y0,x1,y1,f00,f10,f11,f01)
        if edge==0 then return interp(x0,x1,f00,f10),y0 end
        if edge==1 then return x1,interp(y0,y1,f10,f11) end
        if edge==2 then return interp(x1,x0,f11,f01),y1 end
        return x0,interp(y1,y0,f01,f00)
    end

    local function emit_edges(ea,eb,z,x0,y0,x1,y1,f00,f10,f11,f01)
        local ax,ay=edge_point(ea,x0,y0,x1,y1,f00,f10,f11,f01)
        local bx,by=edge_point(eb,x0,y0,x1,y1,f00,f10,f11,f01)
        emit(ax/pi*0.76,z/pi*0.58,ay/pi*0.76,bx/pi*0.76,z/pi*0.58,by/pi*0.76)
    end

    for k=0,slices-1 do
        local z
        if slices==1 then z=0 else z=lo+(hi-lo)*k/(slices-1) end
        for j=0,n-1 do
            local y0=lo+j*step
            local y1=y0+step
            for i=0,n-1 do
                local x0=lo+i*step
                local x1=x0+step
                local f00=field(x0,y0,z)
                local f10=field(x1,y0,z)
                local f11=field(x1,y1,z)
                local f01=field(x0,y1,z)
                local case=0
                if f00>=0 then case=case+1 end
                if f10>=0 then case=case+2 end
                if f11>=0 then case=case+4 end
                if f01>=0 then case=case+8 end

                if case==1 or case==14 then emit_edges(3,0,z,x0,y0,x1,y1,f00,f10,f11,f01)
                elseif case==2 or case==13 then emit_edges(0,1,z,x0,y0,x1,y1,f00,f10,f11,f01)
                elseif case==3 or case==12 then emit_edges(3,1,z,x0,y0,x1,y1,f00,f10,f11,f01)
                elseif case==4 or case==11 then emit_edges(1,2,z,x0,y0,x1,y1,f00,f10,f11,f01)
                elseif case==6 or case==9 then emit_edges(0,2,z,x0,y0,x1,y1,f00,f10,f11,f01)
                elseif case==7 or case==8 then emit_edges(3,2,z,x0,y0,x1,y1,f00,f10,f11,f01)
                elseif case==5 or case==10 then
                    local fc=field((x0+x1)*0.5,(y0+y1)*0.5,z)
                    local center_positive=fc>=0
                    if (case==5 and center_positive) or (case==10 and not center_positive) then
                        emit_edges(0,1,z,x0,y0,x1,y1,f00,f10,f11,f01)
                        emit_edges(2,3,z,x0,y0,x1,y1,f00,f10,f11,f01)
                    else
                        emit_edges(3,0,z,x0,y0,x1,y1,f00,f10,f11,f01)
                        emit_edges(1,2,z,x0,y0,x1,y1,f00,f10,f11,f01)
                    end
                end
            end
        end
    end
end

local DISCRETE = {}
DISCRETE.fibonacci_sphere = function(detail, phase)
    local n=math.max(80,floor(500*detail))
    local golden=pi*(3-sqrt(5))
    local x0,y0,z0=nil,nil,nil
    for i=0,n-1 do
        local y=1-2*(i+0.5)/n
        local r=sqrt(math.max(0,1-y*y))
        local a=golden*i+phase*0.04
        local x,z=r*cos(a),r*sin(a)
        if x0 then emit(0.72*x0,0.72*y0,0.72*z0,0.72*x,0.72*y,0.72*z) end
        x0,y0,z0=x,y,z
    end
end

local FRACTAL = {}
FRACTAL.sierpinski_tetra = function(detail)
    local depth=math.max(1,math.min(5,1+floor(detail)))
    local root={
        {-0.62,-0.45,-0.42},{0.62,-0.45,-0.42},{0,0.68,-0.42},{0,0,0.68}
    }
    local function midpoint(a,b) return {(a[1]+b[1])*0.5,(a[2]+b[2])*0.5,(a[3]+b[3])*0.5} end
    local function edges(t)
        local e={{1,2},{1,3},{1,4},{2,3},{2,4},{3,4}}
        for i=1,6 do local a,b=t[e[i][1]],t[e[i][2]];emit(a[1],a[2],a[3],b[1],b[2],b[3]) end
    end
    local function rec(t,d)
        if d<=0 then edges(t);return end
        local a,b,c,e=t[1],t[2],t[3],t[4]
        local ab,ac,ae=midpoint(a,b),midpoint(a,c),midpoint(a,e)
        local bc,be,ce=midpoint(b,c),midpoint(b,e),midpoint(c,e)
        rec({a,ab,ac,ae},d-1);rec({ab,b,bc,be},d-1)
        rec({ac,bc,c,ce},d-1);rec({ae,be,ce,e},d-1)
    end
    rec(root,depth)
end

local FLOW = {}
FLOW.abc = function(detail, phase)
    local A,B,C = 1,sqrt(2/3),sqrt(1/3)
    local seed_n = math.max(4, floor(4*detail))
    local steps = math.max(80, floor(230*detail))
    local h = 0.035

    local function deriv(x, y, z)
        return A*sin(z)+C*cos(y),
            B*sin(x)+A*cos(z),
            C*sin(y)+B*cos(x)
    end

    for s=0,seed_n-1 do
        local a = TWO_PI*s/seed_n + phase*0.06
        local x = pi + 0.8*cos(a)
        local y = pi + 0.8*sin(a)
        local z = pi + 0.35*sin(2*a)

        local function map(px, py, pz)
            return (px-pi)/pi*0.72, (py-pi)/pi*0.72, (pz-pi)/pi*0.72
        end

        local x0,y0,z0 = map(x,y,z)
        for _=1,steps do
            x,y,z = rk4_step(x,y,z,h,deriv)
            x=x%TWO_PI
            y=y%TWO_PI
            z=z%TWO_PI
            local x1,y1,z1 = map(x,y,z)
            local dx,dy,dz = x1-x0,y1-y0,z1-z0
            if dx*dx+dy*dy+dz*dz < 0.22 then
                emit(x0,y0,z0,x1,y1,z1)
            end
            x0,y0,z0 = x1,y1,z1
        end
    end
end

local builders = {
    lorenz = function(d,p) ODE.lorenz(d,p) end,
    rossler = function(d,p) ODE.rossler(d,p) end,
    aizawa = function(d,p) ODE.aizawa(d,p) end,
    thomas = function(d,p) ODE.thomas(d,p) end,
    dadras = function(d,p) ODE.dadras(d,p) end,
    halvorsen = function(d,p) ODE.halvorsen(d,p) end,
    chen = function(d,p) ODE.chen(d,p) end,
    rabinovich = function(d,p) ODE.rabinovich(d,p) end,
    chua = function(d,p) ODE.chua(d,p) end,
    rikitake = function(d,p) ODE.rikitake(d,p) end,
    nose_hoover = function(d,p) ODE.nose_hoover(d,p) end,
    duffing = function(d,p) ODE.duffing(d,p) end,
    de_jong = MAP.de_jong,
    clifford_map = MAP.clifford,
    ikeda = MAP.ikeda,
    trefoil = PARAM.trefoil,
    torus_knot = PARAM.torus_knot,
    lissajous = PARAM.lissajous,
    hopf_links = PARAM.hopf_links,
    mobius = SURFACE.mobius,
    klein = SURFACE.klein,
    clifford_torus = SURFACE.clifford_torus,
    spherical_harmonic = SURFACE.spherical_harmonic,
    enneper = SURFACE.enneper,
    helicoid = SURFACE.helicoid,
    catenoid = SURFACE.catenoid,
    roman = SURFACE.roman,
    superformula = SURFACE.superformula,
    gyroid_contours = IMPLICIT.gyroid_contours,
    fibonacci_sphere = DISCRETE.fibonacci_sphere,
    sierpinski_tetra = FRACTAL.sierpinski_tetra,
    abc_flow = FLOW.abc,
}


function M.new(pattern, detail, phase)
    local fn = builders[pattern] or builders.lorenz
    detail = clamp(tonumber(detail) or 1, 0.5, 4)
    phase = tonumber(phase) or 0
    return coroutine.create(function() fn(detail, phase) end)
end

return M
