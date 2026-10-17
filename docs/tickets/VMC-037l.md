# VMC-037l — Jump Boost

Status: Done within scope at06c64d2:139 affected checks, native power/jump/fall/packets,
production/both TCP transports and actual-client acceptance pass. Larger d7e6062
integration passes1,408 full tests, production and full native integration/both TCP.

Acceptance: stock/custom Jump Boost drinks change owned ground-jump power and safe
fall distance with native arithmetic, including material factors, hidden promotion,
expiry/milk and reconnect. Geometry preparation/fencing must include changed jump
power; never admit an effect that the server then simulates as an ordinary jump.
Use the existing player owner and bounded geometry lane, with no extra tick process.

Reference: pinned26.3 LivingEntity.getJumpPower/getJumpBoostPower/jumpFromGround,
MobEffects.JUMP_BOOST attribute creation, Player default attributes and actual
calculateFallDamage. First compare native power/attribute/fall boundaries against
original Elixir kernels; client packets and runtime composition follow separately.

Client: actual Leaping drinks, repeated ordinary/boosted jumps, low ceilings and
material factors, safer accepted landing, hidden promotion/expiry/milk, creative
flight exclusions and fresh reconnect. Dedicated tester owns a frozen release.
Native scalar proof alone cannot mark this ticket Done. Keep reference bytecode,
raw observations and test worlds ignored.

October16: original `JumpBoostOracle` executes257 native attribute/add/removal
contexts,1,285 actual getJumpPower material contexts and10,280 actual fall damage
calculations across all256 amplifiers plus absent effect. Default jump strength
is native float0.41999998688697815. Bonus is float0.1*(amp+1), added after the block
factor; even factor0 retains the bonus. Safe-fall attribute29 adds amp+1 to base3
under identity minecraft:effect.jump_boost, operation ADD_VALUE. Removal restores3.

`PlayerJumpBoost` derives those facts from the active owned head only, without
extra state or timers. Native comparisons and five affected checks pass(seed863097),
including hidden promotion, float rounding, high amplifier and invalid inputs.
This is not live Jump Boost yet: packet/ground-jump preparation, geometry fencing,
fall authority and graphical validation follow. Raw `.local/jump-boost-{native,elixir,targeted}.log`;
reference bytecode/jar and raw observations remain ignored.

Owned composition admits Jump Boost7 on the existing potion/effect path. Packet
ground jumps and their query hull include the active bonus; amplifier changes
fence prepared geometry, duration-only changes do not. Accepted landings derive
the current safe distance before armor/health processing. Cached self attributes
update only on active amplifier changes, including login, milk, promotion, expiry
and Respawn. No new simulation owner or clock; existing frame/admission caps stay.

Native EntityOracle adds257 safe-fall packets; complete Elixir/native byte and
decode checks pass597 packets/272 velocities. Native PlayerKineticsOracle now runs
the actual Jump Boost callback in1,320 complete jump/sprint/yaw/material cases;
all bit-exact outputs match, retaining24 air branches/245 dead zones/480 support
cases.139 affected checks pass(seed909864), including both-hand actual TCP Leaping,
cancellation, attribute/init/reconnect/milk, genuine hidden promotion/expiry,
boosted query bounds and accepted eight-block falls at amps0/1/255 (4/3/0 damage),
removal before landing restoring5. Other movement/collision/consumption checks pass.
Raw `.local/jump-boost-{live-targeted-fixed,kinetics-native,kinetics-elixir,entity-native,entity-elixir,entity-decode}.log`.
Actual-client jump/landing acceptance and frozen production/TCP follow; no Done claim.

Actual26.3 client PASS on immutable06c64d2; primary reviewed the dedicated report
once. Actual cancellation/main/offhand stock drinks, jumps and walking pass;
read-only samples corroborate floor64 peaks65.252203 ordinary/65.836132 I/
66.516794 II. Actual walk-off eight-block falls on verified grass spend4HP withI,
then5 unbuffed after milk, then3 withII:20→16→11→8. Only the initial actual healing
drink restored inherited1HP; no health fixtures or healing masked falls. Actual
low ceiling clips head at64.2, genuine II→I promotion restores weaker jump, natural
expiry/milk restore ordinary behavior, mixed actual NightVision15 refuses whole.
Creative retains the stock dose; actual movement under a trusted flying fixture
stays controlled (the failed double-Space attempt is not flight-toggle evidence).
Fresh direct reconnect retains bottle/head3402→3285 and boosted jump; actual milk
then restores ordinary height. Honey-specific and separate sprint trials were not
run; native material/sprint probes and actual low-ceiling contact bound the scope.

Both wrappers/JVMs and server69734 stopped; four regions+clock flush:ok, zero
connections/players and1,008 frozen blobs unchanged. Whole final dataset
`/tmp/valimc-jump-boost-live-client-20261016`: survival/flyingfalse,8HP, effects{}/
pool0, bottle36/bucket37, food11/saturation0.2/exhaustion2.09999871254, source61/
outboxnil and destination{2,2}receipt61/items{}. Receipt history remains. Raw report, cleanup and hashes:
`.local/client-tests/VMC-037l/report.md`, `.local/jump-boost-live-cleanup.log`,
`.local/jump-boost-publication-proof.json`. Larger native session75623 exited0
(completion collected October18). All Jump Boost gates pass.
