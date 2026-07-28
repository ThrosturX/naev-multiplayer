local Wormholes = require "multiplayer.p2p.wormhole_objects"

local Runtime = {}
Runtime.__index = Runtime

local SPOB_NAME = "multiplayer_wormhole"
local STORAGE_SYSTEM = "Multiplayer Lobby"
local defined_diffs = {}

local function xml_escape ( value )
   return tostring(value)
      :gsub("&","&amp;")
      :gsub("<","&lt;")
      :gsub(">","&gt;")
      :gsub('"',"&quot;")
      :gsub("'","&apos;")
end

local function diff_xml ( name, system_name, endpoint )
   return string.format([[
<unidiff name="%s">
 <spob name="%s">
  <pos_x>%.17g</pos_x>
  <pos_y>%.17g</pos_y>
 </spob>
 <system name="%s">
  <spob_remove>%s</spob_remove>
 </system>
 <system name="%s">
  <spob_add>%s</spob_add>
 </system>
</unidiff>]],
      xml_escape(name),xml_escape(SPOB_NAME),endpoint.x,endpoint.y,
      xml_escape(STORAGE_SYSTEM),xml_escape(SPOB_NAME),
      xml_escape(system_name),xml_escape(SPOB_NAME))
end

function Runtime.new ( options )
   return setmetatable({
      current_system=assert(options.current_system),
      active=nil,
   },Runtime)
end

function Runtime:remove ()
   local active=self.active
   self.active=nil
   local cache=naev.cache()
   cache.multiplayer_wormhole_target=nil
   if active and type(active.diff_name)=="string"
         and diff.isApplied(active.diff_name) then
      diff.remove(active.diff_name)
   end
   local mouth=spob.get(SPOB_NAME)
   if mouth then mouth:setKnown(false) end
   return active~=nil
end

function Runtime:spawn ( object )
   local system_name=self:current_system()
   local endpoint=Wormholes.endpoint_in(object,system_name)
   local target=Wormholes.target_of(object,endpoint)
   if not endpoint or not target then return false end

   local active=self.active
   if active and active.object_id==object.id
         and active.revision==object.revision
         and active.endpoint_id==endpoint.id
         and diff.isApplied(active.diff_name) then
      return true
   end
   self:remove()

   local diff_name=table.concat({
      "MP2P Wormhole",object.id,tostring(object.revision),endpoint.id,
   }," ")

   if not diff.isApplied(diff_name) then
      if defined_diffs[diff_name] then
         diff.apply(diff_name)
      else
         if not diff.newDynamic(
               diff_xml(diff_name,system_name,endpoint)) then
            error("Unable to create unstable wormhole diff: "..diff_name)
         end
         defined_diffs[diff_name]=true
      end
   end

   if not diff.isApplied(diff_name) then
      error("Unable to apply unstable wormhole diff: "..diff_name)
   end

   self.active={
      object_id=object.id,
      revision=object.revision,
      endpoint_id=endpoint.id,
      diff_name=diff_name,
   }
   naev.cache().multiplayer_wormhole_target={
      object_id=object.id,
      system=target.system,
      x=target.x,
      y=target.y,
   }
   local mouth=spob.get(SPOB_NAME)
   if mouth then mouth:setKnown(true) end
   return true
end

function Runtime:remove_object ( object_id )
   if not self.active or self.active.object_id~=object_id then return false end
   return self:remove()
end

function Runtime:reconcile ( objects )
   local selected
   local system_name=self:current_system()
   for _id,object in pairs(objects or {}) do
      if Wormholes.endpoint_in(object,system_name)
            and (not selected or object.id<selected.id) then
         selected=object
      end
   end
   if selected then return self:spawn(selected) end
   self:remove()
   return false
end

function Runtime:leave ()
   self:remove()
end

return Runtime
