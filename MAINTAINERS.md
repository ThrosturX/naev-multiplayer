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

If `naev.claimTest(system.cur())` returns false, another exclusive claim blocks
shared authority and this participant must host its own simulation: ignore
remote directory hints and gameplay claims, and never enter or remain in the
guest state. Check again during the visit because the result can change after
system entry.

Separate hosts in the same system do not exchange simulation state. Once a
verified peer advertises a foreign host epoch, accept only its directly authored
chat under that epoch, display it locally without rebroadcasting, and show one
notice per remote host and local system visit explaining that the simulations
remain separate. Deduplicate chat by remote node, epoch, and sequence because
simultaneous inbound and outbound ENet connections can carry the same packet.

Every system packet carries a system visit. Authoritative packets and guest
gameplay submissions also carry the accepted host epoch. Entity identifiers
contain an owner, visit/generation, kind, generation counter, and local pilot
ID. NPC announcements and player/craft descriptions supply a stable origin
key. A different entity generation for the same origin explodes and replaces
the old replica.

Each player owns their real ship's movement and health. Network health is
applied only to disposable player proxies; it must never be written to
`player.pilot()`.

The host owns naturally spawned ambient NPC identity, lifecycle, health, and
launched fighters. Guests disable ambient spawning immediately and remove
speculative ambient pilots once they accept a host. An NPC replica runs the AI
named in its owner's creation description, so local physics produces thrust,
trails, targeting, and combat between bounded owner records. Fresh records
correct its motion, health, energy, and target. Replica outfit installation
excludes fighter bays, so running the described AI cannot create a second
speculative fighter population.

An NPC created locally on a guest after joining remains guest-authoritative,
including NPCs spawned by local faction consequences and their nested
fighters. The guest assigns the entity ID, keeps normal AI and lethal health,
and sends its description reliably to the host. The host creates only a
no-death replica, broadcasts an immediate complete NPC announcement, and then
relays the guest's bounded state through the ordinary NPC scheduler. The guest
never proposes authority transfer and the host never creates an authoritative
replacement. This version deliberately trusts valid owner-matching
descriptions, state, and lifecycle messages from a connected guest.

Non-owning player, craft, and NPC replicas remain damageable. They use
no-death only to prevent local combat from deciding lifecycle before a fresh
authoritative record arrives; do not make them invincible. Persistent objects
are the exception to no-death: they are peer-trusted, fully killable on every
participant, and directory deletion converges their lifecycle.

Player-owned craft, guest-owned NPCs, and their nested fighters remain
owner-authoritative. A guest sends at most one owned-entity record per 15 Hz
tick. The host applies it to the owner's host-side replica and includes it
through the canonical bounded world scheduler. Remote player proxy AI must
retain the normal player policy `mem.atk_kill=false`, and every owned-craft
replica receives that policy directly because its network leader may be bound
after AI creation. Owned escorts then stop their existing attack task when its
target becomes disabled, without requiring a new network order. Non-owner
craft replicas also set `mem.aggressive=false`: they may attack through a
replicated reliable `e_attack` order, but cannot invent a local attack merely
because their replica leader selected a target or local faction relationships
differ.

## Population lifecycle

Population discovery is event driven:

1. The initial host performs one `pilot.get()` inventory scan.
2. The global creation hook stores new pilot handles in a runtime-only queue.
   Since `hook.safe` supports one custom argument, it passes only the visit
   generation to one deferred callback, which drains the queue after outfits
   and leaders are complete. The host registers an unowned NPC directly; a
   guest registers a locally created NPC as guest-owned and sends its
   description to the host.
3. Each authoritative pilot receives explicit death, jump, and land hooks.
4. A scheduled invalid-handle audit checks one cached authority entry at a
   time.

Do not introduce a periodic population scan. All authority hooks are removed
when the pilot departs, authority changes, the system visit ends, or the
session stops.

When a participant leaves a live shared visit, discard network ownership but
do not delete its player, craft, or guest-owned NPC replicas. Apply the same
departure lifecycle to each ship: if its last state is within the exit radius,
ship radius, and packet-lag allowance of a landable friendly spob or usable
jump, clear network controls and push the matching native AI departure task.
Otherwise leave it behind as a permanently disabled, damageable ship. Retain
departing handles outside the gameplay registries until Naev completes their
landing or jump so creation and attack hooks cannot readmit them. On rejoin,
destroy disabled remnants before creating the participant's replacement; let
ships already committed to landing or jumping finish their departure.
Before starting this lifecycle, the participant proxy broadcasts "Signal
lost.", plays the disconnect cue once, and gains a visible "(disconnected)"
suffix. Do not expose its internal node identifier in that name.

