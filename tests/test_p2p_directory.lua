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

local host_peer={}
local guest_peer={}
assert(service:connect(host_peer,"198.51.100.10:45000"))
assert(sent[#sent].message.type=="hello" and sent[#sent].message.cap=="directory")
assert(service:receive(host_peer,assert(codec.encode{type="hello",node="10",cap="player",name="Host"})))
assert(service:receive(host_peer,assert(codec.encode{type="claim",node="10",system="Delta Polaris",
   claim="abc",endpoint="0.0.0.0:62001"})))

-- The directory uses the observed public address with the host's advertised
-- listening port, never the unusable 0.0.0.0 address in the claim.
assert(service.hosts["Delta Polaris"].endpoint=="198.51.100.10:62001")

assert(service:connect(guest_peer,"198.51.100.20:46000"))
assert(service:receive(guest_peer,assert(codec.encode{type="hello",node="20",cap="player",name="Guest"})))
assert(service:receive(guest_peer,assert(codec.encode{type="query",node="20",system="Delta Polaris"})))
local hint=sent[#sent].message
assert(hint.type=="hint" and hint.host=="10" and hint.endpoint=="198.51.100.10:62001" and hint.ttl==60)

-- A query made just before a host claim is retained for the connection, so a
-- directory restart or race does not force the querying peer to claim too.
local waiting_peer={}
assert(service:connect(waiting_peer,"198.51.100.40:49000"))
assert(service:receive(waiting_peer,assert(codec.encode{type="hello",node="40",cap="player",name="Waiting"})))
assert(service:receive(waiting_peer,assert(codec.encode{type="query",node="40",system="New Haven"})))
local sent_before=#sent
assert(service:receive(host_peer,assert(codec.encode{type="claim",node="10",system="New Haven",
   claim="ghi",endpoint="0.0.0.0:62001"})))
assert(#sent==sent_before+1 and sent[#sent].peer==waiting_peer and sent[#sent].message.host=="10")

-- Simultaneously active claims converge on the lowest node ID.
local lower_peer={}
assert(service:connect(lower_peer,"198.51.100.5:47000"))
assert(service:receive(lower_peer,assert(codec.encode{type="hello",node="05",cap="player",name="Lower"})))
assert(service:receive(lower_peer,assert(codec.encode{type="claim",node="05",system="Delta Polaris",
   claim="def",endpoint="0.0.0.0:62002"})))
assert(service.hosts["Delta Polaris"].node=="05")

-- Disconnected claims remain useful as stale hints. Any new live claimant can
-- supersede a stale entry regardless of node ordering.
service:disconnect_peer(lower_peer)
clock=100000; service:prune()
assert(service.hosts["Delta Polaris"].node=="05" and not service.hosts["Delta Polaris"].active)
local replacement_peer={}
assert(service:connect(replacement_peer,"198.51.100.30:48000"))
assert(service:receive(replacement_peer,assert(codec.encode{type="hello",node="30",cap="player",name="Replacement"})))
assert(service:receive(replacement_peer,assert(codec.encode{type="claim",node="30",system="Delta Polaris",
   claim="jkl",endpoint="0.0.0.0:62003"})))
assert(service.hosts["Delta Polaris"].node=="30" and service.hosts["Delta Polaris"].active)

-- Gameplay packets are ignored, and packets before hello are rejected.
local bad_peer={}
assert(service:connect(bad_peer,"198.51.100.50:50000"))
local ok=service:receive(bad_peer,assert(codec.encode{type="query",node="30",system="X"}))
assert(not ok and disconnected[bad_peer])

print("ok - minimal MP2P directory")
