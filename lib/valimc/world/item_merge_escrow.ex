defmodule Valimc.World.ItemMergeEscrow do
  @moduledoc "Pure source withdrawal/receipt-backed return; the caller must persist before publication."
  alias Valimc.ItemMotionState
  alias Valimc.World.{ItemLedger, ItemMergeTransfer, Items}

  def prepare(items, key, epoch, request) do
    with true <- items.epoch == epoch and request.source == key,
         true <- items.ledger.outgoing == nil and request.sequence == items.ledger.sequence + 1,
         {:ok, {^epoch, id, revision}} <- Items.find(items, request.donor.uuid),
         entry = items.entries[id],
         true <- entry.stack == request.donor.stack,
         true <-
           Map.get(items.ledger.generations, request.donor.uuid, 0) == request.donor_generation,
         request = %{request | donor: record(entry)},
         {:ok, escrow} <- ItemMergeTransfer.escrow(request),
         {:ok, next} <- Items.remove(items, epoch, id, revision),
         next = %{next | ledger: %{next.ledger | sequence: request.sequence, outgoing: escrow}},
         true <- Items.return_capacity?(next),
         {:ok, _} <- ItemLedger.encode(key, Items.records(next), %{}, next.ledger) do
      {:ok, next}
    else
      _ -> {:error, :item_merge_not_prepared}
    end
  rescue
    _ -> {:error, :item_merge_not_prepared}
  end

  def finish(
        %{ledger: %{outgoing: %{kind: :merge, request: request}}} = items,
        key,
        sequence,
        proof
      ) do
    with true <- request.source == key and sequence == request.sequence,
         {:ok, result} <- ItemMergeTransfer.receipt_result(request, proof),
         {:ok, decision} <- ItemMergeTransfer.decision(request),
         stack = if(result == :rejected, do: request.donor.stack, else: decision.donor_stack),
         next = %{items | ledger: %{items.ledger | outgoing: nil}},
         {:ok, next} <- restore(next, key, request, stack),
         {:ok, _} <- ItemLedger.encode(key, Items.records(next), %{}, next.ledger) do
      {:ok, next, result}
    else
      _ -> {:error, :item_merge_proof_conflict}
    end
  end

  def finish(_, _, _, _), do: {:error, :item_merge_proof_conflict}

  defp restore(items, _, _, nil), do: {:ok, items}

  defp restore(items, key, request, stack) do
    generations =
      Map.put(items.ledger.generations, request.donor.uuid, request.donor_generation + 1)

    items = %{items | ledger: %{items.ledger | generations: generations}}

    case Items.create_record(items, key, %{request.donor | stack: stack}) do
      {:ok, next, _} -> {:ok, next}
      error -> error
    end
  end

  defp record(entry) do
    entry.entity
    |> Map.take([:uuid, :x, :y, :z])
    |> Map.put(:stack, entry.stack)
    |> Map.put(:motion, Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity}))
  end
end
