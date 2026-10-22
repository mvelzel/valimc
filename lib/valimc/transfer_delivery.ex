defmodule Valimc.TransferDelivery do
  @moduledoc "Bounded destination I/O jobs; source inventory/leases remain with their owners."
  alias Valimc.Txn.Operation
  alias Valimc.World

  @doc """
  Deliver `intent`'s pending outbox for player `uuid` to its destination
  section of `dimension` (the player's: it changes dimension only with no
  transfer pending, VMC-026b).
  """
  def start(owner, token, uuid, intent, dimension) do
    case Valimc.Txn.Delivery.start(
           owner,
           fn worker, token, result -> {:transfer_delivered, worker, token, result} end,
           fn -> deliver(uuid, intent, dimension) end,
           token: token
         ) do
      {:ok, job} -> {:ok, job}
      {:error, _} = error -> error
    end
  end

  defdelegate retryable?(result), to: Valimc.Error

  defdelegate completed?(snapshot, result), to: Valimc.Txn.Operation

  # One generic attempt: rebuild the pinned request, refuse an ephemeral
  # destination, deliver. The region may commit before this job sees its reply,
  # so an exit only ever leads to redelivering the same pinned intent.
  defp deliver(uuid, snapshot, dimension) do
    operation = Operation.of(snapshot)

    try do
      with {:ok, key, request, _digest} <- operation.request(uuid, snapshot),
           {:ok, owner} <- World.item_owner(World.section(dimension, key, :section)),
           :ok <- persistent_destination(operation, owner, uuid) do
        operation.apply(owner, request)
      end
    rescue
      _ -> {:error, operation.invalid()}
    catch
      :exit, _ -> Valimc.Error.retry(:region_restarting)
    end
  end

  defp persistent_destination(operation, owner, uuid) do
    case operation.receipt(owner, uuid) do
      {:ok, _} ->
        :ok

      {:error, missing} when missing in [:missing_transfer_receipt, :missing_container_receipt] ->
        :ok

      error ->
        error
    end
  end
end
