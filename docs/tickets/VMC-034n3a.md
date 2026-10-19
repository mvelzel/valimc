# VMC-034n3a — Durable remote XP spawn protocol

Status: **Done within unused protocol/storage scope** at `4b09f6f`, with maximum
ledger regression at `eb0e4aa`. Part of [orb ownership](VMC-034n3.md).
Live owner-to-owner delivery and remote publication follow this slice.

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
not proof of a write. The [delivery runtime](VMC-034n3b.md) now invokes this path;
its own graphical gate is separate from this accepted storage scope.
Source obligations/intents are retry/provenance records, not another active orb;
conservation tracks the unique award across routing and destination adoption.

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
Ten focused checks (seed533281) also prove the exact 427,020-byte ledger with
256 full-recipe imports plus 256 source intents. No broad gate is due for this subticket.

Measurement at `4b09f6f`: M4/24 GiB, 10 schedulers, 5 warmups/30 samples. Source
always retains 256 pending awards ×107 recipes; routes/imports vary 1/64/256.
At 256, source/destination snapshots are 422,545/418,649 bytes; prepare p50/p95
103.674/140.176 ms, adoption39.220/57.502 ms, settlement101.344/142.085 ms.
These validations belong on bounded CPU/I/O workers. Pure codecs/proposals only,
no gameplay/disk/socket load; host/tester activity overlaps and no capacity/speed
comparison is established. Raw samples, script and source hashes:
`.local/orb-transfer-bench-4b09f6f.{exs,json,log}`.

Actual-client gate **PASS** (2026-10-19), Java26.3/protocol777 at `4b09f6f`: local
orb grid/stats, survival furnace mining/pickup, actual smelting and normal/Shift
output refusals, both owner deaths and full server restart/fresh reconnect. Same
whole dataset preserves exact 14 pending awards/13 local markers/12 views/4,931 XP
and the pending source route/matching durable destination adoption (XP3, lost-ACK
boundary). Destination remains unpublished. Final source/typed24, item receipt16,
gold13/smooth stone1/furnace1/pickaxe wear1; no dirt/raw iron/coal/cursor/outbox/drops.
A absent; Boutput1/use1. All owned sessions stopped and port25565 clear.
Evidence/report: `.local/client-tests/VMC-034n3a/report.md`. Muted audio and native
6,000-tick client aging remain limits; no remote graphics/delivery or pickup claim.
The [delivery runtime](VMC-034n3b.md) follows; it must not reinterpret this unused
foundation as a completed live handoff.
