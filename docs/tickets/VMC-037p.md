# VMC-037p — Every status effect

Status: Awaiting client
Milestone: M4
Depends on: [VMC-037n](VMC-037n.md), [VMC-043b](VMC-043b.md) (mobs and their
effects), [VMC-085](VMC-085.md) (Saturation, Strength, Weakness).

All 40 of 26.3's status effects work on players and on mobs, as vanilla's
`MobEffect` classes and `LivingEntity`'s effect hooks give them, checked
against the oracle.

The work comes in three slices:

| Slice | Scope |
|---|---|
| 037p1 | Effect facts, the gate, attributes and immunities |
| 037p2 | Invisibility, glowing, effect particles and the omens |
| 037p3 | Death and hurt effects: wind charged, weaving, oozing, infested |

Hand-offs to other lanes:
- Hero of the Village's discounts and gifts go to 044b and 044e.
- Bad Omen turning into Raid Omen in a village, and Raid Omen starting a
  raid, go to 044e.
- Trial Omen turning trial spawners ominous waits for trial spawners, which
  no M4 lane owns yet.

Each of these effects is still live here: it is stored, ticked and sent,
with its particles and its sound on being added.

## Facts

- **`EffectMetadata`** (`priv/protocol/effect_facts.json`, stage
  `effect_metadata`) gives each effect's:
  - category and colour;
  - whether it is instantaneous;
  - its particle (`entity_effect`, tinted by the colour, or its own);
  - its blend durations;
  - its sound on being added.
- **`HostileOracle facts`** already gives each effect's attribute modifiers
  (`effect_modifiers`). It now also gives `effect_immunities`: the effects
  each living type refuses (`canBeAffected`). That covers the tags
  `ignores_poison_and_regen`, `immune_to_infested` and `immune_to_oozing`,
  and the spider, nautilus, wither, wither skeleton and parched overrides.
- **`inverted_healing_and_harm`** comes from `tags.json`.

## 037p1 — The gate, attributes and immunities

Acceptance:
- Every effect passes `/effect`, drinking and login; `/effect give` takes
  mobs as targets.
- Haste and Conduit Power speed up mining, and Mining Fatigue slows it,
  bit for bit as `Player.getDestroySpeed`. Checked by the `player_mining`
  stage's effect cases.
- Health Boost raises a player's maximum health. The attribute is sent, the
  maximum survives a rejoin, and removing the effect clamps health. Luck and
  Bad Luck set `minecraft:luck`, which is replicated and feeds the luck of
  chest loot opened and mobs killed by that player.
- A mob's effects carry their attribute modifiers from the generated table
  on add, refresh, promotion and removal (expiry and milk), whatever adds
  them: potions, clouds, drinks, spawn effects, gifts or play-dead.
- A mob refuses what its type is immune to, on every path.
- Undead heal from Instant Damage and are hurt by Instant Health: drinks,
  splashes, clouds and the timed form all invert.
- Absorption fills a mob's pool when it starts.
- Effects that a mob's hit adds (wither skeletons, cave spiders) and tipped
  arrows reach mob targets as well as players.

## 037p2 — Visibility and the omens

Acceptance:
- Invisibility and Glowing set the shared flags (0x20, 0x40) of players and
  mobs.
- The effect particles and ambience entity data
  (`updateSynchronizedMobEffectParticles`) are sent for players and mobs, so
  others see the swirls. Ambient effects send the faint colour; hidden
  particles send nothing.
- A mob targeting an invisible mob sees it at `0.7 ×` its armour cover,
  as it already sees an invisible player.
- Effects with a sound on being added (Bad Omen, Trial Omen, Raid Omen) play
  it.

## 037p3 — Death and hurt effects

Acceptance:
- **Wind Charged:** a killed entity bursts as a wind charge does
  (strength `3 + 2r`, knockback, no damage, triggers blocks).
- **Weaving:** a killed entity spreads 2–3 cobwebs on sturdy floors within
  a block's reach. Mobs need `mob_griefing`; players always do it.
  A weaving entity moves through cobwebs at `(0.5, 0.25, 0.5)`.
- **Oozing:** a killed entity drops two size-2 slimes, capped by
  `max_entity_cramming` and the slimes already nearby.
- **Infested:** each hit has a 10% chance to release one or two silverfish
  along the entity's look.
- These work on players and on mobs, and draws and counts match the oracle.

## Results

### 037p1

- **The gate is gone.** `Effects.live/0` and the login refusal of unknown
  saved effects are removed. `/effect give` and `/effect clear` take mobs
  (`Region.effect_entities/3`, the section's `mob_section_effect` `add`,
  `remove` and `clear`).
- **Mobs.** One `living::mob::add_effect` serves every path: the NIF, drinks,
  spawn effects, witches, gifts and play-dead. It does the following:
  - refuses the generated immunities;
  - merges the effect in;
  - refreshes its modifiers from `effect_modifiers`;
  - fills Absorption's pool.

  On the tick, a promoted or ended effect refreshes its modifiers, and an
  empty pool ends Absorption. Health Boost's maximum follows `max_health`;
  lowering it clamps health. A lower maximum absorption clamps the pool.
  Timed Instant Health and Damage act each tick and invert for
  `inverted_healing_and_harm`. The dragon still refuses everything (its own
  `addEffect`).
