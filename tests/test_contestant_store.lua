package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local Store=require "multiplayer.contestant_store"

local profiles={
   a1={
      node="a1",seen=123,division=1,name="Ace & One",ship="Hyena",
      ship_fallbacks="Hyena",outfits="Laser%20Cannon",
      slots="1:Laser%20Cannon",
   },
   b2={
      node="b2",seen=456,division=3,name="Heavy",ship="Goddard",
      ship_fallbacks="",outfits="Railgun",slots="1:Railgun",
   },
}

local encoded=Store.encode(profiles)
local decoded=Store.decode(encoded)
assert(decoded.a1 and decoded.a1.name=="Ace & One" and decoded.a1.division==1)
assert(decoded.b2 and decoded.b2.ship=="Goddard" and decoded.b2.seen==456)

local damaged=encoded.."bad\tline\n"
decoded=Store.decode(damaged)
assert(decoded.a1 and decoded.b2 and not decoded.bad)
assert(next(Store.decode("not a roster\n"))==nil)

print("ok - contestant persistence")
