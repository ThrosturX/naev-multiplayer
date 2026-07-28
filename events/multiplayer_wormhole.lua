--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Multiplayer Wormhole">
 <location>none</location>
 <chance>0</chance>
</event>
--]]
local audio = require "love.audio"
local lf = require "love.filesystem"
local pp_shaders = require "pp_shaders"

local pixelcode=lf.read("shaders/love/wormhole_travel.frag")
local target_system,target_pos,colour,shader,r
local sfx=audio.newSource("snd/sounds/wormhole")

function create ()
   local cache=naev.cache()
   local travel=cache.multiplayer_wormhole_travel
   cache.multiplayer_wormhole_travel=nil
   if type(travel)~="table" or type(travel.system)~="string"
         or type(travel.x)~="number" or type(travel.y)~="number" then
      local p=player.pilot()
      if p and p:exists() then p:shipvarPop("wormhole") end
      return evt.finish(false)
   end
   target_system=system.get(travel.system)
   target_pos=vec2.new(travel.x,travel.y)
   colour={0.0,0.8,1.0}
   hook.update("update")
   sfx:play()
   shader=pp_shaders.newShader(pixelcode)
   shader:send("u_col_outter",colour)
   shader.addPPShader(shader,"final")
   r=-rnd.rnd()*1000
end

local timer=0
local jumped=false
local jumptime=2.0
function update ( _dt, real_dt )
   timer=timer+real_dt
   shader:send("u_time",timer+r)
   shader:send("u_progress",math.min(timer/jumptime,1.0))
   if timer<jumptime then return end
   if not jumped then
      jumped=true
      r=r+timer
      timer=0
      shader:send("u_progress",0)
      shader:send("u_invert",1)
      hook.safe("wormhole_jump")
      return
   end
   shader.rmPPShader(shader)
   evt.finish()
end

function wormhole_jump ()
   time.inc(time.new(0,0,1000+2000*rnd.rnd()))
   player.teleport(target_system)
   local p=player.pilot()
   p:setPos(target_pos+vec2.newP(100+100*rnd.rnd(),rnd.angle()))
   p:shipvarPop("wormhole")
   p:effectAdd("Wormhole Exit")
end
