# VMC-034n4b — Durable mutable XP bodies and terminal expiry

Status: In progress. Storage slice of [orb simulation](VMC-034n4.md), using
[verified arithmetic](VMC-034n4a.md) and [accepted pickup](VMC-034n5.md).

Separate mutable position/velocity/age from immutable birth/adoption proofs.
Persist terminal expiry before removal so cold publication cannot resurrect it.
This slice must not silently enable live motion before geometry, pickup admission,
replication and moving-owner transfer are ready together.

Acceptance:

- Define bounded body initialization/migration markers. A missing mutable row
  after initialization must not recreate a body from its birth. Resolve launch
  randomness once in a durable decision; replay uses that decision without RNG.
- Preserve UUID/value and birth provenance. For each birth, account exactly for
  remaining, consumed and terminally expired units. Expiry cannot increment player
  XP or consumption counters. Merges/moving handoff need their own proved lineage
  transitions; never overload an initial spawn/adoption replay as a moving handoff.
- Store bounded pose/velocity/age/revision and terminal decisions, at most the
  existing2,816 birth-record bound and shared8MiB snapshot budget. Preserve exact
  version1–7 bytes when the extension is unused. Reject unknown/duplicate/orphan
  bodies, inconsistent counts, nonfinite/unbounded state and partial initialization.
- Use original owner/joint writer lanes, snapshot/revision/epoch fences and bounded
  worker proposals. Pure proposals cannot mutate observations or player state.
  Ordinary kinematics may use defined periodic checkpoints; collected/expired
  terminal units must remain retired across crashes. Do not synchronously write
  the whole container snapshot for every orb on every simulation step.
- Prove partial initialization, capacity refusal, stale proposals, interrupted
  writes, legacy migration, owner replacement and full cold recovery with mixed
  container/birth/adoption/consumption records. Preserve existing player journals
  and receipt proofs. Publication and pickup use initialized stored poses/counts;
  terminal expiry must reject stale pickups. Automatic ticking remains disabled.
- Dedicated actual-client baseline on a frozen checkpoint retains smelt/output/XP,
  empty-output negatives and restart conservation. Add a stored-pose/terminal
  fixture to verify contact at its current pose and no expired-unit resurrection.
  No automatic expiry or travel claim until runtime ticking receives its own checks.

Follow with supplied geometry/current travel, target/escape decisions and live
body scheduling/admission/replication. Reuse ordinary-item ownership ideas where
appropriate, keeping XP provenance and terminal accounting explicit.

Implemented: version8 container snapshots add per-award initialization markers
with complete UUID row sets, decided launch pose/velocity, age/revision/support
and terminal expired-unit counts. Versions1–7 retain exact bytes when unused.
`CookingOrbBodies` proposes bounded initialization/checkpoints; `install` fences
body/consumption revisions and rebases only that field, preserving other container
work. Markers cannot disappear, age cannot rewind and terminal rows cannot revive.
All serialization and transition planning is pure work for bounded workers.

Publication reads current stored poses and remaining counts, retaining entity IDs
when positions change. Pickup reads the same authority, rejects expired units,
and retains the accepted player journal/receipt path. Body revisions fence late
publication workers. Initialization/checkpoint APIs are not automatically scheduled;
there is no live motion/age loop yet. Future movement must also invalidate or bind
pickup permits to the moving pose generation before enabling concurrent ticks.

Checks (2026-10-19):39 existing owner/pickup/creation/transfer checks pass
(seed519368);11 storage/boundary checks pass(seed776281);47 runtime/socket/menu/
container checks pass(seed169160). Seven pure storage checks repeat after the
empty-extension fast path(seed566651). Native launch/motion regression still
matches56 launches/5,184 ticks/5 age boundaries from VMC-034n4a. Logs stay under
`.local/orb-bodies-*.log`. Coverage includes all legacy formats, local/imported/
partly consumed/zero awards, missing/orphan/duplicate rows, nonfinite state,
stale proposals/publication, owner loss and every interrupted joint-write subset.

The exact2,816-row/256-marker body ledger is236,554 bytes. Initialization refuses
before a decision if shared storage is full; fixed-size expiry still commits at
exactly8MiB. Current-region bounds refuse cross-owner poses until moving handoff
exists. Native expiry arithmetic reuses the completed kernel; no per-tick disk
writes or per-orb processes are introduced.

Next gate: dedicated stored-pose/expiry fixture and actual smelt/XP/restart
acceptance on a frozen checkpoint; benchmark storage/projection while it runs.
