# VMC-043c — Farm and passive animals

Status: Awaiting client
Milestone: M3
Depends on: [VMC-041b](VMC-041b.md), [VMC-037n](VMC-037n.md).

Food, leather and wool:

- the animals: cow, mooshroom, pig, sheep (colours, regrowth), chicken (eggs)
  and rabbit;
- what players do with them: breeding and babies, tempting, shearing,
  milking, dyeing and eating, and leads.

Wolves and cats tame later, and riding horses is VMC-046.

Acceptance:

- Breeding, growth and drops match the oracle.
- Animals from chunk generation (VMC-042a) graze and wander as in vanilla.

## VMC-043c1 — animals live (October 23, 2026)

**Animals** (`Valimc.Entity.Animal`, one module per animal under
`Valimc.Entity.Animals`): cow, mooshroom, pig, sheep, chicken and rabbit
are `Valimc.AI.Kind` families; `use Valimc.Entity.Animal` gives each the
shared hooks (data, entity values, a baby's dimensions and voice, the
animal tick, finalizeSpawn) and its module adds its goals and its own.
An animal's `AgeableMob`/`Animal` state is its body's data, saved with it:
age (a baby counts up from -24,000, a parent down from 6,000), forced age,
age lock, love and its cause; plus its own: a cow's, pig's and chicken's
temperature and sound variants, a mooshroom's colour and stew, a sheep's
colour and shearing, a chicken's egg time and jockey flag, a rabbit's type
and carrot hunger. Entity data sends the baby and age-lock flags, variants
by registry id, a sheep's wool byte and the mooshroom and rabbit types. A
baby's dimensions are its own (physics, AI boxes, sensing). Ambient, hurt
and death sounds come from the sound variant (a baby's set where it has
one), at the mob's volume and a baby's higher pitch.

**Tick**: `Animal.customServerAiStep` (love only for adults), then after the
move `AgeableMob.aiStep` and `Animal.aiStep`: ageing, forced-age and
age-lock particle draws, love running out with its hearts' gaussian draws
(`Self.gaussian/1`, `MarsagliaPolarGaussian`, its held value in the mind);
a hurt animal loses its love. A chicken falls slowly and lays when its egg
time runs out (sound, next time, the egg from its laying table below). A sheep grazes
(`EatBlockGoal`): grass under it turns to dirt or the plant it stands in
breaks (a block-rule `Edit` action), its wool grows back and a lamb grows.
A rabbit hops: its `customServerAiStep`, `RabbitMoveControl`,
`RabbitJumpControl`, jump power and push (`MobMotion.hop`, the kernel's
`Hop`), flees players, wolves and monsters and raids grown carrots
(`MoveToBlockGoal`'s spiral search).

**Breeding** (`BreedGoal` → `Animal.breed/2`): the child's data from the
parent's random (either parent's variant; a mooshroom's rare flip; a lamb's
crafted dye mix, else either colour from the level's random; a kit's biome
type one time in twenty), both parents' age and love, the hearts event, an
orb of 1 to 7 while mobs drop loot. The partner's change applies at once to
mobs thinking after the parent (`AI.think` changes other mobs as alerts
do). The owner adds the child (a baby where the parent stood) and the orb.

**Shared goal library**: `EatBlock`, `MoveToBlock`, `ClimbPowderSnow`.
**Fixes in passing**: vanilla's `NoAI` (no travel at all, still its
ambient sound; tests that move mobs alone turn goals off per scope with
`mob_goals: false`), float `0.2F` in voice pitches, `mob_griefing` now
reaches the AI.

Animals reading moving animals (a calf following a walking parent, two
walking partners) read them where they moved this tick, as vanilla does;
see VMC-043c4.

Checks: stage `animal_facts` (`AnimalOracle facts`); stage `animals`
(`AnimalOracle cases`, `scripts/check_animals.exs`): 7,248 ticks of 12
scenes equal vanilla's bit for bit (cow, mooshroom and chicken wandering,
a sheep and a lamb grazing, a rabbit hopping, fleeing and tempted, a cow
breeding with a still partner, a calf following a still parent, a fed
piglet, a cow's love running out): positions, motion, rotations, randoms,
goals, age, love, wool, hops, sounds, entity events, eaten blocks, the calf
and its orb; and 240 breedings of the six animals (children, orbs, parents,
both randoms). `ai_facts`, `entity_facts`, `combat_facts`, `mob_ai`,
`paths`, `mob_travel`, `entity` pass; the touched ExUnit files pass.

