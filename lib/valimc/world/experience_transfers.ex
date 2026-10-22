defmodule Valimc.World.ExperienceTransfers do
  @moduledoc """
  An XP pickup (VMC-077h): one unit of an orb entity, taken under the container
  receipts the player's pickup protocol uses; the player's grant follows its
  durable proof.
  """
  alias Valimc.World.{ContainerRequest, ContainerTransfers, Entities}
  alias Valimc.Physics.{Box, ItemPickup}

  def contact?(box, {x, y, z}) do
    with {:ok, query} <- ItemPickup.query_box(box),
         do: Box.intersects?(query, {x - 0.25, y, z - 0.25, x + 0.25, y + 0.5, z + 0.25}),
         else: (_ -> false)
  end

  def eligible?(
        items,
        request,
        %{
          uuid: source,
          game_mode: %{current: mode},
          health: %{value: hp},
          box: box,
          entity_id: collector,
          expires: expiry
        },
        now
      )
      when source == request.source and collector == request.collector and
             mode in [:survival, :adventure, :creative] and hp > 0 and
             now < expiry do
    with {:ok, {_, id, _}} <- Entities.find(items, request.orb_uuid),
         %{kind: :orb, value: value, count: count, entity: %{x: x, y: y, z: z}} <-
           items.entries[id],
         true <- {floor(x), floor(y), floor(z)} == request.position,
         true <- value == request.value and count > 0,
         do: contact?(box, {x, y, z}),
         else: (_ -> false)
  rescue
    _ -> false
  end

  def eligible?(_, _, _, _), do: false

  @doc """
  `{:ok, %{containers, items, result, experience}}`: the receipt, the orb with
  one unit fewer, and, once applied, the pickup observers see (`experience`).
  """
  def plan(containers, items, key, request, eligible) do
    with {:ok, digest} <- ContainerRequest.digest(key, request),
         {:ok, reserved, _} <- ContainerTransfers.reserve(containers, request.source) do
      case Valimc.Txn.Receipts.classify(
             reserved.receipts,
             request.source,
             request.sequence,
             digest,
             {:prefix, "VMCCONTAINER-RESULT"}
           ) do
        {:duplicate, result} ->
          {:ok, %{containers: reserved, result: result}}

        {:error, _} = error ->
          error

        :new ->
          {result, next, pickup} =
            case eligible && Entities.take_orb(items, request.orb_uuid, request.value) do
              {:ok, next, id} -> {:applied, next, %{id: id, collector: request.collector}}
              _ -> {:rejected, items, nil}
            end

          receipt = %{
            sequence: request.sequence,
            digest: ContainerTransfers.result_digest(digest, result)
          }

          receipts = Map.put(reserved.receipts, request.source, receipt)

          {:ok,
           %{
             containers: %{reserved | receipts: receipts},
             items: next,
             result: result,
             experience: pickup
           }}
      end
    end
  end
end
