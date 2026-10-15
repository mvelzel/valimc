defmodule Valimc.World.MiningTransfers do
  @moduledoc "Internal mining inbox plans; delivery requires a durable, fenced player intent."
  alias Valimc.World.{ItemRecords, Items, MiningRecord}
  @max_sequence 18_446_744_073_709_551_615
  @max_sources ItemRecords.max_sources()

  def plan(items, receipts, key, transfer, eligible) when is_boolean(eligible) do
    with {:ok, digest} <- digest(key, transfer) do
      base = %{
        source: transfer.source,
        sequence: transfer.sequence,
        digest: digest,
        permit: transfer.permit,
        expected: transfer.expected,
        items: items,
        receipts: receipts,
        result: nil
      }

      case receipts[transfer.source] do
        %{sequence: prior} when transfer.sequence < prior ->
          {:error, :stale_transfer}

        %{sequence: sequence} = receipt when sequence == transfer.sequence ->
          case outcome(digest, receipt.digest) do
            :applied -> {:ok, %{base | result: :already_applied}}
            :rejected -> {:ok, %{base | result: :already_rejected}}
            :conflict -> {:error, :transfer_conflict}
          end

        nil when map_size(receipts) >= @max_sources ->
          {:error, :transfer_source_limit}

        _ ->
          if eligible do
            case add_items(items, key, transfer.records) do
              {:ok, next} -> {:ok, finish(base, :applied, next, receipts)}
              {:error, _} -> {:ok, finish(base, :rejected, items, receipts)}
            end
          else
            {:ok, finish(base, :rejected, items, receipts)}
          end
      end
    end
  end

  def reject(%{result: :applied} = plan, items, receipts),
    do: finish(plan, :rejected, items, receipts)

  def digest(key, %{
        source: <<_::128>> = source,
        sequence: sequence,
        permit: <<_::128>> = permit,
        expected: expected,
        records: records
      })
      when is_integer(sequence) and sequence in 1..@max_sequence and
             is_map(expected) and is_list(records) do
    records = records |> Enum.take(257) |> Enum.sort_by(fn %{uuid: uuid} -> uuid end)

    with {:ok, item_bytes} <- ItemRecords.encode(key, records),
         {:ok, body} <- MiningRecord.encode(key, expected, item_bytes) do
      {:ok, :crypto.hash(:sha256, ["VMCMINE-INBOX", source, <<sequence::64>>, permit, body])}
    else
      _ -> {:error, :invalid_mining_transfer}
    end
  rescue
    _ -> {:error, :invalid_mining_transfer}
  end

  def digest(_, _), do: {:error, :invalid_mining_transfer}

  def receipt_result(key, transfer, %{sequence: sequence, digest: result}) do
    with {:ok, digest} <- digest(key, transfer),
         true <- sequence == transfer.sequence do
      case outcome(digest, result) do
        :conflict -> {:error, :transfer_conflict}
        value -> {:ok, value}
      end
    else
      false -> {:error, :stale_transfer}
      error -> error
    end
  end

  defp finish(plan, result, items, receipts) do
    receipt = %{sequence: plan.sequence, digest: result_digest(plan.digest, result)}
    %{plan | result: result, items: items, receipts: Map.put(receipts, plan.source, receipt)}
  end

  defp outcome(digest, actual) do
    cond do
      actual == result_digest(digest, :applied) -> :applied
      actual == result_digest(digest, :rejected) -> :rejected
      true -> :conflict
    end
  end

  defp result_digest(digest, result),
    do:
      :crypto.hash(:sha256, [
        "VMCMINE-RESULT",
        if(result == :applied, do: <<1>>, else: <<0>>),
        digest
      ])

  defp add_items(items, key, records) do
    Enum.reduce_while(records, {:ok, items}, fn record, {:ok, current} ->
      case Items.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end
end
