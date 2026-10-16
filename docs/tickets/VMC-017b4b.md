# VMC-017b4b — Ordered fire-block contacts

Status: In progress; not live or graphically verified.

Acceptance: fenced retained movement paths produce bounded ordered fire/soul-fire/
lava/water contacts. The player owner applies native step ordering, cooldowns,
ignition, fresh defenses and damage, stopping after death. Fire ignition deduplicates
within a step; per-block damage callbacks remain. No stale/unloaded contact or
unbounded work. Keep live lava/ongoing burning regressions.

Client: walk into ordinary/soul fire, leave burning, extinguish in water, negative
mode/equipment cases and fatal respawn. Fixture setup and graphical actions are
reported separately. Rain and status effects remain parent work.

Pinned26.3 reference: `BaseFireBlock.entityInside/fireIgnite`,
`LavaFluid.entityInside`, `WaterFluid.entityInside`, `InsideBlockEffectApplier`'s
step collector and `Entity.applyEffectsFromBlocks`. Original callback probe:
`scripts/FireContactOracle.java`; raw data stays ignored.

October16 foundation: `PlayerBurning.fire` advances negative cooldowns without
randomness, then uses a1-or2 increment for an exposed server player, signed overflow,
mode setter caps and an eight-second minimum scaled by burning-time. The bounded
`PlayerFireContacts.plan` deduplicates ignition per step, preserves per-contact
hurt requests and orders extinguishing last. Clear-freeze remains separate from
fire immunity. This is data/pure work, not another simulation process.

4,080 actual ServerPlayer/block/fluid collector cases match counters, freeze state,
PRNG calls and ordered damage requests. The native probe binds Entity's level field
as well as its accessor so final `Entity.hurt` reaches the captured hurtServer path.
Nine affected tests pass(seed313771), including work limits and overflow. Logs:
`.local/fire-contact-{native,native-check,targeted}.log`; raw4080 rows remain ignored.
The probe controls isAlive and excludes geometry, health and damage-induced death.

Geometry foundation: `Physics.FireContact.sample_paths` consumes the existing
immutable frame and retained accepted paths; it emits ordered operations, not
health mutations. Shared `BodyPaths` retains101 paths,16 steps per move with native
destination fallback,4,096 candidate attempts and the2,048-cell frame ceiling.
Slowing contacts reuse that traversal. Native metadata covers all35,723 states,
512 ordinary/one soul-fire state,136 static inside-shape exceptions and contextual
powder snow. Fluid hits use strict swept native body/surface contact, including
waterlogged blocks and same-fluid-above heights; candidate overlap alone is not a hit.

1,584 actual native path/contact scenes match counter, freeze, PRNG and ordered
requests.1,680 slowing scenes and3,456 retained-path batches remain exact after
extraction;4,080 callback cases remain exact.27 targeted tests pass(seed206775),
including existing live-lava connections. Logs:
`.local/fire-geometry-{native-final,targeted-final}.log`,
`.local/body-paths-native-regression.log`; generated facts compare exactly with
`priv/physics/inside_blocks.json`. Probe controls health/alive/freeze eligibility,
advancement/debug delivery and powder-snow destruction permissions. It does not
validate damage-induced death, freeze accumulation, melting or cauldron effects.
Powder contact contributes fire extinction; existing freezing ownership remains
separate. This geometry is not yet connected to player authority.

Next: player-owner application, including death gating, admission/clock cadence,
negative-fire contact wakeup and fresh defense refresh, then connection/client checks. Keep this pending
feature local; the pure foundation above is verified and need not be repeated.
