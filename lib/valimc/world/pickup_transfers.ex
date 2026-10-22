defmodule Valimc.World.PickupTransfers do
  @moduledoc "Pure receipt-backed withdrawal; only the region's fresh permit can authorize eligibility."
  alias Valimc.Txn.Receipts
  alias Valimc.World.{Entities, PickupRequest}
  @scheme {:prefix, "VMCPICK-RESULT"}

  def plan(items, receipts, key, request, eligible) when is_boolean(eligible) do
    with {:ok, digest} <- PickupRequest.digest(key, request) do
      base = %{items: items, receipts: receipts, result: nil}

      case Receipts.classify(receipts, request.source, request.sequence, digest, @scheme) do
        {:duplicate, result} ->
          {:ok, %{base | result: result}}

        {:error, _} = error ->
          error

        :new ->
          {result, next} =
            case eligible && withdraw(items, key, request) do
              {:ok, next} -> {:applied, next}
              _ -> {:rejected, items}
            end

          receipts =
            Receipts.record(receipts, request.source, request.sequence, digest, @scheme, result)

          {:ok, %{base | items: next, result: result, receipts: receipts}}
      end
    end
  end

  def receipt_result(key, transfer, receipt) do
    with {:ok, digest} <- PickupRequest.digest(key, transfer),
         do: Receipts.outcome(receipt, transfer.sequence, digest, @scheme)
  end

  defp withdraw(items, key, request) do
    with {:ok, {epoch, id, revision}} <- Entities.find(items, request.item_uuid),
         entry = items.entries[id],
         true <-
           Valimc.World.region_key(Valimc.World.chunk_key(entry.entity.x, entry.entity.z)) == key,
         true <- entry.stack == request.before,
         true <- Entities.hops(items, request.item_uuid) == request.generation,
         true <- Map.get(Map.get(entry, :motion, %{}), :pickup_delay, 0) == 0 do
      if request.remainder == nil,
        do: Entities.remove(items, epoch, id, revision),
        else:
          with(
            {:ok, next, _} <- Entities.replace(items, epoch, id, revision, request.remainder),
            do: {:ok, next}
          )
    else
      _ -> {:error, :stale_pickup_item}
    end
  end
end
