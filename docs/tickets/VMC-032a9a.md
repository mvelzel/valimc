# VMC-032a9a — Owner-fenced ordinary chest viewing

Status: Automated verified; dedicated Minecraft validation pending. Parent
[live menus](VMC-032a9.md) retains all exchange/physical lifecycle gates.

Acceptance: the unmodified26.3 client opens an owned single chest as a3×9 view,
sees its current contents and its own main inventory/hotbar, closes/reopens and
reconnects without moving items. Refuse predicted clicks in this checkpoint.
Respect main/offhand/secondary precedence, initial lid obstruction, current entity/
range/owner validity and relocation. Do not claim lid animation, sounds, locks,
loot-table filling, double chests, physical creation/removal or live exchanges.

The existing per-socket menu job owns at most one250ms query with a300ms deadline.
The region checks current block/entity and returns immutable contents only on
open or changed revision. Unchanged tick checks return a small validity decision;
missing/replaced owners and expired contexts close the view. Player state never
owns the shared contents. The source action preview from8a820ce remains unused
until exchange wiring lands.

October18 checks:47 affected tests pass (seed419522), including real TCP opening/
content/refused pickup/shift/offhand/wrong ID, hand/secondary/spectator, lid blocking,
missing entity, removal, relocation, owner replacement and fresh reconnect. An
initial fixture inadvertently placed planks on its sneak-use negative, correctly
blocking its next open; the final negative targets the occupied underside and
does not mutate the dataset. Six native ChestMenu layouts/405 addresses and exact
ClientboundOpenScreenPacket/ClientboundContainerSetContentPacket bodies pass.
Raw `.local/chest-view-targeted-final.log`, `.local/chest-view-native.json` and
`.local/chest-view-native-comparison.log`. Mojang26.3 SHA1
33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c; provider/validity classes and obstruction
contexts are recorded in the parent and VMC-032a6.

Client scenario: clone the complete stopped a8 dataset; retain source66, item
receipts66/61 and container receipt63. Verify empty chest UI/main inventory of eight
planks, refused pickup/shift/number/offhand, close/reopen, then a fresh direct launch
with unchanged contents/counters. Confirm the existing table still opens and closes.
The dedicated tester owns visual acceptance and reports pass/fail with debug detail.
