# VMC-034n3b — Live remote XP spawn delivery

Status: Done within initial remote-spawn scope. Runtime `38cf281`, additional
fairness check/measurements `5cb237f`. Depends on the [durable protocol](VMC-034n3a.md); part of
[orb ownership](VMC-034n3.md). This covers initial remote spawning, not moving
an already active orb or enabling earned-output withdrawal.

Source owners must route pending awards to the owner of their spawn position.
Use the stored intent before delivery, the destination's durable adoption before
publication/ACK, and the source's matching digest before marking delivery settled.
Retain the immutable recipe obligation. Replays must never create another effect.

Implementation/acceptance:

- Keep CPU validation/publication planning on bounded workers and destination I/O
  on bounded transfer workers. One delivery in flight per source region; rotate
  retries with deadlines/backoff. Waiting on another owner never blocks a region.
- Use epoch/lease/token fences and the shared durable write lane. Rebase only the
  routing/adoption delta into current containers, preserving concurrent cooking,
  slots, receipts and local orbs. Publish/ACK only after the exact successful write.
- Include transfer revision in scheduling/publication fences. Cold owners retry
  pending routes and rebuild adopted native records with stable UUIDs/fresh IDs.
  Combine imports/local views under existing 256-award/2,816-record, frame, chunk
  observation and observer pacing limits. Remote source regions expose no copy.
- Duplicate adoption returns its original success without another effect. Full or
  unavailable destinations retain the source intent. Late/uncertain callbacks,
  worker saturation, owner/writer death and graceful shutdown conserve decisions.
  Receipt/creation records stay immutable; no eviction or pickup shortcut.
- Targeted owner/TCP regressions cover both endpoints, replay at each crash boundary,
  capacity refusal/retry, zero XP, simultaneous local cooking and stale observers.
- Actual client: cross the boundary and see the remote orb only at its destination;
  source/destination replacement and full restart preserve one scene and the exact
  ledgers. Repeat ordinary pickup/cooking/output-refusal negatives. Pickup/player
  XP and server motion/lifetime remain inactive and separately tracked.

References: pinned native splitting/codecs in the parent; `CookingOrbTransfers`
for immutable decisions and `ItemHandoffDelivery` for bounded delivery patterns.
Do not redo the accepted local runtime or durable protocol.

Runtime design: one CPU proposal and one outbound delivery per region. The inbox
accepts only a bounded canonical request binary and a deadline. Preparation,
adoption and settlement rebase their ledger delta at the current lease/epoch;
the source retains one received acknowledgement until its own settlement commits.
No write lane is held while waiting for another region. Source intents never
become source-side entity observations; destination adoption alone owns the effect.

Implementation: automatic remote route preparation, bounded transfer-worker RPC,
destination adoption/publication and source settlement are integrated. CPU plans
have 2 s deadlines; writes 5 s; inbox/RPC/delivery limits are 6/7/8 s. Busy worker
admission backs off 100 ms; uncertain deliveries rotate after 1 s. The transfer
revision wakes scheduling even when record counts are unchanged. Both imported
and local frozen views share native replication and its prediction corrections.

Automated checks (2026-10-19): 84 distinct affected tests pass across the
83-test regression (seed141334) and nine-test delivery run below, including
simultaneous opposite deliveries/zero XP, source death while destination writes,
writer death after adoption durability/before ACK, concurrent slots/receipts/timers
during adoption and settlement, shared-byte refusal/retry, stale/late work and
worker saturation. Native TCP covers both local and remote spawn/value/pose,
ordinary pickup separation, late join and stable UUIDs/fresh network IDs after
owner loss. Existing native denomination/packet probes remain unchanged. Logs:
`.local/orb-delivery-*.log`. No broad gate is due at this subticket boundary.

The additional full-destination regression passes with all nine delivery tests
(seed441054): a refused destination retains its durable source intent while a
second destination receives and settles its award. Its existing 256 imports remain
unchanged; the source exposes no copy and retains both immutable obligations.

Measurements at `38cf281`: M4/24 GiB, 10 schedulers, 5 warmups/30 samples,
1/64/256 imported one-recipe awards worth 4,925 XP each (11/704/2,816 records).
Cold import planning p50/p95 is 0.041/0.087, 3.713/5.385 and 12.631/18.142 ms;
source settlement planning is 0.024/0.090, 0.533/1.124 and 1.371/2.102 ms.
Both idle schedulers together, 1,000 calls with a copied ledger, take
0.071/0.146, 0.115/0.224 and 0.070/0.157 ms. The maximum imported snapshot is
38,745 bytes for this one-recipe workload; it is not the maximum legal ledger.
At 2,816 records, visible reads for nine/64 chunks are 77/197 and 354/721 µs;
continuous observer corrections are 266/479 µs for one paced batch (1,024 visible).
The unchanged local workload rerun retains flat idle cost, but host variance and
added transfer-aware planning give no latency improvement claim: maximum cold
local planning is 11.222/29.489 ms versus 5.812/7.619 ms at `ed06d5a`.
Raw samples, exact scripts, source hashes and coverage are retained in
`.local/orb-delivery-{imports,local}-38cf281.{exs,json}`. These are pure worker/ETS/
replication measurements without disk/socket/gameplay load; actual client tests
overlapped on the host. They do not establish server capacity or comparative speed.

Actual client **PASS** (2026-10-19), Java26.3/protocol777, frozen `38cf281`:
all five scenarios pass on the same whole dataset
`.local/client-tests/VMC-034n3b/world`. It began with 14 real receipt-backed
obligations and no creation/transfer records. Runtime produced 13 local markers,
12 local sprites/4,931 XP and one remote route/adoption/sprite worth3 XP. Exact
pending, local, source/destination transfer and imported record maps match.
Actual W/S crossed x640 and contacted the single remote sprite without duplicate,
persistent drift, pickup or XP gain. Mining A/ordinary item pickup and cooking B
passed; ordinary/Shift earned-output take remained refused with empty cursor.
Both owner replacements preserved 13 UUIDs with disjoint fresh network IDs and no
old tracked IDs. Duplicate delivery returned `already_applied`, preserving IDs.
Full server restart/fresh direct client retained the scene, inventory and refusals.

Final source sequence/typed receipt24, cursor/outbox nil, all 14 obligations retained,
4,934 owned XP, A absent, Boutput1/use1, gold13/smoothstone1/furnace1, pickaxe wear1,
raw iron/coal/dirt0 and no dropped item records; pickup receipt16 retained. Both
owners/clock flushed, players0, owned helpers/JVMs/servers stopped and port25565
clear. Report: `.local/client-tests/VMC-034n3b/report.md`; exact reconciliation,
identity and duplicate diagnostics remain alongside it. Tester diagnostic assertion
errors were corrected and final assertions pass. No routine images were required.
Static staging/client6,000-tick lifetime, offline-auth/renderer warnings and muted
audio remain limits. No physics/pickup/player-XP/full-survival claim. Next:
[authoritative orb simulation](VMC-034n4.md); earned output remains gated.
