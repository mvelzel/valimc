defmodule Valimc.World.ContainerPermits do
  @moduledoc "Action grants in the owner's `Valimc.Txn.Permits`, bound to a canonical request digest."
  alias Valimc.Txn.Permits
  alias Valimc.World.ItemReceipts

  def issue(%Permits{} = permits, receipts, request, digest, now) when is_integer(now) do
    with %{
           source: <<_::128>> = source,
           permit: <<_::128>> = token,
           sequence: sequence,
           position: {_, _, _} = position
         } <- request,
         true <- is_integer(sequence) and sequence > 0,
         true <- is_binary(digest) and byte_size(digest) == 32,
         %{sequence: prior} = receipt <- Map.get(receipts, source),
         true <- ItemReceipts.valid?(receipt) and prior < sequence do
      grant = %{sequence: sequence, digest: digest}

      case Permits.issue(permits, :container, token, source, [position], grant, now) do
        {:ok, permits, _} -> {:ok, permits}
        {:error, :permit_collision} -> {:error, :container_permit_collision}
        error -> error
      end
    else
      _ -> {:error, :invalid_container_permit}
    end
  end

  def issue(_, _, _, _, _), do: {:error, :invalid_container_permit}

  @doc """
  Take the presented permit in the owner (irreversible even when the payload was
  altered); the grant goes to the planning worker, which checks `eligible?/3`.
  """
  def take(%Permits{} = permits, %{source: source, permit: token}, now),
    do: Permits.take(permits, :container, token, source, now)

  def take(permits, _, _), do: {permits, nil}

  def eligible?(%{sequence: sequence, digest: digest}, %{sequence: sequence}, digest), do: true
  def eligible?(_, _, _), do: false
end
