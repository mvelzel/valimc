defmodule Valimc.World.PlacementTransfers do
  @moduledoc "Typed terminal placement receipts; block mutation remains fenced by its owner."
  alias Valimc.World.{ItemRecords, PlacementRequest}
  @max_sources ItemRecords.max_sources()

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

      case receipts[transfer.source] do
        %{sequence: prior} when transfer.sequence < prior ->
          {:error, :stale_transfer}

        %{sequence: sequence} = receipt when sequence == transfer.sequence ->
          case outcome(digest, receipt.digest) do
            :applied -> {:ok, %{base | result: :already_applied}}
            :rejected -> {:ok, %{base | result: :already_rejected}}
            :conflict -> {:error, :transfer_conflict}
          end

        nil when map_size(receipts) >= @max_sources ->
          {:error, :transfer_source_limit}

        _ ->
          {:ok, finish(base, if(eligible, do: :applied, else: :rejected), items, receipts)}
      end
    end
  end

  def reject(%{result: :applied} = plan, items, receipts),
    do: finish(plan, :rejected, items, receipts)

  def receipt_result(key, transfer, %{sequence: sequence, digest: result}) do
    with {:ok, digest} <- PlacementRequest.digest(key, transfer),
         true <- sequence == transfer.sequence do
      case outcome(digest, result) do
        :conflict -> {:error, :transfer_conflict}
        value -> {:ok, value}
      end
    else
      false -> {:error, :stale_transfer}
      error -> error
    end
  end

  def receipt_result(_, _, _), do: {:error, :transfer_conflict}

  defp finish(plan, result, items, receipts) do
    receipt = %{sequence: plan.sequence, digest: result_digest(plan.digest, result)}
    %{plan | result: result, items: items, receipts: Map.put(receipts, plan.source, receipt)}
  end

  defp outcome(digest, actual) do
    cond do
      actual == result_digest(digest, :applied) -> :applied
      actual == result_digest(digest, :rejected) -> :rejected
      true -> :conflict
    end
  end

  defp result_digest(digest, result),
    do:
      :crypto.hash(:sha256, [
        "VMCPLACE-RESULT",
        if(result == :applied, do: <<1>>, else: <<0>>),
        digest
      ])
end
