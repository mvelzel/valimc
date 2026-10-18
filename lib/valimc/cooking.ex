defmodule Valimc.Cooking do
  @moduledoc "One bounded pure stock furnace step; the region must durably admit its entire result."
  alias Valimc.{CookingRecipes, Protocol.ItemStack}
  alias Valimc.Physics.{CookingFuel, CookingItems}
  defstruct slots: {nil, nil, nil}, burn_left: 0, burn_total: 0, progress: 0, total: 0, speed: 1.0

  def step(%__MODULE__{} = state, block) do
    true = valid?(state)

    case CookingRecipes.find(nil, block, state.speed) do
      :none -> :ok
      {:error, reason} -> throw({:cooking_error, reason})
    end

    {input, fuel, _} = state.slots
    next = %{state | burn_left: max(0, state.burn_left - 1)}

    cond do
      next.burn_left > 0 or (fuel != nil and input != nil) -> cook(next, block)
      next.progress > 0 -> result(%{next | progress: min(next.total, max(0, next.progress - 2))})
      true -> result(next)
    end
  rescue
    _ -> {:error, :invalid_cooking_state}
  catch
    {:cooking_error, reason} -> {:error, reason}
    {:item_error, _} -> {:error, :invalid_cooking_state}
  end

  def step(_, _), do: {:error, :invalid_cooking_state}

  defp cook(%{slots: {nil, _, _}} = state, _), do: result(%{state | progress: 0})

  defp cook(state, block) do
    case CookingRecipes.find(elem(state.slots, 0), block, state.speed) do
      :none ->
        result(state)

      {:ok, recipe} ->
        case CookingItems.finish(state.slots, recipe.result) do
          {:error, :output_full} -> result(%{state | progress: 0})
          {:ok, _} -> advance(state, block, recipe)
          {:error, reason} -> throw({:cooking_error, reason})
        end

      {:error, reason} ->
        throw({:cooking_error, reason})
    end
  end

  defp advance(state, block, recipe) do
    {state, drops} = if state.burn_left > 0, do: {state, []}, else: ignite(state, block)

    if state.burn_left > 0 do
      state = %{state | progress: state.progress + 1}

      if state.progress >= state.total do
        {:ok, current_recipe} = CookingRecipes.find(elem(state.slots, 0), block, state.speed)
        {:ok, slots} = CookingItems.finish(state.slots, recipe.result)

        result(
          %{state | slots: slots, progress: 0, total: current_recipe.cook_ticks},
          drops,
          recipe.key
        )
      else
        result(state, drops)
      end
    else
      result(%{state | progress: 0}, drops)
    end
  end

  defp ignite(state, block) do
    fuel = elem(state.slots, 1)

    case CookingFuel.resolve(fuel, block) do
      {:ok, resolved} ->
        next = %{
          state
          | burn_left: resolved.burn_ticks,
            burn_total: resolved.burn_ticks,
            speed: resolved.speed_multiplier
        }

        next =
          if state.total > 0 and state.progress < state.total do
            {:ok, recipe} = CookingRecipes.find(elem(state.slots, 0), block, next.speed)
            progress = ceil(f32(f32(state.progress / state.total) * recipe.cook_ticks))
            %{next | progress: progress, total: recipe.cook_ticks}
          else
            next
          end

        if next.burn_left > 0 do
          {:ok, consumed} = CookingItems.consume_fuel(fuel, block)
          {%{next | slots: put_elem(next.slots, 1, consumed.fuel)}, consumed.drops}
        else
          {next, []}
        end

      {:error, reason} ->
        throw({:cooking_error, reason})
    end
  end

  defp result(state, drops \\ [], completed \\ nil),
    do: {:ok, state, %{lit: state.burn_left > 0, drops: drops, completed: completed}}

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end

  defp valid?(state) do
    is_tuple(state.slots) and tuple_size(state.slots) == 3 and
      Enum.all?(Tuple.to_list(state.slots), fn
        nil ->
          true

        %ItemStack{} = stack ->
          ItemStack.identity_key(stack)
          true

        _ ->
          false
      end) and is_integer(state.burn_left) and state.burn_left in 0..20_000 and
      is_integer(state.burn_total) and state.burn_total in 0..20_000 and
      is_integer(state.progress) and state.progress in 0..200 and
      is_integer(state.total) and state.total in 0..200 and state.speed in [1.0, 2.0]
  end
end
