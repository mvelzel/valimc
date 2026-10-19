defmodule Valimc.PlayerProgression do
  @moduledoc "Durable player XP and learned cooking recipes; immutable award proofs stay with regions."
  alias Valimc.PlayerExperience
  import Bitwise
  @path Path.expand("../../priv/crafting/cooking.json", __DIR__)
  @external_resource @path
  @recipes JSON.decode!(File.read!(@path))["recipes"] |> Enum.map(& &1["recipe"])
  @ids @recipes |> Enum.with_index() |> Map.new()
  defstruct experience: %PlayerExperience{}, recipes: MapSet.new()
  def recipe_ids, do: @ids
  def recipe_names, do: @recipes
  def bytes, do: 26

  def valid?(%__MODULE__{experience: xp, recipes: %MapSet{} = recipes}),
    do:
      PlayerExperience.valid?(xp) and MapSet.size(recipes) <= length(@recipes) and
        Enum.all?(recipes, &Map.has_key?(@ids, &1))

  def valid?(_), do: false

  def learn(%__MODULE__{} = state, recipes) when is_list(recipes) and length(recipes) <= 107 do
    next = %{state | recipes: MapSet.union(state.recipes, MapSet.new(recipes))}
    if valid?(next), do: {:ok, next}, else: {:error, :invalid_recipe_grant}
  end

  def encode(state) do
    true = valid?(state)
    {:ok, xp} = PlayerExperience.encode(state.experience)

    mask =
      Enum.reduce(state.recipes, 0, fn recipe, mask ->
        bor(mask, bsl(1, Map.fetch!(@ids, recipe)))
      end)

    {:ok, <<xp::binary, mask::112>>}
  rescue
    _ -> {:error, :invalid_player_progression}
  end

  def decode(<<xp::binary-size(12), mask::112>>) do
    {:ok, xp} = PlayerExperience.decode(xp)
    true = mask < bsl(1, length(@recipes))
    recipes = for {recipe, id} <- @ids, band(mask, bsl(1, id)) != 0, do: recipe
    state = %__MODULE__{experience: xp, recipes: MapSet.new(recipes)}
    {:ok, _} = encode(state)
    {:ok, state}
  rescue
    _ -> {:error, :invalid_player_progression}
  end

  def decode(_), do: {:error, :invalid_player_progression}
end
