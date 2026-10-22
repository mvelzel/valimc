alias Valimc.{ItemMotionState, World.EntityReplication, World.Entities, World.EntityTracking}
alias Valimc.World.EntityView
alias Valimc.Protocol.ItemStack

rich = %{
  ItemStack.new("stone")
  | components: %{
      "minecraft:custom_data" =>
        {:compound, %{"bytes" => {:byte_array, :binary.copy(<<12>>, 12_000)}}}
    }
}

rows =
  for {name, count, stack} <- [{"plain", 256, ItemStack.new("stone")}, {"components", 32, rich}] do
    owners =
      for rx <- 0..3 do
        items =
          Enum.reduce(1..count, Entities.new(), fn n, items ->
            {:ok, next, _} = Entities.create(items, {rx, 0}, stack, {rx * 128 + n / 4, 64.5, 0.5})
            next
          end)

        tracking = EntityTracking.sync(%EntityTracking{}, items.views, nil)
        {{rx, 0}, items, Enum.sort(Map.keys(items.entries)), tracking, %{}}
      end

    # What observers read: each owner's published views and its last frame.
    views = fn owners ->
      Enum.reduce(owners, %{}, fn {_, items, _, tracking, _}, all ->
        tracking
        |> EntityTracking.published(items.views)
        |> Map.new(fn {id, view} -> {id, Map.put(view, :tick, tracking.tick)} end)
        |> Map.merge(all)
      end)
    end

    frames = fn owners ->
      by_region =
        Map.new(owners, fn {key, _, _, tracking, frame} -> {key, {tracking.tick, frame}} end)

      fn region, last ->
        {tick, frame} = by_region[region]
        if last == nil or last >= tick, do: {:ok, tick, []}, else: {:ok, tick, [{tick, frame}]}
      end
    end

    initial =
      Enum.reduce_while(1..(4 * count), EntityReplication.new(), fn _, observer ->
        {next, _} = EntityReplication.reconcile(observer, views.(owners), frames.(owners))
        if map_size(next.tracked) == 4 * count, do: {:halt, next}, else: {:cont, next}
      end)

    true = map_size(initial.tracked) == 4 * count

    :erlang.garbage_collect()

    {owners, _observer, times, packets, bytes} =
      Enum.reduce(1..200, {owners, initial, [], 0, 0}, fn tick,
                                                          {owners, observer, times, packets,
                                                           bytes} ->
        {elapsed, {owners, observer, emitted}} =
          :timer.tc(fn ->
            owners =
              Enum.map(owners, fn {key, items, ids, tracking, _frame} ->
                offset = rem((tick - 1) * 32, count)

                steps =
                  ids
                  |> Enum.drop(offset)
                  |> Enum.take(32)
                  |> Enum.map(fn id ->
                    entry = items.entries[id]
                    direction = if rem(div(tick - 1, div(count, 32)), 2) == 0, do: 1, else: -1

                    %{
                      id: id,
                      revision: entry.revision,
                      position:
                        {entry.entity.x + direction * 0.01, entry.entity.y, entry.entity.z},
                      motion: %ItemMotionState{
                        velocity: {direction * 0.01, 0, 0},
                        age: tick,
                        no_gravity: true
                      }
                    }
                  end)

                {:ok, next, _} = Entities.advance(items, key, items.epoch, steps)
                {tracking, frame} = EntityTracking.step(tracking, next.views, nil, tick)
                {key, next, ids, tracking, frame}
              end)

            {observer, emitted} =
              EntityReplication.reconcile(observer, views.(owners), frames.(owners))

            {owners, observer, emitted}
          end)

        {owners, observer, [elapsed | times], packets + length(emitted),
         bytes + Enum.sum(Enum.map(emitted, &EntityView.packet_bytes/1))}
      end)

    :erlang.garbage_collect()
    sorted = Enum.sort(times)

    %{
      profile: name,
      owners: length(owners),
      visible_items: count * 4,
      frames: 200,
      accepted_steps_per_frame: 128,
      observer_change_cap: 64,
      metadata_payload_bytes: if(name == "plain", do: 0, else: 12_000),
      p50_us: Enum.at(sorted, 99),
      p95_us: Enum.at(sorted, 189),
      p99_us: Enum.at(sorted, 197),
      max_us: List.last(sorted),
      total_packets: packets,
      total_wire_bytes: bytes,
      retained_process_bytes: elem(Process.info(self(), :memory), 1)
    }
  end

IO.puts(
  JSON.encode!(%{
    elixir: System.version(),
    otp: System.otp_release(),
    schedulers: System.schedulers_online(),
    scope:
      "pure accepted 32-step owner batches, owner trackers and one observer forwarding their frames; excludes geometry, sockets, disk, automatic clock and other servers",
    profiles: rows
  })
)
