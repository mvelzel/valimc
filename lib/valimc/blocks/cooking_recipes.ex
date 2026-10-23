defmodule Valimc.Blocks.CookingRecipes do
  @moduledoc "Indexed pinned stock furnace/smoker/blast-furnace recipe observations; no live cooking or XP awards."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  use Valimc.Data.Facts, "crafting/cooking.json"
  @contexts Valimc.Blocks.CookingFuel.contexts()
  @recipes @facts["recipes"]
           |> Enum.map(fn row ->
             <<xp::float-32>> = <<row["xp_bits"]::unsigned-32>>

             %{
               key: row["recipe"],
               result: %ItemStack{item_id: row["result"], count: row["count"]},
               base_ticks: row["ticks"],
               experience: xp,
               times: List.to_tuple(row["times"])
             }
           end)
           |> List.to_tuple()
  @items @facts["items"] |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
  @experience @recipes |> Tuple.to_list() |> Map.new(&{&1.key, &1.experience})
  @names @recipes |> Tuple.to_list() |> Enum.map(& &1.key)
  @ids @names |> Enum.with_index() |> Map.new()
  unless tuple_size(@items) == 3 and tuple_size(@recipes) == 107 and
           map_size(@experience) == 107 and map_size(@contexts) == 24 and
           Enum.all?(Tuple.to_list(@items), fn index ->
             tuple_size(index) == 1658 and
               Enum.all?(Tuple.to_list(index), &(is_integer(&1) and &1 in -1..106))
           end) and
           Enum.all?(Tuple.to_list(@recipes), fn recipe ->
             is_binary(recipe.key) and String.starts_with?(recipe.key, "minecraft:") and
               ItemTypes.item(recipe.result.item_id) != nil and recipe.result.count == 1 and
               recipe.base_ticks == 200 and recipe.times == {200, 200, 100} and
               recipe.experience >= 0 and recipe.experience <= 2
           end),
         do: raise("Wrong pinned cooking recipes")

  @doc """
  Smelting (furnace) results by input item name (`furnace_smelt` in loot
  tables): the recipe a furnace finds for each item that has one.
  """
  def smelting do
    furnace = elem(@items, 0)

    for id <- 0..(tuple_size(furnace) - 1),
        (index = elem(furnace, id)) >= 0,
        into: %{},
        do:
          {ItemTypes.item(id)["name"],
           ItemTypes.item(elem(@recipes, index).result.item_id)["name"]}
  end

  @doc "The recipe names in recipe id order."
  def names, do: @names

  @doc "Recipe ids by name."
  def ids, do: @ids

  @doc "Resolve stored recipe credit independently of the current input/block."

  def experience(key), do: Map.fetch(@experience, key)

  @doc "Select a stock recipe in the supplied cooking block and admitted stock speed context."
  def find(stack, state, speed \\ 1.0) do
    with {:ok, kind} <- Map.fetch(@contexts, state),
         true <- speed in [0.0, 1.0, 2.0] do
      lookup(stack, kind, speed)
    else
      :error -> {:error, :unsupported_furnace_context}
      false -> {:error, :unsupported_cooking_speed}
    end
  end

  defp lookup(nil, _, _), do: :none

  defp lookup(%ItemStack{item_id: item} = input, kind, speed)
       when is_integer(item) and item > 0 and item < 1658 do
    _identity = ItemStack.identity_key(input)

    case elem(elem(@items, kind), item) do
      -1 ->
        :none

      index ->
        recipe = elem(@recipes, index)

        {:ok,
         recipe |> Map.delete(:times) |> Map.put(:cook_ticks, elem(recipe.times, trunc(speed)))}
    end
  rescue
    _ -> {:error, :invalid_cooking_input}
  catch
    {:item_error, _} -> {:error, :invalid_cooking_input}
  end

  defp lookup(_, _, _), do: {:error, :invalid_cooking_input}
end
