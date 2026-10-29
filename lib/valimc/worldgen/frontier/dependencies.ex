defmodule Valimc.Worldgen.Frontier.Dependencies do
  @moduledoc """
  Chunk statuses and what generation work waits for (VMC-077n, VMC-077x1).

  A chunk is absent, then `:terrain` (it has a proto cell), then `:decorated`
  (its own decoration ran over its 3 × 3), and final once its whole 3 × 3 is
  decorated; it is `:handed` once its region persisted it. Decorating a chunk
  reads and writes its 3 × 3, so decorations within 2 conflict: a running
  decoration holds its 3 × 3, so conflicting ones run one after the other.
  Live generation runs them in the order they start (VMC-081c1), as vanilla's
  features run in the order its chunks reach them; the order they ran in is
  what a reference replays. In request order (`serial`, the oracle checks),
  conflicting decorations run in number order instead, so chunks depend only
  on the order of requests; live, that made the work beside a player wait for
  a chain of earlier requested decorations along the view's edge.

  A chunk gets a decoration number when a goal needs it and it has none (the
  goal's undecorated chunks within 1, nearest a player first, then Z outer and
  X inner). Each knows what it still waits for: in request order the earlier
  numbered decorations within 2 (`waits`, all numbered within 2 when it got
  its number; none live), and the chunks of its 3 × 3 without a cell
  (`lacking`). It can start once both are empty and none of its 3 × 3 is held.
  Its `need` counts the goals within 1 of it and the needed later decorations
  waiting for it, so it is needed while some goal reaches it; membership
  changes keep the count, players' moves never touch it. One nobody needs any
  more, and not running, gives its number up. `ready` holds the needed
  decorations that can start and are not running, and `terrain` counts, per
  chunk, the needed decorations that lack it. A result updates only what it
  touches; `free/2` is the one way a number goes (decorated, unneeded, or
  blocked by a frozen chunk), and it re-checks the decorations within 2 that
  waited for it.

  `resolve/3` finds the work to start from the goals in order. A chunk wanted
  again after it was handed over, or one that needs a decoration that can no
  longer run (a neighbour handed over or failed), is made alone (`alone`).
  """
  alias Valimc.Worldgen.Frontier
  alias Valimc.Worldgen.Frontier.Goals

  # Steps (goals and decorations) a walk takes at most.
  @budget 1_000

  @doc "The chunks within `r` of `chunk`, Z outer and X inner."
  def around({x, z}, r), do: for(dz <- -r..r, dx <- -r..r, do: {x + dx, z + dz})

  ## Statuses

  def status(f, chunk) do
    case f.chunks do
      %{^chunk => %{status: status}} -> status
      _ -> nil
    end
  end

  def handed?(f, chunk), do: status(f, chunk) == :handed
  def decorated?(f, chunk), do: status(f, chunk) in [:decorated, :handed]
  def cell?(f, chunk), do: status(f, chunk) in [:terrain, :decorated]
  defp frozen?(f, chunk), do: handed?(f, chunk) or Map.has_key?(f.failed, chunk)

  def final?(%{final_after_terrain: true} = f, chunk), do: cell?(f, chunk)
  def final?(f, chunk), do: Enum.all?(around(chunk, 1), &decorated?(f, &1))

  # An undecorated chunk whose decoration cannot run: its 3 × 3 holds a chunk
  # handed over (its region has it full) or failed.
  defp blocked?(f, n), do: not decorated?(f, n) and Enum.any?(around(n, 1), &frozen?(f, &1))

  # Made alone: lost after it was handed over, or needing a blocked decoration
  # (only possible with a frozen chunk within 2, the cheaper test first).
  def alone?(f, chunk) do
    handed?(f, chunk) or
      (Enum.any?(around(chunk, 2), &frozen?(f, &1)) and
         Enum.any?(around(chunk, 1), &blocked?(f, &1)))
  end

  defp needs_terrain?(f, c),
    do: status(f, c) == nil and not Map.has_key?(f.busy, c) and not Map.has_key?(f.failed, c)

  ## Goals gained and lost

  @doc """
  Goals gained (`added`: wanted by nobody before, `gained`: goals now) and
  lost: decorations numbered for the added ones, needs counted, and the goals
  final or to be made alone noted.
  """
  def goals(%Frontier{final_after_terrain: true} = f, _added, gained, _lost),
    do: Enum.reduce(gained, f, &check_final(&2, &1))

  def goals(f, added, gained, lost) do
    # Decorations numbered now count the goals around them as they start.
    f = Enum.reduce(gained, f, fn g, f -> Enum.reduce(around(g, 1), f, &need(&2, &1, 1)) end)
    f = Enum.reduce(lost, f, fn g, f -> Enum.reduce(around(g, 1), f, &need(&2, &1, -1)) end)
    f = number(f, Enum.uniq(added ++ gained))

    lost = MapSet.new(lost)
    f = %{f | finals: MapSet.difference(f.finals, lost), alone: MapSet.difference(f.alone, lost)}
    f = find_alone(f, gained)
    Enum.reduce(gained, f, &check_final(&2, &1))
  end

  # Decoration numbers for the undecorated chunks within 1 of `goals` that have
  # none, nearest a player first, then Z outer and X inner. In request order
  # every numbered chunk within 2 is earlier; the goals within 1 need it.
  defp number(f, goals) do
    goals
    |> Enum.flat_map(&around(&1, 1))
    |> Enum.uniq()
    |> Enum.reject(&(decorated?(f, &1) or Map.has_key?(f.seqs, &1) or blocked?(f, &1)))
    |> Enum.sort_by(fn {x, z} = n -> {Goals.nearest(f, n), z, x} end)
    |> Enum.reduce(f, fn n, f ->
      waits = if f.serial, do: for(m <- around(n, 2), m != n, Map.has_key?(f.deps, m), do: m)
      lacking = Enum.reject(around(n, 1), &cell?(f, &1))

      f = %{
        f
        | seqs: Map.put(f.seqs, n, f.next_seq),
          next_seq: f.next_seq + 1,
          deps: Map.put(f.deps, n, %{waits: waits || [], lacking: lacking, need: 0})
      }

      need(f, n, Enum.count(around(n, 1), &Goals.goal?(f, &1)))
    end)
  end

  # `n`'s need changes by `delta`; when it starts or stops, the need of every
  # earlier decoration it waits for goes up or down by one. One no longer
  # needed and not running gives its number up.
  defp need(f, _n, 0), do: f

  defp need(f, n, delta) do
    case f.deps do
      %{^n => %{need: need} = deps} ->
        f = check(%{f | deps: Map.put(f.deps, n, %{deps | need: need + delta})}, n)

        cond do
          need == 0 and delta > 0 ->
            starts(f, deps, 1)

          need > 0 and need + delta == 0 ->
            f = starts(f, deps, -1)
            if running?(f, n), do: f, else: free(f, n)

          true ->
            f
        end

      _ ->
        f
    end
  end

  # A decoration's need started (1) or stopped (-1): so does the need of the
  # earlier ones it waits for and of the terrain it lacks.
  defp starts(f, deps, delta),
    do: Enum.reduce(deps.waits, lacks(f, deps.lacking, delta), &need(&2, &1, delta))

  defp lacks(f, chunks, delta) do
    terrain =
      Enum.reduce(chunks, f.terrain, fn c, terrain ->
        case Map.get(terrain, c, 0) + delta do
          0 -> Map.delete(terrain, c)
          n -> Map.put(terrain, c, n)
        end
      end)

    %{f | terrain: terrain}
  end

  @doc "Whether `n` is a numbered decoration some goal needs."
  def needed?(f, n), do: match?(%{^n => %{need: need}} when need > 0, f.deps)

  @doc "`n` in `ready` if it is needed, waits for nothing and is not running."
  def check(f, n) do
    ready =
      case f.deps do
        %{^n => %{waits: [], lacking: [], need: need}} when need > 0 ->
          if running?(f, n), do: MapSet.delete(f.ready, n), else: MapSet.put(f.ready, n)

        _ ->
          MapSet.delete(f.ready, n)
      end

    %{f | ready: ready}
  end

  defp running?(f, n) do
    case f.busy do
      %{^n => ref} -> match?(%{kind: :decorate, chunk: ^n}, f.jobs[ref])
      _ -> false
    end
  end

  ## Results

  @doc "`chunk` got its terrain (or lost it, `made: false`, when dropped)."
  def made(f, chunk, made \\ true) do
    around(chunk, 1)
    |> Enum.filter(&Map.has_key?(f.deps, &1))
    |> Enum.reduce(f, fn n, f ->
      deps = f.deps[n]
      lacked = chunk in deps.lacking
      lacking = if made, do: List.delete(deps.lacking, chunk), else: [chunk | deps.lacking]

      f =
        cond do
          deps.need == 0 or lacked != made -> f
          made -> lacks(f, [chunk], -1)
          true -> lacks(f, [chunk], 1)
        end

      if lacked != made,
        do: f,
        else: check(%{f | deps: Map.put(f.deps, n, %{deps | lacking: lacking})}, n)
    end)
  end

  @doc "`n`'s decoration ran: its number goes, and the finals within 1 are checked."
  def decorated(f, n), do: Enum.reduce(around(n, 1), free(f, n), &check_final(&2, &1))

  @doc """
  `n`'s number goes (decorated, unneeded or blocked): it no longer needs what
  it waited for, and the decorations within 2 waiting for it are checked again.
  """
  def free(f, n) do
    case Map.pop(f.deps, n) do
      {nil, _} ->
        f

      {deps, rest} ->
        f = %{f | deps: rest, seqs: Map.delete(f.seqs, n), ready: MapSet.delete(f.ready, n)}
        f = if deps.need > 0, do: starts(f, deps, -1), else: f

        for m <- around(n, 2), f.serial, Map.has_key?(f.deps, m), reduce: f do
          f ->
            deps = f.deps[m]
            check(%{f | deps: Map.put(f.deps, m, %{deps | waits: List.delete(deps.waits, n)})}, m)
        end
    end
  end

  @doc """
  `chunk` is frozen (handed over or failed): the decorations whose 3 × 3
  holds it can no longer run, so their numbers go, and the goals that needed
  them are made alone. A chunk handed over with its 3 × 3 decorated blocks
  nothing: only itself, if wanted again, is made alone.
  """
  def freeze(%Frontier{final_after_terrain: true} = f, _chunk), do: f

  def freeze(f, chunk) do
    blocked = for n <- around(chunk, 1), not decorated?(f, n), do: n
    near = if blocked == [], do: [chunk], else: around(chunk, 2)
    f = Enum.reduce(blocked, f, &free(&2, &1))
    find_alone(f, Enum.filter(near, &Goals.goal?(f, &1)))
  end

  @doc "A goal now final goes to `finals`."
  def check_final(f, chunk) do
    if Goals.goal?(f, chunk) and final?(f, chunk) and not handed?(f, chunk),
      do: %{f | finals: MapSet.put(f.finals, chunk)},
      else: f
  end

  defp find_alone(%Frontier{final_after_terrain: true} = f, _chunks), do: f

  defp find_alone(f, chunks),
    do: %{f | alone: for(c <- chunks, alone?(f, c), into: f.alone, do: c)}

  @doc "Each numbered decoration's waits and lacking cells again (a restored snapshot)."
  def rebuild(f) do
    deps =
      Map.new(f.seqs, fn {n, seq} ->
        waits =
          for m <- around(n, 2), f.serial, s = f.seqs[m], s != nil and s < seq, do: m

        {n, %{waits: waits, lacking: Enum.reject(around(n, 1), &cell?(f, &1)), need: 0}}
      end)

    %{f | deps: deps}
  end

  ## Resolution

  @doc """
  The work the goals need, in goal order: up to `d` needed decorations that can
  start (none of their chunks held) and up to `t` chunks of terrain
  (`{decorations, terrain, more}`; `more` when work that could start was left
  out for want of room). Each comes as `{order, chunk}`: the goal it was found
  for (`{0, rank, z, x}`, as the goals are ordered), or `{1, …}` for other
  needed work, so jobs of every kind can start nearest goal first (VMC-081c).
  The walk goes through each goal's decorations, transitively the earlier
  ones they wait for (the earliest first), and the terrain those lack, each
  once; it stops as soon as each kind fills its room or all of it that can
  start was found, or after `@budget` steps. Room it leaves goes to the other
  needed work.
  """
  # Flat worlds: the goals not held; worlds final after terrain: their terrain.
  def resolve(%Frontier{final_after_terrain: true} = f, d, t) do
    {keep, n} =
      if f.kind == :flat,
        do: {&(not Map.has_key?(f.busy, &1)), d},
        else: {&needs_terrain?(f, &1), t}

    chunks = take(:gb_sets.iterator(f.goals), n + 1, keep, [])
    {[], Enum.take(chunks, n), length(chunks) > n}
  end

  def resolve(f, d, t) do
    held = Enum.count(f.busy, fn {c, _} -> Map.has_key?(f.terrain, c) end)

    walk = %{
      seen: %{},
      goal: nil,
      budget: @budget,
      decorations: [],
      d: d,
      found: 0,
      ready: MapSet.size(f.ready),
      terrain: [],
      t: t,
      taken: 0,
      lacking: map_size(f.terrain) - held
    }

    walk = goals_in_order(:gb_sets.iterator(f.goals), f, walk)

    decorations =
      f.ready
      |> Enum.reject(&(is_map_key(walk.seen, &1) or held?(f, &1)))
      |> Enum.sort_by(&f.seqs[&1])
      |> Enum.take(walk.d)
      |> Enum.map(&{{1, f.seqs[&1], 0, 0}, &1})

    terrain =
      other_terrain(:maps.next(:maps.iterator(f.terrain)), f, walk, walk.t, [])
      |> Enum.map(&{{2, 0, 0, 0}, &1})

    decorations = Enum.reverse(walk.decorations, decorations)
    terrain = Enum.reverse(walk.terrain, terrain)

    more =
      (length(decorations) == d and walk.ready > d) or (length(terrain) == t and walk.lacking > t)

    {decorations, terrain, more}
  end

  defp held?(f, n), do: Enum.any?(around(n, 1), &Map.has_key?(f.busy, &1))

  # Up to `t` needed terrain chunks the walk did not take, none held.
  defp other_terrain(:none, _f, _walk, _t, acc), do: acc
  defp other_terrain(_next, _f, _walk, 0, acc), do: acc

  defp other_terrain({c, _, next}, f, walk, t, acc) do
    if is_map_key(walk.seen, {:terrain, c}) or Map.has_key?(f.busy, c),
      do: other_terrain(:maps.next(next), f, walk, t, acc),
      else: other_terrain(:maps.next(next), f, walk, t - 1, [c | acc])
  end

  # Up to `n` goals that pass `keep`, in goal order, with their order.
  defp take(_goals, 0, _keep, acc), do: Enum.reverse(acc)

  defp take(goals, n, keep, acc) do
    case :gb_sets.next(goals) do
      :none ->
        Enum.reverse(acc)

      {{r, z, x, g}, goals} ->
        if keep.(g),
          do: take(goals, n - 1, keep, [{{0, r, z, x}, g} | acc]),
          else: take(goals, n, keep, acc)
    end
  end

  defp enough?(walk) do
    walk.budget <= 0 or
      ((walk.d == 0 or walk.found >= walk.ready) and (walk.t == 0 or walk.taken >= walk.lacking))
  end

  defp goals_in_order(goals, f, walk) do
    if enough?(walk) do
      walk
    else
      case :gb_sets.next(goals) do
        :none ->
          walk

        {{r, z, x, g}, goals} ->
          walk = %{walk | budget: walk.budget - 1, goal: {0, r, z, x}}
          walk = Enum.reduce(around(g, 1), walk, &visit(f, &1, &2))
          goals_in_order(goals, f, walk)
      end
    end
  end

  defp visit(f, n, walk) do
    case f.deps do
      %{^n => deps} when not is_map_key(walk.seen, n) ->
        if enough?(walk) do
          walk
        else
          walk = %{walk | seen: Map.put(walk.seen, n, true), budget: walk.budget - 1}

          if MapSet.member?(f.ready, n) do
            walk = %{walk | found: walk.found + 1}

            if walk.d > 0 and not held?(f, n),
              do: %{walk | decorations: [{walk.goal, n} | walk.decorations], d: walk.d - 1},
              else: walk
          else
            # The earliest first: a chain advances from its first decoration.
            walk = Enum.reduce(deps.waits, walk, &visit(f, &1, &2))
            Enum.reduce(deps.lacking, walk, &terrain(f, &1, &2))
          end
        end

      _ ->
        walk
    end
  end

  defp terrain(f, c, walk) do
    key = {:terrain, c}

    if walk.t > 0 and not is_map_key(walk.seen, key) and not Map.has_key?(f.busy, c) and
         not Map.has_key?(f.failed, c),
       do: %{
         walk
         | seen: Map.put(walk.seen, key, true),
           terrain: [{walk.goal, c} | walk.terrain],
           t: walk.t - 1,
           taken: walk.taken + 1
       },
       else: walk
  end
end
