alias Valimc.ItemMotionState
alias Valimc.Protocol.ItemStack
alias Valimc.World.{EntityHandoffs, EntityReplication, EntityTracking, Entities}

measure = fn run ->
  for _ <- 1..20, do: run.()
  :erlang.garbage_collect()
  samples = for _ <- 1..100, do: elem(:timer.tc(run), 0)
  sorted = Enum.sort(samples)
  %{samples: 100, p50_us: Enum.at(sorted, 49), p95_us: Enum.at(sorted, 94)}
end

record = fn n, bytes ->
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

  %{
    uuid: <<n::128>>,
    x: 0.5,
    y: 65.5,
    z: 0.5,
    stack: stack,
    motion: %ItemMotionState{velocity: {0.2, -0.04, 0.0}}
  }
end

handoffs =
  for {active, count, bytes} <- [{1, 1, 0}, {32, 32, 0}, {256, 32, 0}, {32, 32, 4096}] do
    {:ok, initial} = Entities.restore({0, 0}, Enum.map(1..active, &record.(&1, bytes)))

    steps =
      initial.entries
      |> Enum.take(count)
      |> Enum.map(fn {id, entry} ->
        %{id: id, revision: entry.revision, position: {128.5, 65.5, 0.5}, motion: entry.motion}
      end)

    run = fn ->
      {:ok, source, transfer} =
        EntityHandoffs.depart(
          initial,
          {:overworld, 0, 0},
          initial.epoch,
          {:overworld, 1, 0},
          steps
        )

      {:ok, destination, :applied} =
        EntityHandoffs.accept(Entities.new(), {:overworld, 1, 0}, transfer)

      {:ok, digest} = EntityHandoffs.digest(transfer)

      {:ok, source} =
        EntityHandoffs.finish(source, {:overworld, 0, 0}, transfer.sequence, digest, :applied)

      true = map_size(source.entries) + map_size(destination.entries) == active
      true = Enum.all?(destination.entries, fn {_, entry} -> entry.hops == 1 end)
    end

    Map.merge(measure.(run), %{active: active, moved: count, component_bytes: bytes})
  end

replication =
  for count <- [1, 64, 256, 1024], torn <- [false, true] do
    unique = if torn, do: count - min(div(count, 2), 32), else: count

    items =
      for index <- 0..div(unique - 1, 256) do
        first = index * 256 + 1
        last = min(first + 255, unique)
        {:ok, items} = Entities.restore({0, 0}, Enum.map(first..last, &record.(&1, 0)))
        items
      end

    views = Enum.reduce(items, %{}, &Map.merge(&2, &1.views))

    views =
      if torn do
        records = items |> hd() |> Entities.records() |> Enum.take(min(div(count, 2), 32))

        if records == [] do
          views
        else
          records = Enum.map(records, &Map.merge(&1, %{x: 128.5, hops: 1}))
          {:ok, adopted} = Entities.restore({1, 0}, records)
          Map.merge(views, adopted.views)
        end
      else
        views
      end

    # Published as an owner's tracker publishes them; no frames are pending.
    views =
      %EntityTracking{}
      |> EntityTracking.sync(views, nil)
      |> EntityTracking.published(views)
      |> Map.new(fn {id, view} -> {id, Map.put(view, :tick, 0)} end)

    frames = fn _region, _last -> {:ok, 0, []} end

    tracked =
      Enum.reduce(1..16, EntityReplication.new(), fn _, state ->
        {next, _} = EntityReplication.reconcile(state, views, frames)
        next
      end)

    true = map_size(tracked.tracked) == unique
    run = fn -> {^tracked, []} = EntityReplication.reconcile(tracked, views, frames) end
    Map.merge(measure.(run), %{sampled_views: map_size(views), unique_items: unique, torn: torn})
  end

IO.puts(
  :json.encode(%{
    scope:
      "pure depart/adopt/clear plans and converged observer samples; no storage, workers, geometry, sockets or automatic clock",
    runtime: %{
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online()
    },
    handoffs: handoffs,
    replication: replication
  })
)
