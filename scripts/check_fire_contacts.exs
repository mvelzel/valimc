alias Valimc.{PlayerBurning, PlayerFireContacts}
[path] = System.argv()
rows = :json.decode(File.read!(path))
kinds = %{"fire" => :fire, "soul_fire" => :soul_fire, "lava" => :lava, "water" => :water}

for row <- rows do
  Process.put(:fire_contact_draws, 0)

  random = fn ->
    Process.put(:fire_contact_draws, Process.get(:fire_contact_draws) + 1)
    row["increment"]
  end

  steps =
    for step <- String.split(row["pattern"], "|"),
        do: Enum.map(String.split(step, ","), &Map.fetch!(kinds, &1))

  {:ok, operations} = PlayerFireContacts.plan(steps)

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
