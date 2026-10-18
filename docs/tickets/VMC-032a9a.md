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

First client run at e0c9f27: **FAIL**, not published. Opening displayed the correct
Chest27+36 UI; actual hotbar pickup disconnected as malformed. InventoryClick's
prediction decoder still assumed0..45. The fix bounds prediction indices by the
active menu (63 for this chest), retaining46 for player/table menus.51 affected
checks pass (seed965650), now including nonempty hotbar predictions over TCP and
exact native hotbar pickup inputs for all six chest dimensions. Raw
`.local/chest-view-prediction-targeted.log`, `.local/chest-view-native-fixed.json`,
`.local/chest-view-native-fixed-comparison.log`. Dedicated fixed-client rerun pending.

The e0c9f27 coherent integration block passes1,481 full tests, production and both
native TCP transports. An incidental tester plank placement before opening consumed
one plank: the complete stopped dataset now retains seven planks, source/item3,3
receipt67, unchanged container receipt63/revision1/empty27 and old item2,2receipt61.
No reset was performed. First failure report `.local/client-tests/VMC-032a9a/report.md`;
wrapper stopped, zero players and all four region/clock flushes passed before shutdown.

Fixed68de778 client: the pickup/shift/number/F refusal stays connected, but F over
an occupied player hotbar creates a persistent client-only offhand ghost. Closing
and opening the player inventory clears it; authority remains seven in slot36,
no slot45, source67 unchanged. This is a failed correction gate, not item duplication.
Generic chest/table contents omit offhand, so resynchronization now also sends the
native ClientboundSetPlayerInventoryPacket for physical index40 (server slot45).
Pinned client ClientPacketListener.handleSetPlayerInventory writes that index
directly even with a chest open. Native empty/populated offhand bodies and25
affected packet/table checks pass (seed889700); exact fixed read-only build and
dedicated retest remain pending. Raw `.local/chest-view-offhand-native.json`,
`.local/chest-view-offhand-native-comparison.log`, `.local/chest-offhand-correction-targeted.log`.
