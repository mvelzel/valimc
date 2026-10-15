# VMC-011a — Authoritative simulation ownership and tick order

Status: Planned — next architecture prerequisite. October 15, 2026.

The pose/movement math is usable, but region read revisions and ETS publications
cannot authorize coupled gameplay. Resolve this before publishing live selected
poses or adding gravity. Reprioritize implementation as the evidence warrants.

Reference: pinned Folia README and its official [region logic](https://docs.papermc.io/folia/reference/region-logic/)
reviewed October 15: it groups nearby chunks and prevents ownership expansion
while a region ticks. Dragonfly's pinned `server/world/tx.go` scopes mutations to
an owner callback. These suggest ownership constraints, not a Java/Go port.

Acceptance/design decisions to implement:

- Connection processes retain transport/input; a simulation owner holds each
  entity's authoritative pose, velocity, collision state and logical tick.
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

Working direction: separate cold ownership/topology admission from hot simulation
domains. Nearby coupled sections must share an ordered mutation boundary; distant
domains can tick independently on BEAM schedulers. Keep transport processes stable
and reuse immutable geometry/jobs. Do not infer independence from fixed storage
region coordinates. A revision recheck or expiring read lease alone cannot make
multi-owner gameplay atomic.

Before implementation, settle quiescent merge/split/transfer, epochs and owner-loss
behavior, then verify native tick/input ordering. The first slice should exercise
domain partition and tick admission deterministically; it must not declare live
movement authority until integrated owners and actual reconciliation pass.
