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
  slot (0 input, 1 fuel, 2 result), `{:brewing, i}` a brewing stand's (0..2
  bottles, 3 the ingredient, 4 the fuel, VMC-034o), `{:payment, i}` a merchant's payment
  slot (VMC-044b2), whose result is address 0 as a grid's is (only drags
  and collects reach the engine there; `Valimc.Player.Merchant` takes it). The 2×2 grid and a table's grid share
  the result address 0: `Inventory.crafting_result/1` reads the open one.
  """
  alias Valimc.Blocks.{Brewing, Cooking, CookingBlocks, CookingRecipes}
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}

  defstruct kind: :inventory, rows: nil, block: nil

  # Menus over a container's plain slots: chests, hoppers (`HopperMenu`),
  # dispensers and droppers (`DispenserMenu`, VMC-049a) and shulker boxes
  # (`ShulkerBoxMenu`, VMC-032c2).
  @plain [:chest, :hopper, :dispenser, :shulker_box]

  @bucket Data.item("bucket")
  @lapis Data.item("lapis_lazuli")
  @equipment %{"head" => 5, "chest" => 6, "legs" => 7, "feet" => 8, "offhand" => 45}

  def inventory, do: %__MODULE__{}
  def table, do: %__MODULE__{kind: :table}

  @doc "The menu of the crafting grid `inventory` has open: a table's, or the 2×2."
  def crafting(%Inventory{table_inputs: nil}), do: inventory()
  def crafting(%Inventory{}), do: table()
  def chest(rows) when rows in 1..6, do: %__MODULE__{kind: :chest, rows: rows}
  def cooking(block), do: %__MODULE__{kind: :cooking, block: block}
  def hopper, do: %__MODULE__{kind: :hopper}
  def shulker_box, do: %__MODULE__{kind: :shulker_box}
  def merchant, do: %__MODULE__{kind: :merchant}
  def brewing, do: %__MODULE__{kind: :brewing}
  def enchanting, do: %__MODULE__{kind: :enchanting}
  def anvil, do: %__MODULE__{kind: :anvil}
  def grindstone, do: %__MODULE__{kind: :grindstone}
  def smithing, do: %__MODULE__{kind: :smithing}

  def dispenser(kind) when kind in [:dropper, :dispenser],
    do: %__MODULE__{kind: :dispenser, block: kind}

  @doc "The menu of a machine kind (`:hopper`, `:dropper`, `:dispenser`)."
  def machine(:hopper), do: hopper()
  def machine(kind), do: dispenser(kind)

  @doc """
  The menu of a storage kind (VMC-032c1): a barrel's is a three-row chest's
  (`ChestMenu.threeRows`), a shulker box's its own (VMC-032c2); an ender
  chest's (VMC-032c3) is a three-row chest's over the player's ender slots.
  """
  def storage(:barrel), do: chest(3)
  def storage(:ender_chest), do: chest(3)
  def storage(:shulker_box), do: shulker_box()

  @doc "The container slots of a plain menu."
  def size(%__MODULE__{kind: :chest, rows: rows}), do: rows * 9
  def size(%__MODULE__{kind: :hopper}), do: 5
  def size(%__MODULE__{kind: :dispenser}), do: 9
  def size(%__MODULE__{kind: :shulker_box}), do: 27

  @doc "The window type a menu opens with (`open_screen`)."
  def type(%__MODULE__{kind: :chest, rows: rows}), do: {:ok, rows - 1}
  def type(%__MODULE__{kind: :cooking, block: block}), do: cooking_type(CookingBlocks.kind(block))
  def type(%__MODULE__{kind: :hopper}), do: {:ok, 16}
  def type(%__MODULE__{kind: :dispenser}), do: {:ok, 6}
  def type(%__MODULE__{kind: :merchant}), do: {:ok, 19}
  def type(%__MODULE__{kind: :enchanting}), do: {:ok, 13}
  def type(%__MODULE__{kind: :anvil}), do: {:ok, 8}
  def type(%__MODULE__{kind: :grindstone}), do: {:ok, 15}
  def type(%__MODULE__{kind: :smithing}), do: {:ok, 21}
  def type(%__MODULE__{kind: :shulker_box}), do: {:ok, 20}
  def type(%__MODULE__{kind: :brewing}), do: {:ok, 11}
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
      when kind in [:cooking, :brewing | @plain] and slot in [-1, -999],
      do: {:ok, slot}

  def address(%__MODULE__{kind: :brewing}, slot) when slot in 0..4, do: {:ok, {:brewing, slot}}
  def address(%__MODULE__{kind: :brewing}, slot) when slot in 5..40, do: {:ok, slot + 4}

  def address(%__MODULE__{kind: :merchant}, slot) when slot in 0..1, do: {:ok, {:payment, slot}}
  def address(%__MODULE__{kind: :merchant}, 2), do: {:ok, 0}
  def address(%__MODULE__{kind: :merchant}, slot) when slot in 3..38, do: {:ok, slot + 6}
  def address(%__MODULE__{kind: :merchant}, slot) when slot in [-1, -999], do: {:ok, slot}
  # `EnchantmentMenu` (VMC-038a): the item and the lapis are the player's
  # two menu inputs.
  def address(%__MODULE__{kind: :enchanting}, slot) when slot in 0..1, do: {:ok, {:payment, slot}}
  def address(%__MODULE__{kind: :enchanting}, slot) when slot in 2..37, do: {:ok, slot + 7}
  def address(%__MODULE__{kind: :enchanting}, slot) when slot in [-1, -999], do: {:ok, slot}
  # An anvil's and a grindstone's two inputs (VMC-038b); their result
  # (window slot 2) is the menu's own (`Player.Anvil`).
  def address(%__MODULE__{kind: kind}, slot) when kind in [:anvil, :grindstone] and slot in 0..1,
    do: {:ok, {:payment, slot}}

  def address(%__MODULE__{kind: kind}, slot) when kind in [:anvil, :grindstone] and slot in 3..38,
    do: {:ok, slot + 6}

  def address(%__MODULE__{kind: kind}, slot)
      when kind in [:anvil, :grindstone] and slot in [-1, -999],
      do: {:ok, slot}

  # A smithing table's template, base and addition (VMC-038c); its result
  # (window slot 3) is the menu's own.
  def address(%__MODULE__{kind: :smithing}, slot) when slot in 0..2, do: {:ok, {:payment, slot}}
  def address(%__MODULE__{kind: :smithing}, slot) when slot in 4..39, do: {:ok, slot + 5}
  def address(%__MODULE__{kind: :smithing}, slot) when slot in [-1, -999], do: {:ok, slot}
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

  def contents(%__MODULE__{kind: :brewing}, storage, %Inventory{} = inventory)
      when is_tuple(storage) do
    if Brewing.valid?(%Brewing{slots: storage}),
      do: {:ok, Tuple.to_list(storage) ++ Enum.map(9..44, &Inventory.get(inventory, &1))},
      else: {:error, :invalid_menu_contents}
  end

  def contents(%__MODULE__{kind: :merchant}, nil, %Inventory{payments: {a, b}} = inventory),
    do: {:ok, [a, b, nil | Enum.map(9..44, &Inventory.get(inventory, &1))]}

  def contents(%__MODULE__{kind: kind}, nil, %Inventory{payments: {a, b}} = inventory)
      when kind in [:anvil, :grindstone],
      do: {:ok, [a, b, nil | Enum.map(9..44, &Inventory.get(inventory, &1))]}

  def contents(%__MODULE__{kind: :smithing}, nil, %Inventory{payments: {t, b, a}} = inventory),
    do: {:ok, [t, b, a, nil | Enum.map(9..44, &Inventory.get(inventory, &1))]}

  def contents(%__MODULE__{kind: :enchanting}, nil, %Inventory{payments: {a, b}} = inventory),
    do: {:ok, [a, b | Enum.map(9..44, &Inventory.get(inventory, &1))]}

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

  # A brewing stand's (`BrewingStandBlockEntity.dataAccess`): brew time, fuel,
  # their totals.
  def properties(%Brewing{} = brewing) do
    if Brewing.valid?(brewing),
      do: {:ok, [brewing.brew_time, brewing.fuel, brewing.total_brew_time, brewing.total_fuel]},
      else: {:error, :invalid_brewing_properties}
  end

  def properties(_), do: {:error, :invalid_cooking_properties}

  @doc "The slots a pick-all (double click) collects from, in window order."
  def visible(%__MODULE__{kind: :inventory}), do: Enum.to_list(1..45)
  def visible(%__MODULE__{kind: :table}), do: Enum.map(0..8, &{:table, &1}) ++ Enum.to_list(9..44)

  def visible(%__MODULE__{kind: kind} = menu) when kind in @plain,
    do: Enum.map(0..(size(menu) - 1), &{:container, &1}) ++ Enum.to_list(9..44)

  def visible(%__MODULE__{kind: :cooking}),
    do: Enum.map(0..2, &{:cooking, &1}) ++ Enum.to_list(9..44)

  def visible(%__MODULE__{kind: :brewing}),
    do: Enum.map(0..4, &{:brewing, &1}) ++ Enum.to_list(9..44)

  # `MerchantMenu.canTakeItemForPickAll` refuses every slot.
  def visible(%__MODULE__{kind: :merchant}), do: []

  def visible(%__MODULE__{kind: kind}) when kind in [:anvil, :grindstone],
    do: [{:payment, 0}, {:payment, 1} | Enum.to_list(9..44)]

  def visible(%__MODULE__{kind: :smithing}),
    do: [{:payment, 0}, {:payment, 1}, {:payment, 2} | Enum.to_list(9..44)]

  def visible(%__MODULE__{kind: :enchanting}),
    do: [{:payment, 0}, {:payment, 1} | Enum.to_list(9..44)]

  @doc "Whether `address` accepts `stack` (vanilla's `Slot.mayPlace`)."
  def may_place?(_menu, _address, nil), do: true
  def may_place?(_menu, 0, _stack), do: false
  def may_place?(_menu, {:cooking, 2}, _stack), do: false
  def may_place?(_menu, {:cooking, 1}, stack), do: stack.item_id == @bucket or fuel?(stack)

  # `BrewingStandMenu`'s `PotionSlot`, `IngredientsSlot` and `FuelSlot`.
  def may_place?(_menu, {:brewing, slot}, stack) when slot in 0..2,
    do: Brewing.potion_input?(stack)

  def may_place?(_menu, {:brewing, 3}, stack), do: Brewing.reagent?(stack)
  def may_place?(_menu, {:brewing, 4}, stack), do: Brewing.fuel?(stack)

  def may_place?(%__MODULE__{kind: :inventory}, slot, stack) when slot in 5..8,
    do: equipment_slot(stack) == slot

  # A grindstone takes what can wear or is enchanted (`GrindstoneMenu`'s slots).
  def may_place?(%__MODULE__{kind: :grindstone}, {:payment, _}, stack) do
    (is_integer(ItemStack.component(stack, "minecraft:max_damage")) and
       is_integer(ItemStack.component(stack, "minecraft:damage")) and
       ItemStack.component(stack, "minecraft:unbreakable") == nil) or
      map_size(ItemStack.component(stack, "minecraft:enchantments") || %{}) > 0 or
      map_size(ItemStack.component(stack, "minecraft:stored_enchantments") || %{}) > 0
  end

  # A smithing table's inputs take what some recipe takes there.
  def may_place?(%__MODULE__{kind: :smithing}, {:payment, slot}, stack),
    do: Valimc.Menus.Smithing.may_place?(slot, stack)

  # The enchanting table's lapis slot takes lapis only.
  def may_place?(%__MODULE__{kind: :enchanting}, {:payment, 1}, stack),
    do: stack.item_id == @lapis

  # `ShulkerBoxSlot.mayPlace`: only what fits inside a container item.
  def may_place?(%__MODULE__{kind: :shulker_box}, {:container, _}, stack),
    do: not Valimc.Blocks.ShulkerBox.item?(stack)

  def may_place?(_menu, _address, _stack), do: true

  @doc """
  Whether the player may take `stack` from `address` (vanilla's
  `Slot.mayPickup`): an armour slot keeps a piece whose enchantments
  prevent armour changes (Curse of Binding, VMC-037q) unless the player is
  creative (`infinite`).
  """
  def may_pickup?(_menu, _address, nil, _infinite), do: true

  def may_pickup?(%__MODULE__{kind: :inventory}, slot, stack, false) when slot in 5..8,
    do: not Valimc.Living.Enchant.prevents_armor_change?(Valimc.Living.Enchant.levels(stack))

  def may_pickup?(_menu, _address, _stack, _infinite), do: true

  @doc "The most of `stack` `address` holds (vanilla's `Slot.getMaxStackSize(stack)`)."
  def limit(%__MODULE__{kind: :inventory}, slot, _stack) when slot in 5..8, do: 1
  def limit(%__MODULE__{kind: :enchanting}, {:payment, 0}, _stack), do: 1
  def limit(_menu, {:cooking, 1}, %{item_id: @bucket}), do: 1
  def limit(_menu, {:brewing, slot}, _stack) when slot in 0..2, do: 1
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
  # `EnchantmentMenu.quickMoveStack`: its inputs to the inventory from the
  # hotbar's end; lapis to its slot; anything else one at a time to the
  # item slot (whose limit is one).
  def routes(%__MODULE__{kind: :enchanting}, _inventory, {:payment, _}, _stack),
    do: [Enum.to_list(44..9//-1)]

  def routes(%__MODULE__{kind: :enchanting}, _inventory, _slot, %{item_id: @lapis}),
    do: [[{:payment, 1}]]

  def routes(%__MODULE__{kind: :enchanting}, _inventory, _slot, _stack),
    do: [[{:payment, 0}]]

  # `ItemCombinerMenu.quickMoveStack` and the grindstone's: inputs to the
  # inventory; the inventory to the inputs, else between it and the hotbar.
  def routes(%__MODULE__{kind: kind}, _inventory, {:payment, _}, _stack)
      when kind in [:anvil, :grindstone, :smithing],
      do: [Enum.to_list(9..44)]

  def routes(%__MODULE__{kind: kind} = menu, _inventory, slot, stack)
      when kind in [:anvil, :grindstone, :smithing] do
    count = if kind == :smithing, do: 2, else: 1
    inputs = for i <- 0..count, may_place?(menu, {:payment, i}, stack), do: {:payment, i}
    rest = if slot in 9..35, do: Enum.to_list(36..44), else: Enum.to_list(9..35)
    if inputs == [], do: [rest], else: [inputs]
  end

  def routes(%__MODULE__{kind: :merchant}, _inventory, {:payment, _}, _stack),
    do: [Enum.to_list(9..44)]

  def routes(%__MODULE__{kind: :merchant}, _inventory, slot, _stack) when slot in 9..35,
    do: [Enum.to_list(36..44)]

  def routes(%__MODULE__{kind: :merchant}, _inventory, _slot, _stack),
    do: [Enum.to_list(9..35)]

  # `BrewingStandMenu.quickMoveStack`: its slots to the inventory from the
  # end; fuel to the fuel slot then the ingredient's (blaze powder is both),
  # reagents to the ingredient's, bottles to the bottles'.
  def routes(%__MODULE__{kind: :brewing}, _inventory, {:brewing, _}, _stack),
    do: [Enum.to_list(44..9//-1)]

  def routes(%__MODULE__{kind: :brewing}, _inventory, slot, stack) do
    cond do
      Brewing.fuel?(stack) and Brewing.reagent?(stack) -> [[{:brewing, 4}], [{:brewing, 3}]]
      Brewing.fuel?(stack) -> [[{:brewing, 4}]]
      Brewing.reagent?(stack) -> [[{:brewing, 3}]]
      Brewing.potion_input?(stack) -> [Enum.map(0..2, &{:brewing, &1})]
      slot in 9..35 -> [Enum.to_list(36..44)]
      true -> [Enum.to_list(9..35)]
    end
  end

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
