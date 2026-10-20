defmodule Valimc.World.PlacementPermits do
  @moduledoc "Placement fences in the owner's `Valimc.Txn.Permits`, separate from mining authority."
  alias Valimc.Txn.Permits

  def reserve(%Permits{} = permits, blocks, now)
      when is_map(blocks) and map_size(blocks) in 1..2 and is_integer(now) do
    case Permits.issue(permits, :placement, nil, nil, Map.keys(blocks), blocks, now) do
      {:ok, permits, token} -> {:ok, permits, token}
      error -> error
    end
  end

  def reserve(_, _, _), do: {:error, :invalid_placement_reservation}

  def lookup(%Permits{} = permits, token, now) do
    case Permits.lookup(permits, :placement, token, now) do
      {:ok, blocks} -> {:ok, blocks}
      :error -> {:error, :stale_placement_permit}
    end
  end
end
