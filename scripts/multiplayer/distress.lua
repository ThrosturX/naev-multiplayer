local Transient = require "multiplayer.p2p.transient"
local fmt = require "format"

local distress = {}

local BEACON_SHIP = "Distress Beacon"
local BEACON_NAME = "Automated Distress Relay"

local function gate_position ( origin_name, target_name )
   local origin = system.get(origin_name)
   local target = system.get(target_name)
   local path = origin:jumpPath(target)
   local final_jump = path and path[#path]
   if not final_jump then return 0, 0 end
   return final_jump:reverse():pos():get()
end

local function active_targets ( origin_name, range, active_systems )
   local targets = {}
   local seen = {}
   local origin = system.get(origin_name)

   for _index, system_name in ipairs(active_systems) do
      if system_name ~= origin_name and not seen[system_name] then
         seen[system_name] = true
         local target = system.exists(system_name)
         if target then
            local distance = origin:jumpDist(target)
            if distance and distance <= range then
               targets[#targets+1] = {
                  system = system_name,
                  distance = distance,
               }
            end
         end
      end
   end

   table.sort(targets, function ( a, b )
      if a.distance ~= b.distance then return a.distance < b.distance end
      return a.system < b.system
   end)
   return targets
end

function distress.stop ()
   Transient.stop("distress")
end

function distress.active ()
   return Transient.active("distress")
end

function distress.send ( params )
   params = params or {}

   if Transient.active() then
      return nil,_("A distress transmission is already in progress.")
   end
   if player.isLanded() then
      return nil,_("The distress beacon can only be used in space.")
   end
   if params.enabled ~= true then
      return nil,_("The distress beacon can only be activated when P2P multiplayer is enabled.")
   end
   if type(params.directory) ~= "string" or params.directory == "" then
      return nil,_("No subspace relay configuration found.")
   end
   if type(params.node_id) ~= "string"
         or not params.node_id:match("^[%x]+$") then
      return nil,_("No multiplayer identity is configured.")
   end
   if type(params.ship_name) ~= "string" or params.ship_name == "" then
      return nil,_("Unable to identify the ship in distress.")
   end

   local origin=system.cur():nameRaw()
   local range=math.max(1,math.floor(tonumber(params.range) or 3))
   return Transient.start{
      kind="distress",
      directory=params.directory,
      node_id=params.node_id,
      node_suffix="b",
      origin_suffix=".player",
      ship=BEACON_SHIP,
      name=BEACON_NAME,
      text=fmt.f(
         _("Automated distress signal: {ship} in {system} requests assistance."),
         {ship=params.ship_name,system=_(origin)}),
      target_systems=function ( systems )
         return active_targets(origin,range,systems)
      end,
      position=function ( target )
         return gate_position(origin,target.system)
      end,
      on_target=function ( target )
         local unit=target.distance==1 and _("jump") or _("jumps")
         player.msg(fmt.f(
            _("Distress beacon successfully deployed {jumps} {unit} away."),
            {jumps=target.distance,unit=unit}))
      end,
      on_empty=function ()
         player.msg("#r".._("The distress beacon completed a round trip in subspace without acknowledgement of receipt. There were no receivers detected in range.").."#0")
      end,
      on_error=function ( err )
         player.msg("#r"..tostring(err).."#0")
      end,
      unsupported=_("The multiplayer directory does not provide activity data."),
      host_error=_("The distress beacon doesn't have a functional transponder.."),
      connect_error=_("The distress beacon doesn't appear to be functional."),
      lost_error=_("Lost connection to the multiplayer directory."),
      timeout_error=_("The multiplayer directory did not answer the distress beacon."),
   }
end

function distress.update ( _dt )
   if Transient.active("distress") then Transient.update() end
end

return distress
