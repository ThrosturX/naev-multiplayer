package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local clock=100
local cache={}
_G._=function(value) return value end
_G.naev={cache=function() return cache end}
_G.player={
   isLanded=function() return false end,
   pilot=function() return {exists=function() return true end} end,
}
local random=0
_G.rnd={rnd=function()
   random=random+1
   return random
end}

local Base={}
Base.__index=Base
function Base.new ( options )
   return setmetatable({
      settings={node_id="a1"},
      pending_requests={},
      running=true,
      current_system=options.current_system,
      now=function() return clock end,
      request_sequence=0,
   },Base)
end
function Base:peer () return true end
function Base:next_request ()
   self.request_sequence=self.request_sequence+1
   return self.request_sequence
end
function Base:send_create ( request, pending )
   self.sent_request=request
   self.sent_pending=pending
   return true
end
function Base.spawn () return false end
function Base.remove_local () return false end
function Base.clear_local () end
function Base.finish_query () end
function Base.complete_create () end
function Base.fail_create () end
function Base.update () return true end
function Base.stop () return true end

package.preload["multiplayer.p2p.object_runtime"]=function() return Base end
package.preload["multiplayer.p2p.objects"]=function()
   return {encode=function(object)
      assert(object.kind=="one_way_wormhole" or object.kind=="two_way_wormhole")
      return "packed"
   end}
end
package.preload["multiplayer.p2p.wormhole_runtime"]=function()
   return {new=function()
      return {
         spawn=function() return false end,
         remove_object=function() return false end,
         leave=function() end,
         reconcile=function() end,
      }
   end}
end
package.preload["multiplayer.p2p.wormhole_objects"]=function()
   return {is_wormhole=function() return false end}
end

local Runtime=require "multiplayer.p2p.wormhole_extension"

local function request ( object_kind, generator )
   return {
      object_kind=object_kind,
      generator=generator,
      activation_id=generator.."_1",
      source_system="Halir",source_x=1,source_y=2,source_dir=3,
      target_system="Arandon",target_x=4,target_y=5,target_dir=6,
      fuel_cost=600,energy_cost=600,
   }
end

local one_way=Runtime.new{current_system=function() return "Halir" end}
assert(one_way:create_wormhole(request("one_way_wormhole","emergency")))
local emergency=one_way.sent_pending
assert(emergency.object.kind=="one_way_wormhole")
assert(emergency.generator=="emergency")
assert(emergency.object.endpoints[1].role=="entrance")
assert(emergency.object.endpoints[1].visible==true)
assert(emergency.object.endpoints[1].target==emergency.object.endpoints[2].id)
assert(emergency.object.endpoints[2].role=="destination")
assert(emergency.object.endpoints[2].visible==false)
assert(emergency.object.endpoints[2].target==nil)

cache.multiplayer_wormhole_pending=nil
local two_way=Runtime.new{current_system=function() return "Halir" end}
assert(two_way:create_wormhole(request("two_way_wormhole","unstable")))
local unstable=two_way.sent_pending
assert(unstable.object.kind=="two_way_wormhole")
assert(unstable.object.endpoints[1].role=="mouth")
assert(unstable.object.endpoints[2].role=="mouth")
assert(unstable.object.endpoints[1].target==unstable.object.endpoints[2].id)
assert(unstable.object.endpoints[2].target==unstable.object.endpoints[1].id)

print("ok - one-way and two-way wormhole creation")
