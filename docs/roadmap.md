# Current work

Target: full vanilla Java 26.3 player experience (protocol 777), Elixir 1.20.4 / OTP 29.1.1.
Server internals may freely use BEAM strengths; upstream servers inform design,
without imposing their implementation or compatibility contracts.
This queue is editable. [Compatibility](compatibility.md) describes the preview;
[backlog](backlog.md) covers remaining features; [completed](history/completed.md)
indexes validated tickets. None imply full parity.

## Priority

1. **[VMC-011a](tickets/VMC-011a.md): authoritative ownership/tick ordering.**
   Resolve coupled state ownership before enforcing movement or publishing selected
   poses. Owner/timer, client-tick admission and block batches are validated.
   [Resource/owner separation](tickets/VMC-011a4.md) passes targeted checks;
   client validation remains before coupled domains and transfers.
   [Cold-load isolation](tickets/VMC-011a5.md) also passes targeted checks.

VMC-061's concise docs/retrieval workflow is complete, ahead of further features.

## Pending client queue

One dedicated tester owns CUA. Code checkpoints can progress independently.

| Ticket | Remaining gate | Checkpoint / release |
|---|---|---|
| [VMC-011a4](tickets/VMC-011a4.md) | Edits/batches/durable scene items/reconnect | Local dev checkpoint |
| [VMC-011a5](tickets/VMC-011a5.md) | Active client during unrelated cold I/O; reconnect | Local dev checkpoint |
| [VMC-005b2a](tickets/VMC-005b2a.md) | Sustained multi-slot client drag | Published with gate pending |
| [VMC-005b2c](tickets/VMC-005b2c.md) | Client-generated clone/fill | Published with gate pending |

The latest coherent block passes 472 tests, production build and full native
integration, including plaintext/encrypted TCP. Live pose authority remains unimplemented.

## Retrieve and update

```sh
rg -n 'VMC-014c3b2b1' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-014c3b2b1.md
```

Read the ticket's referenced code/probes next. After a checkpoint, update its
checks/next gate and this queue. On Done, remove the pending row and add a link to
`history/completed.md`; keep detailed evidence in the ticket. Change priorities
when it helps compatibility. See [development](development.md) for Git/test rules.
