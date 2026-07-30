package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local Status=require "multiplayer.p2p.status"

assert(Status.UPDATE_INTERVAL<=0.1,
   "status cadence is too slow for the fast countdown blink")

local active={}
local shown={}
local pilot={}
function pilot.effectAdd ( _self, name, remaining )
   active[name]=remaining
   shown[#shown+1]=name
end
function pilot.effectRm ( _self, name )
   active[name]=nil
end

local status=Status.new(function () return pilot end)
status:host_alone(6,0)
assert(shown[#shown]=="Multiplayer: Autonav Pending")
status:update(3.4)
assert(shown[#shown]=="Multiplayer: Autonav Pending Dim")
status:update(3.9)
assert(shown[#shown]=="Multiplayer: Autonav Pending")
status:update(5.1)
assert(shown[#shown]=="Multiplayer: Autonav Pending Dim")
status:update(5.3)
assert(shown[#shown]=="Multiplayer: Autonav Pending")
status:update(6)
assert(not active["Multiplayer: Autonav Pending"]
   and not active["Multiplayer: Autonav Pending Dim"])

shown={}
status:mark_aggression(20,0)
assert(shown[#shown]=="Multiplayer: Aggression")
status:update(15.4)
assert(shown[#shown]=="Multiplayer: Aggression Dim")
status:update(15.9)
assert(shown[#shown]=="Multiplayer: Aggression")
status:update(19.1)
assert(shown[#shown]=="Multiplayer: Aggression Dim")
status:update(19.3)
assert(shown[#shown]=="Multiplayer: Aggression")

print("ok - P2P status timers reach bright and dim blink phases")
