defmodule Valimc.ItemStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region
  alias Valimc.Protocol.ItemStack
  import ExUnit.CaptureLog

  setup :scope

  def scope(_context) do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-items-#{nonce}")
    key = {230 + rem(nonce, 3_333) * 3, 230}
    TestScope.isolate(key, world_path: base)
    {:ok, {pid, _} = owner} = World.item_owner(key)

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    {rx, rz} = key

    %{
      base: base,
      key: key,
      pid: pid,
      owner: owner,
      position: {rx * 128 + 0.5, 64.5, rz * 128 + 0.5}
    }
  end

  defp seed(ctx) do
    stone = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:custom_data" => {:compound, %{"save" => {:string, "region"}}}},
        removed: MapSet.new(["minecraft:rarity"])
    }

    {:ok, handle} = Region.create_item(ctx.owner, stone, ctx.position)
    view = World.item_snapshot(ctx.key)[elem(handle, 2)]
    {handle, view.uuid, stone}
  end

  # What was flushed survives the owner's death, however it dies.
  defp replace_owner(ctx, reason \\ :kill) do
    :ok = Region.flush(ctx.pid)
    ref = Process.monitor(ctx.pid)

    if reason == :kill,
      do: Process.exit(ctx.pid, :kill),
      else: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)

    assert_receive {:DOWN, ^ref, :process, _, _}
    {:ok, owner} = World.item_owner(ctx.key)
    owner
  end

  test "flushed create/replace/remove survive owner replacement with UUID and fresh handles",
       ctx do
    {handle, uuid, _stone} = seed(ctx)
    egg = ItemStack.new("egg", 3)
    {:ok, updated} = Region.replace_item(handle, egg)
    owner = replace_owner(ctx)
    assert {:ok, current} = Region.find_item(owner, uuid)
    assert elem(current, 2) != elem(updated, 2) and elem(current, 1) != elem(updated, 1)

    assert {:error, {:retry, :stale_owner}} =
             Region.remove_item(
               {elem(owner, 0), elem(updated, 1), elem(updated, 2), elem(updated, 3)}
             )

    assert :sys.get_state(elem(owner, 0)).resource.entities.items.entries[elem(current, 2)].stack ==
             egg

    assert :ok = Region.remove_item(current)
    next = replace_owner(%{ctx | pid: elem(owner, 0)}, :shutdown)
    assert {:error, :missing_item} = Region.find_item(next, uuid)
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "a log failure stops the owner, which reloads the durable state", ctx do
    {handle, uuid, stone} = seed(ctx)
    :ok = Region.flush(ctx.pid)
    old = disk(ctx)
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(stripe)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      assert {:ok, _} = Region.replace_item(handle, ItemStack.new("egg", 3))

      Valimc.TestWait.until(fn ->
        Valimc.TestRegion.in_flight?(Valimc.TestConn.state(ctx.pid).resource)
      end)

      Process.exit(stripe, :kill)
      assert_receive {:DOWN, ^ref, :process, _, {:storage_failed, _}}
    end)

    assert disk(ctx) == old
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)

    assert :sys.get_state(elem(owner, 0)).resource.entities.items.entries[elem(current, 2)].stack ==
             stone

    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "a corrupt checkpoint is preserved and prevents only its region from loading", ctx do
    seed(ctx)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    Valimc.TestDisk.corrupt(ctx.base, ctx.key)

    capture_log(fn ->
      assert {:error, _} = World.item_owner(ctx.key)
    end)

    assert World.item_snapshot(ctx.key) == %{} and disk(ctx) == :corrupt
    {rx, rz} = ctx.key
    {:ok, healthy} = World.item_owner({rx + 1, rz})

    assert {:ok, _} =
             Region.create_item(healthy, ItemStack.new("stone"), {(rx + 1) * 128, 64, rz * 128})

    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(healthy, 0))
  end

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  def transfer(ctx, sequence \\ 1) do
    {x, y, z} = ctx.position
    record = %{uuid: <<sequence::128>>, x: x, y: y, z: z, stack: ItemStack.new("stone", 7)}
    %{source: <<99::128>>, sequence: sequence, records: [record]}
  end
end
