local mod = get_mod("NoBrainer")
local eigen3 = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/SymmetricEigen3")
local dual_contouring = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/DualContouring")

local M = {}

local abs, ceil, exp, floor, log, max, min, sqrt = math.abs, math.ceil, math.exp, math.floor, math.log, math.max, math.min, math.sqrt
local tostring = tostring
local yield = coroutine.yield

local function key(ix,iy,iz) return tostring(ix)..":"..tostring(iy)..":"..tostring(iz) end
local function d2(ax,ay,az,bx,by,bz)
    local x,y,z=ax-bx,ay-by,az-bz
    return x*x+y*y+z*z
end
local function normalize(x,y,z)
    local q=x*x+y*y+z*z
    if q <= 1e-20 then return nil end
    local s=1/sqrt(q)
    return x*s,y*s,z*s
end
local function checkpoint() yield("work") end
local function emit(style, ax,ay,az,bx,by,bz) yield("line",style,ax,ay,az,bx,by,bz) end

local function build_hash(p, cell)
    local h={}
    for i=1,p.count do
        local k=key(floor(p.x[i]/cell),floor(p.y[i]/cell),floor(p.z[i]/cell))
        local b=h[k]
        if not b then b={}; h[k]=b end
        b[#b+1]=i
        if i % 96 == 0 then checkpoint() end
    end
    return h
end

local function each_neighbor(h,p,cell,x,y,z,r,fn)
    local cminx,cmaxx=floor((x-r)/cell),floor((x+r)/cell)
    local cminy,cmaxy=floor((y-r)/cell),floor((y+r)/cell)
    local cminz,cmaxz=floor((z-r)/cell),floor((z+r)/cell)
    local rr=r*r
    local visited=0
    for ix=cminx,cmaxx do for iy=cminy,cmaxy do for iz=cminz,cmaxz do
        local b=h[key(ix,iy,iz)]
        if b then
            for bi=1,#b do
                visited=visited+1
                if visited%128==0 then checkpoint() end
                local j=b[bi]
                local q=d2(x,y,z,p.x[j],p.y[j],p.z[j])
                if q <= rr and fn(j,q) == false then return false end
            end
        end
    end end end
    return true
end

local function weighted_pca(h,p,cell,i,r)
    local x,y,z=p.x[i],p.y[i],p.z[i]
    -- gaussian is intentionally tighter than the search radius so the frame stays actually local
    local sigma2=max(1e-8,(r*0.55)^2)
    local sw,sx,sy,sz,n=0,0,0,0,0
    local anx,any,anz=p.nx[i] or 0,p.ny[i] or 0,p.nz[i] or 0
    each_neighbor(h,p,cell,x,y,z,r,function(j,q)
        local nd=anx*(p.nx[j] or 0)+any*(p.ny[j] or 0)+anz*(p.nz[j] or 0)
        -- nearby backfaces are still a different surface, especially around thin walls
        if nd < -0.55 then return end
        local w=exp(-q/(2*sigma2))
        sw=sw+w; sx=sx+w*p.x[j]; sy=sy+w*p.y[j]; sz=sz+w*p.z[j]; n=n+1
    end)
    if n < 5 or sw <= 1e-10 then return nil end
    local mx,my,mz=sx/sw,sy/sw,sz/sw
    local c00,c01,c02,c11,c12,c22=0,0,0,0,0,0
    each_neighbor(h,p,cell,x,y,z,r,function(j,q)
        local nd=anx*(p.nx[j] or 0)+any*(p.ny[j] or 0)+anz*(p.nz[j] or 0)
        if nd < -0.55 then return end
        local w=exp(-q/(2*sigma2))
        local dx,dy,dz=p.x[j]-mx,p.y[j]-my,p.z[j]-mz
        c00=c00+w*dx*dx; c01=c01+w*dx*dy; c02=c02+w*dx*dz
        c11=c11+w*dy*dy; c12=c12+w*dy*dz; c22=c22+w*dz*dz
    end)
    local l0,l1,l2,nx,ny,nz,t1x,t1y,t1z,t2x,t2y,t2z = eigen3.solve(c00,c01,c02,c11,c12,c22)
    return l0,l1,l2,nx,ny,nz,t1x,t1y,t1z,t2x,t2y,t2z,mx,my,mz
end

local function gabriel(p,scale)
    local cell=max(0.05,scale*0.75)
    local radius=scale*1.5
    local h=build_hash(p,cell)
    for i=1,p.count do
        local xi,yi,zi=p.x[i],p.y[i],p.z[i]
        each_neighbor(h,p,cell,xi,yi,zi,radius,function(j,q)
            if j <= i or q <= 1e-10 then return end
            local xj,yj,zj=p.x[j],p.y[j],p.z[j]

            local nd=(p.nx[i] or 0)*(p.nx[j] or 0)+(p.ny[i] or 0)*(p.ny[j] or 0)+(p.nz[i] or 0)*(p.nz[j] or 0)
            if nd < -0.55 then return end
            local mx,my,mz=(xi+xj)*0.5,(yi+yj)*0.5,(zi+zj)*0.5
            -- gabriel edge survives only when its diameter-ball has nobody else inside
            local rr=q*0.25
            local blocked=false
            each_neighbor(h,p,cell,mx,my,mz,sqrt(rr)*1.001,function(k,kq)
                if k~=i and k~=j and kq < rr*(1-1e-7) then blocked=true; return false end
            end)
            if not blocked then emit(1,xi,yi,zi,xj,yj,zj) end
        end)
        if i%8==0 then checkpoint() end
    end
end

local function pca_frames(p,scale)
    local cell=max(0.05,scale)
    local h=build_hash(p,cell)
    local r=scale*1.35
    local stride=max(1,floor(p.count/1800))
    for i=1,p.count,stride do
        local l0,l1,l2,nx,ny,nz,t1x,t1y,t1z,t2x,t2y,t2z = weighted_pca(h,p,cell,i,r)
        if l0 then
            local pnx,pny,pnz=p.nx[i] or 0,p.ny[i] or 0,p.nz[i] or 0
            if nx*pnx+ny*pny+nz*pnz < 0 then nx,ny,nz=-nx,-ny,-nz end
            local sum=max(1e-12,l0+l1+l2)
            local curvature=max(0,min(1,l0/sum*10))
            local x,y,z=p.x[i],p.y[i],p.z[i]
            local a=scale*0.24
            local b=scale*0.17
            local c=scale*(0.10+0.30*curvature)
            emit(1,x-t1x*a,y-t1y*a,z-t1z*a,x+t1x*a,y+t1y*a,z+t1z*a)
            emit(1,x-t2x*b,y-t2y*b,z-t2z*b,x+t2x*b,y+t2y*b,z+t2z*b)
            emit(curvature>0.35 and 3 or 2,x,y,z,x+nx*c,y+ny*c,z+nz*c)
        end
        if i%16==1 then checkpoint() end
    end
end

local function ransac_planes(p,scale)
    local n=p.count
    if n < 12 then return end
    local stride=max(1,floor(n/2600))
    local active={}
    for i=1,n,stride do active[#active+1]=i end
    local tol=max(0.035,scale*0.075)
    local normal_cos=0.78
    -- deterministic rng so rebuilding the same cloud doesnt pick totally different planes
    local seed=(n*2654435761)%4294967296
    local function rnd(m)
        seed=(seed*1664525+1013904223)%4294967296
        return floor((seed/4294967296)*m)+1
    end

    for plane_no=1,8 do
        if #active < 12 then break end
        local best_count,best_nx,best_ny,best_nz,best_d=0,nil,nil,nil,nil
        local max_trials=160
        local required_trials=max_trials
        local trial=0
        local confidence=0.995
        while trial<required_trials and trial<max_trials do
            trial=trial+1
            -- use an oriented sample as the plane hypothesis, cheaper than 3 points and fits this scan data
            local ia=active[rnd(#active)]
            local nx,ny,nz=normalize(p.nx[ia] or 0,p.ny[ia] or 0,p.nz[ia] or 0)
            if nx then
                local ax,ay,az=p.x[ia],p.y[ia],p.z[ia]
                local dd=-(nx*ax+ny*ay+nz*az)
                local cnt=0
                for q=1,#active do
                    local j=active[q]
                    if abs(nx*p.x[j]+ny*p.y[j]+nz*p.z[j]+dd)<=tol then
                        local jnx,jny,jnz=p.nx[j] or 0,p.ny[j] or 0,p.nz[j] or 0
                        local jq=jnx*jnx+jny*jny+jnz*jnz
                        if jq<=1e-12 or abs(nx*jnx+ny*jny+nz*jnz)/sqrt(jq)>=normal_cos then cnt=cnt+1 end
                    end
                    if q%96==0 then checkpoint() end
                end
                if cnt>best_count then
                    best_count,best_nx,best_ny,best_nz,best_d=cnt,nx,ny,nz,dd
                    local w=cnt/#active
                    if w>=1-1e-12 then
                        required_trials=trial
                    elseif w>1e-12 then
                        -- once a decent plane appears theres no reason to burn all 160 guesses
                        local estimate=ceil(log(1-confidence)/log(1-w))
                        required_trials=min(required_trials,max(12,estimate))
                    end
                end
            end
        end
        local min_inliers=max(12,floor(#active*0.06))
        if best_count < min_inliers or not best_nx then break end

        local inliers={}
        local sx,sy,sz=0,0,0
        for q=1,#active do
            local j=active[q]
            if abs(best_nx*p.x[j]+best_ny*p.y[j]+best_nz*p.z[j]+best_d)<=tol then
                local jnx,jny,jnz=p.nx[j] or 0,p.ny[j] or 0,p.nz[j] or 0
                local jq=jnx*jnx+jny*jny+jnz*jnz
                if jq<=1e-12 or abs(best_nx*jnx+best_ny*jny+best_nz*jnz)/sqrt(jq)>=normal_cos then
                    inliers[#inliers+1]=j; sx=sx+p.x[j]; sy=sy+p.y[j]; sz=sz+p.z[j]
                end
            end
        end
        if #inliers < min_inliers then break end
        local cx,cy,cz=sx/#inliers,sy/#inliers,sz/#inliers
        local c00,c01,c02,c11,c12,c22=0,0,0,0,0,0
        for q=1,#inliers do
            local j=inliers[q]; local x,y,z=p.x[j]-cx,p.y[j]-cy,p.z[j]-cz
            c00=c00+x*x;c01=c01+x*y;c02=c02+x*z;c11=c11+y*y;c12=c12+y*z;c22=c22+z*z
            if q%128==0 then checkpoint() end
        end
        -- ransac only found the support, this pca pass is the actual refit
        local _,_,_,nx,ny,nz,u1,u2,u3,v1,v2,v3=eigen3.solve(c00,c01,c02,c11,c12,c22)
        if nx*best_nx+ny*best_ny+nz*best_nz < 0 then nx,ny,nz=-nx,-ny,-nz end
        local umin,umax,vmin,vmax=math.huge,-math.huge,math.huge,-math.huge
        for q=1,#inliers do
            local j=inliers[q]; local x,y,z=p.x[j]-cx,p.y[j]-cy,p.z[j]-cz
            local u=x*u1+y*u2+z*u3; local v=x*v1+y*v2+z*v3
            if u<umin then umin=u end;if u>umax then umax=u end;if v<vmin then vmin=v end;if v>vmax then vmax=v end
            if q%128==0 then checkpoint() end
        end
        local function pt(u,v) return cx+u*u1+v*v1,cy+u*u2+v*v2,cz+u*u3+v*v3 end
        local a1,a2,a3=pt(umin,vmin); local b1,b2,b3=pt(umax,vmin)
        local c1,c2,c3=pt(umax,vmax); local d1,d2,d3=pt(umin,vmax)
        local style=((plane_no-1)%3)+1
        emit(style,a1,a2,a3,b1,b2,b3);emit(style,b1,b2,b3,c1,c2,c3)
        emit(style,c1,c2,c3,d1,d2,d3);emit(style,d1,d2,d3,a1,a2,a3)
        emit(style,a1,a2,a3,c1,c2,c3);emit(style,b1,b2,b3,d1,d2,d3)
        local nl=scale*0.45; emit(2,cx,cy,cz,cx+nx*nl,cy+ny*nl,cz+nz*nl)

        local remove={}; for q=1,#inliers do remove[inliers[q]]=true end
        local next_active={}
        for q=1,#active do local j=active[q]; if not remove[j] then next_active[#next_active+1]=j end end
        active=next_active
        checkpoint()
    end
end

local function spectral_graph(p,scale)
    local cell=max(0.05,scale)
    local h=build_hash(p,cell)
    local r=scale*1.55
    local kmax=8
    local adj,edge_u,edge_v={},{},{}
    local seen={}
    for i=1,p.count do adj[i]={} end
    for i=1,p.count do
        local idx,ds={},{}
        each_neighbor(h,p,cell,p.x[i],p.y[i],p.z[i],r,function(j,q)
            if j==i then return end
            local nd=(p.nx[i] or 0)*(p.nx[j] or 0)+(p.ny[i] or 0)*(p.ny[j] or 0)+(p.nz[i] or 0)*(p.nz[j] or 0)
            if nd < -0.55 then return end
            local pos=#idx+1
            while pos>1 and ds[pos-1]>q do
                if pos<=kmax then idx[pos],ds[pos]=idx[pos-1],ds[pos-1] end
                pos=pos-1
            end
            if pos<=kmax then idx[pos],ds[pos]=j,q; if #idx>kmax then idx[kmax+1],ds[kmax+1]=nil,nil end end
        end)
        for q=1,#idx do
            local j=idx[q]; local a,b=i,j; if a>b then a,b=b,a end
            local ek=a..":"..b
            if not seen[ek] then
                seen[ek]=true; edge_u[#edge_u+1]=a;edge_v[#edge_v+1]=b
                local w=exp(-ds[q]/max(1e-8,scale*scale))
                local ai,aj=adj[i],adj[j]
                ai[#ai+1]=j;ai[#ai+1]=w;aj[#aj+1]=i;aj[#aj+1]=w
            end
        end
        if i%24==0 then checkpoint() end
    end

    local n=p.count; local v,y,degree,qvec={},{},{},{}
    local qnorm2=0
    for i=1,n do
        local a=adj[i]; local d=0
        for q=1,#a,2 do
            d=d+a[q+1]
            if q%256==255 then checkpoint() end
        end
        degree[i]=d; qvec[i]=sqrt(max(d,0)); qnorm2=qnorm2+qvec[i]*qvec[i]
        v[i]=math.sin(i*12.9898+78.233)
        if i%128==0 then checkpoint() end
    end

    -- normalized adjacency power iteration, projecting out the boring degree mode each round
    -- 42 is mostly just a visual convergence choice at these graph sizes
    for _=1,42 do
        for i=1,n do
            local a=adj[i]; local sv=0; local di=degree[i]
            if di>1e-20 then
                local root_di=sqrt(di)
                for q=1,#a,2 do
                    local j,w=a[q],a[q+1]; local dj=degree[j]
                    if dj>1e-20 then sv=sv+w*v[j]/(root_di*sqrt(dj)) end
                    if q%256==255 then checkpoint() end
                end
                y[i]=0.5*v[i]+0.5*sv
            else y[i]=v[i] end
            if i%128==0 then checkpoint() end
        end
        local proj=0
        if qnorm2>1e-20 then
            for i=1,n do
                proj=proj+qvec[i]*y[i]
                if i%256==0 then checkpoint() end
            end
            proj=proj/qnorm2
        end
        local norm2=0
        for i=1,n do
            y[i]=y[i]-proj*qvec[i];norm2=norm2+y[i]*y[i]
            if i%256==0 then checkpoint() end
        end
        local inv=norm2>1e-20 and 1/sqrt(norm2) or 1
        for i=1,n do
            y[i]=y[i]*inv
            if i%256==0 then checkpoint() end
        end
        v,y=y,v
    end
    for e=1,#edge_u do
        local i,j=edge_u[e],edge_v[e]
        local style=(v[i]*v[j]<0) and 3 or ((v[i]+v[j]>=0) and 1 or 2)
        emit(style,p.x[i],p.y[i],p.z[i],p.x[j],p.y[j],p.z[j])
        if e%32==0 then checkpoint() end
    end
end

local function mls_implicit(p,scale)
    local point_cell=max(0.05,scale)
    local h=build_hash(p,point_cell)
    local size=max(0.14,scale*0.34)
    local support=max(size*2.2,scale*1.55)
    local candidate,cx,cy,cz={}, {}, {}, {}
    local candidate_count=0
    local max_candidates=min(90000,max(12000,p.count*24))
    local function add_vertex(ix,iy,iz)
        if candidate_count>=max_candidates then return end
        local k=key(ix,iy,iz)
        if candidate[k] then return end
        candidate[k]=true
        candidate_count=candidate_count+1
        cx[candidate_count],cy[candidate_count],cz[candidate_count]=ix,iy,iz
    end
    for i=1,p.count do
        local gx,gy,gz=floor(p.x[i]/size),floor(p.y[i]/size),floor(p.z[i]/size)
        for dx=-1,1 do for dy=-1,1 do for dz=-1,1 do add_vertex(gx+dx,gy+dy,gz+dz) end end end
        if i%48==0 then checkpoint() end
    end

    local volume={size=size,voxels={},voxel_list={},count=0}
    function volume:get(ix,iy,iz) return self.voxels[key(ix,iy,iz)] end
    local support2=support*support
    for ci=1,candidate_count do
        local ix,iy,iz=cx[ci],cy[ci],cz[ci]
        local x,y,z=ix*size,iy*size,iz*size
        local nearest_q=math.huge;local rnx,rny,rnz=nil,nil,nil
        local neighbor_count=0
        each_neighbor(h,p,point_cell,x,y,z,support,function(j,q)
            neighbor_count=neighbor_count+1
            if q<nearest_q then nearest_q=q;rnx,rny,rnz=p.nx[j],p.ny[j],p.nz[j] end
        end)
        if neighbor_count>=3 and rnx then
            local sw,sf,snx,sny,snz=0,0,0,0,0
            each_neighbor(h,p,point_cell,x,y,z,support,function(j,q)
                local t=sqrt(q/support2)
                if t<1 then
                    -- compact smooth weight so points near support edge fade out instead of yanking the field
                    local om=1-t; local w=om*om*om*om*(4*t+1)
                    local nx,ny,nz=p.nx[j],p.ny[j],p.nz[j]
                    if nx*rnx+ny*rny+nz*rnz<0 then nx,ny,nz=-nx,-ny,-nz end
                    local signed=nx*(x-p.x[j])+ny*(y-p.y[j])+nz*(z-p.z[j])
                    sw=sw+w;sf=sf+w*signed;snx=snx+w*nx;sny=sny+w*ny;snz=snz+w*nz
                end
            end)
            if sw>1e-8 then
                local nx,ny,nz=normalize(snx,sny,snz)
                if nx then
                    local v={ix=ix,iy=iy,iz=iz,d=sf/sw,w=1,nx=nx,ny=ny,nz=nz}
                    volume.count=volume.count+1;volume.voxels[key(ix,iy,iz)]=v;volume.voxel_list[volume.count]=v
                end
            end
        end
        if ci%32==0 then checkpoint() end
    end
    candidate,cx,cy,cz=nil,nil,nil,nil
    if volume.count==0 then return end
    local ex=dual_contouring.new(volume)
    while not ex:is_done() or ex:segments_remaining()>0 do
        if not ex:is_done() then ex:step(96) end
        while ex:segments_remaining()>0 do
            local ax,ay,az,bx,by,bz=ex:next_segment()
            if ax then emit(1,ax,ay,az,bx,by,bz) end
        end
        checkpoint()
    end
    ex:clear()
end

local algorithms={
    gabriel_graph=gabriel,
    pca_curvature=pca_frames,
    ransac_planes=ransac_planes,
    spectral_graph=spectral_graph,
    mls_implicit=mls_implicit,
}

function M.new(mode,points,scale)
    local fn=algorithms[mode]
    assert(fn,"unknown point-cloud algorithm: "..tostring(mode))
    local co=coroutine.create(function() fn(points,max(0.1,scale)) end)
    local self={co=co,done=false,error=nil}
    function self:resume()
        if self.done then return "done" end
        local ok,a,b,c,d,e,f,g,h=coroutine.resume(self.co)
        if not ok then self.done=true;self.error=a;return "error",a end
        if coroutine.status(self.co)=="dead" then self.done=true;return "done" end
        return a,b,c,d,e,f,g,h
    end
    return self
end

return M
