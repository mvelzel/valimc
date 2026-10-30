# Melee parity (VMC-037n): ValiMC's attack and hurt rules on every
# `CombatOracle cases` case equal vanilla's. A player's attack on a zombie
# (`Living.Melee`, `Entity.Combat.hurt/3`, `Player.Attack.effects/3`): the
# target's and the swept zombie's health and motion, the attack's sounds,
# particles and critical hit animations, and the weapon's wear. A zombie's
# hit on a player (`Entity.Combat.mob_hit/3`, `Player.Hurt.plan/2`,
# `Vitals.resolve_damage/5`): the player's health and motion, its armor's and
# shield's wear, and its sounds.
alias Valimc.Data.{EntityTypes, Float32}
alias Valimc.Entity.{Body, Combat, Store}
alias Valimc.Living.{Armor, Attributes, Health, Melee, Weapons}
alias Valimc.Menus.Inventory
alias Valimc.Player.{Attack, Hurt, Vitals}
alias Valimc.Protocol.{EnchantmentEffects, ItemStack, ItemTypes}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

defmodule CheckCombat do
  def stack(nil), do: nil

  def stack(json),
    do: %ItemStack{
      item_id: ItemTypes.id(json["item"]),
      count: 1,
      components:
        if(json["enchantments"] == %{},
          do: %{},
          else: %{"minecraft:enchantments" => json["enchantments"]}
        )
    }

  def attribute(stack, name) do
    modifiers = for {^name, id, a, op} <- Weapons.modifiers(stack, :mainhand), do: {id, a, op}
    Attributes.value(name, Weapons.player_base(name), modifiers)
  end

  # A store of region {0, 0} whose mobs live in its native section.
  def store, do: %{Store.new() | native: Valimc.Entity.NativeMobs.new({0, 0})}

  # The health of mob `id`, from its section.
  def health(store, id) do
    {value, _, _, _, _, _} = Valimc.Native.mob_section_oracle_health(store.native.ref, id)
    value
  end

  # A zombie of 100 health at `position`, wearing `equipment`, in the store's
  # native section. The cases are around the origin; here they are 64
  # blocks into region {0, 0}.
  def zombie(store, uuid, [x, y, z], ground, yaw, equipment) do
    {x, z} = {x + 64.0, z + 64.0}
    {:ok, body} = Body.new("minecraft:zombie")
    {:ok, health} = Health.restore(nil, 100.0)

    mob = %{
      body.mob
      | living: %{body.mob.living | health: health},
        attributes: %{"minecraft:max_health" => %{base: 100.0, modifiers: []}},
        equipment: equipment
    }

    body = %{body | mob: mob, on_ground: ground, yaw: yaw}

    {:ok, store, {_, id, _}} =
      Store.create_record(store, {0, 0}, Store.body_record(body, uuid, {x, y, z}))

    {store, id}
  end

  def close?({a, b, c}, [x, y, z]),
    do: abs(a - x) < 1.0e-9 and abs(b - y) < 1.0e-9 and abs(c - z) < 1.0e-9

  def worn(nil), do: 0
  def worn(%ItemStack{components: c}), do: Map.get(c, "minecraft:damage", 0)
end

zombie = EntityTypes.id("minecraft:zombie")
player = EntityTypes.id("minecraft:player")

