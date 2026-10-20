defmodule Valimc.World.ItemMergePermits do
  @moduledoc "Recipient contact grants in the owner's `Valimc.Txn.Permits` after durable regional receipt admission."
  alias Valimc.{ItemMotionState, Physics.ItemMerge}
  alias Valimc.Txn.Permits
  alias Valimc.World.{ItemMergeTransfer, Items, OwnerItemReceipts}

  @doc "Run outside the owner; canonicalization and native component decisions can be expensive."
  def prepare(
        items,
        destination,
        %{
          source: source,
          sequence: sequence,
          donor: donor,
          donor_generation: generation,
          recipient_uuid: target
        } = proposal
      )
      when map_size(proposal) == 5 do
    with {:ok, {_, id, _}} <- Items.find(items, target),
         entry = items.entries[id],
         recipient = record(entry),
         true <- donor.stack.count != recipient.stack.count or source < destination,
         request = %{
           source: source,
           destination: destination,
           sequence: sequence,
           donor: donor,
           donor_generation: generation,
           recipient: recipient,
           recipient_generation: Map.get(items.ledger.generations, target, 0),
           permit: :crypto.strong_rand_bytes(16)
         },
         {:ok, _} <- ItemMergeTransfer.decision(request) do
      {:ok, request}
    else
      _ -> {:error, :item_merge_not_available}
    end
  rescue
    _ -> {:error, :item_merge_not_available}
  end

  def prepare(_, _, _), do: {:error, :item_merge_not_available}

  def available?(%Permits{} = permits, source, now),
    do: Permits.admit(permits, :item_merge, source, now)

  @doc "Install only an already worker-validated request after its receipt slot is committed."
  def grant(%Permits{} = permits, incoming, request, now) do
    with :ok <- available?(permits, request.source, now),
         true <- OwnerItemReceipts.valid?(incoming[request.source]),
         {:ok, permits, _} <-
           Permits.issue(permits, :item_merge, request.permit, request.source, [], request, now) do
      {:ok, permits, request}
    else
      false -> {:error, :item_merge_reservation_required}
      error -> error
    end
  end

  def consume(%Permits{} = permits, items, request, now) do
    {permits, accepted} = Permits.take(permits, :item_merge, request.permit, request.source, now)

    valid =
      try do
        with %{} <- accepted,
             true <-
               request.sequence == accepted.sequence and
                 request.destination == accepted.destination and
                 request.recipient == accepted.recipient and
                 request.donor_generation == accepted.donor_generation and
                 request.recipient_generation == accepted.recipient_generation and
                 request.donor.uuid == accepted.donor.uuid and
                 request.donor.stack == accepted.donor.stack,
             {:ok, {_, id, _}} <- Items.find(items, request.recipient.uuid),
             entry = items.entries[id],
             true <-
               entry.stack == accepted.recipient.stack and
                 Map.get(items.ledger.generations, request.recipient.uuid, 0) ==
                   accepted.recipient_generation,
             do: ItemMerge.near?(point(request.donor), point(entry.entity)),
             else: (_ -> false)
      rescue
        _ -> false
      end

    {permits, valid}
  rescue
    _ -> {permits, false}
  end

  defp point(record), do: {record.x, record.y, record.z}

  defp record(entry),
    do:
      entry.entity
      |> Map.take([:uuid, :x, :y, :z])
      |> Map.put(:stack, entry.stack)
      |> Map.put(:motion, Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity}))
end
