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
2. **[VMC-011a8](tickets/VMC-011a8.md): larger-load geometry admission.**
   Prepared plans/samples and a player-budget worker bound pass the original
   512-player workload. Repeat longer/frozen loads and delegate the client gate.
3. **VMC-015: gravity, velocity and grounded state.** Establish native player
   simulation behavior before adding forces, fall distance and damage.

VMC-061's concise docs/retrieval workflow is complete, ahead of further features.

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
production build. The 128-player checks pass; 512-player admission needs work.
Retain [VMC-018c2](tickets/VMC-018c2.md)'s unreproduced item visibility finding for the next item work.

## Retrieve and update

```sh
rg -n 'VMC-014c3b2b1' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-014c3b2b1.md
```

Read the ticket's referenced code/probes next. After a checkpoint, update its
checks/next gate and this queue. On Done, remove the pending row and add a link to
`history/completed.md`; keep detailed evidence in the ticket. Change priorities
when it helps compatibility. See [development](development.md) for Git/test rules.