attack_failures =
  for row <- cases["attacks"],
      weapon = CheckCombat.stack(row["weapon"]),
      enchantments = (weapon && weapon.components["minecraft:enchantments"]) || %{},
      state = row["state"],
      ground = state != 1,
      sprint = state == 2,
      known = if(state == 3, do: {0.3, 0.0, 0.1}, else: {0.05, 0.0, -0.02}),
      speed = CheckCombat.attribute(weapon, "minecraft:attack_speed"),
      damage = CheckCombat.attribute(weapon, "minecraft:attack_damage"),
      strength = Melee.strength(row["ticker"], speed),
      {:ok, movement} = Attributes.movement_speed(%{}, sprint),
      reduce: [] do
    failures ->
      chest =
        case row["armor"] do
          0 -> %{}
          1 -> %{chest: ItemStack.new("iron_chestplate")}
          2 -> %{chest: ItemStack.new("netherite_chestplate")}
        end

      {store, target} =
        CheckCombat.zombie(
          CheckCombat.store(),
          <<1::128>>,
          row["target"],
          row["target_ground"],
          0.0,
          chest
        )

      {store, beside} = CheckCombat.zombie(store, <<2::128>>, row["beside"], true, 0.0, %{})

      expected_sounds =
        Enum.reject(row["sounds"], &String.starts_with?(&1, "minecraft:entity.zombie."))

      mob_sounds = Enum.count(row["sounds"], &(&1 == "minecraft:entity.zombie.hurt"))

      actual =
        case Melee.attack(%{
               damage: damage,
               enchanted:
                 EnchantmentEffects.damage(enchantments, zombie, player, Float32.round(damage)),
               strength: strength,
               sprinting: sprint,
               critical: row["fall"] > 0 and not ground and not sprint,
               sweep:
                 ground and Melee.slow_enough?(known, Float32.round(movement.value)) and
                   Weapons.sword?(weapon)
             }) do
          :none ->
            %{
              health: 100.0,
              velocity: {0.0, 0.0, 0.0},
              beside: 100.0,
              beside_velocity: {0.0, 0.0, 0.0},
              sounds: [],
              particles: [],
              crits: 0,
              magic: 0,
              wear: 0,
              mob_sounds: 0
            }

          {:ok, hit} ->
            facing = Melee.facing(row["yaw"])

            me = %{
              uuid: <<9::128>>,
              entity_id: 9,
              player: true,
              type: "minecraft:player",
              mainhand: weapon
            }

            power =
              Float32.round(
                Float32.round(
                  EnchantmentEffects.knockback(enchantments, zombie, player, 0.0) / 2.0
                ) +
                  if(hit.sprint_knockback, do: 0.5, else: 0.0)
              )

            request = %{
              source: Valimc.Living.DamageSource.new(Weapons.damage_type(weapon, :player_attack)),
              amount: hit.damage,
              attacker: me,
              direct: me,
              position: {64.5, 64.0, 64.5},
              extra_knockback: {power, facing}
            }

            {:ok, store, outcome} = Combat.hurt(store, target, request)

            before =
              if hit.sprint_knockback, do: ["minecraft:entity.player.attack.knockback"], else: []

            {store, swept, sweep_sounds, sweep_particles} =
              if hit.sweep and outcome.hurt do
                ratio =
                  Attributes.value(
                    "minecraft:sweeping_damage_ratio",
                    0.0,
                    for(
                      {"minecraft:sweeping_damage_ratio", id, a, op} <-
                        EnchantmentEffects.attribute_modifiers([{:mainhand, enchantments}]),
                      do: {id, a, op}
                    )
                  )

                base = Melee.sweep_damage(ratio, hit.base)

                amount =
                  Float32.round(
                    EnchantmentEffects.damage(enchantments, zombie, player, base) * strength
                  )

                {:ok, store, swept} =
                  Combat.hurt(store, beside, %{
                    request
                    | amount: amount,
                      extra_knockback: {Melee.default_knockback(), facing}
                  })

                {store, swept, ["minecraft:entity.player.attack.sweep"],
                 ["minecraft:sweep_attack:0"]}
              else
                {store, %{hurt: false}, [], []}
              end

            effects =
              Attack.effects(
                hit,
                outcome.hurt,
                if(outcome.hurt, do: Float32.round(outcome.previous - outcome.health), else: 0.0)
              )

            wear =
              case {outcome.hurt, Weapons.weapon(weapon)} do
                {true, %{wear: wear}} -> wear
                _ -> 0
              end

            %{
              health: CheckCombat.health(store, target),
              velocity: store.entries[target].body.velocity,
              beside: CheckCombat.health(store, beside),
              beside_velocity: store.entries[beside].body.velocity,
              sounds: before ++ sweep_sounds ++ for({:sound, s} <- effects, do: s),
              particles: sweep_particles ++ for({:particles, p, n} <- effects, do: "#{p}:#{n}"),
              crits: Enum.count(effects, &(&1 == {:animate, 4})),
              magic: Enum.count(effects, &(&1 == {:animate, 5})),
              wear: wear,
              mob_sounds: Enum.count([outcome, swept], &Map.get(&1, :full, false))
            }
        end

      ok =
        actual.health == Float32.round(row["health"]) and
          CheckCombat.close?(actual.velocity, row["velocity"]) and
          actual.beside == Float32.round(row["beside_health"]) and
          CheckCombat.close?(actual.beside_velocity, row["beside_velocity"]) and
          actual.sounds == expected_sounds and actual.particles == row["particles"] and
          actual.crits == row["crits"] and actual.magic == row["magic"] and
          actual.wear == ((row["weapon_after"] && row["weapon_after"]["damage"]) || 0) and
          actual.mob_sounds == mob_sounds

      if ok, do: failures, else: [{row, actual} | failures]
  end

