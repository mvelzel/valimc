# VMC-026c — Items through portals

Status: Awaiting client
Milestone: M2 real worlds
Depends on: [VMC-026b](VMC-026b.md) (live dimensions and portals),
[VMC-067](VMC-067.md) (the entity model), the item handoffs of VMC-064.

Dropped items travel through nether portals, end portals and end gateways as
vanilla's `ItemEntity` does. Experience orbs would follow the same path, but
orbs do not move yet (their motion is [VMC-034n4c](VMC-034n4c.md), paused),
so none can enter a portal; they join once they move.

Acceptance:

- An item whose box meets a portal on its way during a tick, off portal
  cooldown, travels at once: non-players have no portal time. It starts the
  cooldown of 300 ticks (`getDimensionChangingDelay`), which a touch renews,
  so an item arriving in a portal stays there until it leaves.
- Nether portals: the other dimension, the scaled position, the closest
  portal or a new one, as for players (VMC-026b2). Items create exit portals,
  as vanilla's do. The item arrives at its place in the exit portal for its
  own size (0.25 × 0.25).
- End portals: from outside the End, the End's arrival platform is built and
  the item arrives at (100.5, 50, 0.5), a block above a player's place. From
  the End, the item arrives at the world spawn's column, on its
  MOTION_BLOCKING_NO_LEAVES surface (`adjustSpawnLocation`).
- End gateways: the gateway's exit, as for players (VMC-026b4), building the
  exit gateway when the gateway has none.
- The item keeps its stack, age, pickup delay and UUID. Its velocity follows
  vanilla's `PositionMoveRotation.calculateAbsolute` for the transition's
  relative flags: rotated by the yaw change (`ROTATE_DELTA`). The same
  rotation applies to players, which VMC-026b2/b3 left out: a portal whose
  axis differs from the entry's turns the velocity a quarter, and entering
  the End turns it to face west.
- Crossing dimensions uses the item handoff: the source withdraws the item
  durably into its one outgoing intent, then delivers it to the destination
  dimension's owner, which adopts it with a receipt. Retries are idempotent,
  and a crash on either side loses or duplicates nothing.
- Velocity rotation equals vanilla's (`portals` stage).

## Design

- `ItemMotionState` gains `portal_cooldown` (0..300), counted down as items
  age. Item records keep it in a free flag bit of the v3 motion encoding, so
  records without a cooldown keep their bytes (receipt digests hash them).
- Cross-dimension handoffs tag their keys: the source is `{dimension, key}`
  and so is the destination, both absolute. Same-dimension handoffs keep
  plain keys and their exact bytes. A destination's receipts from another
  dimension's region therefore never meet those of a same-coordinate
  neighbour. `ItemLedger` v2 stores tagged receipts and a tagged outgoing
  intent; ledgers without either keep v1's bytes.
- `Valimc.Portal.Contact`: the portal blocks a box met along a movement,
  shared by players (published snapshots) and region owners (their own
  blocks).
- Region owners check moving items' local steps for portal contact,
  renew or start cooldowns, and run one destination job at a time, off the
  owner (`Valimc.Portal.Destination`, `EndPortal`, `GatewayDestination`,
  with the entity's size). The result becomes a handoff: tagged for another
  dimension, plain for another region of the same one, or a local move.
- `Valimc.Portal.Motion` ports `calculateAbsolute` with vanilla's `Mth`
  sine table.

## Evidence

- `portals` stage, October 21, 2026: 400 arrival poses over random
  travellers equal vanilla's `calculateAbsolute` exactly. They cover nether
  portals turning 0 or 90, into the End, out of it with a spawn's rotation,
  and gateways, with every earlier case still equal.
- `test/item_portal_region_test.exs`, live owners:
  - An item falling into a lit nether portal leaves its region and arrives in
    the Nether inside a new portal near an eighth of its position. It keeps
    its stack, UUID and age, with its cooldown running.
  - An item dropping into an end portal arrives at (100.5, 50, 0.5) on the
    obsidian platform.
  - An item in a gateway with an exact exit in another End region moves
    there.
- `test/item_portal_handoff_test.exs`:
  - An overworld item handed to a Nether region is adopted once, and stays
    once after both owners restart.
  - A Nether region and the overworld region at the same coordinates hand to
    one Nether owner, which keeps their receipts apart.
  - Crossing digests and the v2 ledger round-trip; v1 bytes are unchanged.
- `test/item_records_test.exs`: a portal cooldown adds two bytes; motion
  without one keeps its bytes. `test/portal_test.exs`: a quarter turn turns
  the motion; facing west into the End from the west, or a gateway, keeps it.

## Limits

- A destination found just before its owner stops is lost with the owner:
  the item stays where it was, on cooldown, until it enters again.

- Resting items are not checked: an item lying in a portal that opens around
  it stays (vanilla's travels). Items arriving in an exit portal stay in
  vanilla too, since their touch renews the cooldown.
- ValiMC items have no yaw (vanilla's is random from spawn), so an item
  entering the End turns its velocity as one with yaw 0.
- Experience orbs (no motion yet, VMC-034n4c), mobs (M3) and thrown ender
  pearls (projectiles, M3) do not use portals; a gateway's own 40-tick
  cooldown is not kept (VMC-026b4).

Reference: pinned 26.3 jar, Vineflower 1.12.0 decompilation (ignored
`research/decompiled/vmc-026b`, `vmc-026c`, `vmc-053`): `Entity`
(`setAsInsidePortal`, `handlePortal`, `getDimensionChangingDelay`,
`teleport`, `teleportCrossDimension`, `restoreFrom`, `adjustSpawnLocation`),
`ItemEntity`, `ExperienceOrb`, `NetherPortalBlock`, `EndPortalBlock`,
`EndGatewayBlock`, `TeleportTransition`, `PositionMoveRotation`,
`Relative`, `Mth`.
