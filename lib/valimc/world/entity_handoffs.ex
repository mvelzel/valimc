defmodule Valimc.World.EntityHandoffs do
  @moduledoc """
  One handoff of entities between owners (VMC-077h), for every kind. Pure:
  callers persist each plan before publishing or delivering it.

  The source withdraws a cohort into one durable outgoing intent; the
  destination adopts it and keeps its receipt, per source, in the same frame;
  the source clears the intent once that receipt is durable. Records keep their
  uuid, kind and hops and, within one VM, their network id, which never enters
  the digest (a recovered intent delivers without it).

  A merge handoff (`merge: target uuid`) carries one item that the
  destination merges into its target on arrival or rejects: a cross-region
  merge is the donor handed over, then merged locally. A rejected donor returns
  to the source when it clears.

  A handoff to another dimension's region (a portal, VMC-026c) names both ends
  absolutely, `{dimension, key}`: its records are in the destination's
  coordinates, and the destination keeps its receipt under the tagged source.
  """
  alias Valimc.Txn.Receipts
  alias Valimc.World.{Entities, ItemMerges}

  @max_records 32
  @scheme {:prefix, "VMCHANDOFF"}

  @doc "Withdraw a freshly fenced cohort, moved by `steps`, into one durable destination intent."
  def depart(items, source, epoch, destination, steps) do
    # Steps of a crossing are in the destination's coordinates.
    region = if crossing?(destination), do: plain(destination), else: destination

    with :ok <- departable(items, source, epoch, destination),
         {:ok, moved, handles} <- Entities.advance(items, region, items.epoch, steps),
         {:ok, next, records} <- Entities.withdraw(moved, handles),
         do: intent(next, source, %{destination: destination, records: records, merge: nil})
  end

  @doc "Withdraw the item `{id, revision}` to merge into `target` in the neighbouring `destination`."
  def depart_merge(items, source, epoch, {id, revision}, destination, target) do
    with :ok <- departable(items, source, epoch, destination),
         false <- crossing?(destination),
         %{kind: :item} <- items.entries[id],
         {:ok, next, records} <- Entities.withdraw(items, [{epoch, id, revision}]) do
      intent(next, source, %{destination: destination, records: records, merge: target})
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_item_handoff}
    end
  end

  @doc """
  New entities at one position (a cooking award's orbs): created here, or
  handed over to the owner of their position in one intent.
  """
  def spawn(items, key, [%{x: x, z: z} | _] = records) when length(records) <= @max_records do
    case Valimc.World.region_key(Valimc.World.chunk_key(x, z)) do
      ^key ->
        create(items, key, records)

      destination ->
        with :ok <- departable(items, key, items.epoch, destination),
             {:ok, next, _} <-
               intent(items, key, %{destination: destination, records: records, merge: nil}),
             do: {:ok, next}
    end
  end

  defp departable(items, source, epoch, destination) do
    cond do
      items.epoch != epoch -> Valimc.Error.retry(:stale_owner)
      items.ledger.outgoing != nil -> {:error, :item_handoff_busy}
      source == destination -> {:error, :invalid_item_handoff}
      crossing?(destination) and own?(destination) -> {:error, :invalid_item_handoff}
      true -> :ok
    end
  end

  defp intent(items, source, outgoing) do
    next = %{
      items
      | ledger: %{items.ledger | sequence: items.ledger.sequence + 1, outgoing: outgoing}
    }

    with {:ok, transfer} <- request(next, source), do: {:ok, next, transfer}
  end

  defp crossing?(key), do: Valimc.Dimension.address?(key)
  defp own?({dimension, _}), do: dimension == Valimc.Dimension.current()
  defp plain({_dimension, key}), do: key

  # The owner's own address for a handoff to or from `other`.
  defp address(key, other),
    do: if(crossing?(other), do: {Valimc.Dimension.current(), key}, else: key)

  @doc "The delivery of the outgoing intent, the same after recovery."
  def request(%{ledger: %{outgoing: nil}}, _), do: {:error, :missing_item_handoff}

  def request(%{ledger: %{sequence: sequence, outgoing: outgoing}}, source) do
    transfer =
      Map.merge(outgoing, %{source: address(source, outgoing.destination), sequence: sequence})

    with {:ok, _} <- digest(transfer), do: {:ok, transfer}
  end

  @doc "A transfer's digest: both ends, its sequence, merge target and records, never network ids."
  def digest(
        %{source: source, sequence: sequence, destination: destination, records: records} =
          transfer
      )
      when map_size(transfer) == 5 and is_integer(sequence) and sequence > 0 and
             is_list(records) do
    merge = Map.get(transfer, :merge, :missing)

    if ends?(source, destination) and
         length(Enum.take(records, @max_records + 1)) in 1..@max_records and
         Enum.all?(records, &match?(%{uuid: <<_::128>>}, &1)) and
         (merge == nil or (match?(<<_::128>>, merge) and length(records) == 1)) do
      records = records |> Enum.map(&Map.delete(&1, :entity_id)) |> Enum.sort_by(& &1.uuid)
      body = {source, sequence, destination, merge, records}
      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(body, [:deterministic]))}
    else
      {:error, :invalid_item_handoff}
    end
  end

  def digest(_), do: {:error, :invalid_item_handoff}

  # Plain region keys within a dimension; tagged ends of different dimensions across.
  defp ends?({from, source}, {to, destination}) when is_atom(from) and is_atom(to),
    do: from != to and crossing?({from, source}) and crossing?({to, destination})

  defp ends?(source, destination),
    do: region?(source) and region?(destination) and source != destination

  defp region?({x, z}), do: is_integer(x) and is_integer(z)
  defp region?(_), do: false

  @doc """
  Adopt a handoff and record its receipt together: `{:ok, items, result}`, a
  retry answering the recorded result without adopting again.
  """
  def accept(items, key, transfer) do
    destination = if is_map(transfer), do: Map.get(transfer, :destination)

    with true <- destination != nil and destination == address(key, destination),
         {:ok, digest} <- digest(transfer) do
      %{source: source, sequence: sequence} = transfer

      case Receipts.classify(items.ledger.incoming, source, sequence, digest, @scheme) do
        {:error, :stale_transfer} ->
          {:error, :stale_item_handoff}

        {:duplicate, result} ->
          {:ok, items, result}

        {:error, :transfer_conflict} ->
          {:error, :item_handoff_conflict}

        :new ->
          with :ok <- unreserved(items, transfer.records),
               {:ok, next, result} <- place(items, key, transfer) do
            incoming =
              Receipts.record(next.ledger.incoming, source, sequence, digest, @scheme, result)

            {:ok, %{next | ledger: %{next.ledger | incoming: incoming}}, result}
          end
      end
    else
      false -> {:error, :invalid_item_handoff}
      error -> error
    end
  end

  # An entity returning here can arrive before this owner cleared the intent it
  # left in. Retry after clearance; the owner stays free to process that receipt.
  defp unreserved(items, records) do
    if Enum.any?(records, &Entities.reserved_uuid?(items, &1.uuid)),
      do: {:error, :item_handoff_busy},
      else: :ok
  end

  defp place(items, key, %{merge: nil, records: records}) do
    with {:ok, next} <- create(items, key, records), do: {:ok, next, :applied}
  end

  defp place(items, key, %{merge: target, records: [donor]}) do
    case ItemMerges.absorb(items, key, target, donor) do
      {:ok, next} -> {:ok, next, :applied}
      :error -> {:ok, items, :rejected}
    end
  end

  defp create(items, key, records) do
    Enum.reduce_while(records, {:ok, items}, fn record, {:ok, current} ->
      case Entities.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Clear the acknowledged intent, keeping the sequence and incoming receipts; a
  rejected merge's donor comes back.
  """
  def finish(items, key, sequence, digest, result) do
    with {:ok, transfer} <- request(items, key),
         true <- transfer.sequence == sequence,
         {:ok, ^digest} <- digest(transfer) do
      cleared = %{items | ledger: %{items.ledger | outgoing: nil}}

      if result == :rejected and transfer.merge != nil,
        do: create(cleared, key, transfer.records),
        else: {:ok, cleared}
    else
      _ -> {:error, :stale_item_handoff}
    end
  end
end
