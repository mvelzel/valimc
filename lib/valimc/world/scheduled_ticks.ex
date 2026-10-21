defmodule Valimc.World.ScheduledTicks do
  @moduledoc """
  A region's scheduled block ticks (VMC-066), ordered like vanilla `LevelTicks`:
  by trigger game tick, then priority (lower first), then scheduling order. A
  (position, block) pair is scheduled at most once; a due tick runs only if the
  block at its position still matches. Bounded per region.
  """

  @limit 65_536
  @max_per_tick 65_536

  defstruct queue: :gb_sets.empty(), index: %{}, sequence: 0

  def new, do: %__MODULE__{}
  def size(%__MODULE__{index: index}), do: map_size(index)

  def scheduled?(%__MODULE__{index: index}, position, block),
    do: Map.has_key?(index, {position, block})

  @doc "Schedule `block` at `position` for game tick `due` (no-op if already scheduled)."
  def schedule(%__MODULE__{} = ticks, position, block, due, priority \\ 0)
      when is_integer(due) and is_integer(priority) do
    cond do
      Map.has_key?(ticks.index, {position, block}) ->
        {:ok, ticks}

      map_size(ticks.index) >= @limit ->
        {:error, :scheduled_tick_limit}

      true ->
        entry = {due, priority, ticks.sequence, position, block}

        {:ok,
         %{
           ticks
           | queue: :gb_sets.add(entry, ticks.queue),
             index: Map.put(ticks.index, {position, block}, entry),
             sequence: ticks.sequence + 1
         }}
    end
  end

  @doc """
  Remove and return the ticks due at or before `tick` whose position passes
  `ticking?` (a chunk that ticks), in vanilla order; the others stay due.
  """
  def take_due(%__MODULE__{} = ticks, tick, ticking? \\ fn _ -> true end),
    do: take(ticks, tick, ticking?, @max_per_tick, [], [])

  defp take(ticks, _tick, _ticking?, 0, acc, waiting), do: done(ticks, acc, waiting)

  defp take(ticks, tick, ticking?, left, acc, waiting) do
    with false <- :gb_sets.is_empty(ticks.queue),
         {due, _, _, position, block} = entry when due <= tick <- :gb_sets.smallest(ticks.queue) do
      queue = :gb_sets.delete(entry, ticks.queue)

      if ticking?.(position) do
        ticks = %{ticks | queue: queue, index: Map.delete(ticks.index, {position, block})}
        take(ticks, tick, ticking?, left - 1, [{position, block} | acc], waiting)
      else
        take(%{ticks | queue: queue}, tick, ticking?, left, acc, [entry | waiting])
      end
    else
      _ -> done(ticks, acc, waiting)
    end
  end

  defp done(ticks, acc, waiting),
    do: {Enum.reverse(acc), %{ticks | queue: Enum.reduce(waiting, ticks.queue, &:gb_sets.add/2)}}

  @doc "Persisted form: entries relative to `tick`, so they survive a restart."
  def dump(%__MODULE__{queue: queue}, tick),
    do:
      for(
        {due, priority, _, position, block} <- :gb_sets.to_list(queue),
        do: {position, block, due - tick, priority}
      )

  @doc "Rebuild from `dump/2` at game tick `tick`."
  def load(entries, tick) when is_list(entries) do
    Enum.reduce(entries, new(), fn {position, block, delay, priority}, acc ->
      case schedule(acc, position, block, tick + delay, priority) do
        {:ok, next} -> next
        {:error, _} -> acc
      end
    end)
  end
end
