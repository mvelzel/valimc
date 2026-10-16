defmodule Valimc.World.ItemReceipts do
  @moduledoc "Bounded player receipt slots; zero/zero reserves capacity without acknowledging a transfer."
  @max_sources 4096
  @max_sequence 18_446_744_073_709_551_615
  def max_sources, do: @max_sources

  def valid?(%{sequence: 0, digest: <<0::256>>}), do: true

  def valid?(%{sequence: sequence, digest: <<_::256>>}),
    do: is_integer(sequence) and sequence in 1..@max_sequence

  def valid?(_), do: false

  @doc "Persist a newly reserved slot before issuing a pickup permit; existing high-water marks stay exact."
  def reserve(receipts, <<_::128>> = source) when is_map(receipts) do
    case Map.fetch(receipts, source) do
      {:ok, receipt} ->
        if valid?(receipt),
          do: {:ok, receipts, :existing},
          else: {:error, :invalid_receipt_reservation}

      :error when map_size(receipts) < @max_sources ->
        {:ok, Map.put(receipts, source, %{sequence: 0, digest: <<0::256>>}), :reserved}

      :error ->
        {:error, :transfer_source_limit}
    end
  end

  def reserve(_, _), do: {:error, :invalid_receipt_reservation}
end
