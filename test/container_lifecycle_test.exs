defmodule Valimc.World.ContainerLifecycleTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerLifecycle, Containers}
  @key {0, 0}
  @position {2, 64, 2}
  @chests JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"]
  @chest hd(@chests)

  test "occupied removals return every original slot without moving any quantity into a player" do
    {:ok, original, entry} = Containers.create(%Containers{}, @key, @position, 3)

    slots =
      entry.slots
      |> put_elem(0, ItemStack.new("diamond", 3))
      |> put_elem(26, ItemStack.new("oak_planks", 7))

    {:ok, original, entry} = Containers.replace(original, @position, entry.revision, slots)

    assert {:ok, %{containers: next, removed: [%{entry: ^entry, position: @position}]}} =
             ContainerLifecycle.plan(original, @key, %{@position => @chest}, %{@position => 1})

    assert next.entries == %{} and next.sequence == 3
    assert original.entries[@position].slots == slots

    assert {:error, :missing_or_invalid_chest} =
             ContainerLifecycle.plan(%Containers{}, @key, %{@position => @chest}, %{
               @position => 0
             })

    assert {:error, :unexpected_container} =
             ContainerLifecycle.plan(original, @key, %{@position => 0}, %{@position => 1})
  end
end
