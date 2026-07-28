package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local Cooldown=require "multiplayer.p2p.wormhole_generator_cooldown"

local cache={}
local pilot={}
local clock=100
_G.naev={
   cache=function() return cache end,
   ticks=function() return clock end,
}
_G.player={pilot=function() return pilot end}

local po={state_value=nil,progress_value=nil}
function po:state ( value ) self.state_value=value end
function po:progress ( value ) self.progress_value=value end

local state={}
Cooldown.init(pilot,po,state,"emergency",120)
assert(po.state_value=="off" and po.progress_value==0)
assert(Cooldown.ready(state,"emergency"))

local first=Cooldown.next_id("emergency")
Cooldown.begin(po,state,"emergency",first)
assert(not Cooldown.ready(state,"emergency"))
Cooldown.update(pilot,po,0,state,"emergency",120)
assert(po.state_value=="cooldown" and po.progress_value==1)
cache.multiplayer_wormhole_activation_result={
   id=first,generator="emergency",ok=false,
}
Cooldown.update(pilot,po,0,state,"emergency",120)
assert(Cooldown.ready(state,"emergency"))
assert(po.state_value=="off" and po.progress_value==0)

local second=Cooldown.next_id("emergency")
Cooldown.begin(po,state,"emergency",second)
cache.multiplayer_wormhole_activation_result={
   id=second,generator="emergency",ok=true,started=clock,
}
Cooldown.update(pilot,po,0,state,"emergency",120)
assert(not Cooldown.ready(state,"emergency"))
assert(po.progress_value==1)
clock=130
Cooldown.update(pilot,po,0,state,"emergency",120)
assert(po.progress_value==0.75)

-- Reinitializing the outfit must preserve the confirmed cooldown.
local reinitialized={}
Cooldown.init(pilot,po,reinitialized,"emergency",120)
assert(not Cooldown.ready(reinitialized,"emergency"))
assert(po.progress_value==0.75)
clock=220
Cooldown.update(pilot,po,0,reinitialized,"emergency",120)
assert(Cooldown.ready(reinitialized,"emergency"))
assert(po.state_value=="off" and po.progress_value==0)

print("ok - wormhole generator cooldown")
