defmodule Valimc.World.ItemMerges do
  @moduledoc "Atomic bounded same-owner merge plans; persist the result before publication."
  alias Valimc.{ItemMotionState, Physics.ItemMerge, World.Entities}

  @doc "Discover at most32 disjoint owned pairs off the owner; input is already bounded to256 items."
  def candidates(items) do
    items.entries
    |> Enum.sort_by(fn {_, entry} -> entry.entity.uuid end)
    |> Enum.filter(fn {_, entry} -> ItemMerge.eligible?(input(entry)) end)
    |> Enum.group_by(fn {_, entry} -> Valimc.Protocol.ItemStack.identity_key(entry.stack) end)
    |> Map.values()
    |> Enum.reduce_while([], fn group, pairs ->
      pairs = discover(group, pairs)
      if length(pairs) == 32, do: {:halt, pairs}, else: {:cont, pairs}
    end)
    |> Enum.reverse()
  end

  defp discover(_, pairs) when length(pairs) == 32, do: pairs
  defp discover([], pairs), do: pairs

  defp discover([{id, entry} | rest], pairs) do
    maximum = Valimc.Protocol.ItemStack.max_stack_size(entry.stack)

    case Enum.find(rest, fn {_, other} ->
           entry.stack.count + other.stack.count <= maximum and
             ItemMerge.near?(point(entry), point(other))
         end) do
      nil ->
        discover(rest, pairs)

      {other_id, other} ->
        pair = %{a: {id, entry.revision}, b: {other_id, other.revision}}

        discover(Enum.reject(rest, fn {candidate, _} -> candidate == other_id end), [pair | pairs])
    end
  end

  def plan(items, epoch, pairs) when is_list(pairs) do
    pairs = Enum.take(pairs, 33)

    with true <- items.epoch == epoch,
         true <- length(pairs) in 1..32,
         ids = Enum.flat_map(pairs, fn %{a: {a, _}, b: {b, _}} -> [a, b] end),
         true <- length(ids) == length(Enum.uniq(ids)) do
      Enum.reduce_while(pairs, {:ok, items, []}, fn pair, {:ok, current, changes} ->
        case merge(current, pair) do
          {:ok, next, change} -> {:cont, {:ok, next, [change | changes]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, next, changes} -> {:ok, next, Enum.reverse(changes)}
        error -> error
      end
    else
      _ -> {:error, :invalid_item_merges}
    end
  rescue
    _ -> {:error, :invalid_item_merges}
  end

  def plan(_, _, _), do: {:error, :invalid_item_merges}

  defp merge(items, %{a: {a, ar}, b: {b, br}}) do
    with %{revision: ^ar} = left <- items.entries[a],
         %{revision: ^br} = right <- items.entries[b],
         true <- ItemMerge.near?(point(left), point(right)),
         {:ok, decision} <- ItemMerge.pair(input(left), input(right)) do
      {rid, recipient, did, donor} =
        if decision.recipient == :a, do: {a, left, b, right}, else: {b, right, a, left}

      with {:ok, next, {epoch, ^rid, revision}} <-
             Entities.replace(items, items.epoch, rid, recipient.revision, decision.stack),
           {:ok, next, [recipient_handle]} <-
             Entities.advance(
               next,
               Valimc.World.region_key(
                 Valimc.World.chunk_key(recipient.entity.x, recipient.entity.z)
               ),
               epoch,
               [
                 %{
                   id: rid,
                   revision: revision,
                   position: point(recipient),
                   motion: decision.motion
                 }
               ]
             ),
           {:ok, next, donor_handle} <- donor(next, did, donor.revision, decision.donor_stack) do
        {:ok, next,
         %{
           recipient: recipient_handle,
           donor: donor_handle,
           removed: if(donor_handle == nil, do: did)
         }}
      end
    else
      nil -> {:error, :stale_item}
      false -> {:error, :items_not_near}
      %{revision: _} -> {:error, :stale_item}
      error -> error
    end
  end

  defp donor(items, id, revision, nil) do
    with {:ok, next} <- Entities.remove(items, items.epoch, id, revision), do: {:ok, next, nil}
  end

  defp donor(items, id, revision, stack),
    do: Entities.replace(items, items.epoch, id, revision, stack)

  # Persisted item records currently have no exclusive pickup target. Targeted
  # lifecycle support must retain that authority before entering this planner.
  defp input(entry),
    do: %{
      stack: entry.stack,
      motion: Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity}),
      target: nil,
      alive: true
    }

  defp point(entry), do: {entry.entity.x, entry.entity.y, entry.entity.z}
end
