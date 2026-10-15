defmodule Valimc.WorldItemsTest do
  use ExUnit.Case, async: false
  alias Valimc.World
  alias Valimc.World.{Items, Region}
  alias Valimc.Protocol.{ItemStack, Wire}

  defp large do
    %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"large" => {:byte_array, :binary.copy(<<17>>, 60_000)}}}
        }
    }
  end

  test "admission validates owner boundaries and preserves supported patches" do
    initial = Items.new()

    stack = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:custom_data" => {:compound, %{"owner" => {:string, "region"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    assert {:ok, items, {epoch, id, 1}} =
             Items.create(initial, {-1, -1}, stack, {-0.5, 64.25, -128.0})

    assert epoch == initial.epoch
    assert items.views[id].chunk == {-1, -8}
    assert items.entries[id].stack == stack
    {^id, <<5, 8, 1, 8, 7, rest::binary>>} = Wire.take_varint(elem(items.views[id].metadata, 1))
    assert {:ok, ^stack, <<255>>} = ItemStack.take(rest)
    assert {:error, :wrong_region} = Items.create(initial, {0, 0}, stack, {-0.01, 64, 0})

    for position <- [{1.0e100, 64, 0}, {0, :bad, 0}, {0, 64}] do
      assert {:error, :invalid_item_position} = Items.create(initial, {0, 0}, stack, position)
    end

    assert {:error, :empty_item} = Items.create(initial, {0, 0}, nil, {0, 64, 0})
    assert {:error, :empty_item} = Items.create(initial, {0, 0}, ItemStack.new("air"), {0, 64, 0})

    assert {:error, :invalid_item} =
             Items.create(initial, {0, 0}, ItemStack.new("egg", 17), {0, 64, 0})

    assert initial.entries == %{} and initial.bytes == 0
  end

  test "count and aggregate byte limits reject admission and replacement atomically" do
    full =
      Enum.reduce(1..256, Items.new(), fn _, items ->
        {:ok, items, _} = Items.create(items, {0, 0}, ItemStack.new("stone"), {0.5, 64, 0.5})
        items
      end)

    assert {:error, :item_count_limit} =
             Items.create(full, {0, 0}, ItemStack.new("stone"), {0, 64, 0})

    bulky =
      Enum.reduce(1..8, Items.new(), fn _, items ->
        {:ok, items, _} = Items.create(items, {0, 0}, large(), {0, 64, 0})
        items
      end)

    assert {:error, :item_byte_limit} = Items.create(bulky, {0, 0}, large(), {0, 64, 0})

    assert {:ok, bulky, {epoch, id, rev}} =
             Items.create(bulky, {0, 0}, ItemStack.new("egg"), {0, 64, 0})

    assert {:error, :item_byte_limit} = Items.replace(bulky, epoch, id, rev, large())
    assert bulky.entries[id].stack == ItemStack.new("egg")
    assert {:ok, removed} = Items.remove(bulky, epoch, id, rev)
    assert removed.bytes < bulky.bytes
  end

  test "CAS updates retain IDs and reject stale, removed and old-incarnation handles" do
    stone = ItemStack.new("stone", 7)
    assert {:ok, first, {epoch, id, 1}} = Items.create(Items.new(), {0, 0}, stone, {0, 64, 0})
    assert {:ok, ^first, {^epoch, ^id, 1}} = Items.replace(first, epoch, id, 1, stone)

    assert {:ok, second, {^epoch, ^id, 2}} =
             Items.replace(first, epoch, id, 1, ItemStack.new("egg", 3))

    assert second.views[id].spawn == first.views[id].spawn
    assert {:error, :stale_item} = Items.remove(second, epoch, id, 1)
    assert {:error, :stale_item} = Items.replace(second, epoch, id, 1, stone)
    assert {:error, :stale_region} = Items.remove(second, make_ref(), id, 2)
    assert {:ok, empty} = Items.remove(second, epoch, id, 2)
    assert empty.bytes == 0 and empty.views == %{}
    assert {:error, :missing_item} = Items.replace(empty, epoch, id, 2, stone)
    assert {:error, :missing_item} = Items.remove(empty, epoch, id, 2)
  end

  test "protected snapshots read while an owner is suspended; loss fences a replacement" do
    key = {220, 220}
    {:ok, {pid, epoch} = owner} = World.item_owner(key)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    {:ok, {^pid, ^epoch, id, 1} = handle} =
      Region.create_item(owner, ItemStack.new("stone"), {28160, 64, 28160})

    {^pid, _, %{items: table}} = Valimc.World.Directory.lookup(key)
    assert_raise ArgumentError, fn -> :ets.insert(table, {:items, %{}}) end
    :sys.suspend(pid)

    try do
      assert Map.has_key?(World.item_snapshot(key), id)
      {:ok, other} = World.item_owner({221, 220})
      assert {:ok, _} = Region.create_item(other, ItemStack.new("egg"), {28288, 64, 28160})
      DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(other, 0))
    after
      :sys.resume(pid)
    end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert World.item_snapshot(key) == %{}
    assert :ets.info(table) == :undefined
    assert catch_exit(Region.remove_item(handle))
    {:ok, {next, _}} = World.item_owner(key)
    assert {:error, :stale_region} = Region.remove_item({next, epoch, id, 1})
    assert World.item_snapshot(key) == %{}
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, next)
  end

  test "racing replacements serialize one revision and readers do not create missing regions" do
    key = {222, 220}
    {:ok, {pid, _} = owner} = World.item_owner(key)
    on_exit(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid) end)
    {:ok, handle} = Region.create_item(owner, ItemStack.new("stone"), {28416, 64, 28160})

    results =
      1..32
      |> Task.async_stream(fn _ -> Region.replace_item(handle, ItemStack.new("egg")) end,
        max_concurrency: 32
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &(&1 in [{:error, :stale_item}, {:error, :item_storage_busy}])) ==
             31

    before = DynamicSupervisor.count_children(Valimc.RegionSupervisor).active
    assert World.item_snapshot({10000, 10000}) == %{}
    assert World.visible_items(MapSet.new([{10000, 10000}]), MapSet.new([{80000, 80000}])) == %{}
    assert DynamicSupervisor.count_children(Valimc.RegionSupervisor).active == before
    id = elem(handle, 2)
    assert World.visible_items(MapSet.new([key]), MapSet.new()) == %{}
    assert Map.has_key?(World.visible_items(MapSet.new([key]), MapSet.new([{1776, 1760}])), id)
  end
end
