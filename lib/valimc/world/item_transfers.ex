defmodule Valimc.World.ItemTransfers do
  @moduledoc "Pure region inbox plans. Callers must enforce a durable, fenced source outbox."
  alias Valimc.World.{ItemRecords, Items}
  @max_batch 5
  @max_sequence 18_446_744_073_709_551_615
  @max_sources ItemRecords.max_sources()

  def plan(items, receipts, key, %{source: <<_::128>> = source, sequence: sequence} = transfer)
      when is_integer(sequence) and sequence in 1..@max_sequence do
    with {:ok, digest} <- digest(key, transfer) do
      case receipts[source] do
        %{sequence: prior} when sequence < prior ->
          {:error, :stale_transfer}

        %{sequence: ^sequence, digest: ^digest} ->
          {:ok, items, receipts, :already_applied}

        %{sequence: ^sequence} ->
          {:error, :transfer_conflict}

        nil when map_size(receipts) >= @max_sources ->
          {:error, :transfer_source_limit}

        _ ->
          with {:ok, next} <- add_items(items, key, transfer.records) do
            receipt = %{sequence: sequence, digest: digest}
            {:ok, next, Map.put(receipts, source, receipt), :applied}
          end
      end
    end
  end

  def plan(_, _, _, _), do: {:error, :invalid_transfer}

  def digest(key, %{source: <<_::128>> = source, sequence: sequence, records: records})
      when is_integer(sequence) and sequence in 1..@max_sequence and is_list(records) do
    records = Enum.take(records, @max_batch + 1)

    if length(records) in 1..@max_batch do
      with {:ok, bytes} <-
             ItemRecords.encode(key, Enum.sort_by(records, fn %{uuid: uuid} -> uuid end)) do
        {:ok, :crypto.hash(:sha256, [<<source::binary, sequence::64>>, bytes])}
      else
        _ -> {:error, :invalid_transfer}
      end
    else
      {:error, :invalid_transfer}
    end
  rescue
    _ -> {:error, :invalid_transfer}
  end

  def digest(_, _), do: {:error, :invalid_transfer}

  defp add_items(items, key, records) do
    Enum.reduce_while(records, {:ok, items}, fn record, {:ok, current} ->
      case Items.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end
end
