# The physics kernel's costs (VMC-077l), matched across revisions: the same
# workloads run against the Elixir physics (a revision before the kernel) and
# the kernel. Per move: one player move packet's validation and observations
# (`MotionQuery`), sequentially (wall and VM CPU per move) and with 16
# moves in flight. Per item: one item tick over the region's published rows.
#
#   MIX_ENV=bench python3 scripts/heavy.py mix run --no-start bench/physics_kernel.exs OUT.json
Code.require_file("blocks.exs", __DIR__)
alias Valimc.Player.{GameMode, Input, MotionQuery}
alias Valimc.Entity.ItemMotionState
alias Valimc.World
alias Valimc.World.View

[output] = System.argv()
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, nil)
{:ok, _} = Application.ensure_all_started(:valimc)
kernel? = function_exported?(MotionQuery, :run, 3)

# One move: synchronous in the connection with the kernel; before it, a pooled
# task whose result the connection awaited (busy pools retried after 1 ms).
move =
  if kernel? do
    fn player -> MotionQuery.run(player, player.target) end
  else
    fn player ->
      Stream.repeatedly(fn -> apply(MotionQuery, :start, [player, player.target]) end)
      |> Enum.find_value(fn
        {:ok, task} -> Task.await(task, 1000)
        {:error, :collision_workers_busy} -> Process.sleep(1) && nil
      end)
    end
  end

key = {870, 870}
{:ok, _} = World.owner(Valimc.World.section(:overworld, key, :section))

players =
  for scenario <- 0..3 do
    x = 870 * 128 + 40.5 + scenario * 6
    z = 870 * 128 + 40.5

    {position, block} =
      case scenario do
        0 -> {{floor(x), 65, floor(z)}, 0}
        1 -> {{floor(x) + 1, 64, floor(z)}, 1}
        2 -> {{floor(x) + 1, 64, floor(z)}, 15180}
        3 -> {{floor(x), 65, floor(z)}, 15178}
      end

    :ok = Bench.Blocks.set(position, block)

    %{
      x: x,
      y: 64.0,
      z: z,
      pose: :standing,
      entity_id: scenario + 1,
      game_mode: GameMode.new(:creative),
      abilities: GameMode.abilities(GameMode.new(:creative), false),
      input: %{
        Input.loaded(%Input{})
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
  |> List.to_tuple()

check = fn player ->
  {:ok, result} = move.(player)
  true = result.accepted == player.expected
end

moves = 2000
for i <- 0..399, do: check.(elem(players, rem(i, 4)))

sequential =
  for repetition <- 1..3 do
    :erlang.garbage_collect()
    {_, _} = :erlang.statistics(:runtime)

    latencies =
      for i <- 0..(moves - 1) do
        {us, _} = :timer.tc(fn -> check.(elem(players, rem(i, 4))) end)
        us
      end

    {_, cpu_ms} = :erlang.statistics(:runtime)
    sorted = Enum.sort(latencies)

    %{
      repetition: repetition,
      moves: moves,
      median_us: Enum.at(sorted, div(moves, 2)),
      p95_us: Enum.at(sorted, div(moves * 95, 100)),
      cpu_us_per_move: cpu_ms * 1000 / moves
    }
  end

parallel =
  for repetition <- 1..3 do
    {wall_us, _} =
      :timer.tc(fn ->
        0..(moves - 1)
        |> Task.async_stream(fn i -> check.(elem(players, rem(i, 4))) end,
          max_concurrency: 16,
          timeout: 5000
        )
        |> Stream.run()
      end)

    %{repetition: repetition, moves: moves, wall_us_per_move: wall_us / moves}
  end

# One kernel call's fixed cost: the snapshots of the chunks around a
# player-sized box handed to the NIF, which reads them in place (kernel only).
call =
  if kernel? do
    alias Valimc.Physics.{CollisionContext, Kernel}
    box = {870 * 128 + 40.2, 64.0, 870 * 128 + 40.2, 870 * 128 + 40.8, 65.8, 870 * 128 + 40.8}
    context = CollisionContext.entity(64.0)

    for repetition <- 1..3 do
      times =
        for _ <- 1..5000 do
          {us, {:ok, _}} = :timer.tc(fn -> Kernel.colliding?(View.new(), box, context) end)
          us
        end

      sorted = Enum.sort(times)

      %{
        repetition: repetition,
        calls: 5000,
        median_us: Enum.at(sorted, 2500),
        p95_us: Enum.at(sorted, 4750)
      }
    end
  end

# Items: 256 on a stone floor (dry) or in water, stepped over published rows.
n = 870 * 128
item_key = {870, 871}
{:ok, _} = World.owner(Valimc.World.section(:overworld, item_key, :section))
m = 871 * 128

items =
  for id <- 1..256 do
    %{
      id: id,
      revision: 1,
      position: {n + 4.5 + rem(id - 1, 16) * 1.5, 64.7, m + 4.5 + div(id - 1, 16) * 1.5},
      motion: %ItemMotionState{velocity: {0.1, -0.1, 0.05}, pickup_delay: 40}
    }
  end

step =
  if kernel? do
    fn inputs -> Valimc.World.ItemStep.run(View.new(), inputs, nil) end
  else
    fn inputs ->
      Enum.map(inputs, &apply(Valimc.Physics.ItemTravel, :sample, [&1, View.new(), true]))
    end
  end

item_rows =
  for scene <- [:dry, :water] do
    if scene == :water do
      for x <- 3..30,
          z <- 3..30,
          do: :ok = Bench.Blocks.set({n + x, 64, m + z}, if(rem(x, 3) == 0, do: 96, else: 89))
    end

    reference = step.(items)
    true = Enum.all?(reference, &match?({:ok, _}, &1))
    for _ <- 1..10, do: ^reference = step.(items)
    :erlang.garbage_collect()

    times =
      for _ <- 1..50 do
        {us, actual} = :timer.tc(fn -> step.(items) end)
        ^reference = actual
        us
      end

    sorted = Enum.sort(times)

    %{
      scene: scene,
      items: length(items),
      samples: 50,
      median_us_per_item: Enum.at(sorted, 24) / length(items),
      p95_us_per_item: Enum.at(sorted, 47) / length(items)
    }
  end

File.write!(
  output,
  JSON.encode!(%{
    revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
    kernel: kernel?,
    recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    otp: System.otp_release(),
    schedulers: System.schedulers_online(),
    load: System.cmd("sysctl", ["-n", "vm.loadavg"]) |> elem(0) |> String.trim(),
    scope:
      "Move validation and observations (open, wall, slab step, Shift tunnel) and item ticks over published rows; no sockets, replication or durable writes.",
    sequential: sequential,
    parallel: parallel,
    kernel_call: call,
    items: item_rows
  })
)

IO.puts("PASS: kernel=#{kernel?}; #{output}")
