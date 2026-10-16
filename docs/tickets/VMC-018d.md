# VMC-018d — Player equipment replication

Status: Validated and complete within six-slot equipment replication scope.
October 16, 2026. Actual-client report reviewed and accepted on7337af64.

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
covered below; native packet equality alone did not complete the client gate.

Block checks: 767 full tests (seed327342), separate production build and both
plaintext/encrypted native TCP transports pass on frozen
`19555bc2cfaacaaf6dbdba09f49d7c36075fdcce` (596 blobs/no mismatches).
Logs `.local/equipment-block-full-tests.log`, `.local/equipment-validation-production.log`,
`.local/equipment-native-tcp-final.log`. The initial isolated TCP attempt timed
out compiling the fresh dev tree; explicit dev compilation followed by the same
driver passed. These checks exclude the subsequent bed-bounce fix.

Client scenario: a second local peer changes held bread/bowl, swaps hands, equips
and removes armor, changes item components and reconnects. Observe third-person
use animation with the correct item; clearing/recreated entities must not retain
old gear. Delegate to the dedicated tester on a frozen release. Full attribute,
combat and specialized wearable behavior remain separate owners.

October16 actual-client evidence — reviewed and accepted: immutable7337af6/
PID74315 on unchanged `/tmp/valimc-consumable-client-20261016`, Java26.3/protocol777,
mandatory SDL06f2450…950e1. Two fresh small actual SDL/CUA observer clients viewed
regular-TCP peer Bench180018; distinct behind-viewer TCP observer retained native
packet sequence. Initial bothhands/all4 distinct armor pieces rendered. Regular
selection, slotwrites and swap changed bowl/bread3-glint; purple glint visible,
counts verified by wire/owner only. Main/off use showed current item/face crumbs,
with committed equipment before active hand metadata. Native pinned client
`AvatarRenderer#getArmPose(Avatar,ItemStack,InteractionHand)` EAT/DRINK falls through
ArmPose.ITEM at bytecode167 (`.local/equipment-AvatarRenderer.javap`, clientSHA1
e877b6a07acd633fb3bb475002175cec036e7b87); waist-level peer food pose is native,
not a missing first-person raised-arm behavior. Armor/held clears rendered empty;
peer reconnect/newentity retained current clears. Regular off-soup completion in
survival gave food5→11/sat7.2 and bowl45, visible with currentdiamondchest. Native
observer events equipment61→mainflag62, equipment101→offflag102, soup equipment141
→offflag144, bowl145→stopflag146 verify ordering. Viewer accepted camera fixtures
out500.5/back2.5 retired/recreated peer cache/render with current bowl/chest only;
fresh actual observer reconnect and final departure had no stale gear. No manual
long-walk/count-visual/attribute/combat/overflow claim. All2JVMs stopped/waited143,
3peer connections+monitor closed, zeroPlayers. Main safe18HP/food20/sat20/air300/
fullinventory andsource10/outboxnil/lastdeath unchanged; all29 exact worldrecords
17/8/4/receipts10/6/9 conserved. New peer sources0/outboxnil, no drops/transfers.
Settings1/unlocked/regenfalse unchanged. Detailed actions/native-client conclusion,
raw protocol/owner traces/limits/cleanup: `.local/client-tests/VMC-018d/report.md`.
