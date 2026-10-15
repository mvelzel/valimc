path = System.fetch_env!("VALIMC_METRICS_FILE")

if System.get_env("VALIMC_BENCH_SCATTER") == "true" do
  count = System.fetch_env!("VALIMC_BENCH_PLAYERS") |> String.to_integer()

  for index <- 0..(count - 1) do
    uuid = Valimc.Connection.offline_uuid("Bench#{index}")
    pose = %{x: index * 128 + 64.5, y: 64.0, z: 64.5, yaw: 0.0, pitch: 0.0}
    snapshot = Valimc.PlayerSnapshot.capture(pose, Valimc.Inventory.new())
    {:ok, bytes} = Valimc.PlayerSnapshot.encode(uuid, snapshot)
    target = Valimc.PlayerStore.path(Valimc.config(:world_path), uuid)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, bytes)
  end
end

spawn_link(fn ->
  loop = fn loop ->
    players = Map.new(Valimc.Players.all(), &{&1.name, Map.take(&1, [:x, :y, :z])})

    sample =
      Valimc.Metrics.snapshot()
      |> Map.put(:time_ms, System.monotonic_time(:millisecond))
      |> Map.put(:accepted_positions, players)

    File.write!(path <> ".tmp", :json.encode(sample))
    File.rename!(path <> ".tmp", path)
    Process.sleep(100)
    loop.(loop)
  end

  loop.(loop)
end)

IO.gets("")
System.stop(0)
