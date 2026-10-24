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

## Finale client checkpoint (October 24, 2026)

The immutable motion repair runtime now shows the same normally admitted
dragon crossing the arena and approaching the podium. Actual survival
breath/knockback observations use disclosed regeneration/resistance; no exact
player damage amount is claimed. Actual spike-crystal bow explosions reduce
the live crystal count. A real arrow hurts the naturally computed body through
a part across X=0; [VMC-037o1](VMC-037o1.md) records the brief aiming freeze,
slow-tick collision and restoration to twenty ticks per second. A visible
crystal beam and authoritative health 200 to 191 to 200 establish a limited
healing observation; the small boss-bar healing delta was not retained.

After those ordinary motion/attack observations, a disclosed one-health
fixture lets an actual arrow establish first-kill completion. The active
exit, egg and XP are visible in `first-exit-egg.png` and
`dragon-staged-kill02.png`, reviewed by the primary. The first death-ray
interval fell between captures; the repeated staged kill below captures it.
This does not establish the fresh survival route's ordinary full-health fight.

Reward accounting includes the exit portal: an intact earlier owner snapshot
holds 8,643 End-orb XP and 3,172 player XP; durable Overworld spawn records
hold another 185 in unique adopted orb records with incoming End receipts.
Their sum is 12,000. Counting only End orbs initially suggested missing XP;
the destination records explain that gap without a storage or reward change.
The visible pre-kill level was zero, but a native XP baseline was not captured.
Later End orbs expire normally while the investigation runs; those later reads
cannot replace the retained earlier snapshot. No source/destination reset or
receipt edit was used.

Evidence under `.local/client-tests/M3-finale/`: `report.md`,
`motion-flight02.png`, `live-dragon-survival-attack.png`,
`dragon-actual-hit-trace.txt`, `first-kill-rewards.txt`,
`first-reward-simultaneous.txt`, `first-reward-durable-spawn.txt` and
`first-reward-durable-orbs.txt`. Actual survival movement into the activated
exit displays the poem/credits; Escape returns to the Overworld spawn with
inventory and displayed level 41 retained. The primary reviewed
`end-credits.png` and `credits-return-spawn.png`. A fresh helper reconnect
retains the active exit and egg; displayed level is then 42 after the
Overworld-spawn orb pickup. `first-kill-fresh-reconnect.png` and
`first-gateway.png` retain the exit and first gateway observations.

Four actual cardinal crystal placements start the respawn sequence at the
normal twenty-tick rate. The arena reaches summoning time 71, then completes
with a new UUID at 200 health and ten spike crystals. The attempted participant
strike arrives after completion, so it establishes no abort result.
`ritual-start-01.png`, `ritual-abort-before.txt` and
`first-ritual-completed.txt` retain this first attempt.

A second disclosed one-health fixture ends through an actual arrow after
resuming normal twenty-tick simulation. `repeat-kill-death.png` captures
clear death rays and explosion particles, reviewed by the primary. The
pre-kill player total is 3,357 XP with no orbs; the retained post-kill
snapshot holds the same player total plus exactly 500 End-orb XP and no
outgoing transfers. Remaining gateway choices decrease from nineteen to
eighteen. `repeat-kill-baseline.txt` and `repeat-kill-reward.txt` retain
that comparison. The original egg was removed with a disclosed host block
edit before the shot, so its presence cannot mask a repeated egg placement.
The exit reactivates; a retained block read finds air at the previous egg
position above the bedrock column. `repeat-exit-no-egg.png` shows the exit
with the column top partly outside the frame; `repeat-egg-absence.txt`
settles that absence.

A fresh set of four actual crystal placements disables the exit, then an
immediate actual strike explodes the participants and reopens it. The
post-action arena remains defeated, with no ritual stage, participants or
new dragon. `abort-ritual-start.png`, `abort-immediate-strike.png` and
`abort-after.txt` retain the graphical actions and state; no stage/counter
edit establishes the result.

A clean owned server restart then retains the next ritual at pillar time
206 with the same four participant UUIDs. A fresh helper join resumes
summoning and completion admits one fresh full-health dragon, clears the
ritual, restores ten ordinary spike crystals and retains eighteen gateway
choices. [VMC-045a8](VMC-045a8.md) records the state/evidence and graphical
limits: ritual beams and protected-crystal rejection still need observation.
Those checks and the ordinary full-health survival fight remain in the
fresh-world VMC-078 route.
