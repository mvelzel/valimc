# VMC-038b — Anvils and grindstones

Status: Awaiting client
Milestone: M4
Depends on: [VMC-038a](VMC-038a.md) (block menus without a block entity).

Repair, combining, renaming, the prior-work penalty and "Too Expensive!";
anvil wear and falling anvils; the grindstone's removal and experience;
checked against the oracle.

## Design

- **Rules** (`Valimc.Menus.Anvil`, pure, over the loot registries'
  enchantment facts, now with each enchantment's `anvil_cost`):
  `result/4` is `AnvilMenu.createResult` (repair materials a quarter of the
  durability each, the same item's durability plus 12%, books and items
  merged with equal levels raised and capped, incompatible enchantments
  priced but dropped, unsupported ones refused unless creative or onto a
  book, stacks priced at 40, renaming and clearing a custom name, the
  prior-work penalty and the 40-level limit); `taken/2` is what `onTake`
  leaves of the addition; `grind/2`, `grind_base/1` and
  `grind_experience/2` are `GrindstoneMenu`'s result and experience;
  `valid_name/1` is `validateName`.
- **Menus** (`Valimc.Player.Anvil`; window types 8 and 15): the two inputs
  are the player's menu inputs (`Inventory.payments`); the engine plans
  clicks on them and the inventory (a grindstone takes what wears or is
  enchanted); the result (window slot 2) is derived and taken here, by a
  pickup or a shift-click. The anvil's cost is its data slot; a
  `rename_item` renames the result.
- **Taking.** An anvil's result costs its levels (creative players pay
  none) and uses up the input and the addition, or only the repair
  materials it used; in survival one take in about eight wears the anvil a
  step (chipped, damaged, gone, by a fenced block write) with its level
  event. A grindstone's result uses up both inputs and leaves its orbs at
  the grindstone. Items and levels change in one session callback.
- **Falling anvils** were VMC-050a2's: a falling anvil hurts what it lands
  on and chips or breaks.

## Implementation (October 31, 2026)

- `AnvilOracle` runs real `AnvilMenu`s for a survival and a creative player
  over 22 input pairs (repairs, combinations, books, incompatible and
  unsupported enchantments, prior work up to "Too Expensive!", renames,
  stacks, elytra and phantom membrane) and `GrindstoneMenu`s over 7 (single
  and merged items, books, curses, unlike items): results, costs, repair
  counts, rename-only flags and experience bases. Stage `anvil`: 51 cases,
  all equal.
- Tests: the connection tests "an anvil puts a book's Sharpness on a sword
  for its cost" and "a grindstone takes a sword's enchantments off for
  experience"; stages `anvil`, `enchanting_table` and `loot` (regenerated
  with `anvil_cost`).

## Awaiting client

- An anvil repairs a damaged sword with diamonds; combines two swords;
  puts a book's enchantment on; renames an item (the field and its cost);
  shows "Too Expensive!" on a heavily reworked item; chips after use.
- A grindstone removes a sword's enchantments, keeps a curse, and gives
  experience orbs.
