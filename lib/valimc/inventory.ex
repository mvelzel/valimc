defmodule Valimc.Inventory do
  @moduledoc "Bounded player-menu state owned entirely by its connection process."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @max_encoded_bytes 524_288
  @equipment %{"head" => 5, "chest" => 6, "legs" => 7, "feet" => 8, "offhand" => 45}
  defguardp click_slot(slot)
            when slot in 1..45 or
                   (is_tuple(slot) and tuple_size(slot) == 2 and elem(slot, 0) == :table and
                      elem(slot, 1) in 0..8)

  defstruct slots: %{},
            table_inputs: nil,
            selected: 0,
            carried: nil,
            state_id: 0,
            drag: nil,
            infinite_materials: false

  def new(infinite_materials \\ false) when is_boolean(infinite_materials),
    do: %__MODULE__{infinite_materials: infinite_materials}

  def get(%{table_inputs: cells}, {:table, index})
      when is_tuple(cells) and tuple_size(cells) == 9 and index in 0..8,
      do: elem(cells, index)

  def get(inventory, slot), do: inventory.slots[slot]
  @doc "All owned physical slots; a table's nine transient inputs follow player slots."
  def contents(inventory),
    do: Enum.map(0..45, &get(inventory, &1)) ++ table_contents(inventory)

  def table_contents(%{table_inputs: nil}), do: []

  def table_contents(%{table_inputs: cells}) when is_tuple(cells) and tuple_size(cells) == 9,
    do: Tuple.to_list(cells)

  def crafting_result(inventory) do
    inputs =
      if inventory.table_inputs,
        do: table_contents(inventory),
        else: Enum.map(1..4, &get(inventory, &1))

    case Valimc.Crafting.result(inputs) do
      {:ok, stack} -> stack
      :none -> nil
    end
  end

  def display_contents(inventory),
    do: [crafting_result(inventory) | Enum.map(1..45, &get(inventory, &1))]

  def advance(inventory), do: %{inventory | state_id: rem(inventory.state_id + 1, 32768)}
  def held(inventory, :main), do: get(inventory, 36 + inventory.selected)
  def held(inventory, :off), do: get(inventory, 45)
  def cancel_drag(inventory), do: %{inventory | drag: nil}

  @doc "Plan one consumed item and its remainder; overflow still requires durable world delivery."
  def consume_hand(inventory, hand, replacement) when hand in [:main, :off] do
    case held(inventory, hand) do
      nil ->
        {:error, :empty_hand}

      stack ->
        remaining =
          if inventory.infinite_materials, do: stack, else: sized(stack, stack.count - 1)

        {held, extras} =
          Valimc.FoodItems.remainder(
            remaining,
            stack.count,
            inventory.infinite_materials,
            replacement
          )

        slot = if hand == :main, do: 36 + inventory.selected, else: 45
        next = inventory |> cancel_drag() |> put(slot, held)

        {next, drops} =
          Enum.reduce(extras, {next, []}, fn extra, {next, drops} ->
            {next, left} = return_stack(next, extra)
            {next, if(left, do: [left | drops], else: drops)}
          end)

        with {:ok, next} <- finish(next), do: {:ok, next, Enum.reverse(drops)}
    end
  end

  @doc "Plans a selected-hand drop without publishing or creating a world entity."
  def drop_selected(inventory, all) when is_boolean(all) do
    case held(inventory, :main) do
      nil ->
        {:ok, cancel_drag(inventory), nil}

      stack ->
        count = if all, do: stack.count, else: 1

        next =
          inventory
          |> cancel_drag()
          |> put(36 + inventory.selected, sized(stack, stack.count - count))

        with {:ok, next} <- finish(next), do: {:ok, next, sized(stack, count)}
    end
  end

  @doc "Plans a connected cleanup batch; commit its at most five drops before continuing."
  def close(inventory) do
    cleanup_batch(inventory, :connected)
  end

  @doc "Plans at most five whole cursor/grid drops; disconnected cleanup never merges storage."
  def disconnect(inventory), do: cleanup_batch(inventory, :disconnected)

  defp transient_slots(inventory),
    do:
      [:carried, 1, 2, 3, 4] ++
        if(inventory.table_inputs, do: Enum.map(0..8, &{:table, &1}), else: [])

  defp owned_stack(inventory, :carried), do: inventory.carried
  defp owned_stack(inventory, slot), do: get(inventory, slot)

  defp put_owned(inventory, :carried, stack), do: %{inventory | carried: stack}

  defp put_owned(inventory, slot, stack), do: put(inventory, slot, stack)

  defp clear_empty_table(inventory) do
    if Enum.all?(table_contents(inventory), &is_nil/1),
      do: %{inventory | table_inputs: nil},
      else: inventory
  end

  defp cleanup_batch(inventory, mode) do
    {next, drops, _count} =
      Enum.reduce_while(transient_slots(inventory), {cancel_drag(inventory), [], 0}, fn
        _, {_, _, 5} = result ->
          {:halt, result}

        slot, {next, drops, count} ->
          stack = owned_stack(next, slot)
          next = put_owned(next, slot, nil)

          {next, remainder} =
            if mode == :connected, do: return_stack(next, stack), else: {next, stack}

          {:cont,
           if(remainder, do: {next, [remainder | drops], count + 1}, else: {next, drops, count})}
      end)

    with {:ok, next} <- next |> put(0, nil) |> clear_empty_table() |> finish(),
         do: {:ok, next, Enum.reverse(drops)}
  end

  @death_slots Enum.to_list(36..44) ++
                 Enum.to_list(9..35) ++ [45, 8, 7, 6, 5, :carried, 1, 2, 3, 4]
  @doc "Plan at most five death drops; native equipment-drop prevention excludes cursor/grid items."
  def death_batch(%__MODULE__{} = inventory) do
    {next, destroyed} =
      Enum.reduce(5..45, {cancel_drag(inventory), []}, fn slot, {next, destroyed} ->
        case get(next, slot) do
          %ItemStack{components: components} = stack ->
            if Map.has_key?(
                 Map.get(components, "minecraft:enchantments", %{}),
                 "minecraft:vanishing_curse"
               ),
               do: {put(next, slot, nil), [stack | destroyed]},
               else: {next, destroyed}

          _ ->
            {next, destroyed}
        end
      end)

    drops =
      (@death_slots ++ if(next.table_inputs, do: Enum.map(0..8, &{:table, &1}), else: []))
      |> Enum.map(fn slot ->
        {slot, owned_stack(next, slot)}
      end)
      |> Enum.reject(fn {_, stack} -> stack == nil end)
      |> Enum.take(5)

    next =
      Enum.reduce(drops, next, fn {slot, _}, next -> put_owned(next, slot, nil) end)
      |> clear_empty_table()

    if drops == [] and destroyed == [] do
      {:ok, next, [], []}
    else
      with {:ok, next} <- finish(next),
           do: {:ok, next, Enum.map(drops, &elem(&1, 1)), Enum.reverse(destroyed)}
    end
  end

  defp return_stack(inventory, nil), do: {inventory, nil}

  defp return_stack(inventory, stack) do
    storage = Enum.to_list(36..44) ++ Enum.to_list(9..35)
    merge_order = Enum.uniq([36 + inventory.selected, 45 | storage])

    {next, left} =
      Enum.reduce(merge_order, {inventory, stack.count}, fn slot, {next, left} ->
        present = get(next, slot)

        # Accepted damageable stacks have maximum 1. They cannot match a
        # nonempty destination with remaining space, as in vanilla isStackable.
        if left > 0 and present != nil and compatible?(present, stack) do
          moved = min(left, max(ItemStack.max_stack_size(present) - present.count, 0))
          {put(next, slot, sized(present, present.count + moved)), left - moved}
        else
          {next, left}
        end
      end)

    {next, left} =
      Enum.reduce(storage, {next, left}, fn slot, {next, left} ->
        if left > 0 and get(next, slot) == nil do
          moved = min(left, ItemStack.max_stack_size(stack))
          {put(next, slot, sized(stack, moved)), left - moved}
        else
          {next, left}
        end
      end)

    {next, sized(stack, left)}
  end

  def creative(inventory, slot, stack) when is_integer(slot) and slot in 1..45,
    do: inventory |> cancel_drag() |> put(slot, stack) |> finish()

  def creative(_, _, _), do: {:error, :invalid_slot}

  def select(inventory, slot) when is_integer(slot) and slot in 0..8,
    do: {:ok, %{inventory | selected: slot}}

  def select(_, _), do: {:error, :invalid_selection}

  def swap_hands(inventory) do
    main = held(inventory, :main)
    off = held(inventory, :off)

    inventory
    |> cancel_drag()
    |> put(36 + inventory.selected, off)
    |> put(45, main)
    |> advance()
  end

  @doc "Plans a click and at most five world drops; the caller owns durable commit/continuation."
  def plan_click(%{drag: drag} = inventory, action, slot, button)
      when drag != nil and action != :quick_craft do
    with {:ok, next} <- click(inventory, action, slot, button), do: {:ok, next, []}
  end

  def plan_click(inventory, :quick_move, 0, button) when button in [0, 1] do
    case crafting_result(inventory) do
      nil -> finish_crafting(inventory, [])
      result -> quick_move_crafting(inventory, result, 99)
    end
  end

  def plan_click(inventory, action, -999, button)
      when action in [:pickup, :quick_move] and button in [0, 1] do
    stack = inventory.carried

    if stack do
      count = if button == 0, do: stack.count, else: 1
      next = %{inventory | carried: sized(stack, stack.count - count)}
      with {:ok, next} <- finish(next), do: {:ok, next, [sized(stack, count)]}
    else
      with {:ok, next} <- finish(inventory), do: {:ok, next, []}
    end
  end

  def plan_click(inventory, :throw, 0, button) when button in -128..127 do
    case {inventory.carried, crafting_result(inventory), button} do
      {nil, %ItemStack{} = result, 1} ->
        drop_crafting(inventory, result, 5, [])

      {nil, %ItemStack{} = result, _} ->
        finish_crafting(consume_crafting_inputs(inventory), [result])

      _ ->
        finish_crafting(inventory, [])
    end
  end

  def plan_click(inventory, :throw, slot, button)
      when (click_slot(slot) or slot in [0, -1, -999]) and button in -128..127 do
    stack = if slot not in [-1, -999] and inventory.carried == nil, do: get(inventory, slot)

    if stack do
      # Result drops need a recipe conversion plan, not ordinary conservation.
      count = if button == 0, do: 1, else: stack.count
      next = put(inventory, slot, sized(stack, stack.count - count))
      with {:ok, next} <- finish(next), do: {:ok, next, [sized(stack, count)]}
    else
      with {:ok, next} <- finish(inventory), do: {:ok, next, []}
    end
  end

  def plan_click(inventory, action, slot, button) do
    with {:ok, next} <- click(inventory, action, slot, button), do: {:ok, next, []}
  end

  def click(inventory, :quick_craft, slot, button) when button in 0..11,
    do: quick_craft(inventory, slot, Bitwise.band(button, 3), Bitwise.bsr(button, 2))

  def click(_, :quick_craft, _, _), do: {:error, :unsupported_click}

  # Vanilla consumes an interrupting click solely to reset the active gesture.
  def click(%{drag: drag} = inventory, _, _, _) when drag != nil,
    do: {:ok, inventory |> cancel_drag() |> advance()}

  def click(inventory, action, slot, button), do: ordinary_click(inventory, action, slot, button)

  defp ordinary_click(inventory, :pickup, 0, button) when button in [0, 1] do
    result = crafting_result(inventory)
    cursor = inventory.carried

    cond do
      result == nil ->
        finish(inventory)

      specialized_click?(cursor) or (cursor != nil and specialized_click?(result)) ->
        {:error, :unsupported_click}

      cursor == nil or
          (compatible?(cursor, result) and
             cursor.count + result.count <= ItemStack.max_stack_size(cursor)) ->
        next = consume_crafting_inputs(inventory)

        carried = if cursor, do: sized(cursor, cursor.count + result.count), else: result
        finish(%{next | carried: carried})

      true ->
        finish(inventory)
    end
  end

  defp ordinary_click(inventory, :quick_move, 0, button) when button in [0, 1] do
    case plan_click(inventory, :quick_move, 0, button) do
      {:ok, next, []} -> {:ok, next}
      {:ok, _, [_ | _]} -> {:error, :world_drop_required}
      error -> error
    end
  end

  defp ordinary_click(inventory, :swap, 0, button) when button in 0..8 or button == 40 do
    target = if button == 40, do: 45, else: 36 + button

    case {crafting_result(inventory), get(inventory, target)} do
      {%ItemStack{} = result, nil} ->
        inventory |> consume_crafting_inputs() |> put(target, result) |> finish()

      _ ->
        finish(inventory)
    end
  end

  defp ordinary_click(inventory, :clone, 0, _) do
    case {inventory.infinite_materials, inventory.carried, crafting_result(inventory)} do
      {true, nil, %ItemStack{} = result} ->
        finish(%{inventory | carried: sized(result, ItemStack.max_stack_size(result))})

      _ ->
        finish(inventory)
    end
  end

  defp ordinary_click(inventory, :pickup_all, 0, button) when button in [0, 1] do
    if crafting_result(inventory),
      do: finish(inventory),
      else: inventory |> collect(0, button) |> finish()
  end

  defp ordinary_click(inventory, :pickup, slot, button)
       when click_slot(slot) and button in [0, 1] do
    if specialized_click?(get(inventory, slot)) or specialized_click?(inventory.carried),
      do: {:error, :unsupported_click},
      else: inventory |> pickup(slot, button) |> finish()
  end

  defp ordinary_click(inventory, :swap, slot, button)
       when click_slot(slot) and (button in 0..8 or button == 40) do
    target = if button == 40, do: 45, else: 36 + button
    first = get(inventory, slot)
    second = get(inventory, target)

    if can_place?(slot, second) and can_place?(target, first) do
      inventory |> put(slot, second) |> put(target, first) |> finish()
    else
      {:error, :slot_restricted}
    end
  end

  defp ordinary_click(inventory, :quick_move, slot, button)
       when click_slot(slot) and button in [0, 1],
       do: inventory |> quick_move(slot) |> finish()

  defp ordinary_click(inventory, :pickup_all, slot, button)
       when (click_slot(slot) or slot == 0) and button in [0, 1],
       do: inventory |> collect(slot, button) |> finish()

  defp ordinary_click(inventory, :clone, slot, _) when click_slot(slot) or slot == 0 do
    source = get(inventory, slot)

    if inventory.infinite_materials and inventory.carried == nil and source != nil,
      do: %{inventory | carried: sized(source, ItemStack.max_stack_size(source))} |> finish(),
      else: finish(inventory)
  end

  defp ordinary_click(_, _, _, _), do: {:error, :unsupported_click}

  defp quick_craft(%{carried: nil} = inventory, _, _, _),
    do: {:ok, inventory |> cancel_drag() |> advance()}

  defp quick_craft(%{infinite_materials: false} = inventory, _, 0, 2),
    do: {:ok, inventory |> cancel_drag() |> advance()}

  defp quick_craft(%{drag: nil} = inventory, _, 0, mode) do
    if mode != 2 and specialized_click?(inventory.carried),
      do: {:error, :unsupported_click},
      else: {:ok, advance(%{inventory | drag: %{mode: mode, slots: MapSet.new()}})}
  end

  defp quick_craft(%{drag: drag} = inventory, slot, 1, _) when drag != nil do
    slots =
      if drag_target?(inventory, slot) and
           (drag.mode == 2 or inventory.carried.count > MapSet.size(drag.slots)),
         do: MapSet.put(drag.slots, slot),
         else: drag.slots

    {:ok, advance(%{inventory | drag: %{drag | slots: slots}})}
  end

  defp quick_craft(%{drag: drag} = inventory, _, 2, _) when drag != nil do
    case Enum.sort(drag.slots) do
      [_slot] when drag.mode == 2 ->
        # Vanilla delegates a single target to PICKUP with button 2, a no-op.
        cancel_drag(inventory) |> finish()

      [slot] ->
        ordinary_click(cancel_drag(inventory), :pickup, slot, drag.mode)

      slots ->
        cursor = inventory.carried
        count = length(slots)

        each =
          case drag.mode do
            0 -> div(cursor.count, max(count, 1))
            1 -> 1
            2 -> ItemStack.max_stack_size(cursor)
          end

        {next, left} =
          Enum.reduce(slots, {inventory, cursor.count}, fn slot, {next, left} ->
            if drag_target?(inventory, slot) and (drag.mode == 2 or cursor.count >= count) do
              present = get(inventory, slot)
              existing = if present, do: present.count, else: 0
              added = min(each, max(slot_limit(slot, cursor) - existing, 0))
              {put(next, slot, sized(cursor, existing + added)), left - added}
            else
              {next, left}
            end
          end)

        %{cancel_drag(next) | carried: sized(cursor, left)} |> finish()
    end
  end

  defp quick_craft(inventory, _, _, _),
    do: {:ok, inventory |> cancel_drag() |> advance()}

  defp drag_target?(inventory, slot) when click_slot(slot) do
    cursor = inventory.carried
    present = get(inventory, slot)

    allow_override = inventory.drag != nil and inventory.drag.mode == 2

    can_place_type?(slot, cursor) and (allow_override or not specialized_click?(present)) and
      (present == nil or
         (compatible?(present, cursor) and present.count <= ItemStack.max_stack_size(cursor)))
  end

  defp drag_target?(_, _), do: false

  def encoded_size(inventory),
    do:
      Enum.reduce(
        display_contents(inventory) ++ table_contents(inventory),
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

  defp quick_move(%{table_inputs: cells} = inventory, slot) when cells != nil do
    case get(inventory, slot) do
      nil ->
        inventory

      stack ->
        groups =
          if slot in 9..44 do
            # Native QUICK_MOVE retries a partially moved source. Finish its grid
            # admission before routing the remainder to the other storage section.
            [
              Enum.map(0..8, &{:table, &1}),
              if(slot in 9..35, do: Enum.to_list(36..44), else: Enum.to_list(9..35))
            ]
          else
            [Enum.to_list(9..44)]
          end

        {next, left} =
          Enum.reduce(groups, {inventory, stack.count}, fn targets, {next, left} ->
            {next, left} = transfer(next, stack, left, targets, :merge)
            transfer(next, stack, left, targets, :empty)
          end)

        put(next, slot, sized(stack, left))
    end
  end

  defp quick_move(inventory, slot) do
    stack = get(inventory, slot)
    equipment = if stack, do: equipment_slot(stack)

    targets =
      cond do
        stack == nil ->
          []

        slot in 9..45 and equipment != nil and equipment != slot and
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

  defp consume_crafting_inputs(inventory) do
    inputs = if inventory.table_inputs, do: Enum.map(0..8, &{:table, &1}), else: 1..4

    Enum.reduce(inputs, inventory, fn slot, next ->
      case get(next, slot) do
        nil -> next
        stack -> put(next, slot, sized(stack, stack.count - 1))
      end
    end)
  end

  defp finish_crafting(inventory, stacks) do
    with {:ok, next} <- finish(inventory), do: {:ok, next, stacks}
  end

  defp drop_crafting(inventory, _, 0, drops), do: finish_crafting(inventory, Enum.reverse(drops))

  defp drop_crafting(inventory, original, budget, drops) do
    result = crafting_result(inventory)

    if result != nil and compatible?(result, original),
      do:
        drop_crafting(consume_crafting_inputs(inventory), original, budget - 1, [result | drops]),
      else: finish_crafting(inventory, Enum.reverse(drops))
  end

  defp quick_move_crafting(inventory, _, 0), do: finish_crafting(inventory, [])

  defp quick_move_crafting(inventory, original, remaining) do
    result = crafting_result(inventory)

    if result != nil and compatible?(result, original) do
      targets = Enum.to_list(44..9//-1)
      {next, left} = transfer(inventory, result, result.count, targets, :merge)
      {next, left} = transfer(next, result, left, targets, :empty)

      cond do
        left == result.count -> finish_crafting(inventory, [])
        left > 0 -> finish_crafting(consume_crafting_inputs(next), [sized(result, left)])
        true -> quick_move_crafting(consume_crafting_inputs(next), original, remaining - 1)
      end
    else
      finish_crafting(inventory, [])
    end
  end

  defp collect(%{carried: nil} = inventory, _, _), do: inventory

  defp collect(inventory, slot, button) do
    if get(inventory, slot) != nil do
      inventory
    else
      visible =
        if inventory.table_inputs,
          do: Enum.map(0..8, &{:table, &1}) ++ Enum.to_list(9..44),
          else: Enum.to_list(1..45)

      targets = if button == 0, do: visible, else: Enum.reverse(visible)

      Enum.reduce([:partial, :all], inventory, fn pass, inventory ->
        Enum.reduce(targets, inventory, fn slot, inventory ->
          cursor = inventory.carried
          present = get(inventory, slot)
          maximum = ItemStack.max_stack_size(cursor)

          if present != nil and cursor.count < maximum and compatible?(present, cursor) and
               (pass == :all or present.count != ItemStack.max_stack_size(present)) do
            moved = min(present.count, maximum - cursor.count)

            %{
              put(inventory, slot, sized(present, present.count - moved))
              | carried: sized(cursor, cursor.count + moved)
            }
          else
            inventory
          end
        end)
      end)
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

  defp compatible?(first, second), do: ItemStack.same_item?(first, second)

  defp specialized_click?(nil), do: false

  defp specialized_click?(stack),
    do: ItemTypes.item(stack.item_id)["inventory_click_override"] == true

  defp sized(_, count) when count <= 0, do: nil
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

  defp put(%{table_inputs: cells} = inventory, {:table, index}, stack)
       when is_tuple(cells) and tuple_size(cells) == 9 and index in 0..8,
       do: %{inventory | table_inputs: put_elem(cells, index, stack)}

  defp put(inventory, slot, nil), do: %{inventory | slots: Map.delete(inventory.slots, slot)}

  defp put(inventory, slot, stack),
    do: %{inventory | slots: Map.put(inventory.slots, slot, stack)}
end
