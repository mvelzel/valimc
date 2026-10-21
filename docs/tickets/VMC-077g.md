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

Checks: in progress.
