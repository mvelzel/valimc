Code.require_file("blocks.exs", __DIR__)
alias Valimc.{GameMode, PlayerInput, PlayerMotionQuery, World}
[output] = System.argv()
concurrency = min(System.schedulers_online(), 16)

sample = fn player ->
  deadline = System.monotonic_time(:millisecond) + 250

  run = fn run, retries ->
    case PlayerMotionQuery.start(player, player.target) do
      {:ok, task} ->
        {Task.await(task, 1000), retries}

      {:error, :collision_workers_busy} ->
        true = System.monotonic_time(:millisecond) < deadline
        Process.sleep(1)
        run.(run, retries + 1)

      error ->
        raise "Movement query failed: #{inspect(error)}"
    end
  end

  {elapsed, {{:ok, result}, retries}} =
    :timer.tc(fn ->
      run.(run, 0)
    end)

  true = result.accepted == player.expected
  {elapsed, retries}
end

workloads =
  for owners <- [1, 16] do
    players =
      for owner <- 0..(owners - 1), scenario <- 0..3 do
        key = {860 + owner, 860}
        {:ok, _} = World.owner(key)
        x = (860 + owner) * 128 + 40.5 + scenario * 6
        z = 860 * 128 + 40.5

        block =
          case scenario do
            1 -> {{floor(x) + 1, 64, floor(z)}, 1}
            2 -> {{floor(x) + 1, 64, floor(z)}, 15180}
            3 -> {{floor(x), 65, floor(z)}, 15178}
            0 -> {{floor(x), 65, floor(z)}, 0}
          end

        :ok = Bench.Blocks.set(elem(block, 0), elem(block, 1))

        %{
          x: x,
          y: 64.0,
          z: z,
          pose: :standing,
          entity_id: owner * 4 + scenario + 1,
          game_mode: GameMode.new(:creative),
          abilities: GameMode.abilities(GameMode.new(:creative), false),
          input: %{
            PlayerInput.loaded(%PlayerInput{})
            | shared_flags: if(scenario == 3, do: 2, else: 0)
          },
          expected: scenario != 1,
          target: %{
            x: x + elem({0.2, 0.5, 1.0, 0.2}, scenario),
            y: if(scenario == 2, do: 64.5, else: 64.0),
            z: z
          }
        }
      end

    for player <- players, do: sample.(player)
    inputs = Enum.map(players, &Map.take(&1, [:x, :y, :z, :target, :expected]))
    players = List.to_tuple(players)

    runs =
      for parallel <- Enum.uniq([1, concurrency]), repetition <- 1..3 do
        {wall_us, results} =
          :timer.tc(fn ->
            0..399
            |> Task.async_stream(
              fn index -> sample.(elem(players, rem(index, tuple_size(players)))) end,
              max_concurrency: parallel,
              timeout: 2000,
              ordered: false
            )
            |> Enum.map(fn {:ok, result} -> result end)
          end)

        latencies = Enum.map(results, &elem(&1, 0))
        sorted = Enum.sort(latencies)

        %{
          concurrency: parallel,
          repetition: repetition,
          requests: length(latencies),
          wall_us: wall_us,
          median_us: Enum.at(sorted, 199),
          p95_us: Enum.at(sorted, 379),
          max_us: List.last(sorted),
          pool_busy_retries: Enum.map(results, &elem(&1, 1)),
          latencies_us: latencies
        }
      end

    %{owners: owners, players: tuple_size(players), inputs: inputs, runs: runs}
  end

File.write!(
  output,
  JSON.encode!(%{
    revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
    recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    elixir: System.version(),
    otp: System.otp_release(),
    architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
    schedulers: System.schedulers_online(),
    memory_bytes: :erlang.memory(:total),
    scope:
      "Movement query admission/geometry only: equal open/wall/slab/Shift tunnel mix, existing owners, warm shapes, revision rechecks. Pool-full retries at 1ms are included; live players retry at publication. No network, player publication, survival simulation or server-capacity claim.",
    source_sha256: :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower),
    implementation_sha256:
      Map.new(Path.wildcard("lib/**/*.ex") ++ Path.wildcard("priv/physics/*.json"), fn path ->
        {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
      end),
    workloads: workloads
  })
)

IO.puts("PASS: four movement outcomes validated across #{length(workloads)} workloads; #{output}")
