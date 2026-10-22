alias Valimc.Living.Burning
alias Valimc.Native
alias Valimc.World.View
alias Valimc.Physics.{CollisionContext, Kernel}
alias Valimc.Data.PlayerPose
[path] = System.argv()
rows = :json.decode(File.read!(path))

for row <- rows do
  states = Map.new(row["blocks"], fn [x, y, z, state] -> {{x, y, z}, state} end)
  {x, y, z} = to = List.to_tuple(row["to"])
  {a, b, c} = from = List.to_tuple(row["from"])
  support = Map.fetch!(states, {floor(x), floor(y - 0.20000000298023224), floor(z)})

  pose =
    Map.fetch!(
      %{"standing" => :standing, "crouching" => :crouching, "swimming" => :swimming},
      row["pose"]
    )

  context =
    CollisionContext.entity(y, row["careful"])
    |> CollisionContext.with_entity(5.0, false, false)

  float = fn {p, q, r} -> {p * 1.0, q * 1.0, r * 1.0} end

  {:ok, fires} =
    Native.physics_player_parity(
      :touched,
      {Kernel.native(View.of(states), nil), [{float.(from), float.(to), nil}],
       Kernel.context(context), {PlayerPose.id(pose), float.(to), false, false, false},
       {row["grounded"], row["careful"], {x - a, y - b, z - c}, support}}
    )

  {:ok, planned} = Burning.plan(fires.steps)

  plan = %{
    operations: for({source, amount} <- fires.immediate, do: {:damage, source, amount}) ++ planned
  }

  Process.put(:hazard_draws, 0)

  random = fn ->
    Process.put(:hazard_draws, Process.get(:hazard_draws) + 1)
    2
  end

  {ticks, frozen, damage, alive} =
    Enum.reduce_while(plan.operations, {-1, 140, [], true}, fn operation,
                                                               {ticks, frozen, damage, alive} =
                                                                 acc ->
      if alive do
        {ticks, frozen, damage} =
          case operation do
            :clear_freeze ->
              {ticks, 0, damage}

            :fire_ignite ->
              {:ok, next} = Burning.fire(ticks, false, 1.0, false, random)
              {next.ticks, if(next.clear_freeze, do: 0, else: frozen), damage}

            :lava_ignite ->
              {:ok, next} = Burning.lava(ticks, false, 1.0, false)
              {next.ticks, if(next.clear_freeze, do: 0, else: frozen), damage}

            :lava_hurt ->
              {ticks, frozen, damage ++ ["lava:4.0"]}

            {:damage, source, amount} ->
              {ticks, frozen, damage ++ ["#{source}:#{amount}"]}

            :extinguish ->
              {:ok, next} = Burning.clear(ticks)
              {next, frozen, damage}
          end

        alive = row["death_at"] == 0 or length(damage) < row["death_at"]
        {:cont, {ticks, frozen, damage, alive}}
      else
        {:halt, acc}
      end
    end)

  ticks = if ticks <= -1, do: -20, else: ticks

  unless {ticks, frozen, damage, alive, Process.get(:hazard_draws)} ==
           {row["fire"], row["frozen"], row["damage"], row["alive"], row["draws"]},
         do:
           raise("Native contact order differs: #{inspect({row, ticks, frozen, damage, alive})}")
end

IO.puts(
  "PASS: #{length(rows)} native support/inside/deferred contact traces and first-hit death gates; health/armor excluded."
)
