# VMC-056e — Report completed simulation TPS and stalled owners

Status: Awaiting client
Milestone: Operations, alongside M3 at the user's request
Depends on: VMC-056b, VMC-056d.

The user's 32-view/10-simulation VPS capture exposes clock TPS near 20 while
the simulation owner completes about 5.84 ticks/s. Make the headline, rolling
windows and graph describe simulation progress. Keep clock progress separately
named; observations must never change tick scheduling or query simulation owners.

Acceptance:

- Simulation TPS is the slowest measured live region owner's completed ticks per
  elapsed observation interval, capped at the configured rate outside sprints.
  A stalled owner contributes zero; idle owners withdraw their tick rows. A new owner without a baseline and a server
  without measured owners have an unavailable rate, not a healthy fallback.
- Persist simulation and clock rates separately in health snapshots/history.
  Weight rolling windows by measured elapsed time and omit unavailable rates.
- Chat, LiveView and standalone exports use the same meanings. Graphs use real
  elapsed time, leave missing observations as gaps, and show region p95 MSPT.
  Old captures retain an explicit clock-history label; never invent past
  simulation rates from MSPT or the last owner snapshot.
- Regression tests cover a healthy clock with a slow owner, complete stalls,
  warmup, owner replacement, unequal sample intervals and viewer/export labels.
  No Minecraft driver or benchmark; the user tests gameplay personally.

Evidence: `/Users/mvelzel/Downloads/valimc-profile(2).json`, a completed 60.020 s
capture on the user's two-vCPU VPS. Final clock rate 19.474 TPS; owner rate
5.842 TPS, interval mean 147.234 ms, lifetime max 1005.207 ms, mailbox 60.
The latest global region ring has median 110.038 ms and p95 181.806 ms. Of 442
health-history points, 122 have region p95 above 100 ms; none contains simulation
TPS history, so that graph cannot be reconstructed retrospectively.

The trial changed view 4→32 and simulation 4→10 together; it does not isolate
render-distance cost. The capture's largest reduction consumers are the region
owner (434.6M) and connection (249.1M). Sampled paths include natural spawning,
mob simulation, chunk installation/light halos, replication and region-log I/O;
observations are not exact CPU attribution. This slice corrects reporting,
without claiming to fix those performance costs.

Implementation: the observer derives interval rates from existing per-owner ETS
counters, then publishes their minimum as simulation TPS and the environment
clock rate as `clock_tps`. Both are retained in one-second history points with
their elapsed interval. A zero completion delta remains zero; missing baselines
remain null. Empty/manual owners withdraw their rows when they stop scheduling
ticks. No owner query, new per-tick message or scheduling rule is added.

LiveView and standalone reports label simulation and clock progress separately,
plot TPS and region p95 duration on elapsed-time axes, break paths at missing
observations, and refresh live views every two seconds. Legacy exports explicitly
retain their clock-history label. Chat identifies both rolling rates, weighted
by elapsed interval instead of sample count. Frozen and sprint state remain
explicit; normal simulation TPS is capped at the configured tick rate.

Checks: 37 targeted profiler, LiveView, tick and regionizer tests pass, including
the previously healthy-clock/slow-owner case, zero-progress stalls, warmup,
owner replacement/withdrawal, unequal intervals, chart gaps and export labels.
Standalone JavaScript syntax and the same stall/gap/spacing/MSPT chart scenarios
pass in Node. Vanilla `commands` and `tcp` pass. Private logs remain under
`.local/profiler-checks/simulation-tps-*`; the regionizer suite logs one disposable
fixture checkpoint failure during cleanup, with no failing assertion.

Client: the user checks the deployed health graph while playing at view 32 and
simulation 10; no graphical client driver or benchmark is run for this slice.
