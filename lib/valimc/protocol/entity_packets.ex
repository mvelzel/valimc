defmodule Valimc.Protocol.EntityPackets do
  @moduledoc "Bounded entity packet primitives; authoritative simulation ownership is separate."
  alias Valimc.Data.Float32
  import Bitwise
  alias Valimc.Data.EntityTypes
  alias Valimc.Protocol.{ItemStack, Packets, PackedVelocity, Wire}
  @max_entity_id 2_147_483_647
  @max_removals 4096

  def spawn_item(entity), do: spawn(entity, "item")
  def spawn_experience_orb(entity), do: spawn(entity, "experience_orb")

  @doc """
  The spawn of an entity of `type` (`ClientboundAddEntityPacket`): its
  position, motion, pitch, yaw and head yaw (`head_yaw`, else its yaw) and the
  type's spawn data (`data`, 0 unless given: a falling block's state).
  """
  def spawn(%{entity_id: id, uuid: uuid, x: x, y: y, z: z} = entity, type) do
    entity_id!(id)
    check(is_binary(uuid) and byte_size(uuid) == 16, "invalid entity UUID")

    check(
      coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and coordinate?(y, 1_000_000),
      "invalid entity position"
    )

    pitch = pack_angle(Map.get(entity, :pitch, 0.0))
    yaw = pack_angle(Map.get(entity, :yaw, 0.0))
    head = pack_angle(Map.get(entity, :head_yaw, Map.get(entity, :yaw, 0.0)))

    Packets.packet("add_entity", [
      Wire.varint(id),
      uuid,
      Wire.varint(EntityTypes.id(type)),
      <<x::float-64, y::float-64, z::float-64>>,
      PackedVelocity.encode(Map.get(entity, :velocity, {0.0, 0.0, 0.0})),
      <<pitch, yaw, head>>,
      Wire.varint(Map.get(entity, :data, 0))
    ])
  end

  def spawn(_, _), do: raise(ArgumentError, "invalid entity")

  @doc "An angle in degrees as vanilla packs it (`Mth.packDegrees`), 0..255."
  def angle(degrees), do: pack_angle(degrees)

  @doc "An entity event (`ClientboundEntityEventPacket`): 3 death, 60 the death poof."
  def entity_event(id, event) when is_integer(event) and event in 0..255 do
    entity_id!(id)
    Packets.packet("entity_event", <<id::signed-32, event>>)
  end

  @doc "An animation (`ClientboundAnimatePacket`): 0 main-hand swing, 3 off-hand swing."
  def animate(id, action) when action in [0, 2, 3, 4, 5] do
    entity_id!(id)
    Packets.packet("animate", [Wire.varint(id), <<action>>])
  end

  def metadata(id, changes) do
    entity_id!(id)
    changes = bounded_list!(changes, 16, "invalid metadata batch")
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

  @doc """
  A relative move (26.3 `ClientboundMoveEntityPacket.Pos`): a linear delta in
  1/4096 blocks from the position the client last received, and the ground flag.
  """
  def move(id, {dx, dy, dz}, on_ground) do
    entity_id!(id)

    check(
      Enum.all?([dx, dy, dz], &(is_integer(&1) and &1 in -32768..32767)) and is_boolean(on_ground),
      "invalid entity move"
    )

    # Properties: the ground flag and a step count of 0 (a linear delta).
    Packets.packet("move_entity_pos", [
      Wire.varint(id),
      <<if(on_ground, do: 1, else: 0), dx::signed-16, dy::signed-16, dz::signed-16>>
    ])
  end

  @doc """
  A relative move with the absolute rotation (26.3
  `ClientboundMoveEntityPacket.PosRot`): the properties (ground flag, step
  count 0), the delta in 1/4096 blocks and the yaw and pitch as angle bytes.
  """
  def move_rotate(id, {dx, dy, dz}, yaw, pitch, on_ground) do
    entity_id!(id)

    check(
      Enum.all?([dx, dy, dz], &(is_integer(&1) and &1 in -32768..32767)) and is_boolean(on_ground) and
        yaw in 0..255 and pitch in 0..255,
      "invalid entity move"
    )

    Packets.packet("move_entity_pos_rot", [
      Wire.varint(id),
      <<if(on_ground, do: 1, else: 0), dx::signed-16, dy::signed-16, dz::signed-16, yaw, pitch>>
    ])
  end

  @doc "A rotation alone (26.3 `ClientboundMoveEntityPacket.Rot`): the ground flag, yaw and pitch bytes."
  def rotate(id, yaw, pitch, on_ground) do
    entity_id!(id)
    check(yaw in 0..255 and pitch in 0..255 and is_boolean(on_ground), "invalid entity rotation")

    Packets.packet("move_entity_rot", [
      Wire.varint(id),
      <<if(on_ground, do: 1, else: 0), yaw, pitch>>
    ])
  end

  @doc "The head's yaw as an angle byte (`ClientboundRotateHeadPacket`)."
  def rotate_head(id, yaw) do
    entity_id!(id)
    check(yaw in 0..255, "invalid head rotation")
    Packets.packet("rotate_head", [Wire.varint(id), <<yaw>>])
  end

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

  @doc """
  `ClientboundSetEntityLinkPacket` (VMC-043c3): entity `id` leashed to
  `holder` (a network id), or to nothing (nil).
  """
  def link(id, holder) do
    entity_id!(id)
    if holder != nil, do: entity_id!(holder)
    Packets.packet("set_entity_link", <<id::signed-32, holder || 0::signed-32>>)
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

  # The water, ambient and End mobs' own fields (VMC-043e), the farm
  # animals' (VMC-043c) and the villagers' (VMC-044a), by serializer.
  @mob_bytes [:shulker_peek, :shulker_color, :bat_flags, :sheep_wool, :iron_golem_flags]
  @mob_flags [
    :fish_from_bucket,
    :dolphin_got_fish,
    :turtle_has_egg,
    :turtle_laying_egg,
    :axolotl_playing_dead,
    :axolotl_from_bucket,
    :guardian_moving,
    # VMC-043c: an ageable mob's age lock.
    :age_locked,
    # VMC-044a: villagers.
    :villager_data_finalized
  ]
  @mob_ints [
    :puff_state,
    :tropical_fish_variant,
    :salmon_type,
    :glow_squid_dark_ticks,
    :dolphin_moistness,
    :axolotl_variant,
    :guardian_attack_target,
    # VMC-043c: animals' variants by registry network id, a mooshroom's and a
    # rabbit's type.
    :cow_variant,
    :cow_sound_variant,
    :pig_variant,
    :pig_sound_variant,
    :chicken_variant,
    :chicken_sound_variant,
    :mooshroom_type,
    :rabbit_type,
    :villager_unhappy
  ]

  defp metadata_value({name, value})
       when name in [
              :shared_flags,
              :living_flags,
              :no_gravity,
              :item_stack,
              :pose,
              :frozen_ticks,
              :health,
              :absorption,
              :air_supply,
              :experience_value,
              :mob_flags,
              :blaze_flags,
              :tnt_fuse,
              :tnt_block_state,
              :falling_block_start_pos,
              :sleeping_pos,
              :ageable_baby,
              :arrow_flags,
              :arrow_pierce_level,
              :arrow_in_ground,
              :arrow_color,
              :thrown_item,
              :eye_item,
              :cloud_radius,
              :cloud_waiting,
              :cloud_particle,
              :custom_name,
              :villager_data
            ] or name in @mob_bytes or name in @mob_flags or name in @mob_ints or
              name == :shulker_attach_face do
    fact = EntityTypes.field(name)

    payload =
      case name do
        name
        when name in [
               :shared_flags,
               :living_flags,
               :mob_flags,
               :blaze_flags,
               :arrow_flags,
               :arrow_pierce_level
             ] or name in @mob_bytes ->
          check(is_integer(value) and value in 0..255, "invalid shared flags")
          <<value>>

        name
        when name in [:no_gravity, :ageable_baby, :arrow_in_ground, :cloud_waiting] or
               name in @mob_flags ->
          check(is_boolean(value), "invalid flag")
          Wire.bool(value)

        # An optional text component (a name tag's, VMC-042a).
        :custom_name ->
          if value == nil, do: <<0>>, else: [<<1>>, Valimc.Text.Codec.encode(value)]

        name when name in [:item_stack, :thrown_item, :eye_item] ->
          stack_bytes(value)

        name when name in @mob_ints ->
          check(is_integer(value) and value in -2_147_483_648..2_147_483_647, "invalid int")
          Wire.varint(value)

        # A `Direction` by its 3D value (down, up, north, south, west, east).
        :shulker_attach_face ->
          check(is_integer(value) and value in 0..5, "invalid direction")
          Wire.varint(value)

        :arrow_color ->
          check(is_integer(value) and value in -2_147_483_648..2_147_483_647, "invalid color")
          Wire.varint(value)

        :cloud_radius ->
          check(is_number(value) and value >= 0 and value <= 32, "invalid radius")
          <<value::float-32>>

        # A particle with a power (`PowerParticleOption`): its type and power.
        :cloud_particle ->
          {type, power} = value
          check(is_integer(type) and type >= 0 and is_number(power), "invalid particle")
          [Wire.varint(type), <<power::float-32>>]

        :pose ->
          check(match?({:ok, _}, Valimc.Data.PlayerPose.dimensions(value)), "invalid pose")
          Wire.varint(Valimc.Data.PlayerPose.id(value))

        :frozen_ticks ->
          check(is_integer(value) and value in 0..2_147_483_647, "invalid frozen ticks")
          Wire.varint(value)

        :air_supply ->
          check(
            is_integer(value) and value in -2_147_483_648..2_147_483_647,
            "invalid air supply"
          )

          Wire.varint(value)

        :tnt_fuse ->
          check(is_integer(value) and value in -2_147_483_648..2_147_483_647, "invalid fuse")
          Wire.varint(value)

        :tnt_block_state ->
          check(is_integer(value) and value >= 0, "invalid block state")
          Wire.varint(value)

        :falling_block_start_pos ->
          check(
            match?({x, y, z} when is_integer(x) and is_integer(y) and is_integer(z), value),
            "invalid block position"
          )

          Wire.position(value)

        # An optional block position: where a living entity sleeps (VMC-040a).
        :sleeping_pos ->
          case value do
            nil ->
              <<0>>

            {x, y, z} when is_integer(x) and is_integer(y) and is_integer(z) ->
              [<<1>>, Wire.position(value)]

            _ ->
              check(false, "invalid sleeping position")
          end

        # `VillagerData.STREAM_CODEC`: type, profession (registry ids), level.
        :villager_data ->
          {type, profession, level} = value

          check(
            Enum.all?([type, profession, level], &(is_integer(&1) and &1 >= 0)),
            "invalid villager data"
          )

          [Wire.varint(type), Wire.varint(profession), Wire.varint(level)]

        :experience_value ->
          check(is_integer(value) and value in 1..2_147_483_647, "invalid experience value")
          Wire.varint(value)

        :health ->
          check(is_number(value) and value >= 0 and value <= 1024, "invalid health")
          <<value::float-32>>

        :absorption ->
          check(is_number(value) and value >= 0 and value <= 2048, "invalid absorption")
          <<value::float-32>>
      end

    {fact["index"], [<<fact["index"]>>, Wire.varint(fact["serializer"]), payload]}
  end

  # The overworld hostiles' own fields (VMC-043b).
  @flags [
    :zombie_baby,
    :zombie_drowned_conversion,
    :zombie_villager_converting,
    :zombie_villager_finalized,
    :skeleton_stray_conversion,
    :bogged_sheared,
    :creeper_powered,
    :creeper_ignited,
    :enderman_creepy,
    :enderman_stared_at,
    :raider_celebrating,
    :witch_using_item,
    # The Nether's (VMC-043d).
    :ghast_charging,
    :piglin_immune,
    :piglin_baby,
    :piglin_charging_crossbow,
    :piglin_dancing,
    :hoglin_immune,
    :strider_suffocating
  ]
  @ints [
    :zombie_special_type,
    :creeper_swell_dir,
    :cube_size,
    :phantom_size,
    :strider_boost_time
  ]

  defp metadata_value({name, value}) when name in @flags do
    check(is_boolean(value), "invalid flag")
    family(name, Wire.bool(value))
  end

  defp metadata_value({name, value}) when name in @ints do
    check(is_integer(value) and value in -2_147_483_648..2_147_483_647, "invalid int")
    family(name, Wire.varint(value))
  end

  defp metadata_value({:spider_flags, value}) do
    check(is_integer(value) and value in 0..255, "invalid flags")
    family(:spider_flags, <<value>>)
  end

  # `VillagerData`: its type and profession (registry ids) and level.
  defp metadata_value({:zombie_villager_data, {type, profession, level}})
       when is_integer(level) do
    family(:zombie_villager_data, [
      Wire.varint(Valimc.Data.HostileFacts.villager_type_id(type)),
      Wire.varint(Valimc.Data.HostileFacts.profession_id(profession)),
      Wire.varint(level)
    ])
  end

  # An optional block state: what an enderman carries (0 for none).
  defp metadata_value({:enderman_carry_state, value}) do
    check(value == nil or (is_integer(value) and value > 0), "invalid block state")
    family(:enderman_carry_state, Wire.varint(value || 0))
  end

  defp metadata_value(_), do: raise(ArgumentError, "unknown or invalid metadata field")

  defp family(name, payload) do
    fact = EntityTypes.field(name)
    {fact["index"], [<<fact["index"]>>, Wire.varint(fact["serializer"]), payload]}
  end

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
    floor((Float32.round(Float32.round(value) * 256.0) / 360.0) |> Float32.round()) &&& 255
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
