defmodule Valimc.World.ExperienceOrbs do
  @moduledoc """
  Experience orbs as entities (VMC-077h): the records a cooking award spawns.

  Vanilla awards each recipe's experience separately (`ExperienceOrb.award`),
  splitting it greedily into orb values (`getExperienceValue`); orbs of one
  value at one position merge into one entity with a count. An orb record is
  `%{kind: :orb, uuid, x, y, z, value, count, age}`.
  """
  @values [2477, 1237, 617, 307, 149, 73, 37, 17, 7, 3, 1]
  @max_experience 2_147_483_647

  @doc "Vanilla's denominations of `amount`: `%{value => count}`, at most eleven values."
  def split(amount) when is_integer(amount) and amount in 0..@max_experience do
    {groups, 0} =
      Enum.reduce(@values, {%{}, amount}, fn value, {groups, remaining} ->
        count = div(remaining, value)
        next = if count == 0, do: groups, else: Map.put(groups, value, count)
        {next, rem(remaining, value)}
      end)

    {:ok, groups}
  end

  def split(_), do: {:error, :invalid_experience}

  @doc """
  The orb records of a cooking award (`CookingAwards.plan/2`) at `position`,
  one per value. The furnace awards each recipe separately: splitting their sum
  would change denominations (XP 3 + 4 is 3, 3, 1, never one value-7 orb).
  """
  def award({x, y, z}, %{recipes: recipes}) do
    recipes
    |> Enum.reduce(%{}, fn row, groups ->
      {:ok, split} = split(row.experience)
      Map.merge(groups, split, fn _, a, b -> a + b end)
    end)
    |> Enum.sort(:desc)
    |> Enum.map(fn {value, count} ->
      %{kind: :orb, uuid: uuid(), x: x, y: y, z: z, value: value, count: count, age: 0}
    end)
  end

  # A version-4 UUID, as vanilla gives a new entity.
  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end
end
