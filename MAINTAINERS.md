# Multiplayer Maintainer Notes

## Protocol boundary

Player gameplay uses one wire format: `MP2G/2`, implemented by
`scripts/multiplayer/p2p/gameplay_codec.lua`. All gameplay participants must run
the same version. There is no gameplay version advertisement, capability
exchange, compatibility branch, or fallback decoder.

`MP2P/1` remains only for directory rendezvous, activity, contestant records,
and persistent objects. Directory capability strings describe directory
services; they are not gameplay negotiation.

Gameplay is a direct host star:

- Guests send state and actions only to the current host.
- The host broadcasts one canonical world stream directly to gameplay peers;
  only guests that accepted that host and epoch apply it.
- Direct guest connections carry only discovery, claims, heartbeats, and
  leaves needed for deterministic election.
- A missing host path stops gameplay publication. The guest redials the host
  directly while the five-second lease and two-second election recovery run.
- Gameplay is never forwarded through another guest.

The gameplay ENet host also contains the directory peer. Gameplay connections
negotiate three ENet channels, while the directory connection negotiates only
channel 0. Discovery, election, guest submissions, and targeted replies use
channel 0. Host world publication encodes each MTU-bounded datagram once and
uses native `host:broadcast` on unreliable channel 1. Reliable canonical
player/craft descriptions, lifecycle, and actions use native broadcast on
channel 2 so they do not head-of-line block motion. ENet reuses each packet
across gameplay peers and cannot queue channels 1 or 2 to the directory.

## Authority and epochs

Every system packet carries a system visit. Authoritative packets and guest
gameplay submissions also carry the accepted host epoch. Entity identifiers
contain an owner, visit/generation, kind, generation counter, and local pilot
ID. NPC announcements and player/craft descriptions supply a stable origin
key. A different entity generation for the same origin explodes and replaces
the old replica.

Each player owns their real ship's movement and health. Network health is
applied only to disposable player proxies; it must never be written to
`player.pilot()`.

The host owns ambient NPC identity, lifecycle, health, and launched fighters.
Guests disable ambient spawning immediately and remove speculative ambient
pilots once they accept a host. A guest NPC runs the AI named in the host's
creation description, so local physics produces thrust, trails, targeting, and
combat between bounded host records. Fresh host records correct its motion,
health, energy, and target. Replica outfit installation excludes fighter bays,
so running the manifest AI cannot create a second speculative fighter
population.

Non-owning player, craft, and NPC replicas remain damageable. They use
no-death only to prevent local combat from deciding lifecycle before a fresh
authoritative record arrives; do not make them invincible. Persistent objects
are the exception to no-death: they are peer-trusted, fully killable on every
participant, and directory deletion converges their lifecycle.

Player-owned craft and their nested fighters remain owner-authoritative. A
guest sends at most one owned-craft record per 15 Hz tick. The host applies it
to the owner's host-side proxy and includes craft through the canonical bounded
world scheduler.

## Population lifecycle

Population discovery is event driven:

1. The initial host performs one `pilot.get()` inventory scan.
2. The global creation hook stores new pilot handles in a runtime-only queue.
   Since `hook.safe` supports one custom argument, it passes only the visit
   generation to one deferred callback, which drains the queue after outfits
   and leaders are complete.
3. Each authoritative pilot receives explicit death, jump, and land hooks.
4. A scheduled invalid-handle audit checks one cached authority entry at a
   time.

Do not introduce a periodic population scan. All authority hooks are removed
when the pilot departs, authority changes, the system visit ends, or the
session stops.

World publication never waits for a population acknowledgement. NPCs have no
separate manifest lifecycle: every selected round-robin NPC announcement
contains both its cached creation description and its current dynamic state.
A guest that does not know the ID creates it directly from that announcement;
a guest that already knows it applies the fresh state. Newly created NPCs and
explicit `entity_query` requests are placed in the next bounded announcement
slots, and the answer is broadcast to every guest.

Player and owner-controlled craft descriptions remain reliable because those
records enter through their owners rather than the host NPC ring. Unknown
player/craft dynamic state is held only as one latest bounded record while its
description is requested. If an ID does not exist, the host returns targeted
reliable `entity_absent` and the requester explodes any stale replica.
Reliable incremental removals remain the immediate lifecycle path. There are
no snapshot boundaries, ready acknowledgements, or parallel repair protocol.

## World publication and reconciliation

Players publish at 15 Hz. A host world frame contains cached player records plus
only bounded entity records:

- one priority NPC, newly announced NPC, or ambient ring NPC every tick;
- at most one additional ambient NPC every third tick;
- at most one craft record;
- at most one persistent-object dynamic record.

Naev's ENet binding cannot request unreliable fragmentation. A world frame is
therefore encoded into one or more canonical datagrams capped below ENet's
default MTU, and each encoded buffer is passed once to native ENet broadcast.
Packed world fields are carried raw inside the validated MP2G/2 envelope to
avoid escaping the same record twice. A complete NPC announcement that still
exceeds the unreliable budget is broadcast as an otherwise identical reliable
world record, while the bounded player/world datagrams continue normally.
Receivers reject stale records per entity so separately replaceable datagrams
remain safe when lost or reordered. Never rebuild a monolithic world packet;
ENet rejects an oversized unreliable packet instead of fragmenting it.

