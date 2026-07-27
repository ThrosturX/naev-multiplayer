-- Death Race reuses Qex's established course shapes without mutating the
-- canonical module table, then adds a combat-oriented course of its own.
-- Stable internal IDs are retained for existing directory contestant records.
local canonical = require "missions.neutral.race.tracks_qex"
local tracks = {}
local canonical_contestants = {4,6,8}
local canonical_ids = {"peninsula","smiling_man","qex_tour"}
for index,track in ipairs(canonical) do
   local copy={}
   for key,value in pairs(track) do copy[key]=value end
   copy.contestants=canonical_contestants[index]
   copy.id=canonical_ids[index]
   if index==3 then
      copy.name=N_("Alteris Tour")
      copy.centre=true
   end
   tracks[index]=copy
end

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
   vec2.new(0,0),
   -- Broad eastern lobe: the opening overtaking arena.
   vec2.new(1300,350),
   vec2.new(1500,0),
   vec2.new(1300,-350),
   vec2.new(0,0),
   -- Tight northern slingshot.
   vec2.new(-450,650),
   vec2.new(0,1200),
   vec2.new(450,650),
   vec2.new(0,0),
   -- Broad western lobe, returning traffic toward the leaders.
   vec2.new(-1300,350),
   vec2.new(-1500,0),
   vec2.new(-1300,-350),
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
   id="death_knot",
   name=N_("Darkshed Death Knot"),
   description=N_("Large fields form random two-pilot teams to fight through four combat lobes, a central killbox, and a diagonal revenge gauntlet."),
   reward=350e3,
   contestants=12,
   team_size=2,
   team_min_contestants=6,
   scale=4,
   centre=true,
   centre_offset=vec2.new(0,9000),
   track=closed_bezier(crossfire_points,0.55),
}

return tracks
