defmodule Valimc.World.ItemHandoffDelivery do
  @moduledoc "One bounded destination I/O attempt; the source retains its durable intent until receipt."
  alias Valimc.World
  alias Valimc.World.{ItemHandoffs, ItemMergeTransfer, Region}

  @doc "The owner job delivering region `key`'s outgoing ledger intent once."
  def work(key, ledger), do: fn -> deliver(key, ledger) end

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
         {:ok, owner} <- owner(request.destination),
         {:ok, result} when result in [:applied, :already_applied] <-
           Region.apply_item_handoff(owner, request),
         do: {:ok, request.sequence, digest}
  catch
    :exit, _ -> {:error, :item_handoff_uncertain}
  end

  # Another dimension's region (VMC-026c) is found, and loaded, in that dimension.
  defp owner({dimension, key} = destination) when is_atom(dimension) do
    if Valimc.Dimension.address?(destination),
      do: Valimc.Dimension.within(dimension, fn -> World.item_owner(key) end),
      else: {:error, :invalid_item_handoff}
  end

  defp owner(key), do: World.item_owner(key)
end
