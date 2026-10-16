defmodule Valimc.Protocol.Packets do
  @moduledoc "Minecraft 26.3 clientbound packet payloads. All integers are network endian."
  alias Valimc.Protocol.{Data, EntityPackets, ItemStack, Wire}
  import Bitwise

  def time(data) do
    entries =
      Enum.sort_by(data.clocks, fn {name, _} ->
        Data.registry_id("minecraft:world_clock", name)
      end)

    body = [
      <<data.game_time::signed-64>>,
      Wire.varint(length(entries)),
      Enum.map(entries, fn {name, clock} ->
        [
          Wire.varint(Data.registry_id("minecraft:world_clock", name)),
          Valimc.World.ClockState.network(clock, data.advance_time)
        ]
      end)
    ]

    packet("set_time", IO.iodata_to_binary(body))
  end

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

  def inventory(inventory),
    do: inventory_content(0, inventory, Valimc.Inventory.display_contents(inventory))

  def open_table(container) when container in 1..127 do
    packet("open_screen", [
      Wire.varint(container),
      Wire.varint(12),
      Valimc.Protocol.NBT.encode({:compound, %{"translate" => {:string, "container.crafting"}}})
    ])
  end

  def table_inventory(container, inventory) when container in 1..127,
    do: inventory_content(container, inventory, Valimc.TableMenu.contents(inventory))

  defp inventory_content(container, inventory, contents) do
    packet("container_set_content", [
      Wire.varint(container),
      Wire.varint(inventory.state_id),
      Wire.varint(46),
      Enum.map(contents, &ItemStack.encode/1),
      ItemStack.encode(inventory.carried)
    ])
  end

  def held_slot(slot), do: packet("set_held_slot", Wire.varint(slot))
  def cursor(stack), do: packet("set_cursor_item", ItemStack.encode(stack))

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

  def login(player) do
    d = Valimc.config(:view_distance)

    packet("login", [
      <<player.entity_id::signed-32, 0, 1>>,
      Wire.string("minecraft:overworld"),
      Wire.varint(Valimc.config(:max_players)),
      Wire.varint(d),
      Wire.varint(d),
      <<0, 1, 0>>,
      spawn_info(player, Map.get(player, :last_death)),
      <<0, 0>>
    ])
  end

  def respawn(player, last_death \\ nil),
    do: packet("respawn", [spawn_info(player, last_death), <<0>>])

  defp spawn_info(player, last_death) do
    [
      Wire.varint(Data.registry_id("minecraft:dimension_type", "minecraft:overworld")),
      Wire.string("minecraft:overworld"),
      <<0::64>>,
      Wire.varint(Valimc.GameMode.id(Map.get(player, :game_mode, %Valimc.GameMode{}).current)),
      previous_mode(Map.get(player, :game_mode, %Valimc.GameMode{}).previous),
      <<0, 1>>,
      death_location(last_death),
      <<0>>,
      Wire.varint(63)
    ]
  end

  defp death_location(nil), do: <<0>>

  defp death_location({x, y, z} = position)
       when is_integer(x) and abs(x) <= 29_999_984 and is_integer(z) and abs(z) <= 29_999_984 and
              is_integer(y) and abs(y) <= 1_000_000,
       do: [<<1>>, Wire.string("minecraft:overworld"), Wire.position(position)]

  defp death_location(_), do: raise(ArgumentError, "invalid death location")

  def teleport(player, teleport_id) do
    %{x: x, y: y, z: z, yaw: yaw, pitch: pitch} = player

    packet("player_position", [
      Wire.varint(teleport_id),
      <<x::float-64, y::float-64, z::float-64, 0.0::float-64, 0.0::float-64, 0.0::float-64,
        yaw::float-32, pitch::float-32, 0::32>>
    ])
  end

  def spawn_position do
    packet("set_default_spawn_position", [
      Wire.string("minecraft:overworld"),
      Wire.position({0, 64, 0}),
      <<0.0::float-32, 0.0::float-32>>
    ])
  end

  def abilities(abilities \\ Valimc.PlayerAbilities.for_mode(:creative)) do
    packet(
      "player_abilities",
      <<Valimc.PlayerAbilities.flags(abilities), abilities.flying_speed::float-32,
        abilities.walking_speed::float-32>>
    )
  end

  def health(health \\ %Valimc.PlayerHealth{}, food \\ %Valimc.PlayerFood{}) do
    unless Valimc.PlayerHealth.valid?(health) and Valimc.PlayerFood.valid?(food),
      do: raise(ArgumentError, "invalid health/food")

    packet("set_health", [
      <<health.value::float-32>>,
      Wire.varint(food.level),
      <<food.saturation::float-32>>
    ])
  end

  def level_load_start, do: packet("game_event", <<13, 0.0::float-32>>)

  def update_effect(entity_id, effect_id, {ticks, level, ambient, particles, icon} = rung, blend) do
    life_entity_id!(entity_id)

    unless Valimc.Protocol.EffectTypes.valid_id?(effect_id) and Valimc.StatusEffect.valid?([rung]) and
             is_boolean(blend),
           do: raise(ArgumentError, "invalid effect packet")

    flags =
      if(ambient, do: 1, else: 0) + if(particles, do: 2, else: 0) +
        if(icon, do: 4, else: 0) + if(blend, do: 8, else: 0)

    packet("update_mob_effect", [
      Wire.varint(entity_id),
      Wire.varint(effect_id),
      Wire.varint(level),
      Wire.varint(ticks),
      <<flags>>
    ])
  end

  def remove_effect(entity_id, effect_id) do
    life_entity_id!(entity_id)

    unless Valimc.Protocol.EffectTypes.valid_id?(effect_id),
      do: raise(ArgumentError, "invalid effect packet")

    packet("remove_mob_effect", [Wire.varint(entity_id), Wire.varint(effect_id)])
  end

  def self_magic_damage(entity_id) do
    life_entity_id!(entity_id)

    packet("damage_event", [
      Wire.varint(entity_id),
      Wire.varint(Data.registry_id("minecraft:damage_type", "minecraft:indirect_magic")),
      Wire.varint(entity_id + 1),
      Wire.varint(entity_id + 1),
      <<0>>
    ])
  end

  def damage_event(entity_id, source \\ :fall) do
    life_entity_id!(entity_id)

    unless source in [
             :fall,
             :stalagmite,
             :freeze,
             :drown,
             :out_of_world,
             :starve,
             :on_fire,
             :in_fire,
             :lava,
             :hot_floor,
             :campfire,
             :cactus,
             :sweet_berry_bush,
             :magic,
             :wither
           ],
           do: raise(ArgumentError, "invalid damage source")

    packet("damage_event", [
      Wire.varint(entity_id),
      Wire.varint(
        Data.registry_id("minecraft:damage_type", "minecraft:" <> Atom.to_string(source))
      ),
      <<0, 0, 0>>
    ])
  end

  def death(entity_id, message) do
    life_entity_id!(entity_id)

    unless (is_binary(message) and byte_size(message) <= 1024 and String.valid?(message)) or
             is_struct(message, Valimc.Protocol.ServerText) or
             Valimc.Protocol.TextComponent.valid?(message),
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

  def armor_break(entity_id, slot) when slot in 5..8 do
    life_entity_id!(entity_id)
    packet("entity_event", <<entity_id::signed-32, Valimc.ArmorDurability.break_event(slot)>>)
  end

  def use_item_finished(entity_id) do
    life_entity_id!(entity_id)
    packet("entity_event", <<entity_id::signed-32, 9>>)
  end

  defp life_entity_id!(entity_id) do
    unless is_integer(entity_id) and entity_id in 1..2_147_483_647,
      do: raise(ArgumentError, "invalid entity ID")
  end

  def difficulty(%{level: level, locked: locked})
      when is_integer(level) and level in 0..3 and is_boolean(locked),
      do: packet("change_difficulty", <<level, if(locked, do: 1, else: 0)>>)

  def commands, do: packet("commands", Valimc.Commands.graph_payload())
  def center({x, z}), do: packet("set_chunk_cache_center", [Wire.varint(x), Wire.varint(z)])
  def unload({x, z}), do: packet("forget_level_chunk", <<z::signed-32, x::signed-32>>)
  def chat(text), do: packet("system_chat", [Wire.text_component(text), <<0>>])

  def block(position, state),
    do: packet("block_update", [Wire.position(position), Wire.varint(state)])

  def ack(sequence), do: packet("block_changed_ack", Wire.varint(sequence))

  def block_destruction(entity_id, position, stage)
      when entity_id in 0..2_147_483_647 and stage in -1..9,
      do:
        packet("block_destruction", [
          Wire.varint(entity_id),
          Wire.position(position),
          <<stage::8>>
        ])

  def player_info(player) do
    packet("player_info_update", [
      <<0x1D, 1>>,
      player.uuid,
      Wire.string(player.name),
      properties(Map.get(player, :properties, [])),
      Wire.varint(Valimc.GameMode.id(Map.get(player, :game_mode, %Valimc.GameMode{}).current)),
      <<1, 0>>
    ])
  end

  defp previous_mode(nil), do: <<0>>
  defp previous_mode(mode), do: Wire.varint(Valimc.GameMode.id(mode) + 1)

  def interaction_attributes(player) do
    attributes = Valimc.PlayerInteraction.attributes(player.game_mode.current)
    attribute_packet(player.entity_id, attributes)
  end

  def armor_attributes(player, attributes),
    do: attribute_packet(player.entity_id, Valimc.PlayerArmor.protocol_attributes(attributes))

  def movement_attributes(player, attribute), do: attribute_packet(player.entity_id, [attribute])

  def absorption_attributes(player, attribute),
    do: attribute_packet(player.entity_id, [attribute])

  defp attribute_packet(entity_id, attributes) do
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

  def remove_info({_, uuid, _, _, _, _, _, _, _, _, _, _}),
    do: packet("player_info_remove", [<<1>>, uuid])

  def remove_info(player), do: packet("player_info_remove", [<<1>>, player.uuid])

  def remove_entity({id, _, _, _, _, _, _, _, _, _, _, _}),
    do: packet("remove_entities", [<<1>>, Wire.varint(id)])

  def remove_entity(player), do: packet("remove_entities", [<<1>>, Wire.varint(player.entity_id)])

  def add_entity(player) do
    packet("add_entity", [
      Wire.varint(player.entity_id),
      player.uuid,
      Wire.varint(Data.player_type()),
      <<player.x::float-64, player.y::float-64, player.z::float-64, 0, angle(player.pitch),
        angle(player.yaw), angle(player.yaw), 0>>
    ])
  end

  def view(player),
    do:
      {player.entity_id, player.uuid, round(player.x * 4096), round(player.y * 4096),
       round(player.z * 4096), angle(player.yaw), angle(player.pitch), shared_flags(player),
       Map.get(player, :pose, :standing), Valimc.PlayerEnvironment.frozen(player),
       player_health_value(player), Map.get(player, :equipment, %{})}

  def player_flags(player),
    do: EntityPackets.metadata(player.entity_id, shared_flags: shared_flags(player))

  def player_pose(player),
    do: EntityPackets.metadata(player.entity_id, pose: Map.get(player, :pose, :standing))

  def player_health(player),
    do: EntityPackets.metadata(player.entity_id, health: player_health_value(player))

  def player_absorption(player),
    do: EntityPackets.metadata(player.entity_id, absorption: Map.get(player, :absorption, 0.0))

  def player_use(player),
    do: EntityPackets.metadata(player.entity_id, living_flags: Map.get(player, :use_flags, 0))

  def player_equipment(player, previous \\ %{}) do
    case Valimc.PlayerEquipment.changes(Map.get(player, :equipment, %{}), previous) do
      [] -> []
      changes -> [EntityPackets.equipment(player.entity_id, changes)]
    end
  end

  defp player_health_value(player), do: Map.get(player, :health, %Valimc.PlayerHealth{}).value

  def player_environment(player),
    do:
      EntityPackets.metadata(player.entity_id,
        frozen_ticks: Valimc.PlayerEnvironment.frozen(player),
        air_supply: Valimc.PlayerAir.supply(player)
      )

  def player_air(player),
    do: EntityPackets.metadata(player.entity_id, air_supply: Valimc.PlayerAir.supply(player))

  def drowning_bubbles(entity_id) do
    life_entity_id!(entity_id)
    packet("entity_event", <<entity_id::signed-32, 67>>)
  end

  def shared_flags(player) do
    flags = Map.get(player, :input, %Valimc.PlayerInput{}).shared_flags &&& bnot(17)
    flags = if Map.get(player, :fire_ticks, 0) > 0, do: flags ||| 1, else: flags
    if Map.get(player, :motion, %Valimc.PlayerMotion{}).swimming, do: flags ||| 16, else: flags
  end

  def move_entity(player, {_, _, x, y, z, yaw, pitch, flags, pose, frozen, health, equipment}) do
    dx = round(player.x * 4096) - x
    dy = round(player.y * 4096) - y
    dz = round(player.z * 4096) - z

    cond do
      not Enum.all?([dx, dy, dz], &(&1 >= -32768 and &1 <= 32767)) ->
        # Recreated entities need metadata even when their old flags did not change.
        [
          remove_entity(player),
          add_entity(player),
          player_flags(player),
          player_pose(player),
          player_environment(player),
          player_use(player),
          player_health(player)
        ] ++ player_equipment(player)

      true ->
        movement =
          if {dx, dy, dz, angle(player.yaw), angle(player.pitch)} == {0, 0, 0, yaw, pitch} do
            []
          else
            [
              packet("move_entity_pos_rot", [
                Wire.varint(player.entity_id),
                <<1, dx::signed-16, dy::signed-16, dz::signed-16, angle(player.yaw),
                  angle(player.pitch)>>
              ])
            ]
          end

        metadata = if shared_flags(player) == flags, do: [], else: [player_flags(player)]

        pose_update =
          if Map.get(player, :pose, :standing) == pose, do: [], else: [player_pose(player)]

        environment =
          if Valimc.PlayerEnvironment.frozen(player) == frozen,
            do: [],
            else: [player_environment(player)]

        health_update =
          if player_health_value(player) == health, do: [], else: [player_health(player)]

        movement ++
          metadata ++
          pose_update ++ environment ++ health_update ++ player_equipment(player, equipment)
    end
  end

  defp angle(value), do: round(value * 256 / 360) &&& 255
end
