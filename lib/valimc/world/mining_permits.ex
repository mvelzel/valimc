defmodule Valimc.World.MiningPermits do
  @moduledoc "Mining reservations in the owner's `Valimc.Txn.Permits`: the expected blocks, revoked by their edits."
  alias Valimc.Txn.Permits

  def reserve(%Permits{} = permits, blocks, now)
      when is_map(blocks) and map_size(blocks) in 1..128 and is_integer(now) do
    case Permits.issue(permits, :mining, nil, nil, Map.keys(blocks), blocks, now) do
      {:ok, permits, token} -> {:ok, permits, token}
      error -> error
    end
  end

  def reserve(_, _, _), do: {:error, :invalid_mining_reservation}

  def lookup(%Permits{} = permits, token, now) do
    case Permits.lookup(permits, :mining, token, now) do
      {:ok, blocks} -> {:ok, blocks}
      :error -> {:error, :stale_mining_permit}
    end
  end

  @doc "Extend only a still-live reservation; expired, mutated and released identities never revive."
  def renew(%Permits{} = permits, token, now) when is_integer(now) do
    case Permits.renew(permits, :mining, token, now) do
      {:ok, permits, blocks} -> {:ok, permits, blocks}
      :error -> {:error, :stale_mining_permit}
    end
  end
end
