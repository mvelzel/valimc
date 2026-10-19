# VMC-034n4b — Durable mutable XP bodies and terminal expiry

Status: Planned. Next storage slice of [orb simulation](VMC-034n4.md), using
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
  and receipt proofs; this storage foundation does not change pickup admission yet.
- Dedicated actual-client baseline on a frozen checkpoint retains smelt/output/XP,
  empty-output negatives and restart conservation. No live expiry or travel claim
  until its runtime integration receives separate native and graphical checks.

Follow with supplied geometry/current travel, target/escape decisions and live
body scheduling/admission/replication. Reuse ordinary-item ownership ideas where
appropriate, keeping XP provenance and terminal accounting explicit.
