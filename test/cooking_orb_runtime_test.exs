defmodule Valimc.CookingOrbRuntimeTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.CookingAwards

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbRuntime,
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

  defp seed(ctx) do
    {cs, _} = add(%Containers{}, ctx.key, ctx.position)
    {:ok, writer, lease} = Store.open(ctx.key)
    :ok = Store.flush_containers(writer, lease, cs)
    :ok = Store.close(writer, lease)
    RegionData.load(ctx.key)
  end

  defp start(state), do: CookingOrbRuntime.tick(state, System.monotonic_time(:millisecond))

  defp result(state) do
    %{worker: worker, token: token} = state.cooking_orbs.job
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_orb_plan, ^worker, ^token, _} = message}
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp saved(state) do
    token = Valimc.TestRegion.write_token(state)
    epoch = state.items.epoch
    writer = state.store
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, _} = message}
    RegionData.handle_info(message, state)
  end

  defp published(state) do
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
end
