# VMC-040a — Beds, sleep and spawn points

Status: Planned
Milestone: M3
Depends on: [VMC-029d](VMC-029d.md) (two-part beds), [VMC-050a](VMC-050a.md)
(bed explosions).

- **Sleeping:** players sleep in beds; the night skips when the
  `playersSleepingPercentage` share sleeps; monsters nearby forbid sleep, and
  phantoms count time since rest.
- **Spawn points:** a bed sets the respawn point, and respawning at a missing
  or blocked bed falls back as vanilla does.
- **Explosions:** beds explode in the Nether and the End.
- **Respawn anchors:** they charge with glowstone and explode outside the
  Nether.

Acceptance:

- Sleep, skip and respawn fixtures match the oracle.
- With two clients, one sleeping alone does not skip the night under the
  default percentage.
