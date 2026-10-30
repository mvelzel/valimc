# Vanilla's `finalizeSpawn` (HostileOracle spawns) against the native one
# (VMC-043b, `Kind::finalize` run as a turn runs it, `mob_oracle_ai_spawn`):
# fresh mobs of each family type, made first (a brain mob's brain built) and
# then seeded as the oracle seeds them, over the same seeded level and mob
# randoms, difficulty and local difficulty, spawn reason, biome and nearby
# chicken, over the same floor and roof. Their equipment and its
# enchantments, drop chances, flags, attributes, health, villager data, the
# jockey and mobs they made, and both randoms after must equal vanilla's;
# then the equipment they drop dying and their random after.
alias Valimc.Data.JavaRandom
alias Valimc.Entity.{Body, Mob, Store}
alias Valimc.Living.DamageSource
alias Valimc.Native

[path] = System.argv()
Valimc.Entity.MobFacts.install!()
Valimc.Data.BlockFacts.install!()
{fixtures, :ok, ""} = :json.decode(File.read!(path), :ok, %{null: nil})
cases = fixtures["cases"]
unless length(cases) >= 3000, do: raise("Incomplete spawn fixtures")

float = fn bits ->
  <<v::float-32>> = <<bits::signed-32>>
  v
end

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

stone = Valimc.Data.Blocks.default_state("stone")
air = Valimc.Data.Blocks.default_state("air")
blocks = for y <- [63, 66], x <- -6..6, z <- -6..6, do: {x, y, z, stone}
loot = Valimc.Blocks.Loot.registry()

# A chicken beside the mob, for a baby's jockey.
{:ok, chicken} = Body.new("minecraft:chicken")
chicken = Store.body_record(chicken, <<9::128>>, {2.5, 64.0, 1.5})

operations = %{"add_value" => 0, "add_multiplied_base" => 1, "add_multiplied_total" => 2}

checked =
  for c <- cases, reduce: 0 do
    count ->
      type = c["type"]
      difficulty = String.to_atom(c["difficulty"])
      {:ok, body} = Body.spawned(type, String.to_atom(c["reason"]))
      body = %{body | mob: %{body.mob | ai: %{random: JavaRandom.new(c["mob_seed"])}}}
      record = Store.body_record(body, <<1::128>>, {0.5, 64.0, 0.5})

      scene = %{
        random: JavaRandom.new(c["level_seed"]),
        difficulty: difficulty,
        local: {c["time"], c["inhabited"], float.(c["moon"]) * 1.0},
        biome: c["biome"],
        halloween: c["halloween"],
        blocks: blocks,
        air: air,
        mobs: if(c["chicken"], do: [{9, chicken}], else: [])
      }

      # Then a death by a player (Looting or not) or by none: what equipment
      # drops, worn, and the mob's random after (`dropCustomDeathLoot`).
      d = c["death"]
      sword = Valimc.Protocol.ItemStack.new("iron_sword")

      sword =
        if d["looting"] > 0,
          do: %{
            sword
            | components: %{"minecraft:enchantments" => %{"minecraft:looting" => d["looting"]}}
          },
          else: sword

      player = %{
        player: true,
        mainhand: sword,
        uuid: <<2::128>>,
        entity_id: 2,
        type: "minecraft:player"
      }

      hit = %{source: DamageSource.new(:player_attack), amount: 1.0, attacker: player}

      {record, young, hunted, jockey, spawned, level_after, {drops, death_seed}} =
        Native.mob_oracle_ai_spawn(record, scene, loot, {hit, d["by_player"]})

      {:ok, made} = Body.restore(record)
      mob = made.mob

      equipment =
        for {slot, stack} <- mob.equipment, into: %{} do
          enchantments =
            stack.components
            |> Map.get("minecraft:enchantments", %{})
            |> Enum.map(fn {e, l} -> [e, l] end)

          {Atom.to_string(slot),
           %{
             "item" => Valimc.Protocol.ItemTypes.item(stack.item_id)["name"],
             "enchantments" => Enum.sort(enchantments)
           }}
        end

      want_equipment =
        Map.new(c["equipment"], fn {slot, e} ->
          {slot, %{e | "enchantments" => Enum.sort(e["enchantments"])}}
        end)

      attributes =
        for {name, want} <- c["attributes"], into: %{} do
          modifiers =
            for {id, amount, op} <- get_in(mob.attributes, [name, :modifiers]) || [],
                do: [id, amount, op]

          {name,
           %{
             "base" => Mob.base(type, mob.attributes, name),
             "modifiers" => Enum.sort(modifiers)
           }}
          |> then(fn r -> {r, want} end)
        end

      got_attributes = Map.new(attributes, fn {{name, r}, _} -> {name, r} end)

      want_attributes =
        Map.new(attributes, fn {{name, _}, want} ->
          {name,
           %{
             "base" => double.(want["base"]),
             "modifiers" =>
               want["modifiers"]
               |> Enum.map(fn [id, amount, op] -> [id, double.(amount), operations[op]] end)
               |> Enum.sort()
           }}
        end)

      got = %{
        equipment: equipment,
        drop_chances: Map.new(mob.drop_chances, fn {s, v} -> {Atom.to_string(s), v} end),
        left_handed: mob.left_handed,
        can_pick_up_loot: mob.can_pick_up_loot,
        baby: young,
        can_break_doors: Map.get(made.data, :can_break_doors),
        hunted_recently: hunted,
        attributes: got_attributes,
        # The record's (a restore holds health to the base maximum).
        health: record.mob.living.health.value,
        villager: if(type == "minecraft:zombie_villager", do: Tuple.to_list(made.data.villager)),
        jockey: jockey,
        spawned: spawned,
        level_seed: level_after,
        mob_seed: mob.ai.random,
        drops: for({item, damage} <- drops, do: [item, damage]),
        death_seed: death_seed
      }

      want = %{
        equipment: want_equipment,
        drop_chances: Map.new(c["drop_chances"], fn {s, v} -> {s, float.(v)} end),
        left_handed: c["left_handed"],
        can_pick_up_loot: c["can_pick_up_loot"],
        baby: c["baby"],
        can_break_doors: c["can_break_doors"],
        hunted_recently: c["hunted_recently"],
        attributes: want_attributes,
        health: float.(c["health"]),
        villager: c["villager"],
        jockey: c["jockey"],
        spawned: c["spawned"],
        level_seed: c["level_seed_after"],
        mob_seed: c["mob_seed_after"],
        drops: d["drops"],
        death_seed: d["mob_seed_after"]
      }

      differ = for {k, v} <- want, got[k] != v, do: {k, v, got[k]}

      unless differ == [] do
        raise "#{type} #{c["difficulty"]} #{c["reason"]} seeds #{c["level_seed"]}/#{c["mob_seed"]}: " <>
                Enum.map_join(differ, "; ", fn {k, v, g} ->
                  "#{k} vanilla #{inspect(v)} ours #{inspect(g)}"
                end)
      end

      count + 1
  end

IO.puts(
  "PASS: #{checked} finalizeSpawn results equal vanilla's (equipment, enchantments, flags, attributes, jockeys, randoms, equipment dropped on death)"
)
