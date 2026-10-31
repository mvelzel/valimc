defmodule Valimc.ItemSpillTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{ItemSpill, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Explosion

  test "a destroyed block item spills its container, a bundle its contents, others nothing" do
    box = %{
      ItemStack.new("shulker_box")
      | components: %{
          "minecraft:container" => [nil, ItemStack.new("stone", 5), ItemStack.new("dirt", 2)]
        }
    }

    bundle = %{
      ItemStack.new("red_bundle")
      | components: %{"minecraft:bundle_contents" => [ItemStack.new("arrow", 3)]}
    }

    assert ItemSpill.contents(box) == [ItemStack.new("stone", 5), ItemStack.new("dirt", 2)]
    assert ItemSpill.contents(bundle) == [ItemStack.new("arrow", 3)]
    assert ItemSpill.contents(ItemStack.new("shulker_box")) == []
    # Only a block item's container spills (`BlockItem.onDestroyed`).
    stick = %{ItemStack.new("stick") | components: box.components}
    assert ItemSpill.contents(stick) == []
  end

  test "an explosion that destroys a shulker box spills it in the same change" do
    key = {0, 0}

    box = %{
      ItemStack.new("shulker_box")
      | components: %{"minecraft:container" => [ItemStack.new("stone", 5)]}
    }

    record = %{uuid: <<1::128>>, x: 4.5, y: 64.0, z: 4.5, stack: box}
    {:ok, store} = Store.restore(key, [record])
    [id] = Map.keys(store.entries)
    after_blast = Explosion.apply_hits(store, key, [{id, :destroy}])
    assert [%{stack: stone, entity: %{x: 4.5, z: 4.5}}] = Map.values(after_blast.entries)
    assert stone == ItemStack.new("stone", 5)
  end
end
