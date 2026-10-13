# VMC-005a — Owner-local player inventory and synchronization

Status: Awaiting client validation. Updated: October 13, 2026. Depends on tested VMC-004a code.
VMC-003/004a remain queued for actual-client verification and unpushed.

## Scope and acceptance

Replace the nine-entry hotbar preview with a bounded session-owned player menu:
46 indexed slots, selected hotbar, cursor and 15-bit menu state ID.

- Initial play sends exactly 46 slots, empty cursor and selected slot. Independent
  connections cannot observe or mutate each other's inventory.
- Creative writes accept menu slots 1..45, including main storage, armor, hotbar
  and offhand; result slot 0 is not client-writable. Preserve accepted stack
  count/components and correct unsupported or out-of-range edits.
- Slot selection and main/offhand lookup use authoritative session state. Hand
  swaps atomically update both slots. Ordinary blocks place from either hand.
- Unknown/stale container interactions never apply client-reported slot changes.
  Until click transactions land, explicitly restore the authoritative snapshot
  and cursor instead of silently accepting client-side prediction.
- State IDs wrap at 32768; empty slots do not allocate growing map entries.
- ExUnit tests cover all slot boundaries, state wrap, isolation, held items,
  offhand/swap and correction. Mojang decodes startup/full inventory packets,
  slot edits, cursor, selection, swap and resynchronization over real TCP.

Actual-client scenario, queued while locked: join, inspect empty inventory,
fill main storage/hotbar/offhand in creative, select another hotbar slot, swap
hands with F, place ordinary blocks from both hands, attempt unsupported inventory
click and verify resynchronization. Reconnect currently resets items: inventory
persistence, click/drag/shift transactions and drops are separate slices.

## References and design

Pinned 26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`InventoryMenu` slot mapping; `AbstractContainerMenu.incrementStateId` masks
with 32767; `ClientboundContainerSetContentPacket`,
`ClientboundSetCursorItemPacket`, `ClientboundSetHeldSlotPacket`;
`ServerboundContainerClickPacket` (hashed predicted stacks, not trusted inventory);
`ServerGamePacketListenerImpl.handleSetCreativeModeSlot` permits 1..45.
Private disassembly remains ignored.

SteelMC `f6fb4e49778c`, `steel-core/src/player/player_inventory/core.rs` and
`player_handlers.rs`: stable slot mapping and separation of menu dispatch from
player inventory. Use a pure bounded Elixir struct inside the existing session
owner; no locks, global coordinator or extra process per slot. Authoritative
region transfer/cross-owner inventory transactions are later survival foundations.

## Verification

October 13, 2026: all 41 ExUnit tests pass. Formatting and production release
pass. Pure and TCP tests cover 46-slot mapping, result/out-of-range restrictions,
state wrap, sparse clearing, startup/cursor/selection snapshots, stale prediction
restoration, main storage/offhand writes, selected-hand swap/placement and peer
isolation. New regressions verify abort/direction-change actions retain blocks.

The expanded Mojang TCP oracle initially found a version mismatch: 26.3's
`CHANGE_DESTROY_DIRECTION` shifts subsequent action enum values. We now extract
all nine action IDs from the pinned runtime; swap is 7, abort is 2, stop is 3.
The previous preview incorrectly treated abort as completed breaking. Fixing
the mapping and generating facts addresses both the new swap behavior and that
existing bug. Existing item/component facts are semantically unchanged.

Mojang's stack fixture checks and full TCP oracle pass, including startup/menu
packets, main storage/offhand/selection, hand swap, offhand placement and stale
click snapshot/cursor restoration. Public-tree audit and exact-diff checks pass.
Actual-client validation remains queued. Inventory clicks currently inspect only
container/state headers and discard the predicted body without mutation; full
bounded hashed-click decoding/transactions are VMC-005b. Drops, persistence,
crafting and equipment replication remain separate work. No full inventory
transaction/persistence compatibility or GUI pass is claimed.

## Checkpoint

Planned subject: `VMC-005a: own and synchronize player inventory slots`.
Local commit after automated checks; push deferred. Next: VMC-004b and VMC-005b.
