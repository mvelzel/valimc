defmodule Valimc.CookingRuntimeTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, CookingRuntime, Entities}
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
    items = Entities.new()
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
end
