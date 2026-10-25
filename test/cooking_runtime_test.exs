defmodule Valimc.CookingRuntimeTest do
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Cooking
  alias Valimc.Blocks.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, CookingRuntime}
  alias Valimc.Entity.Store
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
    items = Store.new()
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

  test "partial-section selection freezes processors and a ticket change wakes them" do
    cooking = %Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal"), nil},
      burn_left: 500,
      burn_total: 1600,
      progress: 10,
      total: 200
    }

    {containers, edits} = seed(:furnace, cooking)
    other = {20, 64, 4}
    {:ok, containers, entry} = Containers.create_cooking(containers, @key, other, :furnace)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, other, entry.revision, cooking, %{})

    edits = Map.put(edits, other, edits[@pos])
    items = Store.new()
    first = MapSet.new([{0, 0}])
    runtime = %CookingRuntime{}
    selected = CookingRuntime.selection(runtime, containers, edits, items, -1000, first)
    assert selected == MapSet.new([@pos])
    {:ok, plan} = CookingRuntime.plan(containers, items, @key, edits, selected, MapSet.new())
    assert plan.containers.entries[@pos].cooking.progress == 11
    assert plan.containers.entries[other] == containers.entries[other]
    assert Map.keys(plan.expected) == [@pos]
    runtime = CookingRuntime.accepted(runtime, plan, plan.containers, edits, items, -1000, first)
    second = MapSet.new([{1, 0}])
    assert CookingRuntime.due?(runtime, plan.containers, edits, items, -950, second)

    assert CookingRuntime.selection(runtime, plan.containers, edits, items, -950, second) ==
             MapSet.new([other])

    none = MapSet.new()
    runtime = CookingRuntime.observed(runtime, plan.containers, edits, none)
    refute CookingRuntime.due?(runtime, plan.containers, edits, items, -900, none)
  end
end
