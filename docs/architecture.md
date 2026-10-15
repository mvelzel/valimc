# Ownership and consistency

Processes define state ownership and failure boundaries. Parallel schedulers do
not make coupled gameplay independent; ETS publications never grant authority.

| State/work | Current owner/access |
|---|---|
| Socket, protocol, AES streams, preview inventory/input/pose | One connection process |
| Admission/names/lifecycle | Players service; outside movement hot paths |
| Nearby-player observations | Published ETS plus spatial index; paced replication |
| Blocks, chunk revisions/cache, stationary items/receipts | Region owner |
| Item observations | Region-owned protected ETS; cached immutable packet binaries |
| World clocks/weather/difficulty | Environment owner; immutable publications |
| Encoding, collision queries, auth/crypto, transfer recovery | Separate bounded worker pools |
| Region files and player snapshots | Linked/leased writers; disk outside sensitive owners |

TCP `active: :once`, packet/rate/write limits and mailbox limits bound ingress.
Observers sample/coalesce changes rather than enqueueing every movement to peers.
Chunk requests share immutable results; region revisions discard stale encodings.
The supervisor's `rest_for_one` order restarts dependent infrastructure; session
and region failures have narrower scopes. Runtime caps live in `config/config.exs`.

## Durability and failure

Block/player state uses custom snapshots, not Anvil/player NBT. Periodic saves can
lose recent uncheckpointed state on hard crash. Source item transfers instead
journal a reduced inventory plus one outbox before delivery. The region commits
records and retry receipts before publication/acknowledgment; pinned retries do
not duplicate removed items. Source clearing requires destination receipt proof.
UUID writer leases, owner incarnations and revisions fence stale operations.

Never fabricate recovery evidence or roll back one side of a committed transfer.
Ambiguous outcomes retain the intent for recovery. Receipt/counter limits are
explicit admission failures, not eviction opportunities. Detailed contracts/tests:
[tickets VMC-019b1](tickets/VMC-019b1.md), [019b2](tickets/VMC-019b2.md),
[019b3a](tickets/VMC-019b3a.md) and [disconnect cleanup](tickets/VMC-005b2d2b.md).

Online login runs verified HTTPS in bounded cold workers before admission; each
connection owns continuous cipher advancement. Discovery/backoff and outage
rejection are covered by [authentication tickets](tickets/VMC-007c3.md).

## Authoritative simulation remains

Current fixed regions support independent preview edits; player simulation still
belongs to connections. Region ticks have deadlines but no survival simulation.
Native movement/pose/block/entity/border primitives now exist. Supplied/live block
observations retain revisions but do not establish simultaneous snapshots or
commit-time authority. Missing/unloaded context is an error, never air.

[VMC-011a](tickets/VMC-011a.md) defines the next ownership/tick/boundary decisions
before live movement enforcement, selected-pose publication, gravity or coupled
mechanics. Keep stable transport processes, owner-local dense state, immutable
observations, bounded pure jobs and supervised I/O. There is no global gameplay
owner or survival TPS/fastest-server claim. See [research](research.md).
