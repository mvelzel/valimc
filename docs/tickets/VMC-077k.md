# VMC-077k — Living rules for any entity

Status: Foundation
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan), [VMC-077d](VMC-077d.md)
(damage types and enchantment effects from data).

Before: health, absorption, damage and its defenses, Resistance, armor,
burning, air, freezing and the status effects were about thirty `Player*` and
effect modules that took a player map and its inventory. The player kept these
values as six loose keys (`health`, `absorption`, `effects`, `fire_ticks`,
`air_supply`, `environment`) read defensively with `Map.get`. Tool and armor
wear each had a copy of `hurtAndBreak` with precomputed Unbreaking tables, and
Fire Resistance immunity used a hand-kept source list.

Scope: the same rules as pure, entity-agnostic modules over one `%Living{}`
struct, so mobs (M3) reuse them. The player holds its living state as one
typed field; food, experience, abilities, input and game mode stay with the
player. No new processes and no behaviour change. Not here: fall damage's
physics inputs (VMC-077l), the `/effect` and `/damage` handlers (VMC-077o),
storage and the player file format (VMC-077f/g).

Acceptance:

- `Valimc.Living` is the struct (health, absorption, effects, fire ticks, air
  supply, freezing) with `restore/1` and `saved/1` (the player file's fields),
  `tick/2`, `die/1`, `respawn/1` and the peer `replica/1`. The rules:
  - `Living.Health`: health, the hurt window and the absorption pool.
  - `Living.Damage`: invulnerability, enchantment and Fire Resistance
    immunity, armor wear, armor and toughness, Resistance, enchantment
    protection, absorption and health, in vanilla's order; below-world damage.
  - `Living.DamageSource`: a damage type with its registry tags, exhaustion and
    death message keys.
  - `Living.Effects`: instances, the effect map and its storage form, the live
    set, and the actions effects request (instant, periodic, Hunger, stock
    food, milk and honey).
  - `Living.Attributes`: movement speed, Jump Boost, travel effects and
    maximum absorption; the one reader of `attributes.json` for these rules.
  - `Living.Armor`: equipment by vanilla slot, armor attributes, enchantments
    per slot, armor wear and freeze-immune wearables.
  - `Living.Air`, `Living.Burning`, `Living.Freezing`.
- `Valimc.Durability.hurt_and_break/4` is the one wear function for tools,
  flint and steel and armor. Unbreaking's removal chance comes from the data
  pack's `item_damage` effect (`Registry.EnchantmentEffects`); it equals the
  two precomputed tables at every level from 1 to 255.
- Fire Resistance immunity asks the `is_fire` tag, which equals the old list.
- Players hold `living: %Living{}`; login restores it and the player file
  writes it unchanged. Peers replicate the living state without the effect map.
- The vitals oracle stages pass unchanged.

Callers other slices use:

- Damage: `Living.Health.hurt_window/3`, then `Valimc.Player.Vitals.apply_damage/4`
  for a player (its wrapper `resolve_damage/6` adds the player-only rules: a
  player who may fly takes no fall damage, a client that has not loaded is
  immune, creative armor does not wear, food pays exhaustion). Mobs call
  `Living.Damage.resolve/5` with their equipment map. `Connection.fall_damage/2`
  is unchanged; Jump Boost's safe fall distance is
  `Living.Attributes.jump_boost/1`.
- Effects: `Connection.live_effects/0`, the `{:effect, id, rung | :remove}`,
  `:clear_effects` and `:kill` command ops and `CommandOps.rung/3` are
  unchanged; `Vitals.apply_effect/3` replaces `Player.StatusEffects.apply/3`.
- Packets: `Packets.attribute/2` (entity id and one derived attribute) replaces
  the movement, absorption and Jump Boost variants; `armor_attributes/2` and
  `armor_break/2` take an entity id, and the latter a slot atom.

Removed (30 files): `PlayerHealth`, `PlayerAbsorption`, `PlayerDamage`,
`PlayerDamageProtection`, `PlayerResistance`, `PlayerArmor`,
`PlayerStatusImmunity`, `PlayerEnchantmentImmunity`, `PlayerVoid`,
`StatusEffect`, `PlayerEffects`, `LiveEffects`, `InstantEffect`,
`PeriodicEffect`, `HungerEffect`, `StockFoodEffects`, `ConsumableRemoval`,
`PlayerAirEffects`, `PlayerJumpBoost`, `PlayerMovementSpeed`,
`PlayerTravelEffects`, `PlayerAir`, `PlayerBurning`, `PlayerFireContacts`,
`PlayerEnvironment`, `ArmorDurability`, `ToolDurability`,
`Physics.ArmorDamage`, `PlayerDeathMessage` and `Player.StatusEffects`. Added
11: `Living` and its nine rule modules, and `Durability`.

One visible difference: a peer's replica now carries the player's air supply,
so an observer who starts tracking a player, or sees its frozen ticks change,
receives the real air value instead of a full bar (air changes already reached
observers directly).

Size: lib 1,711 lines removed and 1,791 added (net +80: the parser of the data
pack's item damage effects replaces two generated tables); scripts +23, tests
+101 (seeds now build `%Living{}`; `TestPlayer.living/1` and `put_living/2`
keep the connection tests' reads short).

Checks: `check_vanilla.py --changed` selected 95 of 211 stages (143 changed
paths); all 95 passed, the vitals, damage, effect, armor, durability, air,
fire and freezing oracles among them. `mix test --stale` on the tree rebased
onto VMC-077o: 706 passed (697 tests, 9 properties), no failures.

Interim client run (VMC-077, release b8646a33): the tester saw no natural
regeneration at food 19 with health at 6–8 hearts. It does not reproduce on
main. A new connection test drives manual ticks from food 19 at timer 0. It
heals at the 80th tick, falls to food 18 on the next one, and heals again 80
ticks later. Each heal reaches the client as `set_health`. Regeneration stops
at food 17, as vanilla's `FoodData.tick` does. Scratch runs found the same
timing in every condition from the run:
- a wall-clock tick with idle or status-only move packets;
- a 10-block fall landed through move packets;
- burning;
- switching creative to survival;
- after a respawn;
- with Speed active.

VMC-077k left the food path unchanged: `PlayerFood` only renamed its health
alias, and `Vitals.advance_food` reads `living.health` instead of `health`.
The most likely reading is a hunger bar at 8.5 (food 17), where vanilla also
stops. A later client run should record the server-side food level.

The same run showed that death messages were missing from the server log.
Vanilla's `broadcastSystemMessage` prints them to the console, so
`Vitals.death_notice/3` now logs the announced message's English text.
The starvation test asserts the log line. `check_vanilla.py --changed` ran
10 of 209 stages and all passed; all 5 food connection tests pass.

Next: a mob equipment model that `Living.Armor` reads directly; entity-agnostic
death messages (they name a player today); the living entity metadata packets
(`Packets.player_health`, `player_environment`, the burning flag) as living
packets keyed by entity id; `status_damage.json` and the Unbreaking tables in
`item_armor_wear.json` are no longer read by `lib` and could leave their
generators; `PlayerInteraction` still decodes `attributes.json` itself.
