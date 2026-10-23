# VMC-041a — Goals, targets, brains and sensors

Status: Done
Milestone: M3
Depends on: [VMC-015i](VMC-015i.md).

Vanilla runs two AI models:

- `GoalSelector` and target selectors with goal flags and priorities, for
  most mobs;
- `Brain`, with memories, sensors, activities and behaviours, for villagers,
  piglins, hoglins, axolotls and others.

A new AI context runs both inside the owning group:

- **Sensors** read the owner's own state and published snapshots: nearest
  players and entities, and hurt-by.
- **Randomness** per mob is deterministic.
- **Cost** is bounded per tick; no goal blocks the owner.
- **Shared goal library:** float, random stroll, look at player and random
  look, melee attack (driving VMC-037n), panic, avoid entity, tempt, breed,
  follow parent, and the nearest-attackable and hurt-by targets.

Families (VMC-043b–e) add their own goals on top of these.

Slices:

- [VMC-041a1](VMC-041a1.md) — goal selectors, sensing, navigation and the
  shared goal library; zombies and pigs (Done).
- [VMC-041a2](VMC-041a2.md) — brains: memories, sensors, activities and
  behaviours; a piglin admires gold (Done).

Acceptance:

- A zombie targets and chases (in a straight line, before VMC-041b) and
  attacks a player.
- A pig wanders, panics when hit and is tempted by carrots.
- A piglin's brain admires gold.
- Each matches the oracle's goal-selection fixtures.
