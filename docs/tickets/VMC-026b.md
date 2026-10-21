# VMC-026b — Live Nether and End with portals

Status: In progress
Milestone: M2 real worlds
Depends on: [VMC-026a](VMC-026a.md) (Nether and End generation),
[VMC-025](VMC-025.md) (live decoration, VMC-025d; structure placement,
VMC-025f, for stronghold portal rooms).

Players reach the Nether and the End and come back as vanilla's do: each
dimension is a live world of its own, and nether portals, end portals and end
gateways carry players between them.

Subtickets:

| Ticket | Slice | Status |
|---|---|---|
| [VMC-026b1](VMC-026b1.md) | Dimension lifecycle: owners, storage, generation and light per dimension, the client's dimension switch, travel that keeps the player's state, reconnects and deaths elsewhere | Awaiting client |
| [VMC-026b2](VMC-026b2.md) | Nether portals: lighting with flint and steel or fire charges, portal blocks and their collapse, entering after the portal time, the scaled destination, portal search and creation, cooldowns | Awaiting client |
| [VMC-026b3](VMC-026b3.md) | End portals: frames filled with eyes of ender, travel to the End's arrival platform, the exit portal (credits, return to spawn) | Awaiting client |
| [VMC-026b4](VMC-026b4.md) | End gateways: teleport to the outer islands with vanilla's exit search, the exit gateway they generate | Awaiting client |

Acceptance (parent):

- A player lights a nether portal, travels to the Nether and back, a portal
  is created on the other side where vanilla creates it, enters the End
  through an end portal onto the arrival platform, uses a gateway, and
  reconnects after a restart in the Nether, as a vanilla client sees it.
- Where vanilla is deterministic (portal shapes, search and creation, the
  arrival platform, gateway exits), ValiMC's results equal vanilla's in
  oracle stages registered in `scripts/vanilla_stages.py`.

## Client check

First run, October 21, 2026: checkpoint c8dcb04, Java 26.3 on a fresh flat
creative world. The evidence stays ignored in `.local/client-tests/VMC-026b`.

- Passed:
  - Lighting a portal; an incomplete frame makes only fire.
  - Walking into the portal to a new Nether portal, and back to the first.
  - A restart and reconnect in the Nether, at the same place.
  - The twelfth eye opening an end portal; the End's platform.
  - A gateway's exit search out to (1028.5, 71, -5.5), and back to
    (93.5, 57, -6.5).
  - The credits, then the respawn at spawn with the inventory kept.
  - A broken frame putting the portal out.
- Failed twice, and both trace to a first visit's destination taking
  seconds. Regions generate whole on first use, slowly on that loaded host
  (load 40–70 with the client).
  - The first walk through a freshly lit portal seemed not to travel. A
    `/tp` into the portal 14 s later (the client's log) then ended in the
    Nether at the typed coordinates, inside netherrack. The walk's job had
    meanwhile finished, so the `/tp` ran in the Nether. In tests, a command
    teleport into a portal arrives at the scaled exit.
  - A player dropped into the new end portal travelled after about 14 s,
    just after a nudge. In tests the End's first platform takes 0.8 to 4.3 s
    under a load of 47.
  - The gateway case that looked the same was a position mistake. The player
    stood beside the exit gateway: this seed's is at (1028, 80, -7), and a
    test reproduces the run's arrivals exactly. The `/tp` went to x 1029.5.
- Fixes:
  - Portals warm their destinations (VMC-026b2, VMC-026b3).
  - A failed destination lets the player try again.
  - `/spawn` from another dimension travels to the overworld's spawn (it
    moved the player within the Nether).
- Observed:
  - The exit gateway cannot be flown into, as in vanilla: bedrock above and
    below.
  - "Loading terrain" lasted 6 to 22 s on overworld arrivals. Tests deliver
    a return's 49 chunks in 34 to 68 ms; the rerun times it.
- Pending: a rerun walks into a portal right after lighting it, drops into
  an end portal right after opening it, enters a gateway at its block, and
  times the overworld arrivals.

Remaining after VMC-026b: the dragon fight (the dragon, respawning crystals,
new gateways after each kill, the exit portal's activation) needs mobs (M3);
respawn points in other dimensions (beds, anchors) are VMC-040.
