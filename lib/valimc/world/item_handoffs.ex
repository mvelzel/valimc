defmodule Valimc.World.ItemHandoffs do
  @moduledoc """
  Pure bounded owner handoffs; callers persist each plan before publishing or
  delivering it.

  A handoff to another dimension's region (a portal, VMC-026c) names both ends
  absolutely, `{dimension, key}`: its records are in the destination's
  coordinates, and the destination keeps its receipt under the tagged source,
  apart from its own dimension's neighbours. Within a dimension keys stay
  plain, with their original bytes.
  """
  alias Valimc.Txn.Receipts
  alias Valimc.World.{ItemLedger, ItemRecords, Items}
  @max_sequence 18_446_744_073_709_551_615

  @doc "Withdraw a freshly fenced cohort into one durable destination intent."
  def depart(items, source, epoch, destination, steps) do
    cond do
      items.epoch != epoch -> Valimc.Error.retry(:stale_owner)
      items.ledger.outgoing != nil -> {:error, :item_handoff_busy}
      items.ledger.sequence == @max_sequence -> {:error, :item_handoff_sequence_limit}
      source == destination -> {:error, :invalid_item_handoff}
      crossing?(destination) and own?(destination) -> {:error, :invalid_item_handoff}
      true -> plan_departure(items, source, destination, steps)
    end
  end

  defp crossing?(key), do: Valimc.Dimension.address?(key)
  defp own?({dimension, _}), do: dimension == Valimc.Dimension.current()
  defp plain({_dimension, key}), do: key

  # The owner's own address for a handoff to `destination`.
  defp address(key, destination),
    do: if(crossing?(destination), do: {Valimc.Dimension.current(), key}, else: key)

  defp plan_departure(items, source, destination, steps) do
    # Steps of a crossing are in the destination's coordinates.
    region = if crossing?(destination), do: plain(destination), else: destination

    with {:ok, moved, handles} <- Items.advance(items, region, items.epoch, steps),
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
    source = address(source, ledger.outgoing.destination)
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
    if crossing?(destination) or crossing?(source),
      do: crossing_digest(source, sequence, destination, records, generations),
      else: plain_digest(source, sequence, destination, records, generations)
  end

  def digest(_, _), do: {:error, :invalid_item_handoff}

  defp plain_digest(source, sequence, destination, records, generations) do
    outgoing = %{destination: destination, records: records, generations: generations}
    ledger = %ItemLedger{sequence: sequence, outgoing: outgoing}

    with {:ok, bytes} <- ItemLedger.encode(source, [], %{}, ledger),
         do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  # A crossing's digest: both tagged ends in different dimensions, the
  # sequence, the records in the destination's coordinates and their hops.
  defp crossing_digest(
         {from, {sx, sz}} = source,
         sequence,
         {to, {dx, dz}} = destination,
         records,
         generations
       )
       when from != to do
    with true <- crossing?(source) and crossing?(destination),
         true <- is_integer(sequence) and sequence in 1..@max_sequence,
         true <- is_list(records) and length(Enum.take(records, 33)) in 1..32,
         true <- map_size(generations) == length(records),
         records = Enum.sort_by(records, & &1.uuid),
         true <- Enum.all?(records, &Map.has_key?(generations, &1.uuid)),
         {:ok, bytes} <- ItemRecords.encode({dx, dz}, records) do
      hops =
        generations |> Enum.sort() |> Enum.map(fn {uuid, hop} -> <<uuid::binary, hop::64>> end)

      {:ok,
       :crypto.hash(:sha256, [
         <<"VMCITRIP", 1, Valimc.Dimension.code(from), sx::signed-32, sz::signed-32, sequence::64,
           Valimc.Dimension.code(to), dx::signed-32, dz::signed-32, byte_size(bytes)::32>>,
         bytes,
         hops
       ])}
    else
      _ -> {:error, :invalid_item_handoff}
    end
  rescue
    _ -> {:error, :invalid_item_handoff}
  end

  defp crossing_digest(_, _, _, _, _), do: {:error, :invalid_item_handoff}

  @doc "Record adoption and its region receipt together; duplicate retries never recreate departed items."
  def accept(items, key, transfer) do
    destination = if is_map(transfer), do: Map.get(transfer, :destination)

    with {:ok, digest} <- digest(address(key, destination), transfer) do
      %{source: source, sequence: sequence} = transfer

      case Receipts.classify(items.ledger.incoming, source, sequence, digest, :plain) do
        {:error, :stale_transfer} ->
          {:error, :stale_item_handoff}

        {:duplicate, result} ->
          {:ok, items, result}

        {:error, :transfer_conflict} ->
          {:error, :item_handoff_conflict}

        {:error, :transfer_source_limit} ->
          {:error, :item_handoff_source_limit}

        :new ->
          with :ok <- unreserved(items, transfer.records),
               {:ok, next} <- adopt(items, key, transfer),
               incoming =
                 Receipts.record(next.ledger.incoming, source, sequence, digest, :plain, :applied),
               ledger = %{next.ledger | incoming: incoming},
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
