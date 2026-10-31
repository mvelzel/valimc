defmodule Valimc.Menus.Menu do
  @moduledoc """
  The menus a player clicks in (vanilla's `AbstractContainerMenu` and its
  subclasses) as slot descriptions for the one click engine
  (`Valimc.Menus.Click`, VMC-077i2): which storage a window slot addresses,
  what a slot accepts and how many, where a shift-click routes a stack, and
  the window's contents and type for packets.

  Addresses: an integer is a player inventory slot (0 the crafting result of
  the open grid, 1..4 the 2×2 inputs, 5..8 armour, 9..44 storage and hotbar,
  45 the offhand; -1 and -999 outside the slots), `{:table, i}` a crafting
  table input, `{:container, i}` a chest's, a hopper's or a dispenser's slot
  and `{:cooking, i}` a furnace
  slot (0 input, 1 fuel, 2 result), `{:payment, i}` a merchant's payment
  slot (VMC-044b2), whose result is address 0 as a grid's is (only drags
  and collects reach the engine there; `Valimc.Player.Merchant` takes it). The 2×2 grid and a table's grid share
  the result address 0: `Inventory.crafting_result/1` reads the open one.
  """
  alias Valimc.Blocks.{Cooking, CookingBlocks, CookingRecipes}
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}

  defstruct kind: :inventory, rows: nil, block: nil

  # Menus over a container's plain slots: chests, hoppers (`HopperMenu`) and
  # dispensers and droppers (`DispenserMenu`, VMC-049a).
  @plain [:chest, :hopper, :dispenser]

  @bucket Data.item("bucket")
  @equipment %{"head" => 5, "chest" => 6, "legs" => 7, "feet" => 8, "offhand" => 45}

  def inventory, do: %__MODULE__{}
  def table, do: %__MODULE__{kind: :table}

  @doc "The menu of the crafting grid `inventory` has open: a table's, or the 2×2."
  def crafting(%Inventory{table_inputs: nil}), do: inventory()
  def crafting(%Inventory{}), do: table()
  def chest(rows) when rows in 1..6, do: %__MODULE__{kind: :chest, rows: rows}
  def cooking(block), do: %__MODULE__{kind: :cooking, block: block}
  def hopper, do: %__MODULE__{kind: :hopper}
  def merchant, do: %__MODULE__{kind: :merchant}

  def dispenser(kind) when kind in [:dropper, :dispenser],
    do: %__MODULE__{kind: :dispenser, block: kind}

  @doc "The menu of a machine kind (`:hopper`, `:dropper`, `:dispenser`)."
  def machine(:hopper), do: hopper()
  def machine(kind), do: dispenser(kind)

  @doc "The menu of a storage kind (VMC-032c1): a barrel's is a three-row chest's (`ChestMenu.threeRows`)."
  def storage(:barrel), do: chest(3)

  @doc "The container slots of a plain menu."
  def size(%__MODULE__{kind: :chest, rows: rows}), do: rows * 9
  def size(%__MODULE__{kind: :hopper}), do: 5
  def size(%__MODULE__{kind: :dispenser}), do: 9

  @doc "The window type a menu opens with (`open_screen`)."
  def type(%__MODULE__{kind: :chest, rows: rows}), do: {:ok, rows - 1}
  def type(%__MODULE__{kind: :cooking, block: block}), do: cooking_type(CookingBlocks.kind(block))
  def type(%__MODULE__{kind: :hopper}), do: {:ok, 16}
  def type(%__MODULE__{kind: :dispenser}), do: {:ok, 6}
  def type(%__MODULE__{kind: :merchant}), do: {:ok, 19}
  def type(_), do: {:error, :invalid_menu}

  @doc "The window type of a furnace-family block's kind."
  def cooking_type(:furnace), do: {:ok, 14}
  def cooking_type(:smoker), do: {:ok, 22}
  def cooking_type(:blast_furnace), do: {:ok, 10}
  def cooking_type(_), do: {:error, :invalid_cooking_kind}

  @doc "The address of window slot `slot`."
  def address(%__MODULE__{kind: :inventory}, slot) when slot in 0..45 or slot in [-1, -999],
    do: {:ok, slot}

  def address(%__MODULE__{kind: :table}, slot) when slot in 1..9, do: {:ok, {:table, slot - 1}}
  def address(%__MODULE__{kind: :table}, slot) when slot in 10..45, do: {:ok, slot - 1}

  def address(%__MODULE__{kind: :table}, slot) when slot in [0, -1, -999], do: {:ok, slot}

  def address(%__MODULE__{kind: kind} = menu, slot)
      when kind in @plain and is_integer(slot) and slot >= 0 do
    size = size(menu)

    cond do
      slot < size -> {:ok, {:container, slot}}
      slot < size + 36 -> {:ok, slot - size + 9}
      true -> {:error, :invalid_menu_slot}
    end
  end

  def address(%__MODULE__{kind: kind}, slot)
      when kind in [:cooking | @plain] and slot in [-1, -999],
      do: {:ok, slot}

  def address(%__MODULE__{kind: :merchant}, slot) when slot in 0..1, do: {:ok, {:payment, slot}}
  def address(%__MODULE__{kind: :merchant}, 2), do: {:ok, 0}
  def address(%__MODULE__{kind: :merchant}, slot) when slot in 3..38, do: {:ok, slot + 6}
  def address(%__MODULE__{kind: :merchant}, slot) when slot in [-1, -999], do: {:ok, slot}
  def address(%__MODULE__{kind: :cooking}, slot) when slot in 0..2, do: {:ok, {:cooking, slot}}
  def address(%__MODULE__{kind: :cooking}, slot) when slot in 3..38, do: {:ok, slot + 6}
  def address(_, _), do: {:error, :invalid_menu_slot}

  @doc "The window's slots in order, as packets send them."
  def contents(%__MODULE__{kind: :inventory}, nil, inventory),
    do: {:ok, Inventory.display_contents(inventory)}

  def contents(%__MODULE__{kind: :table}, nil, %Inventory{table_inputs: cells} = inventory)
      when is_tuple(cells) and tuple_size(cells) == 9,
      do:
        {:ok,
         [Inventory.crafting_result(inventory) | Tuple.to_list(cells)] ++
           Enum.map(9..44, &Inventory.get(inventory, &1))}

  def contents(%__MODULE__{kind: kind} = menu, storage, %Inventory{} = inventory)
      when kind in @plain and is_tuple(storage) do
    if tuple_size(storage) == size(menu),
      do: {:ok, Tuple.to_list(storage) ++ Enum.map(9..44, &Inventory.get(inventory, &1))},
      else: {:error, :invalid_menu_contents}
  end

  def contents(%__MODULE__{kind: :cooking}, storage, %Inventory{} = inventory)
      when is_tuple(storage) do
    if Cooking.valid?(%Cooking{slots: storage}),
      do: {:ok, Tuple.to_list(storage) ++ Enum.map(9..44, &Inventory.get(inventory, &1))},
      else: {:error, :invalid_menu_contents}
  end

  def contents(%__MODULE__{kind: :merchant}, nil, %Inventory{payments: {a, b}} = inventory),
    do: {:ok, [a, b, nil | Enum.map(9..44, &Inventory.get(inventory, &1))]}

  def contents(_, _, _), do: {:error, :invalid_menu_contents}

  @doc "A furnace's window contents from its cooking state."
  def cooking_contents(%Cooking{slots: slots} = cooking, %Inventory{} = inventory) do
    if Cooking.valid?(cooking),
      do: {:ok, Tuple.to_list(slots) ++ Enum.map(9..44, &Inventory.get(inventory, &1))},
      else: {:error, :invalid_menu_contents}
  end

  def cooking_contents(_, _), do: {:error, :invalid_menu_contents}

  @doc "A furnace's progress properties: burn left, burn total, progress and total."
  def properties(%Cooking{} = cooking) do
    if Cooking.valid?(cooking),
      do: {:ok, [cooking.burn_left, cooking.burn_total, cooking.progress, cooking.total]},
      else: {:error, :invalid_cooking_properties}
  end

  def properties(_), do: {:error, :invalid_cooking_properties}

  @doc "The slots a pick-all (double click) collects from, in window order."
  def visible(%__MODULE__{kind: :inventory}), do: Enum.to_list(1..45)
  def visible(%__MODULE__{kind: :table}), do: Enum.map(0..8, &{:table, &1}) ++ Enum.to_list(9..44)

  def visible(%__MODULE__{kind: kind} = menu) when kind in @plain,
    do: Enum.map(0..(size(menu) - 1), &{:container, &1}) ++ Enum.to_list(9..44)

  def visible(%__MODULE__{kind: :cooking}),
    do: Enum.map(0..2, &{:cooking, &1}) ++ Enum.to_list(9..44)

  # `MerchantMenu.canTakeItemForPickAll` refuses every slot.
  def visible(%__MODULE__{kind: :merchant}), do: []

  @doc "Whether `address` accepts `stack` (vanilla's `Slot.mayPlace`)."
  def may_place?(_menu, _address, nil), do: true
  def may_place?(_menu, 0, _stack), do: false
  def may_place?(_menu, {:cooking, 2}, _stack), do: false
  def may_place?(_menu, {:cooking, 1}, stack), do: stack.item_id == @bucket or fuel?(stack)

  def may_place?(%__MODULE__{kind: :inventory}, slot, stack) when slot in 5..8,
    do: equipment_slot(stack) == slot

  def may_place?(_menu, _address, _stack), do: true

  @doc "The most of `stack` `address` holds (vanilla's `Slot.getMaxStackSize(stack)`)."
  def limit(%__MODULE__{kind: :inventory}, slot, _stack) when slot in 5..8, do: 1
  def limit(_menu, {:cooking, 1}, %{item_id: @bucket}), do: 1
  def limit(_menu, _address, stack), do: ItemStack.max_stack_size(stack)

  @doc """
  Where a shift-click (vanilla's `quickMoveStack`) routes `stack` from
  `address`: groups of slots, each filled by merging, then into empty slots.
  """
  def routes(%__MODULE__{kind: :inventory}, inventory, slot, stack) do
    equipment = equipment_slot(stack)

    cond do
      slot in 9..45 and equipment != nil and equipment != slot and
          Inventory.get(inventory, equipment) == nil ->
        [[equipment]]

      slot in 9..35 ->
        [Enum.to_list(36..44)]

      slot in 36..44 ->
        [Enum.to_list(9..35)]

      true ->
        [Enum.to_list(9..44)]
    end
  end

  # Vanilla retries a partly moved source: it fills the grid, then the other
  # storage section.
  def routes(%__MODULE__{kind: :table}, _inventory, slot, _stack) when slot in 9..44,
    do: [
      Enum.map(0..8, &{:table, &1}),
      if(slot in 9..35, do: Enum.to_list(36..44), else: Enum.to_list(9..35))
    ]

  def routes(%__MODULE__{kind: :table}, _inventory, _address, _stack), do: [Enum.to_list(9..44)]

  def routes(%__MODULE__{kind: kind}, _inventory, {:container, _}, _stack) when kind in @plain,
    do: [Enum.to_list(44..9//-1)]

  def routes(%__MODULE__{kind: kind} = menu, _inventory, _slot, _stack) when kind in @plain,
    do: [Enum.map(0..(size(menu) - 1), &{:container, &1})]

  # `MerchantMenu.quickMoveStack`: payments to the inventory; the inventory
  # and hotbar to each other, never to the payments.
  def routes(%__MODULE__{kind: :merchant}, _inventory, {:payment, _}, _stack),
    do: [Enum.to_list(9..44)]

  def routes(%__MODULE__{kind: :merchant}, _inventory, slot, _stack) when slot in 9..35,
    do: [Enum.to_list(36..44)]

  def routes(%__MODULE__{kind: :merchant}, _inventory, _slot, _stack),
    do: [Enum.to_list(9..35)]

  def routes(%__MODULE__{kind: :cooking}, _inventory, {:cooking, 2}, _stack),
    do: [Enum.to_list(44..9//-1)]

  def routes(%__MODULE__{kind: :cooking}, _inventory, {:cooking, _}, _stack),
    do: [Enum.to_list(9..44)]

  def routes(%__MODULE__{kind: :cooking, block: block}, _inventory, slot, stack) do
    cond do
      match?({:ok, _}, CookingRecipes.find(stack, block)) -> [[{:cooking, 0}]]
      fuel?(stack) -> [[{:cooking, 1}]]
      slot in 9..35 -> [Enum.to_list(36..44)]
      true -> [Enum.to_list(9..35)]
    end
  end

  @doc "The armour slot a stack equips to, or nil."
  def equipment_slot(stack) do
    if MapSet.member?(stack.removed, "minecraft:equippable"),
      do: nil,
      else: @equipment[ItemTypes.item(stack.item_id)["equipment_slot"]]
  end

  # A stack that explicitly patches its fuel component is not modelled yet.
  defp fuel?(%ItemStack{item_id: item, components: components, removed: removed}) do
    if Map.has_key?(components, "minecraft:cooking_fuel"), do: throw(:unsupported_cooking_fuel)

    not MapSet.member?(removed, "minecraft:cooking_fuel") and
      MapSet.member?(ItemTypes.defaults(item).present, "minecraft:cooking_fuel")
  end
end
