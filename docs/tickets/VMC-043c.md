# VMC-043c — Farm and passive animals

Status: In progress
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

**Not exact by design**: ValiMC's AI reads every mob of a section as the tick
began (one kernel call per section), where vanilla's later mob reads earlier
ones after they moved; animals reading moving animals (a calf following a
walking parent, two walking partners) can differ by that tick. A
sequential-tick kernel session is the fix (follow-up).

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
