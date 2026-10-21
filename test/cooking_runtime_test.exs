defmodule Valimc.CookingRuntimeTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, CookingRuntime, Items}
  @key {0, 0}
  @pos {4, 64, 4}

  defp seed(kind, cooking) do
    {:ok, containers, entry} = Containers.create_cooking(%Containers{}, @key, @pos, kind)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, @pos, entry.revision, cooking, %{})

    {:ok, block} = CookingBlocks.placement(kind, 0.0)
    {containers, %{@pos => block}}
  end

  test "stable processors sleep and an external slot edit wakes them" do
    {containers, edits} = seed(:furnace, %Cooking{})
    items = Items.new()
    runtime = %CookingRuntime{}
    assert CookingRuntime.due?(runtime, containers, edits, items, -1000)
    {:ok, plan} = CookingRuntime.plan(containers, items, @key, edits, :all, MapSet.new())
    runtime = CookingRuntime.accepted(runtime, plan, containers, edits, items, -1000)
    refute CookingRuntime.due?(runtime, containers, edits, items, -950)

    entry = containers.entries[@pos]

    {:ok, changed, _} =
      Containers.replace_cooking(
        containers,
        @pos,
        entry.revision,
        %Cooking{slots: {ItemStack.new("raw_iron"), ItemStack.new("coal"), nil}},
        %{}
      )

    assert CookingRuntime.selection(runtime, changed, edits, items, -900) == :all
    assert CookingRuntime.due?(runtime, changed, edits, items, -900)
  end

  test "capacity refusal backs off, wakes when capacity changes, and does not stall neighbors" do
    fuel = %{ItemStack.new("lava_bucket", 2) | components: %{"minecraft:max_stack_size" => 99}}
    {containers, edits} = seed(:furnace, %Cooking{slots: {ItemStack.new("raw_iron"), fuel, nil}})
    other = {5, 64, 4}
    {:ok, containers, entry} = Containers.create_cooking(containers, @key, other, :furnace)

    {:ok, containers, _} =
      Containers.replace_cooking(
        containers,
        other,
        entry.revision,
        %Cooking{burn_left: 20, burn_total: 20},
        %{}
      )

    {:ok, lit} = CookingBlocks.lit(edits[@pos], true)
    edits = Map.put(edits, other, lit)

    records =
      for n <- 1..256,
          do: %{uuid: <<n::128>>, x: 8.5, y: 64.0, z: 8.5, stack: ItemStack.new("stone")}

    {:ok, items} = Items.restore(@key, records)
    {:ok, plan} = CookingRuntime.plan(containers, items, @key, edits, :all, MapSet.new())
    assert plan.refused == %{@pos => :item_count_limit}
    assert plan.containers.entries[other].cooking.burn_left == 19

    runtime =
      CookingRuntime.accepted(%CookingRuntime{}, plan, plan.containers, edits, items, 1000)

    assert runtime.retry_at == 2000

    assert CookingRuntime.selection(runtime, plan.containers, edits, items, 1050) ==
             MapSet.new([other])

    assert MapSet.member?(
             CookingRuntime.selection(runtime, plan.containers, edits, items, 2000),
             @pos
           )

    {id, entry} = Enum.at(items.entries, 0)
    {:ok, room} = Items.remove(items, items.epoch, id, entry.revision)

    assert MapSet.member?(
             CookingRuntime.selection(runtime, plan.containers, edits, room, 1050),
             @pos
           )
  end

  test "new remainders preserve newer item motion and reject changed capacity without overwriting anything" do
    items = Items.new()

    {:ok, original, {epoch, id, revision}} =
      Items.create(items, @key, ItemStack.new("stone"), {8.5, 65.0, 8.5})

    {:ok, proposed, _} = Items.create(original, @key, ItemStack.new("bucket"), {4.5, 64.5, 4.5})

    [step] = [
      %{
        id: id,
        revision: revision,
        position: {8.6, 65.0, 8.5},
        motion: %Valimc.ItemMotionState{no_gravity: true, age: 7, velocity: {0.1, 0.0, 0.0}}
      }
    ]

    {:ok, moved, _} = Items.advance(original, @key, epoch, [step])
    {:ok, rebased} = Items.merge_created(moved, original, proposed)
    assert rebased.entries[id] == moved.entries[id]
    assert Enum.count(Items.records(rebased), &(&1.stack == ItemStack.new("bucket"))) == 1
    assert rebased.ledger == moved.ledger
    full = %{moved | entries: Map.new(1..256, &{&1, moved.entries[id]})}
    assert {:error, :item_count_limit} = Items.merge_created(full, original, proposed)

    assert {:error, :invalid_item_additions} =
             Items.merge_created(Items.new(), original, proposed)
  end
end
