defmodule Valimc.ContainerClick do
  @moduledoc "Pure drop-free container click plans; region revision and durable transfer admission are external."
  alias Valimc.{ChestMenu, Inventory}
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @max_bytes 524_288

  def plan(rows, storage, %Inventory{drag: nil} = inventory, action, wire, button) do
    with {:ok, _} <- ChestMenu.contents(rows, storage, inventory),
         {:ok, address} <- ChestMenu.address(rows, wire),
         {:ok, next} <- click({storage, inventory}, rows, address, action, button) do
      finish(next)
    end
  rescue
    _ -> {:error, :invalid_container_click}
  catch
    _, _ -> {:error, :invalid_container_click}
  end

  def plan(_, _, _, _, _, _), do: {:error, :unsupported_container_click}

  defp click({_, inventory} = state, _, address, :pickup, button) when button in [0, 1] do
    present = get(state, address)
    cursor = inventory.carried

    if override?(present) or override?(cursor),
      do: {:error, :unsupported_container_click},
      else: {:ok, pickup(state, address, present, cursor, button)}
  end

  defp click(state, rows, address, :quick_move, button) when button in [0, 1] do
    targets =
      case address do
        {:container, _} -> Enum.to_list(44..9//-1)
        _ -> Enum.map(0..(rows * 9 - 1), &{:container, &1})
      end

    case get(state, address) do
      nil ->
        {:ok, state}

      source ->
        {next, left} = transfer(state, source, source.count, targets, :merge)
        {next, left} = transfer(next, source, left, targets, :empty)
        {:ok, put(next, address, sized(source, left))}
    end
  end

  defp click(state, _, address, :swap, button) when button in 0..8 or button == 40 do
    target = if button == 40, do: 45, else: 36 + button
    source = get(state, address)
    other = get(state, target)

    # Native oversized number swaps can produce player overflow/drop callbacks.
    # Those require a durable world plan and are not admitted by this slice.
    if fits?(source) and fits?(other),
      do: {:ok, state |> put(address, other) |> put(target, source)},
      else: {:error, :unsupported_container_click}
  end

  defp click(_, _, _, _, _), do: {:error, :unsupported_container_click}

  defp pickup(state, address, present, cursor, button) do
    cond do
      cursor == nil and present != nil ->
        count = if button == 0, do: present.count, else: div(present.count + 1, 2)

        state
        |> put(address, sized(present, present.count - count))
        |> cursor(sized(present, count))

      cursor != nil and present == nil ->
        count = min(if(button == 0, do: cursor.count, else: 1), ItemStack.max_stack_size(cursor))
        state |> put(address, sized(cursor, count)) |> cursor(sized(cursor, cursor.count - count))

      cursor != nil and present != nil and ItemStack.same_item?(cursor, present) ->
        count =
          min(
            if(button == 0, do: cursor.count, else: 1),
            max(ItemStack.max_stack_size(cursor) - present.count, 0)
          )

        state
        |> put(address, sized(present, present.count + count))
        |> cursor(sized(cursor, cursor.count - count))

      cursor != nil and present != nil and fits?(cursor) ->
        state |> put(address, cursor) |> cursor(present)

      true ->
        state
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
            :empty -> present == nil
          end

        if eligible do
          current = if present, do: present.count, else: 0
          moved = min(left, max(ItemStack.max_stack_size(stack) - current, 0))
          value = sized(present || stack, current + moved)
          {:cont, {put(state, target, value), left - moved}}
        else
          {:cont, {state, left}}
        end
      end
    end)
  end

  defp finish({storage, inventory}) do
    bytes =
      storage
      |> Tuple.to_list()
      |> Enum.reduce(0, fn stack, size -> size + IO.iodata_length(ItemStack.encode(stack)) end)

    if bytes <= @max_bytes and Inventory.encoded_size(inventory) <= @max_bytes,
      do: {:ok, storage, Inventory.advance(inventory)},
      else: {:error, :container_click_byte_limit}
  end

  defp get({storage, _}, {:container, index}), do: elem(storage, index)
  defp get({_, inventory}, slot), do: Inventory.get(inventory, slot)

  defp put({storage, inventory}, {:container, index}, stack),
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
  defp fits?(nil), do: true
  defp fits?(stack), do: stack.count <= ItemStack.max_stack_size(stack)
  defp override?(nil), do: false
  defp override?(stack), do: ItemTypes.item(stack.item_id)["inventory_click_override"] == true
end
