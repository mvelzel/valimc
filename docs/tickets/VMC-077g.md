# VMC-077g — Owner skeleton: one job table, one error taxonomy, owner lookup

Status: In progress
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the plan), [VMC-077f](VMC-077f.md) (storage).

Before: the region owner launched eight kinds of background work through eight
bespoke paths (its planning slot through four launchers, cooking,
cross-owner merges, portal destinations, orb plans and deliveries,
item handoff deliveries, chunk encodes), each with its own worker, monitor,
token, timer and deadline fields, result, deadline and `:DOWN` handlers;
several workers caught every exception; retryable failures were a hand-kept
list of atoms in `Txn.Delivery`; owner processes were found and started by
three different sleep-and-retry loops.

Scope: the region owner's process skeleton. Not here: the entity store
(VMC-077h) and transfers (VMC-077i), which replace the item code itself.

Limits: only transient errors are classified so far, the one class callers
act on generically; the region owner's other refusals (rules, races, bad
input) keep their atoms until their modules are rewritten (the entity store,
transfers, commands). The planning slot and block-transfer guards are one
function each (`write_busy/1`, `block_transfer_writing?/1`) rather than a
general admission guard.

Acceptance:

- One job table (`Valimc.World.Jobs`): at most one job per kind, each a worker
  under a bounded task supervisor with a token, monitor and optional deadline;
  one report (`{:job, kind, token, result}`), one deadline
  (`{:job_deadline, kind, token}`) and one `:DOWN` path, routed by a guard on
  the table's monitors. Every worker kind of the region owner runs on it: the
  planning slot (`:plan`), `:cooking`, `:cross_merge`,
  `:portal` (its polled 60 s expiry is now its deadline), `:orb_plan`,
  `:orb_delivery`, `:handoff` and `{:encode, chunk}`. A crashed worker is a
  failed job: the portal, orb-plan and orb-delivery workers no longer rescue
  every exception. A planning job that overruns its deadline fails its caller
  with a retryable error instead of stopping the owner. Stopping the owner
  stops every job (before, portal workers outlived it).
- One owner lookup (`Valimc.Owners.ensure/4`): find the registered process
  or start one, waiting out a registration whose process just exited or a
  predecessor still stopping, 1 ms at a time and boundedly. Region owners
  (through the Directory), proto owners and log stripes use it; their three
  sleep-and-retry loops are gone. `PlayerStore.open/1` keeps its own path: it
  adopts a closing store rather than finding one and never retries.
- One error taxonomy (`Valimc.Error`): `{:error, {:retry | :reject |
  :conflict | :invalid, detail}}`, the class decided where the error is made.
  Every transient error is classified `:retry` where it is made: the planning
  slot and mining slot being busy, worker pools full, an owner restarting,
  unloaded or replaced (one `:stale_owner` instead of `:stale_region` and
  `:stale_owner`), a chunk still generating, a Directory backoff or region cap,
  owner calls that time out or find the owner gone, uncertain commits, a
  destination's item capacity, and a player transfer not yet applied or its
  destination unavailable. A poisoned region is `:reject`. `Txn.Delivery`'s
  hand-kept list of retryable atoms is gone (`Error.retryable?/1`), as are the
  atoms it named that nothing produced (`:storage_backpressure`,
  `:container_commit_uncertain`, `:mining_commit_uncertain`); the portal
  reader retries `{:retry, _}` and lost races instead of its own list.

Checks: in progress.
