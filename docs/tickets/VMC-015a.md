# VMC-015a — Player movement observations and fall distance

Status: Automated checks pass; actual-client gate pending. October 15, 2026.
Depends on VMC-014c4 and VMC-011a8.

Track accepted displacement, client ground/contact flags and fall distance in the
player owner. Feed fall distance into contextual block geometry; the current live
queries previously always used zero, missing powder-snow collision changes after a fall.
Ground flags describe client reports, not independent proof of block support.

Acceptance:

- Compare accumulation, float rounding, landing/reset and water suppression to
  pinned native `Entity.checkFallDamage`; preserve accepted movement order.
- Failed, cancelled and pending positions cannot accrue fall distance. Rotation
  and status packets cannot invent displacement. Teleports clear motion history.
- Query signatures include fall context; workers still only return observations.
- Actual client: drop onto a solid floor and powder snow, jump, creative flight,
  teleport and reconnect. Inspect owner state and fresh logs alongside the image.

Reference: pinned 26.3 server jar, SHA256
`a362163eec5d1612d520772bc16e5b39c09e3b234fdc045f56bf544284ee8ae6`;
private dumps
`.local/gravity-*.javap` and `.local/movement-handler.javap`. Native connection
`tickPlayer` runs simulation then restores its reconciliation position;
`handlePlayerPositionChange` checks fall damage from accepted displacement and
resets distance after upward motion. `Entity.checkFallDamage` subtracts the
float-rounded negative Y delta and resets on landing. Native entity save/load uses
a double fall distance. This slice does not yet
implement health/damage, fluid detection, impulses or full tick integration;
those remain VMC-015 work, not substitutes for this state boundary.

Implementation: constant-size `PlayerMotion` belongs to the socket/player owner.
Only accepted geometry results commit displacement/fall context; rotation/status
packets retain native client-report flags without inventing displacement. Empty
client ticks clear known movement. Upward motion/flight and authorized relocations
reset fall distance; rejected moves preserve prior accepted distance. Queries and
signatures consume it for contextual blocks. Checksummed snapshot v6 persists it,
including pending inventory transfer and disconnect cleanup; v1–v5 still load.

Checks: 151 affected tests pass (motion/pose, codecs, persistence, transfer and
inventory recovery), plus 160 direct native fall cases and plaintext/AES native
TCP. The new regression caught/fixed a transfer-plan field filter that discarded
fall context after pending-disconnect recovery. Legacy migration and invalid
sealed negative/NaN/excessive distance cases are covered. Evidence and commands:
`.local/player-fall-checkpoint-tests.log`, `.local/player-fall-native.log`,
`.local/player-fall-native-tcp.log`, `.local/player-fall-checkpoint-commands.txt`.

Next gate: frozen actual-client drop/jump/powder-snow, flight, relocation/reconnect
and cleanup. Dry-block geometry uses accepted distance; live water/environment
resets, health/damage and forces remain explicit following work under VMC-015.
