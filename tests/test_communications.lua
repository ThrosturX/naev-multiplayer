package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

_=function ( value ) return value end

local started
local transient_active
package.preload["multiplayer.p2p.transient"]=function ()
   return {
      active=function ( kind )
         if kind then return transient_active==kind end
         return transient_active~=nil
      end,
      start=function ( params )
         started=params
         transient_active=params.kind
         return true
      end,
      update=function () end,
      stop=function ( kind )
         if not kind or transient_active==kind then transient_active=nil end
      end,
   }
end
package.preload["format"]=function ()
   return {f=function ( template, values )
      return (template:gsub("{([%w_]+)}",function ( key )
         return tostring(values[key])
      end))
   end}
end

local outfit_names={}
local landed=false
local comms={}
local activity={received=1,entries={}}
local config={node_id="a1"}
local systems={}

local function outfit ( name )
   return {nameRaw=function () return name end}
end

local current={
   nameRaw=function () return "Origin" end,
   jumpDist=function ( _self, target ) return target.distance end,
   jumpPath=function () return nil end,
}
systems.Origin=current

player={
   pilot=function ()
      local fitted={}
      for index,name in ipairs(outfit_names) do fitted[index]=outfit(name) end
      return {
         outfits=function () return fitted end,
         name=function () return "Zebra" end,
      }
   end,
   isLanded=function () return landed end,
   name=function () return "Tester" end,
}
pilot={comm=function ( sender, text )
   comms[#comms+1]={sender=sender,text=text}
end}
naev={cache=function () return {
   multiplayer_activity=activity,
   multiplayer_p2p_config=config,
} end}
system={
   cur=function () return current end,
   exists=function ( name ) return systems[name] end,
   get=function ( name ) return assert(systems[name]) end,
}

local communications=require "multiplayer.p2p.communications"

local function reset ( names )
   outfit_names=names
   comms={}
end

systems.Far={distance=9}
reset{"Communications Sniffer"}
assert(not communications.observe({
   type="player_manifest",system="Far",owner="b2",name="Peer",
}))
assert(communications.observe({
   type="chat",system="Far",text="hello",owner="b2",
}))
assert(#comms==1 and comms[1].sender=="[Far] Peer")

systems.Near={distance=2}
systems.TooFar={distance=3}
reset{"Short-Range Communications Sniffer"}
assert(communications.observe({type="chat",system="Near",text="near",owner="c3"},"Direct"))
assert(not communications.observe({type="chat",system="TooFar",text="far",owner="c3"},"Direct"))
assert(#comms==1 and comms[1].sender=="[Near] Direct")

activity={received=2,entries={}}
for index=1,9 do
   local name="Active"..index
   systems[name]={distance=index}
   activity.entries[#activity.entries+1]={system=name,active=true}
end
reset{"Wide-Area Communications Sniffer"}
assert(communications.observe({type="chat",system="Active8",text="yes",owner="d4"}))
assert(not communications.observe({type="chat",system="Active9",text="no",owner="d4"}))
assert(#comms==1 and comms[1].sender=="[Active8] Unknown transmitter")

reset{"Augmented Communications Suite"}
assert(not communications.observe({
   type="player_manifest",system="Near",owner="e5",
   name="[Far] Relay",origin="e5.visit.communications",
}))
assert(communications.observe({
   type="chat",system="Near",text="relayed",owner="e5",
}))
assert(#comms==1 and comms[1].sender=="[Far] Relay")
comms={}
assert(not communications.observe({
   type="chat",system="Near",text="echo",owner="a1a",
}))
assert(#comms==0)
assert(communications.send("broadcast",{
   enabled=true,directory="directory:1",node_id="a1",
}))
assert(started.kind=="augmented_communications")
assert(started.name=="[Origin] Zebra")
assert(started.text=="broadcast")
local targets=started.target_systems{"TooFar","Near","Origin"}
assert(#targets==1 and targets[1].system=="Near")
communications.stop()

print("communications tests passed")
