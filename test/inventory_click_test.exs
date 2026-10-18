defmodule Valimc.Protocol.InventoryClickTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{InventoryClick, ItemTypes, Wire}

  defp header(action \\ "pickup"),
    do: [<<0, 0, 9::signed-16, 0>>, Wire.varint(ItemTypes.input_id(action))]

  defp decode(parts), do: parts |> IO.iodata_to_binary() |> InventoryClick.decode()

  defp hash_stack(added, removed \\ []),
    do: [
      <<1>>,
      Wire.varint(ItemTypes.id("stone")),
      <<17>>,
      Wire.varint(length(added)),
      Enum.map(added, fn {id, hash} -> [Wire.varint(id), <<hash::signed-32>>] end),
      Wire.varint(length(removed)),
      Enum.map(removed, &Wire.varint/1)
    ]

  test "empty and populated observations decode without becoming inventory stacks" do
    assert {:ok, click} = decode([header(), <<0, 0>>])
    assert click.slot == 9 and click.button == 0 and click.action == :pickup
    assert click.predicted_slots == %{} and click.predicted_cursor == nil
    id = ItemTypes.component_id("enchantment_glint_override")
    remove = ItemTypes.component_id("item_name")
    stack = hash_stack([{id, -1}], [remove])
    assert {:ok, click} = decode([header(), <<1, 9::signed-16>>, stack, stack])
    assert click.predicted_slots[9].hashes[id] == -1
    assert click.predicted_cursor.removed == MapSet.new([remove])
    refute is_struct(click.predicted_cursor, Valimc.Protocol.ItemStack)
  end

  test "truncation and trailing data fail at every boundary" do
    bytes = IO.iodata_to_binary([header(), <<1, 9::16>>, hash_stack([{3, 42}]), <<0>>])

    for size <- 0..(byte_size(bytes) - 1),
        do: assert(match?({:error, _}, InventoryClick.decode(binary_part(bytes, 0, size))))

    assert decode([bytes, <<0>>]) == {:error, :malformed_click}
    assert InventoryClick.decode(:binary.copy(<<0>>, 65_537)) == {:error, :click_byte_limit}
  end

  test "predicted slots are bounded by the active menu, including chest hotbars" do
    for cells <- [46, 63, 90] do
      bytes = IO.iodata_to_binary([header(), <<1, cells - 1::signed-16, 0, 0>>])
      assert {:ok, click} = InventoryClick.decode(bytes, cells)
      assert click.predicted_slots == %{(cells - 1) => nil}
      bytes = IO.iodata_to_binary([header(), <<1, cells::signed-16, 0, 0>>])
      assert {:error, :invalid_predicted_slot} = InventoryClick.decode(bytes, cells)
    end

    bytes = IO.iodata_to_binary([header(), <<1, 54::signed-16, 0, 0>>])
    assert {:ok, _} = InventoryClick.decode(bytes, 63)
    assert {:error, :invalid_predicted_slot} = InventoryClick.decode(bytes)
  end

  test "unknown IDs, counts, duplicate slots and patches are rejected" do
    for container <- [-1, 128],
        do:
          assert(
            decode([Wire.varint(container), <<0, 9::16, 0, 0, 0, 0>>]) ==
              {:error, :invalid_menu_id}
          )

    assert decode([<<0>>, Wire.varint(-1), <<9::16, 0, 0, 0, 0>>]) == {:error, :invalid_menu_id}
    assert decode([header(), Wire.varint(129)]) == {:error, :predicted_slot_limit}
    assert decode([header(), <<2, 9::16, 0, 9::16, 0, 0>>]) == {:error, :duplicate_predicted_slot}
    assert decode([header(), <<1, 46::16, 0, 0>>]) == {:error, :invalid_predicted_slot}
    assert decode([header(), <<0, 1>>, Wire.varint(999_999)]) == {:error, :unknown_predicted_item}
    assert decode([header(), <<0, 1, 1, 100>>]) == {:error, :invalid_predicted_count}

    assert decode([header(), <<0>>, hash_stack([{999, 0}])]) ==
             {:error, :unknown_predicted_component}

    assert decode([header(), <<0>>, hash_stack([{3, 0}, {3, 1}])]) ==
             {:error, :duplicate_predicted_component}

    assert decode([header(), <<0>>, hash_stack([{3, 0}], [3])]) ==
             {:error, :duplicate_predicted_component}

    assert decode([<<0, 0, 9::16, 0, 7, 0, 0>>]) == {:error, :unknown_click_action}
  end
end
