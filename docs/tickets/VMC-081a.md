# VMC-081a — Fixed-workload tick budget harness

Status: Foundation
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).

User captures mix workloads and arrive one deployment at a time. Every 081
slice needs a matched before/after on the same terrain, population and
settings, on the host's two schedulers.

`bench/tick_budget.exs` plays a vanilla world (seed 20261020) with one real
loopback client at view 32 and simulation 10, the hosted settings. `prepare`
generates a template world once: the player's whole view around the spawn,
with the animals generation places. Each `run` copies the template, so terrain
and the starting population are fixed.

- `mobs` (capture 8; `combat` until 081d): survival at midnight with the
  daylight cycle paused.
  Hostiles spawn to the caps and attack; the client respawns at once when
  killed. A minute of warm-up fills the caps before measuring.
- `explore` (capture 9): a spectator at y 160 flies along +X at 20 blocks per
  second into terrain nothing generated, moving only while its chunk is
  there, as the vanilla client does.

It reports the owner hosting the player over the measured window: completed
ticks per second, per-callback-kind percentiles and totals per minute, sampled
phase means, heap, mailbox, workload counts and mean normal/dirty scheduler
use. Diagnostics: `PROFILE=stacks` adds a built-in profiler report of the window
(the same format as a user capture), `HEAP=1` the flat size of each section
field, `GCTRACE=1` the owner's collections, `PROFILE_EVERY=1` the phases of each
of the last hundred ticks and `PROFILE=memory` per-function allocation (too
heavy for a full mobs window). `MIN_HEAP` overrides the group heap minimum.

`Valimc.Data.ProfileWork` now counts every callback's duration in fixed
buckets per owner (250 µs to 1 s), so reports and the harness give interval
percentiles instead of only means and lifetime maxima. Its phase sampling rate
is configurable (`:profile_sample_every`, default 20) and each owner keeps the
phases of its last hundred sampled ticks, which shows periodic spikes.

The harness preloads the application's modules as a release does: checkpoints
decode with `:safe`, which refuses atoms of modules `mix run` has not loaded.
The template view is circular at 26.3's view distance (3,725 chunks at 32).
Generating it used about one core of ten: each group takes one generation
delivery at a time, so its owner's install rate bounds generation (081c).

Acceptance:

- Two runs of a scenario at one revision give comparable results; the report
  names its revision, dirty-tree flag, schedulers and harness hash.
- Start the VM with `--erl "+S 2:2 +SDcpu 2:2"` to match the host. A macOS
  development host is faster per core than the VPS; compare revisions on the
  same host only.
- No assertion gates the run; budgets are judged from its report.

Reference: captures 8 and 9 ([VMC-080](VMC-080.md)).

Checks: profile-work tests (histograms, percentiles) pass; repeated baseline
runs differ by under 1% in tick mean, while sampled phase means vary by about 15%.
Results: [081b](VMC-081b.md).
