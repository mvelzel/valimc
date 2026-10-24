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
health dashboard refreshes every ten seconds over WebSockets. Save a report as a self-contained
HTML file to inspect it later, or download its JSON for analysis.

## Commands

| Command | Shows or does |
|---|---|
| `/spark` | Command help |
| `/spark profiler start --timeout 120 --interval 20` | Record for up to 120 seconds; target a 20 ms sampling delay |
| `/spark profiler start --process Valimc.World` | Select process groups by a case-sensitive name substring |
| `/spark profiler start --include-waiting` | Include waiting processes to inspect idle stacks |
| `/spark health [show]` | Print health and link a live dashboard |
| `/spark tps` | Rolling world-clock TPS, region min/median/p95/max MSPT and scheduler utilization |
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

Each region simulates independently. Region MSPT is the mean, p95 and maximum of
the last 100 measured region ticks, across owners. The region table shows each
owner's latest observation interval, tick duration, lateness, sample age and
maximum since that owner started. A new owner needs two observations for an
interval rate. Clock TPS is measured from actual clock progress over the latest
health interval; it can stay healthy while one region falls behind. Frozen and
sprint states affect the expected rate. Commands average available observations
over 5 s, 10 s, 1 m, 5 m and 15 m windows; these warm up after startup. Region
duration statistics use the latest 100 ticks, rather than claiming Java's single
global tick windows. Health history retains up to 15 minutes.

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
its public HTTP(S) origin, such as `https://valimc.fly.dev`. The public origin
controls chat links, LiveView's allowed origin and the WebSocket CSP source.
Terminate HTTPS at the reverse proxy and route WebSocket upgrades to the same
listener. Unknown report tokens still return 404; `/healthz` returns only `ok`
for deployment checks. Anyone holding a report link can read it. See
[Fly hosting](hosting.md) for the supplied single-server deployment.

Completed recordings are also saved under `.local/profiles/` as `.html` and
`.json`; `config :valimc, profiler_path: "/path/to/profiles"` changes the folder.
`VALIMC_PROFILER_PATH` sets the same folder in a release.
Files remain until you remove them. The last 16 report links remain available
until server restart or observer restart; save a report for longer retention.
An active capture survives a viewer restart, but an observer crash cancels it.
If disk saving fails, the in-memory report remains available at its link.
These are ValiMC reports; spark.lucko.me does not read this JSON format.
