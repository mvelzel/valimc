defmodule Valimc.CookingClick do
  @moduledoc "Pure drop-free cooking-slot exchanges; journal, input-reset hooks and awards are external."
  alias Valimc.{Cooking, CookingMenu, CookingRecipes, Inventory}
  alias Valimc.CookingBlocks
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}
  @bucket Data.item("bucket")
  @max_bytes 524_288

  def plan(
        block,
        storage,
        %Inventory{drag: nil, table_inputs: nil} = inventory,
        action,
        wire,
        button
      ) do
    with true <- CookingBlocks.kind(block) != nil,
         {:ok, _} <- CookingMenu.contents(%Cooking{slots: storage}, inventory),
         {:ok, address} <- CookingMenu.address(wire),
         {:ok, next} <- click({storage, inventory}, block, address, action, button) do
      finish(next, elem(storage, 2))
    else
      _ -> {:error, :unsupported_cooking_click}
    end
  rescue
    _ -> {:error, :invalid_cooking_click}
  catch
    _, _ -> {:error, :invalid_cooking_click}
  end

  def plan(_, _, _, _, _, _), do: {:error, :unsupported_cooking_click}

  defp click({_, inventory} = state, _, address, :pickup, button) when button in [0, 1] do
    present = get(state, address)
    cursor = inventory.carried

    if override?(present) or override?(cursor),
      do: {:error, :unsupported_cooking_click},
      else: {:ok, pickup(state, address, present, cursor, button)}
  end

  defp click(state, block, address, :quick_move, button) when button in [0, 1] do
    case get(state, address) do
      nil ->
        {:ok, state}

      source ->
        targets = targets(address, source, block)
        {next, left} = transfer(state, source, source.count, targets, :merge)
        {next, left} = transfer(next, source, left, targets, :empty)
        {:ok, put(next, address, sized(source, left))}
    end
  end

  defp click(state, _, address, :swap, button) when button in 0..8 or button == 40 do
    target = if button == 40, do: 45, else: 36 + button
    source = get(state, address)
    other = get(state, target)

    cond do
      not may_place?(address, other) ->
        {:ok, state}

      not fits?(source, target) or not fits?(other, address) ->
        {:error, :unsupported_cooking_click}

      true ->
        {:ok, state |> put(address, other) |> put(target, source)}
    end
  end

  defp click(_, _, _, _, _), do: {:error, :unsupported_cooking_click}

  defp pickup(state, address, present, cursor, button) do
    cond do
      cursor == nil and present != nil ->
        count = if button == 0, do: present.count, else: div(present.count + 1, 2)

        state
        |> put(address, sized(present, present.count - count))
        |> cursor(sized(present, count))

      cursor != nil and present == nil and may_place?(address, cursor) ->
        count = min(if(button == 0, do: cursor.count, else: 1), capacity(address, cursor))
        state |> put(address, sized(cursor, count)) |> cursor(sized(cursor, cursor.count - count))

      cursor != nil and present != nil and ItemStack.same_item?(cursor, present) and
          may_place?(address, cursor) ->
        count =
          min(
            if(button == 0, do: cursor.count, else: 1),
            max(capacity(address, cursor) - present.count, 0)
          )

        state
        |> put(address, sized(present, present.count + count))
        |> cursor(sized(cursor, cursor.count - count))

      cursor != nil and present != nil and may_place?(address, cursor) and fits?(cursor, address) ->
        state |> put(address, cursor) |> cursor(present)

      cursor != nil and present != nil and not may_place?(address, cursor) and
        ItemStack.same_item?(cursor, present) and
          cursor.count + present.count <= ItemStack.max_stack_size(cursor) ->
        count = present.count

        state
        |> put(address, sized(present, present.count - count))
        |> cursor(sized(cursor, cursor.count + count))

      true ->
        state
    end
  end

  defp targets({:cooking, 2}, _, _), do: Enum.to_list(44..9//-1)
  defp targets({:cooking, _}, _, _), do: Enum.to_list(9..44)

  defp targets(slot, stack, block) do
    cond do
      match?({:ok, _}, CookingRecipes.find(stack, block)) -> [{:cooking, 0}]
      fuel?(stack) -> [{:cooking, 1}]
      slot in 9..35 -> Enum.to_list(36..44)
      true -> Enum.to_list(9..35)
    end
  end

  defp transfer(state, stack, count, targets, mode) do
    Enum.reduce_while(targets, {state, count}, fn target, {state, left} ->
      if left == 0 do
        {:halt, {state, left}}
      else
        present = get(state, target)

        eligible =
          case mode do
            :merge -> present != nil and ItemStack.same_item?(present, stack)
            :empty -> present == nil and may_place?(target, stack)
          end

        if eligible do
          current = if present, do: present.count, else: 0
          moved = min(left, max(capacity(target, stack) - current, 0))
          {:cont, {put(state, target, sized(present || stack, current + moved)), left - moved}}
        else
          {:cont, {state, left}}
        end
      end
    end)
  end

  defp finish({storage, inventory}, previous_output) do
    bytes =
      Enum.reduce(Tuple.to_list(storage), 0, fn stack, size ->
        size + IO.iodata_length(ItemStack.encode(stack))
      end)

    if bytes <= @max_bytes and Inventory.encoded_size(inventory) <= @max_bytes do
      taken = max(count(previous_output) - count(elem(storage, 2)), 0)
      {:ok, storage, Inventory.advance(inventory), taken}
    else
      {:error, :cooking_click_byte_limit}
    end
  end

  defp may_place?(_, nil), do: true
  defp may_place?({:cooking, 2}, _), do: false
  defp may_place?({:cooking, 1}, stack), do: stack.item_id == @bucket or fuel?(stack)
  defp may_place?(_, _), do: true
  defp capacity({:cooking, 1}, %{item_id: @bucket}), do: 1
  defp capacity(_, stack), do: ItemStack.max_stack_size(stack)
  defp fits?(nil, _), do: true
  defp fits?(stack, address), do: stack.count <= capacity(address, stack)

  defp fuel?(%ItemStack{item_id: item, components: components, removed: removed}) do
    if Map.has_key?(components, "minecraft:cooking_fuel"), do: throw(:unsupported_cooking_fuel)

    not MapSet.member?(removed, "minecraft:cooking_fuel") and
      MapSet.member?(ItemTypes.defaults(item).present, "minecraft:cooking_fuel")
  end

  defp get({storage, _}, {:cooking, index}), do: elem(storage, index)
  defp get({_, inventory}, slot), do: Inventory.get(inventory, slot)

  defp put({storage, inventory}, {:cooking, index}, stack),
    do: {put_elem(storage, index, stack), inventory}

  defp put({storage, inventory}, slot, stack) do
    slots =
      if stack == nil,
        do: Map.delete(inventory.slots, slot),
        else: Map.put(inventory.slots, slot, stack)

    {storage, %{inventory | slots: slots}}
  end

  defp cursor({storage, inventory}, stack), do: {storage, %{inventory | carried: stack}}
  defp sized(_, count) when count <= 0, do: nil
  defp sized(stack, count), do: %{stack | count: count}
  defp count(nil), do: 0
  defp count(stack), do: stack.count
  defp override?(nil), do: false
  defp override?(stack), do: ItemTypes.item(stack.item_id)["inventory_click_override"] == true
end
