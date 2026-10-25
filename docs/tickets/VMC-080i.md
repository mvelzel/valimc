# VMC-080i — Complete owner timing observations

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).
Depends on: [080h](VMC-080h.md).

The tick timer currently measures only `run_tick`. Lifecycle, transfers and
commit preparation after it also occupy the same owner, as do player, generation,
light and storage callbacks between ticks. Pooled durations and sampled stacks
cannot distinguish those costs or choose the next Elixir/Rust boundary.

Measure completed tick callbacks through lifecycle, and publish cumulative owner
callback wall times without messages to the observer. Sample exclusive phase
times and workload counts on the first and every twentieth executed tick.
Separate detailed sample counts from complete callback counts and simulation
progress. Keep one bounded row per owner, fixed phase names and dead-owner cleanup.
Retain owner-specific interval observations in the exported report/history.

Acceptance:

- A completed automatic tick includes lifecycle and commit preparation in MSPT;
  inactive or frozen owners do not gain completed simulation ticks.
- Sampled phase times partition the callback; nested work is not double-counted.
  Exceptions preserve the callback's behavior and clear timing context.
- Reports distinguish interval totals, lifetime maxima and sampled phase costs,
  with explicit workload timestamps and coverage limits.
- Preserve tick/phase order, timers, transfer fences and gameplay state; no
  simulation or data-representation refactor belongs in this slice.
- Targeted profiler/owner tests and publication audit pass. The user does the
  gameplay check; no GUI client, hosting stress tester or flight benchmark.

Reference: 080h's pinned vanilla/Pumpkin comparison and reproduced owner timing
gap. This slice observes the current scheduling policy; changing it is separate.

Implemented locally: all owner call/message/load callbacks publish bounded wall
time summaries; normal tick durations include lifecycle and commit preparation.
One in twenty executed ticks publishes exclusive phases and pre-tick workload
counts, using the existing entity chunk index. Owner summaries use concurrent
ETS writes and retain no entity/world payloads. The observer exports capture and
interval deltas, with explicit warmup, sample coverage, ages and lifetime maxima.
History caps work detail at eight owners per interval; final capture totals cover
surviving owners. Details are in JSON; the existing browser still shows its
duration and owner tables, without new phase charts.

Checks: 41 focused profiler/timing tests pass, including automatic owner ticks,
exception/throw cleanup, exclusive accounting, sampled workload reads, bounded
unknown tags, dead-owner cleanup and new-owner capture exports. The broader
52-test owner/transfer/generation/light/profiler run passes. Its first run had a
`sky_source <= motion_blocking` assertion fail by one; an
isolated run with baseline owner/profiler code passes, and the broader follow-up
passes. The fixture's terrain coordinates depend on a unique integer, so these
runs do not establish a matched terrain regression or prove the assertion stable;
terrain code was not changed.
Raw follow-up and baseline logs are in `.local/simulation-audit/owner-timing/`.

Vanilla `clock`, `client_tick`, `cooking_tick`, `mob_ai` and plain/encrypted `tcp`
pass (5/5 stages). Formatting, exact diff checks and publication/docs/layer audit
pass. No new native code belongs to this slice. Earlier 080f/g prototypes remain
unchanged and uncommitted; their diff hash still matches the audit manifest.

No new deployment or live gameplay check. Sampling overhead and production phase
costs are not established by these functional tests. Next: combine these
observations with the activity and entity-frame work before the user's next
deployment/profile; do not claim this instrumentation solves the throughput gap.
