# Profiling while playing

ValiMC includes a spark-style profiler for Elixir/OTP. Join as an operator
(permission level 3 or 4), open chat and run:

```text
/spark profiler start --timeout 60
```

Play through the problem, then run `/spark profiler stop`, or let the timeout
finish the recording. Chat shows a clickable browser link when recording starts
and when it finishes. `/spark profiler open` returns the running report again;
`/spark profiler info` shows elapsed time. `/spark profiler cancel` discards it.
Console and RCON accept the same commands without the leading slash.

The Phoenix LiveView browser UI follows spark's dark palette, JetBrains Mono,
compact widgets, controls and dense call-tree rows. Commands use spark's
lightning prefix, colors and multiline statistics. Architecture-specific labels
identify BEAM and independent region measurements.

The browser has a searchable call tree, a flame graph with click-to-zoom, hot
methods, process reductions/memory/mailboxes, per-region tick measurements, ETS
memory and server counters. A running report refreshes every two seconds. The
health dashboard also refreshes every two seconds over WebSockets. Save a report as a self-contained
HTML file to inspect it later, or download its JSON for analysis.

## Commands

| Command | Shows or does |
|---|---|
| `/spark` | Command help |
| `/spark profiler start --timeout 120 --interval 20` | Record for up to 120 seconds; target a 20 ms sampling delay |
| `/spark profiler start --process Valimc.World` | Select process groups by a case-sensitive name substring |
| `/spark profiler start --include-waiting` | Include waiting processes to inspect idle stacks |
| `/spark health [show]` | Print health and link a live dashboard |
| `/spark tps` | Rolling simulation TPS (slowest region), separate world-clock TPS, region min/median/p95/max MSPT and scheduler utilization |
| `/spark tickmonitor [--threshold-tick 50]` | Toggle slow-region-tick messages for this player; expires after ten minutes |
| `/spark processes [--sort memory]` | Top eight observed processes from a running profile; also accepts `mailbox` or `reductions` |
| `/spark schedulers` | Normal, dirty CPU and dirty IO scheduler utilization and run queue |
| `/spark heapsummary` | BEAM memory categories and a dashboard link |
| `/spark ets` | Largest eight ETS tables by allocated memory |
| `/spark gc` | Per-process GC collection and reclaimed-word totals since boot |
| `/spark ping` | Mean/min/max of players' latest keepalive round-trip times |
| `/spark activity` | Recent profiler activity |

Timeout is 1–600 seconds (default 60), interval 10–1000 milliseconds (default 20),
and the process filter is at most 128 bytes. Only one recording runs at a time.
Unknown options and duplicate flags are rejected before starting. Java allocation,
heap-dump and collector controls have no equivalent here; GC reporting never
forces a collection. Use `/spark help` to see the supported commands.

## Reading measurements

Stack observations count sightings of running/runnable processes. They are
statistical observations, not CPU time: reducing the interval improves coverage
and adds overhead. The observer reads up to 128 processes per pass, rotating
through a discovery window of 4096. A large node has a longer effective interval
per process. Reductions rank each observed process's work independently; they
are not attributed to whatever stack happens to be visible. Waiting stacks can
help explain blocked owners, but do not represent CPU consumption.

Each region simulates independently. The primary **simulation TPS** is the
slowest live ticking owner's completed ticks divided by the elapsed observation
interval. It includes time lost to queued work, scheduling and blocked owners;
an owner completing no ticks contributes zero. A new owner needs a baseline
before it has an interval rate. No measured owners means unavailable, with no
fallback to the world clock. Owners that stop scheduling ticks withdraw their
observations. Normal TPS is capped at the configured rate; sprints can exceed it.
Frozen simulation is labeled as such. The region table identifies each owner's
rate, latest duration, lateness, sample age and maximum since startup.

World-clock TPS is shown separately: the environment clock can progress at 20
while a region and its players advance at 5. The headline is a bottleneck metric
over independent owners; inspect the region table to locate it. Commands weight
available intervals by elapsed time over 5 s, 10 s, 1 m, 5 m and 15 m windows.
These warm up after startup. History records both rates, uses elapsed-time
spacing and leaves unavailable simulation observations as gaps. Old captures
have explicitly labeled clock history; past simulation rates cannot be inferred
from their MSPT or last owner snapshot.

Region MSPT is the min, median, p95 and maximum of the latest 100 completed
region ticks across owners, also shown as a p95 history graph. These durations
measure tick work; they exclude time awaiting the next tick or processing other
mailbox work. A blocked tick cannot publish its duration until it completes;
its zero TPS and increasing sample age expose the stall meanwhile. These are
region-duration statistics rather than Java's single global tick windows.
Health history retains up to 15 minutes.

Scheduler utilization is sampled wall-time utilization, not host CPU usage.
Dirty scheduler utilization helps identify native work, but sampled stacks only
show the BEAM/NIF boundary. Rust functions inside a NIF and allocations held in
native resources are not resolved. Process memory, shared binaries and ETS are
different categories; memory rollups overlap. GC totals do not measure pauses.
Short calls, exited processes and activity between observations can be missed.
The capture retains at most 4096 distinct stacks and 4096 process summaries;
the viewer reports dropped stack observations when full. Tick monitoring reads
a 256-entry ring of ticks lasting at least 10 ms, reporting at most once per
second per subscriber (maximum 16); a burst can overwrite older slow ticks.

## Local reports

By default the viewer binds to `127.0.0.1`, on an automatically chosen port. Its URLs
contain random bearer tokens; anyone with a token and access to that loopback
listener can read that report. There are no uploads to spark or other services.
Phoenix routes and LiveView run inside the server's OTP supervision tree; Bandit
provides HTTP and WebSocket connections. Clients and fonts are served locally.
The endpoint allows 64 connections and 16 connected report views. Request lines
and headers are limited to 4 KiB, with at most 32 headers; WebSocket messages are
limited to 16 KiB. Filters accept 128 bytes. Tables show at most 500 rows, call
trees 1,000 visible rows / 128 expanded branches, and flame graphs 2,000 frames /
24 levels. Only one refresh timer runs per view. Signed sessions, CSRF and local
origin checks protect LiveView; report tokens still authorize report access.
When playing on a remote server, forward the port printed in chat with SSH and
open that URL on your computer. `config :valimc, profiler_port: 25580` pins the
port for forwarding; the default is `0` (automatic).

For a hosted viewer, set `VALIMC_PROFILER_BIND` to the listener address,
`VALIMC_PROFILER_PORT` to its internal HTTP port and `VALIMC_PROFILER_URL` to
its public HTTP(S) origin, such as `https://profiles.example.com`. The public origin
controls chat links, LiveView's allowed origin and the WebSocket CSP source.
Terminate HTTPS at the reverse proxy and route WebSocket upgrades to the same
listener. Unknown report tokens still return 404; `/healthz` returns only `ok`
for deployment checks. Anyone holding a report link can read it. See
[Ubuntu hosting](hosting.md) for the supplied single-server deployment and SSH tunnel.

Completed recordings are also saved under `.local/profiles/` as `.html` and
`.json`; `config :valimc, profiler_path: "/path/to/profiles"` changes the folder.
`VALIMC_PROFILER_PATH` sets the same folder in a release.
Files remain until you remove them. The last 16 report links remain available
until server restart or observer restart; save a report for longer retention.
An active capture survives a viewer restart, but an observer crash cancels it.
If disk saving fails, the in-memory report remains available at its link.
These are ValiMC reports; spark.lucko.me does not read this JSON format.
