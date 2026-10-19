# VMC-005b2b — Authoritative collect-to-cursor

Status: Done
Note: Done. Updated: October 13, 2026. Depends on VMC-005b1/005b2a.

## Scope and acceptance

Ordinary double-click currently restores state as unsupported. Implement
`PICKUP_ALL` against owned slots and cursor, with vanilla's two-pass ordering.

- A nonempty cursor and an empty trigger slot enable collection. An occupied
  pickup-enabled trigger or an empty/full cursor leaves items unchanged.
- Button 0 scans slots in ascending order; button 1 scans descending. Collect
  partial stacks first, then full stacks, up to the cursor's effective stack cap.
- Include crafting inputs, equipment, main storage, hotbar and offhand, while
  excluding crafting output. Preserve item/component totals and patch identity;
  incompatible stacks stay untouched. Existing drag interruption rules apply.
- Predictions and stale state IDs never supply owned items. Invalid buttons or
  slot indices receive existing authoritative corrections. Each transaction has
  at most two scans of 45 slots and runs within the connection's existing owner.
- Test order, pass priority, caps, empty/occupied triggers, component mismatch,
  crafting-output exclusion, atomic conservation, forged observations and peers.
  Add an independent behavior oracle calling Mojang's actual collect algorithm,
  plus a Mojang-codec TCP scenario.

Actual 26.3 client scenario: use the ordinary-menu UI fixture, seed separate
component-bearing stone stacks and eggs, double-click to collect stones, inspect
cursor/remaining counts, place the result, and collect eggs to their cap of 16.
Check incompatible patches stay separate; exercise an unsupported drop and
reopen. Setup fixtures do not count as computer-use actions.

## References and design

Pinned vanilla 26.3 server jar SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`AbstractContainerMenu.doClick(PICKUP_ALL)`, `Slot.safeTake`,
`InventoryMenu.canTakeItemForPickAll`, `AbstractCraftingMenu` inheritance.
Private bytecode remains ignored. Vanilla prioritizes partial stacks in both
directions, checks the trigger, and excludes the result container. A focused
oracle invokes vanilla's menu method with ordinary slots; it does not stand in
for recipes, equipment locks, a full gameplay server or graphical validation.

SteelMC `f6fb4e49778c`, `steel-core/src/inventory/menu/mod.rs::do_pickup_all`,
separates dispatch from collection and explicitly performs two passes. Use
original Elixir code and a bounded pure transformation inside the socket owner;
do not copy its container locks or introduce another process/coordinator.

The current shared comparator requires identical accepted patches. Normalizing
different patches with equal effective default components remains a recorded
compatibility follow-up in VMC-004b2; do not claim all item semantics are complete.
Cursor return/drop, creative clone/fill, recipes, inventory persistence and
enchantment-based equipment locks remain subsequent slices.

## Verification

October 13, 2026: all 71 ExUnit tests, formatting, production release, public-tree
audit/self-tests and exact diff checks pass. The full Mojang oracle passes both
the collect behavior harness and the TCP collect scenario with forged diamond
predictions. The harness binds official item defaults and invokes Mojang's menu
method with ordinary slots and a constructor-free test player, allocated only
inside this development tool. The collect branch does not use world/player
lifecycle state. This is explicit focused algorithm evidence, not full gameplay
or equipment-lock validation; no JVM is introduced into the Elixir server.

Actual Minecraft 26.3 CUA, using the isolated SDL adapter, passed after a graceful
release restart and localhost join. A normal creative-input fixture populated
the items, and a game-event fixture selected the ordinary inventory UI while
the server retained creative gameplay. CUA double-click of the hotbar's 50
patched stones produced cursor 64, consumed the partial 7 and 7 of the partial 9,
retained the full source 64 and left the incompatible plain 7 unchanged. The
owner confirmed exact counts and identical glint/custom NBT. CUA placed the
collected stack in the hotbar. Double-click of 8 eggs collected to cursor 16,
leaving 2 of the source 10, then CUA placed that result. Q/drop displayed the
existing unsupported-operation correction; reopen preserved stone 64 and egg 16.
Final cursor was empty; all component-group totals were conserved.

The client log has zero Network Protocol Error, DecoderException,
EncoderException or ERROR entries; its private copy remains under
`.local/client-tests/VMC-005b2b/`. The parent inventory subsystem, equal-default
patch normalization and VMC-005b2a's sustained-gesture gate remain incomplete.
Checkpoint subject: `VMC-005b2b: collect owned stacks into the cursor`.
