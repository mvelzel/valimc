defmodule Valimc.World.ItemHandoffDelivery do
  @moduledoc "One bounded destination I/O attempt; the source retains its durable intent until receipt."
  alias Valimc.World
  alias Valimc.World.{ItemHandoffs, ItemMergeTransfer, Region}

  def start(owner, epoch, token, key, ledger) do
    case Valimc.Txn.Delivery.start(
           owner,
           fn worker, token, result ->
             {:resource, epoch, {:item_handoff_delivered, worker, token, result}}
           end,
           fn -> deliver(key, ledger) end,
           token: token,
           link: true
         ) do
      {:ok, job} -> {:ok, job.pid, job.monitor}
      {:error, _} -> {:error, :item_handoff_workers_busy}
    end
  end

  defp deliver(key, %{outgoing: %{kind: :merge, request: request}}) do
    with true <- request.source == key,
         {:ok, owner} <- World.item_owner(request.destination),
         {:ok, result} when result in [:applied, :already_applied, :rejected, :already_rejected] <-
           Region.apply_item_merge(owner, request),
         {:ok, {destination, proof}} when destination == request.destination <-
           Region.owner_item_receipt(owner, key),
         {:ok, _} <- ItemMergeTransfer.receipt_result(request, proof),
         do: {:ok, request.sequence, {:item_merge, proof}}
  catch
    :exit, _ -> {:error, :item_handoff_uncertain}
  end

  defp deliver(key, ledger) do
    with {:ok, request} <- ItemHandoffs.request(%{ledger: ledger}, key),
         {:ok, digest} <- ItemHandoffs.digest(request.destination, request),
         {:ok, owner} <- World.item_owner(request.destination),
         {:ok, result} when result in [:applied, :already_applied] <-
           Region.apply_item_handoff(owner, request),
         do: {:ok, request.sequence, digest}
  catch
    :exit, _ -> {:error, :item_handoff_uncertain}
  end
end
