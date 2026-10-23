defmodule Valimc.Protocol.Packets do
  @moduledoc "Minecraft 26.3 clientbound packet payloads. All integers are network endian."
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.Protocol.DamageTypes
  import Bitwise

  def packet(name, payload, state \\ :play), do: {Data.id(state, :clientbound, name), payload}
  def frame({id, payload}, threshold), do: Wire.frame(id, payload, threshold)

  def container_slot(state_id, slot, stack) do
    packet("container_set_slot", [
      Wire.varint(0),
      Wire.varint(state_id),
      <<slot::signed-16>>,
      ItemStack.encode(stack)
    ])
  end

  # Native event1 opens for any positive byte; binary occupancy avoids wrapping
  # an opener count of256 to a spurious close. Ordinary chest registry ID245.
  def chest_lid(position, open?) when is_boolean(open?),
    do:
      packet("block_event", [
        Wire.position(position),
        <<1, if(open?, do: 1, else: 0)>>,
        Wire.varint(245)
      ])

  def held_slot(slot), do: packet("set_held_slot", Wire.varint(slot))
  def cursor(stack), do: packet("set_cursor_item", ItemStack.encode(stack))

  def player_inventory_slot(slot, stack) when slot in 0..40,
    do: packet("set_player_inventory", [Wire.varint(slot), ItemStack.encode(stack)])

  def known_packs do
    packet(
      "select_known_packs",
      [<<1>>, Wire.string("minecraft"), Wire.string("core"), Wire.string(Valimc.version())],
      :configuration
    )
  end

  def configuration do
    registries =
      for {name, entries} <- Enum.sort(Data.registries()) do
        packet(
          "registry_data",
          [
            Wire.string(name),
            Wire.varint(length(entries)),
            Enum.map(entries, &[Wire.string(&1), <<0>>])
          ],
          :configuration
        )
      end

    [packet("update_enabled_features", [<<1>>, Wire.string("minecraft:vanilla")], :configuration)] ++
      registries ++
      [
        packet("update_tags", Data.tags_payload(), :configuration),
        packet("finish_configuration", <<>>, :configuration)
      ]
  end

  def teleport(player, teleport_id, {dx, dy, dz} \\ {0.0, 0.0, 0.0}) do
    %{x: x, y: y, z: z, yaw: yaw, pitch: pitch} = player

    packet("player_position", [
      Wire.varint(teleport_id),
      <<x::float-64, y::float-64, z::float-64, dx::float-64, dy::float-64, dz::float-64,
        yaw::float-32, pitch::float-32, 0::32>>
    ])
  end

  def level_load_start, do: packet("game_event", <<13, 0.0::float-32>>)

  def remove_effect(entity_id, effect_id) do
    life_entity_id!(entity_id)

    unless Valimc.Data.EffectTypes.valid_id?(effect_id),
      do: raise(ArgumentError, "invalid effect packet")

    packet("remove_mob_effect", [Wire.varint(entity_id), Wire.varint(effect_id)])
  end

  def self_magic_damage(entity_id) do
    life_entity_id!(entity_id)

    packet("damage_event", [
      Wire.varint(entity_id),
      Wire.varint(DamageTypes.id(:indirect_magic)),
      Wire.varint(entity_id + 1),
      Wire.varint(entity_id + 1),
      <<0>>
    ])
  end

  @doc """
  `ClientboundDamageEventPacket`: entity `entity_id` took damage of type
  `source`, caused by entity `cause` directly through entity `direct` (network
  ids or nil), from an explicit source `position` (nil for entity sources).
  """
  def damage_event(entity_id, source \\ :fall, cause \\ nil, direct \\ nil, position \\ nil) do
    life_entity_id!(entity_id)

    unless DamageTypes.known?(source), do: raise(ArgumentError, "invalid damage source")

    packet("damage_event", [
      Wire.varint(entity_id),
      Wire.varint(DamageTypes.id(source)),
      Wire.varint(if(cause, do: cause + 1, else: 0)),
      Wire.varint(if(direct, do: direct + 1, else: 0)),
      case position do
        nil -> <<0>>
        {x, y, z} -> <<1, x::float-64, y::float-64, z::float-64>>
      end
    ])
  end

  def death(entity_id, message) do
    life_entity_id!(entity_id)

    unless (is_binary(message) and byte_size(message) <= 1024 and String.valid?(message)) or
             is_struct(message, Valimc.Protocol.ServerText) or
             Valimc.Text.Codec.valid?(message),
           do: raise(ArgumentError, "invalid death message")

    encoded = Wire.text_component(message)

    if not is_binary(message) and not is_struct(message, Valimc.Protocol.ServerText) and
         IO.iodata_length(encoded) > 1024,
       do: raise(ArgumentError, "death message exceeds limit")

    packet("player_combat_kill", [Wire.varint(entity_id), encoded])
  end

  def death_animation(entity_id) do
    life_entity_id!(entity_id)
    packet("entity_event", <<entity_id::signed-32, 3>>)
  end

  @doc "A held item breaking (entity events 47 and 48: main and off hand)."
  def item_break(entity_id, :main), do: packet("entity_event", <<entity_id::signed-32, 47>>)
  def item_break(entity_id, :off), do: packet("entity_event", <<entity_id::signed-32, 48>>)

  def use_item_finished(entity_id) do
    life_entity_id!(entity_id)
    packet("entity_event", <<entity_id::signed-32, 9>>)
  end

  @doc "Raises unless `entity_id` is a living entity's network id."
  def life_entity_id!(entity_id) do
    unless is_integer(entity_id) and entity_id in 1..2_147_483_647,
      do: raise(ArgumentError, "invalid entity ID")
  end

  def difficulty(%{level: level, locked: locked})
      when is_integer(level) and level in 0..3 and is_boolean(locked),
      do: packet("change_difficulty", <<level, if(locked, do: 1, else: 0)>>)

  @doc "`ClientboundChunksBiomesPacket`: per chunk its packed position and biome containers."
  def chunks_biomes(entries) do
    packet("chunks_biomes", [
      Wire.varint(length(entries)),
      for {{x, z}, bytes} <- entries do
        <<z::signed-32, x::signed-32>> |> then(&[&1, Wire.varint(byte_size(bytes)), bytes])
      end
    ])
  end

  def center({x, z}), do: packet("set_chunk_cache_center", [Wire.varint(x), Wire.varint(z)])
  def unload({x, z}), do: packet("forget_level_chunk", <<z::signed-32, x::signed-32>>)
  def chat(text), do: packet("system_chat", [Wire.text_component(text), <<0>>])

  def block(position, state),
    do: packet("block_update", [Wire.position(position), Wire.varint(state)])

  def ack(sequence), do: packet("block_changed_ack", Wire.varint(sequence))

  @doc """
  A level event (vanilla `levelEvent`; type 2001 is a block's break particles
  and sound); a global one plays for every player at any distance.
  """
  def level_event(type, position, data, global \\ false)
      when type in 0..2_147_483_647 and data in -2_147_483_648..2_147_483_647 and
             is_boolean(global),
      do:
        packet("level_event", [
          <<type::32>>,
          Wire.position(position),
          <<data::signed-32, if(global, do: 1, else: 0)>>
        ])

  def block_destruction(entity_id, position, stage)
      when entity_id in 0..2_147_483_647 and stage in -1..9,
      do:
        packet("block_destruction", [
          Wire.varint(entity_id),
          Wire.position(position),
          <<stage::8>>
        ])

  @doc "One derived attribute `{id, base, modifiers}` of a living entity."
  def attribute(entity_id, attribute), do: attributes(entity_id, [attribute])

  @doc "Derived attributes `{id, base, modifiers}` of a living entity."
  def attributes(entity_id, attributes) do
    packet("update_attributes", [
      Wire.varint(entity_id),
      Wire.varint(length(attributes)),
      Enum.map(attributes, fn {id, base, modifiers} ->
        [
          Wire.varint(id),
          <<base::float-64>>,
          Wire.varint(length(modifiers)),
          Enum.map(modifiers, fn {name, amount, operation} ->
            [Wire.string(name), <<amount::float-64, operation>>]
          end)
        ]
      end)
    ])
  end

  def properties(values) when is_list(values) and length(values) <= 16 do
    [
      Wire.varint(length(values)),
      Enum.map(values, fn property ->
        [
          Wire.string(property.name),
          Wire.string(property.value),
          if(property.signature == nil, do: <<0>>, else: [<<1>>, Wire.string(property.signature)])
        ]
      end)
    ]
  end

  def remove_info(player), do: packet("player_info_remove", [<<1>>, player.uuid])

  def add_entity(player) do
    packet("add_entity", [
      Wire.varint(player.entity_id),
      player.uuid,
      Wire.varint(Data.player_type()),
      <<player.x::float-64, player.y::float-64, player.z::float-64, 0, angle(player.pitch),
        angle(player.yaw), angle(player.yaw), 0>>
    ])
  end

  def drowning_bubbles(entity_id) do
    life_entity_id!(entity_id)
    packet("entity_event", <<entity_id::signed-32, 67>>)
  end

  defp angle(value), do: round(value * 256 / 360) &&& 255
end
