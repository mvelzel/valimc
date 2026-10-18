defmodule Valimc.World.ContainerLifecycleTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerLifecycle, Containers}
  @key {0, 0}
  @position {2, 64, 2}
  @chests JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"]
  @chest hd(@chests)

  test "create, state-only update and removal keep metadata and typed receipts coherent" do
    receipts = %{<<1::128>> => %{sequence: 8, digest: <<2::256>>}}
    original = %Containers{receipts: receipts}

    assert {:ok, %{containers: created, removed: []}} =
             ContainerLifecycle.plan(original, @key, %{@position => 0}, %{@position => @chest})

    entry = created.entries[@position]
    assert entry.rows == 3 and entry.slots == Tuple.duplicate(nil, 27)
    assert created.receipts == receipts and created.sequence == 1

    for state <- @chests do
      assert {:ok, %{containers: ^created, removed: []}} =
               ContainerLifecycle.plan(created, @key, %{@position => @chest}, %{
                 @position => state
               })
    end

    assert {:ok, %{containers: removed, removed: [%{position: @position, entry: ^entry}]}} =
             ContainerLifecycle.plan(created, @key, %{@position => @chest}, %{@position => 0})

    assert removed.entries == %{} and removed.receipts == receipts and removed.sequence == 2

    assert {:ok, %{containers: replaced}} =
             ContainerLifecycle.plan(removed, @key, %{@position => 0}, %{@position => @chest})

    assert replaced.entries[@position].revision == 3
    assert {:error, :stale_container} = Containers.replace(replaced, @position, 1, entry.slots)
  end

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

  test "remove-first planning permits a full region to replace a chest without an allocation gap" do
    original =
      Enum.reduce(0..1023, %Containers{}, fn n, current ->
        {:ok, next, _} = Containers.create(current, @key, {div(n, 128), 64, rem(n, 128)}, 3)
        next
      end)

    old = {7, 64, 127}
    new = {0, 65, 0}

    assert {:ok, %{containers: next, removed: [_]}} =
             ContainerLifecycle.plan(original, @key, %{old => @chest, new => 0}, %{
               old => 0,
               new => @chest
             })

    assert map_size(next.entries) == 1024 and next.entries[old] == nil
    assert next.entries[new].revision == 1026 and next.sequence == 1026

    assert {:error, :container_limit} =
             ContainerLifecycle.plan(original, @key, %{new => 0}, %{new => @chest})
  end

  test "double-chest edits and a partially exhausted remove/create batch return no proposal" do
    double =
      Enum.find(
        JSON.decode!(File.read!("priv/protocol/chest_states.json"))["states"],
        &(&1["part"] != "single")
      )["state"]

    for {before_state, after_state} <- [{0, double}, {double, @chest}] do
      assert {:error, :invalid_container_lifecycle} =
               ContainerLifecycle.plan(%Containers{}, @key, %{@position => before_state}, %{
                 @position => after_state
               })
    end

    {:ok, original, _} = Containers.create(%Containers{}, @key, @position, 3)
    original = %{original | sequence: 18_446_744_073_709_551_614}
    other = {3, 64, 3}

    assert {:error, :container_sequence_exhausted} =
             ContainerLifecycle.plan(original, @key, %{@position => @chest, other => 0}, %{
               @position => 0,
               other => @chest
             })

    assert map_size(original.entries) == 1 and original.entries[@position].revision == 1
  end

  test "wrong owner, incomplete/invalid observations and exhausted revisions fail without a proposal" do
    for {expected, edits} <- [
          {%{}, %{@position => @chest}},
          {%{{128, 64, 0} => 0}, %{{128, 64, 0} => @chest}},
          {%{{0, -65, 0} => 0}, %{{0, -65, 0} => @chest}},
          {%{@position => 35_723}, %{@position => @chest}},
          {%{@position => 0}, %{@position => nil}}
        ] do
      assert {:error, :invalid_container_lifecycle} =
               ContainerLifecycle.plan(%Containers{}, @key, expected, edits)
    end

    original = %Containers{sequence: 18_446_744_073_709_551_615}

    assert {:error, :container_sequence_exhausted} =
             ContainerLifecycle.plan(original, @key, %{@position => 0}, %{@position => @chest})
  end
end
