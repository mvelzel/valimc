defmodule Valimc.World.ItemHandoffs do
  @moduledoc "Pure bounded owner handoffs; callers persist each plan before publishing or delivering it."
  alias Valimc.World.{ItemLedger, Items}
  @max_sequence 18_446_744_073_709_551_615

  @doc "Withdraw a freshly fenced cohort into one durable destination intent."
  def depart(items, source, epoch, destination, steps) do
    cond do
      items.epoch != epoch -> {:error, :stale_region}
      items.ledger.outgoing != nil -> {:error, :item_handoff_busy}
      items.ledger.sequence == @max_sequence -> {:error, :item_handoff_sequence_limit}
      source == destination -> {:error, :invalid_item_handoff}
      true -> plan_departure(items, source, destination, steps)
    end
  end

  defp plan_departure(items, source, destination, steps) do
    with {:ok, moved, handles} <- Items.advance(items, destination, items.epoch, steps),
         {:ok, withdrawn} <- withdraw(moved, handles) do
      uuids = MapSet.new(handles, fn {_, id, _} -> moved.entries[id].entity.uuid end)
      records = moved |> Items.records() |> Enum.filter(&MapSet.member?(uuids, &1.uuid))
      hops = Map.new(records, &{&1.uuid, Map.get(items.ledger.generations, &1.uuid, 0) + 1})
      outgoing = %{destination: destination, records: records, generations: hops}

      next = %{
        withdrawn
        | ledger: %{withdrawn.ledger | sequence: items.ledger.sequence + 1, outgoing: outgoing}
      }

      with {:ok, _} <- ItemLedger.encode(source, Items.records(next), %{}, next.ledger),
           {:ok, transfer} <- request(next, source),
           do: {:ok, next, transfer}
    end
  end

  defp withdraw(items, handles) do
    Enum.reduce_while(handles, {:ok, items}, fn {epoch, id, revision}, {:ok, current} ->
      case Items.remove(current, epoch, id, revision) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Reconstruct the same delivery after recovery; runtime handles never enter its digest."
  def request(%{ledger: %{outgoing: nil}}, _), do: {:error, :missing_item_handoff}

  def request(%{ledger: %{outgoing: %{kind: :merge}}}, _), do: {:error, :not_item_handoff}

  def request(%{ledger: ledger}, source) do
    transfer = Map.merge(ledger.outgoing, %{source: source, sequence: ledger.sequence})
    with {:ok, _} <- digest(transfer.destination, transfer), do: {:ok, transfer}
  end

  def digest(
        destination,
        %{
          source: source,
          sequence: sequence,
          destination: destination,
          records: records,
          generations: generations
        } = transfer
      )
      when map_size(transfer) == 5 do
    outgoing = %{destination: destination, records: records, generations: generations}
    ledger = %ItemLedger{sequence: sequence, outgoing: outgoing}

    with {:ok, bytes} <- ItemLedger.encode(source, [], %{}, ledger),
         do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  def digest(_, _), do: {:error, :invalid_item_handoff}

  @doc "Record adoption and its region receipt together; duplicate retries never recreate departed items."
  def accept(items, key, transfer) do
    with {:ok, digest} <- digest(key, transfer) do
      %{source: source, sequence: sequence} = transfer

      case items.ledger.incoming[source] do
        %{sequence: prior} when sequence < prior ->
          {:error, :stale_item_handoff}

        %{sequence: ^sequence, digest: ^digest} ->
          {:ok, items, :already_applied}

        %{sequence: ^sequence} ->
          {:error, :item_handoff_conflict}

        nil when map_size(items.ledger.incoming) >= 4096 ->
          {:error, :item_handoff_source_limit}

        _ ->
          with :ok <- unreserved(items, transfer.records),
               {:ok, next} <- adopt(items, key, transfer),
               ledger = %{
                 next.ledger
                 | incoming:
                     Map.put(next.ledger.incoming, source, %{sequence: sequence, digest: digest})
               },
               {:ok, _} <- ItemLedger.encode(key, Items.records(next), %{}, ledger),
               do: {:ok, %{next | ledger: ledger}, :applied}
      end
    end
  end

  # A returning item can arrive before the earlier outgoing acknowledgement was
  # cleared. Retry after clearance; the owner stays free to process that ack.
  defp unreserved(%{ledger: %{outgoing: nil}}, _), do: :ok

  defp unreserved(items, records) do
    if not Enum.any?(records, &Items.reserved_uuid?(items, &1.uuid)),
      do: :ok,
      else: {:error, :item_handoff_busy}
  end

  defp adopt(items, key, transfer) do
    ledger = %{
      items.ledger
      | generations: Map.merge(items.ledger.generations, transfer.generations)
    }

    Enum.reduce_while(transfer.records, {:ok, %{items | ledger: ledger}}, fn record,
                                                                             {:ok, current} ->
      case Items.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Clear only the acknowledged intent, retaining sequence, incoming receipts and unrelated motion."
  def finish(items, key, sequence, digest) do
    with {:ok, transfer} <- request(items, key),
         true <- transfer.sequence == sequence,
         {:ok, ^digest} <- digest(transfer.destination, transfer) do
      {:ok, %{items | ledger: %{items.ledger | outgoing: nil}}}
    else
      _ -> {:error, :stale_item_handoff}
    end
  end
end
