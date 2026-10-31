defmodule Valimc.Menus.Inventory do
  @moduledoc """
  A player's inventory: slots, the open table's grid, an open merchant's two
  payment slots (VMC-044b2), the cursor, the selected hotbar slot, the menu
  state id and an active drag. Clicks are planned by the
  one menu engine (`Valimc.Menus.Click`); this module holds the slots and the
  inventory's own plans (eating, drops, cleanup).
  """
  alias Valimc.Protocol.ItemStack
  @max_encoded_bytes 524_288

  defstruct slots: %{},
            table_inputs: nil,
            payments: nil,
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

  def get(%{payments: {a, b}}, {:payment, index}) when index in 0..1,
    do: if(index == 0, do: a, else: b)

  def get(inventory, slot), do: inventory.slots[slot]
  @doc "All owned physical slots; a table's nine transient inputs follow player slots."
  def contents(inventory),
    do:
      Enum.map(0..45, &get(inventory, &1)) ++
        table_contents(inventory) ++ payment_contents(inventory)

  def payment_contents(%{payments: {a, b}}), do: [a, b]
  def payment_contents(_), do: []

  def table_contents(%{table_inputs: nil}), do: []

  def table_contents(%{table_inputs: cells}) when is_tuple(cells) and tuple_size(cells) == 9,
    do: Tuple.to_list(cells)

  def crafting_result(inventory) do
    inputs =
      if inventory.table_inputs,
        do: table_contents(inventory),
        else: Enum.map(1..4, &get(inventory, &1))

    case Valimc.Menus.Crafting.result(inputs) do
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
          Valimc.Living.FoodItems.remainder(
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

  @doc "Drops the whole cursor and grid stacks; disconnected cleanup never merges storage."
  def disconnect(inventory), do: cleanup_batch(inventory, :disconnected)

  defp transient_slots(inventory),
    do:
      [:carried, 1, 2, 3, 4] ++
        if(inventory.table_inputs, do: Enum.map(0..8, &{:table, &1}), else: []) ++
        if(inventory.payments, do: [{:payment, 0}, {:payment, 1}], else: [])

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
    {next, drops} =
      Enum.reduce(transient_slots(inventory), {cancel_drag(inventory), []}, fn slot,
                                                                               {next, drops} ->
        stack = owned_stack(next, slot)
        next = put_owned(next, slot, nil)

        {next, remainder} =
          if mode == :connected, do: return_stack(next, stack), else: {next, stack}

        if remainder, do: {next, [remainder | drops]}, else: {next, drops}
      end)

    with {:ok, next} <-
           next |> put(0, nil) |> clear_empty_table() |> Map.put(:payments, nil) |> finish(),
         do: {:ok, next, Enum.reverse(drops)}
  end

  @death_slots Enum.to_list(36..44) ++
                 Enum.to_list(9..35) ++ [45, 8, 7, 6, 5, :carried, 1, 2, 3, 4]
  @doc """
  A death's drops: every stack but those with Curse of Vanishing, which are
  destroyed. `{:ok, empty, drops, destroyed}`.
  """
  def death(%__MODULE__{} = inventory) do
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
      (@death_slots ++
         if(next.table_inputs, do: Enum.map(0..8, &{:table, &1}), else: []) ++
         if(next.payments, do: [{:payment, 0}, {:payment, 1}], else: []))
      |> Enum.map(fn slot ->
        {slot, owned_stack(next, slot)}
      end)
      |> Enum.reject(fn {_, stack} -> stack == nil end)

    next =
      Enum.reduce(drops, next, fn {slot, _}, next -> put_owned(next, slot, nil) end)
      |> clear_empty_table()
      |> Map.put(:payments, nil)

    if drops == [] and destroyed == [] do
      {:ok, next, [], []}
    else
      with {:ok, next} <- finish(next),
           do: {:ok, next, Enum.map(drops, &elem(&1, 1)), Enum.reverse(destroyed)}
    end
  end

  @doc "Pure native world-stack insertion; remainder mutation is independent of the callback result."
  def pickup_stack(%__MODULE__{} = inventory, nil), do: {:ok, inventory, nil, false}

  def pickup_stack(%__MODULE__{} = inventory, %ItemStack{} = stack) do
    _ = ItemStack.encode(stack)
    {next, remainder} = return_stack(inventory, stack)
    remainder = if inventory.infinite_materials, do: nil, else: remainder
    callback = remainder == nil

    if next == inventory do
      {:ok, inventory, remainder, callback}
    else
      with {:ok, next} <- finish(next), do: {:ok, next, remainder, callback}
    end
  rescue
    _ -> {:error, :invalid_pickup_stack}
  catch
    _, _ -> {:error, :invalid_pickup_stack}
  end

  def pickup_stack(_, _), do: {:error, :invalid_pickup_stack}

  @doc "Return `stack` to the hotbar and storage as vanilla adds it: `{inventory, left over}`."
  def return_stack(inventory, nil), do: {inventory, nil}

  def return_stack(inventory, stack) do
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

  defp compatible?(first, second), do: ItemStack.same_item?(first, second)

  defp sized(_, count) when count <= 0, do: nil
  defp sized(stack, count), do: %{stack | count: count}
  @doc "Put `stack` (nil to empty it) in slot `slot` or table input `{:table, i}`."
  def put(%{payments: {a, b}} = inventory, {:payment, index}, stack) when index in 0..1,
    do: %{inventory | payments: if(index == 0, do: {stack, b}, else: {a, stack})}

  def put(%{table_inputs: cells} = inventory, {:table, index}, stack)
      when is_tuple(cells) and tuple_size(cells) == 9 and index in 0..8,
      do: %{inventory | table_inputs: put_elem(cells, index, stack)}

  def put(inventory, slot, nil), do: %{inventory | slots: Map.delete(inventory.slots, slot)}

  def put(inventory, slot, stack),
    do: %{inventory | slots: Map.put(inventory.slots, slot, stack)}
end
