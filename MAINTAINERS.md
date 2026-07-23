# Maintainer Guide

## Runtime boundaries

`events/multiplayer.lua` owns the Info-menu adapter and P2P lifecycle hooks.
Arena behavior remains in `scripts/multiplayer/client.lua` and `server.lua`.
The isolated P2P implementation is:

- `p2p/session.lua`: one ENet host, non-blocking event pump, Naev lifecycle,
  player proxies, host NPC inventory, and owned-craft publication.
- `p2p/codec.lua`: `MP2P/1` framing, escaping, size limits, and field checks.
- `p2p/topology.lua`: bounded peer cache, expiring hints, and election.
- `p2p/core.lua`: session state transitions.
- `p2p/reconcile.lua`: sequence rejection and capped drift correction.
- `p2p/owned.lua`: nested craft classification, relay, and cleanup rules.
- `p2p/identity.lua`: stable wire names and unique local-only proxy aliases.
- `p2p/directory.lua`: bounded, in-memory directory claim and query logic.

`directory/main.lua` is the standalone blocking lua-enet adapter. It is not
loaded by Naev. The directory never joins a system or relays gameplay data;
its reliable `punch` introductions only make both players dial one another.

Only plain settings are persisted. ENet hosts/peers, ownership claims, hooks,
pilots, and other runtime handles must never enter event memory.

## Protocol and lifecycle

`MP2P/1` uses one packet per message: an ASCII version/type header followed by
percent-escaped `key=value` lines. Packets are limited to 16 KiB. Keep control,
manifests, additions, removals, chat, and claims reliable; player/NPC/craft
state is replaceable and unreliable. Validate peer values before resolving
ships, factions, outfits, pilots, or UI.

Reliable add/remove manifests are the normal entity lifecycle. Initial and
full-resync NPC manifests use bounded reliable batches, with at most one batch
serialized per update; incremental additions and removals remain immediate
singular messages. Do not restore periodic
full-manifest broadcasts. A joining peer sends a reliable `resync` request.
State that races ahead of manifests is coalesced into one resync per authority,
not one request per missing entity; suppress this feedback during the initial
synchronization window. Known targeted requests must use the authoritative
inventory index instead of rescanning `pilot.get()`.
Static manifest collection and high-frequency state collection must remain
separate; state collection must not inspect ship, name, faction, outfits, or
leader. The update hook drains at most 48 ENet events per rendered frame so a
packet backlog cannot monopolize simulation.

Each participant is authoritative for the health of their real local player.
Publish that health in `player_state` and apply it only to disposable remote
proxies. Never apply any network health value to `player.pilot()`. Connected
remote proxies must have no-death protection so unrelated local simulation
cannot remove them; clear that protection when the owner disconnects and the
proxy begins its inferred land, jump, or disabled departure.

Time-control and hostility grace periods piggyback on the existing one-second
liveness maintenance. A host must remain the only system member for ten
seconds before restoring normal autonav/time compression; any joining member
locks it again immediately. Player aggression records only actual hostile
actions and clears local proxy/craft hostility after twenty quiet seconds.
The local player receives stat-neutral status effects for the host-alone and
latest aggression deadlines. Refresh the aggression effect at most once per
second and derive its expiry from the latest live player deadline so it clears
with the final aggression timer. Do not turn either timer into a per-frame
pilot or membership scan.

Do not wrap ordinary ENet or pilot operations in `pcall`. The P2P runtime uses
protected calls only to validate untrusted Naev resource names (whose getters
throw when absent) and to convert an expected listener bind failure into a
startup error. Everything else must validate its invariant explicitly and let
programming errors surface.

Player-capability `hello` messages include the player's unchanged Naev name.
Names are not global network identifiers; node IDs are. If names collide, keep
the local player's name untouched and suffix only remote proxy display names.
Never rewrite the name in a relayed manifest.

Directory and bootstrap settings share the same outbound connection path; the
remote `hello.cap` is authoritative. Never infer capability from which setting
supplied an endpoint. Reject loopback-to-own-listener endpoints before dialing
and reject the local node ID again during `hello` to cover address aliases.
Naev's text input uses `address port`; settings normalize that to the
`address:port` form required by ENet and the wire protocol.
Directory hints carry a receiver-relative TTL capped at 60 seconds; never put
one process's monotonic or wall-clock timestamp on the wire as an expiry.
The TTL bounds each client's hint cache, not directory claim lifetime. Active
claims follow connection liveness. Disconnected claims remain as bounded stale
hints and are immediately superseded by any new live claimant.
For live claims, use the directory connection's observed endpoint as the
primary candidate and retain the advertised listen port as a fallback. Send
both peers reliable `punch` introductions so their shared ENet sockets emit
traffic simultaneously. Same-public-IP peers also receive loopback candidates
for convenient two-instance local testing. A verified player `hello` remains
mandatory before any introduced peer can affect session state.

The update hook must call `service(0)` and drain only immediately available
events. Remove update, enter, takeoff, landing, and jump hooks when disabling
P2P. Guests disable ambient spawning only after a host is directly verified,
and re-enable it when leaving or stopping.

Player health is never imported. Remote player proxies are invincible locally,
but their locally simulated weapons may damage the real player. NPC and owned
craft existence/health are authoritative at the host/owner respectively;
motion uses capped correction after spawn and native NPC AI remains active.

## Validation

Before hand-off, run the parser commands in `AGENTS.md` and
`lua tests/test_p2p.lua`. For an engine smoke test record:

1. Naev versions and confirmation that `lua_enet` is enabled.
2. Local/routed topology, fixed or ephemeral UDP ports, and host/client count.
3. A→B→host discovery with no directory and split-claim resolution.
4. Host mission-NPC replacement, abrupt host loss, election, and reconnect.
5. Player movement/fire/outfits/chat/damage and confirmation local health and
   god mode are not overwritten.
6. Jumping, landing, saving, toggling P2P, and mission limitation behavior.
7. Nested escorts and deployed craft on all peers, including owner departure.
8. A separate two-process arena host/client smoke test.

Passing parsers and mocks does not prove ENet or Naev lifecycle integration.
