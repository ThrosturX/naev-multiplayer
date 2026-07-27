package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

N_=function(s) return s end

local vec2_mt = {}
vec2_mt.__index = vec2_mt
function vec2_mt.__add ( a, b )
   return setmetatable({x=a.x+b.x,y=a.y+b.y},vec2_mt)
end
function vec2_mt.__sub ( a, b )
   return setmetatable({x=a.x-b.x,y=a.y-b.y},vec2_mt)
end
function vec2_mt.__mul ( a, b )
   if type(a)=="number" then a,b=b,a end
   return setmetatable({x=a.x*b,y=a.y*b},vec2_mt)
end
function vec2_mt:dist ( other )
   return math.sqrt((self.x-other.x)^2+(self.y-other.y)^2)
end

vec2 = {
   new=function(x,y)
      return setmetatable({x=x or 0,y=y or 0},vec2_mt)
   end,
}

local canonical = {
   {name="Peninsula",track={}},
   {name="Smiling Man",track={}},
   {name="Qex Tour",track={}},
}
package.preload["missions.neutral.race.tracks_qex"] = function()
   return canonical
end

local tracks = require "multiplayer.pod_racing_tracks"
assert(#canonical==3 and canonical[1].contestants==nil,
   "canonical Qex track table was mutated")
assert(tracks~=canonical and tracks[1]~=canonical[1]
   and tracks[1].track==canonical[1].track,
   "canonical tracks were not copied into a separate list")
assert(tracks[1].contestants==4 and tracks[2].contestants==6
   and tracks[3].contestants==8,"canonical track contestant limits changed")
assert(tracks[1].id=="peninsula" and tracks[2].id=="smiling_man"
   and tracks[3].id=="qex_tour","canonical track IDs changed")
assert(tracks[3].name=="Alteris Tour" and tracks[3].centre==true,
   "Qex Tour was not recentered and renamed for Alteris")

local crossfire = tracks[#tracks]
assert(#tracks==4 and crossfire.name=="Darkshed Death Knot",
   "Darkshed Death Knot is not the final Death Race-only track")
assert(crossfire.reward==350e3 and crossfire.scale==4)
assert(crossfire.id=="death_knot")
assert(crossfire.contestants==12 and crossfire.team_size==2
   and crossfire.team_min_contestants==6)
assert(type(crossfire.description)=="string" and crossfire.description~="")
assert(#crossfire.track>0)
-- luatk.bezier samples each segment eleven times and gfx.renderLinesH accepts
-- at most 256 vertices in one call.
assert(#crossfire.track<=23,"Death Knot exceeds the track-preview line limit")

local crossovers=0
for _index,segment in ipairs(crossfire.track) do
   if segment[1].x==0 and segment[1].y==0 then crossovers=crossovers+1 end
end
assert(crossovers==5,"Death Knot does not revisit its central killbox five times")

local function point_on_segment ( segment, t )
   local p0=segment[1]
   local p1=p0+segment[2]
   local p3=segment[4]
   local p2=p3+segment[3]
   local u=1-t
   return p0*(u^3)+p1*(3*u*u*t)+p2*(3*u*t*t)+p3*(t^3)
end

local checkpoint_previous
for index,segment in ipairs(crossfire.track) do
   local following=crossfire.track[index%#crossfire.track+1]
   assert(segment[4]:dist(following[1])==0,
      "adjacent Bézier segments do not meet")
   assert(segment[1]:dist(segment[4])>0,"degenerate Bézier segment")

   local sample_previous=point_on_segment(segment,0)
   for step=1,200 do
      local position=point_on_segment(segment,step/200)
      assert(position:dist(sample_previous)>0,"degenerate sampled interval")
      sample_previous=position
      if not checkpoint_previous or position:dist(checkpoint_previous)>500 then
         if checkpoint_previous then
            assert(position:dist(checkpoint_previous)>500,
               "degenerate generated checkpoint interval")
         end
         checkpoint_previous=position
      end
   end
end

assert(crossfire.track[#crossfire.track][4]:dist(crossfire.track[1][1])==0,
   "final Bézier segment does not close the loop")

print("ok - death race track definitions")
