defmodule Valimc.Menus.Click do
  @moduledoc """
  The one click engine (VMC-077i2): vanilla's `AbstractContainerMenu.doClick`
  over a menu's slot description (`Valimc.Menus.Menu`), for the player's inventory,
  a crafting table, chests and furnaces alike. Every gesture: pick up and put
  down (buttons 0 and 1, and outside the window to drop), shift-click, number
  and offhand swaps, creative clone, throw, drag (`quick_craft`) and
  double-click collect, plus the crafting result's gestures.

  Pure: `plan/6` returns the storage (a chest's or furnace's slot tuple, nil
  for the player's own menus), the inventory with its state id advanced, and
  at most five stacks to drop into the world, which the caller commits. A
  swap that would push a stack past its slot's limit, or a click on an item
  with its own click behaviour (bundles), is refused, not planned.
  """
  alias Valimc.Menus.{Inventory, Menu}
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @max_bytes 524_288
  @max_drops 5

  @doc "`{:ok, storage, inventory, drops}` or `{:error, reason}`."
  def plan(%Menu{} = menu, storage, %Inventory{} = inventory, action, wire, button) do
    with :ok <- contents?(menu, storage, inventory),
         {:ok, address} <- address(menu, action, wire),
         {:ok, {storage, inventory}, drops} <-
           gesture(menu, {storage, inventory}, action, address, button) do
      finish(storage, inventory, drops)
    end
  rescue
    _ -> {:error, :invalid_click}
  catch
    _, _ -> {:error, :invalid_click}
  end

  @doc "The same click, refused when it would drop anything: `{:ok, storage, inventory}`."
  def plan_without_drops(menu, storage, inventory, action, wire, button) do
    case plan(menu, storage, inventory, action, wire, button) do
      {:ok, storage, inventory, []} -> {:ok, storage, inventory}
      {:ok, _, _, [_ | _]} -> {:error, :world_drop_required}
      error -> error
    end
  end

  # A drag passes over slots that are not the menu's: they are not targets.
  defp address(menu, action, wire) do
    case Menu.address(menu, wire) do
      {:ok, address} -> {:ok, address}
      _ when action == :quick_craft -> {:ok, :none}
      error -> error
    end
  end

  defp contents?(%Menu{kind: kind}, nil, inventory) when kind in [:inventory, :table] do
    if kind == :table and inventory.table_inputs == nil, do: {:error, :table_not_open}, else: :ok
  end

  defp contents?(menu, storage, inventory) do
    case Menu.contents(menu, storage, inventory) do
      {:ok, _} -> if inventory.table_inputs == nil, do: :ok, else: {:error, :unsupported_click}
      error -> error
    end
  end

  # An active drag: any other click only resets it (vanilla consumes it).
  defp gesture(_menu, {storage, %{drag: drag} = inventory}, action, _address, _button)
       when drag != nil and action != :quick_craft,
       do: {:ok, {storage, Inventory.cancel_drag(inventory)}, []}

  defp gesture(menu, state, :quick_craft, address, button) when button in 0..11,
    do: quick_craft(menu, state, address, Bitwise.band(button, 3), Bitwise.bsr(button, 2))

  defp gesture(_menu, _state, :quick_craft, _address, _button), do: {:error, :unsupported_click}

  # The crafting result of the open grid.
  defp gesture(menu, state, action, 0, button) when menu.kind in [:inventory, :table],
    do: result_gesture(state, action, button)

  defp gesture(_menu, {storage, inventory}, action, -999, button)
       when action in [:pickup, :quick_move] and button in [0, 1] do
    case inventory.carried do
      nil ->
        {:ok, {storage, inventory}, []}

      stack ->
        count = if button == 0, do: stack.count, else: 1

        {:ok, {storage, %{inventory | carried: sized(stack, stack.count - count)}},
         [sized(stack, count)]}
    end
  end

  # Outside the slots nothing else happens (vanilla returns early).
  defp gesture(_menu, state, action, address, _button)
       when address in [-1, -999] and
              action in [:throw, :pickup, :quick_move, :swap, :clone, :pickup_all],
       do: {:ok, state, []}

  defp gesture(menu, {_, inventory} = state, :throw, address, button) when button in -128..127 do
    case if(inventory.carried == nil, do: get(state, address)) do
      nil ->
        {:ok, state, []}

      stack ->
        if Menu.may_pickup?(menu, address, stack, inventory.infinite_materials),
          do: throw_stack(state, address, stack, button),
          else: {:ok, state, []}
    end
  end

  defp gesture(menu, {_, inventory} = state, :pickup, address, button) when button in [0, 1] do
    present = get(state, address)

    cond do
      special?(present) or special?(inventory.carried) ->
        {:error, :unsupported_click}

      not Menu.may_pickup?(menu, address, present, inventory.infinite_materials) ->
        {:ok, state, []}

      true ->
        {:ok, pickup(menu, state, address, present, inventory.carried, button), []}
    end
  end

  defp gesture(menu, {_, inventory} = state, :quick_move, address, button)
       when button in [0, 1] do
    case get(state, address) do
      nil ->
        {:ok, state, []}

      stack ->
        if Menu.may_pickup?(menu, address, stack, inventory.infinite_materials),
          do: {:ok, quick_move(menu, state, address, stack), []},
          else: {:ok, state, []}
    end
  end

  defp gesture(menu, {_, inventory} = state, :swap, address, button)
       when button in 0..8 or button == 40 do
    target = if button == 40, do: 45, else: 36 + button
    source = get(state, address)
    other = get(state, target)

    cond do
      # Vanilla leaves a slot that does not take the hotbar's stack as it is,
      # or keeps what it may not give up.
      not Menu.may_place?(menu, address, other) or
          not Menu.may_pickup?(menu, address, source, inventory.infinite_materials) ->
        {:ok, state, []}

      # Past a slot's limit vanilla splits and may drop: not planned here.
      not fits?(menu, target, source) or not fits?(menu, address, other) ->
        {:error, :unsupported_click}

      true ->
        {:ok, state |> put(address, other) |> put(target, source), []}
    end
  end

  defp gesture(_menu, {_, inventory} = state, :clone, address, _button) do
    source = get(state, address)

    if inventory.infinite_materials and inventory.carried == nil and source != nil,
      do: {:ok, cursor(state, sized(source, ItemStack.max_stack_size(source))), []},
      else: {:ok, state, []}
  end

  defp gesture(menu, state, :pickup_all, address, button) when button in [0, 1],
    do: {:ok, collect(menu, state, address, button), []}

  defp gesture(_menu, _state, _action, _address, _button), do: {:error, :unsupported_click}

  defp throw_stack(state, address, stack, button) do
    count = if button == 0, do: 1, else: stack.count
    {:ok, put(state, address, sized(stack, stack.count - count)), [sized(stack, count)]}
  end

  ## Pick up and put down

  defp pickup(menu, state, address, present, cursor, button) do
    cond do
      cursor == nil and present != nil ->
        count = if button == 0, do: present.count, else: div(present.count + 1, 2)

        state
        |> put(address, sized(present, present.count - count))
        |> cursor(sized(present, count))

      cursor != nil and present == nil and Menu.may_place?(menu, address, cursor) ->
        count = min(if(button == 0, do: cursor.count, else: 1), Menu.limit(menu, address, cursor))
        state |> put(address, sized(cursor, count)) |> cursor(sized(cursor, cursor.count - count))

      cursor != nil and present != nil and same?(cursor, present) and
          Menu.may_place?(menu, address, cursor) ->
        count =
          min(
            if(button == 0, do: cursor.count, else: 1),
            max(Menu.limit(menu, address, cursor) - present.count, 0)
          )

        state
        |> put(address, sized(present, present.count + count))
        |> cursor(sized(cursor, cursor.count - count))

      cursor != nil and present != nil and Menu.may_place?(menu, address, cursor) and
          fits?(menu, address, cursor) ->
        state |> put(address, cursor) |> cursor(present)

      # A slot that takes nothing (a result) gives its whole stack to a
      # matching cursor that can hold it (vanilla's `tryRemove`).
      cursor != nil and present != nil and not Menu.may_place?(menu, address, cursor) and
        same?(cursor, present) and
          cursor.count + present.count <= ItemStack.max_stack_size(cursor) ->
        state |> put(address, nil) |> cursor(sized(cursor, cursor.count + present.count))

      true ->
        state
    end
  end

  ## Shift-click

  defp quick_move(menu, {_, inventory} = state, address, stack) do
    {state, left} =
      menu
      |> Menu.routes(inventory, address, stack)
      |> Enum.reduce({state, stack.count}, fn targets, {state, left} ->
        {state, left} = transfer(menu, state, stack, left, targets, :merge)
        transfer(menu, state, stack, left, targets, :empty)
      end)

    put(state, address, sized(stack, left))
  end

  defp transfer(menu, state, stack, count, targets, mode) do
    Enum.reduce(targets, {state, count}, fn address, {state, left} ->
      present = get(state, address)

      matches =
        if mode == :merge,
          do: present != nil and same?(present, stack),
          else: present == nil

      if left > 0 and matches and Menu.may_place?(menu, address, stack) do
        existing = if present, do: present.count, else: 0
        moved = min(left, max(Menu.limit(menu, address, stack) - existing, 0))
        {put(state, address, sized(stack, existing + moved)), left - moved}
      else
        {state, left}
      end
    end)
  end

  ## Double-click collect

  defp collect(_menu, {_, %{carried: nil}} = state, _address, _button), do: state

  defp collect(menu, state, address, button) do
    if get(state, address) != nil do
      state
    else
      visible = Menu.visible(menu)
      targets = if button == 0, do: visible, else: Enum.reverse(visible)

      Enum.reduce([:partial, :all], state, fn pass, state ->
        Enum.reduce(targets, state, &collect_from(menu, &2, &1, pass))
      end)
    end
  end

  defp collect_from(menu, {_, inventory} = state, address, pass) do
    cursor = inventory.carried
    present = get(state, address)
    maximum = ItemStack.max_stack_size(cursor)

    if present != nil and cursor.count < maximum and same?(present, cursor) and
         (pass == :all or present.count != ItemStack.max_stack_size(present)) and
         Menu.may_pickup?(menu, address, present, inventory.infinite_materials) do
      moved = min(present.count, maximum - cursor.count)

      # A slot that takes nothing gives its stack only whole (`safeTake`).
      if moved < present.count and not Menu.may_place?(menu, address, present),
        do: state,
        else:
          state
          |> put(address, sized(present, present.count - moved))
          |> cursor(sized(cursor, cursor.count + moved))
    else
      state
    end
  end

  ## Drag

  defp quick_craft(_menu, {storage, %{carried: nil} = inventory}, _, _, _),
    do: {:ok, {storage, Inventory.cancel_drag(inventory)}, []}

  defp quick_craft(_menu, {storage, %{infinite_materials: false} = inventory}, _, 0, 2),
    do: {:ok, {storage, Inventory.cancel_drag(inventory)}, []}

  defp quick_craft(_menu, {storage, %{drag: nil} = inventory}, _, 0, mode) do
    if mode != 2 and special?(inventory.carried),
      do: {:error, :unsupported_click},
      else: {:ok, {storage, %{inventory | drag: %{mode: mode, slots: MapSet.new()}}}, []}
  end

  defp quick_craft(menu, {storage, %{drag: drag} = inventory} = state, address, 1, _)
       when drag != nil do
    slots =
      if drag_target?(menu, state, address) and
           (drag.mode == 2 or inventory.carried.count > MapSet.size(drag.slots)),
         do: MapSet.put(drag.slots, address),
         else: drag.slots

    {:ok, {storage, %{inventory | drag: %{drag | slots: slots}}}, []}
  end

  defp quick_craft(menu, {storage, %{drag: drag} = inventory} = state, _, 2, _)
       when drag != nil do
    plain = {storage, Inventory.cancel_drag(inventory)}

    case Enum.sort(drag.slots) do
      # Vanilla gives one target to PICKUP with button 2: a no-op.
      [_address] when drag.mode == 2 ->
        {:ok, plain, []}

      [address] ->
        gesture(menu, plain, :pickup, address, drag.mode)

      addresses ->
        cursor = inventory.carried
        count = length(addresses)

        each =
          case drag.mode do
            0 -> div(cursor.count, max(count, 1))
            1 -> 1
            2 -> ItemStack.max_stack_size(cursor)
          end

        {next, left} =
          Enum.reduce(addresses, {plain, cursor.count}, fn address, {next, left} ->
            if drag_target?(menu, state, address) and (drag.mode == 2 or cursor.count >= count) do
              present = get(state, address)
              existing = if present, do: present.count, else: 0
              added = min(each, max(Menu.limit(menu, address, cursor) - existing, 0))
              {put(next, address, sized(cursor, existing + added)), left - added}
            else
              {next, left}
            end
          end)

        {:ok, cursor(next, sized(cursor, left)), []}
    end
  end

  defp quick_craft(_menu, {storage, inventory}, _, _, _),
    do: {:ok, {storage, Inventory.cancel_drag(inventory)}, []}

  defp drag_target?(_menu, _state, address) when address in [0, -1, -999, :none], do: false

  defp drag_target?(menu, {_, inventory} = state, address) do
    cursor = inventory.carried
    present = get(state, address)
    override = inventory.drag != nil and inventory.drag.mode == 2

    Menu.may_place?(menu, address, cursor) and (override or not special?(present)) and
      (present == nil or
         (same?(present, cursor) and present.count <= ItemStack.max_stack_size(cursor)))
  end

  ## The crafting result

  defp result_gesture({_, inventory} = state, :quick_move, button) when button in [0, 1] do
    case Inventory.crafting_result(inventory) do
      nil -> {:ok, state, []}
      result -> quick_move_crafting(state, result, 99, [])
    end
  end

  defp result_gesture({_, inventory} = state, :pickup, button) when button in [0, 1] do
    result = Inventory.crafting_result(inventory)
    cursor = inventory.carried

    cond do
      result == nil ->
        {:ok, state, []}

      special?(cursor) or (cursor != nil and special?(result)) ->
        {:error, :unsupported_click}

      cursor == nil or
          (same?(cursor, result) and
             cursor.count + result.count <= ItemStack.max_stack_size(cursor)) ->
        {state, drops} = consume_inputs(state)
        carried = if cursor, do: sized(cursor, cursor.count + result.count), else: result
        {:ok, cursor(state, carried), drops}

      true ->
        {:ok, state, []}
    end
  end

  defp result_gesture({_, inventory} = state, :swap, button)
       when button in 0..8 or button == 40 do
    target = if button == 40, do: 45, else: 36 + button

    case {Inventory.crafting_result(inventory), get(state, target)} do
      {%ItemStack{} = result, nil} ->
        {state, drops} = state |> put(target, result) |> consume_inputs()
        {:ok, state, drops}

      _ ->
        {:ok, state, []}
    end
  end

  defp result_gesture({_, inventory} = state, :throw, button) when button in -128..127 do
    case {inventory.carried, Inventory.crafting_result(inventory), button} do
      {nil, %ItemStack{} = result, 1} ->
        drop_crafting(state, result, @max_drops, [])

      {nil, %ItemStack{} = result, _} ->
        {state, drops} = consume_inputs(state)
        {:ok, state, drops ++ [result]}

      _ ->
        {:ok, state, []}
    end
  end

  defp result_gesture({_, inventory} = state, :clone, _button) do
    case {inventory.infinite_materials, inventory.carried, Inventory.crafting_result(inventory)} do
      {true, nil, %ItemStack{} = result} ->
        {:ok, cursor(state, sized(result, ItemStack.max_stack_size(result))), []}

      _ ->
        {:ok, state, []}
    end
  end

  defp result_gesture({_, inventory} = state, :pickup_all, button) when button in [0, 1] do
    if Inventory.crafting_result(inventory) do
      {:ok, state, []}
    else
      menu = if inventory.table_inputs, do: Menu.table(), else: Menu.inventory()
      {:ok, collect(menu, state, 0, button), []}
    end
  end

  defp result_gesture(_state, _action, _button), do: {:error, :unsupported_click}

  defp drop_crafting(state, _, 0, drops), do: {:ok, state, drops}

  defp drop_crafting({_, inventory} = state, original, budget, drops) do
    result = Inventory.crafting_result(inventory)

    if result != nil and same?(result, original) do
      {next, remainders} = consume_inputs(state)
      batch = remainders ++ [result]

      if length(batch) <= budget,
        do: drop_crafting(next, original, budget - length(batch), drops ++ batch),
        else: {:ok, state, drops}
    else
      {:ok, state, drops}
    end
  end

  defp quick_move_crafting(state, _, 0, drops), do: {:ok, state, drops}

  defp quick_move_crafting({_, inventory} = state, original, remaining, drops) do
    result = Inventory.crafting_result(inventory)

    if result != nil and same?(result, original) do
      targets = Enum.to_list(44..9//-1)
      menu = Menu.inventory()
      {next, left} = transfer(menu, state, result, result.count, targets, :merge)
      {next, left} = transfer(menu, next, result, left, targets, :empty)

      if left == result.count do
        {:ok, state, drops}
      else
        {next, remainders} = consume_inputs(next)
        batch = remainders ++ if(left > 0, do: [sized(result, left)], else: [])

        cond do
          length(drops) + length(batch) > @max_drops -> {:ok, state, drops}
          left > 0 -> {:ok, next, drops ++ batch}
          true -> quick_move_crafting(next, original, remaining - 1, drops ++ batch)
        end
      end
    else
      {:ok, state, drops}
    end
  end

  # Taking a result uses one of every input; a remainder (a bucket) stays in
  # its input, or goes back to the inventory, or is dropped.
  defp consume_inputs({storage, inventory}) do
    inputs = if inventory.table_inputs, do: Enum.map(0..8, &{:table, &1}), else: 1..4

    {inventory, drops} =
      Enum.reduce(inputs, {inventory, []}, fn slot, {next, drops} ->
        case Inventory.get(next, slot) do
          nil ->
            {next, drops}

          stack ->
            remaining = sized(stack, stack.count - 1)
            next = Inventory.put(next, slot, remaining)

            case {Valimc.Menus.Crafting.remainder(stack), remaining} do
              {nil, _} ->
                {next, drops}

              {remainder, nil} ->
                {Inventory.put(next, slot, remainder), drops}

              {remainder, _} ->
                {next, overflow} = Inventory.return_stack(next, remainder)

                if overflow && not inventory.infinite_materials,
                  do: {next, drops ++ [overflow]},
                  else: {next, drops}
            end
        end
      end)

    {{storage, inventory}, drops}
  end

  ## State

  defp finish(storage, inventory, drops) do
    storage_bytes =
      if storage,
        do:
          Enum.reduce(Tuple.to_list(storage), 0, &(&2 + IO.iodata_length(ItemStack.encode(&1)))),
        else: 0

    cond do
      storage_bytes > @max_bytes -> {:error, :storage_byte_limit}
      Inventory.encoded_size(inventory) > @max_bytes -> {:error, :inventory_byte_limit}
      true -> {:ok, storage, Inventory.advance(inventory), drops}
    end
  end

  defp get({storage, _}, {kind, index}) when kind in [:container, :cooking, :brewing],
    do: elem(storage, index)

  defp get({_, inventory}, address), do: Inventory.get(inventory, address)

  defp put({storage, inventory}, {kind, index}, stack)
       when kind in [:container, :cooking, :brewing],
       do: {put_elem(storage, index, stack), inventory}

  defp put({storage, inventory}, address, stack),
    do: {storage, Inventory.put(inventory, address, stack)}

  defp cursor({storage, inventory}, stack), do: {storage, %{inventory | carried: stack}}
  defp sized(_, count) when count <= 0, do: nil
  defp sized(stack, count), do: %{stack | count: count}
  defp same?(first, second), do: ItemStack.same_item?(first, second)
  defp fits?(_menu, _address, nil), do: true
  defp fits?(menu, address, stack), do: stack.count <= Menu.limit(menu, address, stack)
  defp special?(nil), do: false
  defp special?(stack), do: ItemTypes.item(stack.item_id)["inventory_click_override"] == true
end
