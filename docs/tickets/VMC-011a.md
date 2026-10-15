# VMC-011a — Authoritative simulation ownership and tick order

Status: In progress — player poses validated; live movement reconciliation next. October 15, 2026.

The pose/movement math is usable, but region read revisions and ETS publications
do not themselves authorize coupled gameplay. Player owners must decide/commit
their state. Reprioritize implementation as the evidence warrants.
Preserve the vanilla player experience; region/chunk/tick internals may freely
use BEAM concurrency and measured performance. Paper and other servers inform
design without imposing compatibility contracts (user clarification, October 15).

Reference: pinned Folia README and its official [region logic](https://docs.papermc.io/folia/reference/region-logic/)
reviewed October 15: it groups nearby chunks and prevents ownership expansion
while a region ticks. Dragonfly's pinned `server/world/tx.go` scopes mutations to
an owner callback. These suggest ownership constraints, not a Java/Go port.

Acceptance/design decisions to implement:

- Each player process owns transport/input and its authoritative simulation state;
  bounded workers perform geometry work. Separate lifecycles when gameplay needs it,
  rather than duplicating player state merely to add another process.
- Define admission/input ordering, simulation, commit and immutable publication
  phases. Bound per-tick work and input queues; specify overload behavior.
- Choose and test independent domains, coupled neighbors and boundary transfer
  ordering. Never turn sequential revision checks into an atomicity claim or put
  all gameplay through a global process. Ownership changes require epochs.
- Specify owner/worker loss and recovery before enabling durable effects; delayed
  replies cannot apply a stale decision. Disk/encoding stay outside sensitive owners.
- Integrate the smallest actual movement/pose path using existing native fixtures;
  test independent domains under concurrency and deterministic owner-local traces.
  Delegate actual contact/reconciliation tests and retain explicit parity limits.

Current direction (October 15): stable player processes own selected poses;
block owners supply immutable geometry frames. Gather a bounded read set, compute,
then recheck every source epoch/revision. Changed player inputs/environment discard
late results. Commit in the player owner and replicate at its publication phase.
This is sampled tick geometry, not an atomic transaction spanning player/block
owners; world changes schedule another fit. Source loss/errors retain the last
selected pose, never an invented empty world. No global gameplay coordinator.

Region merges/splits are not prerequisites for independent pose selection. Future
coupled effects (piston pushes, collisions with solid entities, durable transfers)
need explicit ordered mutation protocols; domain handoffs remain an option, not
an upstream architecture requirement. Rechecking revisions or expiring read leases
cannot establish cross-owner mutation atomicity. Live movement enforcement,
gravity and coupled simulation remain unimplemented until their own checks pass.

Live block-based pose selection/metadata/eye height is validated in
[VMC-014c3b2b2](VMC-014c3b2b2.md), including actual low-ceiling retention,
reconnect and standing recovery. Movement collision enforcement is the next slice.
