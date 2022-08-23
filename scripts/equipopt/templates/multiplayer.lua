local optimize = require 'equipopt.optimize'
local ecores = require 'equipopt.cores'
local eoutfits = require 'equipopt.outfits'
local eparams = require 'equipopt.params'

local function choose_one( t ) return t[ rnd.rnd(1,#t) ] end

local mplayer_outfits = eoutfits.merge{{
   -- Heavy Weapons
   "Turbolaser", "Heavy Ripper Turret", "Railgun Turret",
   "Railgun", "Heavy Laser Turret", "Heavy Ion Turret",
   "Heavy Laser Turret", "Heavy Razor Turret",
   "Repeating Railgun",
   -- Medium Weapons
   "Grave Lance", "Orion Lance", "Particle Lance",
   "Heavy Ripper Cannon",
   "Enygma Systems Turreted Fury Launcher",
   "Enygma Systems Turreted Headhunter Launcher",
   "Laser Turret MK2", "Razor Turret MK2", "Turreted Vulcan Gun",
   "Plasma Turret MK2", "EMP Grenade Launcher",
   "TeraCom Headhunter Launcher",
   "TeraCom Medusa Launcher", "TeraCom Vengeance Launcher",
   "Unicorp Caesar IV Launcher",
   "Enygma Systems Huntsman Launcher",
   "TeraCom Fury Launcher", "TeraCom Headhunter Launcher",
   "TeraCom Imperator Launcher",
   "Repeating Banshee Launcher",
   "Laser Cannon MK2", "Razor MK2", "Vulcan Gun", "Plasma Blaster MK2",
   "Ion Cannon",
   -- Small Weapons
   "Laser Cannon MK1", "Razor MK1", "Gauss Gun", "Plasma Blaster MK1",
   "Laser Turret MK1", "Razor Turret MK1", "Turreted Gauss Gun",
   "Plasma Turret MK1",
   "TeraCom Mace Launcher", "TeraCom Banshee Launcher",
   -- Utility
   "Unicorp Light Afterburner",
   "Sensor Array", "Hellburner", "Emergency Shield Booster", --[[ temporarily disabled ]]--
   "Unicorp Medium Afterburner", "Droid Repair Crew",
   "Scanning Combat AI", "Hunting Combat AI",
   "Photo-Voltaic Nanobot Coating",
   "Targeting Array", "Agility Combat AI",
   "Milspec Jammer",
   "Faraday Tempest Coating",
   -- Heavy Structural
   "Biometal Armour",
   "Battery IV",
   "Battery III", "Shield Capacitor III", "Shield Capacitor IV",
   "Reactor Class III",
   "Large Shield Booster",
   -- Medium Structural
   "Battery II", "Shield Capacitor II", "Reactor Class II",
   "Active Plating", "Medium Shield Booster",
   -- Small Structural
   "Battery I", "Shield Capacitor I", "Reactor Class I",
   "Small Shield Booster",
}}

local mplayer_class = { "elite" }

local mplayer_params = {
   ["Kestrel"] = function () return {
         type_range = {
            ["Launcher"] = { max = 2 },
         },
      } end,
	["Pirate Kestrel"] = function () return {
		prefer = {
			[ "Unicorp Caesar IV Launcher"] = 7, ["TeraCom Headhunter Launcher"] = 2,
			["TeraCom Medusa Launcher"] = 3, ["Enygma Systems Turreted Fury Launcher"] = 2
		},
         type_range = {
            ["Launcher"] = { max = 4 },
         },
      } end,
	["Mule"] = function() return {
		fighterbay = 1.2,
		disable = 1.1,
		move = 0.5,
		prefer = { ["Droid Repair Crew"] = 2 },
		type_range = {
			[ "Launcher" ] = { max=1 },
		},
	} end,
	["Goddard"] = function () return {
		fighterbay = 1.5,
		disable = 1.8,
		move = 1.5,
		prefer = {
			["Droid Repair Crew"] = 2, ["Biometal Armour"] = 60, ["Engine Reroute"] = 2,
			["Hyperbolic Blink Engine"] = 5, ["Enygma Systems Huntsman Launcher"] = 2,
			["Agility Combat AI"] = 100
		},
		type_range = {
			[ "Launcher" ] = { max=3 }
		},
	} end,
}

local mplayer_cores = {
   ["Pirate Kestrel"] = function (p)
         local c = ecores.get( p, { systems=mplayer_class, hulls=mplayer_class } )
         table.insert( c, choose_one{ "Nexus Bolt 3500 Engine", "Krain Remige Engine", "Tricon Typhoon Engine", } )
         return c
      end,
	["Kestrel"] = function () return {
         choose_one{ "Unicorp PT-2200 Core System", "Milspec Orion 8601 Core System", "Milspec Thalos 9802 Core System", "Milspec Orion 9901 Core System" },
         choose_one{ "Nexus Bolt 3500 Engine", "Krain Remige Engine", "Tricon Typhoon Engine", },
		 choose_one{ "Unicorp D-48 Heavy Plating", "S&K Heavy Combat Plating" },

      } end,
	["Goddard"] = function () return {
         choose_one{ "Milspec Thalos 9802 Core System", "Milspec Orion 9901 Core System" },
         choose_one{ "Tricon Typhoon II Engine", "Melendez Mammoth XL Engine"},
		 choose_one{ "S&K Superheavy Combat Plating", "S&K Heavy Combat Plating" },
      } end,
	["Pirate Starbridge"] = function (p)
         local c = ecores.get( p, { systems=mplayer_class, hulls=mplayer_class } )
         table.insert( c, choose_one{ "Unicorp Falcon 1300 Engine", "Krain Patagium Engine", "Tricon Cyclone Engine"} )
         return c
      end,
   ["Starbridge"] = function (p)
         local c = ecores.get( p, { systems=mplayer_class, hulls=mplayer_class } )
         table.insert( c, choose_one{ "Unicorp Falcon 1300 Engine", "Krain Patagium Engine", "Tricon Cyclone Engine"} )
         return c
      end,
   ["Shark"] = function () return {
         choose_one{ "Milspec Orion 2301 Core System", "Milspec Thalos 2202 Core System" },
         "Tricon Zephyr Engine",
         choose_one{ "Nexus Light Stealth Plating", "S&K Ultralight Combat Plating" },
      } end,
   ["Empire Shark"] = function () return {
         choose_one{ "Milspec Orion 2301 Core System", "Milspec Thalos 2202 Core System" },
         "Tricon Zephyr Engine",
         choose_one{ "Nexus Light Stealth Plating", "S&K Ultralight Combat Plating" },
      } end,
   ["Mule"] = function() return {
		 choose_one{ "Milspec Orion 5501 Core System", "Milspec Thalos 5402 Core System", "Unicorp PT-310 Core System" },
		 "Melendez Buffalo XL Engine",
		 choose_one{"S&K Medium Combat Plating", "Unicorp D-24 Medium Plating", "S&K Medium-Heavy Combat Plating", "Patchwork Medium Plating" },
   } end,
}

local mplayer_params_overwrite = {
  weap = 2.6, -- Focus on weapons
  disable = 1.4, 
   -- some nice preferable outfits
  prefer = {
        ["Turbolaser"] = 2.8,
        ["Repeating Railgun"] = 2.8,
        ["Heavy Razor Turret"] = 2.8,
        ["Heavy Laser Turret"] = 2.9,
		["Large Shield Booster"] = 1.5,
		[ "Shield Capacitor IV"] = 2, ["Biometal Armour"] = 2
   },

   -- not too much diversity, but some
   max_same_stru = 2,
   max_same_util = 2,
   cargo = 0.1,
   constant = 7,
   rnd = 0.7,
}

--[[
-- @brief Does Multiplayer pilot equipping
--
--    @param p Pilot to equip
--]]
local function equip_mplayer( p, opt_params )
   opt_params = opt_params or {}
   local ps = p:ship()
   local sname = ps:nameRaw()

   -- Choose parameters and make Pirateish
   local params = eparams.choose( p, mplayer_params_overwrite )
   params.rnd = params.rnd * 1.5
  params.max_same_weap = 2
   params.max_mass = 0.98 + 1.5*rnd.rnd()
   -- Per ship tweaks
   local sp = mplayer_params[ sname ]
   if sp then
      params = tmerge_r( params, sp() )
   end
   params = tmerge_r( params, opt_params )

   -- See cores
   local cores
   local esccor = mplayer_cores[ sname ]
   if esccor then
      cores = esccor( p )
   else
      cores = ecores.get( p, { all=mplayer_class } )
   end

   local mem = p:memory()
   mem.equip = { type="mplayer", level="standard" }

   -- Try to equip
   return optimize.optimize( p, cores, mplayer_outfits, params )
end

return equip_mplayer