## VMC-043c2 — what players get from animals (October 23, 2026)

**Spawning** (`finalizeSpawn` through VMC-043b's `Valimc.AI.Spawn`; the
animals are one family of `Valimc.AI.Mobs`): a cow's, pig's and chicken's
temperature variant by its biome (`selectVariantToSpawn` over the variant
registries' biome-tag selectors) and a random sound variant; a sheep's
colour by its biome's climate (`SheepColorSpawnRules`); a rabbit's type by
its biome; then the shared follow range bonus and handedness.

**Drops**: the animals' death tables (cow, mooshroom, sheep with its wool
sub-tables, rabbit; chicken and pig already), shearing tables and the hen's
laying table join the loot facts; the native evaluator reads an entity's
own properties (`minecraft:components` values such as a sheep's colour or
a hen's variant, `type_specific/sheep`'s shearing), which each animal
module lists (`properties/1`). A hen lays its variant's egg.

**Interactions** (`Valimc.Entity.Animals.Interaction`, the owner's
`interact_entity` call, `Player.Interact`): food makes an adult fall in
love (a pig eats out loud) or ages a baby by a tenth of its time left; a
golden dandelion locks (or unlocks) a baby's age; a bucket milks an adult
cow or mooshroom; a bowl takes a mooshroom's stew (a brown one's suspicious
stew after it ate a flower); shears shear a sheep (its wool launched from
the sheep's random) or turn a mooshroom into a cow (a new entity keeping its
age, name, effects) with its five mushrooms; dye colours a sheep. The
owner applies the animal's change, drops and conversion; the session uses,
fills or wears the held stack, swings when vanilla's server does and plays
the player's own sounds to the others. Saddles and riding are VMC-046's.

Checks: stage `animals` adds 384 spawns (six animals in eight biomes:
variants, sound variants, colours, types, follow range bonus, handedness,
both randoms) and 600 drops (deaths on fire or not, shearing, laying) equal
to vanilla's own `finalizeSpawn` and `LootTable.getRandomItems` with real
animals. `test/animal_test.exs` (each interaction; in an owner: a calf and
orb from two cows in love, shearing's wool and a mooshroom's cow) and
`test/animal_connection_test.exs` (a bucket and wheat through `interact`).

## VMC-043c3 — leads (October 23, 2026)

**On a lead** (`Valimc.AI.Leash`, vanilla's `Leashable.tickLeash` as `Mob`
and `PathfinderMob` implement it, at the end of the base tick): a mob's
`leash` names its holder, a player the AI senses or a fence knot, and its
`home` is the holder's block (radius 5). Beyond 12 blocks between their
boxes' centres the lead breaks (its sound at the holder, the lead an item,
`:move` goals stopped until the next `updateControlFlags`, which the goal
selector now honours); beyond the slack it pulls as a damped spring (force
into the motion, torque into an angular momentum that turns the yaw and
that friction slows); closer, the mob walks toward its holder unless it
panics. A holder gone, dead or a spectator drops the lead (an item while
`entity_drops` is on). A home leans and restricts random walk targets
(`RandomPos`, `GoalUtils.mobRestricted`) and the blocks `MoveToBlock`
searches. The lead and home are saved; a restored lead looks for its holder
(a missing knot is made again) and drops after 100 ticks without one.
Sensed players carry their known movement, which the spring reads.
Observers are linked to the holder (`set_entity_link`, at pairing and when
it changes).

**What players do** (`Valimc.Entity.Leashes`, before the animal's own use):
a lead in hand ties an animal within 12 blocks (from a knot, that lead
drops); its holder unties it (an item unless infinite materials); shears
snip it. Using a fence (`LeadItem.bindPlayerMobs`) moves the player's mobs
around it to the fence's knot, made where none is (`minecraft:leash_knot`,
an entity at the block's corner as vanilla spawns it), and the server
swings the arm; using the knot moves the player's mobs to it, or, not
sneaking, its mobs back to the player; shears snip its leads; a hit breaks
it. A knot with no mob tied goes; every 101 ticks a knot off its fence
goes, with its sound. Only farm animals take leads (`Valimc.AI.Kind`'s
`leashable?/0`); other families add theirs.

**Not yet**: tying a player's mobs to another mob (sneak-use on a
leashable), quad leads (happy ghast), leads across a section border (a
knot or mob in a sibling section), shearing equipment, particles.

