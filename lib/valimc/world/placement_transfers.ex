defmodule Valimc.World.PlacementTransfers do
  @moduledoc "Typed terminal placement receipts; block mutation remains fenced by its owner."
  alias Valimc.Txn.Receipts
  alias Valimc.World.PlacementRequest
  @scheme {:prefix, "VMCPLACE-RESULT"}

  def plan(items, receipts, key, transfer, eligible) when is_boolean(eligible) do
    with {:ok, digest} <- PlacementRequest.digest(key, transfer) do
      base = %{
        source: transfer.source,
        sequence: transfer.sequence,
        digest: digest,
        permit: transfer.permit,
        expected: transfer.expected,
        edits: transfer.edits,
        items: items,
        receipts: receipts,
        result: nil
      }

      case Receipts.classify(receipts, transfer.source, transfer.sequence, digest, @scheme) do
        {:duplicate, result} ->
          {:ok, %{base | result: result}}

        {:error, _} = error ->
          error

        :new ->
          {:ok, finish(base, if(eligible, do: :applied, else: :rejected), items, receipts)}
      end
    end
  end

  def reject(%{result: :applied} = plan, items, receipts),
    do: finish(plan, :rejected, items, receipts)

  def receipt_result(key, transfer, receipt) do
    with {:ok, digest} <- PlacementRequest.digest(key, transfer),
         do: Receipts.outcome(receipt, transfer.sequence, digest, @scheme)
  end

  defp finish(plan, result, items, receipts) do
    receipts = Receipts.record(receipts, plan.source, plan.sequence, plan.digest, @scheme, result)
    %{plan | result: result, items: items, receipts: receipts}
  end
end
