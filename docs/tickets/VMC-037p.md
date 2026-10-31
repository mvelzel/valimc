# VMC-037p — Every status effect

Status: In progress
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

- `player_mining` covers Haste, Conduit Power and Mining Fatigue: 144 effect
  rows, 16 contexts each.

## Awaiting client

To be filled as slices land.
