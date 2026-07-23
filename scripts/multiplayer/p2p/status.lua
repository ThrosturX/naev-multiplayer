-- Local HUD countdowns derived from P2P session state.
local status = {}
status.__index = status

local HOST_ALONE_EFFECT = "Multiplayer: Autonav Pending"
local AGGRESSION_EFFECT = "Multiplayer: Aggression"

function status.new ( pilot_get )
   return setmetatable({pilot_get=pilot_get},status)
end

local function remove_effect ( self, name )
   local p=self.pilot_get()
   if p then p:effectRm(name,true) end
end

function status:clear_host_alone ()
   if not self.host_alone_deadline then return end
   remove_effect(self,HOST_ALONE_EFFECT)
   self.host_alone_deadline=nil
end

function status:host_alone ( deadline, stamp )
   if not deadline or deadline<=stamp then
      self:clear_host_alone()
      return
   end
   if self.host_alone_deadline==deadline then return end
   local p=self.pilot_get()
   if p then p:effectAdd(HOST_ALONE_EFFECT,deadline-stamp) end
   self.host_alone_deadline=deadline
end

function status:clear_aggression ()
   if not self.aggression_deadline then return end
   remove_effect(self,AGGRESSION_EFFECT)
   self.aggression_deadline=nil
end

local function show_aggression ( self, deadline, stamp, reconcile_deadline )
   if not deadline or deadline<=stamp then
      self:clear_aggression()
      return
   end
   local old=self.aggression_deadline
   if old and not reconcile_deadline and deadline-old<1 then return end
   if old and reconcile_deadline and math.abs(deadline-old)<1e-6 then return end
   local p=self.pilot_get()
   if p then
      -- Naev deliberately refuses to replace an identical effect with a
      -- shorter duration. Remove it first when the aggregate deadline moves
      -- back to an earlier live aggression timer.
      if old and deadline<old then p:effectRm(AGGRESSION_EFFECT,true) end
      p:effectAdd(AGGRESSION_EFFECT,deadline-stamp)
   end
   self.aggression_deadline=deadline
end

function status:mark_aggression ( deadline, stamp )
   show_aggression(self,deadline,stamp,false)
end

function status:reconcile_aggression ( deadline, stamp )
   show_aggression(self,deadline,stamp,true)
end

function status:clear ()
   remove_effect(self,HOST_ALONE_EFFECT)
   remove_effect(self,AGGRESSION_EFFECT)
   self.host_alone_deadline=nil
   self.aggression_deadline=nil
end

return status
