defmodule Valimc.WorldItemsTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Entity.{ItemMotionState, Store}
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

  test "a burning item shows the on-fire flag until it goes out (VMC-034n4e)" do
    {:ok, store, {epoch, id, rev}} =
      Store.create(Store.new(), {0, 0}, ItemStack.new("stone"), {0.5, 64, 0.5})

    shown = fn fields ->
      {packet, payload} = Valimc.Protocol.EntityPackets.metadata(id, fields)
      {packet, IO.iodata_to_binary(payload)}
    end

    step = fn rev, extra ->
      Map.merge(
        %{id: id, revision: rev, position: {0.5, 64.0, 0.5}, motion: %ItemMotionState{}},
        extra
      )
    end

    stone = [no_gravity: false, item_stack: ItemStack.new("stone")]

    {:ok, burning, [{_, _, rev}]} =
      Store.advance(store, {0, 0}, epoch, [step.(rev, %{on_fire: true})])

    assert burning.views[id].metadata == shown.([shared_flags: 1] ++ stone)

    # A handoff carries the flag to the next owner.
    {:ok, _, [record]} = Store.withdraw(burning, [{epoch, id, rev}])
    {:ok, arrived, _} = Store.create_record(Store.new(), {0, 0}, record)
    assert arrived.views[id].metadata == burning.views[id].metadata

    # A push names no flag and keeps it; going out sends the cleared flag.
    {:ok, pushed, [{_, _, rev}]} =
      Store.advance(burning, {0, 0}, epoch, [
        step.(rev, %{motion: %ItemMotionState{velocity: {0.1, 0.0, 0.0}}})
      ])

    assert pushed.views[id].metadata == burning.views[id].metadata
    {:ok, out, _} = Store.advance(pushed, {0, 0}, epoch, [step.(rev, %{on_fire: false})])
    assert out.views[id].metadata == shown.([shared_flags: 0] ++ stone)
    assert out.views[id].metadata_revision == burning.views[id].metadata_revision + 1
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
