defmodule Valimc.World.EntityView do
  @moduledoc """
  The replication view every entity kind publishes (VMC-067): identity, chunk and
  the four pre-encoded packets observers send (spawn, metadata, position,
  motion). Kinds add their own fields (an item's stack revision, an orb's value).
  """
  alias Valimc.Protocol.{EntityPackets, Wire}

  @max_id 2_147_483_647

  @doc "A network entity id from the VM-wide source players also use."
  def id do
    case System.unique_integer([:positive]) do
      id when id <= @max_id -> {:ok, id}
      _ -> {:error, :entity_id_exhausted}
    end
  end

  def valid_id?(id), do: is_integer(id) and id in 1..@max_id

  @doc """
  A new view of `kind` (`:item` or `:orb`). `entity` holds `entity_id`, `uuid`,
  `x`, `y`, `z` and optionally `velocity`/`on_ground`; `metadata` is the kind's
  encoded metadata packet.
  """
  def new(kind, entity, metadata, epoch, ownership_generation \\ 0) do
    %{entity_id: id, uuid: uuid, x: x, y: y, z: z} = entity

    %{
      kind: kind,
      entity_id: id,
      uuid: uuid,
      epoch: epoch,
      ownership_generation: ownership_generation,
      metadata_revision: 1,
      motion_revision: 1,
      chunk: Valimc.World.chunk_key(x, z),
      at: {x, y, z},
      spawn: packet(spawn(kind, entity)),
      metadata: metadata,
      position: packet(EntityPackets.position(Map.put_new(entity, :on_ground, false))),
      motion: packet(EntityPackets.motion(id, Map.get(entity, :velocity, {0.0, 0.0, 0.0})))
    }
  end

  @doc "Bytes an observer receives to spawn the view."
  def bytes(view),
    do:
      Enum.sum(
        for p <- [view.spawn, view.metadata, view.position, view.motion], do: packet_bytes(p)
      )

  def packet_bytes({id, payload}), do: byte_size(Wire.varint(id)) + byte_size(payload)

  def packet({id, body}), do: {id, IO.iodata_to_binary(body)}

  defp spawn(:item, entity), do: EntityPackets.spawn_item(entity)
  defp spawn(:orb, entity), do: EntityPackets.spawn_experience_orb(entity)
end
