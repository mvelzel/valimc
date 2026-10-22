defmodule Valimc.Entity.View do
  @moduledoc """
  The view every entity kind publishes (VMC-067, VMC-077h): identity, chunk,
  position and motion as values, and the encoded metadata packet. Kinds add
  their own fields (an item's stack hints, an orb's value). The owner's tracker
  (`Valimc.Entity.Tracking`) adds what observers send at publication: the
  spawn packet at the position clients were last sent, and that position.
  """
  alias Valimc.Protocol.{EntityPackets, Wire}

  defdelegate id, to: Valimc.Entity.Ids, as: :next
  defdelegate valid_id?(id), to: Valimc.Entity.Ids, as: :valid?

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
      chunk: Valimc.Data.Grid.chunk_key(x, z),
      at: {x, y, z},
      velocity: Map.get(entity, :velocity, {0.0, 0.0, 0.0}),
      on_ground: Map.get(entity, :on_ground, false),
      metadata: metadata
    }
  end

  @doc "The spawn packet of `view` at `{x, y, z}` moving at `velocity`."
  def spawn(view, {x, y, z}, velocity) do
    entity = %{entity_id: view.entity_id, uuid: view.uuid, x: x, y: y, z: z, velocity: velocity}

    packet(
      case view.kind do
        :item -> EntityPackets.spawn_item(entity)
        :orb -> EntityPackets.spawn_experience_orb(entity)
      end
    )
  end

  def packet_bytes({id, payload}), do: byte_size(Wire.varint(id)) + byte_size(payload)

  def packet({id, body}), do: {id, IO.iodata_to_binary(body)}
end
