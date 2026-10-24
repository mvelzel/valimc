# VMC-045a — The Ender Dragon fight

Status: In progress
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
routing are [VMC-045a4](VMC-045a4.md). World ticking, attacks and the arena
lifecycle follow within this parent.
