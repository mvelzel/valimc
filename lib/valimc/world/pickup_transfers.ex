defmodule Valimc.World.PickupTransfers do
  @moduledoc "Pure receipt-backed withdrawal; only the region's fresh permit can authorize eligibility."
  alias Valimc.World.{ItemRecords, Items, PickupRequest}
  @max_sources ItemRecords.max_sources()

  def plan(items, receipts, key, request, eligible) when is_boolean(eligible) do
    with {:ok, digest} <- PickupRequest.digest(key, request) do
      base = %{items: items, receipts: receipts, result: nil}

      case receipts[request.source] do
        %{sequence: prior} when request.sequence < prior ->
          {:error, :stale_transfer}

        %{sequence: sequence} = receipt when sequence == request.sequence ->
          case outcome(digest, receipt.digest) do
            :applied -> {:ok, %{base | result: :already_applied}}
            :rejected -> {:ok, %{base | result: :already_rejected}}
            :conflict -> {:error, :transfer_conflict}
          end

        nil when map_size(receipts) >= @max_sources ->
          {:error, :transfer_source_limit}

        _ ->
          {result, next} =
            case eligible && withdraw(items, key, request) do
              {:ok, next} -> {:applied, next}
              _ -> {:rejected, items}
            end

          receipt = %{sequence: request.sequence, digest: result_digest(digest, result)}

          {:ok,
           %{
             base
             | items: next,
               result: result,
               receipts: Map.put(receipts, request.source, receipt)
           }}
      end
    end
  end

  def receipt_result(key, request, %{sequence: sequence, digest: actual}) do
    with {:ok, digest} <- PickupRequest.digest(key, request),
         true <- sequence == request.sequence do
      case outcome(digest, actual) do
        :conflict -> {:error, :transfer_conflict}
        result -> {:ok, result}
      end
    else
      false -> {:error, :stale_transfer}
      error -> error
    end
  end

  def receipt_result(_, _, _), do: {:error, :transfer_conflict}

  defp withdraw(items, key, request) do
    with {:ok, {epoch, id, revision}} <- Items.find(items, request.item_uuid),
         entry = items.entries[id],
         true <-
           Valimc.World.region_key(Valimc.World.chunk_key(entry.entity.x, entry.entity.z)) == key,
         true <- entry.stack == request.before,
         true <- Map.get(items.ledger.generations, request.item_uuid, 0) == request.generation,
         true <- Map.get(Map.get(entry, :motion, %{}), :pickup_delay, 0) == 0 do
      if request.remainder == nil,
        do: Items.remove(items, epoch, id, revision),
        else:
          with(
            {:ok, next, _} <- Items.replace(items, epoch, id, revision, request.remainder),
            do: {:ok, next}
          )
    else
      _ -> {:error, :stale_pickup_item}
    end
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
        "VMCPICK-RESULT",
        if(result == :applied, do: <<1>>, else: <<0>>),
        digest
      ])
end
