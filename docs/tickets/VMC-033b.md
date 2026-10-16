# VMC-033b — Manual player-grid crafting

Status: In progress. October 16, 2026. Parent: VMC-033; uses [recipes](VMC-033a.md).

Acceptance: ordinary grid1..4 manipulations derive a result view and pickup0
takes one complete recipe output, consuming one from each occupied ingredient
cell atomically on the player owner. Both pickup buttons obey cursor identity/
capacity; creative crafting still consumes ingredients. Keep derived output out
of snapshots, physical conservation and close/disconnect/death drops. No global
crafting owner. Bound recipe matching, input work and encoded inventory size.

Pinned native `InventoryMenu`/`ResultSlot` probes in VMC-033a are the reference;
use that ticket's exact jar revision. Verify grid/result packets through real TCP,
wrong/full cursor, interruption, cleanup and reconnect. Dedicated actual tester
manually crafts logs→planks, mixed-plank sticks/table, inspects exact ingredients/
output, closes and reconnects. Recipe book, special recipes/items, remainders and
other result gestures remain explicit follow-ups.

Result0 is a derived display, never a physical inventory stack. Keep
`Inventory.contents` physical; only packet display includes the result. Ordinary
drop conservation cannot authorize recipe conversion: result throw needs a
trusted conversion plan plus exact durable records, and remains refused in this
slice. Result shift/swap/clone also remain refused until native-verified composition.
