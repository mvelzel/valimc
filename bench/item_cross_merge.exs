defmodule Valimc.CrossMergeBench do
  alias Valimc.{ItemMotionState, Metrics, Protocol.ItemStack, World}
  alias Valimc.World.{Region, RegionStorage}

  def run(base, boundaries, component_bytes) do
    stack = ItemStack.new("stone", 2)

    stack =
      if component_bytes == 0,
        do: stack,
        else: %{
          stack
          | components: %{
              "minecraft:custom_data" =>
                {:compound, %{"bytes" => {:byte_array, :binary.copy(<<12>>, component_bytes)}}}
            }
        }

    groups =
      for b <- 1..boundaries do
        key = {90000 + component_bytes + boundaries * 40 + b * 4, 9100}
        target = {elem(key, 0) + 1, elem(key, 1)}

        donors =
          for i <- 1..32,
              do: %{
                uuid: <<elem(key, 0)::64, i::64>>,
                x: (elem(key, 0) + 1) * 128 - 0.1,
                y: 68.0,
                z: elem(key, 1) * 128 + 4.5 + i * 1.5,
                stack: stack,
                motion: %ItemMotionState{no_gravity: true}
              }

        recipients =
          for d <- donors,
              do: %{
                d
                | uuid: :crypto.hash(:md5, d.uuid),
                  x: d.x + 0.2,
                  stack: %{stack | count: 3}
              }

        owners =
          for {k, records} <- [{key, donors}, {target, recipients}] do
            :ok = RegionStorage.import(base, :overworld, k, %{items: records})
            {:ok, owner} = World.item_owner(k)
            # Items simulate and merge only while a ticket makes the region tick.
            chunks = Valimc.World.RegionGeneration.chunks_of(k)
            :ok = Region.ticket(owner, :forced, hd(chunks), chunks)
            {k, owner}
          end

        %{key: key, target: target, owners: owners, recipients: MapSet.new(recipients, & &1.uuid)}
      end

    before = Metrics.snapshot()
    started = System.monotonic_time(:microsecond)

    for g <- groups,
        {_, {pid, _}} <- g.owners,
        do:
          :sys.replace_state(
            pid,
            &put_in(&1.resource.entities.simulate, true)
          )

    times = await(groups, %{}, started, started + 60_000_000)
    owners = Enum.flat_map(groups, & &1.owners)

    wait(fn ->
      Enum.all?(owners, fn {_, {pid, _}} ->
        s = :sys.get_state(pid).resource

        s.entities.store.ledger.outgoing == nil and not Valimc.World.RegionData.planning?(s)
      end)
    end)

    elapsed = System.monotonic_time(:microsecond) - started

    for g <- groups, {k, {pid, _}} <- g.owners do
      :ok = Region.flush(pid)
      {:ok, saved} = RegionStorage.read(base, :overworld, k)

      if k == g.key do
        true = saved.items == [] and saved.ledger.sequence >= 32
      else
        true = length(saved.items) == 32 and Enum.all?(saved.items, &(&1.stack.count == 5))
        true = MapSet.new(saved.items, & &1.uuid) == g.recipients
        {:ok, source} = RegionStorage.read(base, :overworld, g.key)
        true = saved.ledger.incoming[g.key].sequence == source.ledger.sequence
      end
    end

    # Let final physical observations settle before checking idle discovery work.
    Process.sleep(400)
    idle_before = Metrics.snapshot()
    Process.sleep(400)
    after_run = Metrics.snapshot()
    times = times |> Map.values() |> Enum.sort()
    count = boundaries * 32

    result = %{
      boundaries: boundaries,
      owners: boundaries * 2,
      pairs: count,
      item_entities: count * 2,
      component_bytes: component_bytes,
      elapsed_ms: elapsed / 1000,
      merges_per_second: count * 1_000_000 / elapsed,
      recipient_p50_ms: Enum.at(times, div(length(times), 2)) / 1000,
      recipient_p95_ms: Enum.at(times, trunc(length(times) * 0.95)) / 1000,
      handoffs: delta(after_run, before, :item_cross_merges),
      rejected_transfers:
        Enum.sum_by(groups, fn g ->
          {pid, _} = g.owners |> Map.new() |> Map.fetch!(g.key)
          :sys.get_state(pid).resource.entities.store.ledger.sequence - 32
        end),
      idle_handoffs: delta(after_run, idle_before, :item_cross_merges),
      conserved: true
    }

    for g <- groups,
        x <- (elem(g.key, 0) - 1)..(elem(g.key, 0) + 2),
        z <- 9099..9101,
        {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
        do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

    result
  end

  defp await(groups, times, started, deadline) do
    if System.monotonic_time(:microsecond) >= deadline, do: raise("merge convergence timeout")

    times =
      Enum.reduce(groups, times, fn g, acc ->
        for {_, view} <- World.item_snapshot(g.target), view.count == 5, reduce: acc do
          acc -> Map.put_new(acc, view.uuid, System.monotonic_time(:microsecond) - started)
        end
      end)

    if map_size(times) == length(groups) * 32,
      do: times,
      else:
        (
          Process.sleep(5)
          await(groups, times, started, deadline)
        )
  end

  defp wait(fun, tries \\ 1000) do
    if fun.(),
      do: :ok,
      else:
        (
          if tries == 0, do: raise("merge journals did not clear")
          Process.sleep(5)
          wait(fun, tries - 1)
        )
  end

  defp delta(a, b, key), do: Map.get(a, key, 0) - Map.get(b, key, 0)
end

[base] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :item_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)

rows =
  for bytes <- [0, 4096], boundaries <- [1, 8] do
    row = Valimc.CrossMergeBench.run(base, boundaries, bytes)
    IO.puts(:json.encode(row))
    row
  end

IO.puts(
  :json.encode(%{
    workload:
      "automatic cross-owner merges; real region fsync/proof; stationary items; no TCP/rendering",
    dataset: base,
    schedulers: System.schedulers_online(),
    results: rows
  })
)
