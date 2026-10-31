# VMC-038a — The enchanting table

Status: Awaiting client
Milestone: M4
Depends on: [VMC-037q](VMC-037q.md) (enchantment effects).

Bookshelf power, the offered enchantments and the enchantment seed, and
lapis and level costs match the oracle.

## Design

- **Rules** (`Valimc.Menus.Enchanting`, pure): `bookcases/2` is
  `EnchantingTableBlock.isValidBookShelf` over the 32 offsets (a power
  provider with a transmitter halfway, both block tags); `offers/3` and
  `enchant/4` call the loot registry (`loot.rs` `table_offers` and
  `table_enchant`), which holds the enchantment definitions, the items'
  enchantability and `selectEnchantment`: `getEnchantmentCost` for each
  slot from the seed, then each slot's list reseeded with the seed plus the
  slot (a book loses one at random), and a clue drawn from it. A book
  becomes an enchanted book storing them.
- **Seed.** The player state keeps `enchantment_seed` (vanilla's `XpSeed`):
  a new player draws one, each enchanting draws the next.
- **Menu** (`Valimc.Player.Enchanting`, `Menu.enchanting/0`, window type
  13): the item and the lapis are the player's two menu inputs
  (`Inventory.payments`, as a merchant's payments: saved with the
  inventory, given back or dropped on close); clicks go through the one
  click engine (lapis only in its slot, one item in the item slot,
  `quickMoveStack`'s routes). After a change the offers are made again from
  the published blocks around the table and sent as the ten data slots
  (costs, the seed, the clues' enchantments and levels).
- **Buttons** (`container_button_click`, `clickMenuButton`): with at least
  the button's number in lapis and levels and the offer's cost in levels
  (creative players need none), the item takes the button's enchantments,
  the lapis and the levels go, the seed changes and the table sounds, all in
  one session callback in the player's state.
- **Access.** `MenuAccess` knows block menus without a block entity
  (`blockless/0`: the crafting and enchanting tables): the table opens as
  `{:open, :enchanting}` and stays valid within reach.

## Implementation (October 31, 2026)

- `EnchantingTableOracle` runs a real `EnchantmentMenu` over a probe level
  with bookshelves on the first N offsets (0 to 20, and a round with stone
  between some) for 17 items (books, tools, weapons, armour, a fishing rod,
  a pumpkin, a stick) and four seeds each: the costs and clues, then each
  affordable button's item, lapis and levels. Stage `enchanting_table`: 476
  cases, all equal.
- Tests: the connection test "an enchanting table enchants a sword for
  lapis and levels" (open, shift-clicks, offers, the button, close); stages
  `enchanting_table`, `loot`, `block_loot` and `enchantment_effects`.

## Awaiting client

- The table opens; a sword and lapis show three offers with their glyph
  clues; more bookshelves raise the costs to 30; a button enchants the
  sword, takes lapis and levels and plays the sound; a book becomes an
  enchanted book.
