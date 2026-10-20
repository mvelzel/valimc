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

  @doc "Remove and return the ticks due at or before `tick`, in vanilla order."
  def take_due(%__MODULE__{} = ticks, tick, limit \\ @max_per_tick),
    do: take(ticks, tick, limit, [])

  defp take(ticks, _tick, 0, acc), do: {Enum.reverse(acc), ticks}

  defp take(ticks, tick, left, acc) do
    if :gb_sets.is_empty(ticks.queue) do
      {Enum.reverse(acc), ticks}
    else
      case :gb_sets.smallest(ticks.queue) do
        {due, _, _, position, block} = entry when due <= tick ->
          ticks = %{
            ticks
            | queue: :gb_sets.delete(entry, ticks.queue),
              index: Map.delete(ticks.index, {position, block})
          }

          take(ticks, tick, left - 1, [{position, block} | acc])

        _ ->
          {Enum.reverse(acc), ticks}
      end
    end
  end

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
