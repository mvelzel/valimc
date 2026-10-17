# VMC-037j — Owned Absorption

Status: Done within scope; runtime958c8ee validated/published throughb97c5ca.
128 affected checks,1,368 full tests, production/full native integration/both TCP
transports and all five actual-client groups pass.

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

Owned composition uses the existing player state/clock and consumption checkpoint.
Native start hooks run for every accepted incoming dose, even unchanged refreshes;
milk/removal and hidden promotion clamp without refill. Damage spends the pool
after existing armor/Resistance/Protection, exhausting food only for residual red
damage. Depletion ends hidden/infinite heads; admitted status requests spend the
pre-expiry pool before final duration/max clamping. Login restores/clamps the saved
amount without starting a dose; Respawn resets it. Cached maximum/pool changes
replicate to self/nearby peers and fresh tracking. No extra owner/timer or global
gameplay lane; unchanged durations do not emit attribute/heart packets.

128 affected checks pass(seed812851), including both-hand golden-heart TCP data,
spent reconnect/no replay, mixed Absorption/harming order, unchanged weak refill,
milk/expiry/promotion/depletion, creative immunity, fully absorbed campfire food
cost and whole negative-healing refusal. Existing periodic/health/food/death/drop/
store/codec checks pass. Initial integration exposed an old219-byte snapshot
expectation (v19 adds5) and an assertion that ETS must retain one exact stale
effect head; newer observations are legitimate, while owner/save durations remain
exact. Both expectations were corrected before the passing run. Raw:
`.local/absorption-live-targeted-final.log`. Frozen production/client gate follows.

Frozen958c8ee production and both native TCP transports pass. Initial larger suite
passes1,364/1,368: three old fixtures expected pre-v19 bytes, and the initial-stream
test compared a per-second rate counter across its rollover. Current fixtures
include the zero pool; migration asserts v19. The stream test now observes the
counter's window too, preserving its no-chunks-before-ack assertion. All12 affected
checks pass(seed825783); full suite rerun follows. These are test-only corrections;
the immutable production runtime under graphical verification stays unchanged.
Raw `.local/absorption-live-{production,native-tcp,full-tests}.log`,
`.local/absorption-full-integration-fixes-targeted.log`.

Full rerun at test-only checkpointb97c5ca passes1,368 tests; runtime/config/data
files are identical to the immutable958c8ee release. Raw
`.local/absorption-live-full-tests-fixed.log`. New stock-food research is outside
that full run. Production/TCP remain at958c8ee; graphical verification continues.

Actual26.3 client PASS on immutable958c8ee; primary reviewed the dedicated tester's
report once. Cancelled use leaves no pool; actual amp1 grants8, actual harming
spends6 leaving2 without red damage, and fresh direct reconnect retains2 without
refill/replay. Actual one-block falls spend1; milk removes pool/icon. Genuine
strong→weak promotion clamps7→4 and preserves a spent2 without refill; natural
expiry clears it. An actual incoming weaker dose refills2→4 while stronger stays.
Creative retains the dose and ignores falling; mixed actual NightVision15 refuses
whole. An isolated fatal drink spends golden hearts before actual death/Respawn,
leaving20HP, zero pool/effects and empty inventory. No health fixtures masked damage.

Both clients/JVMs and server63175 stopped; eight regions+clock flush:ok and zero
connections/players.994 frozen blobs remain unchanged. Whole dataset
`/tmp/valimc-absorption-live-client-20261016` retains source61/outboxnil, destination
{2,2} receipt61 and exactly one unpicked count1 glass bottle from the fatal dose.
Independent stopped-dataset decode verifies player/receipt/item and no pending
transfer. First offline interval lacked a byte comparison; actual fresh reconnect
proves spent-pool retention, and final offline hashes are stable. Private report,
cleanup, audit and hashes: `.local/client-tests/VMC-037j/report.md`,
`.local/absorption-{live-cleanup,final-audit}.log`,
`.local/absorption-publication-proof.json`. Larger native integration session17839
runs against958c8ee; do not repeat the passed client gate.

Final frozen958c8ee full native integration exits0 on October16, including actual
plaintext and continuous AES-CFB8 TCP. Published prefixb97c5ca includes only
test-fixture corrections after that runtime; no remaining gate for this scope.
Private final log/hash is bound in the publication proof.
