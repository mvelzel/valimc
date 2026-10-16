defmodule Valimc.World.OwnerItemReceipts do
  @moduledoc "Regional source high-water marks shared by item handoffs and cross-owner merges."
  @limit 4096
  @maximum 18_446_744_073_709_551_615
  def reserve(receipts, source, destination)
      when is_map(receipts) and map_size(receipts) <= @limit do
    cond do
      not region?(source) or not region?(destination) or source == destination ->
        {:error, :invalid_item_receipt_source}

      valid?(receipts[source]) ->
        {:ok, receipts, :existing}

      Map.has_key?(receipts, source) ->
        {:error, :invalid_item_receipt}

      map_size(receipts) >= @limit ->
        {:error, :item_handoff_source_limit}

      true ->
        {:ok, Map.put(receipts, source, %{sequence: 0, digest: <<0::256>>}), :reserved}
    end
  end

  def reserve(_, _, _), do: {:error, :invalid_item_receipts}

  def valid?(%{sequence: 0, digest: <<0::256>>} = receipt), do: map_size(receipt) == 2

  def valid?(%{sequence: n, digest: <<_::256>>} = receipt)
      when is_integer(n) and n in 1..@maximum, do: map_size(receipt) == 2

  def valid?(_), do: false

  defp region?({x, z}),
    do:
      is_integer(x) and is_integer(z) and
        x in -2_147_483_648..2_147_483_647 and z in -2_147_483_648..2_147_483_647

  defp region?(_), do: false
end
