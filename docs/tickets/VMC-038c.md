# VMC-038c — Smithing

Status: Awaiting client
Milestone: M4
Depends on: [VMC-038b](VMC-038b.md) (the block menus' inputs and results).

Netherite upgrades and armour trims with templates match the oracle.

## Design

- **Recipes.** `SmithingOracle facts` writes the data pack's 30 smithing
  recipes to `priv/crafting/smithing.json`: each one's template, base and
  addition item sets, a transform's result and a trim's pattern.
- **Rules** (`Valimc.Menus.Smithing`, pure): `result/3` is
  `SmithingMenu.createResult`: the first recipe whose ingredients take the
  inputs (no ingredient takes no item); a transform (the netherite upgrade)
  turns the base into its result keeping every component (enchantments,
  wear, trim, name); a trim puts the template's pattern and the addition's
  `provides_trim_material` on one of the base, unless it wears that trim
  already. `may_place?/2` is the slots' recipe property sets.
- **Menu** (`Valimc.Player.Anvil` with the anvil and the grindstone; window
  type 21): the template, base and addition are the player's three menu
  inputs (`Inventory.payments`, now two or three); clicks on them go
  through the engine; taking the result (window slot 3) uses one of each
  input and plays the table's event (1044), in one session callback.

## Implementation (October 31, 2026)

- `SmithingOracle cases` assembles, in a `RecipeManager` over the data
  pack, every template with eight bases (diamond and iron gear, netherite
  boots, a turtle shell, horse armour, a stick) and eight additions
  (netherite, trim materials, wrong items), plain, enchanted and worn, and
  already trimmed. Stage `smithing`: the recipes equal the committed facts
  and 2,632 cases equal.
- Tests: the connection test "a smithing table upgrades an enchanted
  diamond sword to netherite"; stages `smithing`, `anvil` and
  `enchanting_table`.

## Awaiting client

- A smithing table upgrades diamond gear to netherite (enchantments kept),
  and trims armour with a template and a material (the trim shows on the
  armour and in its tooltip).
