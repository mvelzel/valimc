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

Remaining after VMC-026b: the dragon fight (the dragon, respawning crystals,
new gateways after each kill, the exit portal's activation) needs mobs (M3);
respawn points in other dimensions (beds, anchors) are VMC-040.