The same proximity test is used when first creating a remote player proxy.
Spawn it from a nearby spob or jump so Naev supplies the native takeoff or
jump-in motion; otherwise create it at the received position and velocity.
Apply this departure lifecycle consistently to non-death NPC and craft removal
messages as well; only explicit death or explosion reasons are destructive.

Targeting closes any creation-hook admission gap without a scan. Before any
participant publishes its own target, a valid local pilot with no object,
replica, or authority identity is registered immediately. Target serialization
and the priority scheduler therefore cannot hide that pilot behind an unknown
ID. A global attacked hook admits both the victim and attacker, so untargeted
fire also discovers a missed pilot. On a guest, a newly discovered native NPC
becomes guest-owned and is described reliably to the host; on the host it
becomes host-owned. Existing replicas and persistent objects retain their
current identities. Naev exposes no generic hook for an unknown NPC merely
selecting a participant as its target, so targeting, creation, and the first
local damage event are the event-driven repair boundaries.

World publication never waits for a population acknowledgement. NPCs have no
separate manifest lifecycle: every selected round-robin NPC announcement
contains both its cached creation description and its current dynamic state.
A guest that does not know the ID creates it directly from that announcement;
a guest that already knows it applies the fresh state. Newly created NPCs and
explicit `entity_query` requests are placed in the next bounded announcement
slots, and the answer is broadcast to every guest.

Player, owner-controlled craft, and guest-owned NPC descriptions enter the
host reliably through their owners. The host republishes craft descriptions
reliably; guest-owned NPCs join the same complete round-robin announcement
format as ambient NPCs. Unknown dynamic state is held only as one latest
bounded record while its description is requested. If an ID does not exist,
the host returns targeted reliable `entity_absent` and the requester explodes
any stale replica. Reliable incremental removals remain the immediate
lifecycle path. There are no snapshot boundaries, ready acknowledgements, or
parallel repair protocol.

All player descriptions are refreshed with the latest cached dynamic record
before reliable broadcast. A newly joined peer therefore creates existing
player proxies at their current coordinates; later records use ordinary
packet-arrival reconciliation, including the bounded large-error catch-up
described below.

An owner may name a dynamic faction that does not exist on another peer. NPC
replicas use the named faction when available and otherwise synthesize a
local-only neutral relationship container while preserving the owner-provided
AI, identity, target, and state. Missing local faction registration must not
silently prevent a trusted guest-owned NPC from entering the host broadcast.

## World publication and reconciliation

Players publish at 15 Hz. A host world frame contains cached player records plus
only bounded entity records:

- up to two priority NPCs, newly announced NPCs, or ambient ring NPCs per tick,
  with one of those slots reserved for ambient selection every third tick;
- at most two additional ambient NPCs every tick;
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

This limits host NPC dynamic collection to 60 records per second regardless of
population. Ambient selection inspects at most eight ring candidates and skips
pilots undetectable by the local player and the bounded participant-proxy
check. Participant attackers, participant targets, and owned-craft engagements
feed deterministic priority rings. One priority-capable slot gives participant
target interest first refusal before falling back to announcements, combat
priority, and finally the ambient ring.

NPC ship, faction, name, outfit, AI, and leader fields are collected once and
cached, then accompany that NPC's selected round-robin announcement. Dynamic
motion, health, energy, target, weapon set, and control fields are sampled only
for the selected records. Never rebuild static NPC data on a world tick.

Reconciliation runs only when a fresh record arrives. Initial `pilot.add`
chooses position. Subsequent records normally turn position error into capped
velocity bias, but an error over 2,000 units moves the replica halfway toward
the authoritative coordinates before applying that bias. The threshold uses
squared distance, and the partial correction occurs only on packet arrival;
there is no per-frame position setter or full snap. Direction changes use a
capped angular step based on elapsed record time. Health, energy, target,
weapon set, and controls avoid redundant setters. Because replicas are
damageable, health and energy compare the live pilot value on each fresh record;
otherwise unchanged authoritative values could not repair unrelated local
damage. NPCs, player-owned craft, and persistent objects all integrate through
local physics between records and receive the same packet-arrival motion
correction; players remain authoritative for their own real ship. There is no
population-wide smoothing update.

