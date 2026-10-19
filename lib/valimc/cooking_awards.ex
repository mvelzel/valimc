defmodule Valimc.CookingAwards do
  @moduledoc "Pure bounded XP decisions; callers must journal the proposal before clearing recipe credit."
  alias Valimc.CookingRecipes
  @max_int 2_147_483_647
  @draw_scale 16_777_216

  @doc "Plan all stored uses with explicit unsigned 24-bit nextFloat samples keyed by recipe."
  def plan(uses, draws \\ %{})

  def plan(uses, draws)
      when is_map(uses) and map_size(uses) <= 107 and is_map(draws) and map_size(draws) <= 107 do
    rows =
      uses
      |> Enum.sort()
      |> Enum.map(fn {recipe, count} ->
        true = is_integer(count) and count in 1..@max_int
        {:ok, xp} = CookingRecipes.experience(recipe)
        product = f32(f32(count) * xp)

        # Native integer saturation/wrap at extreme edited counts must not erase credit.
        if product > @max_int, do: throw({:award_error, :experience_limit})
        whole = floor(product)
        {recipe, count, whole, f32(product - f32(whole))}
      end)

    true =
      Enum.all?(draws, fn {recipe, sample} ->
        Map.has_key?(uses, recipe) and is_integer(sample) and sample in 0..(@draw_scale - 1)
      end)

    {awards, total, used} =
      Enum.reduce(rows, {[], 0, %{}}, fn {recipe, count, whole, fraction},
                                         {awards, total, used} ->
        {amount, used} =
          if fraction == 0.0 do
            {whole, used}
          else
            sample =
              case Map.fetch(draws, recipe) do
                {:ok, sample} -> sample
                :error -> throw({:award_error, :missing_award_draw})
              end

            {whole + if(sample / @draw_scale < fraction, do: 1, else: 0),
             Map.put(used, recipe, sample)}
          end

        if total + amount > @max_int, do: throw({:award_error, :experience_limit})
        award = %{recipe: recipe, uses: count, experience: amount}
        {[award | awards], total + amount, used}
      end)

    {:ok, %{recipes: Enum.reverse(awards), experience: total, draws_used: used}}
  rescue
    _ -> {:error, :invalid_cooking_award}
  catch
    {:award_error, reason} -> {:error, reason}
  end

  def plan(_, _), do: {:error, :invalid_cooking_award}

  defp f32(number) do
    <<rounded::float-32>> = <<number::float-32>>
    rounded
  end
end
