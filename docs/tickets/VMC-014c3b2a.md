# VMC-014c3b2a — Player entity-collision observations

Status: Done — client validated. October 15, 2026.
Depends on VMC-014c3b1.

Add the bounded pure entity-collider collector needed by player pose fitting.
The current block collector cannot establish that a player fits when a solid
entity occupies the same space. Live entity snapshots/fencing and pose publication
remain VMC-014c3b2b; supplied observations confer no gameplay authority.

Acceptance:

- Match pinned `EntityGetter.getEntityCollisions` and the default player
  `Entity.canCollideWith` policy: native average-size threshold, inflated lookup
  box, self/spectator exclusion, subject-dependent collidability and shared vehicle
  exclusion. Preserve candidate order and native empty voxel shapes.
- Require complete supplied facts, bound candidates/coordinates and reject
  duplicate identities or invalid observations; never infer missing entities.
  Add no world I/O, processes or publication path.
- Differentially invoke the actual native methods across threshold/overlap,
  null-subject, predicate and ordering cases. Run format, tests, release and audit.
- Dedicated client scenario: render a stationary preview item and a loopback
  player, walk through each and compare the non-solid observations; check commands,
  reconnect and fresh logs. Native controlled solid-entity fixtures remain
  differential evidence, not a claim of implemented boats or live authority.

Reference: pinned Mojang 26.3 jar and private
`research/disassembly/VMC014c3b2-{EntityGetter,Entity,EntitySelector}.txt`.
Collidability must be supplied for the particular subject by a future entity owner;
it is not a universal entity-type flag or a client claim.

Implementation: one pure bounded scan of at most 256 supplied candidates;
subject-specific facts are mandatory. Duplicate identities and malformed/oversize
observations fail explicitly. Preserve empty shapes because native collision-list
presence is distinct from voxel-shape emptiness. No entity observation is fetched
from eventually consistent player publications.

Checks: format, 449 tests and isolated production release
`.local/entity-fit-build/rel/valimc` pass. Native `EntityGetter`/`Entity` methods
match all 6,048 threshold, predicate, overlap-margin, ordering and shape fixtures;
the probe confirms `Player` inherits the default collision predicate.
Private cases/logs: `.local/vmc014c3b2a-*`.

Dedicated tester: actual item and loopback player rendered; W/S crossed both at
feet y64. Ten sampled AABB overlaps produced no colliders; solid positive controls
selected the same boxes. Commands, committed item removal/peer cleanup, actual
reconnect and fresh logs passed, preserving source counter/outbox/receipts.
Evidence: `.local/client-tests/VMC-014c3b2a/`, including release hashes and traces.
The first sampler missed its gesture and is excluded. These are non-solid entity
contacts/pure predictions, not live pose enforcement or implemented solid mobs.