This limits host NPC dynamic collection to 20 records per second regardless of
population. Ambient selection inspects at most four ring candidates and skips
pilots undetectable by the local player and the bounded participant-proxy
check. Participant attackers, participant targets, and owned-craft engagements
feed deterministic priority rings.

NPC ship, faction, name, outfit, AI, and leader fields are collected once and
cached, then accompany that NPC's selected round-robin announcement. Dynamic
motion, health, energy, target, weapon set, and control fields are sampled only
for the selected records. Never rebuild static NPC data on a world tick.

Reconciliation runs only when a fresh record arrives. Initial `pilot.add`
chooses position; subsequent updates never call `setPos`. Position error
becomes capped velocity bias, and direction changes use a capped angular step
based on elapsed record time. Health, energy, target, weapon set, and controls
avoid redundant setters. Because replicas are damageable,
health and energy compare the live pilot value on each fresh bounded record;
otherwise unchanged authoritative values could not repair unrelated local
damage. NPCs, player-owned craft, and persistent objects all integrate through
local physics between records and receive the same packet-arrival motion
correction; players remain authoritative for their own real ship. There is no
population-wide smoothing update.

Players still publish ordinary unreliable state at 15 Hz while idle. Guest
state uses the motion channel and the host immediately rebroadcasts each
accepted fresh record, in addition to retaining it for the canonical world
tick. Reliable control messages are emitted only when held input changes;
Naev key-repeat callbacks must never force another message. Player velocity in
a fresh record is applied directly; when its ordinary `vx` and `vy` are zero,
residual replica drift is zero as well. This is not a separate stopped state or
edge.

Guest steering, acceleration, reverse, target/fire/weapon edges, and outfit
activate/deactivate edges are reliable. Active-outfit inventories are never
included in periodic state or control records. The host applies edges to the
guest's `p2p_remote_control` player proxy, so weapons physically interact with
host NPCs, craft, player proxies, and persistent-object pilots. The host
broadcasts each canonical action to every gameplay peer; guests apply it only
for their accepted host/epoch and ignore self-owned echoes.

## Host recovery

The host lease is five seconds and deterministic recovery lasts two seconds. A
fresh, remotely acknowledged incumbent wins. If recovered claims conflict
without a live incumbent, node ID resolves the winner.

When a guest is elected:

- every existing NPC replica becomes authoritative immediately;
- its already-running manifest AI is reinitialized for authority;
- replica tasks are cleared and no-death is removed;
- ambient spawning remains disabled for the rest of that system visit;
- entities receive the new authority generation and epoch;
- other peers discard the departed host's population and rebuild it from the
  new authority's complete round-robin NPC announcements.

Recovery does not synthesize missing NPCs or wait for another complete
population before promotion.

## Persistent objects

Persistent objects use `ObjectRuntime` and a dedicated ENet client. They never
enter gameplay NPC/craft registries or manifests. The gameplay update does not
service this client. `space_objects.lua` provides a one-second subscription
timer and a pending safe hook for acknowledgements, deletes, and reconnects.

Remembered objects are instantiated immediately after takeoff. The directory
query is authoritative: omitted remembered objects are exploded locally.
Message buoys remain visible and highlighted and keep anonymous local naming.
Local pilot handles map to stable object IDs. Destroying a local copy on any
peer reports that exact ID to the directory, whose idempotent deletion removes
every copy. The gameplay host publishes at most one object record per world
tick with motion and health. Live copies apply host health on arrival, but
objects have neither invincibility nor no-death: a peer that kills its copy
before the next record has killed the object, and a later record cannot revive
it. Object motion uses the same capped packet-arrival velocity and direction
reconciliation as NPCs. An `entity_absent` response from the gameplay host
never removes an object. Directory coordinates are only spawn/reset positions;
ordinary engine physics integrates object motion between host records.

## Time and event loop

Whenever discovery is unresolved or a remote participant is present, disable
speed input and enforce both `player.autonavSetSpeed(1)` and
`player.setSpeed(1)`. The update hook corrects autonav's own per-frame ramp;
one-second maintenance and modal chat/hail pumping preserve the lock. Ordinary
solo speed behavior returns only after the existing host-alone grace.

The per-frame update may:

- drain at most `MAX_EVENTS_PER_FRAME` immediately available ENet events with
  `service(0)`;
- inspect the two scalar player time multipliers while the shared-time lock is
  active;
- compare wall-clock due times;
- run only the scheduled bounded job whose deadline is due.

Do not add object servicing, `pilot.get()`, population traversal, manifest
construction, or an unbounded ENet drain to the frame path.

## Validation and manual smoke testing

Before handoff, run:

```sh
while IFS= read -r file; do luac -p "$file"; done < <(rg --files -g '*.lua')
while IFS= read -r file; do xmllint --noout "$file"; done < <(rg --files -g '*.xml')
```

Parser or mocked-module success is not evidence of playable networking.
Protocol or lifecycle work must report the Naev versions, topology, host/client
count, reproduction steps, disconnect/reconnect coverage, save restrictions,
and whether time compression remained at 1x.

The minimum three-instance manual matrix covers simultaneous undock, identical
NPC identities, guest NPC motion/trails/combat, guest fire through host
simulation, shared target priority, player/NPC fighters, guest destruction of
a message buoy, dock/takeoff, jump/re-entry, reconnect, host pause/loss/return,
authority promotion, and 1x autonav enforcement. Record host and guest FPS and
visible spikes; acceptance is based on the structural workload bounds and
observed playability, not a fixed numeric threshold.
