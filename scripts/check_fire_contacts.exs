alias Valimc.{PlayerBurning, PlayerFireContacts}
[path | facts] = System.argv()

for native_path <- facts do
  unless :json.decode(File.read!(native_path)) ==
           :json.decode(File.read!("priv/physics/inside_blocks.json")),
         do: raise("Native inside-block catalog differs")
end

rows = :json.decode(File.read!(path))
kinds = %{"fire" => :fire, "soul_fire" => :soul_fire, "lava" => :lava, "water" => :water}

for row <- rows do
  Process.put(:fire_contact_draws, 0)

  random = fn ->
    Process.put(:fire_contact_draws, Process.get(:fire_contact_draws) + 1)
    row["increment"]
  end

  operations =
    if Map.has_key?(row, "pattern") do
      steps =
        for step <- String.split(row["pattern"], "|"),
            do: Enum.map(String.split(step, ","), &Map.fetch!(kinds, &1))

      {:ok, operations} = PlayerFireContacts.plan(steps)
      operations
    else
      alias Valimc.Physics.{BlockCollisions.Frame, CollisionContext, BlockContacts}
      states = Map.new(row["blocks"], fn [x, y, z, id] -> {{x, y, z}, id} end)

      paths =
        Enum.map(row["paths"], fn p ->
          %{
            from: List.to_tuple(p["from"]),
            to: List.to_tuple(p["to"]),
            axis: if(is_list(p["axis"]), do: List.to_tuple(p["axis"]))
          }
        end)

      feet = List.to_tuple(row["feet"])

      context =
        CollisionContext.entity(elem(feet, 1))
        |> CollisionContext.with_entity(row["fall"], false, false)

      facts = %{
        pose:
          Map.fetch!(
            %{"standing" => :standing, "crouching" => :crouching, "swimming" => :swimming},
            row["pose"]
          ),
        feet: feet,
        flying: false,
        spectator: row["spectator"],
        weaving: false,
        grounded: false,
        careful: false,
        known_movement: {0.0, 0.0, 0.0},
        support_state: 0
      }

      case BlockContacts.sample_paths(
             %Frame{states: states, fences: %{}, entities: %{}},
             paths,
             context,
             facts
           ) do
        {:ok, result} -> result.operations
        error -> raise("Native geometry refused: #{inspect({row, error})}")
      end
    end

  {ticks, frozen, damage} =
    Enum.reduce(operations, {row["current"], 140, []}, fn operation, {ticks, frozen, damage} ->
      case operation do
        :clear_freeze ->
          {ticks, 0, damage}

        :fire_ignite ->
          {:ok, next} =
            PlayerBurning.fire(ticks, row["immune"], row["factor"], row["invulnerable"], random)

          {next.ticks, if(next.clear_freeze, do: 0, else: frozen), damage}

        :lava_ignite ->
          {:ok, next} =
            PlayerBurning.lava(ticks, row["immune"], row["factor"], row["invulnerable"])

          {next.ticks, if(next.clear_freeze, do: 0, else: frozen), damage}

        :lava_hurt ->
          {ticks, frozen, if(row["immune"], do: damage, else: damage ++ ["lava:4.0"])}

        {:damage, :in_fire, amount} ->
          {ticks, frozen, damage ++ ["in_fire:#{amount}"]}

        :extinguish ->
          {:ok, next} = PlayerBurning.clear(ticks)
          {next, frozen, damage}
      end
    end)

  unless {ticks, frozen, damage, Process.get(:fire_contact_draws)} ==
           {row["next"], row["frozen"], row["damage"], row["draws"]},
         do: raise("Native ordered contact differs: #{inspect({row, ticks, frozen, damage})}")
end

IO.puts(
  "PASS: #{length(rows)} native ordered fire/fluid callback and ServerPlayer ignition cases."
)
