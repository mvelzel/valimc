alias Valimc.{ItemMotionState, World}
alias Valimc.Protocol.ItemStack
alias Valimc.World.{ItemRecords, Items, Region, Store}

[base] = System.argv()
File.mkdir_p!(base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, Path.expand(base))
{:ok, _} = Application.ensure_all_started(:valimc)
count_saves = fn -> Map.get(Valimc.Metrics.snapshot(), :item_snapshot_saves, 0) end

workloads =
  for mode <- [:durable, :coalesced],
      count <- [1, 32],
      bytes <- [0, 4096],
      do: {mode, count, bytes}

results =
  for {{mode, count, bytes}, index} <- Enum.with_index(workloads) do
    key = {9100 + index, 9100}
    {rx, rz} = key
    stack = ItemStack.new("stone", 3)

    stack =
      if bytes == 0,
        do: stack,
        else: %{
          stack
          | components: %{
              "minecraft:custom_data" =>
                {:compound, %{"bytes" => {:byte_array, :binary.copy(<<12>>, bytes)}}}
            }
        }

    records =
      for id <- 1..count do
        %{
          uuid: <<index * 100 + id::128>>,
          stack: stack,
          x: rx * 128 + 4.5 + rem(id - 1, 8) * 1.5,
          y: 65.5,
          z: rz * 128 + 4.5 + div(id - 1, 8) * 1.5,
          motion: %ItemMotionState{}
        }
      end

    {:ok, initial} = ItemRecords.encode(key, records)
    File.write!(Store.item_path(Path.expand(base), key), initial, [:binary, :sync])
    {:ok, {pid, _} = owner} = World.item_owner(key)
    original = :sys.get_state(pid).resource.items
    origin = Map.new(original.entries, fn {id, %{entity: e}} -> {id, {e.x, e.y, e.z}} end)
    saves = count_saves.()
    started = System.monotonic_time(:microsecond)

    times =
      for tick <- 1..100 do
        items = :sys.get_state(pid).resource.items

        steps =
          Enum.map(items.entries, fn {id, entry} ->
            {x, y, z} = origin[id]

            %{
              id: id,
              revision: entry.revision,
              position: {x + tick * 0.01, y, z},
              motion: %ItemMotionState{velocity: {0.01, 0, 0}, age: tick, no_gravity: true}
            }
          end)

        {us, {:ok, handles}} =
          :timer.tc(fn ->
            if mode == :durable,
              do: Region.advance_items(owner, steps),
              else: Region.publish_item_motion(owner, steps)
          end)

        true = length(handles) == count
        us
      end

    {flush_us, :ok} = :timer.tc(fn -> Region.flush(pid) end)
    elapsed = System.monotonic_time(:microsecond) - started
    {:ok, disk} = ItemRecords.decode(File.read!(Store.item_path(Path.expand(base), key)), key)
    true = disk.records == Items.records(:sys.get_state(pid).resource.items)
    true = Enum.all?(disk.records, &(&1.motion.age == 100))
    sorted = Enum.sort(times)

    %{
      mode: mode,
      items: count,
      component_bytes: bytes,
      frames: 100,
      p50_us: Enum.at(sorted, 49),
      p95_us: Enum.at(sorted, 94),
      flush_us: flush_us,
      total_us: elapsed,
      item_snapshot_saves: count_saves.() - saves
    }
  end

IO.puts(
  :json.encode(%{
    scope:
      "100-frame accepted-motion burst, no geometry/sockets; both end with durable flush, intermediate crash guarantees differ",
    runtime: %{
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online()
    },
    results: results
  })
)
