defmodule Valimc.World.ScheduledTicks do
  @moduledoc """
  A section's scheduled block ticks (VMC-066), shaped like vanilla's
  `LevelTicks`: one container per chunk, each ordered by trigger game tick,
  then priority (lower first), then scheduling order. A tick runs only in a
  chunk that ticks (`take_due/3` visits only those chunks' containers), so the
  ticks of chunks outside simulation are never touched until their chunk
  ticks. A (position, block) pair is scheduled at most once; a due tick runs
  only if the block at its position still matches. Like vanilla, nothing caps
  how many a section holds; at most #{65_536} run in one tick, the rest the next.

  Dues are stored relative to `shift`, so a section moving to a group on
  another game tick (`rebase/2`) keeps every delay without touching its ticks.
  A chunk's ticks are one record (`{:ticks, chunk}`, its container in order
  as `record/1` writes it, VMC-077w; `from_records/1` reads them back). A
  container nothing changed stays the same term, so the section's storage
  finds the changed chunks by identity and a frame costs what they hold.

  The containers of chunks outside simulation can be frozen (`freeze/2`): each
  becomes one off-heap binary that the owner's collections never copy, which
  matters for the fluid ticks generation leaves in every rendered chunk
  (VMC-081b). A frozen chunk thaws when it ticks or gets a tick.
  """

  import Bitwise

  @max_per_tick 65_536

  # `frozen`: chunk => `{:frozen, count, binary}` of its container's entries.
  defstruct containers: %{}, index: %{}, frozen: %{}, sequence: 0, shift: 0

  def new, do: %__MODULE__{}

  def size(%__MODULE__{index: index, frozen: frozen}),
    do: map_size(index) + Enum.sum(for {_, {:frozen, n, _}} <- frozen, do: n)

  @doc "Whether `block` is pending at `position`."
  def scheduled?(%__MODULE__{index: index, frozen: frozen}, {x, _, z} = position, block) do
    Map.has_key?(index, {position, block}) or
      case Map.fetch(frozen, {x >>> 4, z >>> 4}) do
        {:ok, container} ->
          Enum.any?(entries(container), &match?({_, _, _, ^position, ^block}, &1))

        :error ->
          false
      end
  end

  @doc "Schedule `block` at `position` for game tick `due` (no-op if already scheduled)."
  def schedule(%__MODULE__{} = ticks, {x, _, z} = position, block, due, priority \\ 0)
      when is_integer(due) and is_integer(priority) do
    ticks = thaw(ticks, [{x >>> 4, z >>> 4}])

    if Map.has_key?(ticks.index, {position, block}) do
      {:ok, ticks}
    else
      entry = {due - ticks.shift, priority, ticks.sequence, position, block}
      chunk = {Integer.floor_div(x, 16), Integer.floor_div(z, 16)}

      containers =
        Map.update(ticks.containers, chunk, :gb_sets.singleton(entry), &:gb_sets.add(entry, &1))

      {:ok,
       %{
         ticks
         | containers: containers,
           index: Map.put(ticks.index, {position, block}, entry),
           sequence: ticks.sequence + 1
       }}
    end
  end

  @doc """
  Schedule many `{position, block, due, priority}` at once (a generated
  chunk's fluid and block ticks), in their order: each chunk's container is
  built once instead of tick by tick.
  """
  def schedule_all(%__MODULE__{} = ticks, entries) do
    ticks =
      if ticks.frozen == %{},
        do: ticks,
        else: thaw(ticks, Enum.uniq(for {{x, _, z}, _, _, _} <- entries, do: {x >>> 4, z >>> 4}))

    {added, index, sequence} =
      Enum.reduce(entries, {[], ticks.index, ticks.sequence}, fn {position, block, due, priority},
                                                                 {added, index, sequence} ->
        if Map.has_key?(index, {position, block}) do
          {added, index, sequence}
        else
          entry = {due - ticks.shift, priority, sequence, position, block}
          {[entry | added], Map.put(index, {position, block}, entry), sequence + 1}
        end
      end)

    by_chunk =
      Enum.group_by(added, fn {_, _, _, {x, _, z}, _} ->
        {Integer.floor_div(x, 16), Integer.floor_div(z, 16)}
      end)

    containers =
      Enum.reduce(by_chunk, ticks.containers, fn {chunk, entries}, acc ->
        set = :gb_sets.from_list(entries)

        Map.update(acc, chunk, set, fn container ->
          if :gb_sets.size(container) >= :gb_sets.size(set),
            do: Enum.reduce(entries, container, &:gb_sets.add/2),
            else: :gb_sets.fold(&:gb_sets.add/2, set, container)
        end)
      end)

    %{ticks | containers: containers, index: index, sequence: sequence}
  end

  @doc """
  Remove and return the ticks due at or before `tick` in the `chunks` that
  tick, in vanilla order across them (at most #{65_536}); every other tick
  stays as it is.
  """
  def take_due(%__MODULE__{} = ticks, tick, chunks) do
    stored = tick - ticks.shift

    # Chunks that tick again thaw first.
    ticks =
      if ticks.frozen == %{},
        do: ticks,
        else: thaw(ticks, Enum.filter(chunks, &Map.has_key?(ticks.frozen, &1)))

    # Whichever is fewer: the chunks that tick, or those with ticks (VMC-077w).
    chunks =
      if is_struct(chunks, MapSet) and map_size(ticks.containers) < MapSet.size(chunks),
        do: Enum.filter(Map.keys(ticks.containers), &MapSet.member?(chunks, &1)),
        else: chunks

    {due, containers} =
      Enum.reduce(chunks, {[], ticks.containers}, fn chunk, {due, containers} = acc ->
        with %{^chunk => container} <- containers,
             {[_ | _] = taken, rest} <- take(container, stored, []) do
          containers =
            if :gb_sets.is_empty(rest),
              do: Map.delete(containers, chunk),
              else: Map.put(containers, chunk, rest)

          {taken ++ due, containers}
        else
          _ -> acc
        end
      end)

    if due == [], do: {[], ticks}, else: take_run(ticks, containers, due)
  end

  defp take_run(ticks, containers, due) do
    {run, later} = due |> Enum.sort() |> Enum.split(@max_per_tick)

    containers =
      Enum.reduce(later, containers, fn {_, _, _, {x, _, z}, _} = entry, acc ->
        chunk = {Integer.floor_div(x, 16), Integer.floor_div(z, 16)}
        Map.update(acc, chunk, :gb_sets.singleton(entry), &:gb_sets.add(entry, &1))
      end)

    keys = for {_, _, _, position, block} <- run, do: {position, block}

    {keys, %{ticks | containers: containers, index: Map.drop(ticks.index, keys)}}
  end

  defp take(container, stored, acc) do
    if :gb_sets.is_empty(container) do
      {acc, container}
    else
      case :gb_sets.take_smallest(container) do
        {{due, _, _, _, _} = entry, rest} when due <= stored -> take(rest, stored, [entry | acc])
        _ -> {acc, container}
      end
    end
  end

  @doc """
  Freeze the containers of chunks not in `simulated`: their entries leave the
  index and the heap for one binary each. The same term when none is left.
  """
  def freeze(%__MODULE__{containers: containers} = ticks, simulated) do
    case for {chunk, _} <- containers, not MapSet.member?(simulated, chunk), do: chunk do
      [] ->
        ticks

      chunks ->
        Enum.reduce(chunks, ticks, fn chunk, acc ->
          list = :gb_sets.to_list(Map.fetch!(acc.containers, chunk))

          %{
            acc
            | containers: Map.delete(acc.containers, chunk),
              index: Map.drop(acc.index, for({_, _, _, p, b} <- list, do: {p, b})),
              frozen:
                Map.put(acc.frozen, chunk, {:frozen, length(list), :erlang.term_to_binary(list)})
          }
        end)
    end
  end

  defp thaw(%__MODULE__{frozen: frozen} = ticks, _chunks) when frozen == %{}, do: ticks

  defp thaw(ticks, chunks) do
    Enum.reduce(chunks, ticks, fn chunk, acc ->
      case Map.pop(acc.frozen, chunk) do
        {nil, _} ->
          acc

        {container, frozen} ->
          list = entries(container)

          index =
            Enum.reduce(list, acc.index, fn {_, _, _, p, b} = e, i -> Map.put(i, {p, b}, e) end)

          %{
            acc
            | frozen: frozen,
              index: index,
              containers: Map.put(acc.containers, chunk, :gb_sets.from_ordset(list))
          }
      end
    end)
  end

  # A container's entries in order, frozen or not.
  defp entries({:frozen, _, binary}), do: :erlang.binary_to_term(binary)
  defp entries(container), do: :gb_sets.to_list(container)

  @doc "Every chunk's container, frozen or not, for storage (`record/1` reads either)."
  def all_containers(%__MODULE__{containers: containers, frozen: frozen}),
    do: if(frozen == %{}, do: containers, else: Map.merge(containers, frozen))

  @doc "Continue at game tick `to` from game tick `from`: every due keeps its delay."
  def rebase(%__MODULE__{} = ticks, from, to), do: %{ticks | shift: ticks.shift + to - from}

  @doc """
  A chunk's stored ticks (the value of its `{:ticks, chunk}` record): its
  container in order, `[{due, priority, position, block}]`, dues relative to
  the `{:ticks, :shift}` record.
  """
  def record(container),
    do:
      for(
        {due, priority, _, position, block} <- entries(container),
        do: {due, priority, position, block}
      )

  @doc """
  The ticks of a section's `{:ticks, _}` records, in vanilla order across
  chunks (due, then priority; each chunk's own order is kept).
  """
  def from_records(records) do
    entries =
      for(
        {{:ticks, {_, _}}, list} <- records,
        {due, priority, pos, block} <- list,
        do: {pos, block, due, priority}
      )
      |> Enum.sort_by(fn {_, _, due, priority} -> {due, priority} end)

    %{schedule_all(new(), entries) | shift: Map.get(records, {:ticks, :shift}, 0)}
  end
end
