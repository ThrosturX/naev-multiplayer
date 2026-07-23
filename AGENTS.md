# Repository Guidelines

## Project Structure

This repository is an experimental multiplayer plugin for Naev. The persistent
UI/event adapter is `events/multiplayer.lua`. Runtime networking is under
`scripts/multiplayer/`: `client.lua` drives a connected player, `server.lua`
runs the authoritative arena server, `syst_server.lua` runs the P2P system
server, `relay.lua` handles discovery, and `common.lua` owns shared wire-format
constants and decoding. The current P2P rendezvous directory is
`directory/main.lua`, backed by `scripts/multiplayer/p2p/directory.lua`. Game
assets and arena definitions live under `ai/`, `scripts/equipopt/`, `ships/`,
`ssys/`, `collision/`, `gfx/`, and `snd/`. Plugin metadata is in `plugin.toml`
and the legacy `plugin.xml`.

## Development Commands

There is no build system or standalone test suite yet. Before hand-off, run:

- `while IFS= read -r file; do luac -p "$file"; done < <(rg --files -g '*.lua')`
  to parse every Lua source file.
- `while IFS= read -r file; do xmllint --noout "$file"; done < <(rg --files -g '*.xml')`
  to parse XML metadata and assets.

The plugin requires a Naev build with `lua_enet` enabled. Network behavior must
also be checked with separate Naev server and client instances; syntax checks
cannot validate ENet behavior or engine lifecycle integration. See
`MAINTAINERS.md` for the smoke-test boundary.

## Style and Architecture

Match the surrounding Lua unless a touched section is being normalized: use
three-space indentation, `snake_case` locals/functions, and keep hook callbacks
named explicitly in the relevant `luacheck: globals` declaration. Do not shadow
Naev's translation function `_`; prefix intentionally unused arguments with
`_` instead. Keep `events/multiplayer.lua` focused on UI and lifecycle entry,
and put networking behavior in the appropriate module.

Treat the text protocol as a compatibility boundary. Define shared message
keys and payload parsing in `common.lua`, update sender and receiver together,
and preserve the distinction between reliable control messages and unreliable
high-frequency state updates. Validate all data received from peers before it
reaches pilots, outfits, hooks, or UI. Never log credentials or private relay
configuration.

Unlike ordinary gameplay plugins, multiplayer intentionally uses `hook.update`
to service ENet without blocking the game loop. Keep update handlers
non-blocking, drain only immediately available events, and avoid extra
per-frame work. Explicitly remove update, input, timer, and pilot hooks on
disconnect, stop, landing, or role changes. Persist only plain configuration;
never persist ENet peers/hosts, pilots, hooks, or other runtime handles.

Treat Lua/C crossings as expensive in hot paths. High-frequency state records
must contain only dynamic state; collect static identity, ship, outfit, name,
and faction data only when building manifests. Cache previously applied state
and do not call engine setters when the value has not changed. Bound ENet event
processing per frame rather than draining an unbounded queue, and prefer
reliable incremental add/remove messages plus explicit resynchronization over
periodic full-manifest broadcasts.

Do not use `pcall` to probe expected pilot or runtime state inside loops. Check
documented invariants such as handle existence explicitly, then prune, repair,
or resynchronize invalid state. Reserve `pcall` for genuinely recoverable
external boundaries where the underlying API can raise unexpectedly.

## Testing and Changes

Preserve the source repository's existing uncommitted P2P work; inspect the
diff before editing `client.lua`, `relay.lua`, or `syst_server.lua`. Do not
delete relay logs, scratch files, or `relay.lua.patch` unless asked, even though
they are currently untracked. Passing parsers or mocked tests is not evidence
that player-visible multiplayer behavior works. For protocol or lifecycle
changes, report the Naev versions, topology, host/client count, reproduction
steps, and whether disconnect/reconnect and save restrictions were exercised.

Keep commits focused and imperative. Pull requests should call out protocol
changes, compatibility assumptions, security implications, validation run,
and observed in-game results.
