defmodule Valimc.PickupBench do
  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerSnapshot, PlayerStore, TransferDelivery}
  alias Valimc.World.{Entities, Region, RegionStorage}

  def source(base, owner, key, uuid, records) do
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)
    first = hd(records)

    initial = %{
      pose: Map.merge(Map.take(first, [:x, :y, :z]), %{yaw: 0.0, pitch: 0.0}),
      inventory: %Inventory{},
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 20.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      transfer_sequence: 0,
      outbox: nil
    }

    {fence, snapshot, latencies, retries} =
      Enum.reduce(records, {fence, initial, [], 0}, fn item, {fence, snapshot, times, retries} ->
        started = System.monotonic_time(:microsecond)
        {fence, snapshot, rejected} = collect(owner, key, uuid, writer, fence, snapshot, item)

        {fence, snapshot, [System.monotonic_time(:microsecond) - started | times],
         retries + rejected}
      end)

    :ok = PlayerStore.close(writer, fence, snapshot)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(PlayerStore.path(base, uuid)), uuid)
    true = saved.outbox == nil
    total = saved.inventory.slots |> Map.values() |> Enum.sum_by(& &1.count)
    ^total = length(records)
    %{latencies: latencies, retries: retries, received: total}
  end

  defp collect(owner, key, uuid, writer, fence, snapshot, item, rejected \\ 0) do
    if rejected >= 20, do: raise("pickup repeatedly expired")
    deadline = System.monotonic_time(:millisecond) + 30_000

    actor = %{
      uuid: uuid,
      box: {item.x - 0.3, item.y, item.z - 0.3, item.x + 0.3, item.y + 1.8, item.z + 0.3},
      game_mode: snapshot.game_mode,
      health: snapshot.health
    }

    {:ok, grant} = retry(fn -> Region.reserve_pickup(owner, actor, item.uuid) end, deadline)
    {:ok, _, remainder, _} = Inventory.pickup_stack(snapshot.inventory, grant.before)
    intent = %{kind: :pickup, key: key, request: Map.put(grant, :remainder, remainder)}
    ref = make_ref()
    PlayerStore.prepare_pickup(writer, fence, snapshot, intent, ref)

    {fence, pending} =
      receive do
        {:player_transfer_saved, ^ref, {:ok, fence, pending}} -> {fence, pending}
      after
        5000 -> raise "source prepare timeout"
      end

    result = retry(fn -> deliver(uuid, pending) end, deadline)
    true = TransferDelivery.completed?(pending, result)
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)

    {fence, resolved} =
      receive do
        {:player_transfer_saved, ^ref, {:ok, fence, resolved}} -> {fence, resolved}
      after
        5000 -> raise "source completion timeout"
      end

    if result in [{:ok, :applied}, {:ok, :already_applied}],
      do: {fence, resolved, rejected},
      else: collect(owner, key, uuid, writer, fence, resolved, item, rejected + 1)
  end

  defp deliver(uuid, pending) do
    token = make_ref()

    case TransferDelivery.start(self(), token, uuid, pending) do
      {:ok, job} ->
        receive do
          {:transfer_delivered, pid, ^token, result} when pid == job.pid ->
            Process.demonitor(job.monitor, [:flush])
            result
        after
          6500 -> raise "delivery timeout"
        end

      error ->
        error
    end
  end

  defp retry(fun, deadline) do
    result = fun.()

    case result do
      {:ok, _} ->
        result

      error ->
        true = TransferDelivery.retryable?(error)
        if System.monotonic_time(:millisecond) >= deadline, do: raise("pickup capacity timeout")
        Process.sleep(2)
        retry(fun, deadline)
    end
  end

  def run(base, population, component_bytes) do
    stack = Valimc.Protocol.ItemStack.new("stone")

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

    sources =
      for owner_index <- 1..population, source <- 1..4 do
        key = {84000 + component_bytes + population * 32 + owner_index, 8100}
        {rx, rz} = key

        records =
          for i <- 1..16,
              do: %{
                uuid: <<rx::32, source::32, i::64>>,
                x: rx * 128 + 8.5 + i * 2,
                y: 64.0,
                z: rz * 128 + 8.5 + source * 4,
                stack: stack,
                motion: %Valimc.ItemMotionState{no_gravity: true}
              }

        {key, <<rx::64, source::64>>, records}
      end

    owners =
      for {key, grouped} <- Enum.group_by(sources, &elem(&1, 0)) do
        records = Enum.flat_map(grouped, &elem(&1, 2))
        :ok = RegionStorage.import(base, :overworld, key, %{items: records})
        {:ok, owner} = Valimc.World.item_owner(key)
        {key, owner}
      end
      |> Map.new()

    started = System.monotonic_time(:microsecond)

    rows =
      Task.async_stream(
        sources,
        fn {key, uuid, records} ->
          source(base, owners[key], key, uuid, records)
        end,
        max_concurrency: length(sources),
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, row} -> row end)

    elapsed = System.monotonic_time(:microsecond) - started

    for {key, {pid, _}} <- owners do
      :ok = Region.flush(pid)
      true = Entities.records(:sys.get_state(pid).resource.entities.store) == []
      {:ok, saved} = RegionStorage.read(base, :overworld, key)
      true = saved.items == [] and map_size(saved.receipts) == 4
      DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end

    times = rows |> Enum.flat_map(& &1.latencies) |> Enum.sort()
    count = Enum.sum_by(rows, & &1.received)

    %{
      owners: population,
      sources: length(sources),
      item_entities: count,
      component_bytes: component_bytes,
      elapsed_ms: elapsed / 1000,
      pickups_per_second: count * 1_000_000 / elapsed,
      p50_ms: Enum.at(times, div(length(times), 2)) / 1000,
      p95_ms: Enum.at(times, trunc(length(times) * 0.95)) / 1000,
      rejected_retries: Enum.sum_by(rows, & &1.retries),
      conserved: true
    }
  end
end

[base] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :item_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)
rows = for bytes <- [0, 4096], owners <- [1, 8], do: Valimc.PickupBench.run(base, owners, bytes)

IO.puts(
  :json.encode(%{
    workload: "durable pickup I/O; trusted contact; no TCP/rendering/physics",
    dataset: base,
    schedulers: System.schedulers_online(),
    results: rows
  })
)
