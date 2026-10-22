defmodule Valimc.World.ExperienceTransfers do
  @moduledoc "One XP-unit withdrawal shares container receipts; a player grant requires its exact durable proof."
  alias Valimc.World.{
    ContainerRequest,
    ContainerTransfers,
    Containers,
    CookingOrbConsumptions,
    CookingOrbBodies
  }

  alias Valimc.Physics.{Box, ItemPickup}

  def contact?(box, {x, y, z}) do
    with {:ok, query} <- ItemPickup.query_box(box),
         do: Box.intersects?(query, {x - 0.25, y, z - 0.25, x + 0.25, y + 0.5, z + 0.25}),
         else: (_ -> false)
  end

  def eligible?(
        containers,
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
    with %{value: value, count: count, position: {x, y, z} = at} <-
           CookingOrbBodies.fetch(containers, request.orb_uuid),
         true <- {floor(x), floor(y), floor(z)} == request.position,
         true <- value == request.value and count > 0,
         true <-
           Map.get(containers.orb_consumption.counts, request.orb_uuid, 0) == request.consumed,
         do: contact?(box, at),
         else: (_ -> false)
  rescue
    _ -> false
  end

  def eligible?(_, _, _, _), do: false

  def plan(containers, key, request, eligible) do
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
          {result, next} =
            case eligible &&
                   CookingOrbConsumptions.take(
                     reserved,
                     request.orb_uuid,
                     request.value,
                     request.consumed
                   ) do
              {:ok, next} -> {:applied, next}
              _ -> {:rejected, reserved}
            end

          receipt = %{
            sequence: request.sequence,
            digest: ContainerTransfers.result_digest(digest, result)
          }

          next = %{next | receipts: Map.put(next.receipts, request.source, receipt)}

          case Containers.encode(key, next) do
            {:ok, _} ->
              {:ok,
               %{
                 containers: next,
                 result: result,
                 experience: if(result == :applied, do: request, else: nil)
               }}

            {:error, _} ->
              # The source slot was reserved before admission. Its fixed-size
              # terminal rejection fits even when a new consumed counter cannot.
              rejected = %{
                reserved
                | receipts:
                    Map.put(reserved.receipts, request.source, %{
                      sequence: request.sequence,
                      digest: ContainerTransfers.result_digest(digest, :rejected)
                    })
              }

              with {:ok, _} <- Containers.encode(key, rejected),
                   do: {:ok, %{containers: rejected, result: :rejected, experience: nil}}
          end
      end
    end
  end
end
