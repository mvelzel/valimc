defmodule Valimc.World.PickupPermits do
  @moduledoc "Bounded short-lived contact grants; their source receipt slot must already be durable."
  alias Valimc.Physics.ItemPickup
  alias Valimc.World.{ItemReceipts, Items}
  defstruct entries: %{}
  @max_permits 128
  @lifetime_ms 250
  def new, do: %__MODULE__{}

  def issue(permits, receipts, items, %{uuid: <<_::128>> = source} = actor, item_uuid, now)
      when is_integer(now) do
    permits = prune(permits, now)

    cond do
      Enum.any?(permits.entries, fn {_, grant} -> grant.source == source end) ->
        {:error, :pickup_already_pending}

      map_size(permits.entries) >= @max_permits ->
        {:error, :pickup_permits_full}

      not ItemReceipts.valid?(receipts[source]) ->
        {:error, :pickup_receipt_slot_required}

      true ->
        with {:ok, {_, id, _}} <- Items.find(items, item_uuid),
             entry = items.entries[id],
             true <- ItemPickup.eligible?(actor, entry) do
          token = :crypto.strong_rand_bytes(16)

          actor = %{
            uuid: source,
            box: actor.box,
            game_mode: actor.game_mode,
            health: %{value: actor.health.value}
          }

          grant = %{
            source: source,
            item_uuid: item_uuid,
            generation: Map.get(items.ledger.generations, item_uuid, 0),
            before: entry.stack,
            actor: actor,
            expires_at: now + @lifetime_ms
          }

          {:ok, %{permits | entries: Map.put(permits.entries, token, grant)},
           %{
             permit: token,
             item_uuid: item_uuid,
             generation: grant.generation,
             before: entry.stack
           }}
        else
          _ -> {:error, :pickup_not_available}
        end
    end
  end

  def issue(_, _, _, _, _, _), do: {:error, :invalid_pickup_permit}

  def consume(permits, items, %{permit: token, source: source} = request, now)
      when is_integer(now) do
    permits = prune(permits, now)

    case permits.entries[token] do
      %{source: ^source} = grant ->
        next = %{permits | entries: Map.delete(permits.entries, token)}

        eligible =
          with true <-
                 request.item_uuid == grant.item_uuid and request.before == grant.before and
                   request.generation == grant.generation,
               {:ok, {_, id, _}} <- Items.find(items, grant.item_uuid),
               entry = items.entries[id],
               true <-
                 entry.stack == grant.before and
                   Map.get(items.ledger.generations, grant.item_uuid, 0) == grant.generation,
               do: ItemPickup.eligible?(grant.actor, entry),
               else: (_ -> false)

        {next, eligible}

      _ ->
        {permits, false}
    end
  rescue
    _ -> {permits, false}
  end

  def consume(permits, _, _, _), do: {permits, false}

  defp prune(permits, now),
    do: %{
      permits
      | entries: Map.reject(permits.entries, fn {_, grant} -> now >= grant.expires_at end)
    }
end
