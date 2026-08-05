package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

_=function ( value ) return value end

package.preload["format"]=function ()
   return {f=function ( template, values )
      return (template:gsub("{([%w_]+)}",function ( key )
         return tostring(values[key])
      end))
   end}
end

local outfit_names={}
local outfit_tags={
   ["Communications Sniffer"]={multiplayer_receive_relay=true},
   ["Short-Range Communications Sniffer"]={
      ["multiplayer_receive_range=2"]=true,
   },
   ["Wide-Area Communications Sniffer"]={
      ["multiplayer_wide_system_cap=8"]=true,
   },
   ["Augmented Communications Suite"]={
      ["multiplayer_receive_range=2"]=true,
      ["multiplayer_send_range=2"]=true,
   },
   ["Extended Communications Suite"]={
      ["multiplayer_receive_range=5"]=true,
      ["multiplayer_send_range=5"]=true,
   },
}
local landed=false
local comms={}
local activity={received=1,entries={}}
local config={node_id="a1"}
local systems={}

local function outfit ( name )
   return {
      nameRaw=function () return name end,
      tags=function () return outfit_tags[name] or {} end,
   }
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
         exists=function () return true end,
         outfits=function () return fitted end,
         actives=function ()
            local actives={}
            for index,name in ipairs(outfit_names) do
               actives[index]={outfit=outfit(name),active=true}
            end
            return actives
         end,
         name=function () return "Zebra" end,
      }
   end,
   isLanded=function () return landed end,
   name=function () return "Tester" end,
   msg=function ( text ) comms[#comms+1]=text end,
}
pilot={}
naev={cache=function () return {
   multiplayer_activity=activity,
   multiplayer_p2p_config=config,
} end}
system={
   cur=function () error("communications receive path must not call system.cur") end,
   exists=function ( name ) return systems[name] end,
   get=function ( name ) return assert(systems[name]) end,
}

local communications=require "multiplayer.p2p.communications"

local function reset ( names )
   outfit_names=names
   comms={}
end

systems.Far={distance=9}
local old_pilot=player.pilot
player.pilot=function () return {exists=function () return false end} end
assert(not communications.observe({
   type="chat",system="Far",text="during load",owner="b2",
},nil,"Origin"))
player.pilot=old_pilot
reset{"Communications Sniffer"}
local capabilities=assert(communications._fitted_capabilities())
assert(capabilities.receive_relay and not capabilities.receive_range)

systems.Near={distance=2}
systems.TooFar={distance=3}
reset{"Short-Range Communications Sniffer"}
assert(communications.observe({type="chat",system="Near",text="near",owner="c3"},"Direct","Origin"))
assert(not communications.observe({type="chat",system="TooFar",text="far",owner="c3"},"Direct","Origin"))
assert(#comms==1 and comms[1]=='Comm Direct (2 jumps)> "near"')

activity={received=2,entries={}}
for index=1,9 do
   local name="Active"..index
   systems[name]={distance=index}
   activity.entries[#activity.entries+1]={system=name,active=true}
end
reset{"Wide-Area Communications Sniffer"}
capabilities=assert(communications._fitted_capabilities())
assert(capabilities.wide_system_cap==8 and not capabilities.receive_range)

reset{"Augmented Communications Suite"}
assert(not communications.observe({
   type="player_manifest",system="Near",owner="e5",
   name="[Far] Relay",origin="e5.visit.communications",
},nil,"Origin"))
assert(communications.observe({
   type="chat",system="Near",text="relayed",owner="e5",
},nil,"Origin"))
assert(#comms==1 and comms[1]=='Comm [Far] Relay> "relayed"')
comms={}
assert(not communications.observe({
   type="chat",system="Near",text="echo",owner="a1a",
},nil,"Origin"))
assert(#comms==0)
capabilities=assert(communications._fitted_capabilities())
assert(capabilities.receive_range==2 and capabilities.send_range==2)
assert(capabilities.transmit_active)

systems.Five={distance=5}
systems.Six={distance=6}
reset{"Extended Communications Suite"}
assert(communications.observe({
   type="chat",system="Five",text="five",owner="f6",
},"Direct","Origin"))
assert(not communications.observe({
   type="chat",system="Six",text="six",owner="f6",
},"Direct","Origin"))
capabilities=assert(communications._fitted_capabilities())
assert(capabilities.receive_range==5 and capabilities.send_range==5)
assert(capabilities.transmit_active)

print("communications tests passed")
