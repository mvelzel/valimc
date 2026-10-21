defmodule Valimc.CookingBatchTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, CookingBatch, Items}
  @key {0, 0}
  @position {4, 64, 4}

  defp seed(kind, cooking, recipes \\ %{}) do
    {:ok, containers, entry} = Containers.create_cooking(%Containers{}, @key, @position, kind)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, @position, entry.revision, cooking, recipes)

    {:ok, block} = CookingBlocks.placement(kind, 0.0)
    {containers, block}
  end

  test "full item capacity refuses the whole remainder step without stalling unrelated progress" do
    fuel = %{ItemStack.new("lava_bucket", 2) | components: %{"minecraft:max_stack_size" => 99}}

    {containers, block} =
      seed(:furnace, %Cooking{slots: {ItemStack.new("raw_iron"), fuel, nil}, total: 200})

    other = {5, 64, 4}
    {:ok, containers, entry} = Containers.create_cooking(containers, @key, other, :furnace)

    {:ok, containers, _} =
      Containers.replace_cooking(
        containers,
        other,
        entry.revision,
        %Cooking{burn_left: 50, burn_total: 100},
        %{}
      )

    records =
      for n <- 1..256,
          do: %{uuid: <<n::128>>, x: 8.5, y: 64.0, z: 8.5, stack: ItemStack.new("stone")}

    {:ok, items} = Items.restore(@key, records)
    {:ok, lit} = CookingBlocks.lit(block, true)
    {:ok, plan} = CookingBatch.plan(containers, items, @key, %{@position => block, other => lit})
    assert plan.refused == %{@position => :item_count_limit}

    assert plan.items == items and
             plan.containers.entries[@position] == containers.entries[@position]

    assert plan.containers.entries[other].cooking.burn_left == 49
    assert plan.containers.entries[other].revision == entry.revision + 1
    assert plan.changes == %{} and plan.changed == [other]
  end
end
