# VMC-ID — Concrete behavior

Status: Planned
Milestone: M1 foundations (or the milestone this ticket serves)
Depends on: relevant tickets only.

`Status:` is exactly one of Planned, In progress, Foundation, Awaiting client,
Done or Parked. Done means live in play; an unused building block is Foundation.
An optional `Note:` line may qualify the scope in one sentence.

Behavior before/after and explicit scope limits.

Acceptance:

- Vanilla behavior and meaningful positive/failure boundaries.
- Ownership, work bounds, ordering/fencing/recovery when relevant.
- Performance expectation when the slice is on a hot path (benchmark name).
- Player-visible scenario for the milestone client handoff, if any.

Reference: pinned revisions/classes/methods and design conclusions.

Checks: targeted commands and results. Broad gates run at milestone boundaries.
Client: milestone handoff reference, date, PASS/FAIL and limits (raw evidence stays
in `.local/`). Next: concrete remaining work.
