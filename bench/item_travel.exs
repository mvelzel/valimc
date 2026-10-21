Code.require_file("blocks.exs", __DIR__)
alias Valimc.{ItemMotionState, ItemPhysicsQuery, World}

Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, nil)
{:ok, _} = Application.ensure_all_started(:valimc)
{:ok, _} = World.owner({8800, 8800})
n = 8800 * 128

inputs =
  for id <- 1..32 do
    %{
      id: id,
      revision: 1,
      position: {n + 4.5 + rem(id - 1, 8) * 1.5, 64.7, n + 4.5 + div(id - 1, 8) * 1.5},
      motion: %ItemMotionState{velocity: {0.1, -0.1, 0.05}, pickup_delay: 40}
    }
  end

rows =
  for scene <- [:dry, :water], count <- [1, 8, 32], mode <- [:individual, :batched] do
    if scene == :water do
      for x <- 3..16,
          z <- 3..11,
          do: :ok = Bench.Blocks.set({n + x, 64, n + z}, if(rem(x, 3) == 0, do: 96, else: 89))
    end

    selected = Enum.take(inputs, count)

    run = fn ->
      batches = if mode == :batched, do: [selected], else: Enum.map(selected, &[&1])

      tasks =
        Enum.map(batches, fn batch ->
          {:ok, task} = ItemPhysicsQuery.start(batch)
          task
        end)

      steps =
        Enum.flat_map(tasks, fn task ->
          {:ok, %{steps: steps, refused: []}} = Task.await(task, 1500)
          steps
        end)

      true = length(steps) == count
      Enum.sort_by(steps, & &1.id)
    end

    reference = run.()
    for _ <- 1..20, do: ^reference = run.()
    :erlang.garbage_collect()

    times =
      for _ <- 1..100 do
        {elapsed, actual} = :timer.tc(run)
        ^reference = actual
        elapsed
      end

    sorted = Enum.sort(times)

    %{
      scene: Atom.to_string(scene),
      items: count,
      mode: Atom.to_string(mode),
      samples: 100,
      jobs_per_sample: if(mode == :batched, do: 1, else: count),
      p50_us: Enum.at(sorted, 49),
      p95_us: Enum.at(sorted, 94)
    }
  end

IO.puts(
  :json.encode(%{
    scope: "geometry RPC + pure travel; no disk, sockets, replication or automatic clock",
    runtime: %{
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online()
    },
    results: rows
  })
)
