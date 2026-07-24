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
   and sent[#sent].message.features=="activity")
assert(service:receive(host_peer,assert(codec.encode{type="hello",node="10",cap="player",name="Host",
   endpoint="0.0.0.0:62001"})))
assert(service:receive(host_peer,assert(codec.encode{type="claim",node="10",system="Delta Polaris",
   claim="abc",endpoint="0.0.0.0:62001"})))

-- The observed source port is the actual NAT mapping. Keep the advertised
-- fixed port as a fallback candidate in case it is explicitly forwarded.
assert(service.hosts["Delta Polaris"].endpoint=="198.51.100.10:45000")
assert(service.hosts["Delta Polaris"].alternate=="198.51.100.10:62001")

assert(service:connect(guest_peer,"198.51.100.20:46000"))
assert(service:receive(guest_peer,assert(codec.encode{type="hello",node="20",cap="player",name="Guest",
   endpoint="0.0.0.0:63000"})))
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
-- supersede a stale entry regardless of node ordering.
service:disconnect_peer(host_peer)
clock=100000; service:prune()
assert(service.hosts["Delta Polaris"].node=="10" and not service.hosts["Delta Polaris"].active)
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

-- Gameplay packets are ignored, and packets before hello are rejected.
local bad_peer={}
assert(service:connect(bad_peer,"198.51.100.50:50000"))
local ok=service:receive(bad_peer,assert(codec.encode{type="query",node="30",system="X"}))
assert(not ok and disconnected[bad_peer])

print("ok - minimal MP2P directory")