hit_failures =
  for row <- cases["hits"], reduce: [] do
    failures ->
      weapon = CheckCombat.stack(row["zombie_weapon"])

      {store, zombie_id} =
        CheckCombat.zombie(
          CheckCombat.store(),
          <<3::128>>,
          row["zombie"],
          true,
          row["zombie_yaw"],
          if(weapon, do: %{mainhand: weapon}, else: %{})
        )

      {:ok, hit} = Combat.mob_hit(store, zombie_id, "minecraft:player")
      shield = if row["shield"], do: ItemStack.new("shield")

      armor =
        Map.new(row["armor"], fn "minecraft:" <> name ->
          slot =
            cond do
              String.ends_with?(name, "helmet") -> 5
              String.ends_with?(name, "chestplate") -> 6
              String.ends_with?(name, "leggings") -> 7
              String.ends_with?(name, "boots") -> 8
            end

          {slot, ItemStack.new(name)}
        end)

      inventory = %Inventory{slots: if(shield, do: Map.put(armor, 45, shield), else: armor)}

      defender = %{
        position: {64.5, 64.0, 64.5},
        yaw: row["yaw"],
        invulnerable: false,
        difficulty: row["difficulty"],
        blocking: if(shield, do: {shield, row["used"]})
      }

      actual =
        case Hurt.plan(hit, defender) do
          :ignored ->
            %{health: 20.0, velocity: {0.0, 0.0, 0.0}, worn: %{}, sounds: [], hurt: false}

          plan ->
            equipment = Armor.equipment(inventory)
            velocity = {0.0, 0.0, 0.0}

            velocity =
              case plan.knockback do
                {power, dir} -> Hurt.knockback_velocity(velocity, true, power, dir, equipment)
                nil -> velocity
              end

            {:ok, selected} = Health.hurt_window(%Health{}, plan.damage)

            fake = %{
              living: %Valimc.Living{},
              abilities: Valimc.Player.Abilities.for_mode(:survival),
              input: %Valimc.Player.Input{load_ticks: 0},
              food: %Valimc.Player.Food{}
            }

            {:ok, %{player: hurt, inventory: worn_inventory}} =
              Vitals.resolve_damage(fake, inventory, selected, hit.source, %{})

            fully = plan.blocked > 0.0 and plan.damage <= 0.0

            velocity =
              if selected.notify and not fully,
                do:
                  Hurt.knockback_velocity(
                    velocity,
                    true,
                    Melee.default_knockback(),
                    Hurt.away({64.5, 64.0, 64.5}, hit.position),
                    equipment
                  ),
                else: velocity

            worn =
              for {slot, index} <- [head: 5, chest: 6, legs: 7, feet: 8],
                  Map.has_key?(armor, index),
                  into: %{},
                  do: {Atom.to_string(slot), CheckCombat.worn(worn_inventory.slots[index])}

            worn = if shield, do: Map.put(worn, "offhand", plan.shield_wear), else: worn

            sounds =
              if(plan.blocked > 0.0 and selected.notify,
                do: ["minecraft:item.shield.block"],
                else: []
              ) ++
                if(selected.notify,
                  do: [
                    if(hurt.living.health.value <= 0,
                      do: "minecraft:entity.player.death",
                      else: "minecraft:entity.player.hurt"
                    )
                  ],
                  else: []
                )

            %{
              health: hurt.living.health.value,
              velocity: velocity,
              worn: worn,
              sounds: sounds,
              hurt: not fully
            }
        end

      ok =
        actual.health == Float32.round(row["health"]) and
          CheckCombat.close?(actual.velocity, row["velocity"]) and
          actual.worn == row["worn"] and actual.sounds == row["sounds"] and
          actual.hurt == row["hurt"]

      if ok, do: failures, else: [{row, actual} | failures]
  end

for {row, actual} <-
      Enum.take(Enum.reverse(attack_failures), 4) ++ Enum.take(Enum.reverse(hit_failures), 4),
    do: IO.puts("FAIL #{inspect(row, limit: :infinity)}\n  ours #{inspect(actual)}")

if attack_failures != [] or hit_failures != [] do
  IO.puts(
    "FAIL: #{length(attack_failures)} of #{length(cases["attacks"])} attacks, #{length(hit_failures)} of #{length(cases["hits"])} zombie hits differ"
  )

  System.halt(1)
end

IO.puts(
  "PASS: #{length(cases["attacks"])} player attacks and #{length(cases["hits"])} zombie hits equal vanilla's"
)
