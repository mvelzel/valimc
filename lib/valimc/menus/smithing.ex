defmodule Valimc.Menus.Smithing do
  @moduledoc """
  The smithing table's rules (VMC-038c), pure, over the data pack's
  smithing recipes (`priv/crafting/smithing.json`, `SmithingOracle facts`):
  `result/3` is what `SmithingMenu.createResult` assembles from the
  template, the base and the addition. A transform (the netherite upgrade)
  turns the base into its result keeping every component (its enchantments,
  wear, trim and name); a trim puts the template's pattern and the
  addition's `provides_trim_material` on one of the base, unless the base
  wears that trim already.
  """
  use Valimc.Data.Facts, "crafting/smithing.json"
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  set = fn
    nil -> nil
    names -> MapSet.new(names)
  end

  @recipes for r <- @facts["recipes"],
               do: %{
                 type: r["type"],
                 template: set.(r["template"]),
                 base: set.(r["base"]),
                 addition: set.(r["addition"]),
                 result: r["result"],
                 count: r["count"],
                 pattern: r["pattern"]
               }

  @doc "Whether `stack` may go in the menu's slot `slot` (0 template, 1 base, 2 addition)."
  def may_place?(slot, stack) do
    key = elem({:template, :base, :addition}, slot)
    name = name(stack)
    Enum.any?(@recipes, fn r -> r[key] != nil and MapSet.member?(r[key], name) end)
  end

  @doc "The result of the inputs, or nil (`getRecipeFor` then `assemble`)."
  def result(template, base, addition) do
    Enum.find_value(@recipes, fn recipe ->
      if matches?(recipe.template, template) and base != nil and matches?(recipe.base, base) and
           matches?(recipe.addition, addition),
         do: {:found, assemble(recipe, base, addition)}
    end)
    |> case do
      {:found, result} -> result
      nil -> nil
    end
  end

  # `Ingredient.testOptionalIngredient`: no ingredient takes no item.
  defp matches?(nil, stack), do: stack == nil
  defp matches?(_set, nil), do: false
  defp matches?(set, stack), do: MapSet.member?(set, name(stack))

  defp name(stack), do: ItemTypes.item(stack.item_id)["name"]

  # `TransmuteRecipe.createWithOriginalComponents`.
  defp assemble(%{type: "transform"} = recipe, base, _addition),
    do: %{base | item_id: ItemTypes.id(recipe.result), count: recipe.count}

  # `SmithingTrimRecipe.applyTrim`.
  defp assemble(%{type: "trim", pattern: pattern}, base, addition) do
    case addition && ItemStack.component(addition, "minecraft:provides_trim_material") do
      nil ->
        nil

      material ->
        trim = %{"material" => material, "pattern" => pattern}

        if ItemStack.component(base, "minecraft:trim") == trim,
          do: nil,
          else: %{base | count: 1, components: Map.put(base.components, "minecraft:trim", trim)}
    end
  end
end
