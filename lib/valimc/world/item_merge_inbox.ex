defmodule Valimc.World.ItemMergeInbox do
  @moduledoc "Pure recipient update and terminal proof; an expired/stale contact rejects without granting."
  alias Valimc.ItemMotionState
  alias Valimc.World.{ItemLedger, ItemMergeTransfer, Items, OwnerItemReceipts}

  def apply(items, key, request, permitted) when is_boolean(permitted) do
    with true <- request.destination == key,
         {:ok, _} <- ItemMergeTransfer.digest(request) do
      prior = items.ledger.incoming[request.source]

      case ItemMergeTransfer.receipt_result(request, prior) do
        {:ok, result} ->
          {:ok, items, if(result == :applied, do: :already_applied, else: :already_rejected)}

        {:error, :stale_item_merge} = error ->
          error

        _ ->
          cond do
            not OwnerItemReceipts.valid?(prior) -> {:error, :item_merge_reservation_required}
            prior.sequence == request.sequence -> {:error, :item_merge_receipt_conflict}
            true -> plan(items, key, request, permitted)
          end
      end
    else
      _ -> {:error, :invalid_item_merge_transfer}
    end
  rescue
    _ -> {:error, :invalid_item_merge_transfer}
  end

  def apply(_, _, _, _), do: {:error, :invalid_item_merge_transfer}

  @doc "A one-shot owner-authorized counter effect moves no material and advances no transfer receipt."
  def counter_plan(items, key, request, true) do
    with true <- request.destination == key,
         {:ok, _} <- ItemMergeTransfer.digest(request),
         {:ok, next} <- update(items, key, request, true) do
      {:ok, next}
    else
      _ -> {:error, :item_merge_not_available}
    end
  rescue
    _ -> {:error, :item_merge_not_available}
  end

  def counter_plan(_, _, _, _), do: {:error, :item_merge_not_available}

  defp plan(items, key, request, permitted) do
    {next, result} =
      case if(permitted, do: update(items, key, request), else: :rejected) do
        {:ok, next} -> {next, :applied}
        _ -> {items, :rejected}
      end

    {:ok, proof} = ItemMergeTransfer.receipt(request, result)
    ledger = %{next.ledger | incoming: Map.put(next.ledger.incoming, request.source, proof)}

    with {:ok, _} <- ItemLedger.encode(key, Items.records(next), %{}, ledger),
         do: {:ok, %{next | ledger: ledger}, result}
  end

  defp update(items, key, request, counters_only \\ false) do
    with {:error, :missing_item} <- Items.find(items, request.donor.uuid),
         {:ok, {epoch, id, revision}} <- Items.find(items, request.recipient.uuid),
         current = items.entries[id],
         true <- current.stack == request.recipient.stack,
         true <-
           Map.get(items.ledger.generations, request.recipient.uuid, 0) ==
             request.recipient_generation,
         actual = record(current),
         {:ok, decision} <- ItemMergeTransfer.decision(%{request | recipient: actual}),
         true <-
           not counters_only or
             (decision.stack == current.stack and decision.donor_stack == request.donor.stack),
         {:ok, next, {^epoch, ^id, revision}} <-
           Items.replace(items, epoch, id, revision, decision.stack),
         {:ok, next, [_]} <-
           Items.advance(next, key, epoch, [
             %{
               id: id,
               revision: revision,
               position: {actual.x, actual.y, actual.z},
               motion: decision.motion
             }
           ]) do
      {:ok, next}
    else
      _ -> :rejected
    end
  end

  defp record(entry) do
    entry.entity
    |> Map.take([:uuid, :x, :y, :z])
    |> Map.put(:stack, entry.stack)
    |> Map.put(:motion, Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity}))
  end
end
