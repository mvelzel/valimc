# Current work

Target: full vanilla Java 26.3 player experience (protocol 777), Elixir 1.20.4 / OTP 29.1.1.
Compatibility policy update: **Done**, `4c449d9` (October 15). [AGENTS.md](../AGENTS.md)
preserves vanilla gameplay/client interoperability and permits BEAM-native internals.
This queue is editable. [Compatibility](compatibility.md) describes the preview;
[backlog](backlog.md) covers remaining features; [completed](history/completed.md)
indexes validated tickets. None imply full parity.

## Priority

1. **[VMC-011a](tickets/VMC-011a.md): authoritative ownership/tick ordering.**
   Player processes own their simulation state; bounded workers sample geometry.
   Coupled effects need explicit ordering. Owner/timer, client-tick admission and
   block batches are validated, as are [resource separation](tickets/VMC-011a4.md),
   [cold-load isolation](tickets/VMC-011a5.md), [writer leases](tickets/VMC-011a6.md),
   [cold admission/ETS routing](tickets/VMC-011a7.md) and
   [live player poses](tickets/VMC-014c3b2b2.md).
   [Live block-based movement](tickets/VMC-014c4.md) is validated and complete
   within its scope (`d10f566`); gravity/coupled effects remain.
2. **VMC-015: gravity, velocity and grounded state.**
   [Accepted-move fall accounting](tickets/VMC-015a.md) is validated (`84f5fb0`),
   including real jump/drop/powder-snow, flight and reconnect.
   [Gravity/drag](tickets/VMC-015b.md)'s pure air/collision kernels and complete
   block motion facts match native cases/traces (`1da26e93`, baseline client smoke
   passed). [Live default velocity](tickets/VMC-015b1.md) now composes them on the
   bounded player tick/geometry lane; validated and complete within its scope
   (`6691f43`), including frozen loads and actual-client regression after
   eliminating duplicate pose observations.
   [Saved velocity](tickets/VMC-015b2.md) is validated and complete within its
   scope (`18aad55`): direct airborne/ground reconnect, landing, jump and flight.
   [Fluid travel](tickets/VMC-015d.md) is in progress: complete material facts/body
   depths validated (`01c4627`); local native water/lava kernels (`0ae6ef3`).
   Current, contextual support and vertical input match native cases. [Default
   live composition](tickets/VMC-015d1.md) is validated (`2e66935`): actual water/
   lava/current/input/flight/reconnect, 578 tests, full native integration,
   production release and frozen preview loads. [Swimming state/geometry](tickets/VMC-015d2.md)
   and [pitch steering](tickets/VMC-015d3.md) are validated (`3c99728`): actual
   tunnel/crawl/peer/pitch/flight/reconnect, 587 tests, full native integration,
   production release and active-water 512/128-player loads.
   [Climbing](tickets/VMC-015e.md) is validated (`f83e8e7`): actual ladder/vine/
   scaffolding/trapdoor/wet/flight/reconnect, 600 tests, full native integration,
   production build and controlled 512/128-player water loads.
   [Relative input](tickets/VMC-015f.md) now has native direction/acceleration/rate
   kernels; native reported intent preserves simulated controls. Entity/vehicle
   ownership remains open. [Slowing contacts](tickets/VMC-015g.md) are validated
   and published (`bc4eb1e`):
   actual client, 622 tests, full native integration/build and controlled 512/128
   water loads. Weaving status ownership and damage remain follow-ups.
   [Sneaking at edges](tickets/VMC-015h.md) is validated and published (`6ca22ef`):
   native query/frame traces, affected tests and actual ledges/corners/slabs/exclusions.
   Effects/survival consequences remain open.
   [Owned health/fall damage](tickets/VMC-017a.md) has native calculation, health/
   cooldown, codec and journal foundations. Owner/login/timer composition is
   validated (`18028cd`): 75 affected tests and actual hearts/inventory/reconnect.
   Death/respawn codecs pass native checks locally; owned lifecycle and fenced
   landing damage are next. No live damage yet.
   [Environment ticks](tickets/VMC-015c.md) share the
   geometry lane and fix the stale powder freezing state; validated and complete
   within freezing scope (`91caf387`), including actual thaw/reconnect and flight.
   [Geometry admission](tickets/VMC-011a8.md) is complete within measured preview
   scope (`8871985`); prepared samples retain owner fencing and bounded work.

VMC-061's concise docs/retrieval workflow is complete, ahead of further features.
[VMC-003c](tickets/VMC-003c.md)'s direct local test-client lifecycle is complete:
automatic join, small window, readable Auto UI, muted launch and owned shutdown.

## Pending client queue

One dedicated tester owns CUA. Code checkpoints can progress independently.

| Ticket | Remaining gate | Checkpoint / release |
|---|---|---|
| [VMC-005b2a](tickets/VMC-005b2a.md) | Sustained multi-slot client drag | Published with gate pending |
| [VMC-005b2c](tickets/VMC-005b2c.md) | Client-generated clone/fill | Published with gate pending |

The admission/routing block (`66a4b81`) passes 481 tests, production build and full
native integration, including plaintext/encrypted TCP. Live pose selection
(`b65e6ec`) passes 113 affected tests, native codecs/TCP and actual-client checks;
live movement (`d10f566`) passes its client gate, 109 affected tests and both native
TCP transports. The larger block passes 505 tests, full native integration and a
production build. The admission block passes 508 tests, native integration and a
production build; frozen 512-player and 128-player layouts pass, with client
movement/flight/reconnect retested. See VMC-011a8 for workload and host-load limits.
Retain [VMC-018c2](tickets/VMC-018c2.md)'s unreproduced item visibility finding for the next item work.
The fall/environment block passes 527 tests, full native integration and a separate
production build; VMC-015c records client evidence and frozen preview loads.

## Retrieve and update

```sh
rg -n 'VMC-014c3b2b1' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-014c3b2b1.md
```

Read the ticket's referenced code/probes next. After a checkpoint, update its
checks/next gate and this queue. On Done, remove the pending row and add a link to
`history/completed.md`; keep detailed evidence in the ticket. Change priorities
when it helps compatibility. See [development](development.md) for Git/test rules.
