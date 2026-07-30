package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

package.preload.enet=function () return {} end
package.preload.format=function ()
   return {f=function ( template ) return template end}
end

local communications=require "multiplayer.p2p.communications"
local owns=communications._owns_target_observation

assert(not communications.owns_observation{
   system="Arandon",epoch="a1:a1:1",
},
   "communications claimed a system without a runtime")
assert(not owns(nil))
assert(not owns({peer={},verified=false,ready=true,epoch="a1:a1:1"},
   "a1:a1:1"))
assert(not owns({peer=nil,verified=true,ready=true,epoch="a1:a1:1"},
   "a1:a1:1"))
assert(not owns({peer={},verified=true,ready=false,epoch="a1:a1:1"},
   "a1:a1:1"))
assert(not owns({peer={},verified=true,ready=true,epoch="a1:a1:1"},
   "b2:b2:2"))
assert(owns({peer={},verified=true,ready=true,epoch="a1:a1:1"},
   "a1:a1:1"),
   "ready dedicated target did not own observation")

print("ok - communications paths have one local observation owner")
