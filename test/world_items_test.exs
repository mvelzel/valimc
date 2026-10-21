defmodule Valimc.WorldItemsTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.{Items, Region}
  alias Valimc.Protocol.ItemStack

  defp large do
    %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"large" => {:byte_array, :binary.copy(<<17>>, 60_000)}}}
        }
    }
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

  test "racing replacements serialize one revision" do
    key = {222, 220}
    {:ok, {pid, _} = owner} = World.item_owner(key)
    on_exit(fn -> TestScope.kill(pid) end)
    {:ok, handle} = Region.create_item(owner, ItemStack.new("stone"), {28416, 64, 28160})

    results =
      1..32
      |> Task.async_stream(fn _ -> Region.replace_item(handle, ItemStack.new("egg")) end,
        timeout: 60_000,
        max_concurrency: 32
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &(&1 in [{:error, :stale_item}, {:error, :item_storage_busy}])) ==
             31

    id = elem(handle, 2)
    assert World.visible_items(MapSet.new([key]), MapSet.new()) == %{}
    assert Map.has_key?(World.visible_items(MapSet.new([key]), MapSet.new([{1776, 1760}])), id)
  end
end
