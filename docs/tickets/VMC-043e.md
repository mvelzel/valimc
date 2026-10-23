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
- [VMC-043e2](VMC-043e2.md) — squid, glow squid and fish: mobs tick one at
  a time, the kernel's water travels, fish move control, schooling, puffing,
  variants and sizes, flopping and air (Awaiting client).
- [VMC-043e3](VMC-043e3.md) — guardians and elder guardians: the guardian
  move control and travel, the beam, thorns, homes, Mining Fatigue
  (Awaiting client).
- [VMC-043e4](VMC-043e4.md) — bats: resting, flying and waking (Awaiting
  client).
- [VMC-043e5](VMC-043e5.md) — dolphins: the smooth swimming controls,
  breathing, drying, leaps, items and Dolphin's Grace (Awaiting client).
- [VMC-043e6](VMC-043e6.md) — turtles: home beaches, travels, eggs laid,
  hatched and crushed (Awaiting client).
- [VMC-043e7](VMC-043e7.md) — axolotls: their brain, playing dead,
  hunting, mid-tick melee on mobs, mob effects (Awaiting client).

Acceptance: behaviour fixtures match the oracle.

## Handoff (October 2026)

- Done and verified (Awaiting client): 043e1–043e7. Stage `mob_ai` (50 scenes,
  17463 ticks incl. dolphins, turtles, axolotls) and the targeted stages
  (`combat`, `paths`, `ai_facts`, `animal_facts`, `animals`, `village`,
  `nether_mobs`, `hostile_ai`) pass on the pushed tip.
- Cross-cutting changes siblings should know: mob melee on a mob of the
  same tick lands mid-tick in `MobTicks` (with `{:attack_extra, ...}`), mob
  effects tick only in `MobVitals.base_tick/2`, the MobAiOracle reports
  mob targets by entity id and stops ticking removed mobs.
- Remains: picking axolotls and fish up in buckets, a spawn group's later
  babies (axolotl variants, turtle packs), turtle eggs' `onPlace`
  particles; the batched client handoff for 043e1–043e7. Then close
  VMC-043e (Status stays In progress until the client gate).
