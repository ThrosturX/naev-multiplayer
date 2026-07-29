local Transient = require "multiplayer.p2p.transient"
local fmt = require "format"

local communications = {}

local SHORT_RANGE = 2
local WIDE_SYSTEM_CAP = 8
local TRANSMITTER_SHIP = "Distress Beacon"

local OUTFIT_SNIFFER = "Communications Sniffer"
local OUTFIT_SHORT = "Short-Range Communications Sniffer"
local OUTFIT_WIDE = "Wide-Area Communications Sniffer"
local OUTFIT_SUITE = "Augmented Communications Suite"

local wide_cache = {
   received=nil,
   current=nil,
   systems={},
}
local remote_senders = {}

local function display_text ( text )
   return tostring(text):gsub("#","＃")
end

local function fitted_capabilities ()
   local p=player.pilot()
   if not p then return end
   local capabilities={}
   for _slot,o in pairs(p:outfits()) do
      local name=o and o:nameRaw()
      if name==OUTFIT_SNIFFER then
         capabilities.receive_any=true
      elseif name==OUTFIT_SHORT then
         capabilities.receive_short=true
      elseif name==OUTFIT_WIDE then
         capabilities.receive_wide=true
      elseif name==OUTFIT_SUITE then
         capabilities.receive_short=true
         capabilities.send=true
      end
   end
   if next(capabilities) then return capabilities end
end

local function jump_distance ( source_name )
   local origin=system.cur()
   local source=system.exists(source_name)
   if not origin or not source then return end
   local distance=origin:jumpDist(source,false,true)
   if not distance or distance==math.huge then return end
   return math.floor(distance)
end

local function refresh_wide_cache ( current_name )
   local snapshot=naev.cache().multiplayer_activity
   if type(snapshot)~="table" or type(snapshot.received)~="number"
         or type(snapshot.entries)~="table" then
      wide_cache.received=nil
      wide_cache.current=current_name
      wide_cache.systems={}
      return
   end
   if wide_cache.received==snapshot.received
         and wide_cache.current==current_name then return end
   local systems={}
   local count=0
   for _index,entry in ipairs(snapshot.entries) do
      if count>=WIDE_SYSTEM_CAP then break end
      if entry.active and entry.system~=current_name and not systems[entry.system] then
         systems[entry.system]=true
         count=count+1
      end
   end
   wide_cache.received=snapshot.received
   wide_cache.current=current_name
   wide_cache.systems=systems
end

local function wide_receives ( source_name, current_name )
   refresh_wide_cache(current_name)
   return wide_cache.systems[source_name]==true
end

local function local_transmitter_owner ()
   local config=naev.cache().multiplayer_p2p_config
   local node=type(config)=="table" and config.node_id or nil
   if type(node)=="string" and node:match("^[%x]+$") then return node.."a" end
end

function communications.observe ( message, direct_name )
   if type(message)~="table" then return false end
   local kind=message.type
   if kind~="chat" and kind~="player_manifest" and kind~="leave" then
      return false
   end
   if player.isLanded() then return false end
   local capabilities=fitted_capabilities()
   if not capabilities then return false end

   if kind=="player_manifest" then
      if type(message.owner)=="string" and type(message.name)=="string"
            and message.name~="" then
         remote_senders[message.owner]={
            name=message.name,
            augmented=type(message.origin)=="string"
               and message.origin:match("%.communications$")~=nil,
         }
      end
      return false
   elseif kind=="leave" then
      if type(message.owner)=="string" then remote_senders[message.owner]=nil end
      return false
   elseif type(message.system)~="string"
         or type(message.text)~="string" then return false end

   if message.owner==local_transmitter_owner() then return false end

   local current=system.cur()
   local current_name=current and current:nameRaw()
   if not current_name or message.system==current_name then return false end

   local accepted=capabilities.receive_any==true
   if not accepted and capabilities.receive_short then
      local distance=jump_distance(message.system)
      accepted=distance~=nil and distance<=SHORT_RANGE
   end
   if not accepted and capabilities.receive_wide then
      accepted=wide_receives(message.system,current_name)
   end
   if not accepted then return false end

   local record=remote_senders[message.owner]
   local sender=record and record.name or direct_name or _("Unknown transmitter")
   local label=record and record.augmented and display_text(sender)
      or fmt.f(_("[{system}] {sender}"),{
         system=_(message.system),sender=display_text(sender),
      })
   pilot.comm(label,display_text(message.text))
   return true
end

local function gate_position ( origin_name, target_name )
   local origin=system.get(origin_name)
   local target=system.get(target_name)
   local path=origin:jumpPath(target)
   local final_jump=path and path[#path]
   if not final_jump then return 0,0 end
   return final_jump:reverse():pos():get()
end

local function active_targets ( origin_name, active_systems )
   local targets={}
   local seen={}
   local origin=system.get(origin_name)
   for _index,system_name in ipairs(active_systems) do
      if system_name~=origin_name and not seen[system_name] then
         seen[system_name]=true
         local target=system.exists(system_name)
         local distance=target and origin:jumpDist(target,false,true)
         if distance and distance<=SHORT_RANGE then
            targets[#targets+1]={system=system_name,distance=distance}
         end
      end
   end
   table.sort(targets,function ( a, b )
      if a.distance~=b.distance then return a.distance<b.distance end
      return a.system<b.system
   end)
   return targets
end

local function local_sender_name ()
   local p=player.pilot()
   local name=p and p:name() or nil
   if type(name)=="string" and name~="" then return name end
   return player.name()
end

function communications.send ( text, settings )
   local capabilities=fitted_capabilities()
   if not capabilities or not capabilities.send or Transient.active() then
      return false
   end
   if player.isLanded() or type(text)~="string" or text==""
         or type(settings)~="table" or settings.enabled~=true
         or type(settings.directory)~="string" or settings.directory==""
         or type(settings.node_id)~="string"
         or not settings.node_id:match("^[%x]+$") then return false end
   local current=system.cur()
   local origin=current and current:nameRaw()
   if not origin then return false end

   local ok=Transient.start{
      kind="augmented_communications",
      directory=settings.directory,
      node_id=settings.node_id,
      node_suffix="a",
      origin_suffix=".communications",
      ship=TRANSMITTER_SHIP,
      name=fmt.f(_("[{system}] {captain}"),{
         system=_(origin),captain=local_sender_name(),
      }),
      text=text:sub(1,1024),
      target_systems=function ( systems )
         return active_targets(origin,systems)
      end,
      position=function ( target )
         return gate_position(origin,target.system)
      end,
      on_error=function ( err )
         print("P2P: augmented communications: "..tostring(err))
      end,
      unsupported=_("The multiplayer directory does not provide activity data."),
   }
   return ok==true
end

function communications.active ()
   return Transient.active("augmented_communications")
end

function communications.update ()
   if communications.active() then Transient.update() end
end

function communications.stop ()
   Transient.stop("augmented_communications")
   remote_senders={}
   wide_cache.received=nil
   wide_cache.current=nil
   wide_cache.systems={}
end

return communications
