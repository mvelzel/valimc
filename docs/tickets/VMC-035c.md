# VMC-035c — Ordinary item pickup

Status: **Done within unmounted, untargeted pickup scope**, October16,2026.
Runtime checkpoint `79811a818824ae869e43232af83b58217478cde4`.
[Advanced contexts](VMC-035c1.md) and [cross-owner merging](VMC-035b1.md) remain open.

## Behavior and authority

Native inventory insertion preserves slot priority, exact components, partial
capacity and creative overflow. Partial insertion changes inventory and the world
remainder even when the native callback is false. Delay, mode, health, loading,
teleport and contact gate live collection; adjacent-region contact works.

Each connection owns player/inventory ordering and one bounded pickup query.
Visible position/delay hints discover candidates; they confer no authority. Queries
rotate candidates, release unusable grants, and create no empty-scene jobs. Fresh
accepted player state fences responses. Regions recheck their current owned item.
There is no global gameplay coordinator or process per item.

1. Region admission durably reserves source receipt capacity before granting
   contact permission: at most128 grants/owner, one/source,250ms lifetime.
2. The leased player writer assigns a monotone sequence and saves the original
   inventory plus a v16 intent. Slots/cursor/table/selection and material permission
   are pinned; a later mode change cannot reinterpret an accepted insertion.
3. A bounded owner plan commits withdrawal/partial replacement and a typed applied
   or rejected receipt together, before publication. Competing mutations wait/refuse.
4. The source writer fetches actual owner proof before saving gain plus intent clear.
   A delivery acknowledgment or observation cannot grant inventory. Rejection clears
   without gain; lost acknowledgments replay receipts, never recreate withdrawn items.
5. Disconnect/reopen uses the same protocol. Failed final source saves retain a
   recoverable intent. Expired preparation rejects safely and can retry with a new
   sequence; committed counters/receipts never rewind.

Whole pickup emits the native take callback after commit. Partial false callbacks
emit none. Canonical requests are at most131,164bytes; source intents add41bytes.
Legacy source records remain readable. Regional receipt tables remain bounded4096;
sequence0/digest0 reserves capacity and acknowledges no positive transfer.

## References and verification

Pinned Mojang26.3 `Inventory.add(ItemStack)`, `ItemEntity.playerTouch` and
`Player.aiStep` supply insertion/callback/contact behavior. An unmounted body expands
by(1,0.5,1); strict native AABB intersection applies. Reference bytecode remains
ignored in `.local/{inventory-pickup,item-entity,drop-player}-bytecode.txt`.

| Check | Result / private evidence |
|---|---|
| Native insertion |384 actual cases; `.local/item-pickup-native{.json,.log,-check.log}` |
| Native contact |5,832 boundaries; `.local/item-pickup-contact-native{.json,.log,-check.log}` |
| Pure withdrawal/source codecs |26 withdrawal /42 source checks; `.local/{pickup-withdrawal,player-pickup-intent}-targeted.log` |
| Capacity / leased writer / permits |30 /36 /19 checks; `.local/{pickup-receipt-reservation,player-pickup-store,pickup-permits}-targeted.log` |
| Live region/writer/delivery |62 checks(seed352045); `.local/pickup-inbox-checkpoint-targeted.log` |
| Automatic TCP / related regressions |73 checks(seed476133); `.local/pickup-auto-checkpoint-targeted.log` |
| Storage/worker pressure |14 checks, including3 new cases(seed618829); `.local/pickup-pressure-targeted.log` |
| Full suite |1,123 pass(seed489962); `.local/item-pickup-full-tests-retest.log` |
| Production / full native integration |PASS, including plaintext and continuous AES-CFB8 TCP; `.local/item-pickup-{production,full-native}.log` |

The first broad run had one obsolete item-age assertion: the new delay hint changes
while retained wire packets/versions do not. The corrected assertion and full
retest pass; runtime code was unchanged. Frozen manifest805 blobs:
`.local/item-pickup-checkpoint.json`.

Actual Minecraft PASS across8 fresh direct Java26.3/protocol777 launches: natural Q
and menu whole-stack drops, positive-delay contact then collection, partial7→1+6,
full survival refusal, creative overflow, spectator/range negatives, distinct named
stacks across an ownership boundary, reconnect and a paused-save/disconnect/retry.
The dedicated tester owns the verdict: `.local/client-tests/VMC-035c/report.md`.
No unexpected protocol/gameplay error occurred. All clients stopped; full original
player restored except latest sequence30/nil outbox, histories retained, owners
flushed, runtime module hashes unchanged, zero players/connections.

Exact take-animation frame timing/sound, graphical two-player contention and a
post-withdrawal crash were not separately certified. Owner/TCP fault tests cover
contention, owner restart before/after withdrawal and failed final source saving.
Mounted pickup/persistent exclusive targets remain the separate follow-up.

## Measurement

`bench/item_pickup.exs` exercises real source saves, region withdrawal, delivery and
proof across4/32 sources,1/8 owners,64/512 entities and plain/4KiB components. Both
runs conserve all items. Run01:721–1,349 pickups/s,1.6–24.6ms median. Run02 during
full-suite/native/client load:76–145/s,37–244ms median,42 safely rejected/retried
expired permits. These measure trusted-contact durable I/O; TCP, graphics, physics
and cross-server comparisons are excluded. Raw results/workload hashes/load notes
and whole datasets: `.local/item-pickup-bench-{01.log,02.log,manifest.json}` and the
logged `/tmp` paths. This establishes no fastest-server claim.
