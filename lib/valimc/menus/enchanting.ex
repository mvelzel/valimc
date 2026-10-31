defmodule Valimc.Menus.Enchanting do
  @moduledoc """
  The enchanting table's rules (VMC-038a), pure: `EnchantingTableBlock`'s
  bookshelf power and `EnchantmentMenu`'s offers and enchanting. The
  enchantment choice is vanilla's `getEnchantmentCost` and
  `selectEnchantment` over `#in_enchanting_table` in the loot registry
  (`Native.loot_table_offers/4`, `loot_table_enchant/5`), from the player's
  enchantment seed, so the offers a seed shows are the ones it gives.
  """
  alias Valimc.Blocks.Loot
  alias Valimc.Native
  alias Valimc.Protocol.{Data, Enchantments, ItemStack, ItemTypes}

  @providers MapSet.new(Data.tags()["minecraft:block"]["minecraft:enchantment_power_provider"])
  @transmitters MapSet.new(
                  Data.tags()["minecraft:block"]["minecraft:enchantment_power_transmitter"]
                )

  # `EnchantingTableBlock.BOOKSHELF_OFFSETS`: the 5 × 5 ring two blocks out,
  # at the table's height and one above.
  @offsets for x <- -2..2,
               y <- 0..1,
               z <- -2..2,
               abs(x) == 2 or abs(z) == 2,
               do: {x, y, z}

  @book ItemTypes.id("minecraft:book")

  @doc """
  The bookshelves that power the table at `{x, y, z}`
  (`isValidBookShelf`): a power provider at each offset with a transmitter
  (air and the like) halfway. `block` reads a position's block registry id.
  """
  def bookcases({x, y, z}, block) do
    Enum.count(@offsets, fn {dx, dy, dz} ->
      MapSet.member?(@providers, block.({x + dx, y + dy, z + dz})) and
        MapSet.member?(@transmitters, block.({x + div(dx, 2), y + dy, z + div(dz, 2)}))
    end)
  end

  @doc "`ItemStack.isEnchantable`: an `enchantable` item without enchantments."
  def enchantable?(nil), do: false

  def enchantable?(%ItemStack{} = stack) do
    match?(%{"value" => v} when v > 0, ItemStack.component(stack, "minecraft:enchantable")) and
      map_size(ItemStack.component(stack, "minecraft:enchantments") || %{}) == 0
  end

  @doc """
  The three offers for `stack` (`slotsChanged`): `[{cost, clue}]`, a clue
  `{enchantment registry id, level}` or nil; all `{0, nil}` for an item the
  table cannot enchant.
  """
  def offers(stack, bookcases, seed) do
    if enchantable?(stack) do
      {:ok, offers} =
        Native.loot_table_offers(
          Loot.registry(),
          ItemTypes.item(stack.item_id)["name"],
          bookcases,
          seed
        )

      for {cost, clue} <- offers do
        {cost, with({name, level} <- clue, do: {Enchantments.id(name), level})}
      end
    else
      List.duplicate({0, nil}, 3)
    end
  end

  @doc """
  The item button `button` makes of `stack` at `cost` (`clickMenuButton`):
  its enchantments added, a book becoming an enchanted book that stores
  them; `:none` when the seed gives it none.
  """
  def enchant(stack, seed, button, cost) do
    {:ok, list} =
      Native.loot_table_enchant(
        Loot.registry(),
        ItemTypes.item(stack.item_id)["name"],
        seed,
        button,
        cost
      )

    case list do
      [] ->
        :none

      _ ->
        {stack, component} =
          if stack.item_id == @book,
            do:
              {%{stack | item_id: ItemTypes.id("minecraft:enchanted_book")},
               "minecraft:stored_enchantments"},
            else: {stack, "minecraft:enchantments"}

        # `ItemStack.enchant`: each upgrades what the item holds.
        levels =
          Enum.reduce(list, Map.get(stack.components, component, %{}), fn {name, level}, acc ->
            Map.update(acc, name, level, &max(&1, level))
          end)

        {:ok, %{stack | components: Map.put(stack.components, component, levels)}}
    end
  end
end
