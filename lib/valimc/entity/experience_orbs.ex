defmodule Valimc.Entity.ExperienceOrbs do
  @moduledoc """
  Experience orbs as entities (VMC-077h): the records a cooking award spawns,
  and what a player touches to pick one up.

  Vanilla awards each recipe's experience separately (`ExperienceOrb.award`),
  splitting it greedily into orb values (`getExperienceValue`); a new orb
  joins an earlier one at its spot only by chance (`plan/3`), and lying orbs
  merge now and then (`merge/2`), so an orb entity has a count. An orb record
  is `%{kind: :orb, uuid, x, y, z, value, count, age}`.
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

  @doc "Whether a player's `box` touches the orb at `{x, y, z}` (its pickup box, inflated)."
  def contact?(box, {x, y, z}) do
    with {:ok, query} <- Valimc.Entity.ItemPickup.query_box(box),
         do:
           Valimc.Data.Box.intersects?(
             query,
             {x - 0.25, y, z - 0.25, x + 0.25, y + 0.5, z + 0.25}
           ),
         else: (_ -> false)
  end

  @doc """
  The orb records of a cooking award (`CookingAwards.plan/2`) at `position`.
  The furnace awards each recipe separately (`orbs/2`): splitting their sum
  would change denominations (XP 3 + 4 is 3, 3, 1, never one value-7 orb).
  """
  def award(position, %{recipes: recipes}),
    do: orbs(position, Enum.map(recipes, & &1.experience))

  @doc """
  The orb records of `points` dropped at `position` (vanilla's
  `ExperienceOrb.award` of a dying player's or a mined block's reward).
  """
  def drop(position, points) when is_integer(points) and points >= 0,
    do: orbs(position, [points])

  @doc """
  One orb of `value` at `position` (`new ExperienceOrb`, a breeding's: not
  split into denominations), with the constructor's launch.
  """
  def single({x, y, z}, value) when is_integer(value) and value > 0 do
    draws = {:rand.uniform_real(), :rand.uniform_real(), :rand.uniform_real()}
    {:ok, launch} = Valimc.Entity.OrbMotion.launch({x, y, z}, {0.0, 0.0, 0.0}, draws)

    %{
      kind: :orb,
      uuid: uuid(),
      x: x,
      y: y,
      z: z,
      value: value,
      count: 1,
      age: 0,
      motion: %Valimc.Entity.ItemMotionState{velocity: launch.velocity}
    }
  end

  @doc """
  The orb records of `amounts` awarded in turn at `position` (vanilla's
  `ExperienceOrb.award` of each): the orbs `plan/3` spawns, each with its
  count and vanilla's random launch velocity (the constructor's, no
  direction), so a furnace's or a mob's orbs scatter.
  """
  def orbs({x, y, z}, amounts) do
    for {value, count} <- plan(amounts, fn -> :rand.uniform(40) - 1 end) do
      draws = {:rand.uniform_real(), :rand.uniform_real(), :rand.uniform_real()}
      {:ok, launch} = Valimc.Entity.OrbMotion.launch({x, y, z}, {0.0, 0.0, 0.0}, draws)
      motion = %Valimc.Entity.ItemMotionState{velocity: launch.velocity}

      %{
        kind: :orb,
        uuid: uuid(),
        x: x,
        y: y,
        z: z,
        value: value,
        count: count,
        age: 0,
        motion: motion
      }
    end
  end

  @doc """
  Vanilla's merge-or-spawn choice (`ExperienceOrb.awardWithDirection`) for the
  orbs of `amounts` awarded in turn at one position: each orb, in `split/1`'s
  order, joins the first earlier orb of its value whose id is congruent modulo
  40 to a uniform pick below 40 (`tryMergeToExisting`), else spawns with the
  next id from `base`. `pick` returns the next pick. `[{value, count}]` in
  spawn order. Orbs already lying there are not considered.

  Once all 40 congruence classes of a value hold an orb, every further orb of
  it joins one; past 4,096 such orbs in one amount, they are shared out evenly
  and only the remainder is picked.
  """
  def plan(amounts, pick, base \\ 0) do
    {spawned, _} =
      for amount <- amounts,
          {:ok, split} <- [split(amount)],
          {value, count} <- Enum.sort(split, :desc),
          reduce: {%{}, %{}} do
        acc -> award_value(acc, value, count, pick, base)
      end

    spawned |> Enum.sort() |> Enum.map(fn {_, orb} -> orb end)
  end

  # `spawned` maps a spawn index to `{value, count}`; `first` maps `{value,
  # id mod 40}` to the first such orb's index.
  defp award_value({spawned, first} = acc, value, count, pick, base) do
    full = Enum.all?(0..39, &Map.has_key?(first, {value, &1}))

    if full and count > 4096 do
      share = div(count, 40)

      spawned =
        Enum.reduce(0..39, spawned, fn r, acc ->
          Map.update!(acc, first[{value, r}], fn {v, n} -> {v, n + share} end)
        end)

      award_value({spawned, first}, value, rem(count, 40), pick, base)
    else
      Enum.reduce(1..count//1, acc, fn _, {spawned, first} ->
        case first[{value, pick.()}] do
          nil ->
            index = map_size(spawned)
            key = {value, Integer.mod(base + index, 40)}
            {Map.put(spawned, index, {value, 1}), Map.put_new(first, key, index)}

          index ->
            {Map.update!(spawned, index, fn {v, n} -> {v, n + 1} end), first}
        end
      end)
    end
  end

  @doc """
  Vanilla's orb merging (`ExperienceOrb.scanForMerges`) by the orbs
  `scanning`, in order: each one still present absorbs every other orb of its
  value whose id is congruent to its own modulo 40 and whose box meets its own
  grown by 0.5, adding their counts and keeping the lower age. `orbs` maps an
  id to `%{value, count, age, at: {x, y, z}}`; returns `{orbs, absorbed}`
  with the absorbed orbs' ids.
  """
  def merge(orbs, scanning) do
    Enum.reduce(scanning, {orbs, []}, fn id, {orbs, absorbed} ->
      case orbs do
        %{^id => orb} ->
          query = grown(orb.at)

          taken =
            for {other, o} <- orbs,
                other != id and o.value == orb.value and rem(other - id, 40) == 0 and
                  Valimc.Data.Box.intersects?(query, box(o.at)),
                do: other

          merged =
            Enum.reduce(taken, orb, fn other, acc ->
              %{acc | count: acc.count + orbs[other].count, age: min(acc.age, orbs[other].age)}
            end)

          {orbs |> Map.drop(taken) |> Map.put(id, merged), taken ++ absorbed}

        _ ->
          {orbs, absorbed}
      end
    end)
  end

  defp box({x, y, z}), do: {x - 0.25, y, z - 0.25, x + 0.25, y + 0.5, z + 0.25}

  defp grown(at) do
    {x0, y0, z0, x1, y1, z1} = box(at)
    {x0 - 0.5, y0 - 0.5, z0 - 0.5, x1 + 0.5, y1 + 0.5, z1 + 0.5}
  end

  # A version-4 UUID, as vanilla gives a new entity.
  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end
end
