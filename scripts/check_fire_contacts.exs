alias Valimc.Living.Burning
alias Valimc.Native
alias Valimc.World.View
[path] = System.argv()

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

      {:ok, operations} = Burning.plan(steps)
      operations
    else
      alias Valimc.Physics.{CollisionContext, Kernel, PlayerPose}
      states = Map.new(row["blocks"], fn [x, y, z, id] -> {{x, y, z}, id} end)
      vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

      paths =
        Enum.map(row["paths"], fn p ->
          {vec.(p["from"]), vec.(p["to"]), if(is_list(p["axis"]), do: vec.(p["axis"]))}
        end)

      feet = vec.(row["feet"])

      context =
        CollisionContext.entity(elem(feet, 1))
        |> CollisionContext.with_entity(row["fall"], false, false)

      pose =
        Map.fetch!(
          %{"standing" => :standing, "crouching" => :crouching, "swimming" => :swimming},
          row["pose"]
        )

      body = {PlayerPose.id(pose), feet, false, row["spectator"], false}

      case Native.physics_player_parity(
             :touched,
             {Kernel.native(View.of(states), nil), paths, Kernel.context(context), body,
              {false, false, {0.0, 0.0, 0.0}, 0}}
           ) do
        {:ok, fires} ->
          {:ok, operations} = Burning.plan(fires.steps)
          for({source, amount} <- fires.immediate, do: {:damage, source, amount}) ++ operations

        error ->
          raise("Native geometry refused: #{inspect({row, error})}")
      end
    end

  {ticks, frozen, damage} =
    Enum.reduce(operations, {row["current"], 140, []}, fn operation, {ticks, frozen, damage} ->
      case operation do
        :clear_freeze ->
          {ticks, 0, damage}

        :fire_ignite ->
          {:ok, next} =
            Burning.fire(ticks, row["immune"], row["factor"], row["invulnerable"], random)

          {next.ticks, if(next.clear_freeze, do: 0, else: frozen), damage}

        :lava_ignite ->
          {:ok, next} =
            Burning.lava(ticks, row["immune"], row["factor"], row["invulnerable"])

          {next.ticks, if(next.clear_freeze, do: 0, else: frozen), damage}

        :lava_hurt ->
          {ticks, frozen, if(row["immune"], do: damage, else: damage ++ ["lava:4.0"])}

        {:damage, :in_fire, amount} ->
          {ticks, frozen, damage ++ ["in_fire:#{amount}"]}

        :extinguish ->
          {:ok, next} = Burning.clear(ticks)
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
