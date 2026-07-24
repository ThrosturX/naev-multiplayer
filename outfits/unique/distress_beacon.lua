local distress = require "multiplayer.distress"

local COOLDOWN = 30
local DISABLED_RANGE = 16
local DEFAULT_RANGE = 8

local CLASS_RANGE = {
   ["Yacht"] = 4,
   ["Scout"] = 4,
   ["Interceptor"] = 4,
   ["Fighter"] = 4,
   ["Courier"] = 6,
   ["Bomber"] = 6,
   ["Corvette"] = 6,
   ["Freighter"] = 8,
   ["Armoured Transport"] = 8,
   ["Destroyer"] = 8,
   ["Bulk Freighter"] = 10,
   ["Cruiser"] = 10,
   ["Battleship"] = 12,
   ["Carrier"] = 12,
}

local function transmission_range ( p )
   if p:disabled() then return DISABLED_RANGE end
   return CLASS_RANGE[p:ship():class()] or DEFAULT_RANGE
end

local function start_cooldown ( po )
   mem.timer = COOLDOWN
   po:state("cooldown")
   po:progress(1)
end

local function deploy ( p, po, force )
   if mem.timer and not force then return false end

   local config = naev.cache().multiplayer_p2p_config
   if type(config) ~= "table" then
      player.msg("#r".._("Multiplayer session state is unavailable.").."#0")
      return false
   end

   local ok, err = distress.send{
      range = transmission_range(p),
      enabled = config.enabled,
      directory = config.directory,
      node_id = config.node_id,
      ship_name = p:name(),
   }
   if not ok then
      player.msg("#r"..tostring(err).."#0")
      return false
   end

   start_cooldown(po)
   return true
end

function init( p, po )
   if p ~= player.pilot() then return end

   mem.timer = nil
   mem.was_disabled = p:disabled()
   po:state("off")
   po:progress(0)
end

function update( p, po, dt )
   if p ~= player.pilot() then return end

   distress.update(dt)

   local disabled = p:disabled()
   if disabled and not mem.was_disabled then
      mem.was_disabled = true
      if not distress.active() then
         deploy(p, po, true)
      end
   elseif not disabled then
      mem.was_disabled = false
   end

   if not mem.timer then return end

   mem.timer = mem.timer-dt
   po:progress(math.max(0, mem.timer/COOLDOWN))

   if mem.timer <= 0 then
      mem.timer = nil
      po:state("off")
      po:progress(0)
   end
end

function ontoggle( p, po, on )
   if p ~= player.pilot() or not on then
      return false
   end
   return deploy(p, po, false)
end
