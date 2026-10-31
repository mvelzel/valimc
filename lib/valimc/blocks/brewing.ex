defmodule Valimc.Blocks.Brewing do
  @moduledoc """
  The brewing stand (VMC-034o) as 26.3's data gives it
  (`priv/crafting/brewing.json`, `BrewingOracle facts`): the `minecraft:brewing`
  recipes, the reagents, the potion inputs and the fuels. `tick/2` is
  `BrewingStandBlockEntity.serverTick` as a pure step over the five slots (three
  bottles, the ingredient, the fuel) and the stand's times.

  A stand's state is `%Brewing{}`: the brew time left and its total, the fuel
  uses left and their total, the fuel's speed, the ingredient a brew started
  with (`ingredient`, an item id) and the bottle bits last shown on the block
  (`shown`, nil before the first tick).
  """
  use Valimc.Data.Facts, "crafting/brewing.json"
  alias Valimc.Data.PotionTypes
  alias Valimc.Protocol.{ItemStack, ItemTypes, PotionContents}

  # A placed stand's totals start at 0; a saved one without them reads 400
  # and 20 (`loadAdditional`).
  defstruct brew_time: 0,
            total_brew_time: 0,
            fuel: 0,
            total_fuel: 0,
            speed: 1.0,
            ingredient: nil,
            shown: nil

  @type t :: %__MODULE__{}

  @recipes Map.new(
             for row <- @facts["recipes"], potion <- row["potions"] do
               {{ItemTypes.id(row["input"]), PotionTypes.id(potion),
                 ItemTypes.id(row["reagent"])},
                {ItemTypes.id(row["output"]), PotionTypes.id(row["output_potion"])}}
             end
           )
  @reagents MapSet.new(@facts["reagents"], &ItemTypes.id/1)
  @inputs MapSet.new(@facts["potion_inputs"], &ItemTypes.id/1)
  @fuels Map.new(@facts["fuels"], fn row ->
           remainder = row["remainder"] && ItemTypes.id(row["remainder"])
           {ItemTypes.id(row["item"]), {row["uses"], row["speed"] * 1.0, remainder}}
         end)
  @remainders Map.new(@facts["reagent_remainders"], fn {item, rest} ->
                {ItemTypes.id(item), ItemTypes.id(rest)}
              end)

  @doc "Whether `stack` is a reagent (`RecipePropertySet.BREWING_REAGENTS`)."
  def reagent?(%ItemStack{item_id: id}), do: MapSet.member?(@reagents, id)
  def reagent?(_), do: false

  @doc "Whether `stack` may stand in a bottle slot (`PotionIngredient.isPotionInput`)."
  def potion_input?(%ItemStack{item_id: id}), do: MapSet.member?(@inputs, id)
  def potion_input?(_), do: false

  @doc "Whether `stack` fuels a stand (its `brewing_fuel` component)."
  def fuel?(stack), do: fuel(stack) != nil

  defp fuel(%ItemStack{item_id: id, removed: removed}) do
    if MapSet.member?(removed, "minecraft:brewing_fuel"), do: nil, else: @fuels[id]
  end

  defp fuel(_), do: nil

  @doc """
  The bottle a recipe makes of `bottle` with `reagent` (a fresh stack of the
  output and its potion, `BrewingRecipe.assemble`), or nil.
  """
  def brew(%ItemStack{item_id: input} = bottle, %ItemStack{item_id: reagent}) do
    with potion when is_integer(potion) <- potion(bottle),
         {output, made} <- @recipes[{input, potion, reagent}] do
      %ItemStack{
        item_id: output,
        components: %{"minecraft:potion_contents" => %{PotionContents.empty() | potion: made}}
      }
    else
      _ -> nil
    end
  end

  def brew(_, _), do: nil

  # The potion of a stack's contents, its own or its item's default.
  defp potion(%ItemStack{components: components, removed: removed, item_id: id}) do
    cond do
      MapSet.member?(removed, "minecraft:potion_contents") ->
        nil

      Map.has_key?(components, "minecraft:potion_contents") ->
        components["minecraft:potion_contents"].potion

      bytes = ItemTypes.defaults(id).values["minecraft:potion_contents"] ->
        {value, <<>>} = PotionContents.take(bytes)
        value.potion

      true ->
        nil
    end
  end

  @doc """
  One `serverTick`: `{stand, slots, events}` with `slots` a map of the five
  slots (0..2 bottles, 3 the ingredient, 4 the fuel; absent is empty).
  Events, in order: `:changed` (`setChanged`), `{:drop, stack}` (a
  remainder dropped at the stand), `{:level_event, 1035}` (a brew finished)
  and `{:bottles, [b0, b1, b2]}` (the `has_bottle_*` states to set).
  """
  def tick(%__MODULE__{} = stand, slots) when is_map(slots) do
    {stand, slots, events} = refuel(stand, slots, [])
    brewable = brewable?(slots)
    ingredient = slots[3]

    {stand, slots, events} =
      cond do
        stand.brew_time > 0 ->
          stand = %{stand | brew_time: stand.brew_time - 1}

          cond do
            stand.brew_time == 0 and brewable ->
              {slots, events} = do_brew(slots, events)
              {stand, slots, [:changed | events]}

            not brewable or ingredient == nil or ingredient.item_id != stand.ingredient ->
              {%{stand | brew_time: 0}, slots, [:changed | events]}

            true ->
              {stand, slots, [:changed | events]}
          end

        brewable and stand.fuel > 0 ->
          speed = if stand.speed > 0.0, do: stand.speed, else: 1.0
          time = ceil(Valimc.Data.Float32.round(400.0 / speed))

          stand = %{
            stand
            | fuel: stand.fuel - 1,
              brew_time: time,
              total_brew_time: time,
              ingredient: ingredient.item_id
          }

          {stand, slots, [:changed | events]}

        true ->
          {stand, slots, events}
      end

    bits = for slot <- 0..2, do: slots[slot] != nil

    if bits == stand.shown,
      do: {stand, slots, Enum.reverse(events)},
      else: {%{stand | shown: bits}, slots, Enum.reverse([{:bottles, bits} | events])}
  end

  defp refuel(%{fuel: fuel} = stand, slots, events) when fuel <= 0 do
    case fuel(slots[4]) do
      nil ->
        {stand, slots, events}

      {uses, speed, remainder} ->
        stack = slots[4]
        {left, events} = shrink(stack, remainder, events)
        stand = %{stand | fuel: uses, total_fuel: uses, speed: speed}
        {stand, put(slots, 4, left), [:changed | events]}
    end
  end

  defp refuel(stand, slots, events), do: {stand, slots, events}

  # One taken off `stack`: its remainder replaces it when it runs out, and
  # drops beside the stand otherwise.
  defp shrink(stack, remainder, events) do
    left = if stack.count > 1, do: %{stack | count: stack.count - 1}

    cond do
      remainder == nil -> {left, events}
      left == nil -> {%ItemStack{item_id: remainder}, events}
      true -> {left, [{:drop, %ItemStack{item_id: remainder}} | events]}
    end
  end

  defp brewable?(slots) do
    ingredient = slots[3]

    reagent?(ingredient) and
      Enum.any?(0..2, fn slot -> slots[slot] != nil and brew(slots[slot], ingredient) != nil end)
  end

  defp do_brew(slots, events) do
    ingredient = slots[3]

    slots =
      Enum.reduce(0..2, slots, fn slot, slots ->
        case slots[slot] && brew(slots[slot], ingredient) do
          nil -> slots
          made -> Map.put(slots, slot, made)
        end
      end)

    {left, events} = shrink(ingredient, @remainders[ingredient.item_id], events)
    {put(slots, 3, left), [{:level_event, 1035} | events]}
  end

  defp put(slots, slot, nil), do: Map.delete(slots, slot)
  defp put(slots, slot, stack), do: Map.put(slots, slot, stack)
end
