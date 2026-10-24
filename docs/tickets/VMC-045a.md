# VMC-045a — The Ender Dragon fight

Status: Awaiting client
Milestone: M3
Depends on: [VMC-041b](VMC-041b.md), [VMC-037o](VMC-037o.md),
[VMC-050a](VMC-050a.md), [VMC-043e](VMC-043e.md) (endermen in the End).

`EndDragonFight` as vanilla runs it:

- **The dragon.** Its phases: holding, strafing, landing, perching, breath
  and charging, plus fireballs and dragon's breath. Its multipart hitboxes
  take damage.
- **End crystals.** The spikes' crystals generation records explode and
  heal the dragon.
- **After the kill:**
  - the exit portal activates and the dragon egg is placed;
  - each kill opens a new End gateway;
  - the credits and leaving the End follow;
  - the respawn ritual with four crystals.
- **Persistence.** The fight's state survives restarts.

Acceptance:

- The fight's phase and pathing fixtures match the oracle.
- On the real client, a player kills the dragon and leaves by the exit
  portal.

Slices: [VMC-045a1](VMC-045a1.md) makes the crystals live first. Dragon
geometry and arena paths are [VMC-045a2](VMC-045a2.md), with phase decisions
in [VMC-045a3](VMC-045a3.md). The living body, part IDs, damage and wire
routing are [VMC-045a4](VMC-045a4.md), with group-wide projectile authority
in [VMC-037o1](VMC-037o1.md). [VMC-045a5](VMC-045a5.md) connects live
ticking, attacks, crystal healing and death. [VMC-045a6](VMC-045a6.md)
defines arena geometry, boss packets and the respawn sequence.
[VMC-045a7](VMC-045a7.md) admits the live fight and commits its portal,
egg and gateway with completion. [VMC-045a8](VMC-045a8.md) connects the
full four-crystal ritual, pillar regeneration, abort and restart recovery.
The complete live fight is in its batched finale client gate. Its first
live natural-spawn run exposed ordinary distance despawning of the boss;
[VMC-045a9](VMC-045a9.md) fixes and rechecks that policy before the fight
can pass. Its recheck then exposed zeroed actor motion at shared mob-tick
finalization; [VMC-045a10](VMC-045a10.md) restores that flight boundary.
