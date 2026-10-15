# Current work

Target: full vanilla Java 26.3 compatibility (protocol 777), Elixir 1.20.4 / OTP 29.1.1.
This queue is editable. [Compatibility](compatibility.md) describes the preview;
[backlog](backlog.md) covers remaining features; [completed](history/completed.md)
indexes validated tickets. None imply full parity.

## Priority

1. **[VMC-011a](tickets/VMC-011a.md): authoritative ownership/tick ordering.**
   Resolve coupled state ownership before enforcing movement or publishing selected
   poses. Owner/tick timer fencing is validated; next is client-tick admission,
   then coupled domain ownership. Paper-compatible runtime choices are accepted.

VMC-061's concise docs/retrieval workflow is complete, ahead of further features.

## Pending client queue

One dedicated tester owns CUA. Code checkpoints can progress independently.

| Ticket | Remaining gate | Checkpoint / release |
|---|---|---|
| [VMC-005b2a](tickets/VMC-005b2a.md) | Sustained multi-slot client drag | Published with gate pending |
| [VMC-005b2c](tickets/VMC-005b2c.md) | Client-generated clone/fill | Published with gate pending |

The fitting block passes 458 tests, production build, full native integration and
its client gates. Live pose authority is still unimplemented.

## Retrieve and update

```sh
rg -n 'VMC-014c3b2b1' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-014c3b2b1.md
```

Read the ticket's referenced code/probes next. After a checkpoint, update its
checks/next gate and this queue. On Done, remove the pending row and add a link to
`history/completed.md`; keep detailed evidence in the ticket. Change priorities
when it helps compatibility. See [development](development.md) for Git/test rules.
