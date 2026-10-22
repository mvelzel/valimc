defmodule Valimc.Worldgen.Frontier do
  @moduledoc """
  The generation state of one dimension (VMC-077n), as data:
  `Valimc.Worldgen.Scheduler` runs it on the generation pool, and spawn search
  runs it inline at world creation.

  A chunk is absent, then `:terrain` (it has a proto chunk, a native cell),
  then `:decorated` (its own decoration ran over its 3 × 3), and final once its
  whole 3 × 3 is decorated; a final chunk is made full for whoever wants it and
  becomes `:handed` (its cell dropped) once its region has persisted it. A
  handed chunk's entry goes once its 3 × 3 is handed too. In a world generated
  before decoration a chunk is final once it has terrain; a flat-layer world's
  chunks are full at once.

  Decorating a chunk reads and writes its 3 × 3, so two decorations conflict
  within distance 2. A chunk gets a decoration number when some request first
  needs it (a request's chunks within 1, Z outer and X inner), and starts only
  once its 3 × 3 has terrain, no job holds any of those chunks, and no
  conflicting chunk with a smaller number is still undecorated: decorations
  that touch run in number order, so chunks depend only on the order of
  requests. Everything else runs in parallel.

  Wants carry a priority per chunk (smaller first: the squared distance to the
  player that wants it, -1 for calls that wait). Players also tell the
  scheduler which chunk they are in and which way they move (`focus/4`,
  VMC-077u), straight from their connection rather than through the regions'
  tickets, which arrive later. While any player is in the dimension, a wanted
  chunk's priority is its score from the nearest player: their own chunk
  first, then the chunks ahead of them before those beside and behind; calls
  that wait stay first. The work a wanted chunk needs inherits its priority,
  including the earlier decorations it waits for. Work waits in priority
  queues that a job's result updates around its chunk. A want or a focus
  looks only at the chunks whose priority changed (VMC-077x): a priority that
  went down passes at once to the work its chunk needs, and the queues are
  rebuilt whole (`refresh/1`, which the caller paces) for those that went up
  or away. `next/3` returns the jobs that can start (final chunks, then
  decorations, then terrain), as closures for the caller to run, and
  `done/3` takes their results. Nothing here polls or answers
  busy: what cannot start yet is simply not returned until what it waits for
  is done.

  A chunk wanted again after it was handed over (its region lost it), or one
  that needs a decoration that can no longer run (a neighbour is handed over
  or failed), is made alone, as vanilla makes a chunk missing from its region
  file: over fresh terrain of its 3 × 3, with only its own decoration.

  Proto cells in memory are bounded (VMC-077q): past `cap`, the cells no
  wanted chunk or needed decoration is near go, least recently used first
  (`evictions/2`). Terrain no decoration wrote into is dropped and made
  again when needed (terrain reads only the starts' beards, which placement
  never changes, so it comes out the same). Any other cell spills: the
  caller writes its encoding to a scratch file that is never durable state
  (`spilled/2`), and a job that needs it decodes it there and hands it back.
  A decoration cannot be made again exactly without replaying, in number
  order, every earlier decoration within 2 of it, transitively; a spilled
  cell is the chunk itself.
  """
  alias Valimc.Native
  alias Valimc.World.Blocks
  alias Valimc.Worldgen.Generator

  defstruct [
    :kind,
    :worldgen,
    :source,
    :starts,
    :flat,
    # Final once it has terrain (a noise world generated before decoration).
    final_after_terrain: false,
    sky: true,
    chunks: %{},
    seqs: %{},
    next_seq: 0,
    wants: %{},
    # Per wanted chunk, who wants it at which priority.
    index: %{},
    # Where players are and which way they move (`focus/4`): while any
    # player is here, it sets the priorities.
    focus: %{},
    # Each wanted chunk's priority and each numbered decoration's (inherited
    # from the wanted chunks and the later decorations that wait for it):
    # lowered where wants change, rebuilt by `refresh/1` (`stale` until then).
    stale: false,
    priority: %{},
    needs: %{},
    busy: %{},
    jobs: %{},
    delivered: MapSet.new(),
    # Work by priority: wanted final chunks (`{priority, chunk}`), wanted
    # chunks to make alone, decorations that can run (`{priority, seq,
    # chunk}`), and terrain needed (`{priority, z, x, chunk}`; in a flat
    # world, the wanted chunks).
    finals: :gb_sets.new(),
    alone: MapSet.new(),
    ready: :gb_sets.new(),
    queue: :gb_sets.new(),
    # Chunks whose generation failed (frozen), and wanted chunks given up.
    failed: %{},
    given_up: MapSet.new(),
    attempts: %{},
    # The numbered chunks in order, newest first, when recorded (checks).
    log: nil,
    # Proto cells in memory, the most kept (nil: no bound), a use clock for
    # least-recently-used eviction, the scratch file spilled cells are read
    # back from, and counts of cells dropped and spilled (VMC-077q).
    cap: nil,
    in_memory: 0,
    clock: 0,
    scratch: nil,
    dropped: 0,
    spills: 0
  ]

  # A job whose worker dies is tried again this often, then fails.
  @max_attempts 3
  # A player's focus reorders the wanted chunks this near it at once, and
  # priorities under `@urgent` (theirs, and calls that wait) pass down the
  # decoration chain at once.
  @near 4
  @urgent 4 * @near * @near

  @doc """
  The generation of `spec` (a `Generator.spec_of/2` spec of a dimension).
  Options: `decorated` (false: chunks are final after terrain), `sky` (the
  dimension has sky light, stored in full chunks' images) and `log` (record
  the decoration order).
  """
  def new(spec, opts \\ []) do
    decorated = Keyword.get(opts, :decorated, true)
    sky = Keyword.get(opts, :sky, true)
    log = if Keyword.get(opts, :log, false), do: []

    case spec do
      %{kind: :noise} ->
        {:ok, worldgen} = Generator.worldgen(spec.seed, spec.noise_settings, spec.facts)
        structures = decorated and Map.get(spec, :structures, false)

        %__MODULE__{
          kind: :noise,
          worldgen: worldgen,
          source: spec.biome_source,
          starts: if(structures, do: Native.gen_starts_new()),
          final_after_terrain: not decorated,
          sky: sky,
          log: log
        }

      %{kind: :flat} ->
        %__MODULE__{kind: :flat, flat: spec, final_after_terrain: true, sky: sky}
    end
  end

  ## Requests

  @doc """
  `requester` wants `wanted` (`chunk => priority`) made full, replacing what
  it wanted; an empty map withdraws. A chunk it newly wants that was already
  sent is sent again (it lost it). Only the chunks whose wants changed are
  looked at (VMC-077x): a priority that went down reaches the work its chunk
  needs at once, one that went up or away waits for `refresh/1`.
  """
  def want(%__MODULE__{} = f, requester, wanted) when is_map(wanted) do
    before = Map.get(f.wants, requester, %{})

    wants =
      if wanted == %{},
        do: Map.delete(f.wants, requester),
        else: Map.put(f.wants, requester, wanted)

    added = for {c, _} <- wanted, not Map.has_key?(before, c), do: c
    removed = for {c, _} <- before, not Map.has_key?(wanted, c), do: c
    changed = for {c, p} <- wanted, Map.get(before, c, p) != p, do: c

    index =
      Enum.reduce(removed, f.index, fn c, index ->
        case Map.delete(Map.get(index, c, %{}), requester) do
          by when by == %{} -> Map.delete(index, c)
          by -> Map.put(index, c, by)
        end
      end)

    index =
      Enum.reduce(added ++ changed, index, fn c, index ->
        Map.update(index, c, %{requester => wanted[c]}, &Map.put(&1, requester, wanted[c]))
      end)

    f = %{
      f
      | wants: wants,
        index: index,
        delivered: Enum.reduce(added, f.delivered, &MapSet.delete(&2, &1))
    }

    f
    |> number(added)
    |> find_alone(added)
    |> reprioritize(added ++ changed ++ removed)
  end

  @doc """
  Player `holder` is in `chunk`, moving along `heading` (`{x, z}` of unit
  length, or nil when it stands or jumped); a nil chunk forgets it. The
  wanted chunks near it take their new priorities at once, the others at the
  next `refresh/1`.
  """
  def focus(%__MODULE__{} = f, holder, nil, _heading) do
    if Map.has_key?(f.focus, holder),
      do: %{f | focus: Map.delete(f.focus, holder), stale: true},
      else: f
  end

  def focus(%__MODULE__{} = f, holder, {_, _} = chunk, heading) do
    f = %{f | focus: Map.put(f.focus, holder, {chunk, heading}), stale: true}
    near = for c <- around(chunk, @near), Map.has_key?(f.index, c), do: c
    reprioritize(f, near)
  end

  # The wanted chunks among `chunks` at their priorities as they are now:
  # lower ones pass to the work they need, most urgent first (the chains of
  # earlier decorations overlap, and each is walked once at its smallest
  # priority), and the rest wait for a refresh.
  defp reprioritize(f, chunks) do
    {f, lowered} =
      Enum.reduce(chunks, {f, []}, fn c, {f, lowered} ->
        case {effective(f, c), Map.get(f.priority, c)} do
          {same, same} ->
            {f, lowered}

          {nil, _} ->
            {%{f | priority: Map.delete(f.priority, c), stale: true}, lowered}

          {p, old} when old == nil or p < old ->
            {%{f | priority: Map.put(f.priority, c, p)}, [{p, c} | lowered]}

          {p, _} ->
            {%{f | priority: Map.put(f.priority, c, p), stale: true}, lowered}
        end
      end)

    lowered |> Enum.sort() |> Enum.reduce(f, fn {p, c}, f -> lower(f, c, p) end)
  end

  # A wanted chunk's priority: the smallest any requester gives it, or with a
  # player focused its score from the nearest (calls that wait stay first).
  defp effective(f, chunk) do
    case f.index do
      %{^chunk => by} ->
        p = by |> Map.values() |> Enum.min()

        cond do
          MapSet.member?(f.given_up, chunk) -> nil
          p < 0 or f.focus == %{} -> p
          true -> f.focus |> Map.values() |> Enum.map(&score(chunk, &1)) |> Enum.min()
        end

      _ ->
        nil
    end
  end

  # `chunk`'s priority went down to `p`: so does the work it needs.
  defp lower(%{kind: :flat} = f, {x, z} = c, p) do
    if Map.has_key?(f.busy, c) or MapSet.member?(f.delivered, c),
      do: f,
      else: %{f | queue: :gb_sets.add({p, z, x, c}, f.queue)}
  end

  defp lower(%{final_after_terrain: true} = f, {x, z} = c, p) do
    f = check_final(f, c)
    if needs_terrain?(f, c), do: %{f | queue: :gb_sets.add({p, z, x, c}, f.queue)}, else: f
  end

  # The chain of earlier decorations a chunk far from every player waits for
  # spans the undecorated band between them: its priority reaches it at the
  # next refresh, an urgent one at once.
  defp lower(f, c, p) when p < @urgent do
    f = check_final(f, c)
    around(c, 1) |> Enum.filter(&Map.has_key?(f.seqs, &1)) |> lower_needs(p, f)
  end

  defp lower(f, c, _p), do: %{check_final(f, c) | stale: true}

  # Numbered decorations needed at `p`, and the earlier ones they wait for:
  # each that was needed later goes into the queues at `p`. An entry left at
  # its old priority starts no second job: what it names is held, then done.
  defp lower_needs([], _p, f), do: f

  defp lower_needs([n | rest], p, f) do
    case f.needs do
      %{^n => q} when q <= p ->
        lower_needs(rest, p, f)

      _ ->
        seq = Map.fetch!(f.seqs, n)
        earlier = earlier(f, n, seq)
        f = %{f | needs: Map.put(f.needs, n, p)}

        f =
          if earlier == [] and ready?(f, n, seq),
            do: %{f | ready: :gb_sets.add({p, seq, n}, f.ready)},
            else: f

        queue =
          for {x, z} = c <- around(n, 1), needs_terrain?(f, c), reduce: f.queue do
            queue -> :gb_sets.add({p, z, x, c}, queue)
          end

        lower_needs(earlier ++ rest, p, %{f | queue: queue})
    end
  end

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

  @doc """
  Where a finished chunk goes in its delivery (VMC-077w): its score from the
  nearest focused player, smaller first; 0 when no player is focused.
  """
  def rank(%__MODULE__{focus: focus}, _chunk) when focus == %{}, do: 0

  def rank(%__MODULE__{focus: focus}, chunk),
    do: focus |> Map.values() |> Enum.map(&score(chunk, &1)) |> Enum.min()

  defp within(chunks, r), do: chunks |> Enum.flat_map(&around(&1, r)) |> Enum.uniq()

  # Decoration numbers for the undecorated chunks within 1 of `added` that have
  # none, Z outer and X inner.
  defp number(%__MODULE__{final_after_terrain: true} = f, _added), do: f

  defp number(f, added) do
    added
    |> within(1)
    |> Enum.reject(&(decorated?(f, &1) or Map.has_key?(f.seqs, &1) or blocked?(f, &1)))
    |> Enum.sort_by(fn {x, z} -> {z, x} end)
    |> Enum.reduce(f, fn chunk, f ->
      log = if f.log, do: [chunk | f.log]
      %{f | seqs: Map.put(f.seqs, chunk, f.next_seq), next_seq: f.next_seq + 1, log: log}
    end)
  end

  @doc """
  The priorities and queues of the wants as they are now, rebuilt whole when
  any went up or away since (`stale`). Its cost grows with every wanted chunk
  and numbered decoration, so the scheduler does it at most a few times a
  second (VMC-077x); until then that work is only done earlier than needed.
  """
  def refresh(%__MODULE__{stale: false} = f), do: f

  def refresh(%__MODULE__{} = f) do
    priority = for {c, _} <- f.index, p = effective(f, c), p != nil, into: %{}, do: {c, p}
    f = %{f | priority: priority, stale: false}
    needs = needs(f)
    f = %{f | needs: needs}

    ready =
      for {n, seq} <- f.seqs, p = needs[n], p != nil, ready?(f, n, seq), do: {p, seq, n}

    finals = for {chunk, p} <- priority, final_ready?(f, chunk), do: {p, chunk}

    %{
      f
      | ready: :gb_sets.from_list(ready),
        finals: :gb_sets.from_list(finals),
        queue: :gb_sets.from_list(queue(f)),
        alone: MapSet.filter(f.alone, &Map.has_key?(priority, &1))
    }
  end

  # Each numbered decoration's priority: the smallest of the wanted chunks
  # it writes into and of the later decorations within 2 (which wait for it),
  # so the work a wanted chunk waits on inherits its priority.
  defp needs(%{final_after_terrain: true}), do: %{}

  defp needs(f) do
    f.seqs
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.reduce(%{}, fn {n, _seq}, needs ->
      own = for c <- around(n, 1), p = f.priority[c], p != nil, do: p
      # Later decorations only: in this order the earlier ones have none yet.
      waiting = for m <- around(n, 2), p = needs[m], p != nil, do: p

      case own ++ waiting do
        [] -> needs
        list -> Map.put(needs, n, Enum.min(list))
      end
    end)
  end

  # The terrain needed now: the 3 × 3 of every needed decoration, else the
  # wanted chunks themselves.
  defp queue(%{kind: :flat} = f),
    do: for({{x, z} = c, p} <- f.priority, not Map.has_key?(f.busy, c), do: {p, z, x, c})

  defp queue(%{final_after_terrain: true} = f),
    do: for({{x, z} = c, p} <- f.priority, needs_terrain?(f, c), do: {p, z, x, c})

  defp queue(f) do
    f.needs
    |> Enum.reduce(%{}, fn {n, p}, acc ->
      Enum.reduce(around(n, 1), acc, fn c, acc ->
        if needs_terrain?(f, c), do: Map.update(acc, c, p, &min(&1, p)), else: acc
      end)
    end)
    |> Enum.map(fn {{x, z} = c, p} -> {p, z, x, c} end)
  end

  defp needs_terrain?(f, c),
    do: status(f, c) == nil and not Map.has_key?(f.busy, c) and not Map.has_key?(f.failed, c)

  # Chunks among `chunks` (wanted ones) that must be made alone.
  defp find_alone(%{final_after_terrain: true} = f, _chunks), do: f

  defp find_alone(f, chunks) do
    %{f | alone: for(c <- chunks, alone?(f, c), into: f.alone, do: c)}
  end

  @doc "Who wants `chunk`."
  def wanting(%__MODULE__{wants: wants}, chunk),
    do: for({requester, wanted} <- wants, Map.has_key?(wanted, chunk), do: requester)

  @doc "The numbered chunks in decoration-number order, when recorded."
  def order(%__MODULE__{log: log}), do: if(log, do: Enum.reverse(log))

  @doc """
  The regions persisted these full chunks: their cells go, and the entries of
  handed chunks whose 3 × 3 is handed too.
  """
  def handed_over(%__MODULE__{} = f, chunks), do: hand(f, chunks, false)

  @doc """
  These chunks are full in their region (it loaded them): handed over as far
  as generation is concerned, so a neighbour wanted later knows them.
  """
  def present(%__MODULE__{} = f, chunks), do: hand(f, chunks, true)

  # Chunks final after terrain need no record: a lost one is made again.
  defp hand(%{final_after_terrain: true} = f, chunks, _present) do
    chunks = Enum.reject(chunks, &Map.has_key?(f.busy, &1))
    held = Enum.count(chunks, &in_memory?(f, &1))

    %{
      f
      | chunks: Map.drop(f.chunks, chunks),
        in_memory: f.in_memory - held,
        delivered: Enum.reduce(chunks, f.delivered, &MapSet.delete(&2, &1))
    }
  end

  defp hand(f, chunks, present) do
    f =
      Enum.reduce(chunks, f, fn chunk, f ->
        status = status(f, chunk)

        handed =
          cond do
            # A running decoration writes into it (only a region's own report).
            busy_decorating?(f, chunk) -> false
            status == :handed -> false
            present -> true
            true -> final?(f, chunk) or MapSet.member?(f.delivered, chunk)
          end

        if handed,
          do:
            freeze(
              %{
                f
                | chunks: Map.put(f.chunks, chunk, %{status: :handed, cell: nil}),
                  in_memory: f.in_memory - if(in_memory?(f, chunk), do: 1, else: 0),
                  delivered: MapSet.delete(f.delivered, chunk)
              },
              chunk
            ),
          else: %{f | delivered: MapSet.delete(f.delivered, chunk)}
      end)

    chunks
    |> Enum.flat_map(&around(&1, 1))
    |> Enum.uniq()
    |> Enum.filter(fn chunk -> Enum.all?(around(chunk, 1), &handed?(f, &1)) end)
    |> then(&%{f | chunks: Map.drop(f.chunks, &1)})
  end

  # `chunk` is frozen (handed over or failed): the decorations whose 3 × 3
  # holds it can no longer run, so they lose their numbers and nothing waits
  # for them (the chunks that need them are made alone).
  # A chunk handed over with its 3 × 3 decorated blocks nothing: only itself,
  # if wanted again, is made alone.
  defp freeze(f, chunk) do
    blocked = for n <- around(chunk, 1), not decorated?(f, n), do: n
    near = if blocked == [], do: [chunk], else: around(chunk, 2)
    wanted = for c <- near, Map.has_key?(f.priority, c), do: c
    find_alone(%{f | seqs: Map.drop(f.seqs, blocked)}, wanted)
  end

  defp busy_decorating?(f, chunk) do
    case f.busy do
      %{^chunk => ref} -> f.jobs[ref].kind == :decorate
      _ -> false
    end
  end

  ## Statuses

  defp status(f, chunk) do
    case f.chunks do
      %{^chunk => %{status: status}} -> status
      _ -> nil
    end
  end

  defp handed?(f, chunk), do: status(f, chunk) == :handed

  defp in_memory?(f, chunk) do
    case f.chunks do
      %{^chunk => %{cell: cell}} -> is_reference(cell)
      _ -> false
    end
  end

  defp decorated?(f, chunk), do: status(f, chunk) in [:decorated, :handed]
  defp cell?(f, chunk), do: status(f, chunk) in [:terrain, :decorated]
  defp frozen?(f, chunk), do: handed?(f, chunk) or Map.has_key?(f.failed, chunk)

  defp final?(%{final_after_terrain: true} = f, chunk), do: cell?(f, chunk)
  defp final?(f, chunk), do: Enum.all?(around(chunk, 1), &decorated?(f, &1))

  # An undecorated chunk whose decoration cannot run: its 3 × 3 holds a chunk
  # handed over (its region has it full) or failed.
  defp blocked?(f, n), do: not decorated?(f, n) and Enum.any?(around(n, 1), &frozen?(f, &1))

  # Made alone: lost after it was handed over, or needing a blocked decoration
  # (only possible with a frozen chunk within 2, the cheaper test first).
  defp alone?(f, chunk) do
    handed?(f, chunk) or
      (Enum.any?(around(chunk, 2), &frozen?(f, &1)) and
         Enum.any?(around(chunk, 1), &blocked?(f, &1)))
  end

  @doc "The chunks within `r` of `chunk`, Z outer and X inner."
  def around({x, z}, r), do: for(dz <- -r..r, dx <- -r..r, do: {x + dx, z + dz})

  ## Jobs

  @doc """
  Up to `capacity` jobs that can start now, at most `bulk` of them terrain,
  most urgent first: `%{ref, kind, chunk, bulk, run}`, `run` a closure for the
  caller to run (anywhere) and report with `done/3`, or give back with
  `cancel/2`.
  """
  def next(f, capacity, bulk \\ nil)

  def next(%__MODULE__{} = f, capacity, bulk) when capacity > 0 do
    # Final chunks first (players wait for them), then the decorations every
    # final chunk waits on, then terrain.
    {jobs, f, _} =
      {[], f, {capacity, bulk || capacity, capacity - (bulk || capacity)}}
      |> take(:finals)
      |> take(:alone)
      |> take(:ready)
      |> take(:queue)

    {Enum.reverse(jobs), f}
  end

  def next(%__MODULE__{} = f, _capacity, _bulk), do: {[], f}

  # Start the entries of a queue that can start, most urgent first, as far
  # as there is room; entries no longer needed go.
  defp take({jobs, f, {0, _, _}} = acc, _queue) when is_list(jobs) and is_map(f), do: acc

  defp take({jobs, f, room}, :alone) do
    f.alone
    |> Enum.sort_by(&{Map.get(f.priority, &1), elem(&1, 1), elem(&1, 0)})
    |> Enum.reduce({jobs, f, room}, fn chunk, acc ->
      if still(elem(acc, 1), :alone, chunk),
        do: claim(acc, {:alone, chunk}, nil),
        else: acc
    end)
  end

  defp take({jobs, f, room}, queue) do
    take_from(:gb_sets.iterator(Map.fetch!(f, queue)), queue, {jobs, f, room})
  end

  defp take_from(_iterator, _queue, {_, _, {0, _, _}} = acc), do: acc

  defp take_from(_iterator, :queue, {_, %{kind: kind}, {_, 0, _}} = acc) when kind != :flat,
    do: acc

  defp take_from(iterator, queue, {jobs, f, room} = acc) do
    case :gb_sets.next(iterator) do
      :none ->
        acc

      {entry, iterator} ->
        case still(f, queue, entry) do
          nil ->
            f = Map.update!(f, queue, &:gb_sets.delete(entry, &1))
            take_from(iterator, queue, {jobs, f, room})

          candidate ->
            {jobs2, f2, room2} = claim(acc, candidate, {queue, entry})

            # Started: off the queue; held by a job meanwhile: stays.
            f2 =
              if room2 != room,
                do: Map.update!(f2, queue, &:gb_sets.delete(entry, &1)),
                else: f2

            take_from(iterator, queue, {jobs2, f2, room2})
        end
    end
  end

  defp still(f, :finals, {_, chunk}), do: if(final_ready?(f, chunk), do: {:full, chunk})

  defp still(f, :ready, {_, seq, n}),
    do: if(Map.get(f.seqs, n) == seq and ready?(f, n, seq), do: {:decorate, n})

  defp still(%{kind: :flat} = f, :queue, {_, _, _, c}) do
    if Map.has_key?(f.priority, c) and not MapSet.member?(f.delivered, c),
      do: {:flat, c}
  end

  # Terrain only while work still needs it: an entry can outlive its need, and
  # a chunk handed over with its 3 × 3 has no status left.
  defp still(%{final_after_terrain: true} = f, :queue, {_, _, _, c}) do
    if needs_terrain?(f, c) and Map.has_key?(f.priority, c) and
         not MapSet.member?(f.delivered, c),
       do: {:terrain, c}
  end

  defp still(f, :queue, {_, _, _, c}) do
    if needs_terrain?(f, c) and
         Enum.any?(around(c, 1), &(Map.has_key?(f.seqs, &1) and Map.has_key?(f.needs, &1))),
       do: {:terrain, c}
  end

  defp still(f, :alone, c) do
    Map.has_key?(f.priority, c) and not MapSet.member?(f.delivered, c) and
      not Map.has_key?(f.busy, c) and alone?(f, c)
  end

  # A decoration that can start now (but for jobs holding its chunks).
  defp ready?(f, n, seq) do
    not decorated?(f, n) and not Map.has_key?(f.failed, n) and
      Enum.all?(around(n, 1), &cell?(f, &1)) and earlier(f, n, seq) == []
  end

  defp check_ready(f, n) do
    with %{^n => seq} <- f.seqs,
         %{^n => p} <- f.needs,
         true <- ready?(f, n, seq) do
      %{f | ready: :gb_sets.add({p, seq, n}, f.ready)}
    else
      _ -> f
    end
  end

  defp final_ready?(f, chunk) do
    Map.has_key?(f.priority, chunk) and final?(f, chunk) and not handed?(f, chunk) and
      not MapSet.member?(f.delivered, chunk)
  end

  defp check_final(%{kind: :flat} = f, _chunk), do: f

  defp check_final(f, chunk) do
    if final_ready?(f, chunk),
      do: %{f | finals: :gb_sets.add({f.priority[chunk], chunk}, f.finals)},
      else: f
  end

  # The chunks within 2 of `n` numbered before it, which it waits for (a
  # number goes once its chunk is decorated or blocked).
  defp earlier(f, n, seq) do
    for m <- around(n, 2), m != n, s = Map.get(f.seqs, m), s != nil and s < seq, do: m
  end

  # Room is `{jobs, terrain jobs, slots terrain leaves}`: as on the pool,
  # terrain never takes the last slots, whatever took the others.
  defp claim({jobs, f, {0, _, _} = room}, _candidate, _origin), do: {jobs, f, room}
  defp claim({jobs, f, {_, 0, _} = room}, {:terrain, _}, _origin), do: {jobs, f, room}

  defp claim({jobs, f, {capacity, bulk, gap} = room}, {kind, _} = candidate, origin) do
    case start(f, candidate, origin) do
      {nil, f} ->
        {jobs, f, room}

      {job, f} ->
        bulk = if kind == :terrain, do: bulk - 1, else: bulk
        {[job | jobs], f, {capacity - 1, max(min(bulk, capacity - 1 - gap), 0), gap}}
    end
  end

  # Claim what a job holds and build it; `{nil, f}` when it cannot start.
  defp start(f, {kind, chunk}, origin) do
    holds = if kind == :decorate, do: around(chunk, 1), else: [chunk]

    if Enum.any?(holds, &Map.has_key?(f.busy, &1)) do
      {nil, f}
    else
      ref = make_ref()

      job = %{
        ref: ref,
        kind: kind,
        chunk: chunk,
        holds: holds,
        bulk: kind == :terrain,
        origin: origin
      }

      busy = Enum.reduce(holds, f.busy, &Map.put(&2, &1, ref))
      clock = f.clock + 1
      chunks = Enum.reduce(holds, f.chunks, &touch(&2, &1, clock))
      f = %{f | busy: busy, jobs: Map.put(f.jobs, ref, job), chunks: chunks, clock: clock}
      {Map.put(job, :run, runner(f, job)), f}
    end
  end

  defp touch(chunks, chunk, clock) do
    case chunks do
      %{^chunk => entry} -> Map.put(chunks, chunk, Map.put(entry, :used, clock))
      _ -> chunks
    end
  end

  @doc "Give back a job `next/3` returned that did not start."
  def cancel(%__MODULE__{} = f, ref) do
    case Map.pop(f.jobs, ref) do
      {nil, _} ->
        f

      {job, jobs} ->
        f = %{f | jobs: jobs, busy: Map.drop(f.busy, job.holds)}

        # Back into its queue (an alone chunk stays in its set until sent).
        case job.origin do
          {queue, entry} -> Map.update!(f, queue, &:gb_sets.add(entry, &1))
          nil -> f
        end
    end
  end

  defp runner(f, %{kind: :terrain, chunk: {x, z}}) do
    {worldgen, source, starts} = {f.worldgen, f.source, f.starts}
    fn -> Native.gen_terrain(worldgen, source, starts, x, z) end
  end

  # Spilled cells come back with the decoration's result.
  defp runner(f, %{kind: :decorate, chunk: center}) do
    {worldgen, source, starts, scratch} = {f.worldgen, f.source, f.starts, f.scratch}
    cells = Enum.map(around(center, 1), &{&1, f.chunks[&1].cell})

    fn ->
      with {:ok, restored} <- load(worldgen, scratch, cells),
           cells = Enum.map(cells, fn {chunk, cell} -> Map.get(restored, chunk, cell) end),
           {:ok, _lenient} <- Native.gen_decorate(worldgen, source, starts, center, cells),
           do: if(restored == %{}, do: :ok, else: {:ok, restored})
    end
  end

  # A spilled cell stays spilled: making it full changes nothing in it.
  defp runner(f, %{kind: :full, chunk: chunk}) do
    {worldgen, cell, sky, scratch} = {f.worldgen, f.chunks[chunk].cell, f.sky, f.scratch}

    fn ->
      with {:ok, restored} <- load(worldgen, scratch, [{chunk, cell}]),
           {:ok, full} <-
             Native.gen_full(
               worldgen,
               Map.get(restored, chunk, cell),
               Generator.protocol_biomes()
             ),
           do: {:ok, lit(full, sky)}
    end
  end

  defp runner(f, %{kind: :alone, chunk: {x, z} = chunk}) do
    {worldgen, source, structures, sky} = {f.worldgen, f.source, f.starts != nil, f.sky}

    fn ->
      with {:ok, cells} <-
             Native.gen_reference(worldgen, source, {x - 1, z - 1}, 3, [chunk], structures),
           {:ok, full} <-
             Native.gen_full(worldgen, Enum.at(cells, 4), Generator.protocol_biomes()),
           do: {:ok, lit(full, sky)}
    end
  end

  defp runner(f, %{kind: :flat, chunk: {x, z}}) do
    {spec, sky} = {f.flat, f.sky}

    fn ->
      {:ok, image} = Native.column_layers_image(spec.layers, spec.biome)

      full = %{
        x: x,
        z: z,
        image: image,
        heights: [],
        block_entities: [],
        block_ticks: [],
        fluid_ticks: [],
        marks: []
      }

      {:ok, lit(full, sky)}
    end
  end

  # The spilled cells among `cells` (`{chunk, cell}`), decoded from the scratch
  # file: `{:ok, %{chunk => cell}}`.
  defp load(worldgen, scratch, cells) do
    Enum.reduce_while(cells, {:ok, %{}}, fn
      {chunk, {:spilled, offset, size}}, {:ok, acc} ->
        with {:ok, bytes} <- read_spilled(scratch, offset, size),
             {:ok, cell} <- Native.gen_decode(worldgen, bytes) do
          {:cont, {:ok, Map.put(acc, chunk, cell)}}
        else
          error -> {:halt, {:error, {:scratch, error}}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  @doc "A spilled cell's encoding, read from the scratch file at `path`."
  def read_spilled(path, offset, size) do
    with {:ok, file} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(file, offset, size) do
          {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
          other -> {:error, {:short_read, other}}
        end
      after
        :file.close(file)
      end
    end
  end

  ## Bounded memory (VMC-077q)

  @doc """
  Past `cap` proto cells in memory, make room down to seven eighths of it:
  `{f, spills}`, at most `limit` spills of `{chunk, cell}` for the caller to
  write and record with `spilled/2`. Cells within 2 of a wanted chunk, within
  1 of a needed decoration or held by a job stay; of the others, least
  recently used first, terrain no decoration wrote into is dropped and any
  other cell spills.
  """
  def evictions(f, limit \\ 64)

  def evictions(%__MODULE__{cap: cap, in_memory: n} = f, limit)
      when is_integer(cap) and n > cap do
    keep = cap - div(cap, 8)

    f.chunks
    |> Enum.filter(fn {_, %{cell: cell}} -> is_reference(cell) end)
    |> Enum.sort_by(fn {_, entry} -> Map.get(entry, :used, 0) end)
    |> Enum.reduce_while({f, []}, fn {chunk, entry}, {f, spills} ->
      cond do
        f.in_memory - length(spills) <= keep or length(spills) >= limit ->
          {:halt, {f, spills}}

        protected?(f, chunk) ->
          {:cont, {f, spills}}

        droppable?(f, chunk) ->
          f = %{
            f
            | chunks: Map.delete(f.chunks, chunk),
              in_memory: f.in_memory - 1,
              dropped: f.dropped + 1
          }

          {:cont, {f, spills}}

        true ->
          {:cont, {f, [{chunk, entry.cell} | spills]}}
      end
    end)
    |> then(fn {f, spills} -> {f, Enum.reverse(spills)} end)
  end

  def evictions(f, _limit), do: {f, []}

  # A cell work soon needs, or one a job holds. Needs are rebuilt only now
  # and then: a decoration that ran since is no need.
  defp protected?(f, chunk) do
    Map.has_key?(f.busy, chunk) or Enum.any?(around(chunk, 2), &Map.has_key?(f.priority, &1)) or
      Enum.any?(around(chunk, 1), &(Map.has_key?(f.needs, &1) and Map.has_key?(f.seqs, &1)))
  end

  # Terrain no decoration wrote into: no chunk within 1 of it decorated.
  defp droppable?(f, chunk),
    do: status(f, chunk) == :terrain and not Enum.any?(around(chunk, 1), &decorated?(f, &1))

  @doc """
  A job that writes `spills` (`{chunk, cell}`, from `evictions/2`) to the
  scratch file, holding their chunks meanwhile (VMC-077x: the encoding runs
  outside the scheduler): `{job, f}`, the job as `next/3` returns them, with
  `done/3` recording where the cells went. One runs at a time: it appends.
  """
  def spill_job(%__MODULE__{} = f, spills) do
    ref = make_ref()
    chunks = Enum.map(spills, &elem(&1, 0))
    job = %{ref: ref, kind: :spill, chunk: nil, holds: chunks, bulk: false, origin: nil}
    path = f.scratch
    busy = Enum.reduce(chunks, f.busy, &Map.put(&2, &1, ref))
    f = %{f | busy: busy, jobs: Map.put(f.jobs, ref, job)}
    {Map.put(job, :run, fn -> write_spills(path, spills) end), f}
  end

  defp write_spills(path, spills) do
    {:ok, file} = :file.open(path, [:read, :write, :raw, :binary])

    try do
      {:ok, start} = :file.position(file, :eof)

      {locations, _} =
        Enum.map_reduce(spills, start, fn {chunk, cell}, offset ->
          {:ok, bytes} = Native.gen_encode(cell)
          :ok = :file.write(file, bytes)
          {{chunk, offset, byte_size(bytes)}, offset + byte_size(bytes)}
        end)

      {:ok, locations}
    after
      :file.close(file)
    end
  end

  @doc """
  These cells (`{chunk, offset, size}`) are written to the scratch file: their
  proto chunks leave memory, to be read back from there.
  """
  def spilled(%__MODULE__{} = f, locations) do
    Enum.reduce(locations, f, fn {chunk, offset, size}, f ->
      case f.chunks do
        %{^chunk => %{cell: cell} = entry} when is_reference(cell) ->
          %{
            f
            | chunks: Map.put(f.chunks, chunk, %{entry | cell: {:spilled, offset, size}}),
              in_memory: f.in_memory - 1,
              spills: f.spills + 1
          }

        _ ->
          f
      end
    end)
  end

  @doc "The proto cells in memory (the memory gauge)."
  def cells_in_memory(%__MODULE__{} = f),
    do: for({_, %{cell: cell}} <- f.chunks, is_reference(cell), do: cell)

  # A full chunk's image with its light alone stored in it (VMC-077c).
  defp lit(full, sky) do
    lit = Blocks.lit_images(%{{full.x, full.z} => full.image}, sky)
    %{full | image: Map.fetch!(lit, {full.x, full.z})}
  end

  @doc """
  A job's result: `{f, events}`, events `{:full, requesters, chunk, full}`
  (for the requesters that want it now) and `{:failed, requesters, chunks,
  reason}` (a deterministic error: the chunk stays failed, and the wanted
  chunks within 2 of it are given up).
  """
  def done(%__MODULE__{} = f, ref, result) do
    case Map.pop(f.jobs, ref) do
      {nil, _} ->
        {f, []}

      {job, jobs} ->
        f = %{f | jobs: jobs, busy: Map.drop(f.busy, job.holds)}
        f = %{f | attempts: Map.delete(f.attempts, {job.kind, job.chunk})}
        apply_result(f, job, result)
    end
  end

  defp apply_result(f, %{kind: :terrain, chunk: chunk}, {:ok, cell}) do
    entry = %{status: :terrain, cell: cell, used: f.clock}
    f = %{f | chunks: Map.put(f.chunks, chunk, entry), in_memory: f.in_memory + 1}

    if f.final_after_terrain,
      do: {check_final(f, chunk), []},
      else: {Enum.reduce(around(chunk, 1), f, &check_ready(&2, &1)), []}
  end

  defp apply_result(f, %{kind: :decorate} = job, {:ok, restored}) when is_map(restored) do
    chunks =
      Enum.reduce(restored, f.chunks, fn {c, cell}, chunks ->
        Map.update!(chunks, c, &%{&1 | cell: cell})
      end)

    apply_result(%{f | chunks: chunks, in_memory: f.in_memory + map_size(restored)}, job, :ok)
  end

  defp apply_result(f, %{kind: :decorate, chunk: chunk}, :ok) do
    entry = %{f.chunks[chunk] | status: :decorated}
    f = %{f | chunks: Map.put(f.chunks, chunk, entry), seqs: Map.delete(f.seqs, chunk)}
    f = Enum.reduce(around(chunk, 2), f, &check_ready(&2, &1))
    {Enum.reduce(around(chunk, 1), f, &check_final(&2, &1)), []}
  end

  defp apply_result(f, %{kind: kind, chunk: chunk}, {:ok, full})
       when kind in [:full, :alone, :flat] do
    requesters = wanting(f, chunk)
    # Sent: wanted again only if lost.
    wants =
      Enum.reduce(requesters, f.wants, fn requester, wants ->
        case Map.delete(wants[requester], chunk) do
          left when left == %{} -> Map.delete(wants, requester)
          left -> Map.put(wants, requester, left)
        end
      end)

    # Every requester got it: wanted no more until one wants it again.
    f = %{
      f
      | wants: wants,
        index: Map.delete(f.index, chunk),
        priority: Map.delete(f.priority, chunk),
        delivered: MapSet.put(f.delivered, chunk),
        alone: MapSet.delete(f.alone, chunk)
    }

    {f, if(requesters == [], do: [], else: [{:full, requesters, chunk, full}])}
  end

  defp apply_result(f, %{kind: :spill}, {:ok, locations}), do: {spilled(f, locations), []}

  # Not written: the cells stay in memory.
  defp apply_result(f, %{kind: :spill}, {:error, _reason}), do: {f, []}

  defp apply_result(f, %{chunk: chunk}, {:error, reason}) do
    Valimc.Data.Metrics.add(:worldgen_errors)
    f = freeze(%{f | failed: Map.put(f.failed, chunk, reason)}, chunk)

    affected =
      f.wants
      |> Enum.flat_map(fn {_, wanted} -> Map.keys(wanted) end)
      |> Enum.uniq()
      |> Enum.filter(&near?(&1, chunk))
      |> Enum.reject(&MapSet.member?(f.delivered, &1))

    requesters = affected |> Enum.flat_map(&wanting(f, &1)) |> Enum.uniq()

    f = %{
      f
      | given_up: Enum.into(affected, f.given_up),
        priority: Map.drop(f.priority, affected)
    }

    {f, if(affected == [], do: [], else: [{:failed, requesters, affected, reason}])}
  end

  defp near?({x, z}, {a, b}), do: abs(x - a) <= 2 and abs(z - b) <= 2

  @doc """
  A job's worker went down without reporting: its work is tried again, up to
  #{@max_attempts} times, then fails.
  """
  def lost(%__MODULE__{} = f, ref) do
    case Map.fetch(f.jobs, ref) do
      :error ->
        {f, []}

      {:ok, job} ->
        key = {job.kind, job.chunk}
        attempts = Map.get(f.attempts, key, 0) + 1

        if attempts >= @max_attempts,
          do: done(f, ref, {:error, :worker_down}),
          else: {%{cancel(f, ref) | attempts: Map.put(f.attempts, key, attempts)}, []}
    end
  end

  @doc "Counts for metrics and tests."
  def stats(%__MODULE__{} = f) do
    by_status = Enum.frequencies_by(f.chunks, fn {_, %{status: s}} -> s end)

    %{
      terrain: Map.get(by_status, :terrain, 0),
      decorated: Map.get(by_status, :decorated, 0),
      handed: Map.get(by_status, :handed, 0),
      numbered: map_size(f.seqs),
      wanted: f.wants |> Enum.map(fn {_, w} -> map_size(w) end) |> Enum.sum(),
      running: map_size(f.jobs),
      failed: map_size(f.failed),
      in_memory: f.in_memory,
      spilled: Enum.count(f.chunks, &match?({_, %{cell: {:spilled, _, _}}}, &1)),
      dropped: f.dropped,
      spills: f.spills
    }
  end

  ## Snapshot (D3)

  @snapshot_version 1

  @doc """
  The chunks' statuses and proto chunks, the decoration numbers and the start
  table as a binary (a graceful stop's snapshot), or nil when there is
  nothing to keep. Chunks a running job holds are left out (as after a
  crash, their work is lost).
  """
  def snapshot(%__MODULE__{kind: :noise, final_after_terrain: false} = f) do
    chunks =
      for {chunk, %{status: status, cell: cell}} <- f.chunks, not Map.has_key?(f.busy, chunk) do
        {chunk, status, encoded(f, cell)}
      end

    starts = f.starts && elem(Native.gen_starts_snapshot(f.starts), 1)

    if chunks == [] do
      nil
    else
      :erlang.term_to_binary(
        %{
          version: @snapshot_version,
          source: f.source,
          chunks: chunks,
          seqs: f.seqs,
          next_seq: f.next_seq,
          starts: starts
        },
        [:compressed]
      )
    end
  end

  def snapshot(_f), do: nil

  defp encoded(_f, nil), do: nil
  defp encoded(f, {:spilled, offset, size}), do: elem(read_spilled(f.scratch, offset, size), 1)
  defp encoded(_f, cell), do: elem(Native.gen_encode(cell), 1)

  @doc """
  `f` with a snapshot's chunks and starts; `{:error, reason}` for another
  generation's. With `spill` (`image -> {offset, size}`, writing to the scratch
  file), its proto chunks stay spilled until a job needs them.
  """
  def restore(f, binary, spill \\ nil)

  def restore(%__MODULE__{kind: :noise, final_after_terrain: false} = f, binary, spill) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: @snapshot_version, source: source} = s when source == f.source ->
        chunks =
          Map.new(s.chunks, fn
            {chunk, status, nil} ->
              {chunk, %{status: status, cell: nil}}

            {chunk, status, image} when spill != nil ->
              {offset, size} = spill.(image)
              {chunk, %{status: status, cell: {:spilled, offset, size}}}

            {chunk, status, image} ->
              {:ok, cell} = Native.gen_decode(f.worldgen, image)
              {chunk, %{status: status, cell: cell}}
          end)

        in_memory = Enum.count(chunks, fn {_, %{cell: cell}} -> is_reference(cell) end)

        starts =
          case {f.starts, s.starts} do
            {nil, _} -> nil
            {starts, nil} -> starts
            {_, binary} -> elem(Native.gen_starts_restore(binary), 1)
          end

        {:ok,
         %{
           f
           | chunks: chunks,
             in_memory: in_memory,
             seqs: s.seqs,
             next_seq: s.next_seq,
             starts: starts,
             stale: true
         }}

      _ ->
        {:error, :snapshot_of_another_generation}
    end
  rescue
    error -> {:error, {:invalid_snapshot, Exception.message(error)}}
  end

  def restore(_f, _binary, _spill), do: {:error, :nothing_to_restore}

  ## Inline

  @doc """
  Run `f` in this process until `chunks` are full (spawn search, checks):
  `{full_chunks_in_order, f}`.
  """
  def run(%__MODULE__{} = f, chunks) do
    requester = make_ref()
    f = want(f, requester, Map.new(chunks, &{&1, -1}))
    drive(f, requester, chunks, %{})
  end

  defp drive(f, requester, chunks, got) do
    if Enum.all?(chunks, &Map.has_key?(got, &1)) do
      {Enum.map(chunks, &Map.fetch!(got, &1)), want(f, requester, %{})}
    else
      case next(refresh(f), 1) do
        {[job], f} ->
          {f, events} = done(f, job.ref, safe(job.run))
          got = Enum.reduce(events, got, &collect(&1, &2, requester))
          drive(f, requester, chunks, got)

        {[], _f} ->
          raise "generation stalled with #{length(chunks) - map_size(got)} chunks left"
      end
    end
  end

  defp collect({:full, requesters, chunk, full}, got, requester),
    do: if(requester in requesters, do: Map.put(got, chunk, full), else: got)

  defp collect({:failed, requesters, chunks, reason}, got, requester) do
    if requester in requesters,
      do: raise("generating #{inspect(chunks)} failed: #{inspect(reason)}"),
      else: got
  end

  @doc "Run a job's closure; a raise is a deterministic error."
  def safe(run) do
    run.()
  rescue
    error -> {:error, {:generation, Exception.message(error)}}
  end
end
