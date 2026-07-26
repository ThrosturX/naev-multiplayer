--[[
<?xml version='1.0' encoding='utf8'?>
<mission name="Pod Racing">
 <priority>4</priority>
 <chance>100</chance>
 <location>Bar</location>
 <spob>Melendez Dome</spob>
</mission>
--]]
local fmt = require "format"
local pod = require "multiplayer.pod_racing"
local ai_setup = require "ai.core.setup"
local spfxtrack = require "luaspfx.racetrack"
local equip_mplayer = require "equipopt.templates.multiplayer"
local vn = require "vn"
local luatk = require "luatk"
local bezier = require "luatk.bezier"
local luasfx = require "luaspfx.sfx"
local lmisn = require "lmisn"

local tracks = require "multiplayer.pod_racing_tracks"
local rewards = {}
for index,track in ipairs(tracks) do rewards[index]=track.reward or 100e3 end
local start_sfx = audiodata.new("snd/sounds/race_start")
local col_next = {0,1,1,0.35}
local col_past = {1,0,1,0.2}
local ROSTER_WAIT = 9

local racers, gates, markers, hidden_pilots
local race_over, omsg, progress_hook, finish_hook, countdown_hooks, roster_hook
local countdown_protected

-- luacheck: globals create approach_terminal start_race countdown allowmove
-- luacheck: globals update_race return_to_dome race_landed loaded abort

local function lerp ( a, b, t )
   return a+(b-a)*t
end

local function cubic_bezier ( t, p0, p1, p2, p3 )
   local l1=lerp(p0,p1,t)
   local l2=lerp(p1,p2,t)
   local l3=lerp(p2,p3,t)
   return lerp(lerp(l1,l2,t),lerp(l2,l3,t),t)
end

local function track_length ( track )
   local length=0
   local scale=track.scale or 1
   local previous=track.track[1][1]*scale
   for _index,segment in ipairs(track.track) do
      for t=0,1,0.05 do
         local position=cubic_bezier(t,segment[1],segment[1]+segment[2],
            segment[4]+segment[3],segment[4])*scale
         length=length+position:dist(previous)
         previous=position
      end
   end
   return length
end

function create ()
   mem.race_spob=spob.cur()
   -- The canonical Qex Racing offer claims this system while its terminal is
   -- present. Pod Racing must remain an independent second bar terminal, so
   -- it deliberately does not compete for that claim.
   mem.lengths={}
   for index,track in ipairs(tracks) do mem.lengths[index]=track_length(track) end
   misn.npcAdd("approach_terminal",_("Pod Racing Terminal"),"minerva_terminal",
      _("A battered terminal advertises armed, no-rules racing against contestants from across the galaxy."),
      4)
end

local function show_intro ()
   if var.peek("pod_racing_intro") then return end

   vn.clear()
   vn.scene()
   vn.transition()
   vn.na(_("The terminal detects that you have no Pod Racing record and offers a short explanation."))
   vn.menu{
      {_("Get an explanation"),"explain"},
      {_("Skip the explanation"),"done"},
   }
   vn.label("explain")
   vn.na(_("Pod Racing is decided by position, not a clock. Pass every gate in order; the first surviving racer through the final gate wins."))
   vn.na(_("Weapons are unrestricted and destruction is real. Racers may attack each other, so bring a combat-ready ship and expect your opponents to do the same."))
   vn.na(_("Ships compete in Light, Medium, or Heavy divisions so that interceptors are not matched against battleships. When P2P is enabled, opponents are based on captains registered with the multiplayer directory."))
   vn.na(_("Speed matters. Use an afterburner, Hades Torch, adrenal gland, or any other movement advantage your ship can sustain."))
   vn.label("done")
   vn.func(function() var.push("pod_racing_intro",true) end)
   vn.run()
end

