defmodule Valimc.World.CookingRuntime do
  @moduledoc "Bounded cooking activity and proposals; simulation runs on workers, never the owner."
  alias Valimc.Physics.CookingBlocks
  alias Valimc.World.{BlockBatch, Chunk, CookingBatch}

  defstruct enabled: false,
            job: nil,
            seen: nil,
            active: MapSet.new(),
            blocked: MapSet.new(),
            capacity: nil,
            retry_at: nil,
            dirty: false,
            # Bumped on every in-memory progress change; a durable frame that
            # carried the containers at this generation clears `dirty`.
            generation: 0,
            checkpoint_at: 0

  def capacity(items), do: {map_size(items.entries), items.bytes, items.ledger.outgoing}

  def due?(runtime, containers, edits, items, now) do
    runtime.seen != {containers, edits} or MapSet.size(runtime.active) > 0 or
      (MapSet.size(runtime.blocked) > 0 and retry?(runtime, items, now))
  end

  def selection(runtime, containers, edits, items, now) do
    cond do
      runtime.seen != {containers, edits} -> :all
      retry?(runtime, items, now) -> MapSet.union(runtime.active, runtime.blocked)
      true -> runtime.active
    end
  end

  defp retry?(runtime, items, now),
    do: runtime.retry_at == nil or now >= runtime.retry_at or capacity(items) != runtime.capacity

  def plan(containers, items, key, edits, selection, blocked) do
    blocks =
      for {position, %{cooking: _}} <- containers.entries,
          into: %{},
          do: {position, Chunk.block_at(edits, position)}

    selected =
      for {position, block} <- blocks,
          if(selection == :all,
            do: CookingBatch.awake?(containers.entries[position], block),
            else: MapSet.member?(selection, position)
          ),
          into: %{},
          do: {position, block}

    with {:ok, plan} <- CookingBatch.plan(containers, items, key, selected),
         real = Map.reject(plan.changes, fn {position, block} -> blocks[position] == block end),
         {:ok, batch} <- prepare(real) do
      active =
        for {position, block} <- selected,
            not Map.has_key?(plan.refused, position),
            awake_after?(
              plan.containers.entries[position],
              Map.get(real, position, block)
            ),
            into: MapSet.new(),
            do: position

      held =
        if selection == :all,
          do: MapSet.new(),
          else:
            blocked
            |> MapSet.difference(selection)
            |> MapSet.intersection(MapSet.new(Map.keys(blocks)))

      content =
        Enum.filter(plan.changed, fn position ->
          before = containers.entries[position]
          after_entry = plan.containers.entries[position]

          before.cooking.slots != after_entry.cooking.slots or
            before.recipes != after_entry.recipes
        end)

      {:ok,
       Map.merge(plan, %{
         expected: blocks,
         batch: batch,
         content: content,
         active: active,
         blocked: MapSet.union(held, MapSet.new(Map.keys(plan.refused)))
       })}
    end
  end

  def accepted(runtime, plan, containers, edits, items, now) do
    %{
      runtime
      | seen: {containers, edits},
        active: plan.active,
        blocked: plan.blocked,
        capacity: capacity(items),
        retry_at: if(map_size(plan.refused) > 0, do: now + 1000, else: runtime.retry_at)
    }
  end

  def lit_change?(original, replacement) do
    CookingBlocks.kind(original) != nil and
      Enum.any?([true, false], &(CookingBlocks.lit(original, &1) == {:ok, replacement}))
  end

  # A successful step leaves valid slots. Remaining heat must decrease next tick;
  # do not simulate that tick again just to rediscover the same active processor.
  defp awake_after?(%{cooking: %{burn_left: heat}}, _) when heat > 0, do: true
  defp awake_after?(entry, block), do: CookingBatch.awake?(entry, block)

  defp prepare(real) when map_size(real) == 0, do: {:ok, nil}
  defp prepare(real), do: BlockBatch.prepare(real)
end
