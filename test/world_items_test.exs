defmodule Valimc.WorldItemsTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Entity.Store
  alias Valimc.World.Region
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

  test "a store holds any number of items and stacks of any accepted size (VMC-077h)" do
    many =
      Enum.reduce(1..300, Store.new(), fn _, items ->
        {:ok, items, _} = Store.create(items, {0, 0}, ItemStack.new("stone"), {0.5, 64, 0.5})
        items
      end)

    assert map_size(many.entries) == 300 and map_size(many.uuids) == 300

    assert {:ok, bulky, {epoch, id, rev}} =
             Store.create(many, {0, 0}, ItemStack.new("egg"), {0, 64, 0})

    assert {:ok, replaced, {^epoch, ^id, next}} = Store.replace(bulky, epoch, id, rev, large())
    assert replaced.entries[id].stack == large()
    assert {:ok, removed} = Store.remove(replaced, epoch, id, next)

    assert map_size(removed.entries) == 300 and
             not Map.has_key?(removed.uuids, replaced.entries[id].entity.uuid)
  end

  test "racing replacements serialize one revision" do
    key = {222, 220}
    {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(key)
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

    assert Enum.count(
             results,
             &(&1 in [{:error, :stale_item}, {:error, {:retry, :item_storage_busy}}])
           ) ==
             31

    id = elem(handle, 2)
    assert Valimc.TestWorld.visible_items(MapSet.new([key]), MapSet.new()) == %{}

    assert Map.has_key?(
             Valimc.TestWorld.visible_items(MapSet.new([key]), MapSet.new([{1776, 1760}])),
             id
           )
  end
end
