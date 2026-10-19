defmodule Valimc.ItemCrossMergeAutoTest do
  use ExUnit.Case, async: false
  # Serial: asserts deltas of global Metrics counters other owners also bump.
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, Metrics, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Items, Region}

  setup tags do
    n = System.unique_integer([:positive])
    key = {72000 + rem(n, 10000), 2300}
    target_key = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-cross-auto-#{n}")
    File.mkdir_p!(base)
    TestScope.isolate(TestScope.neighborhood(key, 2), world_path: base)
    variant = tags[:variant]
    count = tags[:pairs] || 1

    custom =
      if variant in [:counter, :reverse] or count > 1,
        do: %{"minecraft:max_stack_size" => 99},
        else: %{}

    {donors, recipients} =
      for i <- 1..count, reduce: {[], []} do
        {ds, rs} ->
          components = if count > 1, do: Map.put(custom, "minecraft:repair_cost", i), else: custom
          stack = %{ItemStack.new("stone", 2) | components: components}

          donor = %{
            uuid: <<n::64, i::64>>,
            x: (elem(key, 0) + 1) * 128 - 0.1,
            y: 68.0,
            z: elem(key, 1) * 128 + 4.5 + i * 3,
            stack: %{stack | count: if(variant == :reverse, do: 1, else: 2)},
            motion: %ItemMotionState{
              age: 30,
              pickup_delay: 15,
              no_gravity: true,
              velocity: if(tags[:moving], do: {0.0, 0.0, 0.01}, else: {0.0, 0.0, 0.0})
            }
          }

          recipient = %{
            donor
            | uuid: <<n::64, i + 256::64>>,
              x: donor.x + 0.2,
              stack: %{
                stack
                | count:
                    cond do
                      variant == :reverse -> 65
                      variant == :counter or count > 1 -> 64
                      true -> 3
                    end
              },
              motion: %{donor.motion | age: 100, pickup_delay: 0}
          }

          {donor, recipient} =
            case variant do
              :equal ->
                {%{donor | stack: %{stack | count: 3}}, recipient}

              :opposite ->
                {%{donor | stack: %{stack | count: 4}}, recipient}

              :components ->
                {donor,
                 %{
                   recipient
                   | stack: %{recipient.stack | components: %{"minecraft:repair_cost" => 1}}
                 }}

              :capacity ->
                {donor, %{recipient | stack: %{recipient.stack | count: 63}}}

              :horizontal ->
                {donor, %{recipient | x: donor.x + 0.75}}

              :vertical ->
                {donor, %{recipient | y: donor.y + 0.25}}

              :sentinel ->
                {%{donor | motion: %{donor.motion | age: -32768}}, recipient}

              _ ->
                {donor, recipient}
            end

          {[donor | ds], [recipient | rs]}
      end

    recipients = if variant == :later, do: [], else: recipients

    for {k, records} <- [{key, donors}, {target_key, recipients}] do
      {:ok, bytes} = ItemLedger.encode(k, records, %{}, %ItemLedger{})
      Valimc.TestDisk.write(base, k, :items, bytes)
    end

    {:ok, source} = World.item_owner(key)
    {:ok, target} = World.item_owner(target_key)

    on_exit(fn ->
      for x <- (elem(key, 0) - 1)..(elem(key, 0) + 2),
          z <- (elem(key, 1) - 1)..(elem(key, 1) + 1) do
        for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}) do
          writer = state({pid, nil}).store
          if Process.alive?(writer), do: :sys.resume(writer)
          TestScope.kill(pid)
        end

        for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, {x, z}),
            do: TestScope.kill(pid)
      end

      File.rm_rf!(base)
    end)

    %{
      key: key,
      target_key: target_key,
      source: source,
      target: target,
      donors: donors,
      recipients: recipients,
      base: base
    }
  end

  defp state({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp start(c) do
    for {pid, _} <- [c.source, c.target],
        do:
          :sys.replace_state(
            pid,
            &%{&1 | resource: %{&1.resource | item_simulation_enabled: true}}
          )
  end

  defp wait(fun, tries \\ 1000) do
    if value = fun.(),
      do: value,
      else:
        (
          assert tries > 0
          Process.sleep(5)
          wait(fun, tries - 1)
        )
  end

  defp idle(c),
    do:
      Enum.all?([c.source, c.target], fn owner ->
        s = state(owner)

        s.items.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s) and
          s.item_cross_job == nil
      end)

  defp jobs, do: Map.get(Metrics.snapshot(), :item_cross_jobs, 0)

  defp ages(c),
    do: for(o <- [c.source, c.target], r <- Items.records(state(o).items), do: r.motion.age)

  # Re-evaluates discovery on the next owner tick instead of after its 200 ms cadence,
  # then waits until both owners have ticked twice and no transfer or query is in flight.
  defp rescan(c) do
    before = Enum.max(ages(c))

    for {pid, _} <- [c.source, c.target],
        do: :sys.replace_state(pid, &%{&1 | resource: %{&1.resource | item_cross_next: nil}})

    wait(fn -> Enum.max(ages(c)) >= before + 2 and idle(c) end)
  end

  defp total(c),
    do:
      Enum.sum(for o <- [c.source, c.target], {_, e} <- state(o).items.entries, do: e.stack.count)

  defp converged(c), do: map_size(state(c.source).items.entries) == 0 and idle(c)

  defp disk(c, k) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, k, :items), k)
    saved
  end

  test "automatic boundary discovery commits and recovers a merge without manual grants", c do
    start(c)
    wait(fn -> converged(c) end)
    assert total(c) == 5

    assert [%{uuid: uuid, stack: %{count: 5}, motion: motion}] =
             Items.records(state(c.target).items)

    assert uuid == hd(c.recipients).uuid and motion.age < 90
    assert disk(c, c.key).records == [] and disk(c, c.key).ledger.sequence == 1
    assert disk(c, c.target_key).ledger.incoming[c.key].sequence == 1
    {pid, _} = c.target
    assert :ok = Region.flush(pid)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, restarted} = World.item_owner(c.target_key)
    assert [%{uuid: ^uuid, stack: %{count: 5}}] = Items.records(state(restarted).items)
  end

  @tag variant: :equal
  test "equal-count owners choose one direction without opposing withdrawals", c do
    start(c)
    wait(fn -> converged(c) end)
    assert total(c) == 6 and disk(c, c.key).ledger.sequence == 1
    assert state(c.target).items.ledger.sequence == 0
  end

  @tag variant: :opposite
  test "larger stack on the lower owner receives from its neighbor", c do
    start(c)
    wait(fn -> map_size(state(c.target).items.entries) == 0 and idle(c) end)
    assert [%{uuid: uuid, stack: %{count: 7}}] = Items.records(state(c.source).items)
    assert uuid == hd(c.donors).uuid
    assert disk(c, c.target_key).ledger.sequence == 1
  end

  for variant <- [:components, :capacity, :horizontal, :vertical, :sentinel] do
    @tag variant: variant
    test "automatic discovery rejects #{variant} without a journal", c do
      before = jobs()
      start(c)
      # Both owners finish a scan; the sentinel donor never enters the source scene.
      wait(fn ->
        state(c.target).item_cross_stamp != nil and idle(c) and
          if(c.variant == :sentinel,
            do: jobs() == before,
            else: jobs() > before and state(c.source).item_cross_stamp != nil
          )
      end)

      rescan(c)
      assert idle(c) and total(c) == hd(c.donors).stack.count + hd(c.recipients).stack.count

      assert map_size(state(c.source).items.entries) == 1 and
               map_size(state(c.target).items.entries) == 1

      assert state(c.source).items.ledger.sequence == 0 and
               state(c.target).items.ledger.sequence == 0

      assert state(c.target).items.ledger.incoming == %{}
    end
  end

  @tag variant: :counter
  test "counter-only automatic effects settle without identity or journal churn", c do
    ids = Map.keys(state(c.source).items.entries) ++ Map.keys(state(c.target).items.entries)
    start(c)
    wait(fn -> hd(Items.records(state(c.target).items)).motion.age < 90 end)

    wait(fn ->
      Enum.all?(
        [c.source, c.target],
        &(state(&1).item_cross_stamp != nil and map_size(state(&1).item_resting) == 1)
      ) and idle(c)
    end)

    jobs = jobs()
    rescan(c)

    assert ids ==
             Map.keys(state(c.source).items.entries) ++ Map.keys(state(c.target).items.entries)

    assert total(c) == 66 and state(c.source).items.ledger.sequence == 0
    assert state(c.target).items.ledger.incoming[c.key].sequence == 0
    assert jobs() == jobs
  end

  @tag variant: :reverse
  test "custom65 reverse flow returns two then settles on the counter-only path", c do
    start(c)
    wait(fn -> state(c.source).items.ledger.sequence == 1 and idle(c) end)
    assert [%{uuid: uuid, stack: %{count: 2}}] = Items.records(state(c.source).items)
    assert uuid == hd(c.donors).uuid
    assert state(c.source).items.ledger.generations[uuid] == 1
    assert [%{stack: %{count: 64}}] = Items.records(state(c.target).items)
    rescan(c)
    assert total(c) == 66 and state(c.source).items.ledger.sequence == 1
  end

  @tag variant: :later
  test "a later neighboring birth wakes a previously empty discovery scene", c do
    start(c)
    wait(fn -> state(c.source).item_cross_stamp != nil end)
    donor = hd(c.donors)

    assert {:ok, _} =
             Region.create_item(
               c.target,
               ItemStack.new("stone", 3),
               {donor.x + 0.2, donor.y, donor.z}
             )

    wait(fn -> converged(c) end)
    assert total(c) == 5
  end

  @tag pairs: 12
  test "bounded counter batches eventually visit pairs beyond the first eight", c do
    start(c)
    wait(fn -> Enum.all?(Items.records(state(c.target).items), &(&1.motion.age < 90)) end)
    wait(fn -> state(c.source).item_cross_stamp != nil and idle(c) end)
    assert total(c) == 12 * 66
    assert state(c.source).items.ledger.sequence == 0
    assert map_size(state(c.source).items.entries) == 12
  end

  @tag pairs: 12, moving: true
  test "moving scenes do not starve counter pairs beyond the first batch", c do
    start(c)
    wait(fn -> Enum.all?(Items.records(state(c.target).items), &(&1.motion.age < 90)) end, 400)
    assert total(c) == 12 * 66 and state(c.source).items.ledger.sequence == 0
  end

  test "a query deadline during source fsync leaves its accepted journal recoverable", c do
    writer = state(c.source).store
    :sys.suspend(writer)

    try do
      start(c)

      wait(fn ->
        Valimc.TestRegion.in_flight?(state(c.source))
      end)

      job = state(c.source).item_cross_job
      assert job != nil
      wait(fn -> not Process.alive?(job.worker) end)
      assert Valimc.TestRegion.in_flight?(state(c.source))
      assert {:ok, c.source} == GenServer.call(elem(c.source, 0), :owner)
      :sys.resume(writer)
      wait(fn -> converged(c) end)
      # The first grant expires while the source is paused. Its committed journal
      # is rejected and returned; automatic discovery retries at the next sequence.
      assert total(c) == 5 and disk(c, c.key).ledger.sequence == 2
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "an exhausted shared I/O pool retries discovery after capacity returns", c do
    workers = fill_pool([])
    before = Map.get(Metrics.snapshot(), :item_cross_busy, 0)

    try do
      start(c)
      wait(fn -> Map.get(Metrics.snapshot(), :item_cross_busy, 0) > before end)
      assert state(c.source).item_cross_job == nil
      assert total(c) == 5 and state(c.source).items.ledger.outgoing == nil
      for pid <- workers, do: send(pid, :stop)
      wait(fn -> Enum.all?(workers, &(not Process.alive?(&1))) end)
      wait(fn -> converged(c) end)
      assert total(c) == 5
    after
      for pid <- workers, Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  defp fill_pool(acc) do
    case Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
           receive do
             :stop -> :ok
           end
         end) do
      {:ok, pid} -> fill_pool([pid | acc])
      {:error, :max_children} -> acc
    end
  end
end
