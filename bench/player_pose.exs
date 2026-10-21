Code.require_file("blocks.exs", __DIR__)
alias Valimc.{GameMode, PlayerInput, PlayerPoseQuery, World}
[output] = System.argv()
concurrency = min(System.schedulers_online(), 16)

sample = fn player ->
  {elapsed, {:ok, result}} =
    :timer.tc(fn ->
      {:ok, task} = PlayerPoseQuery.start(player)
      Task.await(task, 1000)
    end)

  true = result.pose == player.expected
  elapsed
end

workloads =
  for owners <- [1, 16] do
    players =
      for owner <- 0..(owners - 1), scenario <- 0..3 do
        key = {800 + owner, 800}
        {:ok, _} = World.owner(key)
        x = (800 + owner) * 128 + 40.5 + scenario * 2
        z = 800 * 128 + 40.5

        roof =
          case scenario do
            2 -> 15178
            3 -> 1
            _ -> 0
          end

        :ok = Bench.Blocks.set({floor(x), 65, floor(z)}, roof)

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
            | shared_flags: if(scenario == 1, do: 2, else: 0)
          },
          expected: elem({:standing, :crouching, :crouching, :swimming}, scenario)
        }
      end

    for player <- players, do: sample.(player)
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
            |> Enum.map(fn {:ok, latency} -> latency end)
          end)

        sorted = Enum.sort(results)

        %{
          concurrency: parallel,
          repetition: repetition,
          requests: length(results),
          wall_us: wall_us,
          median_us: Enum.at(sorted, 199),
          p95_us: Enum.at(sorted, 379),
          max_us: List.last(sorted),
          latencies_us: results
        }
      end

    %{owners: owners, players: tuple_size(players), runs: runs}
  end

record = %{
  base_revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  elixir: System.version(),
  otp: System.otp_release(),
  architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
  schedulers: System.schedulers_online(),
  scope:
    "Live sampled pose work only: existing owners, equal four-way open/Shift/crouch/crawl mix, warm geometry, revision rechecks. No network, survival or fastest-server claim.",
  source_sha256: :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower),
  implementation_sha256:
    Map.new(Path.wildcard("lib/**/*.ex") ++ ["priv/protocol/entities.json"], fn path ->
      {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
    end),
  workloads: workloads
}

File.write!(output, JSON.encode!(record))
IO.puts("PASS: sampled poses validated in #{length(workloads)} workloads; #{output}")
