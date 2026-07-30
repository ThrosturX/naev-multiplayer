-- Local HUD countdowns derived from P2P session state.
local status = {}
status.__index = status
status.UPDATE_INTERVAL = 0.1

local HOST_ALONE_EFFECT = "Multiplayer: Autonav Pending"
local HOST_ALONE_DIM_EFFECT = "Multiplayer: Autonav Pending Dim"
local HOST_ALONE_BLINK_AT = 3
local HOST_ALONE_BLINK_HALF_PERIOD = 0.5
local HOST_ALONE_FAST_BLINK_AT = 1
local HOST_ALONE_FAST_BLINK_HALF_PERIOD = 0.16
local AGGRESSION_EFFECT = "Multiplayer: Aggression"
local AGGRESSION_DIM_EFFECT = "Multiplayer: Aggression Dim"
local AGGRESSION_BLINK_AT = 5
local AGGRESSION_BLINK_HALF_PERIOD = 0.5
local AGGRESSION_FAST_BLINK_AT = 1
local AGGRESSION_FAST_BLINK_HALF_PERIOD = 0.25

function status.new ( pilot_get )
   return setmetatable({pilot_get=pilot_get},status)
end

local function remove_effect ( self, name )
   local p=self.pilot_get()
   if p then p:effectRm(name,true) end
end

local function show_host_alone ( self, name, remaining )
   if self.host_alone_effect==name then return end
   local p=self.pilot_get()
   if p then p:effectAdd(name,remaining) end
   self.host_alone_effect=name
end

local function show_aggression_effect ( self, name, remaining )
   if self.aggression_effect==name then return end
   local p=self.pilot_get()
   if p then p:effectAdd(name,remaining) end
   self.aggression_effect=name
end

function status:clear_host_alone ()
   if not self.host_alone_deadline and not self.host_alone_effect then return end
   -- Remove both variants so interrupted swaps cannot leave a stale icon.
   remove_effect(self,HOST_ALONE_EFFECT)
   remove_effect(self,HOST_ALONE_DIM_EFFECT)
   self.host_alone_deadline=nil
   self.host_alone_effect=nil
end

local function update_host_alone ( self, stamp )
   local deadline=self.host_alone_deadline
   if not deadline then return end

   local remaining=deadline-stamp
   if remaining<=0 then
      self:clear_host_alone()
      return
   end

   local name=HOST_ALONE_EFFECT
   if remaining<=HOST_ALONE_BLINK_AT then
      local half_period=HOST_ALONE_BLINK_HALF_PERIOD
      if remaining<=HOST_ALONE_FAST_BLINK_AT then
         half_period=HOST_ALONE_FAST_BLINK_HALF_PERIOD
      end
      local phase=math.floor(remaining/half_period)%2
      if phase==1 then name=HOST_ALONE_DIM_EFFECT end
   end
   show_host_alone(self,name,remaining)
end

local function update_aggression ( self, stamp )
   local deadline=self.aggression_deadline
   if not deadline then return end

   local remaining=deadline-stamp
   if remaining<=0 then
      self:clear_aggression()
      return
   end

   local name=AGGRESSION_EFFECT
   if remaining<=AGGRESSION_BLINK_AT then
      local half_period=AGGRESSION_BLINK_HALF_PERIOD
      if remaining<=AGGRESSION_FAST_BLINK_AT then
         half_period=AGGRESSION_FAST_BLINK_HALF_PERIOD
      end
      local phase=math.floor(remaining/half_period)%2
      if phase==1 then name=AGGRESSION_DIM_EFFECT end
   end
   show_aggression_effect(self,name,remaining)
end

function status:update ( stamp )
   update_host_alone(self,stamp)
   update_aggression(self,stamp)
end

function status:host_alone ( deadline, stamp )
   if not deadline or deadline<=stamp then
      self:clear_host_alone()
      return
   end
   if self.host_alone_deadline==deadline then return end
   self.host_alone_deadline=deadline
   -- Force the new deadline into the currently displayed effect even when its
   -- bright/dim phase happens to match the previous deadline.
   self.host_alone_effect=nil
   self:update(stamp)
end

function status:clear_aggression ()
   if not self.aggression_deadline and not self.aggression_effect then return end
   remove_effect(self,AGGRESSION_EFFECT)
   remove_effect(self,AGGRESSION_DIM_EFFECT)
   self.aggression_deadline=nil
   self.aggression_effect=nil
end

local function show_aggression ( self, deadline, stamp, reconcile_deadline )
   if not deadline or deadline<=stamp then
      self:clear_aggression()
      return
   end
   local old=self.aggression_deadline
   if old and not reconcile_deadline and deadline-old<1 then return end
   if old and reconcile_deadline and math.abs(deadline-old)<1e-6 then return end

   -- Identical effects refuse shorter replacement durations. Remove the active
   -- variant before moving the aggregate deadline backwards.
   if old and deadline<old then
      remove_effect(self,AGGRESSION_EFFECT)
      remove_effect(self,AGGRESSION_DIM_EFFECT)
   end

   self.aggression_deadline=deadline
   -- Force an extension, shortening, or renewed timer into the HUD effect even
   -- if the newly selected bright/dim phase has the same name as before.
   self.aggression_effect=nil
   self:update(stamp)
end

function status:mark_aggression ( deadline, stamp )
   show_aggression(self,deadline,stamp,false)
end

function status:reconcile_aggression ( deadline, stamp )
   show_aggression(self,deadline,stamp,true)
end

function status:clear ()
   remove_effect(self,HOST_ALONE_EFFECT)
   remove_effect(self,HOST_ALONE_DIM_EFFECT)
   remove_effect(self,AGGRESSION_EFFECT)
   remove_effect(self,AGGRESSION_DIM_EFFECT)
   self.host_alone_deadline=nil
   self.host_alone_effect=nil
   self.aggression_deadline=nil
   self.aggression_effect=nil
end

return status
