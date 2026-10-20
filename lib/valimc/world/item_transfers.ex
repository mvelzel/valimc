defmodule Valimc.World.ItemTransfers do
  @moduledoc "Pure region inbox plans. Callers must enforce a durable, fenced source outbox."
  alias Valimc.Txn.Receipts
  alias Valimc.World.{ItemRecords, Items}
  @max_batch 5
  @max_sequence 18_446_744_073_709_551_615

  def plan(items, receipts, key, %{source: <<_::128>> = source, sequence: sequence} = transfer)
      when is_integer(sequence) and sequence in 1..@max_sequence do
    with {:ok, digest} <- digest(key, transfer) do
      case Receipts.classify(receipts, source, sequence, digest, :plain) do
        {:duplicate, result} ->
          {:ok, items, receipts, result}

        {:error, _} = error ->
          error

        :new ->
          with {:ok, next} <- add_items(items, key, transfer.records) do
            {:ok, next, Receipts.record(receipts, source, sequence, digest, :plain, :applied),
             :applied}
          end
      end
    end
  end

  def plan(_, _, _, _), do: {:error, :invalid_transfer}

  def digest(key, transfer) do
    with {:ok, _bytes, digest} <- encode_request(key, transfer), do: {:ok, digest}
  end

  def encode_request(key, %{source: <<_::128>> = source, sequence: sequence, records: records})
      when is_integer(sequence) and sequence in 1..@max_sequence and is_list(records) do
    records = Enum.take(records, @max_batch + 1)

    if length(records) in 1..@max_batch do
      with {:ok, bytes} <-
             ItemRecords.encode(key, Enum.sort_by(records, fn %{uuid: uuid} -> uuid end)) do
        {:ok, bytes, :crypto.hash(:sha256, [<<source::binary, sequence::64>>, bytes])}
      else
        _ -> {:error, :invalid_transfer}
      end
    else
      {:error, :invalid_transfer}
    end
  rescue
    _ -> {:error, :invalid_transfer}
  end

  def encode_request(_, _), do: {:error, :invalid_transfer}

  defp add_items(items, key, records) do
    Enum.reduce_while(records, {:ok, items}, fn record, {:ok, current} ->
      case Items.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end
end
