local setup = {}

local usable_outfits = {
   ["Emergency Shield Booster"]  = "shield_booster",
   ["Berserk Chip"]              = "berserk_chip",
   ["Combat Hologram Projector"] = "hologram_projector",
   ["Neural Accelerator Interface"] = "neural_interface",
   ["Blink Drive"]               = "blink_drive",
   ["Hyperbolic Blink Engine"]   = "blink_engine",
   ["Unicorp Jammer"]            = "jammer",
   ["Milspec Jammer"]            = "jammer",
   -- Mining stuff, not strictly combat...
   ["S&K Plasma Drill"]          = "plasma_drill",
   ["S&K Heavy Plasma Drill"]    = "plasma_drill",
   -- Bioships
   ["Feral Rage III"]            = "feral_rage",
   ["The Bite"]                  = "bite",
   ["The Bite - Improved"]       = "bite",
   ["The Bite - Blood Lust"]     = {"bite", "bite_lust"},
   -- afterburners
   ["Unicorp Light Afterburner"] = "afterburner",
   ["Unicorp Medium Afterburner"] = "afterburner",
   ["Hellburner"] = "afterburner",
   ["Hades Torch"] = "afterburner",
}

if __debugging then
   for k,v in pairs(usable_outfits) do
      if not outfit.get(k) then
         warn(_("Unknown outfit"))
      end
   end
end

function setup.setup( p )
   local added = false

   -- Clean up old stuff
   local m = p:memory()
   m._o = nil
   local o = {}

   -- Check out what interesting outfits there are
   for k,v in ipairs(p:outfits()) do
      if v then
         local var = usable_outfits[ v:nameRaw() ]
         if var then
            if type(var)=="table" then
               for i,t in ipairs(var) do
                  o[t] = k
               end
            else
               o[var] = k
            end
            added = true
         end
      end
   end

   -- Actually added an outfit, so we set the list
   if added then
      m._o = o
   end
end

return setup
