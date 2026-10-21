# VMC-077a — Runtime safety: supervision, world spec and settings, commands off the connection

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan); uses VMC-077b's
generation pool.

Before: the application was one flat `rest_for_one` supervisor of 35 children
allowing 3 restarts in 5 s, so a burst of accept errors or a crash loop in any
early table holder stopped the whole server. `world.json` was re-read on every
region load and any read failure turned a generated world into flat terrain,
while `/setworldspawn` rewrote that same file in place. Commands ran inside the
issuing connection and called owners and other connections synchronously, so a
slow owner or two operators targeting each other killed or stalled sessions.
`/save-all`, `/locate` and `/place` ignored the executing dimension.

Scope: the five runtime fixes of VMC-077 phase 1a. Not here: region-load
backoff and chunk streaming (VMC-077e), pool sizing and NIF hygiene (VMC-077b),
atomic multi-region `/fill` and `/clone` and a pure command source with
selectors over entities (VMC-077o).

## What changed

- **Supervision.** The root is `rest_for_one` over five domain supervisors,
  each allowing 10 restarts in 10 s: infrastructure (settings, tick rate,
  clock, stopwatches, admin lists, worker pools; `one_for_one`), storage
  (player logs and stores), world (registries, directory, region writers,
  regions, protos: a directory restart still fences every owner and writer),
  players (admission, login workers, command workers, connections) and network
  (listener, console, RCON; `one_for_one`). The root allows 3 domain restarts
  in 30 s. A directory restart no longer drops every player or the listener. Metrics counters, the terrain board and the autosave flag are
  created in `Application.start` and owned by the application, not by
  processes that only held them. Listener and RCON acceptors share one accept
  loop that backs off (10 ms doubling to 1 s) on any accept error but a closed
  socket.
- **World spec.** `Valimc.World.Spec` reads `world.json` once at start: the
  generator kind, seed, recorded settings, and per dimension its generation
  (nil, `{:ok, spec}` or `{:error, reason}`) and whether it is decorated. A
  file that does not read stops the start; only a missing file means ValiMC's
  flat profile. `world.json` now holds only `{"generator": …}`, written once,
  crash-safely, at creation or import. `Generator.of/recorded/decorated?/spec/
  generates?/current/current_settings/settings` and `record_import` are gone.
- **Settings owner.** `Valimc.World.Settings` holds the world spawn
  (vanilla's `RespawnData`: dimension, block, yaw, pitch), the default game
  mode, `white-list` and `player-idle-timeout` in `settings.json`. It writes the
  whole file through `Valimc.DurableFile` (temporary file, fsync, rename,
  directory fsync) and publishes only after the write; a failed write changes
  nothing. `/setworldspawn` stores the executing dimension and pitch; new
  players, respawns without a respawn point, `/spawn`, the End's exit and the
  console's source use the spawn's dimension (`MinecraftServer.
  findRespawnDimension`); `/defaultgamemode` persists. `Admin.Lists` writes a
  list file before it publishes its rows, and its switches moved to the
  settings owner. `RegionWriter.durable_write` became `DurableFile.write`.
  Worlds whose `world.json` keeps a spawn or that have an `admin-settings.json`
  are refused with a message (VMC-077 D4: no migration).
- **Commands off the connection.** A player's command runs as the
  connection's `:command` job (`Valimc.Session.Commands`, a task of
  `Valimc.CommandWorkers`) with a snapshot source; owner calls happen in the
  job. Players, the issuer included, are changed through `{:command_op, …}`
  calls sent at once with `:gen_server.send_request` and awaited under one
  deadline (`Commands.Remote.run_all/2`); feedback and packets to the issuer go
  through its mailbox in order. Commands run one at a time, up to eight queued.
  Any raise, exit or the 60 s deadline is `command.failed`; the console and
  RCON run the same `Commands.run/2` in their own processes. Command
  suggestions run as a `:suggestion` job (only the latest waiting request is
  kept). `Source` lost its connection state: handlers return their result.
- **Fenced block writes.** `World.get_block/set_block/remove_block` are
  deleted. `/setblock` observes the block and commits at the section fence it
  read (`Region.set_blocks/3`), retrying a stale fence. Creative placement of a
  block item without modelled placement is a creative placement command like
  the modelled ones: its block's default state on a replaceable block beside
  the clicked face, admitted against the player's body and committed through
  `Region.place_block/4`; any other use is corrected by a correction job.
  Tests read and write blocks through `Valimc.TestBlocks` (fenced).
- **Dimensions.** `Source` carries the executing dimension; a command job runs
  in it. `/save-all` reaches every running region of every dimension by its
  scoped registry key, looked up in its own dimension and never admitted.
  `/locate structure` and `/place` use the executing dimension's generation;
  their worldgen calls (state creation, `/locate` search, `/place` plan and
  placement) run as jobs of `Valimc.Worldgen.Pool` (`Pool.run/2`), never in the
  command's process. `/particle` reaches viewers in the source's dimension only.
