-- Pod Racing shares Qex's established courses without mutating the canonical
-- module table, then adds combat-oriented courses of its own.
local canonical = require "missions.neutral.race.tracks_qex"
local tracks = {}
for index,track in ipairs(canonical) do tracks[index]=track end

-- Converts a closed Catmull-Rom path to the relative-control-point cubic
-- Bézier representation used by Naev's race tracks.
local function closed_bezier ( points, tension )
   local segments = {}
   local count = #points
   for index,current in ipairs(points) do
      local previous = points[(index-2)%count+1]
      local following = points[index%count+1]
      local after = points[(index+1)%count+1]
      local control_out = current+(following-previous)*(tension/3)
      local control_in = following-(after-current)*(tension/3)
      segments[index] = {
         current,
         control_out-current,
         control_in-following,
         following,
      }
   end
   return segments
end

local crossfire_points = {
   -- Launch chute.
   vec2.new(-1500,-650),
   vec2.new(-700,-250),
   vec2.new(0,0),
   -- Broad eastern lobe: the opening overtaking arena.
   vec2.new(650,500),
   vec2.new(1300,350),
   vec2.new(1500,0),
   vec2.new(1300,-350),
   vec2.new(650,-500),
   vec2.new(0,0),
   -- Tight northern slingshot.
   vec2.new(-450,650),
   vec2.new(0,1200),
   vec2.new(450,650),
   vec2.new(0,0),
   -- Broad western lobe, returning traffic toward the leaders.
   vec2.new(-650,500),
   vec2.new(-1300,350),
   vec2.new(-1500,0),
   vec2.new(-1300,-350),
   vec2.new(-650,-500),
   vec2.new(0,0),
   -- Tight southern slingshot.
   vec2.new(450,-650),
   vec2.new(0,-1200),
   vec2.new(-450,-650),
   vec2.new(0,0),
   -- A deliberately asymmetric revenge gauntlet and diagonal crossover.
   vec2.new(850,250),
   vec2.new(1400,650),
   vec2.new(300,450),
   vec2.new(-300,-450),
   vec2.new(-1400,-650),
}

tracks[#tracks+1] = {
   name=N_("Melendez Death Knot"),
   description=N_("Four combat lobes revisit a central killbox before a diagonal revenge gauntlet and final sprint."),
   reward=350e3,
   scale=4,
   centre=true,
   centre_offset=vec2.new(0,9000),
   track=closed_bezier(crossfire_points,0.55),
}

return tracks
