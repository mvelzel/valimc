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

  test "lit transitions retain every native facing and reject nonprocessing states" do
    facts = JSON.decode!(File.read!("priv/physics/cooking_blocks.json"))["states"]

    for row <- facts, lit <- [false, true] do
      expected =
        Enum.find(
          facts,
          &(&1["kind"] == row["kind"] and &1["facing"] == row["facing"] and &1["lit"] == lit)
        )

      assert CookingBlocks.lit(row["state"], lit) == {:ok, expected["state"]}
    end

    assert {:error, _} = CookingBlocks.lit(Data.block("stone"), true)
    assert {:error, _} = CookingBlocks.lit(6884, :lit)
  end

  test "fuel and completion are indivisible while progress-only changes retain menu content revision" do
    cooking = %Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), nil},
      total: 200
    }

    {containers, block} = seed(:furnace, cooking)
    receipts = %{<<1::128>> => %{sequence: 71, digest: <<2::256>>}}
    containers = %{containers | receipts: receipts}
    {:ok, started} = CookingBatch.plan(containers, Items.new(), @key, %{@position => block})
    entry = started.containers.entries[@position]
    assert entry.revision == 3 and elem(entry.cooking.slots, 1) == ItemStack.new("coal")
    assert entry.cooking.progress == 1 and started.containers.receipts == receipts
    {:ok, lit} = CookingBlocks.lit(block, true)
    assert started.changes == %{@position => lit}

    {:ok, progress} =
      CookingBatch.plan(started.containers, started.items, @key, %{@position => lit})

    assert progress.containers.sequence == 3 and
             progress.containers.entries[@position].revision == 3

    assert progress.containers.entries[@position].cooking.progress == 2
    assert progress.changes == %{} and progress.changed == [@position]
    near = %{entry.cooking | progress: 199}

    {:ok, near_containers, _} =
      Containers.replace_cooking(progress.containers, @position, 3, near, %{})

    {:ok, done} = CookingBatch.plan(near_containers, progress.items, @key, %{@position => lit})
    next = done.containers.entries[@position]

    assert next.cooking.slots ==
             {ItemStack.new("raw_iron"), ItemStack.new("coal"), ItemStack.new("iron_ingot")}

    assert next.recipes == %{"minecraft:iron_ingot_from_smelting_raw_iron" => 1}
    assert next.cooking.progress == 0 and next.revision == 5
    assert containers.entries[@position].cooking == cooking
  end

  test "stacked fuel overflow adds exactly one owned remainder with native scatter" do
    fuel = %{ItemStack.new("lava_bucket", 2) | components: %{"minecraft:max_stack_size" => 99}}
    cooking = %Cooking{slots: {ItemStack.new("raw_iron"), fuel, nil}, total: 200}
    {containers, block} = seed(:furnace, cooking)
    {:ok, plan} = CookingBatch.plan(containers, Items.new(), @key, %{@position => block})
    assert [%{stack: bucket, x: x, y: y, z: z, motion: motion}] = Items.records(plan.items)
    assert bucket == ItemStack.new("bucket") and x >= 4.125 and x < 4.875
    assert y >= 64 and y < 64.75 and z >= 4.125 and z < 4.875
    assert motion.pickup_delay == 0
    assert elem(plan.containers.entries[@position].cooking.slots, 1) == %{fuel | count: 1}
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

  test "recipe and content revision exhaustion retain every processor field" do
    key = "minecraft:iron_ingot_from_smelting_raw_iron"

    cooking = %Cooking{
      slots: {ItemStack.new("raw_iron"), nil, nil},
      burn_left: 50,
      burn_total: 100,
      progress: 199,
      total: 200
    }

    {containers, block} = seed(:furnace, cooking, %{key => 2_147_483_647})
    {:ok, lit} = CookingBlocks.lit(block, true)
    {:ok, plan} = CookingBatch.plan(containers, Items.new(), @key, %{@position => lit})
    assert plan.containers == containers and plan.changed == [] and plan.changes == %{}
    assert plan.refused == %{@position => :invalid_cooking_entry}

    containers = %{
      containers
      | sequence: 18_446_744_073_709_551_615,
        entries: %{@position => %{containers.entries[@position] | recipes: %{}}}
    }

    {:ok, plan} = CookingBatch.plan(containers, Items.new(), @key, %{@position => lit})
    assert plan.containers == containers
    assert plan.refused == %{@position => :container_sequence_exhausted}
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

  test "a multi-entry batch composes completions in deterministic content revision order" do
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, lit} = CookingBlocks.lit(block, true)

    cooking = %Cooking{
      slots: {ItemStack.new("raw_iron"), nil, nil},
      burn_left: 10,
      burn_total: 100,
      progress: 199,
      total: 200
    }

    containers =
      Enum.reduce(0..63, %Containers{}, fn x, current ->
        {:ok, current, entry} = Containers.create_cooking(current, @key, {x, 64, 4}, :furnace)

        {:ok, current, _} =
          Containers.replace_cooking(current, {x, 64, 4}, entry.revision, cooking, %{})

        current
      end)

    blocks = Map.new(0..63, &{{&1, 64, 4}, lit})
    {:ok, result} = CookingBatch.plan(containers, Items.new(), @key, blocks)
    assert result.refused == %{} and length(result.changed) == 64
    assert result.containers.sequence == 192 and result.changes == blocks

    for x <- 0..63 do
      entry = result.containers.entries[{x, 64, 4}]
      assert entry.revision == 129 + x
      assert entry.cooking.slots == {nil, nil, ItemStack.new("iron_ingot")}
      assert entry.recipes == %{"minecraft:iron_ingot_from_smelting_raw_iron" => 1}
    end

    {:ok, bytes} = Containers.encode(@key, result.containers)
    assert {:ok, same} = Containers.decode(bytes, @key)
    assert same == result.containers
  end

  test "one bounded logical step covers the full region capacity without invalidating item revisions" do
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, lit} = CookingBlocks.lit(block, true)

    {containers, blocks} =
      Enum.reduce(0..1023, {%Containers{}, %{}}, fn n, {containers, blocks} ->
        position = {rem(n, 128), 64, div(n, 128)}
        {:ok, containers, entry} = Containers.create_cooking(containers, @key, position, :furnace)

        {:ok, containers, _} =
          Containers.replace_cooking(
            containers,
            position,
            entry.revision,
            %Cooking{burn_left: 20, burn_total: 100},
            %{}
          )

        {containers, Map.put(blocks, position, lit)}
      end)

    {:ok, plan} = CookingBatch.plan(containers, Items.new(), @key, blocks)
    assert length(plan.changed) == 1024 and plan.refused == %{} and plan.changes == %{}
    assert plan.containers.sequence == containers.sequence

    for {position, entry} <- plan.containers.entries do
      assert entry.revision == containers.entries[position].revision
      assert entry.cooking.burn_left == 19
    end
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
