defmodule Valimc.CookingOrbRuntimeTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{CookingAwards, ItemMotionState}
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbRuntime,
    CookingOrbBodies,
    Items,
    PendingCookingAwards,
    RegionData,
    Store
  }

  @gold "minecraft:gold_ingot_from_smelting_gold_ore"
  @iron "minecraft:iron_ingot_from_smelting_raw_iron"
  @source <<31::128>>

  setup :scope

  def scope(_context) do
    nonce = System.unique_integer([:positive])
    key = {91_000 + rem(nonce, 1666) * 3, 2091}
    {rx, rz} = key
    position = {rx * 128 + 2.5, 64.5, rz * 128 + 2.5}
    base = Path.join(System.tmp_dir!(), "valimc-orbs-#{nonce}")
    TestScope.isolate(TestScope.neighborhood(key), world_path: base)
    File.mkdir_p!(base)

    on_exit(fn ->
      # Transfers start neighbouring owners too; none may still write into `base`.
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          neighbour <- TestScope.neighborhood(key),
          {pid, _} <- Registry.lookup(reg, neighbour),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, position: position, base: base}
  end

  defp queued?(state, kind), do: Enum.any?(state.item_writes, &(&1.kind == kind))

  defp add(cs, key, position, uses \\ %{@gold => 3, @iron => 5}, draws \\ %{@iron => 0}) do
    n = map_size(cs.pending_awards) + 1
    digest = :crypto.hash(:sha256, <<n::32>>)
    {:ok, award} = CookingAwards.plan(uses, draws)

    {:ok, awards, id} =
      PendingCookingAwards.put(cs.pending_awards, key, @source, n, digest, position, award)

    {%{
       cs
       | pending_awards: awards,
         receipts: %{
           @source => %{sequence: n, digest: ContainerTransfers.result_digest(digest, :applied)}
         }
     }, id}
  end

  def seed(ctx, remote \\ false) do
    {x, y, z} = ctx.position
    position = if remote, do: {x + 128, y, z}, else: ctx.position
    {cs, _} = add(%Containers{}, ctx.key, position)
    {:ok, writer, lease} = Store.open(ctx.key)
    :ok = Store.flush_containers(writer, lease, cs)
    :ok = Store.close(writer, lease)
    RegionData.load(ctx.key)
  end

  def start(state), do: CookingOrbRuntime.tick(state, System.monotonic_time(:millisecond))

  defp result(state) do
    %{worker: worker, token: token} = state.cooking_orbs.job
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_orb_plan, ^worker, ^token, _} = message}, 3000
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp saved(state) do
    token = Valimc.TestRegion.write_token(state)
    epoch = state.items.epoch
    writer = state.store
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, _} = message}, 3000
    RegionData.handle_info(message, state)
  end

  def published(state) do
    Valimc.World.EntityPublication.source(state.item_publication, :orbs)
  end

  defp disk(ctx) do
    {:ok, state} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    state
  end

  test "planning leaves admission free and even a completed proposal is invisible until durable ACK",
       ctx do
    state = seed(ctx) |> start()
    assert state.cooking_orbs.job != nil and state.item_pending == nil
    assert published(state) == %{}
    :sys.suspend(state.store)

    try do
      proposed = result(state)
      assert queued?(proposed, :containers)
      # Adopted in owner memory; nothing is published or on disk before the ACK.
      assert map_size(proposed.containers.cooking_orbs) == 1 and published(proposed) == %{}
      assert disk(ctx).cooking_orbs == %{}
      :sys.resume(state.store)
      assert {:noreply, installed} = saved(proposed)
      assert installed.containers == disk(ctx)
      assert installed.containers.pending_awards == state.containers.pending_awards
      views = published(installed)
      assert Enum.sort(for {_, v} <- views, do: {v.value, v.count}) == [{1, 1}, {3, 2}]

      assert Enum.all?(views, fn {_, v} ->
               v.epoch == state.items.epoch and v.at == ctx.position
             end)

      assert start(installed).cooking_orbs.job == nil
      RegionData.terminate(:shutdown, installed)
    after
      if Process.alive?(state.store), do: :sys.resume(state.store)
    end
  end

  test "orbs age with the region tick and despawn durably at 6000 ticks", ctx do
    {:noreply, installed} = seed(ctx) |> start() |> result() |> saved()
    assert map_size(published(installed)) == 2

    # Ages accumulate in memory; no write until one reaches 6000 (or 30 s pass).
    aging = Enum.reduce(1..5, installed, fn _, s -> RegionData.orb_lifetime(s) end)
    assert aging.orb_age_ticks == 5 and aging.item_writes == []

    expiring = RegionData.orb_lifetime(%{aging | orb_age_ticks: 5999})
    assert expiring.orb_age_ticks == 0 and expiring.item_writes != []
    assert published(expiring) == published(installed)
    {:noreply, durable} = saved(expiring)
    assert disk(ctx) == durable.containers

    assert Valimc.World.CookingOrbBodies.project(durable.containers)
           |> Enum.all?(fn {_, r} -> r == %{} end)

    # The orb runtime republishes after the body revision changed: nothing left.
    refreshed = durable |> start() |> result()
    assert published(refreshed) == %{}
    RegionData.terminate(:shutdown, refreshed)
  end

  test "imported vanilla orbs publish at their bodies, keep their UUIDs and expire", ctx do
    {x, y, z} = ctx.position

    orbs =
      for {value, n} <- Enum.with_index([7, 3, 17], 1) do
        %{
          uuid: <<n::128>>,
          position: {x + n, y, z},
          velocity: {0.0, 0.0, 0.0},
          age: 100 * n,
          value: value,
          count: n,
          on_ground: true,
          no_gravity: false
        }
      end

    {:ok, cs, []} = Valimc.World.CookingOrbs.import_orbs(%Containers{}, ctx.key, orbs)

    {:ok, ^cs} =
      Containers.encode(ctx.key, cs) |> then(fn {:ok, b} -> Containers.decode(b, ctx.key) end)

    {:ok, writer, lease} = Store.open(ctx.key)
    :ok = Store.flush_containers(writer, lease, cs)
    :ok = Store.close(writer, lease)

    state = RegionData.load(ctx.key) |> start() |> result()
    views = published(state) |> Map.values()
    assert length(views) == 3

    assert Enum.sort(Enum.map(views, &{&1.at, &1.value, &1.count})) ==
             Enum.sort(for o <- orbs, do: {o.position, o.value, o.count})

    assert Valimc.World.CookingOrbConsumptions.births(state.containers)
           |> Map.keys()
           |> Enum.sort() ==
             Enum.map(orbs, & &1.uuid)

    expiring = RegionData.orb_lifetime(%{state | orb_age_ticks: 5999})
    {:noreply, durable} = saved(expiring)
    # Ages 100, 200 and 300 plus 6,000 ticks: every orb has expired.
    assert CookingOrbBodies.project(durable.containers) |> Enum.all?(fn {_, r} -> r == %{} end)
    RegionData.terminate(:shutdown, durable)
  end

  test "rebase preserves concurrent slots, timers, receipts and new awards", ctx do
    state = seed(ctx) |> start()
    {x, _, z} = ctx.position
    pos = {floor(x), 64, floor(z)}
    {:ok, cs, entry} = Containers.create_cooking(state.containers, ctx.key, pos, :furnace)
    cooking = %Valimc.Cooking{slots: {ItemStack.new("raw_iron"), nil, nil}, progress: 17}
    {:ok, cs, _} = Containers.replace_cooking(cs, pos, entry.revision, cooking, %{})
    {cs, _} = add(cs, ctx.key, {x + 1, 64.5, z})
    current = %{state | containers: cs, cooking: %{state.cooking | dirty: true}}
    proposed = result(current)
    assert proposed.containers.entries == cs.entries and published(proposed) == %{}
    {:noreply, installed} = saved(proposed)
    assert installed.containers.entries == cs.entries
    assert installed.containers.receipts == cs.receipts
    assert installed.containers.pending_awards == cs.pending_awards
    assert map_size(installed.containers.cooking_orbs) == 1
    assert not installed.cooking.dirty and disk(ctx) == installed.containers
    ids = Map.keys(installed.cooking_orbs.views) |> MapSet.new()
    {:noreply, all} = installed |> start() |> result() |> saved()
    assert MapSet.subset?(ids, MapSet.new(Map.keys(all.cooking_orbs.views)))
    assert map_size(all.containers.cooking_orbs) == 2
    RegionData.terminate(:shutdown, all)
  end

  test "remote poses acquire a durable route without source entities; a later local award wakes the owner",
       ctx do
    state = seed(ctx, true) |> start() |> result()
    assert queued?(state, :containers) and published(state) == %{}
    {:noreply, state} = saved(state)
    assert state.cooking_orbs.job == nil and state.item_pending == nil
    assert published(state) == %{}
    assert Map.values(state.containers.orb_transfers.outgoing) == [:pending]

    for offset <- [50, 1000, 10000],
        do:
          assert(
            CookingOrbRuntime.tick(state, System.monotonic_time(:millisecond) + offset).cooking_orbs.job ==
              nil
          )

    {cs, _} = add(state.containers, ctx.key, ctx.position)
    {:noreply, installed} = %{state | containers: cs} |> start() |> result() |> saved()
    assert map_size(installed.containers.pending_awards) == 2
    assert map_size(installed.containers.cooking_orbs) == 1
    state = start(installed)
    assert state.cooking_orbs.job == nil and start(state).cooking_orbs.job == nil
    RegionData.terminate(:shutdown, state)
  end

  test "stored poses preserve entity IDs and late publication cannot revive durably expired bodies",
       ctx do
    {:noreply, state} = seed(ctx) |> start() |> result() |> saved()
    before = published(state)
    [id] = Map.keys(state.containers.cooking_orbs)

    decisions =
      for {uuid, _} <- state.containers.cooking_orbs[id],
          into: %{},
          do: {uuid, {{0, 0, 0}, {0.2, 0.7, 0.9}}}

    {:ok, p} = CookingOrbBodies.initialize(state.containers, ctx.key, id, decisions)
    {:ok, cs, :applied} = CookingOrbBodies.install(state.containers, ctx.key, p)
    {x, y, z} = ctx.position

    updates =
      for {uuid, row} <- cs.orb_bodies.awards[id],
          into: %{},
          do:
            {uuid,
             %{
               expected_revision: row.revision,
               position: {x + 20, y, z},
               velocity: row.velocity,
               age: 5999,
               on_ground: true
             }}

    {:ok, p} = CookingOrbBodies.checkpoint(cs, ctx.key, updates)
    {:ok, moved, :applied} = CookingOrbBodies.install(cs, ctx.key, p)
    assert :ok = Store.flush_containers(state.store, state.store_lease, moved)
    state = %{state | containers: moved} |> start() |> result()
    after_move = published(state)
    assert Map.keys(after_move) |> Enum.sort() == Map.keys(before) |> Enum.sort()

    assert Enum.all?(after_move, fn {eid, v} ->
             v.at == {x + 20, y, z} and
               v.motion_revision > before[eid].motion_revision
           end)

    assert :ets.lookup(state.item_publication, {:orbs, Valimc.World.chunk_key(x, z)}) == []

    # Start a valid refresh, then commit expiry before its old worker reply arrives.
    state = put_in(state.cooking_orbs.body_revision, -1) |> start()

    updates =
      for {uuid, row} <- moved.orb_bodies.awards[id],
          into: %{},
          do:
            {uuid,
             %{
               expected_revision: row.revision,
               position: row.position,
               velocity: row.velocity,
               age: 6000,
               on_ground: true
             }}

    {:ok, p} = CookingOrbBodies.checkpoint(moved, ctx.key, updates)
    {:ok, expired, :applied} = CookingOrbBodies.install(moved, ctx.key, p)
    assert :ok = Store.flush_containers(state.store, state.store_lease, expired)
    state = result(%{state | containers: expired})
    assert published(state) == after_move
    state = put_in(state.cooking_orbs.retry_at, nil) |> start() |> result()

    assert published(state) == %{} and
             state.cooking_orbs.body_revision == expired.orb_bodies.revision

    assert start(state).cooking_orbs.job == nil
    RegionData.terminate(:shutdown, state)
    cold = RegionData.load(ctx.key) |> start() |> result()
    assert cold.containers == expired and published(cold) == %{} and disk(ctx) == expired
    RegionData.terminate(:shutdown, cold)
  end

  test "late, failed and busy planning cannot publish or clobber another operation", ctx do
    state = seed(ctx) |> start()
    job = state.cooking_orbs.job
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_orb_plan, _, _, _} = late}, 3000
    {:noreply, expired} = RegionData.handle_info({:cooking_orb_deadline, job.token}, state)
    assert expired.cooking_orbs.job == nil and expired.item_pending == nil
    assert {:noreply, ^expired} = RegionData.handle_info(late, expired)
    assert published(expired) == %{}
    state = put_in(expired.cooking_orbs.retry_at, nil) |> start()
    job = state.cooking_orbs.job

    {:noreply, failed} =
      RegionData.handle_info({:DOWN, job.monitor, :process, job.worker, :injected}, state)

    assert failed.cooking_orbs.job == nil and published(failed) == %{}
    state = put_in(failed.cooking_orbs.retry_at, nil) |> start()
    busy = %{kind: :unrelated, phase: :writing}
    next = result(%{state | item_pending: busy})
    assert next.item_pending == busy and published(next) == %{}
    RegionData.terminate(:shutdown, %{next | item_pending: nil})
  end

  test "I/O failure exposes no orb and retires the owner instead of acknowledging XP", ctx do
    state = seed(ctx) |> start()
    Valimc.TestDisk.break_writer(state.store)
    state = result(state)
    assert {:stop, {:container_storage_failed, _}, stopped} = saved(state)
    assert published(stopped) == %{} and disk(ctx).cooking_orbs == %{}
    RegionData.terminate(:injected, stopped)
  end

  test "writer death after durability but before ACK restores exactly one unpublished materialization",
       ctx do
    state = seed(ctx) |> start() |> result()
    token = Valimc.TestRegion.write_token(state)
    assert {:ok, committed} = Store.load_containers(state.store)
    assert committed == state.containers and published(state) == %{}
    writer = state.store
    monitor = state.store_monitor
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed} = down
    assert {:stop, {:store_failed, :killed}, stopped} = RegionData.handle_info(down, state)
    assert published(stopped) == %{}
    RegionData.terminate(:injected, stopped)
    restored = RegionData.load(ctx.key) |> start() |> result()
    assert restored.item_pending == nil and restored.containers == committed
    assert map_size(published(restored)) == 2 and disk(ctx) == committed

    assert {:noreply, ^restored} =
             RegionData.handle_info({:containers_saved, writer, token, :ok}, restored)

    assert start(restored).cooking_orbs.job == nil
    RegionData.terminate(:shutdown, restored)
  end

  test "stale storage lease rejects an otherwise valid plan without publishing", ctx do
    state = seed(ctx) |> start()
    {:ok, current} = Store.load_containers(state.store)
    state = result(%{state | store_lease: make_ref()})
    assert {:stop, {:container_storage_failed, :stale_store_lease}, stopped} = saved(state)
    assert published(stopped) == %{} and disk(ctx) == current
    RegionData.terminate(:injected, stopped)
  end

  test "zero XP durably marks the award and retains recipe delivery without an entity", ctx do
    recipe = "minecraft:smooth_stone"
    {cs, id} = add(%Containers{}, ctx.key, ctx.position, %{recipe => 1}, %{recipe => 16_777_215})
    {:ok, writer, lease} = Store.open(ctx.key)
    :ok = Store.flush_containers(writer, lease, cs)
    :ok = Store.close(writer, lease)
    state = RegionData.load(ctx.key) |> start() |> result()
    assert queued?(state, :containers)
    {:noreply, installed} = saved(state)
    assert installed.containers.cooking_orbs == %{id => %{}}
    assert installed.containers.pending_awards == cs.pending_awards
    assert installed.containers == disk(ctx) and published(installed) == %{}
    assert start(installed).cooking_orbs.job == nil
    RegionData.terminate(:shutdown, installed)
  end

  test "shared capacity may fill during planning; the refusal preserves the pending award",
       ctx do
    state = seed(ctx) |> start()
    full = fill_snapshot(state.containers, ctx)
    assert :ok = Store.flush_containers(state.store, state.store_lease, full)
    # An unstorable snapshot is refused before adoption, so nothing is queued.
    refused = result(%{state | containers: full})
    assert not queued?(refused, :containers) and refused.containers == full
    assert refused.containers.cooking_orbs == %{} and published(refused) == %{}
    assert disk(ctx) == full and start(refused).cooking_orbs.job == nil
    RegionData.terminate(:shutdown, refused)
  end

  test "destination shared-byte refusal keeps the durable source intent and later retry adopts once",
       ctx do
    alias Valimc.World.CookingOrbTransfers
    state = seed(ctx)
    {rx, rz} = ctx.key
    source_key = {rx - 1, rz}
    {source, id} = add(%Containers{}, source_key, ctx.position)
    {:ok, routed, request, _} = CookingOrbTransfers.prepare(source, source_key, id)
    {:ok, writer, lease} = Store.open(source_key)
    :ok = Store.flush_containers(writer, lease, routed)
    :ok = Store.close(writer, lease)
    {:ok, bytes} = CookingOrbTransfers.encode_request(request)
    tag = make_ref()

    {:noreply, state} =
      CookingOrbRuntime.adopt(
        state,
        state.items.epoch,
        bytes,
        System.monotonic_time(:millisecond) + 6000,
        {self(), tag}
      )

    full = fill_snapshot(state.containers, ctx)
    :ok = Store.flush_containers(state.store, state.store_lease, full)
    refused = result(%{state | containers: full})
    assert_receive {^tag, {:error, :cooking_orb_transfer_capacity}}
    assert refused.containers == full and published(refused) == %{}
    pos = Enum.min(Map.keys(full.entries))
    entry = full.entries[pos]

    {:ok, available, _} =
      Containers.replace(full, pos, entry.revision, put_elem(entry.slots, 0, nil))

    :ok = Store.flush_containers(refused.store, refused.store_lease, available)
    tag = make_ref()
    state = %{refused | containers: available}

    {:noreply, state} =
      CookingOrbRuntime.adopt(
        state,
        state.items.epoch,
        bytes,
        System.monotonic_time(:millisecond) + 6000,
        {self(), tag}
      )

    {:noreply, accepted} = state |> result() |> saved()
    assert_receive {^tag, {:ok, :applied}}
    assert map_size(accepted.containers.orb_transfers.incoming) == 1
    assert map_size(published(accepted)) == 2
    source_bytes = Valimc.TestDisk.read(ctx.base, source_key, :containers)
    assert {:ok, ^routed} = Containers.decode(source_bytes, source_key)
    RegionData.terminate(:shutdown, accepted)
  end

  test "shutdown behind a capacity refusal still flushes current uncheckpointed cooking timers",
       ctx do
    state = seed(ctx) |> start()
    {x, _, z} = ctx.position
    pos = {floor(x), 64, floor(z)}
    {:ok, cs, entry} = Containers.create_cooking(state.containers, ctx.key, pos, :furnace)
    full = fill_snapshot(cs, ctx)
    :ok = Store.flush_containers(state.store, state.store_lease, full)

    {:ok, current, _} =
      Containers.replace_cooking(full, pos, entry.revision, %Valimc.Cooking{progress: 17}, %{})

    state = %{state | containers: current, cooking: %{state.cooking | dirty: true}} |> result()
    assert not queued?(state, :containers) and published(state) == %{}
    RegionData.terminate(:shutdown, state)
    assert disk(ctx) == current
    assert disk(ctx).entries[pos].cooking.progress == 17
  end

  test "shutdown behind the queued write preserves its successor and pending item motion", ctx do
    state = seed(ctx)

    {:ok, items, {epoch, id, revision}} =
      Items.create(state.items, ctx.key, ItemStack.new("stone"), ctx.position)

    :ok = Store.flush_items(state.store, state.store_lease, items, state.item_receipts)
    {x, y, z} = ctx.position

    step = %{
      id: id,
      revision: revision,
      position: {x + 0.1, y, z},
      motion: %ItemMotionState{no_gravity: true}
    }

    {:reply, {:ok, [_]}, state} =
      RegionData.handle_call(
        {:publish_item_motion, epoch, [step], System.monotonic_time(:millisecond) + 250},
        nil,
        %{state | items: items}
      )

    state = %{state | cooking: %{state.cooking | dirty: true}} |> start() |> result()
    expected = state.containers
    RegionData.terminate(:shutdown, state)
    assert disk(ctx) == expected

    {:ok, stored} =
      Valimc.World.ItemRecords.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)

    assert stored.records == Items.records(state.items)
  end

  test "cold ownership republishes durable UUIDs with new network IDs and rejects old epochs",
       ctx do
    state = seed(ctx)
    expected = state.containers.pending_awards
    RegionData.terminate(:shutdown, state)
    {:ok, {pid, epoch}} = Valimc.World.item_owner(ctx.key)
    eventually(fn -> map_size(Valimc.TestConn.state(pid).resource.cooking_orbs.views) == 2 end)
    first = Valimc.TestConn.state(pid).resource
    assert first.containers.pending_awards == expected
    assert disk(ctx) == first.containers
    {x, _, z} = ctx.position
    chunk = Valimc.World.chunk_key(x, z)
    assert Valimc.World.orb_snapshot(chunk) == first.cooking_orbs.views
    assert Valimc.World.visible_orbs(MapSet.new([ctx.key]), MapSet.new()) == %{}
    assert Valimc.World.visible_orbs(MapSet.new(), MapSet.new([chunk])) == %{}

    assert Valimc.World.visible_orbs(MapSet.new([ctx.key]), MapSet.new([chunk])) ==
             first.cooking_orbs.views

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    eventually(fn ->
      case Valimc.World.item_owner(ctx.key) do
        {:ok, {next, _}} when next != pid -> next
        _ -> false
      end
    end)

    {:ok, {replacement, new_epoch}} = Valimc.World.item_owner(ctx.key)
    eventually(fn -> map_size(:sys.get_state(replacement).resource.cooking_orbs.views) == 2 end)
    restored = :sys.get_state(replacement).resource
    assert new_epoch != epoch
    assert restored.containers == first.containers

    assert MapSet.new(for {_, v} <- restored.cooking_orbs.views, do: v.uuid) ==
             MapSet.new(for {_, v} <- first.cooking_orbs.views, do: v.uuid)

    assert MapSet.disjoint?(
             MapSet.new(Map.keys(restored.cooking_orbs.views)),
             MapSet.new(Map.keys(first.cooking_orbs.views))
           )

    send(replacement, {:resource, epoch, {:containers_saved, restored.store, make_ref(), :ok}})
    assert :ok = Valimc.World.Region.flush(replacement)
    assert disk(ctx) == first.containers
  end

  defp eventually(fun, left \\ 200) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end

  defp fill_snapshot(cs, ctx) do
    stack = fn length ->
      %{
        ItemStack.new("stone")
        | components: %{
            "minecraft:custom_data" =>
              {:compound, %{"payload" => {:string, String.duplicate("x", length)}}}
          }
      }
    end

    {x, _, z} = ctx.position
    large = stack.(30_000)

    entries =
      for i <- 1..17, into: %{} do
        count = if i == 17, do: 7, else: 17
        slots = List.to_tuple(List.duplicate(large, count) ++ List.duplicate(nil, 27 - count))
        {{floor(x) + i, 64, floor(z)}, %{revision: cs.sequence + i, rows: 3, slots: slots}}
      end

    cs = %{cs | sequence: cs.sequence + 17, entries: Map.merge(cs.entries, entries)}
    {:ok, bytes} = Containers.encode(ctx.key, cs)
    overhead = IO.iodata_length(ItemStack.encode(stack.(0))) - 1
    length = Containers.max_bytes() - byte_size(bytes) - overhead - 1
    assert length in 1..30_000
    pos = {floor(x) + 17, 64, floor(z)}
    next = put_in(cs.entries[pos].slots, put_elem(cs.entries[pos].slots, 7, stack.(length)))
    {:ok, bytes} = Containers.encode(ctx.key, next)
    assert byte_size(bytes) == Containers.max_bytes() - 1
    next
  end
end

defmodule Valimc.CookingOrbRuntimeTest.Serial do
  use ExUnit.Case, async: false
  # Serial: saturates a global worker pool that concurrent owners also use.
  import Valimc.CookingOrbRuntimeTest, only: [seed: 1, start: 1, published: 1]
  alias Valimc.World.RegionData

  setup {Valimc.CookingOrbRuntimeTest, :scope}

  test "bounded worker saturation backs off without reserving gameplay storage", ctx do
    state = seed(ctx)

    workers =
      for _ <- 1..System.schedulers_online() do
        {:ok, pid} =
          Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
            receive do
              :finish -> :ok
            end
          end)

        pid
      end

    try do
      next = start(state)
      assert next.cooking_orbs.job == nil and next.item_pending == nil
      assert next.cooking_orbs.retry_at > System.monotonic_time(:millisecond)
      assert published(next) == %{}
    after
      for pid <- workers, do: send(pid, :finish)
      RegionData.terminate(:shutdown, state)
    end
  end
end
