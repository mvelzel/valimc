# VMC-034n4b — Durable mutable XP bodies and terminal expiry

Status: Done
Note: Done within stored-body/terminal-decision scope at `1aba4ee` / `966b430`. Storage slice of [orb simulation](VMC-034n4.md), using [verified arithmetic](VMC-034n4a.md) and [accepted pickup](VMC-034n5.md).

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
  existing 2,816 birth-record bound and shared8MiB snapshot budget. Preserve exact
  version 1–7 bytes when the extension is unused. Reject unknown/duplicate/orphan
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

Implemented: version 8 container snapshots add per-award initialization markers
with complete UUID row sets, decided launch pose/velocity, age/revision/support
and terminal expired-unit counts. Versions 1–7 retain exact bytes when unused.
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
matches 56 launches/5,184 ticks/5 age boundaries from VMC-034n4a. Logs stay under
`.local/orb-bodies-*.log`. Coverage includes all legacy formats, local/imported/
partly consumed/zero awards, missing/orphan/duplicate rows, nonfinite state,
stale proposals/publication, owner loss and every interrupted joint-write subset.

The exact 2,816-row/256-marker body ledger is 236,554 bytes. Initialization refuses
before a decision if shared storage is full; fixed-size expiry still commits at
exactly8MiB. Current-region bounds refuse cross-owner poses until moving handoff
exists. Native expiry arithmetic reuses the completed kernel; no per-tick disk
writes or per-orb processes are introduced.

Boundary follow-up: reject more than 11 launch draws/rows per award or 256 candidate
markers before traversing a proposal. Exhausted 64-bit generations refuse without
changing storage. Eight targeted checks pass(seed 252373,
`.local/orb-bodies-width.log`). Successor966b430 contains these early guards.

Measurement at `1aba4ee`: `.local/orb-bodies-bench-1aba4ee.{exs,json,log}` retains
source/script hashes, hardware,5 warmups/30 samples and matched one-recipe
4,925-XP awards at 1/64/256 markers. AppleM 4/10 schedulers, shared host during GUI.
At 256 markers/2,816 records, snapshots are 172,161 bytes legacy and 408,749 bytes
initialized. Active encode p50/p95 is 4.94/7.26ms, cold publication 10.35/14.47ms,
and 1,000 unchanged idle plans 71/94µs. Fully expired publication is 0.308/0.517ms
with no views. One-row checkpoint+install costs 20.22/26.67ms active and
16.62/28.80ms with 6/11 records expired. These full-storage checks belong off the
simulation hot path; future frame updates need in-memory batches and a separate
checkpoint cadence. Pure components exclude disk, geometry, network and live
workload; no TPS/capacity/comparative claim.

Actual-client acceptance (2026-10-19, Java26.3/protocol777): dedicated tester
reports PASS on frozen `1aba4ee` runs 01–02 and `966b430` run 03, same complete dataset
`.local/client-tests/VMC-034n4b/world`. Old-birth contact grants nothing; actual
walking into the stored-pose contact boundary collects both 3-XP units, raising
XP12→18. Walking through a terminal fixture grants nothing. Exact region-owner
replacement restores neither collected nor expired units. Real raw-gold/coal
smelting and ordinary output take/stow yield gold 12 and XP19; empty ordinary/
Shift output clicks refuse. Same-release and successor full restarts retain
gold 12/steak3/XP19, three recipes and empty cursor/outbox. Final cold files reconcile
nine awards:25 decided =19 consumed +6 expired +0 remaining; source/typed51,
container sequence 46, body revision 10/eight markers. All six original awards,
births and consumption counters remain unchanged. Helpers/JVMs/servers stopped,
zero players, region/clock flushed and port 25565 clear. Report, observations and
reconciliation remain in `.local/client-tests/VMC-034n4b/`.

Fixture limit: the active stored pose overlaps a smoker, hiding its sprite.
Actual old-birth refusal versus stored-boundary collection and visible XP change
verify contact authority; separate active-sprite visibility is not claimed. Both
stored pose and expiry were precommitted fixtures, not automatic simulation.
These storage/read-authority gates are closed. Live movement/ageing/expiry,
moving handoff and Mending remain separate; this subticket does not trigger broad
integration/build checks.

Next implementation: [supplied travel geometry/current](VMC-034n4c.md), then
pose-generation admission and live scheduling. Full storage validation is a
checkpoint operation, not a per-frame motion API.
