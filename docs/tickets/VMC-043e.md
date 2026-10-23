# VMC-043e — Water, ambient and End mobs

Status: In progress
Milestone: M3
Depends on: [VMC-041b](VMC-041b.md), [VMC-037o](VMC-037o.md).

The rest that spawning and structures bring in M3:

- **Water:** squid and glow squid, cod, salmon, pufferfish and tropical fish,
  dolphins, turtles (eggs and beaches) and axolotls.
- **Monuments:** guardians and elder guardians, with Mining Fatigue.
- **Ambient:** bats.
- **The End:** shulkers (bullets, the shulker box drop) and endermites.

Each mob's own code lives in its own family module (`Valimc.AI.Mobs.*`,
`Valimc.AI.Kind`): its goals, navigation, entity data and the parts of
vanilla's tick it overrides (a move control, a travel, what it does before
and after its AI). Goals two families share go to the shared goal library.

Slices, in order:

- [VMC-043e1](VMC-043e1.md) — endermites and shulkers: peeking, teleports,
  bullets and levitation, the shell drop (Awaiting client).
- VMC-043e2 — squid, glow squid and fish: the kernel's water travels, fish
  move control, schooling, puffing, variants and sizes, flopping and air.
- VMC-043e3 — guardians and elder guardians: the guardian move control and
  travel, the beam, thorns, Mining Fatigue.
- VMC-043e4 — dolphins, turtles (eggs, beaches, home) and axolotls (brain,
  playing dead), with the smooth swimming controls.
- VMC-043e5 — bats: resting, flying and waking.

Acceptance: behaviour fixtures match the oracle.
