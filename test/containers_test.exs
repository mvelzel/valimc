defmodule Valimc.ContainersTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Containers

  defp resign(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "persisted sequence fences stale competing views and removed/recreated chests" do
    pos = {-1, 64, -1}
    key = {-1, -1}

    assert {:ok, first, %{revision: 1, slots: empty}} =
             Containers.create(%Containers{}, key, pos, 3)

    slots = put_elem(empty, 26, ItemStack.new("diamond", 3))
    assert {:ok, filled, %{revision: 2}} = Containers.replace(first, pos, 1, slots)
    assert {:error, :stale_container} = Containers.replace(filled, pos, 1, empty)
    assert {:error, :stale_container} = Containers.remove(filled, pos, 1)
    assert {:ok, removed, %{slots: ^slots}} = Containers.remove(filled, pos, 2)
    assert removed.entries == %{} and removed.sequence == 3
    assert {:ok, bytes} = Containers.encode(key, removed)
    assert {:ok, ^removed} = Containers.decode(bytes, key)

    assert {:ok, recreated, %{revision: 4, slots: ^empty}} =
             Containers.create(removed, key, pos, 3)

    assert {:error, :stale_container} = Containers.replace(recreated, pos, 2, slots)
    assert {:error, :container_exists} = Containers.create(recreated, key, pos, 3)
  end

  test "hoppers, droppers and dispensers keep their slots, cooldown and tick order (VMC-049a)" do
    key = {0, 0}
    {:ok, state, hopper} = Containers.create_machine(%Containers{}, key, {1, 64, 1}, :hopper)
    {:ok, state, chest} = Containers.create(state, key, {2, 64, 1}, 3)
    {:ok, state, dropper} = Containers.create_machine(state, key, {3, 64, 1}, :dropper)
    assert {tuple_size(hopper.slots), tuple_size(dropper.slots)} == {5, 9}
    assert hopper.cooldown == -1 and hopper.order == 1 and dropper.order == 3

    assert {:error, :invalid_container_kind} =
             Containers.create_machine(state, key, {4, 64, 1}, :chest)

    slots = put_elem(hopper.slots, 4, ItemStack.new("dirt", 7))
    {:ok, state, moved} = Containers.replace(state, {1, 64, 1}, hopper.revision, slots)
    # A cooldown alone keeps the revision; a stale one is refused.
    {:ok, state} = Containers.put_cooldown(state, {1, 64, 1}, moved.revision, 8)

    assert {:error, :stale_container} =
             Containers.put_cooldown(state, {1, 64, 1}, hopper.revision, 3)

    assert %{revision: revision, cooldown: 8, order: 1} = state.entries[{1, 64, 1}]
    assert revision == moved.revision

    assert {:error, :invalid_container_contents} =
             Containers.replace(state, {3, 64, 1}, dropper.revision, slots)

    assert {:ok, bytes} = Containers.encode(key, state)
    assert {:ok, ^state} = Containers.decode(bytes, key)
    assert state.entries[{2, 64, 1}] == chest
  end

  test "corruption, truncation, duplicate positions and impossible revisions fail closed even if rehashed" do
    {:ok, state, _} = Containers.create(%Containers{}, {0, 0}, {0, 64, 0}, 3)
    {:ok, bytes} = Containers.encode({0, 0}, state)
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), checksum::binary>> = bytes
    <<header::binary-size(29), 1::16, row::binary>> = payload

    for bad <- [
          <<>>,
          binary_part(bytes, 0, 31),
          binary_part(bytes, 0, byte_size(bytes) - 1),
          bytes <> <<0>>,
          payload <> <<Bitwise.bxor(:binary.first(checksum), 1)>> <> binary_part(checksum, 1, 31)
        ] do
      assert {:error, :invalid_container_snapshot} = Containers.decode(bad, {0, 0})
    end

    duplicate = <<header::binary, 2::16, row::binary, row::binary>>
    assert {:error, :invalid_container_snapshot} = Containers.decode(resign(duplicate), {0, 0})
    <<prefix::binary-size(21), _::64, suffix::binary>> = payload

    assert {:error, :invalid_container_snapshot} =
             Containers.decode(resign(<<prefix::binary, 0::64, suffix::binary>>), {0, 0})

    <<header::binary-size(31), _x::signed-32, body::binary>> = payload

    assert {:error, :invalid_container_snapshot} =
             Containers.decode(resign(<<header::binary, 128::signed-32, body::binary>>), {0, 0})
  end

  test "aggregate file budget is enforced even when each container fits its own content limit" do
    large = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"payload" => {:string, String.duplicate("x", 30_000)}}}
        }
    }

    slots = List.to_tuple(List.duplicate(large, 17) ++ List.duplicate(nil, 10))

    state =
      Enum.reduce(0..15, %Containers{}, fn x, state ->
        {:ok, state, entry} = Containers.create(state, {0, 0}, {x, 64, 0}, 3)
        {:ok, state, _} = Containers.replace(state, {x, 64, 0}, entry.revision, slots)
        state
      end)

    assert {:ok, bytes} = Containers.encode({0, 0}, state)
    assert byte_size(bytes) < Containers.max_bytes()
    assert {:ok, ^state} = Containers.decode(bytes, {0, 0})
    {:ok, state, entry} = Containers.create(state, {0, 0}, {16, 64, 0}, 3)
    {:ok, state, _} = Containers.replace(state, {16, 64, 0}, entry.revision, slots)
    assert {:error, :invalid_container_snapshot} = Containers.encode({0, 0}, state)
  end
end
