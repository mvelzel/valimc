defmodule Valimc.World.MiningPermits do
  @moduledoc "Bounded owner-local block reservations; unrelated edits do not interrupt another miner."
  @limit 128
  @lifetime 10_000
  defstruct entries: %{}

  def reserve(%__MODULE__{} = permits, blocks, now)
      when is_map(blocks) and map_size(blocks) in 1..128 and is_integer(now) do
    entries = Map.reject(permits.entries, fn {_, entry} -> entry.expires <= now end)

    if map_size(entries) >= @limit do
      {:error, :mining_permit_limit}
    else
      token = :crypto.strong_rand_bytes(16)
      entry = %{blocks: blocks, expires: now + @lifetime}
      {:ok, %{permits | entries: Map.put(entries, token, entry)}, token}
    end
  end

  def reserve(_, _, _), do: {:error, :invalid_mining_reservation}

  def lookup(%__MODULE__{} = permits, token, now) do
    case permits.entries[token] do
      %{blocks: blocks, expires: expires} when expires > now -> {:ok, blocks}
      _ -> {:error, :stale_mining_permit}
    end
  end

  def remove(%__MODULE__{} = permits, token),
    do: %{permits | entries: Map.delete(permits.entries, token)}

  def invalidate(%__MODULE__{} = permits, edits) do
    entries =
      Map.reject(permits.entries, fn {_, entry} ->
        Enum.any?(entry.blocks, fn {position, _} -> Map.has_key?(edits, position) end)
      end)

    %{permits | entries: entries}
  end
end
