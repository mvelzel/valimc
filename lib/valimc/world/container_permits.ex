defmodule Valimc.World.ContainerPermits do
  @moduledoc "Bounded owner-local action grants bound to a canonical request digest."
  alias Valimc.World.ItemReceipts
  defstruct entries: %{}
  @limit 128
  @lifetime_ms 5000

  def issue(%__MODULE__{} = permits, receipts, request, digest, now)
      when is_integer(now) do
    permits = prune(permits, now)

    with %{
           source: <<_::128>> = source,
           permit: <<_::128>> = token,
           sequence: sequence,
           position: {_, _, _} = position
         } <-
           request,
         true <- is_integer(sequence) and sequence > 0,
         true <- is_binary(digest) and byte_size(digest) == 32,
         %{sequence: prior} = receipt <- Map.get(receipts, source),
         true <- ItemReceipts.valid?(receipt) and prior < sequence do
      cond do
        Map.has_key?(permits.entries, token) ->
          {:error, :container_permit_collision}

        Enum.any?(permits.entries, fn {_, entry} -> entry.source == source end) ->
          {:error, :container_already_pending}

        map_size(permits.entries) >= @limit ->
          {:error, :container_permits_full}

        true ->
          grant = %{
            source: source,
            position: position,
            sequence: sequence,
            digest: digest,
            expires: now + @lifetime_ms
          }

          {:ok, %{permits | entries: Map.put(permits.entries, token, grant)}}
      end
    else
      _ -> {:error, :invalid_container_permit}
    end
  end

  def issue(_, _, _, _, _), do: {:error, :invalid_container_permit}

  # The caller computes the canonical digest in a bounded worker. Consuming a
  # matching source token is irreversible even when its payload was altered.
  def consume(%__MODULE__{} = permits, request, digest, now) when is_integer(now) do
    permits = prune(permits, now)

    case request do
      %{source: source, permit: token, sequence: sequence} ->
        case permits.entries[token] do
          %{source: ^source} = grant ->
            next = %{permits | entries: Map.delete(permits.entries, token)}
            {next, grant.sequence == sequence and grant.digest == digest}

          _ ->
            {permits, false}
        end

      _ ->
        {permits, false}
    end
  end

  def consume(permits, _, _, _), do: {permits, false}

  def release(%__MODULE__{} = permits, token, source) do
    case permits.entries[token] do
      %{source: ^source} -> %{permits | entries: Map.delete(permits.entries, token)}
      _ -> permits
    end
  end

  def invalidate(%__MODULE__{} = permits, edits),
    do: %{
      permits
      | entries:
          Map.reject(permits.entries, fn {_, grant} -> Map.has_key?(edits, grant.position) end)
    }

  defp prune(permits, now),
    do: %{
      permits
      | entries: Map.reject(permits.entries, fn {_, grant} -> grant.expires <= now end)
    }
end
