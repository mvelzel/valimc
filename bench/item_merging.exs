alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
alias Valimc.World.{Items, Region, RegionStorage}
[base] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
{:ok, _} = Application.ensure_all_started(:valimc)

wait = fn predicate ->
  deadline = System.monotonic_time(:millisecond) + 15_000

  Stream.repeatedly(fn ->
    if System.monotonic_time(:millisecond) > deadline, do: raise("convergence timeout")
    if predicate.(), do: :done, else: Process.sleep(5)
  end)
  |> Enum.find(&(&1 == :done))
end

results =
  for {population, count, component_bytes} <- [
        {1, 256, 0},
        {8, 256, 0},
        {1, 32, 4096},
        {8, 32, 4096}
      ] do
    keys = for i <- 1..population, do: {81000 + population * 32 + i * 2 + component_bytes, 8000}
    plain = ItemStack.new("stone")

    stack =
      if component_bytes == 0,
        do: plain,
        else: %{
          plain
          | components: %{
              "minecraft:custom_data" =>
                {:compound, %{"bytes" => {:byte_array, :binary.copy(<<12>>, component_bytes)}}}
            }
        }

    for {rx, rz} = key <- keys do
      records =
        for i <- 1..count,
            do: %{
              uuid: <<rx * 1000 + i::128>>,
              x: rx * 128 + 8.5,
              y: 64.0,
              z: rz * 128 + 8.5,
              stack: stack,
              motion: %ItemMotionState{no_gravity: true, on_ground: true}
            }

      :ok = RegionStorage.import(base, :overworld, key, %{items: records})
    end

    before = Valimc.Metrics.snapshot()
    started = System.monotonic_time(:microsecond)

    # Items simulate and merge only while a ticket makes the region tick.
    owners =
      for key <- keys,
          do:
            (
              {:ok, owner} = World.item_owner(key)
              chunks = Valimc.Worldgen.Proto.chunks_of(key)
              :ok = Region.ticket(owner, :forced, hd(chunks), chunks)
              owner
            )

    wait.(fn ->
      Enum.all?(owners, fn {pid, _} ->
        s = :sys.get_state(pid).resource
        s.item_pending == nil and Valimc.World.ItemMerges.candidates(s.items) == []
      end)
    end)

    elapsed = System.monotonic_time(:microsecond) - started
    # Allow the one final changed signature to discover no further pairs.
    Process.sleep(450)
    idle = Valimc.Metrics.snapshot()
    Process.sleep(600)
    after_idle = Valimc.Metrics.snapshot()

    rows =
      for {pid, _} <- owners do
        :ok = Region.flush(pid)
        s = :sys.get_state(pid).resource
        records = Items.records(s.items)
        ^count = Enum.sum(Enum.map(records, & &1.stack.count))
        {:ok, disk} = RegionStorage.read(base, :overworld, s.key)

        true =
          Enum.map(disk.items, &{&1.uuid, &1.stack}) == Enum.map(records, &{&1.uuid, &1.stack})

        row = %{
          region: Tuple.to_list(s.key),
          survivors: length(records),
          counts: Enum.map(records, & &1.stack.count)
        }

        :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
        row
      end

    %{
      owners: population,
      initial_items_per_owner: count,
      component_bytes: component_bytes,
      convergence_us: elapsed,
      merge_jobs: Map.get(idle, :item_merge_jobs, 0) - Map.get(before, :item_merge_jobs, 0),
      idle_merge_jobs:
        Map.get(after_idle, :item_merge_jobs, 0) - Map.get(idle, :item_merge_jobs, 0),
      regions: rows
    }
  end

IO.puts(
  :json.encode(%{
    scope:
      "same-owner automatic durable merges; coincident stone1 populations, no sockets/pickup/cross-owner merging; includes initial owner load",
    elixir: System.version(),
    otp: System.otp_release(),
    schedulers: System.schedulers_online(),
    results: results
  })
)
