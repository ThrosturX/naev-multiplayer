package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local Store=require "multiplayer.contestant_track_store"

local profiles={
   ["a1:peninsula:1"]={
      node="a1",track="peninsula",seen=123,division=1,name="Ace",
      ship="Hyena",ship_fallbacks="Hyena",outfits="Laser",slots="1:Laser",
   },
   ["a1:death_knot:3"]={
      node="a1",track="death_knot",seen=234,division=3,name="Ace",
      ship="Clydesdale",ship_fallbacks="Clydesdale",outfits="Turret",
      slots="1:Turret",
   },
}

local decoded=Store.decode(Store.encode(profiles))
assert(decoded["a1:peninsula:1"].ship=="Hyena")
assert(decoded["a1:death_knot:3"].ship=="Clydesdale")
assert(next(Store.decode("not a track roster\n"))==nil)

print("ok - track contestant persistence")
