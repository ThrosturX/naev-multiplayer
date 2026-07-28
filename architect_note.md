No agent may edit this file.
This file documents the architect's vision.
Developement may drift, but the vision is the ultimate goal.

# p2p world sharing:

##  the big idea:

- when a player is playing alone, it feels exactly like single player (or as close as possible given other constaints)
- It's like everyone playing solo locally, except we allocate whoever enters the system first as the NPC spawning authority to prevent divergence
- Playing as a guest is as close to playing as a solo player as possible, with the exception that other players and NPCs have setNoDeath(true) and are instead killed with explode() when the server says it's dead (or if the player asks (what about [ID]? and the server says "there is no [ID]")
- the host doesn't distinguish between peers, anyone in "this system" is a peer, and any message about "this system" is broadcast() to the network <- USE ENET FOR WHAT IT IS MEANT FOR
- if the host disconnects, some other peer takes over, inheriting whatever they already have locally as their own
- if naev has claimed a system, we yield to the single-player storyline aspect of the game and refuse to guest (this means that we host even if there is another host; it does not matter which host other players join if they are guest eligible and there are multiple hosts)

### protocol simplicity
- Ideally, it's as simple as possible. Something like this:
1. player enters system, no host available, I am the host but not hosting
2. guest enters system, joins host; host is now hosting
3. hosting hosts update all peers, e.g. by broadcasting like:
[ID] [simulation information...] (optionally there are N entries in the broadcast)
4. peers either: update [ID] or request [ID] to be synced in which case:
host broadcasts something like
[ID] [name] [type] [outfits] [etc]
5. peers periodically update the host on their status, e.g. health, position, velocity, direction, active outfits
6. eventually peers know everything the host has told them and everyone is in sync
7. if an NPC is targeted by a host, the host broadcasts that [ID] [sim info...] preemptively; if a guest targets an NPC (or player, honestly there should be no difference) then the guest requests an update about [ID] from the host
8. space objects are not spawned by the host, but by clients' connections to the directory, but the host is authoritative of the object's current state (position, velocity, hitpoints, etc)

## p2p multiplayer balance:
- time controls are disabled unless the host is alone, including pausing
- the host resolves a short grace timer before time controls are resolved after the last guest leaves
- some ships have a time constant, it's important that the "1x standard" applies to multiplayer: regardless of what ship the host is in, the simulation itself should run at canonical 1x, but the host might experience their own ship as slower or faster depending on the time factor
- peers and hosts are treated equal, so a host cannot enforce anything on a peer. this means that peers are responsible for their own health, position, velocity, active outfits, direction, etc
- the same applies to space objects, any peer can attempt to create or destroy a space object by legitimate in-game means, the host is authoritative only for relaying the position of these objects, which can receive different amounts of damage on guest simulations (the final blow might seem drastically overpowered in the wost case, but that's acceptable)

## p2p world sharing directory:
- the directory contains persistence data such as: objects in space, death race contestants, recently active hosts, etc
- the directory's MAIN GOAL is to assist peers in finding each other, making hole punching nice and easy so nobody needs to know anything about networking
- the directory's SECONDARY GOAL is to augment the multiplayer experience with persistent objects such as message buoys, temporary unstable wormholes, system markers, and other tentative multiplayer outfits that don't exist today because the game is mostly single player.
