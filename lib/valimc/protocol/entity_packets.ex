defmodule Valimc.Protocol.EntityPackets do
  @moduledoc "Bounded entity packet primitives; authoritative simulation ownership is separate."
  import Bitwise
  alias Valimc.Protocol.{EntityTypes, ItemStack, Packets, PackedVelocity, Wire}
  @max_entity_id 2_147_483_647
  @max_removals 4096

  def spawn_item(%{entity_id: id, uuid: uuid, x: x, y: y, z: z} = entity) do
    entity_id!(id)
    check(is_binary(uuid) and byte_size(uuid) == 16, "invalid entity UUID")

    check(
      coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and coordinate?(y, 1_000_000),
      "invalid entity position"
    )

    pitch = pack_angle(Map.get(entity, :pitch, 0.0))
    yaw = pack_angle(Map.get(entity, :yaw, 0.0))

    Packets.packet("add_entity", [
      Wire.varint(id),
      uuid,
      Wire.varint(EntityTypes.id("item")),
      <<x::float-64, y::float-64, z::float-64>>,
      PackedVelocity.encode(Map.get(entity, :velocity, {0.0, 0.0, 0.0})),
      <<pitch, yaw, yaw, 0>>
    ])
  end

  def spawn_item(_), do: raise(ArgumentError, "invalid item entity")

  def metadata(id, changes) do
    entity_id!(id)
    changes = bounded_list!(changes, 3, "invalid metadata batch")
    entries = Enum.map(changes, &metadata_value/1)
    indices = Enum.map(entries, &elem(&1, 0))
    check(length(Enum.uniq(indices)) == length(indices), "duplicate metadata field")

    Packets.packet("set_entity_data", [
      Wire.varint(id),
      Enum.map(Enum.sort(entries), &elem(&1, 1)),
      <<255>>
    ])
  end

  def motion(id, velocity) do
    entity_id!(id)
    Packets.packet("set_entity_motion", [Wire.varint(id), PackedVelocity.encode(velocity)])
  end

  @doc "Absolute linear-path synchronization; simulation owns the supplied accepted position."
  def position(%{entity_id: id, x: x, y: y, z: z, on_ground: on_ground} = entity) do
    entity_id!(id)

    check(
      coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and
        coordinate?(y, 1_000_000) and is_boolean(on_ground),
      "invalid entity position"
    )

    yaw = Map.get(entity, :yaw, 0.0)
    pitch = Map.get(entity, :pitch, 0.0)

    check(
      coordinate?(yaw, 1_000_000) and coordinate?(pitch, 1_000_000),
      "invalid entity rotation"
    )

    Packets.packet("entity_position_sync", [
      Wire.varint(id),
      # 26.3 PositionPath.Type.LINEAR, followed by the final Vec3 (no velocity).
      <<0, x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32,
        if(on_ground, do: 1, else: 0)>>
    ])
  end

  def position(_), do: raise(ArgumentError, "invalid entity position")

  def equipment(id, changes) do
    entity_id!(id)
    changes = bounded_list!(changes, 8, "invalid equipment batch")
    check(changes != [], "empty equipment batch")

    slots =
      Enum.map(changes, fn
        {slot, stack} when is_integer(slot) and slot in 0..7 -> {slot, ItemStack.encode(stack)}
        _ -> raise ArgumentError, "invalid equipment slot"
      end)

    check(Enum.uniq_by(slots, &elem(&1, 0)) == slots, "duplicate equipment slot")
    last = length(slots) - 1

    body =
      Enum.with_index(slots, fn {slot, bytes}, index ->
        [<<if(index < last, do: slot ||| 128, else: slot)>>, bytes]
      end)

    Packets.packet("set_equipment", [Wire.varint(id), body])
  end

  def pickup(item_id, collector_id, count) do
    entity_id!(item_id)
    entity_id!(collector_id)
    check(is_integer(count) and count in 1..99, "invalid pickup count")

    Packets.packet("take_item_entity", [
      Wire.varint(item_id),
      Wire.varint(collector_id),
      Wire.varint(count)
    ])
  end

  def remove(ids) do
    ids = bounded_list!(ids, @max_removals, "invalid removal batch")
    Enum.each(ids, &entity_id!/1)
    Packets.packet("remove_entities", [Wire.varint(length(ids)), Enum.map(ids, &Wire.varint/1)])
  end

  defp metadata_value({name, value})
       when name in [
              :shared_flags,
              :living_flags,
              :no_gravity,
              :item_stack,
              :pose,
              :frozen_ticks,
              :health,
              :air_supply
            ] do
    fact = EntityTypes.field(name)

    payload =
      case name do
        name when name in [:shared_flags, :living_flags] ->
          check(is_integer(value) and value in 0..255, "invalid shared flags")
          <<value>>

        :no_gravity ->
          check(is_boolean(value), "invalid no-gravity flag")
          Wire.bool(value)

        :item_stack ->
          stack_bytes(value)

        :pose ->
          check(match?({:ok, _}, Valimc.Physics.PlayerPose.dimensions(value)), "invalid pose")
          Wire.varint(Valimc.Physics.PlayerPose.id(value))

        :frozen_ticks ->
          check(Valimc.PlayerEnvironment.valid_ticks?(value), "invalid frozen ticks")
          Wire.varint(value)

        :air_supply ->
          check(Valimc.PlayerAir.valid?(value), "invalid air supply")
          Wire.varint(value)

        :health ->
          check(is_number(value) and value >= 0 and value <= 1024, "invalid health")
          <<value::float-32>>
      end

    {fact["index"], [<<fact["index"]>>, Wire.varint(fact["serializer"]), payload]}
  end

  defp metadata_value(_), do: raise(ArgumentError, "unknown or invalid metadata field")

  defp stack_bytes(stack) do
    check(
      stack == nil or
        match?(
          %ItemStack{components: components, removed: %MapSet{}} when is_map(components),
          stack
        ),
      "invalid metadata stack"
    )

    ItemStack.encode(stack)
  catch
    {:item_error, _} -> raise(ArgumentError, "invalid metadata stack")
  end

  # Mojang packDegrees uses float32 arithmetic, including its division result.
  defp pack_angle(value) do
    check(coordinate?(value, 1_000_000), "invalid entity rotation")
    floor((float32(float32(value) * 256.0) / 360.0) |> float32()) &&& 255
  end

  defp float32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end

  defp entity_id!(id), do: check(is_integer(id) and id in 1..@max_entity_id, "invalid entity ID")
  defp coordinate?(value, bound), do: is_number(value) and abs(value) <= bound

  defp bounded_list!(values, limit, message) when is_list(values) do
    prefix = Enum.take(values, limit + 1)
    check(length(prefix) <= limit, message)
    prefix
  rescue
    FunctionClauseError -> raise(ArgumentError, message)
    ArgumentError -> raise(ArgumentError, message)
  end

  defp bounded_list!(_, _, message), do: raise(ArgumentError, message)
  defp check(true, _), do: :ok
  defp check(false, message), do: raise(ArgumentError, message)
end
