# VMC-048a — Repeaters, comparators and observers

Status: Planned
Milestone: M3
Depends on: [VMC-047a](VMC-047a.md).

The components that time and measure power:

- **Repeaters:** delay, locking and orientation.
- **Comparators:** compare and subtract modes. They read container
  fullness (chests, furnaces, hoppers once VMC-049a lands), cake, cauldrons,
  composters, lecterns, item frames and end portal frames.
- **Observers:** pulses on the shape changes VMC-029d models.

Their scheduled ticks use vanilla's priorities, in the tick pipeline's
per-chunk containers.

Acceptance:

- Timing fixtures (repeater chains, comparator clocks, observer pulses)
  match the oracle tick by tick.
- A comparator reading a chest's fullness matches vanilla on the real
  client.