function approach_terminal ()
   local selected=1
   local accepted=false
   local pp=player.pilot()
   local division=pod.division_for_size(pp:ship():size())
   local worthy,reason=pp:spaceworthy()
   if not worthy then
      vn.clear()
      vn.scene()
      vn.transition()
      vn.na(_("Your ship is not spaceworthy and cannot enter Pod Racing:\n\n")..reason)
      vn.run()
      return
   end

   show_intro()

   local w,h=520,460
   local wdw=luatk.newWindow(nil,nil,w,h)
   luatk.newButton(wdw,-20-100-20,-20,100,30,_("Enter Race"),function()
      accepted=true
      luatk.close()
   end)
   luatk.newButton(wdw,-20,-20,80,30,_("Close"),luatk.close)
   luatk.newText(wdw,0,10,w,20,_("Choose Pod Racing Track"),nil,"centre")
   luatk.newText(wdw,240,40,w-260,65,fmt.f(
      _("Weapons-free, lethal racing\nDivision: {division}\nFirst through every gate wins."),
      {division=pod.division_name(division)}))

   local txt_race=luatk.newText(wdw,240,110,w-260,45)
   local bzr_race=bezier.newBezier(wdw,240,165,w-260,210)
   local track_names={}
   for index,track in ipairs(tracks) do
      track_names[index]=_(track.name)
   end
   local lst_race=luatk.newList(wdw,20,40,200,h-60,track_names,
      function(_name,index)
         selected=index
         bzr_race:set(tracks[index].track)
         local details=fmt.f(_([[Length: {length} km
Reward: {reward}]]),{
            length=fmt.number(mem.lengths[index]),
            reward=fmt.credits(rewards[index]),
         })
         if tracks[index].description then
            details=details.."\n".._(tracks[index].description)
         end
         txt_race:set(details)
      end)
   lst_race:set(1)
   luatk.run()
   if not accepted then return end

   mem.track_index=selected
   mem.division=division
   mem.reward=rewards[selected]
   mem.player_won=false
   misn.accept()
   misn.setTitle(_("Pod Racing"))
   misn.setDesc(_("Win a lethal armed race at Melendez Dome."))
   misn.setReward(fmt.credits(mem.reward))
   misn.osdCreate(_("Pod Racing"),{
      _("Pass every gate in order and finish first."),
   })
   hook.load("loaded")
   hook.safe("start_race")
   player.takeoff()
end

