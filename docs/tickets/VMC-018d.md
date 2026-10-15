# VMC-018d — Player equipment replication

Status: Live replication automated-verified; graphical gate pending. October 16, 2026.

Acceptance: nearby unmodified clients see both held hands and four worn armor
slots, including count/component changes, hotbar selection, swaps, consumption,
clearing, reconnect and tracking recreation. Publish committed owner inventory
observations; they never authorize inventory actions. Bound updates to six player
slots, batch changes and avoid unchanged packet work. Retire departed peer views.

Reference: pinned 26.3 `ClientboundSetEquipmentPacket`, `EquipmentSlot` and
`LivingEntity` equipment change tracking. Jar SHA1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Private codec/slot inspection stays in
`.local/equipment-{packet,slots}.javap`. Verify native codecs before live use.

Original `EquipmentOracle` passes128 bidirectional native packets: all eight
native slots, empty/plain/patched stacks, entity-ID boundaries and continuation
batches of one through eight entries. One boundary regression rejects invalid,
empty, duplicate and oversized equipment batches. Evidence:
`.local/equipment-{native,check,verify,packet-tests}.log`. These checks do not
publish live equipment or replace the graphical gate.

Live checkpoint: each player publishes six committed inventory observations only
when selected/storage slots change. Existing peer views retain the rendered
equipment and emit one bounded delta batch, including clears; unchanged and
effective-default patches emit nothing. Spawn/recreation initialize current gear.
Use-animation delivery refreshes the peer view first, ensuring its held item is
sent before the active flag. Respawn clears gear; reconnect derives it from the
durable inventory. No global equipment owner or extra timer was added.

Thirty-nine affected tests pass, including two real TCP peer scenarios for initial
hands/armor, selection, patched counts, removal, reconnect and off-hand soup→bowl
with equipment-before-animation ordering. Pure boundaries cover all six slots,
effective identity, clearing and tracking recreation. Evidence
`.local/player-equipment-{compile,affected-tests}.log`. Actual peer rendering is
still pending; native packet equality alone does not complete the client gate.

Client scenario: a second local peer changes held bread/bowl, swaps hands, equips
and removes armor, changes item components and reconnects. Observe third-person
use animation with the correct item; clearing/recreated entities must not retain
old gear. Delegate to the dedicated tester on a frozen release. Full attribute,
combat and specialized wearable behavior remain separate owners.
