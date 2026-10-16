# VMC-037l — Jump Boost

Status: Native scalar foundation verified; live motion/packet admission remains
unimplemented.

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
