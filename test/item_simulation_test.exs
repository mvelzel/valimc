defmodule Valimc.ItemSimulationTest do
  use ExUnit.Case, async: false
  # Serial: one batch claims the global geometry worker pool, and one test saturates it.
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, ItemSimulation, World}

  setup do
    key = {51000 + rem(System.unique_integer([:positive]), 333) * 3, 1000}
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)
    end)

    %{key: key, owner: owner}
  end

  defp inputs({x, z}, count, spread) do
    for n <- 1..count,
        do: %{
          id: n,
          revision: 1,
          position:
            {x * 128 + 3.5 + rem(n - 1, 16) * spread, 66.0,
             z * 128 + 3.5 + div(n - 1, 16) * spread},
          motion: %ItemMotionState{velocity: {0.1, -0.1, 0.0}}
        }
  end

  defp result(inputs) do
    epoch = make_ref()
    token = make_ref()
    {:ok, job} = ItemSimulation.start(self(), epoch, token, inputs)
    worker = job.worker
    assert_receive {:resource, ^epoch, {:item_simulation, ^worker, ^token, result}}
    Process.demonitor(job.monitor, [:flush])
    result
  end

  test "all256 active items receive one simulation step rather than one cohort per tick", ctx do
    inputs = inputs(ctx.key, 256, 0.1)
    assert {:ok, %{steps: steps, refused: [], fences: fences}} = result(inputs)
    assert Enum.sort(Enum.map(steps, & &1.id)) == Enum.to_list(1..256)
    assert Enum.all?(steps, &(&1.motion.age == 1 and elem(&1.position, 1) < 66.0))
    assert Map.keys(fences) == [ctx.key]
  end

  test "saturated item geometry cannot consume player query slots", ctx do
    holders =
      Enum.reduce_while(1..1025, [], fn _, acc ->
        case Task.Supervisor.start_child(Valimc.ItemGeometryWorkers, fn ->
               receive do
                 :stop -> :ok
               end
             end) do
          {:ok, pid} -> {:cont, [pid | acc]}
          {:error, :max_children} -> {:halt, acc}
        end
      end)

    try do
      assert length(holders) in 1..1024

      assert {:error, :collision_workers_busy} =
               Valimc.ItemPhysicsQuery.start(inputs(ctx.key, 1, 0.1))

      {rx, rz} = ctx.key
      box = {rx * 128 + 3.0, 65.0, rz * 128 + 3.0, rx * 128 + 4.0, 66.0, rz * 128 + 4.0}
      assert {:ok, task} = Valimc.Physics.CollisionQuery.start(box)
      assert {:ok, _} = Task.await(task, 60_000)
    after
      for pid <- holders, do: Task.Supervisor.terminate_child(Valimc.ItemGeometryWorkers, pid)
    end
  end
end