local function translated_gates ( track )
   local scale=track.scale or 1
   local translate=track.translate or vec2.new()
   if track.centre then
      local minx,maxx,miny,maxy=math.huge,-math.huge,math.huge,-math.huge
      for _index,segment in ipairs(track.track) do
         for t=0,1,0.05 do
            local position=cubic_bezier(t,segment[1],segment[1]+segment[2],
               segment[4]+segment[3],segment[4])*scale
            local x,y=position:get()
            minx,maxx=math.min(minx,x),math.max(maxx,x)
            miny,maxy=math.min(miny,y),math.max(maxy,y)
         end
      end
      translate=mem.race_spob:pos()-vec2.new(minx,miny)
         -vec2.new((maxx-minx)*0.5,(maxy-miny)*0.5)
         +(track.centre_offset or vec2.new())
   end

   local positions={}
   local previous
   for _index,segment in ipairs(track.track) do
      for t=0,1,0.005 do
         local position=cubic_bezier(t,segment[1],segment[1]+segment[2],
            segment[4]+segment[3],segment[4])*scale+translate
         if not previous or position:dist(previous)>500 then
            positions[#positions+1]=position
            previous=position
         end
      end
   end
   return positions
end

local function external_ship ( name )
   if type(name)~="string" or name=="" then return nil end
   local ok,value=pcall(ship.get,name)
   if ok then return value end
end

local function validate_profile ( profile, division )
   local resolved=external_ship(profile.ship)
   local exact=resolved~=nil
   if not resolved then
      local count=0
      for encoded in (profile.ship_fallbacks or ""):gmatch("([^,]+)") do
         count=count+1
         if count>16 then break end
         local name=require("multiplayer.p2p.codec").unescape(encoded)
         resolved=external_ship(name)
         if resolved then break end
      end
   end
   if not resolved or pod.division_for_size(resolved:size())~=division then
      return nil
   end
   return {
      contestant=profile.contestant,
      division=division,
      name=profile.name,
      ship=resolved:nameRaw(),
      exact=exact,
      outfits=profile.outfits,
      slots=profile.slots,
   }
end

local function roster_profiles ()
   local config=naev.cache().multiplayer_p2p_config
   local cached=naev.cache().multiplayer_contestants
   return pod.opponents(config,cached,mem.division,5,validate_profile)
end

local function install_exact ( p, profile )
   local codec=require "multiplayer.p2p.codec"
   local installed=false
   for item in (profile.slots or ""):gmatch("([^,]+)") do
      local index,encoded=item:match("^(%d+):(.+)$")
      index=tonumber(index)
      local name=encoded and codec.unescape(encoded)
      local outfit_value=name and outfit.exists(name)
      if index and index>=1 and index<=512 and outfit_value then
         installed=p:outfitAddSlot(outfit_value,index,true,true) or installed
      end
   end
   if not installed then return false end
   return p:spaceworthy()
end

local function spawn_opponent ( profile, position, direction, faction_value )
   local p=pilot.add(profile.ship,faction_value,position,profile.name,
      {ai="dummy",naked=true})
   if not p then return nil end
   local equipped
   if profile.exact then equipped=install_exact(p,profile)
   else equipped=equip_mplayer(p) end
   if not equipped then p:rm(); return nil end
   p:changeAI("pod_racer")
   -- Exact directory loadouts bypass equipopt, which normally performs this
   -- scan. Run it for every contestant so active movement outfits, including
   -- the Hades Torch and bioship adrenal glands, are visible to pod_racer.
   ai_setup.setup(p)
   p:setPos(position)
   p:setVel(vec2.new())
   p:setDir(direction)
   p:setNoJump(true)
   p:setNoLand(true)
   p:setHostile(true)
   p:control(true)
   return p
end

local function grid_position ( origin, direction, slot )
   local column=((slot-1)%3)-1
   local row=math.floor((slot-1)/3)
   return origin+vec2.newP(column*220,direction+math.pi/2)
      -vec2.newP(120+row*260,direction)
end

local function activate_visual ( index )
   for offset=0,4 do
      if index-offset>0 then
         local alpha=col_past[4]*(1-offset/4)
         gates[index-offset]:setCol{col_past[1],col_past[2],col_past[3],alpha}
      end
   end
   for offset=1,6 do
      if index+offset<=#gates then
         local alpha=col_next[4]*(1-(offset-1)/7)
         gates[index+offset]:setCol{col_next[1],col_next[2],col_next[3],alpha}
      end
   end
end

local function clear_hook ( id )
   if id then hook.rm(id) end
end

local function release_countdown_protection ()
   for _index,p in ipairs(countdown_protected or {}) do
      if p:exists() then p:setInvincible(false) end
   end
   countdown_protected=nil
end

local function cleanup ()
   clear_hook(roster_hook)
   clear_hook(progress_hook)
   clear_hook(finish_hook)
   for _index,id in ipairs(countdown_hooks or {}) do clear_hook(id) end
   roster_hook,progress_hook,finish_hook,countdown_hooks=nil,nil,nil,nil
   release_countdown_protection()
   if omsg then player.omsgRm(omsg); omsg=nil end
   for _index,gate in ipairs(gates or {}) do gate:rm() end
   for _index,marker in ipairs(markers or {}) do system.markerRm(marker) end
   gates,markers=nil,nil
   for _index,p in ipairs(hidden_pilots or {}) do
      if p:exists() then p:setHide(false) end
   end
   hidden_pilots=nil
   local pp=player.pilot()
   if pp and pp:exists() then
      pp:control(false)
      pp:setNoJump(false)
      pp:setNoLand(false)
   end
   camera.setZoom()
   if mem.spawn_suspended then
      pilot.toggleSpawn(true)
      mem.spawn_suspended=nil
   end
end

local function declare_winner ( racer )
   if race_over then return end
   race_over=true
   mem.player_won=racer.player==true
   if mem.player_won then lmisn.sfxVictory() end
   omsg=player.omsgAdd(fmt.f(_("{name} wins!"),{name=racer.name}),5,50)
   for _index,entry in ipairs(racers) do
      if entry.pilot:exists() then entry.pilot:control(true) end
   end
   finish_hook=hook.timer(5,"return_to_dome")
end

local function gate_centre ( index )
   local data=gates[index]:data()
   return data.seg1+(data.seg2-data.seg1)*0.5
end

local function gate_aim ( index )
   local centre=gate_centre(index)
   local following=gate_centre(index<#gates and index+1 or 1)
   local offset=following-centre
   local distance=math.min(1200,math.max(300,offset:mod()*0.5))
   return centre+vec2.newP(distance,offset:angle())
end

function start_race ()
   roster_hook=nil
   if not mem.spawn_suspended then
      pilot.toggleSpawn(false)
      mem.spawn_suspended=true
   end
   local config=naev.cache().multiplayer_p2p_config
   local cached=naev.cache().multiplayer_contestants
   if type(config)=="table" and config.enabled==true
         and not pod.roster_matches_p2p(config,cached) then
      mem.roster_deadline=mem.roster_deadline or naev.ticks()+ROSTER_WAIT
      if naev.ticks()<mem.roster_deadline then
         if not omsg then
            omsg=player.omsgAdd(_("Contacting the Pod Racing directory…"),0,50)
         end
         roster_hook=hook.timer(0.1,"start_race")
         return
      end
   end
   mem.roster_deadline=nil
   if omsg then player.omsgRm(omsg); omsg=nil end

   -- Unlike canonical Qex Racing, this mission does not claim the system so
   -- its terminal can coexist with the ordinary racing terminal. Do not clear
   -- unrelated pilots: doing so can fire other events' death hooks without an
   -- attacker (and destroys their state). Hide and suspend them instead; Naev
   -- does not update hidden pilots, and cleanup restores the same handles.
   hidden_pilots={}
   local pp=player.pilot()
   for _index,p in ipairs(pilot.get(nil,true)) do
      if p~=pp and p:exists() then
         p:setHide(true)
         hidden_pilots[#hidden_pilots+1]=p
      end
   end

   local positions=translated_gates(tracks[mem.track_index])
   gates,markers={},{}
   for index,position in ipairs(positions) do
      local previous=positions[index-1] or positions[#positions]
      local following=positions[index+1] or positions[1]
      local angle=-(following-previous):angle()
      gates[index]=spfxtrack(position,angle,function() end)
      markers[index]=system.markerAdd(position)
   end
   activate_visual(1)

   local direction=(positions[2]-positions[1]):angle()
   pp:setPos(grid_position(positions[1],direction,1))
   pp:setVel(vec2.new())
   pp:setDir(direction)
   pp:setNoJump(true)
   pp:setNoLand(true)
   pp:control(true)

   local profiles=roster_profiles()
   local factions={}
   for index=1,#profiles do
      factions[index]=faction.dynAdd(nil,"pod_racer_"..index,
         _("Pod Racer"),{ai="pod_racer",clear_allies=true,clear_enemies=true})
   end
   for first=1,#profiles do
      for second=1,#profiles do
         if first~=second then factions[first]:dynEnemy(factions[second]) end
      end
   end

   racers={{
      pilot=pp,name=player.name(),player=true,next_gate=2,last_pos=pp:pos(),
   }}
   for index,profile in ipairs(profiles) do
      local position=grid_position(positions[1],direction,index+1)
      local opponent=spawn_opponent(profile,position,direction,factions[index])
      if opponent then
         opponent:memory().pod_gate=gate_aim(2)
         racers[#racers+1]={
            pilot=opponent,name=profile.name,next_gate=2,last_pos=opponent:pos(),
         }
      end
   end

   countdown_protected={}
   for _index,racer in ipairs(racers) do
      if not racer.pilot:flags("invincible") then
         racer.pilot:setInvincible(true)
         countdown_protected[#countdown_protected+1]=racer.pilot
      end
   end

   race_over=false
   camera.setZoom(2)
   omsg=player.omsgAdd(_("3…"),0,50)
   luasfx(true,nil,start_sfx)
   countdown_hooks={
      hook.timer(1,"countdown",_("2…")),
      hook.timer(2,"countdown",_("1…")),
      hook.timer(3,"allowmove"),
   }
end

function countdown ( message )
   luasfx(true,nil,start_sfx)
   player.omsgChange(omsg,message,0)
end

function allowmove ()
   countdown_hooks={}
   player.omsgChange(omsg,_("GO!"),3)
   luasfx(true,nil,start_sfx,{pitch=2})
   release_countdown_protection()
   for _index,racer in ipairs(racers) do
      if racer.pilot:exists() then racer.pilot:control(false) end
   end
   progress_hook=hook.timer(0.1,"update_race")
end

function update_race ()
   progress_hook=nil
   if race_over then return end
   for _index,racer in ipairs(racers) do
      local p=racer.pilot
      if p:exists() then
         local position=p:pos()
         local gate=gates[racer.next_gate]
         while gate do
            local data=gate:data()
            if not collide.line_line(racer.last_pos,position,data.seg1,data.seg2) then
               break
            end
            local crossed=racer.next_gate
            racer.next_gate=crossed+1
            if racer.player then activate_visual(crossed) end
            if racer.next_gate>#gates then
               declare_winner(racer)
               return
            end
            if not racer.player then
               p:memory().pod_gate=gate_aim(racer.next_gate)
            end
            gate=gates[racer.next_gate]
         end
         racer.last_pos=position
      end
   end
   progress_hook=hook.timer(0.1,"update_race")
end

function return_to_dome ()
   finish_hook=nil
   cleanup()
   hook.land("race_landed")
   player.land(mem.race_spob)
end

function race_landed ()
   vn.clear()
   vn.scene()
   vn.transition()
   if mem.player_won then
      vn.na(fmt.f(_("You won the Pod Race and receive {reward}."),{
         reward=fmt.credits(mem.reward),
      }))
      vn.func(function() player.pay(mem.reward) end)
   else
      vn.na(_("Another racer crossed the finish first. The terminal records your loss without ceremony."))
   end
   vn.run()
   misn.finish(mem.player_won)
end

function loaded ()
   cleanup()
   misn.finish(false)
end

function abort ()
   cleanup()
   if not player.isLanded() then player.land(mem.race_spob) end
   misn.finish(false)
end
