defmodule Valimc.CookingRegionRuntimeTest do
  use ExUnit.Case, async: false
  alias Valimc.{Cooking, Inventory, ItemMotionState}
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, Items, RegionData, Store}

  setup do
    nonce = System.unique_integer([:positive])
    key = {86_000 + rem(nonce, 10_000), 1992}
    {rx, rz} = key
    position = {rx * 128 + 40, 64, rz * 128 + 40}
    base = Path.join(System.tmp_dir!(), "valimc-cooking-owned-#{nonce}")

    previous =
      {Valimc.config(:world_path), Valimc.config(:cooking_simulation),
       Valimc.config(:item_simulation)}

    Application.put_env(:valimc, :world_path, base)
    Application.put_env(:valimc, :cooking_simulation, true)
    File.mkdir_p!(base)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, elem(previous, 0))
      Application.put_env(:valimc, :cooking_simulation, elem(previous, 1))
      Application.put_env(:valimc, :item_simulation, elem(previous, 2))

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      File.rm_rf!(base)
    end)

    {:ok, unlit} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, lit} = CookingBlocks.lit(unlit, true)
    %{key: key, base: base, position: position, unlit: unlit, lit: lit}
  end

  defp seed(ctx, cooking, lit \\ true) do
    {:ok, containers, entry} =
      Containers.create_cooking(%Containers{}, ctx.key, ctx.position, :furnace)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, ctx.position, entry.revision, cooking, %{})

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    File.write!(Store.container_path(ctx.base, ctx.key), bytes)
    {rx, rz} = ctx.key

    File.write!(
      Path.join(ctx.base, "r.#{rx}.#{rz}.etf"),
      :erlang.term_to_binary(
        {:valimc_region, 1, %{ctx.position => if(lit, do: ctx.lit, else: ctx.unlit)}}
      )
    )

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
    assert_receive {:resource, ^epoch, {:cooking_plan, ^worker, ^token, _} = message}, 2000
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp saved(state) do
    token = state.item_pending.token
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, message}, 2000
    assert elem(message, 2) == token
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp disk(ctx) do
    {:ok, containers} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

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
      expires: System.monotonic_time(:millisecond) + 250
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
    assert_receive {:resource, ^epoch, {:container_recovery_plan, _, _, _} = message}, 2000
    {:noreply, state} = RegionData.handle_info(message, state)
    state = if state.item_pending, do: saved(state), else: state
    assert state.containers.receipts[source].sequence == 0
    assert pending.kind == :container
    RegionData.terminate(:shutdown, state)
  end

  test "changed block or contents deterministically discard a stale proposal", ctx do
    state = seed(ctx, %Cooking{burn_left: 1, burn_total: 1}) |> start()
    changed = %{state | edits: Map.put(state.edits, ctx.position, ctx.unlit)} |> result()
    assert changed.item_pending == nil and changed.containers == state.containers
    state = %{changed | edits: state.edits} |> start()
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
    state = RegionData.cooking_tick(state, state.cooking.checkpoint_at)
    assert state.item_pending.kind == :cooking_checkpoint
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

    before = state.containers
    pending = state.item_pending

    assert {:stop, {:cooking_storage_failed, :injected}, stopped} =
             RegionData.handle_info(
               {:mining_saved, state.store, pending.token, {:error, :injected}},
               state
             )

    assert stopped.containers == before and stopped.edits == state.edits
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
    assert state.item_pending.kind == :cooking_batch

    assert state.edits[ctx.position] == ctx.lit and
             state.containers.entries[ctx.position].cooking.burn_left == 1

    state = saved(state)

    assert state.edits[ctx.position] == ctx.unlit and
             state.containers.entries[ctx.position].cooking.burn_left == 0

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
    expected = state.item_pending.plan.containers
    assert elem(expected.entries[ctx.position].cooking.slots, 2) == ItemStack.new("iron_ingot")
    RegionData.terminate(:shutdown, state)
    assert disk(ctx) == expected
  end

  test "a late timed-out plan cannot publish or reserve the write lane", ctx do
    state = seed(ctx, progress()) |> start()
    token = state.cooking.job.token
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_plan, _, ^token, _} = late}, 2000
    {:noreply, expired} = RegionData.handle_info({:cooking_deadline, token}, state)
    assert expired.cooking.job == nil and expired.item_pending == nil
    {:noreply, ignored} = RegionData.handle_info(late, expired)
    assert ignored == expired and disk(ctx) == state.containers
    RegionData.terminate(:shutdown, ignored)
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
        {state.containers, state.edits},
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
    File.write!(Store.container_path(ctx.base, ctx.key), bytes)
    {rx, rz} = ctx.key

    File.write!(
      Path.join(ctx.base, "r.#{rx}.#{rz}.etf"),
      :erlang.term_to_binary({:valimc_region, 1, edits})
    )

    Application.put_env(:valimc, :item_simulation, true)
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
      current = :sys.get_state(pid).resource

      Enum.all?(current.containers.entries, fn {_, entry} ->
        Enum.sum(Map.values(entry.recipes)) == 1
      end) and Enum.any?(current.items.entries, fn {_, entry} -> entry.entity.y < 69.9 end)
    end)

    assert Enum.all?(disk(ctx).entries, fn {_, entry} -> map_size(entry.recipes) == 1 end)
  end

  defp eventually(fun, left \\ 100) do
    if fun.(),
      do: :ok,
      else:
        (
          assert left > 0
          Process.sleep(20)
          eventually(fun, left - 1)
        )
  end
end
