defmodule Valimc.CookingBatchTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.{Data, ItemStack}
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

  test "bounded selection and owned type validation reject forged work; idle batches are exact no-ops" do
    {containers, block} = seed(:furnace, %Cooking{})
    items = Items.new()
    {:ok, plan} = CookingBatch.plan(containers, items, @key, %{@position => block})

    assert plan.containers == containers and plan.items == items and plan.changed == [] and
             plan.changes == %{}

    assert {:error, :invalid_cooking_batch} =
             CookingBatch.plan(containers, items, @key, %{
               @position => Data.item_block(Data.item("smoker"))
             })

    assert {:error, :invalid_cooking_batch} =
             CookingBatch.plan(containers, items, @key, %{{5, 64, 4} => block})

    too_many = Map.new(1..(CookingBatch.limit() + 1), &{{&1, 64, 4}, block})
    assert {:error, :invalid_cooking_batch} = CookingBatch.plan(containers, items, @key, too_many)
    assert {:error, _} = CookingBatch.plan(containers, items, {1, 0}, %{@position => block})
  end

  test "activity sleeps stable empty/blocked/unsupported contents and wakes heat, cooldown or a lit mismatch" do
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, lit} = CookingBlocks.lit(block, true)
    entry = %{kind: :furnace, cooking: %Cooking{}}
    refute CookingBatch.awake?(entry, block)
    assert CookingBatch.awake?(entry, lit)
    assert CookingBatch.awake?(%{entry | cooking: %Cooking{progress: 10, total: 200}}, block)
    assert CookingBatch.awake?(%{entry | cooking: %Cooking{burn_left: 10, burn_total: 100}}, lit)
    fuel = ItemStack.new("coal")
    input = ItemStack.new("raw_iron")
    pending = %Cooking{slots: {input, fuel, nil}, total: 200}
    assert CookingBatch.awake?(%{entry | cooking: pending}, block)
    full = %{pending | slots: {input, fuel, ItemStack.new("iron_ingot", 64)}}
    refute CookingBatch.awake?(%{entry | cooking: full}, block)
    assert CookingBatch.awake?(%{entry | cooking: %{full | burn_left: 10, burn_total: 100}}, lit)

    refute CookingBatch.awake?(
             %{entry | cooking: %{pending | slots: {ItemStack.new("bedrock"), fuel, nil}}},
             block
           )

    refute CookingBatch.awake?(%{entry | kind: :smoker, cooking: pending}, block)
    refute CookingBatch.awake?(nil, block)
  end
end