- **Ingress.** Frames and the receive buffer are capped per phase: 1 KiB in
  handshake and status, 32 KiB in login, `max_packet_bytes` in configuration
  and play (`Connection.frame_limit/1`). Connections run with a 64 MiB
  `max_heap_size` (a player measured about 110 KB at view distance 2). RCON
  closes a client silent for `rcon_idle_ms` (60 s). Chat applies vanilla's
  `isChatMessageIllegal` check, as commands did.

Vanilla now leads where ValiMC used to differ: a command's own feedback follows
the packets its effect broadcasts (the tick state, `chunks_biomes`, a death
message), and a corrected block interaction sends the block updates before the
acknowledgement, as vanilla's `ServerGamePacketListenerImpl` does.

## Acceptance: the removed bug classes

| Bug class | Why it cannot occur now | Test |
|---|---|---|
| An owner timeout kills the session | No command, suggestion or block write calls an owner from the connection; a command's exit or deadline ends its job as `command.failed` | `command_connection_test` "a command whose owner does not answer fails and the session lives on"; `rcon_test` "a command whose owner exits answers command.failed" |
| Mutual commands stall or report wrong targets | Fan-out is `send_request` with one deadline from a job; neither connection waits; unanswered targets are not counted | `command_connection_test` "two operators giving to each other at once both get their items" |
| The listener stops the application | Accept errors back off; a crash loop is absorbed by its domain supervisor | `supervision_test` (scripted `emfile`, `enfile`, `system_limit`, `econnaborted`; four listener and four stopwatch-owner kills leave connections and regions untouched); `directory_recovery_test` (a directory loss fences owners and writers, the session and listener live on) |
| `world.json` falls back to flat | Read once at start, failure fatal; written once, crash-safely; runtime settings live elsewhere | `world_settings_test` "world.json is read once; a broken one is an error, never flat" |
| Settings lost or torn by a crash | One owner, durable write before publish | `world_settings_test` (owner, failed write, unreadable and old formats) |
| Wrong-dimension commands | `Source.dimension`; `/save-all` per scoped key, no admission; generation by dimension | `world_settings_test` Serial: setworldspawn in the Nether, save-all from the Nether, locate a fortress from the Nether |
| Raw unfenced block writes from the connection | The raw API is gone; creative fallback and `/setblock` are fenced | `creative_items_test` (glass pane placed on air, refused on stone) |
| Pre-login memory per connection | 1 KiB / 32 KiB phase caps | `connection_test` "frames before configuration are small" |
| Illegal characters in chat | Same check as commands | `connection_test` "chat with illegal characters ends the session" |
| Idle RCON sockets hold every slot | 60 s idle close | `rcon_test` "an idle client is closed" |

Reference: 26.3 `SetWorldSpawnCommand` (`RespawnData.of(level.dimension(),
pos, yaw, pitch)`), `MinecraftServer.findRespawnDimension/setRespawnData`,
`ClientboundSetDefaultSpawnPositionPacket(RespawnData)`, `KickCommand`,
`TickCommand`, `FillBiomeCommand`, `KillCommand` (effects before
`sendSuccess`), `ServerGamePacketListenerImpl.isChatMessageIllegal`,
`DefaultGameModeCommands`. Vanilla has no RCON idle timeout and no frame caps
below 2 MiB; both are ValiMC bounds.

Checks (October 21, 2026): the touched flows' test files by name while
working; the full `mix test` through `scripts/heavy.py` at the end, 713 of 713
(108.8 s; a first run exposed a test that killed the clock and so re-enabled
natural regeneration for later suites, now killing the stopwatch owner
instead); vanilla stages `commands`, `placement`, `place`, `locate`,
`anvil_content`, `world_settings`, `spawn`, `game_mode`, `player_life`,
`world_border` and `tcp` pass (their oracle and bench scripts moved to
`World.Spec`, `World.Settings` and `bench/blocks.exs`). `--changed` selects
every stage here (`config/config.exs` is a global input), so the stages were
chosen by area. No client run: the milestone handoff covers `/setworldspawn`
in the Nether, creative placement of an unmodelled block item and a command
whose owner is slow.

Size: lib and config +1,546 / −1,154 lines over three commits (new: `World.Spec`,
`World.Settings`, `DurableFile`, the command job; gone: the world.json
re-readers, the raw block API, the preview placement path, the
connection-state threading through every command handler and its self-target
special cases).

Next / deferred:

- `RegionData` still answers raw `{:get_block}`, `{:set_block}` and
  `{:remove_block}` messages, used inside the owner (creative destruction) and
  by two region tests; folding them into the fenced path is owner work
  (VMC-077g).
- The process-dictionary dimension context remains outside commands; making
  every world API take `{dimension, key}` belongs with the regionizer
  (VMC-077j).
- Per-dimension world supervisors need per-dimension directories (VMC-077e,
  VMC-077j).
- Selector `world_limited`, `alive`, atomic `/fill` and `/clone`, and command
  targets beyond players are VMC-077o.
- Stopwatches and the clock still keep their own JSON files (VMC-077f's log).
