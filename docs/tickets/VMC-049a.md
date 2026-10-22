# VMC-049a — Hoppers, droppers and dispensers

Status: Planned
Milestone: M3
Depends on: [VMC-047a](VMC-047a.md), [VMC-037o](VMC-037o.md) (dispensers
shoot projectiles), [VMC-032](VMC-032a.md) (containers).

Item machines, as vanilla's `HopperBlockEntity`, `DispenserBlock` and
`DropperBlock`:

- **Hoppers:** cooldowns, pulling items from containers and item entities
  above them, pushing into containers including furnaces by side, and
  locking by power.
- **Droppers:** they drop items.
- **Dispensers:** each item's dispense behaviour, which includes
  projectiles, buckets with VMC-031a, bone meal with VMC-039a, armour,
  boats deferred, TNT and fire charges.
- **Menus:** each block's menu.

Transfers are ordered and atomic in the group's commit and never duplicate
items. A transfer between containers in different groups uses the
cross-owner primitive.

Acceptance:

- Transfer-order fixtures (hopper chains, furnace feeding, item pickup)
  match the oracle.
- No item duplicates or vanishes under concurrent group ticks or a crash.
- A hopper-fed furnace works on the real client.
