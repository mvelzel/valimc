# VMC-047a — Power sources, consumers and update order

Status: Planned
Milestone: M3
Depends on: [VMC-077m](VMC-077m.md) (wire power and the update engine),
[VMC-029d](VMC-029d.md) (redstone items place in their vanilla states).

Redstone wire power and vanilla's neighbour-update order already run in the
Rust block-update engine. Players cannot use redstone yet. This slice adds:

- **Sources:** levers, buttons and pressure plates (wood and stone, with
  their timing and entity checks), redstone torches with burnout, redstone
  blocks, daylight detectors, target blocks, tripwire hooks and tripwires,
  and lecterns' pulses.
- **Consumers:** redstone lamps, doors, trapdoors and fence gates opened by
  power, note blocks, and TNT ignited by power (with VMC-050a).
- **Rules:** strong and weak power, quasi-connectivity where vanilla has it,
  and the update order of its experimental-off evaluator, with no
  simplified fast redstone. Placement uses the oracle and power uses its
  fixtures.

Acceptance:

- Circuit fixtures from a redstone oracle match vanilla's states tick by
  tick, including across section and group lines.
- On the real client, a button-operated iron door and a lever-lit lamp work.
