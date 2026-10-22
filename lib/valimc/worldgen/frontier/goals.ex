defmodule Valimc.Worldgen.Frontier.Goals do
  @moduledoc """
  What a dimension's generation is asked for, and in which order (VMC-077x1).

  Demand is membership: each requester wants a set of chunks, some urgent
  (calls that wait). A wanted chunk that is not sent yet nor given up is a
  goal. Goals live in one ordered set: urgent ones first, then by their
  `score/2` from the nearest player (`focus/4`), and with no player in key
  order (Z, then X). A change of wants inserts and deletes goals; a player who
  crossed a chunk re-scores the set once, before the next dispatch. Nothing
  else stores a priority: the work a goal needs is found from the goals in
  order when jobs start (`Valimc.Worldgen.Frontier.Dependencies`).
  """
  alias Valimc.Worldgen.Frontier

  @doc """
  `requester` wants `wanted` (`chunk => urgent?`), replacing what it wanted:
  `{f, added, gained, lost}`, the chunks nobody wanted before, and the goals
  gained and lost.
  """
  def want(%Frontier{} = f, requester, wanted) do
    before = Map.get(f.wants, requester, %{})
    changed = for {c, urgent} <- wanted, Map.get(before, c) != urgent, do: c
    removed = for {c, _} <- before, not Map.has_key?(wanted, c), do: c
    added = Enum.reject(changed, &Map.has_key?(f.index, &1))

    index =
      Enum.reduce(removed, f.index, fn c, index ->
        case Map.delete(index[c], requester) do
          by when by == %{} -> Map.delete(index, c)
          by -> Map.put(index, c, by)
        end
      end)

    index =
      Enum.reduce(changed, index, fn c, index ->
        Map.update(index, c, %{requester => wanted[c]}, &Map.put(&1, requester, wanted[c]))
      end)

    wants =
      if wanted == %{},
        do: Map.delete(f.wants, requester),
        else: Map.put(f.wants, requester, wanted)

    {f, gained, lost} = places(%{f | wants: wants, index: index}, changed ++ removed)
    {f, added, gained, lost}
  end

  @doc "`chunk` was sent to everyone who wanted it: it is wanted no more (`{f, lost}`)."
  def sent(%Frontier{} = f, chunk) do
    wants =
      Enum.reduce(Map.get(f.index, chunk, %{}), f.wants, fn {requester, _}, wants ->
        case Map.delete(wants[requester], chunk) do
          left when left == %{} -> Map.delete(wants, requester)
          left -> Map.put(wants, requester, left)
        end
      end)

    {f, [], lost} = places(%{f | wants: wants, index: Map.delete(f.index, chunk)}, [chunk])
    {f, lost}
  end

  @doc "These wanted chunks cannot be generated: goals no more (`{f, lost}`)."
  def give_up(%Frontier{} = f, chunks) do
    {f, [], lost} = places(%{f | given_up: Enum.into(chunks, f.given_up)}, chunks)
    {f, lost}
  end

  @doc """
  Player `holder` is in `chunk`, moving along `heading` (`{x, z}` of unit
  length, or nil when it stands or jumped); a nil chunk forgets it. The goals
  are re-scored before the next dispatch.
  """
  def focus(%Frontier{} = f, holder, nil, _heading) do
    if Map.has_key?(f.focus, holder),
      do: %{f | focus: Map.delete(f.focus, holder), rescore: true},
      else: f
  end

  def focus(%Frontier{} = f, holder, chunk, heading),
    do: %{f | focus: Map.put(f.focus, holder, {chunk, heading}), rescore: true}

  @doc "The goals in order, re-scored if a player moved since."
  def rescore(%Frontier{rescore: false} = f), do: f

  def rescore(%Frontier{} = f) do
    ranks = Map.new(f.ranks, fn {c, _} -> {c, rank(f, c)} end)
    goals = :gb_sets.from_list(for {{x, z} = c, r} <- ranks, do: {r, z, x, c})
    %{f | ranks: ranks, goals: goals, rescore: false}
  end

  @doc "Whether `chunk` is a goal."
  def goal?(%Frontier{ranks: ranks}, chunk), do: Map.has_key?(ranks, chunk)

  @doc "`chunks` (goals) in goal order."
  def sort(%Frontier{ranks: ranks}, chunks),
    do: Enum.sort_by(chunks, fn {x, z} = c -> {ranks[c], z, x} end)

  @doc "Who wants `chunk`."
  def wanting(%Frontier{index: index}, chunk), do: Map.keys(Map.get(index, chunk, %{}))

  @doc """
  A chunk's score from a player in `center` moving along `heading`: 0 for the
  player's own chunk, then four times the squared distance, weighted by
  direction: a quarter of it straight ahead, seven quarters straight behind.
  """
  def score({x, z}, {{cx, cz}, heading}) do
    {dx, dz} = {x - cx, z - cz}
    d2 = dx * dx + dz * dz

    case heading do
      {hx, hz} when d2 > 0 -> round(d2 * (4 - 3 * (dx * hx + dz * hz) / :math.sqrt(d2)))
      _ -> 4 * d2
    end
  end

  @doc "`chunk`'s score from the nearest player; 0 with none."
  def nearest(%Frontier{focus: focus}, _chunk) when focus == %{}, do: 0

  def nearest(%Frontier{focus: focus}, chunk),
    do: focus |> Map.values() |> Enum.map(&score(chunk, &1)) |> Enum.min()

  # Urgent goals first, then by score.
  defp rank(f, chunk) do
    if Enum.any?(f.index[chunk], &elem(&1, 1)), do: -1, else: nearest(f, chunk)
  end

  # The places of `chunks` among the goals as their wants are now:
  # `{f, gained, lost}`.
  defp places(f, chunks) do
    Enum.reduce(chunks, {f, [], []}, fn {x, z} = chunk, {f, gained, lost} ->
      old = Map.get(f.ranks, chunk)

      new =
        if Map.has_key?(f.index, chunk) and not MapSet.member?(f.given_up, chunk),
          do: rank(f, chunk)

      if old == new do
        {f, gained, lost}
      else
        goals = if old, do: :gb_sets.delete({old, z, x, chunk}, f.goals), else: f.goals
        goals = if new, do: :gb_sets.add({new, z, x, chunk}, goals), else: goals
        ranks = if new, do: Map.put(f.ranks, chunk, new), else: Map.delete(f.ranks, chunk)
        f = %{f | goals: goals, ranks: ranks}

        cond do
          old == nil -> {f, [chunk | gained], lost}
          new == nil -> {f, gained, [chunk | lost]}
          true -> {f, gained, lost}
        end
      end
    end)
  end
end
