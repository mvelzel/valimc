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
  player that wants it, -1 for calls that wait); the work a wanted chunk needs
  inherits it, including the earlier decorations it waits for. Work waits in
  priority queues that a job's result updates around its chunk and that are
  rebuilt only when wants change; `next/3` returns the jobs that can start
  (final chunks, then decorations, then terrain), as closures for the caller
  to run, and `done/3` takes their results. Nothing here polls or answers
  busy: what cannot start yet is simply not returned until what it waits for
  is done.

  A chunk wanted again after it was handed over (its region lost it), or one
  that needs a decoration that can no longer run (a neighbour is handed over
  or failed), is made alone, as vanilla makes a chunk missing from its region
  file: over fresh terrain of its 3 × 3, with only its own decoration.
  """
  alias Valimc.Native
  alias Valimc.World.{Blocks, Generator}

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
    # Rebuilt from the wants when they change (`refresh/1`): each wanted
    # chunk's smallest priority, each numbered decoration's (inherited from
    # the wanted chunks and the later decorations that wait for it).
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
    log: nil
  ]

  # A job whose worker dies is tried again this often, then fails.
  @max_attempts 3

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
  sent is sent again (it lost it).
  """
  def want(%__MODULE__{} = f, requester, wanted) when is_map(wanted) do
    before = Map.get(f.wants, requester, %{})

    wants =
      if wanted == %{},
        do: Map.delete(f.wants, requester),
        else: Map.put(f.wants, requester, wanted)

    added = wanted |> Map.keys() |> Enum.reject(&Map.has_key?(before, &1))

    f = %{
      f
      | wants: wants,
        delivered: Enum.reduce(added, f.delivered, &MapSet.delete(&2, &1)),
        stale: true
    }

    f |> number(added) |> find_alone(added)
  end

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

  # The priorities and queues of the wants as they are now.
  defp refresh(%{stale: false} = f), do: f

  defp refresh(f) do
    priority =
      Enum.reduce(f.wants, %{}, fn {_, wanted}, acc ->
        Enum.reduce(wanted, acc, fn {chunk, p}, acc ->
          if MapSet.member?(f.given_up, chunk),
            do: acc,
            else: Map.update(acc, chunk, p, &min(&1, p))
        end)
      end)

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
    |> Enum.reduce(%{}, fn {n, seq}, needs ->
      own = for c <- around(n, 1), p = f.priority[c], p != nil, do: p

      waiting =
        for m <- around(n, 2),
            p = needs[m],
            p != nil and Map.fetch!(f.seqs, m) > seq,
            do: p

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

    %{
      f
      | chunks: Map.drop(f.chunks, chunks),
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
  defp freeze(f, chunk) do
    blocked = for n <- around(chunk, 1), not decorated?(f, n), do: n
    wanted = for c <- around(chunk, 2), Map.has_key?(f.priority, c), do: c
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
      {[], refresh(f), {capacity, bulk || capacity, capacity - (bulk || capacity)}}
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

  defp still(f, :queue, {_, _, _, c}), do: if(needs_terrain?(f, c), do: {:terrain, c})

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
      f = %{f | busy: busy, jobs: Map.put(f.jobs, ref, job)}
      {Map.put(job, :run, runner(f, job)), f}
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

  defp runner(f, %{kind: :decorate, chunk: center}) do
    {worldgen, source, starts} = {f.worldgen, f.source, f.starts}
    cells = Enum.map(around(center, 1), &f.chunks[&1].cell)

    fn ->
      with {:ok, _lenient} <- Native.gen_decorate(worldgen, source, starts, center, cells),
           do: :ok
    end
  end

  defp runner(f, %{kind: :full, chunk: chunk}) do
    {worldgen, cell, sky} = {f.worldgen, f.chunks[chunk].cell, f.sky}

    fn ->
      with {:ok, full} <- Native.gen_full(worldgen, cell, Generator.protocol_biomes()),
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
    f = %{f | chunks: Map.put(f.chunks, chunk, %{status: :terrain, cell: cell})}

    if f.final_after_terrain,
      do: {check_final(f, chunk), []},
      else: {Enum.reduce(around(chunk, 1), f, &check_ready(&2, &1)), []}
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
        priority: Map.delete(f.priority, chunk),
        delivered: MapSet.put(f.delivered, chunk),
        alone: MapSet.delete(f.alone, chunk)
    }

    {f, if(requesters == [], do: [], else: [{:full, requesters, chunk, full}])}
  end

  defp apply_result(f, %{chunk: chunk}, {:error, reason}) do
    Valimc.Metrics.add(:worldgen_errors)
    f = freeze(%{f | failed: Map.put(f.failed, chunk, reason)}, chunk)

    affected =
      f.wants
      |> Enum.flat_map(fn {_, wanted} -> Map.keys(wanted) end)
      |> Enum.uniq()
      |> Enum.filter(&near?(&1, chunk))
      |> Enum.reject(&MapSet.member?(f.delivered, &1))

    requesters = affected |> Enum.flat_map(&wanting(f, &1)) |> Enum.uniq()
    f = %{f | given_up: Enum.into(affected, f.given_up)}
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
      failed: map_size(f.failed)
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
        {chunk, status, cell && elem(Native.gen_encode(cell), 1)}
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

  @doc "`f` with a snapshot's chunks and starts; `{:error, reason}` for another generation's."
  def restore(%__MODULE__{kind: :noise, final_after_terrain: false} = f, binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: @snapshot_version, source: source} = s when source == f.source ->
        chunks =
          Map.new(s.chunks, fn
            {chunk, status, nil} ->
              {chunk, %{status: status, cell: nil}}

            {chunk, status, image} ->
              {:ok, cell} = Native.gen_decode(f.worldgen, image)
              {chunk, %{status: status, cell: cell}}
          end)

        starts =
          case {f.starts, s.starts} do
            {nil, _} -> nil
            {starts, nil} -> starts
            {_, binary} -> elem(Native.gen_starts_restore(binary), 1)
          end

        {:ok,
         %{f | chunks: chunks, seqs: s.seqs, next_seq: s.next_seq, starts: starts, stale: true}}

      _ ->
        {:error, :snapshot_of_another_generation}
    end
  rescue
    error -> {:error, {:invalid_snapshot, Exception.message(error)}}
  end

  def restore(_f, _binary), do: {:error, :nothing_to_restore}

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
      case next(f, 1) do
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
