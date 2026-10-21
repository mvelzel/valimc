defmodule Valimc.CookingRegionRuntimeTest do
  # Timing-based flush/clock assertions flake under concurrent load (seen October 20, 2026).
  use ExUnit.Case, async: false
  alias Valimc.TestScope
  alias Valimc.{Cooking, Inventory, ItemMotionState}
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Blocks, Containers, ContainerTransfers, Items, RegionData, Store}

  setup do
    nonce = System.unique_integer([:positive])
    key = {86_000 + rem(nonce, 3_333) * 3, 1992}
    {rx, rz} = key
    position = {rx * 128 + 40, 64, rz * 128 + 40}
    base = Path.join(System.tmp_dir!(), "valimc-cooking-owned-#{nonce}")
    TestScope.isolate(key, world_path: base, cooking_simulation: true)
    File.mkdir_p!(base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, unlit} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, lit} = CookingBlocks.lit(unlit, true)
    %{key: key, base: base, position: position, unlit: unlit, lit: lit}
  end

  defp queued?(state, kind), do: Enum.any?(state.item_writes, &(&1.kind == kind))

  defp seed(ctx, cooking, lit \\ true) do
    {:ok, containers, entry} =
      Containers.create_cooking(%Containers{}, ctx.key, ctx.position, :furnace)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, ctx.position, entry.revision, cooking, %{})

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)

    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{
      ctx.position => if(lit, do: ctx.lit, else: ctx.unlit)
    })

    RegionData.load(ctx.key)
  end

  defp progress,
    do: %Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), nil},
      burn_left: 500,
      burn_total: 1600,
      progress: 10,
      total: 200
    }

  defp start(state), do: RegionData.cooking_tick(state, System.monotonic_time(:millisecond))

  defp result(state) do
    %{worker: worker, token: token} = state.cooking.job
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_plan, ^worker, ^token, _} = message}
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp saved(state) do
    token = Valimc.TestRegion.write_token(state)
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, message}
    assert elem(message, 2) == token
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp published(state, position) do
    {:ok, _, blocks} =
      Valimc.World.BlockSnapshot.read(state.item_publication, state.items.epoch, [position])

    blocks[position]
  end

  defp disk(ctx) do
    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    containers
  end

  test "a live plan leaves item physics free and cannot roll back accepted movement", ctx do
    state = seed(ctx, %{progress() | progress: 199})
    {x, y, z} = ctx.position

    {:ok, items, {epoch, id, revision}} =
      Items.create(state.items, ctx.key, ItemStack.new("stone"), {x + 0.5, y + 2.0, z + 0.5})

    state = start(%{state | items: items})
    assert state.cooking.job != nil and state.item_pending == nil

    step = %{
      id: id,
      revision: revision,
      physical_revision: items.entries[id].physical_revision,
      position: {x + 0.6, y + 2.0, z + 0.5},
      motion: %ItemMotionState{no_gravity: true, velocity: {0.1, 0.0, 0.0}}
    }

    {:reply, {:ok, [_]}, state} =
      RegionData.handle_call(
        {:publish_item_motion, epoch, [step], System.monotonic_time(:millisecond) + 250},
        nil,
        state
      )

    assert state.items.entries[id].entity.x == x + 0.6
    state = state |> result() |> saved()
    assert state.items.epoch == epoch and state.items.entries[id].entity.x == x + 0.6
    assert elem(disk(ctx).entries[ctx.position].cooking.slots, 2) == ItemStack.new("iron_ingot")
    RegionData.terminate(:shutdown, state)
  end

  test "menu admission wins during cooking planning and the old plan cannot overwrite its receipt",
       ctx do
    state = seed(ctx, progress()) |> start()
    entry = state.containers.entries[ctx.position]
    {x, y, z} = ctx.position
    source = <<17::128>>

    request = %{
      source: source,
      sequence: 1,
      permit: <<0::128>>,
      position: ctx.position,
      revision: entry.revision,
      kind: :furnace,
      slots: entry.cooking.slots,
      inventory: %Inventory{carried: ItemStack.new("coal")},
      action: :pickup,
      slot: 1,
      button: 0
    }

    actor = %{
      uuid: source,
      mode: :survival,
      eye: {x + 0.5, y + 1.62, z - 1.0},
      health: 20.0,
      expires: Valimc.TestRegion.grant_expires()
    }

    {:noreply, state} =
      RegionData.handle_call(
        {:admit_container_transfer, state.items.epoch, request, actor},
        {self(), make_ref()},
        state
      )

    assert state.item_pending.kind == :container
    state = result(state)
    assert state.containers.entries[ctx.position].cooking.progress == 10
    pending = state.item_pending
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:container_recovery_plan, _, _, _} = message}
    {:noreply, state} = RegionData.handle_info(message, state)
    state = if state.item_writes != [], do: saved(state), else: state
    assert state.containers.receipts[source].sequence == 0
    assert pending.kind == :container
    RegionData.terminate(:shutdown, state)
  end

  test "changed block or contents deterministically discard a stale proposal", ctx do
    state = seed(ctx, %Cooking{burn_left: 1, burn_total: 1}) |> start()
    original = Blocks.get(state.blocks, ctx.position)
    :ok = Blocks.put(state.blocks, %{ctx.position => ctx.unlit})
    changed = result(state)
    assert changed.item_pending == nil and changed.containers == state.containers
    :ok = Blocks.put(changed.blocks, %{ctx.position => original})
    state = start(changed)
    entry = state.containers.entries[ctx.position]

    {:ok, containers, _} =
      Containers.replace_cooking(state.containers, ctx.position, entry.revision, progress(), %{})

    changed = %{state | containers: containers} |> result()
    assert changed.item_pending == nil and changed.containers == containers
    RegionData.terminate(:shutdown, changed)
  end

  test "timer progress is flushed explicitly before its checkpoint deadline", ctx do
    state = seed(ctx, progress()) |> start() |> result()
    assert state.cooking.dirty and disk(ctx).entries[ctx.position].cooking.progress == 10
    assert state.containers.entries[ctx.position].cooking.progress == 11
    {:reply, :ok, state} = RegionData.handle_call(:flush, nil, state)
    assert disk(ctx) == state.containers and not state.cooking.dirty
    RegionData.terminate(:shutdown, state)
  end

  test "periodic checkpoints acknowledge current timers and failed storage never publishes a proposal",
       ctx do
    state = seed(ctx, progress()) |> start() |> result()
    before = state.containers.entries[ctx.position].cooking.progress

    state = %{
      state
      | cooking: %{state.cooking | checkpoint_at: System.monotonic_time(:millisecond)}
    }

    state = state |> start() |> result()
    assert state.containers.entries[ctx.position].cooking.progress == before + 1
    assert queued?(state, :containers)
    state = saved(state)
    assert not state.cooking.dirty and disk(ctx) == state.containers

    state =
      %{
        state
        | cooking: %{state.cooking | seen: nil},
          containers: %{
            state.containers
            | entries:
                Map.update!(
                  state.containers.entries,
                  ctx.position,
                  &%{&1 | cooking: %{&1.cooking | progress: 199}}
                )
          }
      }
      |> start()
      |> result()

    durable = disk(ctx)
    lit = published(state, ctx.position)

    assert {:stop, {:mining_storage_failed, :injected}, stopped} =
             RegionData.handle_info(
               {:mining_saved, state.store, Valimc.TestRegion.write_token(state),
                {:error, :injected}},
               state
             )

    assert disk(ctx) == durable and published(stopped, ctx.position) == lit
    RegionData.terminate(:injected, stopped)
  end

  test "clean shutdown retains the exact uncheckpointed progress", ctx do
    state = seed(ctx, progress()) |> start() |> result()
    expected = state.containers
    assert disk(ctx) != expected
    RegionData.terminate(:shutdown, state)
    assert disk(ctx) == expected
    reloaded = RegionData.load(ctx.key)
    assert reloaded.containers == expected
    RegionData.terminate(:shutdown, reloaded)
  end

  test "worker-admission backoff does not postpone an overdue timer checkpoint", ctx do
    state = seed(ctx, progress()) |> start() |> result()
    now = System.monotonic_time(:millisecond)

    state = %{
      state
      | cooking: %{state.cooking | seen: nil, retry_at: now + 100, checkpoint_at: now - 1}
    }

    state = RegionData.cooking_tick(state, now)
    assert queued?(state, :containers) and state.cooking.job == nil
    state = saved(state)
    assert disk(ctx) == state.containers and not state.cooking.dirty
    RegionData.terminate(:shutdown, state)
  end

  test "joint changes publish only after acknowledgement and keep viewers on burnout", ctx do
    state = seed(ctx, %Cooking{burn_left: 1, burn_total: 1})

    {:ok, viewers, [], _} =
      Valimc.World.ContainerViewers.register(
        state.container_viewers,
        self(),
        make_ref(),
        Process.monitor(self()),
        ctx.position,
        false,
        state.containers.entries[ctx.position].revision
      )

    state = %{state | container_viewers: viewers} |> start() |> result()
    assert queued?(state, :blocks)
    # Adopted in memory; readers keep the lit furnace until the ACK is handled.
    assert Blocks.get(state.blocks, ctx.position) == ctx.unlit
    assert published(state, ctx.position) == ctx.lit
    state = saved(state)
    assert published(state, ctx.position) == ctx.unlit
    assert disk(ctx).entries[ctx.position].cooking.burn_left == 0

    assert Map.keys(state.container_viewers.views) == Map.keys(viewers.views)
    assert state.container_viewers.views[self()].ref == viewers.views[self()].ref
    state = start(state)
    assert state.cooking.job == nil
    RegionData.terminate(:shutdown, state)
  end

  test "shutdown behind a queued joint write flushes its successor, never older progress", ctx do
    state = seed(ctx, %{progress() | progress: 198}) |> start() |> result()
    assert state.cooking.dirty and state.containers.entries[ctx.position].cooking.progress == 199
    state = state |> start() |> result()
    expected = state.containers
    assert elem(expected.entries[ctx.position].cooking.slots, 2) == ItemStack.new("iron_ingot")
    RegionData.terminate(:shutdown, state)
    assert disk(ctx) == expected
  end

  test "a timer-only write cannot suppress the clean-shutdown item-motion flush", ctx do
    state = seed(ctx, progress())
    {x, y, z} = ctx.position

    {:ok, items, {epoch, id, revision}} =
      Items.create(state.items, ctx.key, ItemStack.new("stone"), {x + 0.5, y + 2.0, z + 0.5})

    :ok = Store.flush_items(state.store, state.store_lease, items, state.item_receipts)

    step = %{
      id: id,
      revision: revision,
      position: {x + 0.6, y + 2.0, z + 0.5},
      motion: %ItemMotionState{no_gravity: true, velocity: {0.1, 0.0, 0.0}}
    }

    {:reply, {:ok, [_]}, state} =
      RegionData.handle_call(
        {:publish_item_motion, epoch, [step], System.monotonic_time(:millisecond) + 250},
        nil,
        %{state | items: items}
      )

    state = state |> start() |> result()

    state = %{
      state
      | cooking: %{state.cooking | checkpoint_at: System.monotonic_time(:millisecond)}
    }

    state = state |> start() |> result()
    assert queued?(state, :containers)
    expected_items = Items.records(state.items)
    RegionData.terminate(:shutdown, state)

    {:ok, stored} =
      Valimc.World.ItemRecords.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)

    assert stored.records == expected_items
    assert disk(ctx) == state.containers
  end

  test "a late timed-out plan cannot publish or reserve the write lane", ctx do
    state = seed(ctx, progress()) |> start()
    token = state.cooking.job.token
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_plan, _, ^token, _} = late}
    {:noreply, expired} = RegionData.handle_info({:cooking_deadline, token}, state)
    assert expired.cooking.job == nil and expired.item_pending == nil
    {:noreply, ignored} = RegionData.handle_info(late, expired)
    assert ignored == expired and disk(ctx) == state.containers
    RegionData.terminate(:shutdown, ignored)
  end

  test "replacement recovers a queued cooking commit once and ignores old-owner callbacks", ctx do
    state = seed(ctx, %{progress() | progress: 199})
    RegionData.terminate(:shutdown, state)
    TestScope.isolate(ctx.key, cooking_simulation: false)
    {:ok, {pid, old_epoch}} = Valimc.World.item_owner(ctx.key)
    :sys.suspend(pid)
    writer = Valimc.TestConn.state(pid).resource.store
    :sys.suspend(writer)

    try do
      :sys.replace_state(pid, fn state ->
        resource = %{state.resource | cooking: %{state.resource.cooking | enabled: true}}
        %{state | resource: start(resource)}
      end)

      :sys.resume(pid)

      eventually(fn -> queued?(Valimc.TestConn.state(pid).resource, :blocks) end)
      resource = Valimc.TestConn.state(pid).resource
      token = Valimc.TestRegion.write_token(resource)
      expected = resource.containers
      assert disk(ctx) != expected
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
      :sys.resume(writer)
      {replacement, epoch} = replacement(ctx.key)
      assert replacement != pid and epoch != old_epoch
      assert disk(ctx) == expected
      assert :sys.get_state(replacement).resource.containers == expected
      send(replacement, {:resource, old_epoch, {:mining_saved, writer, token, :ok}})
      assert :sys.get_state(replacement).resource.containers == expected
      entry = expected.entries[ctx.position]
      assert elem(entry.cooking.slots, 0) == ItemStack.new("raw_iron")
      assert elem(entry.cooking.slots, 2) == ItemStack.new("iron_ingot")
      assert Enum.sum(Map.values(entry.recipes)) == 1
    after
      if Process.alive?(pid), do: :sys.resume(pid)
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  defp replacement(key, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      case Valimc.World.item_owner(key) do
        {:ok, owner} -> owner
        {:error, _} -> nil
      end
    end)
  end

  test "a cold live owner and its replacement retain pending awards through clock and flush",
       ctx do
    cooking = %Cooking{slots: {nil, nil, ItemStack.new("iron_ingot", 4)}, total: 200}
    state = seed(ctx, cooking, false)
    entry = state.containers.entries[ctx.position]
    recipe = "minecraft:iron_ingot_from_smelting_raw_iron"
    source = <<103::128>>

    {:ok, cs, entry} =
      Containers.replace_cooking(state.containers, ctx.position, entry.revision, cooking, %{
        recipe => 7
      })

    {:ok, cs, _} = ContainerTransfers.reserve(cs, source)

    request = %{
      source: source,
      sequence: 1,
      permit: <<104::128>>,
      position: ctx.position,
      revision: entry.revision,
      kind: :furnace,
      slots: cooking.slots,
      inventory: %Inventory{},
      action: :pickup,
      slot: 2,
      button: 1
    }

    {x, y, z} = ctx.position
    context = %{position: {x + 0.5, y * 1.0, z + 0.5}, draws: %{recipe => 0}}

    {:ok, %{containers: committed, result: :applied}} =
      ContainerTransfers.plan_cooking_award(cs, ctx.key, request, true, context)

    assert :ok = Store.flush_containers(state.store, state.store_lease, committed)
    RegionData.terminate(:shutdown, %{state | containers: committed})
    {:ok, {pid, old_epoch}} = Valimc.World.item_owner(ctx.key)

    assert Valimc.TestConn.state(pid).resource.containers.pending_awards ==
             committed.pending_awards

    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    {replacement, epoch} = replacement(ctx.key)
    assert replacement != pid and epoch != old_epoch
    [id] = Map.keys(committed.pending_awards)

    {:ok, materialized, :materialized} =
      Valimc.World.CookingOrbs.materialize(committed, ctx.key, id)

    eventually(fn ->
      current = :sys.get_state(replacement).resource
      current.containers == materialized and current.item_pending == nil
    end)

    send(replacement, {:resource, old_epoch, {:containers_saved, state.store, make_ref(), :ok}})
    # A write still in flight answers busy; the flush itself must then succeed.
    Valimc.TestWait.until(fn -> Valimc.World.Region.flush(replacement) == :ok end)
    assert disk(ctx) == materialized
  end

  test "the actual region clock cooks all families while dropped-item physics advances", ctx do
    state = seed(ctx, %{progress() | progress: 199})
    RegionData.terminate(:shutdown, state)
    {x, y, z} = ctx.position

    {containers, edits} =
      Enum.reduce(
        [
          {1, :smoker, "cod"},
          {2, :blast_furnace, "raw_iron"}
        ],
        {state.containers, Blocks.image(state.blocks)},
        fn {offset, kind, input}, {containers, edits} ->
          position = {x + offset, y, z}

          {:ok, containers, entry} =
            Containers.create_cooking(containers, ctx.key, position, kind)

          {:ok, containers, _} =
            Containers.replace_cooking(
              containers,
              position,
              entry.revision,
              %Cooking{
                slots: {ItemStack.new(input, 2), ItemStack.new("coal", 2), nil},
                burn_left: 500,
                burn_total: 800,
                progress: 99,
                total: 100,
                speed: 2.0
              },
              %{}
            )

          {:ok, block} = CookingBlocks.placement(kind, 0.0)
          {:ok, lit} = CookingBlocks.lit(block, true)
          {containers, Map.put(edits, position, lit)}
        end
      )

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, edits)

    TestScope.isolate(ctx.key, item_simulation: true)
    {:ok, {pid, _} = owner} = Valimc.World.item_owner(ctx.key)

    record = %{
      uuid: <<81::128>>,
      x: x + 5.5,
      y: 70.0,
      z: z + 0.5,
      stack: ItemStack.new("stone"),
      motion: %ItemMotionState{pickup_delay: 100}
    }

    assert {:ok, :applied} =
             Valimc.World.Region.apply_item_transfer(
               owner,
               %{source: <<82::128>>, sequence: 1, records: [record]}
             )

    eventually(fn ->
      current = Valimc.TestConn.state(pid).resource

      Enum.all?(current.containers.entries, fn {_, entry} ->
        Enum.sum(Map.values(entry.recipes)) == 1
      end) and Enum.any?(current.items.entries, fn {_, entry} -> entry.entity.y < 69.9 end)
    end)

    assert Enum.all?(disk(ctx).entries, fn {_, entry} -> map_size(entry.recipes) == 1 end)
  end

  defp eventually(fun, _budget \\ nil) do
    Valimc.TestWait.until(fun)
    :ok
  end
end
