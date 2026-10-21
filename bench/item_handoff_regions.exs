alias Valimc.ItemMotionState
alias Valimc.Protocol.ItemStack
alias Valimc.World
alias Valimc.World.{Items, Region, RegionStorage}

[base] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, base)
{:ok, _} = Application.ensure_all_started(:valimc)

wait = fn predicate ->
  Enum.reduce_while(1..2000, nil, fn _, _ ->
    if predicate.(),
      do: {:halt, :ok},
      else:
        (
          Process.sleep(1)
          {:cont, :timeout}
        )
  end)
end

# Ages and delays reach the log only with checkpoints; frames hold the rest.
uncounted = fn records ->
  Enum.map(records, fn
    %{motion: m} = r -> %{r | motion: %{m | age: 0, pickup_delay: 0, portal_cooldown: 0}}
    r -> r
  end)
end

percentiles = fn values ->
  values = Enum.sort(values)
  %{p50_us: Enum.at(values, 24), p95_us: Enum.at(values, 47)}
end

rows =
  for {{count, component_bytes}, index} <-
        Enum.with_index([{1, 0}, {32, 0}, {1, 4096}, {32, 4096}]) do
    a_key = {9200 + index * 2, 9200}
    b_key = {elem(a_key, 0) + 1, elem(a_key, 1)}
    stack = ItemStack.new("stone", 3)

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

    records =
      for n <- 1..count,
          do: %{
            uuid: <<index * 100 + n::128>>,
            x: elem(a_key, 0) * 128 + 127.5,
            y: 64.25,
            z: elem(a_key, 1) * 128 + 0.5,
            stack: stack,
            motion: %ItemMotionState{no_gravity: true}
          }

    :ok = RegionStorage.import(base, :overworld, a_key, %{items: records})
    {:ok, a} = World.item_owner(a_key)
    {:ok, b} = World.item_owner(b_key)
    frames = Map.get(Valimc.Metrics.snapshot(), :storage_records, 0)

    samples =
      for turn <- 1..60 do
        {source, destination, source_key, destination_key} =
          if rem(turn, 2) == 1, do: {a, b, a_key, b_key}, else: {b, a, b_key, a_key}

        items = :sys.get_state(elem(source, 0)).resource.items

        steps =
          Enum.map(items.entries, fn {id, entry} ->
            %{
              id: id,
              revision: entry.revision,
              position:
                {elem(destination_key, 0) * 128 + 0.5, 64.25,
                 elem(destination_key, 1) * 128 + 0.5},
              motion: %{entry.motion | age: turn}
            }
          end)

        started = System.monotonic_time(:microsecond)

        {withdrawal, {:ok, _}} =
          :timer.tc(fn -> Region.handoff_items(source, destination_key, steps) end)

        :ok =
          wait.(fn ->
            state = :sys.get_state(elem(source, 0)).resource
            state.items.ledger.outgoing == nil and state.item_pending == nil
          end)

        settled = System.monotonic_time(:microsecond) - started
        source_items = :sys.get_state(elem(source, 0)).resource.items
        destination_items = :sys.get_state(elem(destination, 0)).resource.items
        true = source_items.entries == %{} and map_size(destination_items.entries) == count

        # The last steps are durable within a commit tick of settling.
        for {key, expected} <- [{source_key, source_items}, {destination_key, destination_items}] do
          :ok =
            wait.(fn ->
              {:ok, saved} = RegionStorage.read(base, :overworld, key)

              uncounted.(saved.items) == uncounted.(Items.records(expected)) and
                saved.ledger == expected.ledger
            end)
        end

        %{withdrawal: withdrawal, settled: settled}
      end

    measured = Enum.drop(samples, 10)

    %{
      items: count,
      component_bytes: component_bytes,
      warmup: 10,
      samples: 50,
      withdrawal: percentiles.(Enum.map(measured, & &1.withdrawal)),
      settled: percentiles.(Enum.map(measured, & &1.settled)),
      log_frames: Map.get(Valimc.Metrics.snapshot(), :storage_records, 0) - frames,
      last_generations:
        Map.values(:sys.get_state(elem(a, 0)).resource.items.ledger.generations) |> Enum.uniq()
    }
  end

IO.puts(
  :json.encode(%{
    scope:
      "alternating durable region handoffs including their synced log frames, worker dispatch and 1ms completion polling; no geometry, client sockets or automatic clock",
    runtime: %{
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online()
    },
    results: rows
  })
)
