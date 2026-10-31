# VMC-032c — Remaining containers

Status: In progress
Milestone: M4
Lane: Containers, after [VMC-004b](VMC-004b.md).

Shulker boxes keep their contents when broken and carried, ender chests
hold per-player contents, barrels and the rest of 26.3's containers work,
and an occupied furnace can be removed ([VMC-034f](VMC-034f.md)). Every
container menu is a durable transaction: a crash never loses or duplicates
an item, and contents survive a restart and a group handoff. The brewing
stand belongs to the Effects lane (VMC-034o) and villager trading to the
Villages lane (VMC-044b).

Before this ticket a section owns three kinds of container entry: chests
(single and joined), the furnace family and the machines (hopper, dropper,
dispenser). Every other block entity state is refused on placement
(`BlockEntityTypes.unsupported?`, VMC-034f's container-variant refusal), so
barrels, shulker boxes, ender chests and copper chests cannot be placed.

| Slice | Scope |
|---|---|
| [032c1](VMC-032c1.md) | Barrels, and a storage entry kind the next slices reuse |
| [032c2](VMC-032c2.md) | Shulker boxes: placement, the peeking lid, the restricted menu, contents kept when broken and placed |
| [032c3](VMC-032c3.md) | Ender chests: per-player contents, durable with the player |
| [032c4](VMC-032c4.md) | Copper chests: chests that weather, wax and scrape with their contents |
| [032c5](VMC-032c5.md) | Removing an occupied furnace (its slots and stored experience) and named containers |
| [032c6](VMC-032c6.md) | The other item-holding blocks: crafter, decorated pot, chiseled bookshelf, shelf, lectern, jukebox, campfire |

The M4 gate ([VMC-084](VMC-084.md)) needs 032c1–032c3; the rest follow in
this lane.

## Status (October 31, 2026)

The lane stopped here at the user's request. On `main`: 032c1 (barrels),
032c2 (shulker boxes), 032c3 (ender chests) and 032c5 (occupied furnaces,
named containers; VMC-034f closed), each awaiting M4's batched client run.
`mix test.fast` passed except one swamp-hut spawning test that fails only
under host load.

Remaining, to resume in this order:
- 032c4, copper chests: started and stopped before any change was kept;
  begin from its ticket.
- 032c6, the other item-holding blocks: not started.
- Known gaps the landed slices recorded: explosions leave every block-entity
  cell standing (so they never break a shulker box or furnace); pistons do
  not break a filled shulker box; the shulker lid check ignores block-like
  entities and closes at once; pick-block drops a container's name;
  `/item … enderchest.N` does not reach ender slots; only the first and last
  opener send the lid count event.
