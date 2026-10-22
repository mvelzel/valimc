alias Valimc.Entity.ItemMotionState
alias Valimc.Protocol.ItemStack
alias Valimc.World
alias Valimc.World.{Region, RegionStorage}

[base] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
{:ok, _} = Application.ensure_all_started(:valimc)

snapshot = fn owners ->
  for {pid, _} <- owners do
    state = :sys.get_state(pid).resource
    %{entries: state.entities.store.entries}
  end
end

rows =
  for {{mode, owners, count}, index} <-
        Enum.with_index(
          for mode <- [:moving, :resting],
              {owners, count} <- [{1, 1}, {1, 32}, {1, 256}, {8, 256}],
              do: {mode, owners, count}
        ) do
    regions =
      for n <- 1..owners do
        key = {71000 + index * 32 + n * 2, 9000}
        {rx, rz} = key

        records =
          for id <- 1..count do
            %{
              uuid: <<index * 10000 + n * 1000 + id::128>>,
              stack: ItemStack.new("stone", 3),
              x: rx * 128 + 4.5 + rem(id - 1, 16) * 2.0,
              y: if(mode == :moving, do: 68.0, else: 64.0),
              z: rz * 128 + 4.5 + div(id - 1, 16) * 2.0,
              motion: %ItemMotionState{
                velocity: if(mode == :moving, do: {0.1, 0.0, 0.0}, else: {0.0, 0.0, 0.0}),
                no_gravity: mode == :moving,
                on_ground: mode == :resting
              }
            }
          end

        :ok = RegionStorage.import(base, :overworld, key, %{items: records})
        {:ok, owner} = World.item_owner(Valimc.Data.Grid.section(:overworld, key, :section))
        # Items simulate only while a ticket makes the region tick.
        chunks = Valimc.World.RegionGeneration.chunks_of(key)
        :ok = Region.ticket(owner, :forced, hd(chunks), chunks)
        owner
      end

    Process.sleep(500)
    before = snapshot.(regions)
    metrics = Valimc.Data.Metrics.snapshot()
    started = System.monotonic_time(:microsecond)
    Process.sleep(2000)
    after_snapshot = snapshot.(regions)
    elapsed = System.monotonic_time(:microsecond) - started
    after_metrics = Valimc.Data.Metrics.snapshot()

    rates =
      Enum.zip(before, after_snapshot)
      |> Enum.flat_map(fn {a, b} ->
        true = map_size(a.entries) == count and map_size(b.entries) == count

        Enum.map(a.entries, fn {id, entry} ->
          current = b.entries[id]

          %{
            age: (current.motion.age - entry.motion.age) * 1_000_000 / elapsed,
            motion: (current.physical_revision - entry.physical_revision) * 1_000_000 / elapsed
          }
        end)
      end)

    metric = fn name -> Map.get(after_metrics, name, 0) - Map.get(metrics, name, 0) end

    result = %{
      mode: mode,
      owners: owners,
      items_per_owner: count,
      measured_us: elapsed,
      age_hz_min: Enum.min(Enum.map(rates, & &1.age)),
      age_hz_max: Enum.max(Enum.map(rates, & &1.age)),
      motion_hz_min: Enum.min(Enum.map(rates, & &1.motion)),
      motion_hz_max: Enum.max(Enum.map(rates, & &1.motion)),
      log_frames: metric.(:storage_records),
      checkpoints: metric.(:region_checkpoints),
      merge_jobs: metric.(:item_merge_jobs)
    }

    for {pid, _} <- regions do
      :ok = Region.flush(pid)
      :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end

    result
  end

IO.puts(
  :json.encode(%{
    scope:
      "owned automatic cadence and merge discovery with 2-block item spacing, items stepped in the tick (VMC-077l), counter clocks and periodic saves; no positive merge, sockets, player launch, pickup or cross-owner workload",
    runtime: %{
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online()
    },
    results: rows
  })
)
