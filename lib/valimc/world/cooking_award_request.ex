defmodule Valimc.World.CookingAwardRequest do
  @moduledoc "A withdrawal pins the player's spawn pose and recipe grant names in its durable action."
  alias Valimc.PlayerProgression

  def encode(%{position: {x, y, z}, recipes: recipes} = award)
      when map_size(award) == 2 and is_list(recipes) and length(recipes) in 1..107 do
    true =
      Enum.all?([x, y, z], &is_float/1) and abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and
        abs(y) <= 1_000_000

    true = recipes == Enum.sort(Enum.uniq(recipes))
    ids = PlayerProgression.recipe_ids()
    rows = Enum.map(recipes, fn name -> <<Map.fetch!(ids, name)::16>> end)
    {:ok, IO.iodata_to_binary([<<x::float-64, y::float-64, z::float-64, length(recipes)>>, rows])}
  rescue
    _ -> {:error, :invalid_cooking_award_request}
  end

  def encode(_), do: {:error, :invalid_cooking_award_request}

  def decode(<<x::float-64, y::float-64, z::float-64, count, rows::binary>> = bytes) do
    true = count in 1..107 and byte_size(rows) == count * 2
    names = List.to_tuple(PlayerProgression.recipe_names())
    recipes = for <<id::16 <- rows>>, do: elem(names, id)
    award = %{position: {x, y, z}, recipes: recipes}
    {:ok, ^bytes} = encode(award)
    {:ok, award}
  rescue
    _ -> {:error, :invalid_cooking_award_request}
  end

  def decode(_), do: {:error, :invalid_cooking_award_request}
end
