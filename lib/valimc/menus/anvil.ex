defmodule Valimc.Menus.Anvil do
  @moduledoc """
  The anvil's and the grindstone's rules (VMC-038b), pure, over stacks and
  the enchantment definitions of the loot registries (`LootOracle`: each
  enchantment's maximum level, anvil cost, minimum cost, supported items
  and exclusive set; `#curse`).

  - `result/4` is `AnvilMenu.createResult`: repair with the repair material
    (a quarter of the durability each), combining with the same item or an
    enchanted book (levels merged, raised when equal, capped; incompatible
    ones priced but dropped), renaming and its removal, the prior-work
    penalty (`repair_cost` doubled plus one) and "Too Expensive!" at 40
    levels (creative players pass).
  - `grind/2` is `GrindstoneMenu.computeResult`: one enchanted item loses
    every enchantment but the curses; two of the same item merge their
    durability (plus 5%) and enchantments the same way.
    `grind_experience/2` is what the orbs give.
  - `valid_name/1` is `validateName`.
  """
  use Valimc.Data.Facts, "loot/registries.json"
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.Text.Render

  @enchantments Map.new(@facts["enchantments"], fn e ->
                  {e["id"],
                   %{
                     max: e["max_level"],
                     anvil: e["anvil_cost"],
                     min_cost: {e["min_cost"]["base"], e["min_cost"]["per_level_above_first"]},
                     supported: MapSet.new(e["supported_items"]),
                     exclusive: MapSet.new(e["exclusive_set"])
                   }}
                end)
  @curses MapSet.new(@facts["tags"]["minecraft:enchantment"]["minecraft:curse"])
  @book ItemTypes.id("minecraft:enchanted_book")
  @plain_book ItemTypes.id("minecraft:book")
  @limit 40

  # The component an item keeps its enchantments in.
  defp component(%ItemStack{item_id: @book}), do: "minecraft:stored_enchantments"
  defp component(_stack), do: "minecraft:enchantments"

  defp levels(nil), do: %{}
  defp levels(stack), do: ItemStack.component(stack, component(stack)) || %{}

  defp put_levels(stack, levels),
    do: %{stack | components: Map.put(stack.components, component(stack), levels)}

  defp repair_cost(nil), do: 0
  defp repair_cost(stack), do: ItemStack.component(stack, "minecraft:repair_cost") || 0

  defp item_name(stack), do: ItemTypes.item(stack.item_id)["name"]

  # `isDamageableItem`: a maximum damage and a damage, not unbreakable.
  defp damageable?(stack),
    do:
      is_integer(ItemStack.component(stack, "minecraft:max_damage")) and
        is_integer(ItemStack.component(stack, "minecraft:damage")) and
        ItemStack.component(stack, "minecraft:unbreakable") == nil

  defp damage(stack), do: ItemStack.component(stack, "minecraft:damage") || 0
  defp max_damage(stack), do: ItemStack.component(stack, "minecraft:max_damage") || 0
  defp set_damage(stack, value), do: put(stack, "minecraft:damage", value)

  defp put(stack, name, value), do: %{stack | components: Map.put(stack.components, name, value)}

  # `Repairable.isValidRepairItem`: the repair materials (items or a tag).
  defp repairs?(input, addition) do
    case ItemStack.component(input, "minecraft:repairable") do
      %{"items" => {:tag, tag}} ->
        addition.item_id in Valimc.Protocol.Data.tags()["minecraft:item"][tag]

      %{"items" => items} when is_list(items) ->
        item_name(addition) in items

      _ ->
        false
    end
  end

  # `Enchantment.areCompatible`.
  defp compatible?(a, b) do
    a != b and not MapSet.member?(@enchantments[a].exclusive, b) and
      not MapSet.member?(@enchantments[b].exclusive, a)
  end

  # `getHoverName().getString()`: the custom name, else the item's name.
  defp hover(stack) do
    case ItemStack.component(stack, "minecraft:custom_name") do
      nil -> Render.string(ItemStack.component(stack, "minecraft:item_name"))
      custom -> Render.string(custom)
    end
  end

  @doc """
  `validateName`: the name without the characters chat refuses, nil when
  longer than 50.
  """
  def valid_name(name) when is_binary(name) do
    filtered =
      name
      |> String.to_charlist()
      |> Enum.filter(&(&1 != 167 and &1 >= 32 and &1 != 127))
      |> List.to_string()

    if String.length(filtered) <= 50, do: filtered
  end

  @doc """
  `createResult` for `input` and `addition` with the rename field `rename`
  (nil: untouched) for a player with infinite materials or not:
  `%{result, cost, repair_count, only_renaming}`.
  """
  def result(input, addition, rename, infinite) do
    empty = %{result: nil, cost: 0, repair_count: 0, only_renaming: false}

    cond do
      input == nil -> %{empty | cost: 1}
      true -> compute(input, addition, rename, infinite) || empty
    end
  end

  defp compute(input, addition, rename, infinite) do
    tax = repair_cost(input) + repair_cost(addition)
    acc = %{result: input, enchantments: levels(input), price: 0, repair_count: 0}

    with {:ok, acc} <- combine(acc, input, addition, infinite) do
      {acc, naming} = rename(acc, input, rename)
      price = acc.price
      cost = if price <= 0, do: 0, else: min(tax + price, 2_147_483_647)
      result = if price <= 0, do: nil, else: acc.result
      only_renaming = naming == price and naming > 0
      cost = if only_renaming and cost >= @limit, do: @limit - 1, else: cost
      result = if cost >= @limit and not infinite, do: nil, else: result

      result =
        if result do
          base = max(repair_cost(result), repair_cost(addition))
          base = if naming != price or naming == 0, do: increased(base), else: base

          result
          |> put("minecraft:repair_cost", base)
          |> put_levels(acc.enchantments)
        end

      %{result: result, cost: cost, repair_count: acc.repair_count, only_renaming: only_renaming}
    else
      :none -> nil
    end
  end

  @doc "`calculateIncreasedRepairCost`: doubled plus one."
  def increased(cost), do: min(cost * 2 + 1, 2_147_483_647)

  defp combine(acc, _input, nil, _infinite), do: {:ok, acc}

  defp combine(acc, input, addition, infinite) do
    book = ItemStack.component(addition, "minecraft:stored_enchantments") != nil

    cond do
      damageable?(acc.result) and repairs?(input, addition) ->
        repair(acc, addition)

      not book and (acc.result.item_id != addition.item_id or not damageable?(acc.result)) ->
        :none

      true ->
        acc = if damageable?(acc.result) and not book, do: mend(acc, input, addition), else: acc
        merge(acc, input, addition, book, infinite)
    end
  end

  # Each repair material mends a quarter of the durability (for a level each).
  defp repair(acc, addition) do
    step = fn result -> min(damage(result), div(max_damage(result), 4)) end

    if step.(acc.result) <= 0 do
      :none
    else
      {result, count} =
        Enum.reduce_while(1..addition.count, {acc.result, 0}, fn _, {result, count} ->
          amount = step.(result)

          if amount > 0,
            do: {:cont, {set_damage(result, damage(result) - amount), count + 1}},
            else: {:halt, {result, count}}
        end)

      {:ok, %{acc | result: result, price: acc.price + count, repair_count: count}}
    end
  end

  # Two of the same item: the second's durability plus 12% (2 levels).
  defp mend(acc, input, addition) do
    remaining = max_damage(input) - damage(input)
    additional = max_damage(addition) - damage(addition) + div(max_damage(acc.result) * 12, 100)
    value = max(max_damage(acc.result) - (remaining + additional), 0)

    if value < damage(acc.result),
      do: %{acc | result: set_damage(acc.result, value), price: acc.price + 2},
      else: acc
  end

  defp merge(acc, input, addition, book, infinite) do
    {acc, any_ok, any_bad} =
      addition
      |> levels()
      |> Enum.sort()
      |> Enum.reduce({acc, false, false}, fn {name, level}, {acc, any_ok, any_bad} ->
        definition = @enchantments[name]
        current = Map.get(acc.enchantments, name, 0)
        level = if current == level, do: level + 1, else: max(level, current)

        supported =
          infinite or input.item_id == @book or
            MapSet.member?(definition.supported, item_name(input))

        {ok, price} =
          Enum.reduce(Map.keys(acc.enchantments), {supported, acc.price}, fn other, {ok, price} ->
            if other != name and not compatible?(name, other),
              do: {false, price + 1},
              else: {ok, price}
          end)

        acc = %{acc | price: price}

        if ok do
          level = min(level, definition.max)
          fee = if book, do: max(1, div(definition.anvil, 2)), else: definition.anvil
          price = acc.price + fee * level
          price = if input.count > 1, do: @limit, else: price

          {%{acc | enchantments: Map.put(acc.enchantments, name, level), price: price}, true,
           any_bad}
        else
          {acc, any_ok, true}
        end
      end)

    if any_bad and not any_ok, do: :none, else: {:ok, acc}
  end

  # A new name costs a level; clearing a custom name too.
  defp rename(acc, input, rename) do
    has_custom = ItemStack.component(input, "minecraft:custom_name") != nil

    cond do
      rename != nil and String.trim(rename) != "" ->
        if rename != hover(input) do
          result =
            put(acc.result, "minecraft:custom_name", {:compound, %{"text" => {:string, rename}}})

          {%{acc | result: result, price: acc.price + 1}, 1}
        else
          {acc, 0}
        end

      has_custom ->
        result = %{
          acc.result
          | components: Map.delete(acc.result.components, "minecraft:custom_name")
        }

        {%{acc | result: result, price: acc.price + 1}, 1}

      true ->
        {acc, 0}
    end
  end

  @doc """
  `onTake`: the inputs after the result is taken: the repair materials it
  used, or the whole addition unless only renaming; the input always goes.
  """
  def taken(addition, %{repair_count: count, only_renaming: only}) do
    cond do
      count > 0 and addition != nil and addition.count > count ->
        %{addition | count: addition.count - count}

      count > 0 ->
        nil

      only ->
        addition

      true ->
        nil
    end
  end

  ## Grindstone

  @doc "`GrindstoneMenu.computeResult` of its two inputs, or nil."
  def grind(nil, nil), do: nil

  def grind(input, additional) do
    if (input == nil or input.count <= 1) and (additional == nil or additional.count <= 1) do
      case {input, additional} do
        {item, nil} -> if levels(item) == %{}, do: nil, else: strip(item)
        {nil, item} -> if levels(item) == %{}, do: nil, else: strip(item)
        {a, b} -> merge_items(a, b)
      end
    end
  end

  defp merge_items(input, additional) do
    if input.item_id != additional.item_id do
      nil
    else
      durability = max(max_damage(input), max_damage(additional))

      remaining =
        max_damage(input) - damage(input) + max_damage(additional) - damage(additional) +
          div(durability * 5, 100)

      cond do
        not damageable?(input) and
            (ItemStack.max_stack_size(input) < 2 or not ItemStack.same_item?(input, additional)) ->
          nil

        true ->
          count = if damageable?(input), do: 1, else: 2
          item = %{input | count: count}

          item =
            if damageable?(item),
              do:
                item
                |> put("minecraft:max_damage", durability)
                |> set_damage(max(durability - remaining, 0)),
              else: item

          # `mergeEnchantsFrom`: the other's, a curse only when missing.
          merged =
            Enum.reduce(Enum.sort(levels(additional)), levels(item), fn {name, level}, acc ->
              if not MapSet.member?(@curses, name) or Map.get(acc, name, 0) == 0,
                do: Map.update(acc, name, level, &max(&1, level)),
                else: acc
            end)

          strip(put_levels(item, merged))
      end
    end
  end

  # `removeNonCursesFrom`: only curses stay; an enchanted book left with none
  # is a book; the prior-work penalty counts what stayed.
  defp strip(item) do
    kept = Map.filter(levels(item), fn {name, _} -> MapSet.member?(@curses, name) end)
    item = put_levels(item, kept)

    item =
      if item.item_id == @book and kept == %{},
        do: %{
          item
          | item_id: @plain_book,
            components: Map.delete(item.components, "minecraft:stored_enchantments")
        },
        else: item

    cost = Enum.reduce(1..map_size(kept)//1, 0, fn _, cost -> increased(cost) end)
    put(item, "minecraft:repair_cost", cost)
  end

  @doc "The minimum costs of the inputs' non-curse enchantments (`getExperienceFromItem`)."
  def grind_base(inputs) do
    for stack <- inputs,
        stack != nil,
        {name, level} <- levels(stack),
        not MapSet.member?(@curses, name),
        reduce: 0 do
      sum ->
        {base, per} = @enchantments[name].min_cost
        sum + base + per * (level - 1)
    end
  end

  @doc """
  `getExperienceAmount`: half the base (`grind_base/1`) plus a draw below
  half (`random.(n)` in 0..n-1).
  """
  def grind_experience(inputs, random \\ &(:rand.uniform(&1) - 1)) do
    amount = grind_base(inputs)

    if amount > 0 do
      half = ceil(amount / 2)
      half + random.(half)
    else
      0
    end
  end
end
