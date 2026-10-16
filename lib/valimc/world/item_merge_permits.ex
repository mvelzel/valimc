defmodule Valimc.World.ItemMergePermits do
  @moduledoc "Bounded recipient contact grants after durable regional receipt admission."
  alias Valimc.{ItemMotionState, Physics.ItemMerge}
  alias Valimc.World.{ItemMergeTransfer, Items, OwnerItemReceipts}
  defstruct entries: %{}
  @limit 8
  @lifetime 250
  def new, do: %__MODULE__{}

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

  def available?(permits, source, now) do
    current = prune(permits, now)

    cond do
      Enum.any?(current.entries, fn {_, entry} -> entry.request.source == source end) ->
        {:error, :item_merge_already_pending}

      map_size(current.entries) >= @limit ->
        {:error, :item_merge_permits_full}

      true ->
        :ok
    end
  end

  @doc "Install only an already worker-validated request after its receipt slot is committed."
  def grant(permits, incoming, request, now) do
    with :ok <- available?(permits, request.source, now),
         true <- OwnerItemReceipts.valid?(incoming[request.source]) do
      permits = prune(permits, now)
      entry = %{request: request, expires_at: now + @lifetime}
      {:ok, %{permits | entries: Map.put(permits.entries, request.permit, entry)}, request}
    else
      false -> {:error, :item_merge_reservation_required}
      error -> error
    end
  end

  def consume(permits, items, request, now) do
    permits = prune(permits, now)

    case permits.entries[request.permit] do
      %{request: %{source: source} = accepted} when source == request.source ->
        next = %{permits | entries: Map.delete(permits.entries, request.permit)}

        valid =
          with true <-
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

        {next, valid}

      _ ->
        {permits, false}
    end
  rescue
    _ -> {permits, false}
  end

  def release(permits, token, source) do
    case permits.entries[token] do
      %{request: %{source: ^source}} -> %{permits | entries: Map.delete(permits.entries, token)}
      _ -> permits
    end
  end

  defp prune(permits, now),
    do: %{permits | entries: Map.reject(permits.entries, fn {_, e} -> now >= e.expires_at end)}

  defp point(record), do: {record.x, record.y, record.z}

  defp record(entry),
    do:
      entry.entity
      |> Map.take([:uuid, :x, :y, :z])
      |> Map.put(:stack, entry.stack)
      |> Map.put(:motion, Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity}))
end
