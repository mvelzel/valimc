# VMC-034n3a — Durable remote XP spawn protocol

Status: In progress. Part of [orb ownership](VMC-034n3.md). Unused foundation;
live owner-to-owner delivery and remote publication follow this slice.

An award can belong to a processor's region while its spawn position belongs to
another region. Preserve the immutable source obligation. Persist a source routing
intent before delivery; the destination atomically stores adoption and its replay
receipt. A matching acknowledgement settles routing, never the recipe obligation.
No source orb is exposed for a remote spawn. Award identity fences replay; no
global coordinator or process per award/orb.

Acceptance:

- Pure prepare/request/adopt/ack transitions, exact conflict detection and replay
  after either side restarts. Lost acknowledgements must not recreate records.
- Canonical bounded transfer bytes within the existing leased container snapshot;
  versions 1–5 keep exact bytes when transfer state is empty. Retain all pending
  awards, slots, receipts and existing local orbs. Zero XP retains an empty receipt.
- Bound imports plus local markers to 256 awards/2,816 records, routing intents
  to the source's 256 pending awards and the whole snapshot to 8 MiB. Refusal
  leaves source intent recoverable; never evict a receipt to make capacity.
- Leased storage and existing joint-journal recovery preserve both endpoint
  decisions, including writer death before acknowledgement and interrupted writes.
- Actual client: fresh whole fixture with durable outgoing/imported decisions;
  ordinary local orbs, survival mining/pickup, cooking/output refusal and a full
  restart work while exact transfer bytes and source/receipt counters survive.
  Remote records remain unpublished until delivery/runtime is implemented.

Correctness: pinned Mojang 26.3 award splitting/codecs and stable UUIDs from the
parent ticket. Ownership inspiration: existing bounded `ItemHandoffs` intent and
adoption receipts; XP uses its own domain and immutable award identity. No native
packet/gameplay behavior changes in this storage slice. Future motion/consumption
needs mutable XP authority and ownership generations; this is initial spawning only.

Implementation: `CookingOrbTransfers` reserves one pending route per remote award,
reconstructs its canonical request after recovery, adopts the original decision
and receipt together, and marks only an exact request digest delivered. It retains
delivered routes and all immutable source obligations. Destination receipts also
reject another digest for the same source region/player/sequence. Derived native
orb UUIDs/denominations remain unchanged. Callers must commit proposals before
sending requests, publishing adoption or acknowledging success; the pure API is
not proof of a write. No live packet handler or runtime invokes this path yet.

Container version 6 embeds the bounded transfer ledger with explicit lengths for
the pending/local ledgers. Request limit: 1,633 bytes; ledger limit: 427,020 bytes.
An explicit revision advances on prepare/adopt/settle, with idempotent replay
unchanged. Existing v1–v5 data retains exact bytes with empty transfer state.

Automated verification (2026-10-19): 68 affected checks pass (seed314265), then
nine focused checks (seed823678) add the frozen `ed06d5a` v5 checksum and full
107-recipe record boundary. Coverage includes zero XP, endpoints/boundaries,
conflicting identity/content, canonical bytes, combined record limits, exact 8 MiB
acceptance/one-byte refusal, lost ACKs, stale leases, I/O failure and all eight
joint replacement subsets at each endpoint. Existing native splitting/packet
proofs apply unchanged. Private logs: `.local/orb-transfer-*.log`.

Client gate pending. Fresh dataset: `.local/client-tests/VMC-034n3a/world`, with
14 receipt-backed source awards, a pending route and matching durable destination
adoption (lost-ACK boundary). Remote publication is deliberately inactive.
