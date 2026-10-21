defmodule Valimc.CookingFuel do
  @moduledoc "Pinned stock CookingFuel resolution in native furnace contexts; no fuel consumption or cooking authority."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  use Valimc.Facts, "physics/cooking_fuel.json"

  @contexts @facts["contexts"]
            |> Enum.with_index()
            |> Enum.flat_map(fn {states, kind} -> Enum.map(states, &{&1, kind}) end)
            |> Map.new()
  @profiles @facts["profiles"]
            |> Enum.map(fn profile ->
              profile
              |> Enum.map(fn [burn, speed] -> %{burn_ticks: burn, speed_multiplier: speed} end)
              |> List.to_tuple()
            end)
            |> List.to_tuple()
  @items List.to_tuple(@facts["items"])
  unless @facts["item_count"] == 1658 and tuple_size(@items) == 1658 and
           @facts["fuel_items"] == 347 and map_size(@contexts) == 24 and
           Enum.all?(@contexts, fn {state, kind} ->
             is_integer(state) and state in 0..35_722 and kind in 0..2
           end) and
           Enum.all?(Tuple.to_list(@profiles), fn profile ->
             tuple_size(profile) == 3 and
               Enum.all?(Tuple.to_list(profile), fn entry ->
                 is_integer(entry.burn_ticks) and entry.burn_ticks in 0..20_000 and
                   entry.speed_multiplier in [1.0, 2.0]
               end)
           end) and
           Enum.all?(
             Tuple.to_list(@items),
             &(is_integer(&1) and &1 >= 0 and &1 < tuple_size(@profiles))
           ) and
           Enum.count(Tuple.to_list(@items), &(elem(elem(@profiles, &1), 0).burn_ticks > 0)) ==
             347,
         do: raise("Wrong native cooking-fuel facts")

  @doc "The cooking blocks' states by fuel context: 0 furnace, 1 smoker, 2 blast furnace."
  def contexts, do: @contexts

  def resolve(stack, state) do
    case Map.fetch(@contexts, state) do
      {:ok, kind} -> fuel(stack, kind)
      :error -> {:error, :unsupported_furnace_context}
    end
  end

  defp fuel(nil, _), do: {:ok, %{burn_ticks: 0, speed_multiplier: 1.0}}

  defp fuel(%ItemStack{item_id: item, components: components, removed: removed} = stack, kind)
       when is_integer(item) and item > 0 and item < 1658 do
    if Map.has_key?(components, "minecraft:cooking_fuel") do
      {:error, :unsupported_cooking_fuel}
    else
      _identity = ItemStack.identity_key(stack)
      true = ItemTypes.item(item) != nil

      if MapSet.member?(removed, "minecraft:cooking_fuel"),
        do: fuel(nil, kind),
        else: {:ok, elem(elem(@profiles, elem(@items, item)), kind)}
    end
  rescue
    _ -> {:error, :invalid_cooking_fuel}
  catch
    {:item_error, _} -> {:error, :invalid_cooking_fuel}
  end

  defp fuel(_, _), do: {:error, :invalid_cooking_fuel}
end
