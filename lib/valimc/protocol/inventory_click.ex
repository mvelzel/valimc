defmodule Valimc.Protocol.InventoryClick do
  @moduledoc "Bounded 26.3 click input. Prediction hashes describe observations, never owned items."
  alias Valimc.Protocol.{ItemTypes, Wire}
  defstruct [:container, :state_id, :slot, :button, :action, :predicted_slots, :predicted_cursor]

  def decode(bytes) when byte_size(bytes) <= 65_536 do
    {container, bytes} = Wire.take_varint(bytes)
    {state_id, <<slot::signed-16, button::signed-8, bytes::binary>>} = Wire.take_varint(bytes)
    check(container <= 127 and state_id <= 32767, :invalid_menu_id)
    {action, bytes} = Wire.take_varint(bytes)
    action = ItemTypes.input(action)
    check(action != nil, :unknown_click_action)
    {count, bytes} = Wire.take_varint(bytes)
    check(count <= 128, :predicted_slot_limit)
    {slots, bytes} = slots(bytes, count, %{})
    {cursor, <<>>} = hashed_stack(bytes)

    {:ok,
     %__MODULE__{
       container: container,
       state_id: state_id,
       slot: slot,
       button: button,
       action: action,
       predicted_slots: slots,
       predicted_cursor: cursor
     }}
  rescue
    ArgumentError -> {:error, :malformed_click}
    MatchError -> {:error, :malformed_click}
    FunctionClauseError -> {:error, :malformed_click}
  catch
    {:click_error, reason} -> {:error, reason}
  end

  def decode(_), do: {:error, :click_byte_limit}
  defp slots(bytes, 0, slots), do: {slots, bytes}

  defp slots(<<slot::signed-16, bytes::binary>>, count, slots) do
    check(slot in 0..45, :invalid_predicted_slot)
    check(not Map.has_key?(slots, slot), :duplicate_predicted_slot)
    {stack, bytes} = hashed_stack(bytes)
    slots(bytes, count - 1, Map.put(slots, slot, stack))
  end

  defp hashed_stack(<<0, bytes::binary>>), do: {nil, bytes}

  defp hashed_stack(<<1, bytes::binary>>) do
    {id, bytes} = Wire.take_varint(bytes)
    check(ItemTypes.item(id) != nil, :unknown_predicted_item)
    {count, bytes} = Wire.take_varint(bytes)
    check(count in 1..99, :invalid_predicted_count)
    {added, bytes} = Wire.take_varint(bytes)
    check(added <= ItemTypes.component_count(), :predicted_component_limit)
    {hashes, bytes} = hashes(bytes, added, %{})
    {removed, bytes} = Wire.take_varint(bytes)
    check(added + removed <= ItemTypes.component_count(), :predicted_component_limit)
    {removed, bytes} = removed(bytes, removed, MapSet.new(), hashes)
    {%{item_id: id, count: count, hashes: hashes, removed: removed}, bytes}
  end

  defp hashed_stack(_), do: throw({:click_error, :malformed_prediction})
  defp hashes(bytes, 0, hashes), do: {hashes, bytes}

  defp hashes(bytes, count, hashes) do
    {id, <<hash::signed-32, bytes::binary>>} = Wire.take_varint(bytes)
    check(ItemTypes.component(id) != nil, :unknown_predicted_component)
    check(not Map.has_key?(hashes, id), :duplicate_predicted_component)
    hashes(bytes, count - 1, Map.put(hashes, id, hash))
  end

  defp removed(bytes, 0, removed, _), do: {removed, bytes}

  defp removed(bytes, count, removed, hashes) do
    {id, bytes} = Wire.take_varint(bytes)
    check(ItemTypes.component(id) != nil, :unknown_predicted_component)

    check(
      not MapSet.member?(removed, id) and not Map.has_key?(hashes, id),
      :duplicate_predicted_component
    )

    removed(bytes, count - 1, MapSet.put(removed, id), hashes)
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:click_error, reason})
end
