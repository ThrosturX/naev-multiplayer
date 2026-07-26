local codec = require "multiplayer.p2p.codec"
local pod = {}

local generic = {
   {
      {name=N_("Rivet"),ship="Hyena"},
      {name=N_("Scrapper"),ship="Shark"},
      {name=N_("Hotshot"),ship="Lancelot"},
      {name=N_("Redline"),ship="Dvaered Vendetta"},
      {name=N_("Needle"),ship="Empire Lancelot"},
   },{
      {name=N_("Wrecker"),ship="Admonisher"},
      {name=N_("Hardcase"),ship="Dvaered Phalanx"},
      {name=N_("Roadblock"),ship="Dvaered Vigilance"},
      {name=N_("Burnout"),ship="Empire Pacifier"},
      {name=N_("Axle"),ship="Rhino"},
   },{
      {name=N_("Juggernaut"),ship="Kestrel"},
      {name=N_("War Rig"),ship="Dvaered Goddard"},
      {name=N_("Big Iron"),ship="Empire Peacemaker"},
      {name=N_("Thunderhead"),ship="Empire Hawking"},
      {name=N_("Blacktop"),ship="Pirate Kestrel"},
   },
}

function pod.division_for_size ( size )
   size=tonumber(size)
   if not size then return nil end
   size=math.floor(size)
   if size<1 or size>6 then return nil end
   return math.ceil(size/2)
end

function pod.division_name ( division )
   if division==1 then return _("Light")
   elseif division==2 then return _("Medium")
   elseif division==3 then return _("Heavy") end
   return _("Unknown")
end

function pod.boost_desired ( active, direction, energy )
   direction=math.abs(tonumber(direction) or math.huge)
   energy=tonumber(energy) or 0
   if active then
      return direction<math.rad(85) and energy>5
   end
   return direction<math.rad(65) and energy>15
end

local function outfit_names ( p )
   local names={}
   for _index,o in ipairs(p:outfitsList()) do
      names[#names+1]=codec.escape(o:nameRaw())
   end
   return table.concat(names,",")
end

local function outfit_slots ( p )
   local slots={}
   for index,o in ipairs(p:outfits()) do
      if o then slots[#slots+1]=tostring(index)..":"..codec.escape(o:nameRaw()) end
   end
   return table.concat(slots,",")
end

local function ship_fallback_names ( s )
   local names,seen={},{}
   local inherited=s:inherits()
   while inherited and #names<16 do
      local name=inherited:nameRaw()
      if type(name)~="string" or name=="" or seen[name] then break end
      seen[name]=true
      names[#names+1]=codec.escape(name)
      inherited=inherited:inherits()
   end
   local base=s:baseType()
   if #names<16 and type(base)=="string" and base~="" and not seen[base]
         and ship.exists(base) then
      names[#names+1]=codec.escape(base)
   end
   return table.concat(names,",")
end

function pod.local_profile ( node )
   local p=player.pilot()
   if not p or not p:exists() then return nil end
   local s=p:ship()
   return {
      type="contestant_register",
      node=node,
      division=pod.division_for_size(s:size()),
      name=player.name(),
      ship=s:nameRaw(),
      ship_fallbacks=ship_fallback_names(s),
      outfits=outfit_names(p),
      slots=outfit_slots(p),
   }
end

function pod.roster_matches_p2p ( config, roster )
   return type(config)=="table"
      and config.enabled==true
      and type(config.directory)=="string"
      and config.directory~=""
      and type(config.node_id)=="string"
      and config.node_id~=""
      and type(config.captain)=="string"
      and config.captain==player.name()
      and type(roster)=="table"
      and type(roster.received)=="number"
      and roster.directory==config.directory
      and roster.node_id==config.node_id
      and roster.captain==config.captain
      and type(roster.divisions)=="table"
end

function pod.generics ( division )
   local result={}
   for _index,entry in ipairs(generic[division] or {}) do
      result[#result+1]={name=_(entry.name),ship=entry.ship,generic=true}
   end
   return result
end

local function select_real ( profiles, division, count, validate )
   local selected,seen={},{}
   for _index,profile in ipairs(profiles or {}) do
      if #selected>=count then break end
      local id=profile.contestant
      if profile.division==division and type(id)=="string" and not seen[id] then
         local checked=validate(profile,division)
         if checked then
            seen[id]=true
            selected[#selected+1]=checked
         end
      end
   end
   return selected
end

function pod.opponents ( config, roster, division, count, validate )
   if type(config)=="table" and config.enabled==true then
      if not pod.roster_matches_p2p(config,roster)
            or type(roster.divisions[division])~="table" then
         return {}
      end
      return select_real(roster.divisions[division],division,count,validate)
   end

   local selected={}
   for _index,profile in ipairs(pod.generics(division)) do
      if #selected>=count then break end
      selected[#selected+1]=profile
   end
   return selected
end

return pod
