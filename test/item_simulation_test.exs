defmodule Valimc.ItemSimulationTest do
  use ExUnit.Case, async: false
  alias Valimc.{ItemMotionState, ItemSimulation, World}

  setup do
    key = {51000 + rem(System.unique_integer([:positive]), 1000), 1000}
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
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
    assert_receive {:resource, ^epoch, {:item_simulation, ^worker, ^token, result}}, 1000
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

  test "disjoint bodies split the bounded geometry budget without permanently starving a cohort",
       ctx do
    assert {:ok, %{steps: steps, refused: []}} = result(inputs(ctx.key, 256, 7.0))
    assert length(steps) == 256 and length(Enum.uniq_by(steps, & &1.id)) == 256
  end

  test "a busy owner does not stall geometry, and unavailable geometry retires its tasks", ctx do
    {pid, _} = ctx.owner
    :sys.suspend(pid)

    try do
      # Reads come from the published snapshot, not the (suspended) owner mailbox.
      assert {:ok, %{refused: []}} = result(inputs(ctx.key, 256, 0.1))
    after
      :sys.resume(pid)
    end

    stale_fence(pid)
    assert {:ok, %{steps: [], refused: refused}} = result(inputs(ctx.key, 256, 0.1))
    assert length(refused) == 256
    assert DynamicSupervisor.count_children(Valimc.ItemGeometryWorkers).active == 0
  end

  # Make published reads fail (foreign epoch) without stopping the owner.
  defp stale_fence(pid) do
    :sys.replace_state(pid, fn state ->
      :ets.insert(state.resource.item_publication, {:block_fence, make_ref(), 0})
      state
    end)
  end

  test "empty, oversized and duplicate identity batches refuse before starting work", ctx do
    input = hd(inputs(ctx.key, 1, 0.1))

    for invalid <- [
          [],
          [nil],
          [%{}],
          [%{input | id: -1}],
          [input, input],
          List.duplicate(input, 257)
        ] do
      assert {:error, :invalid_item_simulation} =
               ItemSimulation.start(self(), make_ref(), make_ref(), invalid)
    end
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
      assert {:ok, _} = Task.await(task, 1000)
    after
      for pid <- holders, do: Task.Supervisor.terminate_child(Valimc.ItemGeometryWorkers, pid)
    end
  end

  test "owner death cancels its coordinator and retires geometry requests", ctx do
    pid = elem(ctx.owner, 0)
    :sys.suspend(pid)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, job} =
          ItemSimulation.start(self(), make_ref(), make_ref(), inputs(ctx.key, 256, 0.1))

        send(parent, {:job, job.worker})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:job, worker}, 1000
      monitor = Process.monitor(worker)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 1000
      assert reason in [:killed, :noproc]

      assert Enum.reduce_while(1..100, false, fn _, _ ->
               if Enum.all?(
                    Task.Supervisor.children(Valimc.ItemGeometryWorkers),
                    &(not Process.alive?(&1))
                  ),
                  do: {:halt, true},
                  else:
                    (
                      Process.sleep(5)
                      {:cont, false}
                    )
             end)
    after
      :sys.resume(pid)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end
end
