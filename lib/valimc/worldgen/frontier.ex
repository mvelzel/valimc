defmodule Valimc.Worldgen.Frontier do
  @moduledoc """
  The generation state of one dimension (VMC-077n), as data:
  `Valimc.Worldgen.Scheduler` runs it on the generation pool, and spawn search
  runs it inline at world creation.

  One model decides what is made and in which order (VMC-077x1): the wanted
  chunks not sent yet are goals in one order, the only priority
  (`Frontier.Goals`), and `next/3` finds the work to start from them through
  what each needs (`Frontier.Dependencies`); `Frontier.Memory` bounds the
  proto cells and `Frontier.Runners` holds the jobs' closures. `next/3` returns
  jobs for the caller to run (anywhere) and report with `done/3`, or give back
  with `cancel/2`; nothing polls or answers busy.
  """
  alias Valimc.Native
  alias Valimc.Worldgen.Frontier.{Dependencies, Goals, Memory, Runners}
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
    # How the dimension's chunk packets encode (`Blocks.packet_spec/1`), for
    # full jobs to prepare them (VMC-081c2); nil prepares none.
    packet: nil,
    # chunk => %{status, cell, used}
    chunks: %{},
    # Goals: each requester's wants (`chunk => urgent?`), who wants each
    # chunk, the wanted chunks given up, players' foci, and the goals ordered
    # (`{rank, z, x, chunk}`) with each goal's rank.
    wants: %{},
    index: %{},
    given_up: MapSet.new(),
    focus: %{},
    goals: :gb_sets.new(),
    ranks: %{},
    rescore: false,
    # Dependencies: decoration numbers, what each waits for, the needed ones
    # that can start, the terrain needed ones lack (`chunk => how many`),
    # goals that are final, goals made alone, and the decorated chunks in
    # the order they ran, newest first, when recorded (checks).
    seqs: %{},
    next_seq: 0,
    deps: %{},
    ready: MapSet.new(),
    terrain: %{},
    finals: MapSet.new(),
    alone: MapSet.new(),
    # Conflicting decorations run in request order (the oracle checks), not
    # in the order they start (VMC-081c1).
    serial: false,
    log: nil,
    # Jobs: the chunks they hold, by ref; chunks sent and not handed over
    # yet; chunks whose generation failed; attempts of jobs whose worker
    # died; and whether the last `next/3` left work out for want of room.
    busy: %{},
    jobs: %{},
    delivered: MapSet.new(),
    failed: %{},
    attempts: %{},
    left: false,
    # Memory (VMC-077q): the most cells kept (nil: no bound), the cells in
    # memory by last use, the scratch file spilled cells are read back from,
    # and counts of cells dropped and spilled.
    cap: nil,
    in_memory: 0,
    clock: 0,
    lru: :gb_sets.new(),
    scratch: nil,
    dropped: 0,
    spills: 0
  ]

  # A job whose worker dies is tried again this often, then fails.
  @max_attempts 3

  @doc """
  The generation of `spec` (a `Generator.spec_of/2` spec of a dimension).
  Options: `decorated` (false: chunks are final after terrain), `sky` (the
  dimension has sky light, stored in full chunks' images), `packet` (its
  chunk packets' `Blocks.packet_spec/1`, which full jobs prepare), `log` (record
  the decoration order) and `order` (`:started`, the default, or
  `:requested`: conflicting decorations run in request order).
  """
  def new(spec, opts \\ []) do
    decorated = Keyword.get(opts, :decorated, true)
    sky = Keyword.get(opts, :sky, true)
    packet = Keyword.get(opts, :packet)
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
          packet: packet,
          log: log,
          serial: Keyword.get(opts, :order, :started) == :requested
        }

      %{kind: :flat} ->
        %__MODULE__{kind: :flat, flat: spec, final_after_terrain: true, sky: sky, packet: packet}
    end
  end

  ## Requests

  @doc """
  `requester` wants `wanted` (`chunk => urgent?`) made full, replacing what it
  wanted; an empty map withdraws. A chunk it newly wants that was already
  sent is sent again (it lost it).
  """
  def want(%__MODULE__{} = f, requester, wanted) when is_map(wanted) do
    {f, added, gained, lost} = Goals.want(f, requester, wanted)
    f = %{f | delivered: Enum.reduce(added, f.delivered, &MapSet.delete(&2, &1))}
    Dependencies.goals(f, added, gained, lost)
  end

  @doc "Player `holder` is in `chunk` moving along `heading` (nil chunk: gone); see `Goals.focus/4`."
  defdelegate focus(f, holder, chunk, heading), to: Goals
  defdelegate score(chunk, focus), to: Goals
  defdelegate wanting(f, chunk), to: Goals
  defdelegate around(chunk, r), to: Dependencies

  @doc "Where a finished chunk goes in its delivery (VMC-077w): its score from the nearest player."
  def rank(%__MODULE__{} = f, chunk), do: Goals.nearest(f, chunk)

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
    f = Enum.reduce(chunks, f, &Memory.release(&2, &1))
    delivered = Enum.reduce(chunks, f.delivered, &MapSet.delete(&2, &1))
    %{f | chunks: Map.drop(f.chunks, chunks), delivered: delivered}
  end

  defp hand(f, chunks, present) do
    f =
      Enum.reduce(chunks, f, fn chunk, f ->
        handed =
          cond do
            # A running decoration writes into it (only a region's own report).
            match?(%{kind: :decorate}, f.jobs[f.busy[chunk]]) -> false
            Dependencies.handed?(f, chunk) -> false
            present -> true
            true -> Dependencies.final?(f, chunk) or MapSet.member?(f.delivered, chunk)
          end

        f = %{f | delivered: MapSet.delete(f.delivered, chunk)}

        if handed do
          f = Memory.release(f, chunk)
          f = %{f | chunks: Map.put(f.chunks, chunk, %{status: :handed, cell: nil})}
          f |> Dependencies.free(chunk) |> Dependencies.freeze(chunk)
        else
          f
        end
      end)

    chunks
    |> Enum.flat_map(&around(&1, 1))
    |> Enum.uniq()
    |> Enum.filter(fn chunk -> Enum.all?(around(chunk, 1), &Dependencies.handed?(f, &1)) end)
    |> then(&%{f | chunks: Map.drop(f.chunks, &1)})
  end

  ## Jobs

  @doc """
  Up to `capacity` jobs that can start now, at most `bulk` of them terrain:
  `%{ref, kind, chunk, bulk, run}`. They start in goal order whatever their
  kind (VMC-081c): the work of a nearer goal before a farther goal's, so a
  backlog of work far away never holds up the player's own chunk. For one
  goal, its full chunk or chunk made alone goes first, then the decorations it
  needs (the earliest first), then their terrain; then other needed work.
  """
  def next(f, capacity, bulk \\ nil)

  def next(%__MODULE__{} = f, capacity, bulk) when capacity > 0 do
    f = Goals.rescore(f)
    bulk = bulk || capacity
    room = {capacity, bulk, capacity - bulk}
    {decorations, terrain, left} = Dependencies.resolve(f, capacity, bulk)
    kind = if f.kind == :flat, do: :flat, else: :terrain

    candidates =
      Enum.sort(
        Enum.concat([
          for(c <- f.finals, do: {goal_order(f, c), 0, 0, :full, c}),
          for(c <- f.alone, do: {goal_order(f, c), 1, 0, :alone, c}),
          for({{order, c}, i} <- Enum.with_index(decorations), do: {order, 2, i, :decorate, c}),
          for({{order, c}, i} <- Enum.with_index(terrain), do: {order, 3, i, kind, c})
        ])
      )

    {jobs, f, _room} =
      Enum.reduce(candidates, {[], f, room}, fn candidate, acc ->
        {_, _, _, kind, chunk} = candidate
        claim_one(acc, kind, chunk)
      end)

    left = left or length(jobs) < length(candidates)
    {Enum.reverse(jobs), %{f | left: left}}
  end

  def next(%__MODULE__{} = f, _capacity, _bulk), do: {[], f}

  # A goal's place in the goal order, as `Dependencies.resolve/3` gives it.
  defp goal_order(f, {x, z} = c) do
    case f.ranks do
      %{^c => rank} -> {0, rank, z, x}
      _ -> {3, 0, z, x}
    end
  end

  # Room is `{jobs, terrain jobs, slots terrain leaves}`: as on the pool,
  # terrain never takes the last slots, whatever took the others.
  defp claim_one({_, _, {0, _, _}} = acc, _kind, _chunk), do: acc
  defp claim_one({_, _, {_, 0, _}} = acc, :terrain, _chunk), do: acc

  defp claim_one({jobs, f, {capacity, bulk, gap} = room}, kind, chunk) do
    case start(f, kind, chunk) do
      nil ->
        {jobs, f, room}

      {job, f} ->
        bulk = if kind == :terrain, do: bulk - 1, else: bulk
        {[job | jobs], f, {capacity - 1, max(min(bulk, capacity - 1 - gap), 0), gap}}
    end
  end

  # Claim what a job holds and build it; nil when it cannot start.
  defp start(f, kind, chunk) do
    holds = if kind == :decorate, do: around(chunk, 1), else: [chunk]

    if Enum.any?(holds, &Map.has_key?(f.busy, &1)) or not startable?(f, kind, chunk) do
      nil
    else
      ref = make_ref()
      job = %{ref: ref, kind: kind, chunk: chunk, holds: holds, bulk: kind == :terrain}
      busy = Enum.reduce(holds, f.busy, &Map.put(&2, &1, ref))
      f = Memory.touch(%{f | busy: busy, jobs: Map.put(f.jobs, ref, job)}, holds)
      f = if kind == :decorate, do: Dependencies.check(f, chunk), else: f
      {Map.put(job, :run, Runners.runner(f, job)), f}
    end
  end

  defp startable?(f, :full, c),
    do: Goals.goal?(f, c) and Dependencies.final?(f, c) and not Dependencies.handed?(f, c)

  defp startable?(f, :alone, c), do: Goals.goal?(f, c) and Dependencies.alone?(f, c)
  defp startable?(_f, _kind, _c), do: true

  @doc "Give back a job `next/3` returned that did not start."
  def cancel(%__MODULE__{} = f, ref) do
    case Map.pop(f.jobs, ref) do
      {nil, _} ->
        f

      {job, jobs} ->
        f = %{f | jobs: jobs, busy: Map.drop(f.busy, job.holds)}
        if job.kind == :decorate, do: Dependencies.check(f, job.chunk), else: f
    end
  end

  @doc """
  A job's result: `{f, events}`, events `{:full, requesters, chunk, full}`
  (for the requesters that want it now) and `{:failed, requesters, chunks,
  reason}` (a deterministic error: the chunk stays failed, and the goals
  within 2 of it are given up).
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
    f = Memory.put(f, chunk, cell, :terrain)

    if f.final_after_terrain,
      do: {Dependencies.check_final(f, chunk), []},
      else: {Dependencies.made(f, chunk), []}
  end

  defp apply_result(f, %{kind: :decorate} = job, {:ok, restored}) when is_map(restored) do
    f =
      Enum.reduce(restored, f, fn {c, cell}, f ->
        Memory.put(f, c, cell, Dependencies.status(f, c))
      end)

    apply_result(f, job, :ok)
  end

  defp apply_result(f, %{kind: :decorate, chunk: n}, :ok) do
    f = %{f | chunks: Map.update!(f.chunks, n, &%{&1 | status: :decorated})}
    f = if f.log, do: %{f | log: [n | f.log]}, else: f
    {Dependencies.decorated(f, n), []}
  end

  defp apply_result(f, %{kind: kind, chunk: chunk}, {:ok, full})
       when kind in [:full, :alone, :flat] do
    requesters = wanting(f, chunk)
    # Sent: wanted again only if lost.
    {f, lost} = Goals.sent(f, chunk)
    f = Dependencies.goals(%{f | delivered: MapSet.put(f.delivered, chunk)}, [], [], lost)
    {f, if(requesters == [], do: [], else: [{:full, requesters, chunk, full}])}
  end

  defp apply_result(f, %{kind: :spill}, {:ok, locations}), do: {Memory.spilled(f, locations), []}

  # Not written: the cells stay in memory.
  defp apply_result(f, %{kind: :spill}, {:error, _reason}), do: {f, []}

  defp apply_result(f, %{chunk: chunk}, {:error, reason}) do
    Valimc.Data.Metrics.add(:worldgen_errors)
    f = Dependencies.freeze(%{f | failed: Map.put(f.failed, chunk, reason)}, chunk)
    affected = for c <- around(chunk, 2), Goals.goal?(f, c), do: c
    requesters = affected |> Enum.flat_map(&wanting(f, &1)) |> Enum.uniq()
    {f, lost} = Goals.give_up(f, affected)
    f = Dependencies.goals(f, [], [], lost)
    {f, if(affected == [], do: [], else: [{:failed, requesters, affected, reason}])}
  end

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
      wanted: map_size(f.ranks),
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

  defp encoded(f, {:spilled, offset, size}),
    do: elem(Memory.read_spilled(f.scratch, offset, size), 1)

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
        f =
          Enum.reduce(s.chunks, f, fn
            {chunk, status, nil}, f ->
              %{f | chunks: Map.put(f.chunks, chunk, %{status: status, cell: nil})}

            {chunk, status, image}, f when spill != nil ->
              {offset, size} = spill.(image)
              cell = {:spilled, offset, size}
              %{f | chunks: Map.put(f.chunks, chunk, %{status: status, cell: cell})}

            {chunk, status, image}, f ->
              {:ok, cell} = Native.gen_decode(f.worldgen, image)
              Memory.put(f, chunk, cell, status)
          end)

        starts =
          case {f.starts, s.starts} do
            {nil, _} -> nil
            {starts, nil} -> starts
            {_, binary} -> elem(Native.gen_starts_restore(binary), 1)
          end

        {:ok, Dependencies.rebuild(%{f | seqs: s.seqs, next_seq: s.next_seq, starts: starts})}

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
    f = want(f, requester, Map.new(chunks, &{&1, true}))
    drive(f, requester, chunks, %{})
  end

  defp drive(f, requester, chunks, got) do
    if Enum.all?(chunks, &Map.has_key?(got, &1)) do
      {Enum.map(chunks, &Map.fetch!(got, &1)), want(f, requester, %{})}
    else
      case next(f, 1) do
        {[job], f} ->
          {f, events} = done(f, job.ref, Runners.safe(job.run))
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
end
