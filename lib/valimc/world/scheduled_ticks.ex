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
  Every change goes into a journal of the pairs it touched (`journal`), which
  the section's storage turns into its next frame (`records/2`) and then
  clears (`settled/1`).
  """

  @max_per_tick 65_536

  defstruct containers: %{}, index: %{}, sequence: 0, shift: 0, journal: %{}

  def new, do: %__MODULE__{}
  def size(%__MODULE__{index: index}), do: map_size(index)

  @doc "Schedule `block` at `position` for game tick `due` (no-op if already scheduled)."
  def schedule(%__MODULE__{} = ticks, {x, _, z} = position, block, due, priority \\ 0)
      when is_integer(due) and is_integer(priority) do
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
           sequence: ticks.sequence + 1,
           journal: Map.put(ticks.journal, {position, block}, true)
       }}
    end
  end

  @doc """
  Schedule many `{position, block, due, priority}` at once (a generated
  chunk's fluid and block ticks), in their order: each chunk's container is
  built once instead of tick by tick.
  """
  def schedule_all(%__MODULE__{} = ticks, entries) do
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

    containers =
      added
      |> Enum.group_by(fn {_, _, _, {x, _, z}, _} ->
        {Integer.floor_div(x, 16), Integer.floor_div(z, 16)}
      end)
      |> Enum.reduce(ticks.containers, fn {chunk, entries}, acc ->
        set = :gb_sets.from_list(entries)

        Map.update(acc, chunk, set, fn container ->
          if :gb_sets.size(container) >= :gb_sets.size(set),
            do: Enum.reduce(entries, container, &:gb_sets.add/2),
            else: :gb_sets.fold(&:gb_sets.add/2, set, container)
        end)
      end)

    journal =
      Enum.reduce(added, ticks.journal, fn {_, _, _, position, block}, acc ->
        Map.put(acc, {position, block}, true)
      end)

    %{ticks | containers: containers, index: index, sequence: sequence, journal: journal}
  end

  @doc """
  Remove and return the ticks due at or before `tick` in the `chunks` that
  tick, in vanilla order across them (at most #{65_536}); every other tick
  stays as it is.
  """
  def take_due(%__MODULE__{} = ticks, tick, chunks) do
    stored = tick - ticks.shift

    {due, containers} =
      Enum.reduce(chunks, {[], ticks.containers}, fn chunk, {due, containers} ->
        case containers do
          %{^chunk => container} ->
            {taken, rest} = take(container, stored, [])

            containers =
              if :gb_sets.is_empty(rest),
                do: Map.delete(containers, chunk),
                else: Map.put(containers, chunk, rest)

            {taken ++ due, containers}

          _ ->
            {due, containers}
        end
      end)

    {run, later} = due |> Enum.sort() |> Enum.split(@max_per_tick)

    containers =
      Enum.reduce(later, containers, fn {_, _, _, {x, _, z}, _} = entry, acc ->
        chunk = {Integer.floor_div(x, 16), Integer.floor_div(z, 16)}
        Map.update(acc, chunk, :gb_sets.singleton(entry), &:gb_sets.add(entry, &1))
      end)

    keys = for {_, _, _, position, block} <- run, do: {position, block}

    {keys,
     %{
       ticks
       | containers: containers,
         index: Map.drop(ticks.index, keys),
         journal: Enum.reduce(keys, ticks.journal, &Map.put(&2, &1, true))
     }}
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

  @doc "Continue at game tick `to` from game tick `from`: every due keeps its delay."
  def rebase(%__MODULE__{} = ticks, from, to), do: %{ticks | shift: ticks.shift + to - from}

  @doc """
  The section's records of its scheduled ticks: `{:tick, position, block}`
  keyed `{due, priority}` (dues relative to `{:ticks, :shift}`).
  """
  def records(%__MODULE__{index: index, shift: shift}) do
    for(
      {{pos, block}, {due, priority, _, _, _}} <- index,
      into: %{},
      do: {{:tick, pos, block}, {due, priority}}
    )
    |> Map.put({:ticks, :shift}, shift)
  end

  @doc """
  The records the journal touched since the last `settled/1`: each a value or
  `:deleted`, and the shift.
  """
  def changes(%__MODULE__{index: index, journal: journal, shift: shift}) do
    for({{pos, block} = key, _} <- journal, into: %{}) do
      case index do
        %{^key => {due, priority, _, _, _}} -> {{:tick, pos, block}, {due, priority}}
        _ -> {{:tick, pos, block}, :deleted}
      end
    end
    |> Map.put({:ticks, :shift}, shift)
  end

  @doc "The journal is in a frame (or a checkpoint): it starts over."
  def settled(%__MODULE__{journal: journal} = ticks) when map_size(journal) == 0, do: ticks
  def settled(%__MODULE__{} = ticks), do: %{ticks | journal: %{}}

  @doc "Persisted form: entries relative to `tick`, so they survive a restart."
  def dump(%__MODULE__{index: index, shift: shift}, tick),
    do:
      index
      |> Map.values()
      |> Enum.sort()
      |> Enum.map(fn {due, priority, _, position, block} ->
        {position, block, due + shift - tick, priority}
      end)

  @doc "Rebuild from `dump/2` at game tick `tick`."
  def load(entries, tick) when is_list(entries) do
    new()
    |> schedule_all(
      for {position, block, delay, priority} <- entries,
          do: {position, block, tick + delay, priority}
    )
    |> settled()
  end
end