- **Hit effects.** A hit's `effect` (tipped arrows, a wither skeleton's
  wither, a cave spider's poison) reaches mobs through `Hit.effect`, even on
  a killing hit.
- **Players.**
  - Haste and Conduit Power join `MiningSpeed`.
  - Health Boost sets `health.maximum` and sends `max_health`. The maximum is
    restored with the effects; a removal clamps health, and a respawn starts
    at 20.
  - Luck and Bad Luck send `luck` and feed chest unpacking (the opener's
    grant) and kill loot (the killing player's `Attacker.luck`, as
    `Death.luck`).
- **Oracles.**
  - `mob_effects` (`HostileOracle effects`, `mob_effect_parity`): 12 vanilla
    scripts on fresh zombies, skeletons, cows, spiders, cave spiders, wither
    skeletons, silverfish and slimes. They cover refusals, refresh, promotion
    and expiry with movement speed, the Health Boost and Absorption clamps, and
    undead instant effects. They equal ours after every operation.
  - `player_mining`'s effect rows equal `getDestroySpeed` bit for bit.
  - `effect_metadata` and `hostile_facts` regenerate equal.

### 037p2

- **Flags.** The shared flags carry Invisibility (0x20) and Glowing (0x40)
  for players (`Player.Packets.shared_flags/1`) and native mobs
  (`living::body::values`).
- **Particles.** `Living.Effects.particles/1` and its native twin give
  `effect_particles` and `effect_ambience`. A tinted `entity_effect` is the
  effect's colour at alpha 255, or 38 when ambient; the omens, Wind Charged,
  Weaving, Oozing and Infested show their own particles; hidden effects
  show none. Players send them to observers (the tracker) and to themselves;
  mobs send them with their entity data. The `entity` stage checks the
  encoding against vanilla's packets.
- **Targeting.** A mob targeting an invisible mob sees it at `0.7 ×` its
  armour cover (`sensing::visibility`).
- **Sounds.** The omens play their sound when first added, from the player
  or the mob (`EffectFacts`' sound ids).

### 037p3

- **Rules.** `living::removal` holds the death and hurt rules, drawn from
  the entity's own random.
- **Mobs.** A dead native mob's removal (after its death's 20 ticks) and an
  exploded creeper (`explodeCreeper` goes as killed) run them through
  `mob_section_removed`. The owner then:
  - bursts Wind Charged (`Explosion.wind/2`: no damage, a plain push, the
    gust particles and the breeze's sound);
  - weaves cobwebs on the first replaceable cells over a sturdy floor, only
    with `mob_griefing` (with level event 3018);
  - oozes size-2 slimes (`mob_section_fresh_sized`, capped by
    `max_entity_cramming` and the slimes near it).

  Infested queues silverfish on the mob, which leave with the section's next
  step, moving along its look and crying out.
- **Players.** A player's death animation ends with the same effects
  (`effect_removal`, Weaving whatever the rules), sent to its owner, and an
  Infested player's hurts release silverfish (`effect_infested`).
- **Movement.** Weaving's `(0.5, 0.25, 0.5)` cobweb motion is on for
  players and mobs.
- **Oracles.** `effect_removal` (`HostileOracle removal`) checks Weaving's
  count and 15 cells and Wind Charged's strength over 200 seeds, and
  Infested's silverfish motion over 800 hurts, 92 of them releasing (JOML's
  `rotateY` in floats). The region test "a killed zombie under Weaving and
  Oozing leaves cobwebs and two slimes" runs the owner's side.
- **Digests.** `mob_kernel_parity`'s digests were renewed: `Ticked` prints
  the kernel mob, which gained `weaving`. Its traces are otherwise identical
  to main's.

## Left for later

- Wind Charged's burst does not trigger blocks (doors, buttons, bells);
  that comes with wind charges.
- The cobweb and silverfish level-random draws (a slime's or silverfish's
  facing) use the owner's random.
- A boosted mob's saved health is restored up to its type's maximum.

## Awaiting client

In M4's batched run:
- **Health Boost** gives extra hearts that stay through a rejoin and go,
  clamping health, when it ends.
- **Glowing** outlines the player and a mob for other players.
  **Invisibility** hides them, and mobs lose track of an invisible zombie.
- **Swirls:** effect particles show around other players and mobs (faint
  from a beacon or `/effect … true`); Wind Charged, Weaving, Oozing and
  Infested show their own.
- **Omens:** Bad Omen, Trial Omen and Raid Omen play their sound.
- **Death effects:** a Weaving zombie's death leaves cobwebs, an Oozing
  one's two slimes, and a Wind Charged one's a gust that pushes the player.
- **Infested:** a hit on an Infested player or zombie sometimes releases
  silverfish.
- **Haste** mines faster, and the client's mining matches the server's.
