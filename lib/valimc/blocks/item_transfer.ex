defmodule Valimc.Blocks.ItemTransfer do
  @moduledoc """
  Moving stacks into and out of owned containers as vanilla's hoppers and
  droppers do (`HopperBlockEntity.addItem`, `tryMoveInItem`,
  `tryTakeInItemFromSlot`, `isFullContainer`, VMC-049a), over container
  entries: a chest's or a machine's plain slots, or a furnace's three, which
  it reaches by face (`AbstractFurnaceBlockEntity` as a `WorldlyContainer`:
  input from above, fuel from the sides, result and an empty bucket below).

  A side is the face of the container the stack passes through (`:down`,
  `:up`, `:north`, `:south`, `:west`, `:east`), or nil for a plain insert
  (an item entity's, or into a hopper from above). A furnace entry is
  edited with its block state (`Cooking.edit_slots/3`): a new input resets
  its progress, as `setItem` does.
  """
  alias Valimc.Blocks.Cooking
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}

  @bucket Data.item("bucket")
  @bottom_takeable MapSet.new(
                     Data.tags()["minecraft:item"]["minecraft:furnace_fuel_bottom_takeable"]
                   )
  @hopper_cooldown 8

  @doc "The slots a side reaches (`getSlots`)."
  def slots_for(%{cooking: %Cooking{}}, :down), do: [2, 1]
  def slots_for(%{cooking: %Cooking{}}, :up), do: [0]
  def slots_for(%{cooking: %Cooking{}}, side) when side != nil, do: [1]

  def slots_for(%{cooking: %Cooking{slots: slots}}, nil),
    do: Enum.to_list(0..(tuple_size(slots) - 1))

  def slots_for(%{slots: slots}, _side), do: Enum.to_list(0..(tuple_size(slots) - 1))

  @doc "The stack in `slot`."
  def stack(%{cooking: %Cooking{slots: slots}}, slot), do: elem(slots, slot)
  def stack(%{slots: slots}, slot), do: elem(slots, slot)

  @doc "The entry's slots."
  def slots(%{cooking: %Cooking{slots: slots}}), do: slots
  def slots(%{slots: slots}), do: slots

  @doc "Whether every slot is empty (`Container.isEmpty`)."
  def empty?(entry), do: Enum.all?(Tuple.to_list(slots(entry)), &is_nil/1)

  @doc "A hopper's `inventoryFull`: every slot holds a full stack."
  def full?(%{slots: slots}),
    do:
      Enum.all?(Tuple.to_list(slots), fn
        nil -> false
        stack -> stack.count == ItemStack.max_stack_size(stack)
      end)

  @doc "`isFullContainer`: every slot `side` reaches holds a full stack."
  def full?(entry, side) do
    Enum.all?(slots_for(entry, side), fn slot ->
      case stack(entry, slot) do
        nil -> false
        stack -> stack.count >= ItemStack.max_stack_size(stack)
      end
    end)
  end

  @doc "`canPlaceItem` with `canPlaceItemThroughFace`: whether `slot` takes `stack`."
  def can_place?(%{cooking: %Cooking{slots: {_, fuel, _}}}, slot, stack, _side) do
    case slot do
      2 -> false
      1 -> fuel?(stack) or (stack.item_id == @bucket and not match?(%{item_id: @bucket}, fuel))
      _ -> true
    end
  end

  def can_place?(_entry, _slot, _stack, _side), do: true

  @doc "`canTakeItemThroughFace`: a furnace gives only buckets from its fuel below."
  def can_take?(%{cooking: %Cooking{}}, 1, stack, :down),
    do: MapSet.member?(@bottom_takeable, stack.item_id)

  def can_take?(_entry, _slot, _stack, _side), do: true

  @doc """
  `addItem(from, container, stack, side)`: `{entry, remainder, woke?}`, the
  container with what fitted, the rest of `stack` (nil when all fitted) and
  whether a stack went into the container while it was empty (a hopper
  receiving into its empty inventory takes a cooldown, `tryMoveInItem`).
  `block` is a furnace's state (its recipes), else ignored.
  """
  def add(entry, stack, side, block \\ nil) do
    Enum.reduce_while(slots_for(entry, side), {entry, stack, false}, fn
      _slot, {_, nil, _} = done ->
        {:halt, done}

      slot, {current, stack, woke} ->
        {next, rest, moved?} = move_in(current, stack, slot, side, block)
        woke = woke or (moved? and empty?(current))
        {:cont, {next, rest, woke}}
    end)
  end

  # `tryMoveInItem`: into an empty slot whole, else merged up to the stack's
  # maximum.
  defp move_in(entry, stack, slot, side, block) do
    current = stack(entry, slot)

    cond do
      not can_place?(entry, slot, stack, side) ->
        {entry, stack, false}

      current == nil ->
        {put(entry, slot, stack, block), nil, true}

      current.count <= ItemStack.max_stack_size(current) and ItemStack.same_item?(current, stack) ->
        moved = min(stack.count, ItemStack.max_stack_size(stack) - current.count)

        if moved > 0 do
          entry = put(entry, slot, %{current | count: current.count + moved}, block)

          {entry, if(stack.count == moved, do: nil, else: %{stack | count: stack.count - moved}),
           true}
        else
          {entry, stack, false}
        end

      true ->
        {entry, stack, false}
    end
  end

  @doc """
  `tryTakeInItemFromSlot` for each slot `side` reaches, in order, until one
  moves: one item from `source` into `target` (a plain insert).
  `{:ok, source, target, woke?}` or `:none`.
  """
  def take(source, target, side, source_block \\ nil) do
    Enum.find_value(slots_for(source, side), :none, fn slot ->
      with %ItemStack{} = stack <- stack(source, slot),
           true <- can_take?(source, slot, stack, side),
           {target, nil, woke} <- add(target, %{stack | count: 1}, nil) do
        rest = if stack.count == 1, do: nil, else: %{stack | count: stack.count - 1}
        {:ok, put(source, slot, rest, source_block), target, woke}
      else
        _ -> nil
      end
    end)
  end

  @doc "A hopper's cooldown after a stack woke it: 8, one less when it already ticked (`tryMoveInItem`)."
  def woken_cooldown(%{cooldown: cooldown} = hopper, skip?) do
    if cooldown > @hopper_cooldown,
      do: hopper,
      else: %{hopper | cooldown: @hopper_cooldown - if(skip?, do: 1, else: 0)}
  end

  @doc "Set `slot` to `stack` (`setItem`)."
  def put(%{cooking: %Cooking{} = cooking} = entry, slot, stack, block) do
    slots = put_elem(cooking.slots, slot, stack)

    if slot == 0 do
      {:ok, cooking} = Cooking.edit_slots(cooking, slots, block)
      %{entry | cooking: cooking}
    else
      %{entry | cooking: %{cooking | slots: slots}}
    end
  end

  def put(%{slots: slots} = entry, slot, stack, _block),
    do: %{entry | slots: put_elem(slots, slot, stack)}

  # `has(DataComponents.COOKING_FUEL)`; a patched fuel ValiMC cannot burn is
  # refused.
  defp fuel?(%ItemStack{item_id: item, components: components, removed: removed}) do
    not Map.has_key?(components, "minecraft:cooking_fuel") and
      not MapSet.member?(removed, "minecraft:cooking_fuel") and
      MapSet.member?(ItemTypes.defaults(item).present, "minecraft:cooking_fuel")
  end
end
