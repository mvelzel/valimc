# VMC-037j — Owned Absorption

Status: Native attribute/effect foundation verified; live Absorption unsupported.
Damage spending, durable pool and metadata/owner composition follow.

Acceptance: native golden-heart pool and maximum, effect add/upgrade/promotion/
removal, damage spending after defenses, immunity/source exclusions, persistence
and self/peer metadata on the existing player owner. No second health authority.
Preserve atomic consumption/death checkpoints and no refill on reconnect.

First prove actual native Absorption callbacks and setters over all amplifiers,
existing pools and maximum clamps. Then prove damage/food interactions and native
removal/hidden promotion before admission. Pure request math alone is insufficient.

Client: actual custom Absorption drink displays golden hearts, subsequent actual
fall/contact spends them before red health, milk/expiry removes the permitted pool,
upgrades/hidden promotion follow native behavior and fresh reconnect retains the
spent amount without refill. Include creative/unsupported mixed negatives and
ordinary health/death regressions. Delegate graphical verification after a frozen
production release; native probes cannot replace it.

Reference: pinned26.3 AbsorptionMobEffect, LivingEntity absorption/attributes/
damage hooks, Player absorption metadata and FoodData, MobEffectInstance updates.
Golden-apple chance/listener delivery remains a separate consumable slice. Keep
all native jars, bytecode, captures and worlds ignored.

October16: original `AbsorptionOracle` matches6,912 native setter/start/attribute
removal contexts,240 actual LivingEntity.addEffect refreshes,80 actual instance
ticks, four hidden promotions and48 actual effect removals. All256 amplifiers,
fractional/negative/large pools and added base maximum boundaries are covered.
Default player maximum is0; the active dose adds4×(amplifier+1), attribute ID22/
modifier `minecraft:effect.absorption` ADD_VALUE, capped2048. Player golden-heart
metadata is native index17. The actual native Player setter uses synchronized data.

Every accepted add calls the incoming dose's start hook, even an unchanged/weak
refresh; it can refill a spent pool up to that dose and the active maximum.
Depletion ends even an infinite head before duration decrement/hidden promotion.
Ordinary hidden promotion clamps to the weaker maximum without refilling; actual
removal clamps to the remaining base maximum. Promotion uses the real instance
with a controlled native attribute-update callback; full world ticks are excluded.
`PlayerAbsorption` supplies pure derived attributes, clamp/start and instance-tick
hooks only. Ten affected checks pass(seed351414), including depleted hidden chains,
unchanged refill, high-amplifier bounds and malformed state. No live admission or
damage behavior is established yet. Raw ignored:
`.local/absorption-{native,elixir,targeted}-final.*`; pinned bytecode
`.local/absorption-{AbsorptionMobEffect,LivingEntity,Player,MobEffect}.javap`.

Damage foundation: `AbsorptionDamageOracle` executes40,392 actual Player
actuallyHurt transitions over all51 native source kinds, three starting healths,
six pools,11 amounts (including subnormal/large values) and four controlled
armor→magic factor pairs. Golden hearts spend after both phases; only residual
red-health damage triggers food exhaustion and the damage event. Real FoodData,
health and absorption setters run; armor formulas and combat/stat storage endpoints
are controlled, so this is not a full gear/outer-hurt/death proof. Elixir's spend
kernel matches every pool/residual/health/food result. Keep the native float
subtractions: at sufficiently large damage, rounding can leave a small pool
unchanged, unlike min(pool,damage). Fourteen affected checks pass(seed829282).
Raw `.local/absorption-damage-{native,elixir,targeted}.*`.

Durable-pool foundation: optional snapshot v19 stores one canonical float0..2048
with the existing checksum, effect map and unchanged transfer request/outbox.
All earlier formats remain readable without inventing a refill. Capture is
explicit; malformed/noncanonical/negative/oversize pools, nested/truncated wrappers,
wrong identity and trailing bytes are refused.35 affected snapshot/store/kernel
checks pass(seed171688), including pending death-drop history and byte-stable
roundtrips. Raw `.local/absorption-snapshot-targeted.log`. Live restoration and
graphical golden hearts remain unimplemented at this foundation checkpoint.

Wire foundation: regenerated native entity facts add only player Absorption17/
float serializer3. EntityOracle now supplies12 golden-heart/combined-health
metadata packets and257 maximum-attribute packets (no effect plus all256 amps).
Elixir independently matches complete bytes and native decoding, alongside
existing fixtures:340 packets/272 velocities total. Fourteen affected checks
pass(seed588468), including metadata bounds; no new live emission yet. Raw:
`.local/absorption-entities.log`, `.local/absorption-entity-{native,elixir,decode}.log`,
`.local/absorption-packet-targeted.log`.
