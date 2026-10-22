defmodule Valimc.World.OwnerItemReceipts do
  @moduledoc "Regional source high-water marks shared by item handoffs and cross-owner merges."
  def reserve(receipts, source, destination)
      when is_map(receipts) and map_size(receipts) <= 4096 do
    cond do
      not region?(source) or not region?(destination) or source == destination ->
        {:error, :invalid_item_receipt_source}

      Map.has_key?(receipts, source) and not valid?(receipts[source]) ->
        {:error, :invalid_item_receipt}

      true ->
        Valimc.Txn.Receipts.reserve(receipts, source)
    end
  end

  def reserve(_, _, _), do: {:error, :invalid_item_receipts}

  def valid?(receipt) when is_map(receipt),
    do: map_size(receipt) == 2 and Valimc.Txn.Receipts.valid?(receipt)

  def valid?(_), do: false

  defp region?({x, z}),
    do:
      is_integer(x) and is_integer(z) and
        x in -2_147_483_648..2_147_483_647 and z in -2_147_483_648..2_147_483_647

  defp region?(_), do: false
end
