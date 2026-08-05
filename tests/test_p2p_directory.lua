package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local codec=require "multiplayer.p2p.codec"
local Directory=require "multiplayer.p2p.directory"

local clock=100
local sent={}
local disconnected={}
local service=Directory.new{
   node_id="d1",
   now=function() return clock end,
   send=function(peer,packet) sent[#sent+1]={peer=peer,message=assert(codec.decode(packet))}; return true end,
   disconnect=function(peer) disconnected[peer]=true end,
}

local function find_sent ( first, peer, kind, endpoint )
   for index=first,#sent do
      local entry=sent[index]
      if entry.peer==peer and entry.message.type==kind
            and (not endpoint or entry.message.endpoint==endpoint) then return entry.message end
   end
end

local host_peer={}
local guest_peer={}
assert(service:connect(host_peer,"198.51.100.10:45000"))
assert(sent[#sent].message.type=="hello" and sent[#sent].message.cap=="directory"
   and sent[#sent].message.features==
      "activity,contestants,contestants_by_track,objects")
assert(service:receive(host_peer,assert(codec.encode{type="hello",node="10",cap="player",name="Host",
   endpoint="0.0.0.0:62001"})))
assert(service:receive(host_peer,assert(codec.encode{
   type="contestant_register",node="10",track="peninsula",division=1,
   name="Host Captain",
   ship="Hyena",outfits="Laser%20Cannon",slots="1:Laser%20Cannon",
   ship_fallbacks="Hyena"})))
assert(service:receive(host_peer,assert(codec.encode{type="claim",node="10",system="Delta Polaris",
   claim="abc",endpoint="0.0.0.0:62001"})))

-- The observed source port is the actual NAT mapping. Keep the advertised
-- fixed port as a fallback candidate in case it is explicitly forwarded.
assert(service.hosts["Delta Polaris"].endpoint=="198.51.100.10:45000")
assert(service.hosts["Delta Polaris"].alternate=="198.51.100.10:62001")

assert(service:connect(guest_peer,"198.51.100.20:46000"))
assert(service:receive(guest_peer,assert(codec.encode{type="hello",node="20",cap="player",name="Guest",
   endpoint="0.0.0.0:63000"})))
local roster_at=#sent+1
assert(service:receive(guest_peer,assert(codec.encode{
   type="contestant_query",node="20",division=1,request=7,limit=11})))
local contestant=find_sent(roster_at,guest_peer,"contestant_entry")
local contestant_done=find_sent(roster_at,guest_peer,"contestant_done")
assert(contestant and contestant.contestant=="10" and contestant.name=="Host Captain")
assert(contestant_done and contestant_done.count==1 and contestant_done.request==7)

-- A node can replace only its own profile, and is excluded from its results.
service:register_contestant{
   node="10",division=2,name="Host Captain",ship="Rhino",
   outfits="Laser%20Turret",slots="1:Laser%20Turret",
}
assert(service.contestants["10"].ship=="Rhino"
   and service.track_contestants["10:peninsula:1"].ship=="Hyena",
   "latest fallback profile or exact track profile was not retained")
assert(service:receive(guest_peer,assert(codec.encode{
   type="contestant_register",node="20",division=2,name="Guest Captain",
   ship="Admonisher",outfits="Laser",slots="1:Laser"})))
local self_at=#sent+1
assert(service:receive(guest_peer,assert(codec.encode{
   type="contestant_query",node="20",division=2,request=8,limit=11})))
local medium=find_sent(self_at,guest_peer,"contestant_entry")
assert(medium and medium.contestant=="10" and medium.ship=="Rhino",
   "division query lost another division or included the querying node")
assert(find_sent(self_at,guest_peer,"contestant_done").count==1)

-- Exact track/class profiles come first. If that pool is short, the directory
-- fills it from each player's latest compatible profile, newest first.
clock=110
service:register_contestant{
   node="30",track="qex_tour",division=1,name="Older Fallback",
   ship="Shark",outfits="Laser",slots="1:Laser",
}
clock=120
service:register_contestant{
   node="40",track="smiling_man",division=1,name="Newer Fallback",
   ship="Vendetta",outfits="Laser",slots="1:Laser",
}
clock=130
service:register_contestant{
   node="50",track="qex_tour",division=1,name="Changed Division",
   ship="Shark",outfits="Laser",slots="1:Laser",
}
clock=140
service:register_contestant{
   node="50",track="death_knot",division=2,name="Changed Division",
   ship="Admonisher",outfits="Laser",slots="1:Laser",
}
local track_at=#sent+1
assert(service:send_contestants(guest_peer,{
   type="contestant_query",node="20",track="peninsula",division=1,
   request=9,limit=11,
}))
local track_entries={}
for index=track_at,#sent do
   local message=sent[index].message
   if message.type=="contestant_entry" then
      track_entries[#track_entries+1]=message
      assert(message.track=="peninsula")
   end
end
assert(#track_entries==4)
assert(track_entries[1].contestant=="10" and track_entries[1].ship=="Hyena",
   "exact track profile was not preferred over the player's latest profile")
assert(track_entries[2].contestant=="50" and track_entries[2].ship=="Shark",
   "compatible cross-pool profile was hidden by a newer weight class")
assert(track_entries[3].contestant=="40"
   and track_entries[4].contestant=="30",
   "cross-pool fallback profiles were not returned most-recent first")
assert(find_sent(track_at,guest_peer,"contestant_done").track=="peninsula")
local introduced_at=#sent+1
assert(service:receive(guest_peer,assert(codec.encode{type="query",node="20",system="Delta Polaris"})))
local hint=find_sent(introduced_at,guest_peer,"hint")
assert(hint and hint.host=="10" and hint.endpoint=="198.51.100.10:45000" and hint.ttl==60)
assert(find_sent(introduced_at,guest_peer,"punch","198.51.100.10:45000"))
assert(find_sent(introduced_at,guest_peer,"punch","198.51.100.10:62001"))
assert(find_sent(introduced_at,host_peer,"punch","198.51.100.20:46000"))
assert(find_sent(introduced_at,host_peer,"punch","198.51.100.20:63000"))

-- A query made just before a host claim is retained for the connection, so a
-- directory restart or race does not force the querying peer to claim too.
local waiting_peer={}
assert(service:connect(waiting_peer,"198.51.100.40:49000"))
assert(service:receive(waiting_peer,assert(codec.encode{type="hello",node="40",cap="player",name="Waiting"})))
assert(service:receive(waiting_peer,assert(codec.encode{type="query",node="40",system="New Haven"})))
local sent_before=#sent
assert(service:receive(host_peer,assert(codec.encode{type="claim",node="10",system="New Haven",
   claim="ghi",endpoint="0.0.0.0:62001"})))
assert(find_sent(sent_before+1,waiting_peer,"hint"))
assert(find_sent(sent_before+1,waiting_peer,"punch","198.51.100.10:45000"))
assert(find_sent(sent_before+1,host_peer,"punch","198.51.100.40:49000"))

-- Same-public-IP peers also receive harmless loopback candidates. This makes
-- two local Naev processes work without manually adding a bootstrap peer.
local local_peer={}
assert(service:connect(local_peer,"198.51.100.10:47000"))
assert(service:receive(local_peer,assert(codec.encode{type="hello",node="50",cap="player",name="Local",
   endpoint="0.0.0.0:64000"})))
local local_at=#sent+1
assert(service:receive(local_peer,assert(codec.encode{type="query",node="50",system="Delta Polaris"})))
assert(find_sent(local_at,local_peer,"punch","127.0.0.1:62001"))
assert(find_sent(local_at,host_peer,"punch","127.0.0.1:64000"))

-- Reusing the exact fixed endpoint must not make the directory introduce the
-- new connection to the old identity at its own socket.
local reused_peer={}
assert(service:connect(reused_peer,"198.51.100.10:45000"))
assert(service:receive(reused_peer,assert(codec.encode{
   type="hello",node="70",cap="player",name="Reset Host",
   endpoint="0.0.0.0:62001"})))
local reused_at=#sent+1
assert(service:receive(reused_peer,assert(codec.encode{
   type="query",node="70",system="Delta Polaris"})))
assert(not find_sent(reused_at,reused_peer,"hint"))
assert(not find_sent(reused_at,reused_peer,"punch"))

-- The latest verified claim wins regardless of node ordering.
local lower_peer={}
assert(service:connect(lower_peer,"198.51.100.5:47000"))
assert(service:receive(lower_peer,assert(codec.encode{type="hello",node="05",cap="player",name="Lower"})))
assert(service:receive(lower_peer,assert(codec.encode{type="claim",node="05",system="Delta Polaris",
   claim="def",endpoint="0.0.0.0:62002"})))
assert(service.hosts["Delta Polaris"].node=="05")
assert(service:receive(host_peer,assert(codec.encode{type="claim",node="10",system="Delta Polaris",
   claim="abc2",endpoint="0.0.0.0:62001"})))
assert(service.hosts["Delta Polaris"].node=="10",
   "directory retained a lower-ID claimant instead of the latest claim")

-- Disconnected claims remain useful as stale hints. Any new live claimant can
-- supersede a stale entry regardless of node ordering, but inactive claims
-- expire after one minute.
service:disconnect_peer(host_peer)
local disconnected_at=clock
clock=disconnected_at+59; service:prune()
assert(service.hosts["Delta Polaris"].node=="10" and not service.hosts["Delta Polaris"].active)
clock=clock+1; service:prune()
assert(not service.hosts["Delta Polaris"])
local replacement_peer={}
assert(service:connect(replacement_peer,"198.51.100.30:48000"))
assert(service:receive(replacement_peer,assert(codec.encode{type="hello",node="30",cap="player",name="Replacement"})))
assert(service:receive(replacement_peer,assert(codec.encode{type="claim",node="30",system="Delta Polaris",
   claim="jkl",endpoint="0.0.0.0:62003"})))
assert(service.hosts["Delta Polaris"].node=="30" and service.hosts["Delta Polaris"].active)

-- Activity is answered by the directory alone. A clean leave removes the
-- discovery hint while retaining a short-lived, anonymous activity record.
local activity_peer={}
assert(service:connect(activity_peer,"198.51.100.60:51000"))
assert(service:receive(activity_peer,assert(codec.encode{
   type="hello",node="60",cap="player",name="Activity Host"})))
assert(service:receive(activity_peer,assert(codec.encode{
   type="claim",node="60",system="Activity Reach",claim="mno",
   endpoint="0.0.0.0:62004"})))
local function activity_entry ( system_name )
   local at=#sent+1
   assert(service:receive(activity_peer,assert(codec.encode{
      type="activity_query",node="60"})))
   local response=find_sent(at,activity_peer,"activity")
   assert(response)
   for line in response.entries:gmatch("([^;]+)") do
      local encoded,active,age=line:match("^([^,]+),([01]),(%d+)$")
      if encoded and codec.unescape(encoded)==system_name then
         return active=="1",tonumber(age)
      end
   end
end
local active,age=activity_entry("Activity Reach")
assert(active and age==0)
clock=clock+60
assert(service:receive(activity_peer,assert(codec.encode{
   type="leave",node="60",system="Activity Reach"})))
assert(not service.hosts["Activity Reach"])
active,age=activity_entry("Activity Reach")
assert(active==false and age==0)
clock=clock+901
active=activity_entry("Activity Reach")
assert(active==nil)

-- Contestant history expires independently of connection liveness.
clock=clock+90*24*60*60+1
service:prune()
assert(next(service.contestants)==nil)
assert(next(service.track_contestants)==nil)

-- Gameplay packets are ignored, and packets before hello are rejected.
local bad_peer={}
assert(service:connect(bad_peer,"198.51.100.50:50000"))
local ok=service:receive(bad_peer,assert(codec.encode{type="query",node="30",system="X"}))
assert(not ok and disconnected[bad_peer])

print("ok - minimal MP2P directory")
