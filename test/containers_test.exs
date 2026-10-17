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

  test "contents retain exact patches, removals and boundaries in every generic row layout" do
    item = %{
      ItemStack.new("diamond_sword")
      | components: %{"minecraft:damage" => 7},
        removed: MapSet.new(["minecraft:custom_name"])
    }

    state =
      Enum.reduce(1..6, %Containers{}, fn rows, state ->
        position = {rows, -64, 0}
        {:ok, state, entry} = Containers.create(state, {0, 0}, position, rows)

        slots =
          entry.slots |> put_elem(0, ItemStack.new("stone", 64)) |> put_elem(rows * 9 - 1, item)

        {:ok, state, _} = Containers.replace(state, position, entry.revision, slots)
        state
      end)

    assert {:ok, bytes} = Containers.encode({0, 0}, state)
    assert {:ok, ^state} = Containers.decode(bytes, {0, 0})
    assert {:error, :invalid_container_snapshot} = Containers.decode(bytes, {-1, 0})
  end

  test "invalid ownership, dimensions, normalized air and over-budget contents refuse" do
    for position <- [{128, 64, 0}, {-1, 64, 0}, {0, -65, 0}, {0, 320, 0}, {0.5, 64, 0}] do
      assert {:error, :invalid_container_position} =
               Containers.create(%Containers{}, {0, 0}, position, 3)
    end

    for rows <- [0, 7, nil],
        do:
          assert(
            {:error, :invalid_container_rows} =
              Containers.create(%Containers{}, {0, 0}, {0, 64, 0}, rows)
          )

    {:ok, state, entry} = Containers.create(%Containers{}, {0, 0}, {0, 319, 0}, 3)

    for slots <- [
          {},
          put_elem(entry.slots, 0, ItemStack.new("air")),
          put_elem(entry.slots, 0, ItemStack.new("stone", 100))
        ] do
      assert {:error, :invalid_container_contents} =
               Containers.replace(state, {0, 319, 0}, 1, slots)
    end

    large = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"payload" => {:string, String.duplicate("x", 30_000)}}}
        }
    }

    assert IO.iodata_length(ItemStack.encode(large)) > 30_000

    assert {:error, :invalid_container_contents} =
             Containers.replace(state, {0, 319, 0}, 1, Tuple.duplicate(large, 27))

    assert {:error, :missing_container} = Containers.replace(state, {0, 64, 0}, 1, entry.slots)
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

  test "entry and sequence exhaustion never wrap or erase the last durable generation" do
    full =
      Enum.reduce(0..(Containers.max_entries() - 1), %Containers{}, fn i, state ->
        {:ok, next, _} = Containers.create(state, {0, 0}, {rem(i, 128), 64, div(i, 128)}, 3)
        next
      end)

    assert {:error, :container_limit} = Containers.create(full, {0, 0}, {0, 65, 0}, 3)
    assert {:ok, bytes} = Containers.encode({0, 0}, full)
    assert {:ok, ^full} = Containers.decode(bytes, {0, 0})
    state = %{full | sequence: 18_446_744_073_709_551_615}
    assert {:error, :container_sequence_exhausted} = Containers.remove(state, {0, 64, 0}, 1)

    assert {:error, :container_sequence_exhausted} =
             Containers.replace(state, {0, 64, 0}, 1, full.entries[{0, 64, 0}].slots)

    assert {:error, :container_sequence_exhausted} =
             Containers.create(%{state | entries: %{}}, {0, 0}, {0, 64, 0}, 3)
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