Checks: stage `animals` adds four lead scenes (a cow led by a walking
player, a pig led around a square, a lead pulled past 12 blocks, a sheep
tied to a fence knot): 8,868 ticks of 16 scenes equal vanilla's, with
each tick's lead (holder, angular momentum, home, stopped `:move`), the
links sent, the break's sound at the holder and the lead dropped.
`test/animal_test.exs`: tying, untying, snipping, a knot's lead taken, the
lead and home saved, the link packets; in an owner, a fence taking a cow
onto a new knot, the knot giving it back and going, a broken knot's cow
dropping its lead.

Client (pending, for the milestone's batched run): breed two cows with
wheat (hearts, a calf, an orb); shear a sheep (wool drops, it regrows after
grazing), dye one blue; milk a cow with a bucket and a mooshroom with a
bowl; a chicken lays an egg; a rabbit hops away from a player; put a lead on
a cow and walk: it follows and the lead stretches and pulls; use a fence:
the cow is tied to a knot; use the knot to take it back; run off past 12
blocks: the lead breaks with its sound and drops; shears on a leashed sheep
snip the lead.

## VMC-043c4 — animals read moving animals (October 23, 2026)

043c1 recorded a one-tick lag: a section's mobs read each other as the tick
began. VMC-043e2's in-order tick removed it (`MobTicks.steps/4`: each mob
thinks, travels in the section's kernel ticker and pushes before the next
thinks; `AI.resense_entry/3` puts the moved mob in the AI world's overlay,
which `World.entity/2`, `mobs_in/3`, `mob_list/1` and `mobs_of/2` read).
The kernel work stays one ticker resource per section and tick, so nothing
was batched away.

The in-order reads had a quadratic cost: `World.entity/2` found a mob by
scanning the section's list, and `resense_entry/3` calls it for every mob
after it moves. The AI world now indexes its sensed mobs by uuid (`index`,
built in `AI.prepare/2`; a world built without one still scans), and
`mobs_in/3` reads the overlay in its one pass over the candidates instead
of first rebuilding the whole list. `bench/mob_ticks.exs` gained a herd
(`MOB_TYPE=minecraft:cow`, every other one a calf looking for a parent).

The animal scenes now cover it: `calf_follow_walking`
(a wandering parent ticks before its calf, which follows it) and
`cow_breed_walking` (two cows with goals, both in love, walk to each other
and breed at tick 57, then the calf ticks with them). With the overlay
switched off, the calf scene differs at tick 218 (it loses its parent) and
the breeding one at tick 5 (a partner's head), so the scenes catch the lag.
`AnimalOracle cases` no longer avoids animals that read moving animals.

Checks: stage `animals`: 11,948 ticks of 22 scenes equal vanilla's (with
VMC-044a3's cats), with the breedings, spawns and drops. Stages `mob_ai`,
`nether_mobs`, `hostile_ai`, `mob_travel`, `paths`, `hostile_spawns` and
`shulker_bullets` pass; the mob, animal, villager and AI ExUnit files pass
(38 tests). Cost of the in-order tick: see [performance](../performance.md)
(mob travel).

## Handoff (October 2026)

VMC-043c4 is done and on main. Remains: `World.mobs_in/3` still scans every mob of its type in the section
on each search (vanilla reads entity sections), so a herd of 600 with calves
takes about 110 ms a tick. Next step: a spatial index over the sensed mobs
built in `AI.prepare/2`, kept current by `resense_entry/3` and
`World.resense/3`, returning results in the section's order. Gotchas: the
host was loaded throughout (40–60), so only interleaved old/new runs under
`MIX_ENV=bench` compare; `check_vanilla.py --changed` falls back to the
static graph for `lib/valimc/ai/world.ex` and selects nearly every stage, so
the eight stages that run the AI world were run instead.
