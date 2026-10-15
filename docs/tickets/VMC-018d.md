# VMC-018d — Player equipment replication

Status: Native codec foundation verified; live replication pending. October 16, 2026.

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

Client scenario: a second local peer changes held bread/bowl, swaps hands, equips
and removes armor, changes item components and reconnects. Observe third-person
use animation with the correct item; clearing/recreated entities must not retain
old gear. Delegate to the dedicated tester on a frozen release. Full attribute,
combat and specialized wearable behavior remain separate owners.
