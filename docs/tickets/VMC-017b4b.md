# VMC-017b4b — Ordered fire-block contacts

Status: Done
Note: **Done within ordered natural-fire contact scope**, October 16,2026. Accepted runtime `f0aa671`; rain/effects remain parent follow-ups.

Acceptance: fenced retained movement paths produce bounded ordered fire/soul-fire/
lava/water contacts. The player owner applies native step ordering, cooldowns,
ignition, fresh defenses and damage, stopping after death. Fire ignition deduplicates
within a step; per-block damage callbacks remain. No stale/unloaded contact or
unbounded work. Keep live lava/ongoing burning regressions.

Client: walk into ordinary/soul fire, leave burning, extinguish in water, negative
mode/equipment cases and fatal respawn. Fixture setup and graphical actions are
reported separately. Rain and status effects remain parent work.

Pinned 26.3 reference: `BaseFireBlock.entityInside/fireIgnite`,
`LavaFluid.entityInside`, `WaterFluid.entityInside`, `InsideBlockEffectApplier`'s
step collector and `Entity.applyEffectsFromBlocks`. Original callback probe:
`scripts/FireContactOracle.java`; raw data stays ignored.

October 16 foundation: `PlayerBurning.fire` advances negative cooldowns without
randomness, then uses a1-or2 increment for an exposed server player, signed overflow,
mode setter caps and an eight-second minimum scaled by burning-time. The bounded
`PlayerFireContacts.plan` deduplicates ignition per step, preserves per-contact
hurt requests and orders extinguishing last. Clear-freeze remains separate from
fire immunity. This is data/pure work, not another simulation process.

4,080 actual ServerPlayer/block/fluid collector cases match counters, freeze state,
PRNG calls and ordered damage requests. The native probe binds Entity's level field
as well as its accessor so final `Entity.hurt` reaches the captured hurtServer path.
Nine affected tests pass(seed313771), including work limits and overflow. Logs:
`.local/fire-contact-{native,native-check,targeted}.log`; raw 4080 rows remain ignored.
The probe controls isAlive and excludes geometry, health and damage-induced death.

Geometry foundation: `Physics.FireContact.sample_paths` consumes the existing
immutable frame and retained accepted paths; it emits ordered operations, not
health mutations. Shared `BodyPaths` retains 101 paths,16 steps per move with native
destination fallback,4,096 candidate attempts and a2,048-cell prepared-frame ceiling;
live query admission retains its smaller 1,024-cell limit.
Slowing contacts reuse that traversal. Native metadata covers all 35,723 states,
512 ordinary/one soul-fire state,136 static inside-shape exceptions and contextual
powder snow. Fluid hits use strict swept native body/surface contact, including
waterlogged blocks and same-fluid-above heights; candidate overlap alone is not a hit.

1,584 actual native path/contact scenes match counter, freeze, PRNG and ordered
requests.1,680 slowing scenes and 3,456 retained-path batches remain exact after
extraction;4,080 callback cases remain exact.27 targeted tests pass(seed206775),
including existing live-lava connections. Logs:
`.local/fire-geometry-{native-final,targeted-final}.log`,
`.local/body-paths-native-regression.log`; generated facts compare exactly with
`priv/physics/inside_blocks.json`. Probe controls health/alive/freeze eligibility,
advancement/debug delivery and powder-snow destruction permissions. It does not
validate damage-induced death, freeze accumulation, melting or cauldron effects.
Powder contact contributes fire extinction; existing freezing ownership remains
separate. The following owner composition consumes this verified geometry.

Owner composition: the existing geometry worker samples
accepted history, excluding forecast travel. Only an admitted owner tick consumes
its plan; negative fire contact keeps pose sampling active. Damage uses current
armor/attributes per operation, and death stops remaining operations. Body queries
enclose above-fluid dependencies along old paths. No additional process/timer.

The 101-test affected pass found three fixture expectations: the first incomplete
frame now fails in fire sampling, repeated move packets require client_tick_end,
and item observations expose encoded metadata rather than a raw stack. Those are
corrected;33 fire/kinetics tests pass(seed277343), other 68 had passed unchanged.
New real-TCP cases cover stationary negative ignition, non-admitted moves, a crossed
fire with dry endpoint, first-callback death, exactly one worn death stack and respawn.
Evidence: `.local/fire-live-contacts-{affected-final,owner-final}.log`.

October 16 dedicated client **PASS**, frozen `f0aa671`: five fresh direct clients
exercise actual ordinary/soul-fire entry, sustained and dry-exit burning, armor
wear/break and HUD, single/stacked Fire Protection, water extinction, fresh burning
reconnect, fatal soul fire/respawn, creative/spectator negatives and lava regression.
Trusted setup supplied gear/modes and extended a naturally ignited counter for
reconnect; one duration fixture increased max health. Numerical counters/readbacks
complement graphical actions. The first water attempt stopped short and was not
counted; the repeated crossing passed. No gameplay failure was found. All clients
stopped, full snapshot restored retaining sequence 36/outboxnil and matching receipt;
regions/clock flushed. Report reviewed:
`.local/client-tests/VMC-017b4b/report.md`; server log has no errors/warnings.
Rain/effects, melting/cauldrons, freezing accumulation and extreme-speed sweeps are
not claimed by this client gate. Automated TCP covers the exactly-one worn fatal
drop; that count is not a graphical claim.

Complete block:1,219 full tests(seed263476), production and full native integration
including plaintext/continuous AES-CFB8 TCP pass; native harness terminated 0.
Logs: `.local/fire-contact-live-{full-tests,production,full-native}.log`.

Matched static-water preview loads compare frozen `7b5b382` against `f0aa671`,
identical driver hashes, view 1/10sched,128 dense and 512 spread players,100 legal
moves/client. All six samples have zero disconnects/corrections and verified final
positions/swimming. Dense:6.103→5.304s,136.18→136.83MiB. Spread first/reverse-order
repeat:5.160/5.156→5.171/5.158s;317.18/314.11→316.24/337.86MiB.
Spread login p95 varies 80.91/227.99→224.98/250.93ms; retain that latency/allocation
finding for profiling. These short shared-water workloads do not measure natural
fire capacity, survival or establish a speed win. Raw samples, manifests/revisions
and repeated-pair rationale: `.local/fire-contact-loads/`.

Publication proof rehashes all 859 frozen blobs; tested code matches the accepted
prefix. `.local/fire-contact-publication-proof.json`. This slice is complete;
continue rain/status effects without reopening accepted fire/lava foundations.