NPC and craft replicas smoothly steer velocity toward a fresh authoritative
record plus a prediction of half the observed record interval, capped at 0.125
seconds. This lets local physics integrate continuously instead of exposing the
round-robin cadence as a velocity pulse; a modest trailing offset is acceptable.
Their packet-arrival direction correction uses the player-proxy angular rate
and accounts for up to 0.25 seconds between sparse records, but remains capped
and never snaps directly to the authoritative angle.
Fresh authoritative targets also repair stale native AI attack tasks. Only
`attack`, `attack_forced`, and `attack_forced_kill` are touched: a mismatched
task is retargeted while an authoritative absent target clears it. Other tasks,
including fleeing, landing, returning, and inspection, remain local AI state.
For a guest-owned entity, the host relays its proxy's current motion instead of
rebroadcasting the coordinates cached at owner-packet receipt; health, target,
controls, and lifecycle remain owner-authoritative.

Players still publish ordinary unreliable state at 15 Hz while idle. Guest
state uses the motion channel and the host immediately rebroadcasts each
accepted fresh record, in addition to retaining it for the canonical world
tick. Reliable control messages are emitted only when held input changes;
Naev key-repeat callbacks must never force another message. Player velocity in
a fresh record is applied directly; when its ordinary `vx` and `vy` are zero,
residual replica drift is zero as well. This is not a separate stopped state or
edge.

Player death is an owner-authoritative reliable lifecycle event. The local
player's lethal disable transition is checked for zero armour and immediately
sends the existing `entity_remove` message with `kind=player` and
`reason=death`; the final explosion and sampled zero-armour state are
idempotent fallbacks. The host validates ownership and broadcasts the removal.
Every non-owner clears no-death protection and receives zero health, allowing
Naev's normal multi-frame death sequence to run; `pilot:explode()` is not used
because that API deletes the pilot immediately. A per-visit tombstone
suppresses delayed state and manifest repair so a dead proxy cannot reappear or
retain its old velocity. A zero-armour state received before the reliable
removal is treated as the same idempotent death event.

Naev's Lua API does not expose the player's actual `player_acc` throttle used
by autonav. Manual acceleration remains exact from input state. During autonav,
the runtime infers the existing binary acceleration field from forward
velocity gain and from sustained forward speed above the ship's no-thrust
drift speed. Only changes in that inferred field publish reliable control; the
15 Hz state stream carries its current value normally. This is deliberately a
visual/physics approximation for remote engine trails, not a new stopped or
autonav protocol state.

Guest steering, acceleration, reverse, target/fire/weapon edges, and outfit
activate/deactivate edges are reliable. Active-outfit inventories are never
included in periodic state or control records. The host applies edges to the
guest's `p2p_remote_control` player proxy, so weapons physically interact with
host NPCs, craft, player proxies, and persistent-object pilots. The host
broadcasts each canonical action to every gameplay peer; guests apply it only
for their accepted host/epoch and ignore self-owned echoes.

The green entered/orange left notifications remain the lifecycle notices.
Once per join, reliable chat also restores the original identification
exchange: the host announces its captain and ship and asks the guest to
identify itself; the guest announces its own captain and ship without issuing
the same demand.

## Host recovery

The host lease is five seconds and deterministic recovery lasts two seconds. A
fresh, remotely acknowledged incumbent wins. If recovered claims conflict
without a live incumbent, node ID resolves the winner.

When a guest is elected:

- every existing ambient host-owned NPC replica becomes authoritative
  immediately;
- its already-running described AI is reinitialized for authority;
- its replica tasks are cleared and no-death is removed;
- NPCs owned by still-connected guests remain guest-authoritative and the new
  host continues relaying their records;
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

Disable speed input only when networking is online and another gameplay
participant has been detected in the current system. A reachable directory by
itself, an unanswered connection attempt, another-system activity, and stale
membership without a reachable network all preserve ordinary solo time
controls. While shared-time locking is active, enforce both
`player.autonavSetSpeed(1)` and `player.setSpeed(1)`. The update hook corrects
autonav's own per-frame ramp; one-second maintenance and modal chat/hail
pumping preserve the lock. `HOST_ALONE_GRACE` remains the single duration for
the host-alone transition after same-system peer evidence.

HUD countdown phase selection runs as a bounded 10 Hz scheduler. The status
adapter crosses into pilot effects only when a bright/dim phase changes.

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
