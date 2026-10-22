# VMC-029e — Survival mining of every block

Status: Planned
Milestone: M3
Depends on: [VMC-029a4](VMC-029a4.md) (block loot), [VMC-029d](VMC-029d.md)
(placed states).

Survival mining admits only some states today:

- about 359 cube and pillar states;
- slabs;
- blocks with block entities;
- four random-loot profiles.

`Player.Mining.supported?` corrects every other block back to the client.
That includes leaves, flowers, plants, torches, doors, beds and ores whose
drops depend on Fortune.

The survival run needs them all:

- every block's hardness, tool and harvest rules from the block facts;
- its loot table, with every vanilla loot function and condition the
  survival blocks use (Fortune, shears and Silk Touch already work);
- what breaking two-part and attached blocks also breaks, as vanilla does.

Acceptance:

- Every survival-obtainable block mines with the oracle's break time and
  drops.
- No survival block is refused.
