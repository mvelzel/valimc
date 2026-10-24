# VMC-056a — Built-in spark-style BEAM profiler

Status: Done
Milestone: Operations, advanced alongside M3 at the user's request
Depends on: VMC-077 ownership, metrics and command jobs; VMC-053 command tree.

Operators can start a bounded profile in chat, keep playing and inspect a local
browser report. Spark's familiar profiler/health/tps/tickmonitor workflow is
adapted to BEAM processes, reductions, schedulers, mailboxes, ETS and ValiMC's
region owners. This is original code; no upstream implementation is copied.

Acceptance:

- Permission level 3 commands work through chat, console and RCON; lower levels
  cannot discover or execute them. Start/stop/cancel/info/open and timeout work.
- Reports provide a call tree, flame graph, hot methods, process resource tables,
  per-owner ticks, memory, ETS, counters and a live health view; HTML/JSON exports
  work offline. Links are clickable in the unmodified 26.3 client.
- Sampling, history, stacks, processes, retained links, notifications and HTTP
  workers have explicit bounds. Tick writes use ETS, never the observer mailbox;
  observing an owner never grants authority or reads its simulation state.
- Explain sampling limits, distinguish stack observations from reductions and
  CPU time, clock TPS from region MSPT, BEAM memory from native allocations.
- Reject unsupported options, handle duplicate recording and cancelled timers,
  expire old links, retain reports after disk failures and escape HTML payloads.
- Client handoff: join, baseline `/stats`, use tab completion and `/spark health`,
  profile while moving, open/stop/report link, invalid option, cancel and timeout.

Reference (October 24, 2026):

- [spark command documentation](https://spark.lucko.me/docs/Command-Usage): user
  workflow and spelling only; no claim of spark file/viewer interoperability.
  Spark is GPLv3; implementation, UI and export schema here are original.
- [OTP scheduler documentation](https://www.erlang.org/doc/apps/runtime_tools/scheduler.html):
  enable scheduler wall time from the long-lived observer and compute deltas
  without blocking for a measurement window; normal/dirty pools are separate.
- Pinned Elixir 1.20.4 / OTP 29.1.1: `process_info/2`, `statistics/1`, `:json`, ETS;
  no Java-specific GC controls, tracing session or third-party dependency.

Ownership: `Admin.Profiler` owns recording/health and report ETS publications;
`Data.ProfileTicks` holds per-owner observations and a slow-tick ring;
`Net.ProfileWeb` has two fixed loopback workers. Command jobs receive snapshots.
World tick authority, fencing and journal/receipt data are untouched. Observer
restart loses active capture/links; viewer restart only changes its local port.

Checks (October 24, 2026): targeted commands/clock/admin/RCON/encryption run passed
36 tests; final private-build profiler/server/dispatcher run passed 18; fast suite
passed 577 tests/properties (221 excluded); all 26 selected vanilla stages passed
in 225 seconds, including commands and TCP. Mojang decoded the restricted custom
subtree and greedy-string codec alongside the unchanged vanilla command graph.
Node syntax check and publication/docs/layer audit passed. A concurrent build
briefly removed shared test assets; the isolated check build resolved that race.
The tick-monitor fixture uses a synthetic duration to avoid unrelated slow ticks;
a transient WorldTest frame-publication failure passed in isolation and in the
final full fast run with the same suite seed.

Client: dedicated tester PASS on October 24, 2026, Java 26.3/protocol 777,
run-03, private build `.local/profiler-client/_build` based on `95f9df87` plus
the profiler changes. Joined terrain, `/stats`, tab completion, health/link
confirmation, movement during capture, open/stop/cancel, unsupported `--alloc`
and automatic 3-second timeout passed. The browser's call tree, search/group,
flame zoom/reset, hot methods, processes, region ticks, memory/ETS, counters and
health passed. Client stopped and waited; status confirmed zero players.
Evidence: `.local/client-tests/VMC-056/` and `.local/profiler-client/`.

CUA's download-event wait stalled without returning a path. A separate headless
Chrome check invoked the actual JSON/HTML export handlers from the saved client
report: JSON preserved all 15,075 observations; the exported HTML reopened from
disk with eight tabs, a populated call tree and no live endpoint. No duplicate
tabs or server dependency remained. The temporary server was stopped afterward.

The first fixture used an incorrect operator wildcard, correctly denying access;
the reused dataset then reported invalid checkpoints, so run-03 used a whole
fresh dataset. No checkpoint, journal or receipt side was individually reset.
Remaining operations work is tracked by [VMC-056](VMC-056.md).
