defmodule Valimc.Inventory do
  @moduledoc "Bounded player-menu state owned entirely by its connection process."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @max_encoded_bytes 524_288
  @equipment %{"head" => 5, "chest" => 6, "legs" => 7, "feet" => 8, "offhand" => 45}
  defstruct slots: %{}, selected: 0, carried: nil, state_id: 0
  def new, do: %__MODULE__{}
  def get(inventory, slot), do: inventory.slots[slot]
  def contents(inventory), do: Enum.map(0..45, &get(inventory, &1))
  def advance(inventory), do: %{inventory | state_id: rem(inventory.state_id + 1, 32768)}
  def held(inventory, :main), do: get(inventory, 36 + inventory.selected)
  def held(inventory, :off), do: get(inventory, 45)

  def creative(inventory, slot, stack) when is_integer(slot) and slot in 1..45,
    do: inventory |> put(slot, stack) |> finish()

  def creative(_, _, _), do: {:error, :invalid_slot}

  def select(inventory, slot) when is_integer(slot) and slot in 0..8,
    do: {:ok, %{inventory | selected: slot}}

  def select(_, _), do: {:error, :invalid_selection}

  def swap_hands(inventory) do
    main = held(inventory, :main)
    off = held(inventory, :off)

    inventory
    |> put(36 + inventory.selected, off)
    |> put(45, main)
    |> advance()
  end

  def click(inventory, :pickup, slot, button) when slot in 5..45 and button in [0, 1] do
    if specialized_click?(get(inventory, slot)) or specialized_click?(inventory.carried),
      do: {:error, :unsupported_click},
      else: inventory |> pickup(slot, button) |> finish()
  end

  def click(inventory, :swap, slot, button)
      when slot in 5..45 and (button in 0..8 or button == 40) do
    target = if button == 40, do: 45, else: 36 + button
    first = get(inventory, slot)
    second = get(inventory, target)

    if can_place?(slot, second) and can_place?(target, first) do
      inventory |> put(slot, second) |> put(target, first) |> finish()
    else
      {:error, :slot_restricted}
    end
  end

  def click(inventory, :quick_move, slot, button) when slot in 5..45 and button in [0, 1],
    do: inventory |> quick_move(slot) |> finish()

  def click(_, _, _, _), do: {:error, :unsupported_click}

  def encoded_size(inventory),
    do:
      Enum.reduce(
        contents(inventory),
        IO.iodata_length(ItemStack.encode(inventory.carried)),
        fn stack, size -> size + IO.iodata_length(ItemStack.encode(stack)) end
      )

  defp finish(inventory) do
    if encoded_size(inventory) <= @max_encoded_bytes,
      do: {:ok, advance(inventory)},
      else: {:error, :inventory_byte_limit}
  end

  defp pickup(inventory, slot, button) do
    stack = get(inventory, slot)
    cursor = inventory.carried

    cond do
      cursor == nil and stack != nil ->
        count = if button == 0, do: stack.count, else: div(stack.count + 1, 2)
        %{put(inventory, slot, sized(stack, stack.count - count)) | carried: sized(stack, count)}

      cursor != nil and stack == nil and can_place_type?(slot, cursor) ->
        count = min(if(button == 0, do: cursor.count, else: 1), slot_limit(slot, cursor))

        %{
          put(inventory, slot, sized(cursor, count))
          | carried: sized(cursor, cursor.count - count)
        }

      cursor != nil and stack != nil and compatible?(cursor, stack) and
          can_place_type?(slot, cursor) ->
        count =
          min(
            if(button == 0, do: cursor.count, else: 1),
            max(slot_limit(slot, cursor) - stack.count, 0)
          )

        %{
          put(inventory, slot, sized(stack, stack.count + count))
          | carried: sized(cursor, cursor.count - count)
        }

      cursor != nil and stack != nil and not compatible?(cursor, stack) and
          can_place?(slot, cursor) ->
        %{put(inventory, slot, cursor) | carried: stack}

      true ->
        inventory
    end
  end

  defp quick_move(inventory, slot) do
    stack = get(inventory, slot)
    equipment = if stack, do: equipment_slot(stack)

    targets =
      cond do
        stack == nil ->
          []

        slot not in 5..8 and equipment != nil and equipment != slot and
            get(inventory, equipment) == nil ->
          [equipment]

        slot in 9..35 ->
          Enum.to_list(36..44)

        slot in 36..44 ->
          Enum.to_list(9..35)

        true ->
          Enum.to_list(9..44)
      end

    if stack == nil do
      inventory
    else
      {inventory, left} = transfer(inventory, stack, stack.count, targets, :merge)
      {inventory, left} = transfer(inventory, stack, left, targets, :empty)
      put(inventory, slot, sized(stack, left))
    end
  end

  defp transfer(inventory, stack, count, targets, mode) do
    Enum.reduce(targets, {inventory, count}, fn slot, {inventory, left} ->
      present = get(inventory, slot)

      matches =
        if mode == :merge,
          do: present != nil and compatible?(present, stack),
          else: present == nil

      if left > 0 and matches and can_place_type?(slot, stack) do
        existing = if present, do: present.count, else: 0
        moved = min(left, max(slot_limit(slot, stack) - existing, 0))
        {put(inventory, slot, sized(stack, existing + moved)), left - moved}
      else
        {inventory, left}
      end
    end)
  end

  defp compatible?(first, second),
    do:
      first.item_id == second.item_id and first.components == second.components and
        first.removed == second.removed

  defp specialized_click?(nil), do: false

  defp specialized_click?(stack),
    do: ItemTypes.item(stack.item_id)["inventory_click_override"] == true

  defp sized(_, 0), do: nil
  defp sized(stack, count), do: %{stack | count: count}
  defp can_place?(_, nil), do: true

  defp can_place?(slot, stack),
    do: can_place_type?(slot, stack) and stack.count <= slot_limit(slot, stack)

  defp can_place_type?(slot, stack) when slot in 5..8, do: equipment_slot(stack) == slot
  defp can_place_type?(_, _), do: true
  defp slot_limit(slot, _) when slot in 5..8, do: 1
  defp slot_limit(_, stack), do: ItemStack.max_stack_size(stack)

  defp equipment_slot(stack) do
    if MapSet.member?(stack.removed, "minecraft:equippable"),
      do: nil,
      else: @equipment[ItemTypes.item(stack.item_id)["equipment_slot"]]
  end

  defp put(inventory, slot, nil), do: %{inventory | slots: Map.delete(inventory.slots, slot)}

  defp put(inventory, slot, stack),
    do: %{inventory | slots: Map.put(inventory.slots, slot, stack)}
end
