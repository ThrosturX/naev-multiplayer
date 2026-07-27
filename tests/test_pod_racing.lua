package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

N_=function(s) return s end
_=function(s) return s end

local pod=require "multiplayer.pod_racing"

assert(pod.division_for_size(1)==1 and pod.division_for_size(2)==1)
assert(pod.division_for_size(3)==2 and pod.division_for_size(4)==2)
assert(pod.division_for_size(5)==3 and pod.division_for_size(6)==3)
assert(not pod.division_for_size(0) and not pod.division_for_size(7))

assert(pod.boost_desired(false,math.rad(64),16))
assert(not pod.boost_desired(false,math.rad(65),16))
assert(not pod.boost_desired(false,0,15))
assert(pod.boost_desired(true,math.rad(84),6))
assert(not pod.boost_desired(true,math.rad(85),100))
assert(not pod.boost_desired(true,0,5))

local random_values={3,1}
local teams,team_by_slot=assert(pod.random_teams(4,function(first,last)
   local value=table.remove(random_values,1)
   assert(value>=first and value<=last)
   return value
end))
assert(#teams==2 and team_by_slot[1] and team_by_slot[2]
   and team_by_slot[3] and team_by_slot[4])
assert(team_by_slot[1]==team_by_slot[3]
   and team_by_slot[1]~=team_by_slot[4])

teams,team_by_slot=assert(pod.random_teams(3,function(first,last)
   assert(first==2 and last==3)
   return 2
end))
assert(#teams==2 and #teams[1]==2 and #teams[2]==1)
assert(team_by_slot[1]==team_by_slot[2]
   and team_by_slot[3]~=team_by_slot[1])
assert(not pod.random_teams(1))
local team_track={team_size=2,team_min_contestants=6}
assert(not pod.uses_teams(team_track,5))
assert(pod.uses_teams(team_track,6))
assert(not pod.uses_teams({},12))

player={name=function() return "Captain A" end}
local config={
   enabled=true,directory="example.test:60939",node_id="a1",
   captain="Captain A",
}
local roster={
   received=100,directory="example.test:60939",node_id="a1",
   captain="Captain A",track="death_knot",divisions={},
}
assert(pod.roster_matches_p2p(config,roster,"death_knot"))
assert(not pod.roster_matches_p2p(config,roster,"peninsula"))
config.captain="Captain B"
assert(not pod.roster_matches_p2p(config,roster))
config.captain="Captain A"
config.enabled=false
assert(not pod.roster_matches_p2p(config,roster))
config.enabled=true
roster.node_id="b2"
assert(not pod.roster_matches_p2p(config,roster))
roster.node_id="a1"
roster.directory="other.test:60939"
assert(not pod.roster_matches_p2p(config,roster))
roster.directory="example.test:60939"

local profiles={
   {contestant="a1",division=1,name="A",ship="Hyena"},
   {contestant="a1",division=1,name="Duplicate",ship="Shark"},
   {contestant="b2",division=2,name="Wrong",ship="Admonisher"},
   {contestant="c3",division=1,name="Bad",ship="Missing"},
}
local function validate ( profile )
   if profile.ship=="Missing" then return nil end
   return profile
end

local selected=pod.opponents(config,roster,1,5,validate,"death_knot")
assert(#selected==0,"enabled P2P without a division roster used fallbacks")

roster.divisions[1]=profiles
selected=pod.opponents(config,roster,1,5,validate,"death_knot")
assert(#selected==1 and selected[1].name=="A",
   "real directory profiles were padded with fallbacks")

config.enabled=false
selected=pod.opponents(config,roster,1,11,validate)
assert(#selected==11 and selected[1].generic and selected[11].generic,
   "disabled P2P did not use the generic field")

print("ok - death race roster selection")
