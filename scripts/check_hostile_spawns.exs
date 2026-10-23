# Vanilla's `finalizeSpawn` (HostileOracle spawns) against `Valimc.AI.Spawn`
# (VMC-043b): fresh mobs of each family type over the same seeded level and
# mob randoms, difficulty and local difficulty, spawn reason, biome and
# nearby chicken, over the same floor and roof. Their equipment and its
# enchantments, drop chances, flags, attributes, health, villager data, the
# jockey and mobs they made, and both randoms after must equal vanilla's.
alias Valimc.AI
alias Valimc.AI.{Mind, Self}
alias Valimc.Entity.{Body, Mob}
alias Valimc.Living.LocalDifficulty

[path] = System.argv()
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

scene =
  for y <- [63, 66], x <- -6..6, z <- -6..6, into: %{}, do: {{x, y, z}, stone}

# A brain mob's brain (a piglin's first hunt is a memory, VMC-043d).
brain = fn type ->
  case AI.Mobs.brain(type) do
    nil -> nil
    module -> elem(module.brain(AI.Random.new(0), module.gates(<<1::128>>)), 0)
  end
end

operations = %{"add_value" => 0, "add_multiplied_base" => 1, "add_multiplied_total" => 2}

checked =
  for c <- cases, reduce: 0 do
    count ->
      type = c["type"]
      difficulty = String.to_atom(c["difficulty"])
      {:ok, body} = Body.new(type)
      mob = %{body.mob | finalize: String.to_atom(c["reason"])}

      chickens =
        if c["chicken"],
          do: [
            %{
              kind: :mob,
              uuid: <<9::128>>,
              id: 9,
              type: "minecraft:chicken",
              x: 2.5,
              y: 64.0,
              z: 1.5,
              eye: Valimc.Data.Float32.round(0.644),
              width: Valimc.Data.Float32.round(0.4),
              height: Valimc.Data.Float32.round(0.7),
              alive: true,
              target: nil
            }
          ],
          else: []

      world = %AI.World{
        read: &Map.get(scene, &1, air),
        random: AI.Random.new(c["level_seed"]),
        difficulty: difficulty,
        local: LocalDifficulty.new(difficulty, c["time"], c["inhabited"], float.(c["moon"])),
        biome: fn _ -> c["biome"] end,
        halloween: c["halloween"],
        mobs: chickens,
        by_type: Enum.group_by(chickens, & &1.type)
      }

      {width, height, eye} = Body.dimensions(body)

      self =
        AI.Spawn.finalize(%Self{
          id: 1,
          uuid: <<1::128>>,
          type: type,
          x: 0.5,
          y: 64.0,
          z: 0.5,
          yaw: 0.0,
          pitch: 0.0,
          head: 0.0,
          on_ground: true,
          mob: mob,
          mind: %Mind{random: AI.Random.new(c["mob_seed"]), brain: brain.(type)},
          facts: AI.Facts.mob(type),
          width: width,
          height: height,
          eye: eye,
          data: body.data,
          world: world
        })

      mob = self.mob

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

      jockey =
        Enum.find_value(self.effects, fn
          {:jockey, _} -> "existing"
          {:spawn, "minecraft:chicken", %{jockey: true}} -> "new"
          _ -> nil
        end)

      spawned = for {:spawn, t, _} <- Enum.reverse(self.effects), do: t

      got = %{
        equipment: equipment,
        drop_chances: Map.new(mob.drop_chances, fn {s, v} -> {Atom.to_string(s), v} end),
        left_handed: mob.left_handed,
        can_pick_up_loot: mob.can_pick_up_loot,
        baby: self.data.baby,
        can_break_doors: Map.get(self.data, :can_break_doors),
        hunted_recently: self.mind.brain && AI.Brain.ttl(self, :hunted_recently),
        attributes: got_attributes,
        health: mob.living.health.value,
        villager: if(type == "minecraft:zombie_villager", do: Tuple.to_list(self.data.villager)),
        jockey: jockey,
        spawned: spawned,
        level_seed: self.world.random,
        mob_seed: self.mind.random
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
        mob_seed: c["mob_seed_after"]
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

      dead = %Body{
        body
        | mob: %{mob | ai: self.mind, player_memory: if(d["by_player"], do: 100, else: 0)},
          data: self.data
      }

      {dead, drops} =
        Valimc.Entity.Combat.drop_equipment(dead, %{
          attacker: %{
            player: true,
            mainhand: sword,
            uuid: <<2::128>>,
            entity_id: 2,
            type: "minecraft:player"
          }
        })

      got =
        Map.merge(got, %{
          drops:
            for(
              s <- drops,
              do: [
                Valimc.Protocol.ItemTypes.item(s.item_id)["name"],
                Map.get(s.components, "minecraft:damage", 0)
              ]
            ),
          death_seed: dead.mob.ai.random
        })

      want = Map.merge(want, %{drops: d["drops"], death_seed: d["mob_seed_after"]})

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
