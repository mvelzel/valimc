defmodule Valimc.Entity.ItemMerges do
  @moduledoc "Atomic bounded same-owner merge plans; persist the result before publication."
  alias Valimc.Entity.ItemMotionState
  alias Valimc.{Entity.ItemMerge, Entity.Store}

  @doc "Discover at most32 disjoint owned pairs off the owner; input is already bounded to256 items."
  def candidates(items) do
    items.entries
    |> Enum.filter(fn {_, entry} -> entry.kind == :item and ItemMerge.eligible?(input(entry)) end)
    |> Enum.sort_by(fn {_, entry} -> entry.entity.uuid end)
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
    with %{kind: :item, revision: ^ar} = left <- items.entries[a],
         %{kind: :item, revision: ^br} = right <- items.entries[b],
         true <- ItemMerge.near?(point(left), point(right)),
         {:ok, decision} <- ItemMerge.pair(input(left), input(right)) do
      {rid, recipient, did, donor} =
        if decision.recipient == :a, do: {a, left, b, right}, else: {b, right, a, left}

      with {:ok, next, {epoch, ^rid, revision}} <-
             Store.replace(items, items.epoch, rid, recipient.revision, decision.stack),
           {:ok, next, [recipient_handle]} <-
             Store.advance(
               next,
               Valimc.Data.Grid.region_key(
                 Valimc.Data.Grid.chunk_key(recipient.entity.x, recipient.entity.z)
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

  @doc """
  Merge an item handed over by a neighbouring owner into its `target` here
  (VMC-077h), as vanilla merges two items: `:error` when the target is gone,
  moved away or no longer takes the whole donor.
  """
  def absorb(items, key, target, %{kind: :item, x: x, y: y, z: z, stack: stack} = donor) do
    motion = Map.get(donor, :motion, %ItemMotionState{no_gravity: true})
    input = %{stack: stack, motion: motion, target: nil, alive: true}

    with {:ok, {epoch, id, revision}} <- Store.find(items, target),
         %{kind: :item} = entry <- items.entries[id],
         true <- ItemMerge.near?(point(entry), {x, y, z}),
         {:ok, %{recipient: :b, donor_stack: nil} = decision} <-
           ItemMerge.pair(input, input(entry)),
         {:ok, next, {^epoch, ^id, revision}} <-
           Store.replace(items, epoch, id, revision, decision.stack),
         {:ok, next, _} <-
           Store.advance(next, key, epoch, [
             %{id: id, revision: revision, position: point(entry), motion: decision.motion}
           ]) do
      {:ok, next}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def absorb(_, _, _, _), do: :error

  defp donor(items, id, revision, nil) do
    with {:ok, next} <- Store.remove(items, items.epoch, id, revision), do: {:ok, next, nil}
  end

  defp donor(items, id, revision, stack),
    do: Store.replace(items, items.epoch, id, revision, stack)

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
