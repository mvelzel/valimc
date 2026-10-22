path = System.fetch_env!("VALIMC_METRICS_FILE")

scatter = System.get_env("VALIMC_BENCH_SCATTER") == "true"
fluid = System.get_env("VALIMC_BENCH_FLUID") == "true"

if scatter or fluid do
  count = System.fetch_env!("VALIMC_BENCH_PLAYERS") |> String.to_integer()

  for index <- 0..(count - 1) do
    uuid = Valimc.Net.Connection.offline_uuid("Bench#{index}")

    pose = %{
      x: if(scatter, do: index * 128 + 64.5, else: 0.5),
      y: 64.0,
      z: if(scatter, do: 64.5, else: 0.5),
      yaw: 0.0,
      pitch: 0.0
    }

    snapshot = Valimc.Player.State.capture(pose, Valimc.Menus.Inventory.new())
    {:ok, bytes} = Valimc.Player.State.encode(uuid, snapshot)
    target = Valimc.Player.Storage.path(Valimc.config(:world_path), uuid)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, bytes)
  end

  if fluid do
    edits =
      for index <- 0..if(scatter, do: count - 1, else: 0), x <- -1..1, y <- 64..66, z <- -1..1 do
        pos =
          {if(scatter, do: index * 128 + 64, else: 0) + x, y, if(scatter, do: 64, else: 0) + z}

        {pos, 89}
      end

    for {key, entries} <-
          Enum.group_by(edits, fn {{x, _, z}, _} ->
            Valimc.World.region_key(Valimc.World.chunk_key(x, z))
          end),
        batch <- Enum.chunk_every(entries, 128) do
      {:ok, owner} = Valimc.World.owner(Valimc.World.section(:overworld, key, :section))

      {:ok, observation} =
        Valimc.World.Region.observe_blocks(owner, Enum.map(batch, &elem(&1, 0)))

      {:ok, _} = Valimc.World.Region.set_blocks(owner, observation.revision, Map.new(batch))
    end
  end
end

spawn_link(fn ->
  loop = fn loop ->
    observed = Valimc.Player.PlayerList.all()

    players =
      Map.new(observed, fn player ->
        position = Map.take(player, [:x, :y, :z])

        position =
          if fluid,
            do:
              Map.merge(position, %{
                swimming: player.motion.swimming,
                pose: Atom.to_string(player.pose)
              }),
            else: position

        {player.name, position}
      end)

    sample =
      Valimc.Data.Metrics.snapshot()
      |> Map.put(:time_ms, System.monotonic_time(:millisecond))
      |> Map.put(:accepted_positions, players)

    sample =
      if fluid,
        do: Map.put(sample, :swimming_players, Enum.count(observed, & &1.motion.swimming)),
        else: sample

    File.write!(path <> ".tmp", :json.encode(sample))
    File.rename!(path <> ".tmp", path)
    Process.sleep(100)
    loop.(loop)
  end

  loop.(loop)
end)

IO.gets("")
System.stop(0)
