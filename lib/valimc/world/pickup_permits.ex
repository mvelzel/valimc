defmodule Valimc.World.PickupPermits do
  @moduledoc "Short contact grants in the owner's `Valimc.Txn.Permits`; their source receipt slot must already be durable."
  alias Valimc.Physics.ItemPickup
  alias Valimc.Txn.Permits
  alias Valimc.World.{Entities}

  def issue(
        %Permits{} = permits,
        receipts,
        items,
        %{uuid: <<_::128>> = source} = actor,
        item_uuid,
        now
      )
      when is_integer(now) do
    with :ok <- Permits.admit(permits, :pickup, source, now),
         true <-
           Valimc.Txn.Receipts.valid?(receipts[source]) || {:error, :pickup_receipt_slot_required},
         {:ok, {_, id, _}} <- Entities.find(items, item_uuid),
         %{kind: :item} = entry <- items.entries[id],
         true <- ItemPickup.eligible?(actor, entry) do
      grant = %{
        item_uuid: item_uuid,
        generation: Entities.hops(items, item_uuid),
        before: entry.stack,
        actor:
          %{
            uuid: source,
            box: actor.box,
            game_mode: actor.game_mode,
            health: %{value: actor.health.value}
          }
          |> Map.merge(Map.take(actor, [:entity_id]))
      }

      {:ok, permits, token} = Permits.issue(permits, :pickup, nil, source, [], grant, now)

      {:ok, permits,
       %{permit: token, item_uuid: item_uuid, generation: grant.generation, before: entry.stack}}
    else
      {:error, _} = error -> error
      _ -> {:error, :pickup_not_available}
    end
  end

  def issue(_, _, _, _, _, _), do: {:error, :invalid_pickup_permit}

  @doc "Take the presented permit; `{permits, grant, eligible}` (the grant is `nil` when absent)."
  def consume(%Permits{} = permits, items, %{permit: token, source: source} = request, now)
      when is_integer(now) do
    {permits, grant} = Permits.take(permits, :pickup, token, source, now)

    eligible =
      try do
        with %{} <- grant,
             true <-
               request.item_uuid == grant.item_uuid and request.before == grant.before and
                 request.generation == grant.generation,
             {:ok, {_, id, _}} <- Entities.find(items, grant.item_uuid),
             entry = items.entries[id],
             true <-
               entry.stack == grant.before and
                 Entities.hops(items, grant.item_uuid) == grant.generation,
             do: ItemPickup.eligible?(grant.actor, entry),
             else: (_ -> false)
      rescue
        _ -> false
      end

    {permits, grant, eligible}
  end

  def consume(permits, _, _, _), do: {permits, nil, false}
end
