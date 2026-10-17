# VMC-037m — Slow Falling and Levitation travel

Status: Done within scope atd7e6062:179 affected/1,408 full tests, production,
full native integration/both TCP transports and dedicated actual-client acceptance pass.

Acceptance: current effect heads select native dry/fluid gravity and Levitation
travel, reset fall distance at the correct owner boundary and invalidate stale
geometry. Preserve bounded work, collision/flight exclusions, promotion/expiry,
milk and persisted duration/velocity without extra player timers or authorities.

Reference: pinned26.3 LivingEntity.getEffectiveGravity, aiStep pre-travel reset,
travelInAir/travelInWater/travelInLava and existing AirMotion/FluidMotion kernels.
First prove gravity selection and actual pre-travel fall reset with controlled
observations, then composition. A matching scalar kernel is not live support.

Client: actual slow-fall/Levitation drinks change visible descent/ascent, including
rising/falling, dry/wet, collision, safe landing, expiry/milk and fresh reconnect.
Dedicated tester owns an immutable release; negatives still refuse whole. Keep
bytecode/native output/game evidence ignored. Broader travel/gear remains open.

October16: original GravityEffectOracle proves512 no-action/no-attribute hooks,
96 actual getEffectiveGravity selections and24 actual aiStep pre-travel fall
resets. Slow Falling uses min(baseGravity,0.01) only at vertical velocity<=0;
zero/subnormal/negative-base boundaries retain native behavior. Either effect
resets fall distance before travel at any velocity sign. aiStep input/immobility,
status presence and no-gravity flag are controlled; execution stops at the actual
pre-travel passenger lookup. This does not prove world travel, collision or live
ordering. Initial native fixture lacked entity data for the no-gravity flag;
explicit false observation fixed the probe without bypassing gravity selection.

Pure PlayerTravelEffects derives only current heads/presence, selected gravity,
Levitation amplifier and reset intent. Native comparisons and10 affected checks
pass(seed82838), including active-head promotion, unchanged Slow Falling strength,
invalid inputs and existing dry/fluid kernels. No owner/admission calls it yet.
Raw `.local/gravity-effect-{native,elixir,targeted}.log`; native dump/bytecode stay
ignored. Next compose gravity at each native dry/fluid selection point and fence
geometry/fall authority before adding supported drink admission.

Composed native travel proof: AirMotionOracle now uses real effective-gravity
selection and Slow Falling presence, rather than supplying the selected gravity.
25,926 bit-exact dry cases and two200-tick traces pass, with Levitation absent/
0/1/3/255, Slow Falling, friction/drag/gravity and controlled collisions. Six sign
reversals verify air gravity reads post-collision vertical motion. FluidTravelOracle
likewise retains real selection:5,340 water/lava cases and three200-tick traces
match, including12 sign reversals that instead use pre-move vertical motion.
Fluid escape queries and existing acquired-frame bounds still pass. No runtime
admission was added. Raw `.local/travel-effects-{air,fluid}-{native,elixir}.log`.
These controls do not simulate dynamic collisions/worlds or real input; live owner
composition and GUI remain required.

Owned composition admits both effects through existing potion callbacks. Active
Slow Falling presence/Levitation head enter geometry signatures; duration-only
updates do not. The player clock resets fall distance before requesting geometry,
so worker observations and commits share one context. Pure scratch ticks preserve
the same reset intent. Dry gravity reads post-collision body velocity; fluid gravity
reads pre-move velocity. Levitation affects dry vertical travel and adds no fluid
lift; creative flight keeps its existing vertical override. No new owner/timer,
snapshot version or periodic action. Trusted travel reads active heads directly;
it does not rescan every hidden chain on each physics step.

179 affected checks pass(seed in `.local/travel-effects-live-targeted-final.log`):
dry descent/ascent, fluid/flight exclusions, owned fall reset, current-head fencing,
both-hand actual TCP stock/custom drinks, cancellation, remaining-duration fresh
reconnect, promotion/expiry/milk and whole unsupported mixes; previous jumps,
accepted landings, movement, geometry and consumption checks also pass. Native
selection/composition proofs above remain unchanged. Frozen larger integration and
dedicated actual-client descent/ascent/fall acceptance follow. No Done claim yet.

October18: immutable d7e6062 passes1,408 full tests(seed389490), production, both
native TCP transports and full native integration(session75623 exit0). Dedicated
actual26.3 client acceptance passes: main/offhand Slow Falling/cancellation, protected
eight-block descent versus ordinary five-damage fall, Levitation ascent/wall/ceiling,
actual milk, natural promotion/expiry, water no-lift and dry exit, lava with Fire
Resistance/controlled exit, whole unsupported refusal, creative retained dose/flight
and fresh accepted mixed-dose reconnect without replay. II→I occurred under a
ceiling, so no free-ascent rate comparison is claimed; native rates cover that.
Creative flight was a trusted fixture; actual keyboard movement was exercised.

All client wrappers/JVMs and server74332 stopped; eight regions+clock flush:ok,
zero players/connections and1,013 frozen blobs unchanged. Independent stopped-dataset
audit retains survival/flyingfalse, actual12HP, effects{}/pool0/fall_distance0,
one bottle, source61/outboxnil and destination{2,2}receipt61/items{}. No health or
journal rollback. Report reviewed once. Raw report/fixtures, cleanup/final audit and
hashes: `.local/client-tests/VMC-037m/`, `.local/travel-effects-live-cleanup.log`,
`.local/travel-effects-final-audit.log`, `.local/travel-effects-publication-proof.json`.
