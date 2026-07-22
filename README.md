# Naev Multiplayer Plugin

Experimental multiplayer for Naev, with two independent modes:

- The existing arena client/server mode.
- An opt-in P2P session that shares ordinary star systems without replacing
  the player's ship, save, missions, landing, jumping, or loadout.

Naev must be built with `lua_enet`; set `lua_enet = true` in `conf.lua`.

## P2P setup

Open **Info → Multiplayer → P2P Session Settings**. Enable P2P and configure:

- **Listen port**: `0` selects an ephemeral port. Use a fixed, forwarded UDP
  port when peers must connect from another network.
- **Directory**: defaults to `79.76.110.205:60939`. Its absence is silent and does
  not stop direct discovery. This is also an ordinary initial peer address: a
  player listening there is contacted exactly like a bootstrap peer.
- **Bootstrap peers**: manually maintained reachable endpoints. In Naev's text
  input, enter the address and port separated by a space, such as
  `127.0.0.1 62001`; the plugin stores the canonical `address:port` form.

Peers remember up to 32 recently seen endpoints. On entering a system they ask
connected, configured, and remembered peers for the current host. If no host is
verified in 1.5 seconds, the lowest-ID claimant becomes host. This is direct
UDP connectivity only: there is no NAT traversal or traffic relay.

The host owns the system's NPC population. A guest removes its local ambient
and mission NPCs and recreates the host's population; disable P2P before
entering a system where your own mission state must control its pilots. Remote
players use their real ship and outfits as invincible local proxies. Damage to
your actual player remains entirely local, so god mode and other local behavior
are neither synchronized nor checked.

Player-owned escorts, fleet craft, followers, and deployed craft remain owned
by their player. The system host relays their owner-authoritative state and
does not adopt them as ambient NPCs when the owner leaves.

Autonav and the speed key are disabled while participating in a shared system
to prevent local game-speed changes from desynchronizing peers. Normal controls
are restored on system leave or when P2P is disabled.

The wire protocol is `MP2P/1`. Incompatible peers are ignored without changing
ordinary play. A directory-only node answers host queries but cannot claim or
join systems.

Player names travel unchanged on the wire. When a remote player has the same
name as the local player (or another visible remote), only that remote proxy is
given a local display suffix such as `#2`; a player's own name is never changed.

## Directory service

`directory/main.lua` is a minimal standalone directory using the same ENet
transport and `MP2P/1` codec as players. It stores no accounts or gameplay
data. Active hosts refresh their claim every 10 seconds. Claims remain active
for the directory connection's lifetime; disconnected claims are retained as
bounded stale hints until superseded or evicted. Clients retry configured
directory/bootstrap connections every five seconds, and hosts immediately
re-announce after reconnecting. A stale hint never prevents the normal local
claim fallback when its old host cannot be reached.

It requires Lua 5.1, ENet, and the `lua-enet` binding. On Ubuntu or Debian:

```sh
sudo apt update
sudo apt install lua5.1 liblua5.1-0-dev libenet-dev luarocks build-essential
sudo luarocks --lua-version=5.1 install enet
lua5.1 directory/main.lua '*:60939'
```

For an always-on installation, copy the repository to
`/opt/naev-multiplayer`, install `directory/multiplayer-directory.service` in
`/etc/systemd/system`, then run:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now multiplayer-directory
sudo systemctl status multiplayer-directory
```

Allow inbound UDP port `60939` in both the VM's OS firewall and its cloud
network/security-list firewall. Players enter the public address in Naev using
the space-separated UI form, for example `directory.example.org 60939`.
The service supplies discovery only: peers still need direct UDP reachability,
and gameplay traffic is never relayed through the directory.

See `directory/OCI.md` for an exact Oracle Cloud Always Free deployment and
verification walkthrough.

## Arena mode

Arena **Connect** and **Host Server** retain the original client/server flow.
The arena server is authoritative and uses its existing lobby and arena assets.
P2P code is isolated under `scripts/multiplayer/p2p/` and is not loaded by the
arena client or server.

## Validation

Run the standalone protocol and reconciliation tests:

```sh
lua tests/test_p2p.lua
lua tests/test_p2p_directory.lua
lua tests/test_p2p_integration.lua
lua5.1 tests/test_p2p_directory_enet.lua # when lua-enet is installed
```

Syntax checks and mocked tests do not establish engine networking behavior.
Use separate Naev processes for host/client acceptance testing; see
`MAINTAINERS.md`.
