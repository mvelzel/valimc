defmodule Valimc.Protocol.Packets do
  @moduledoc "Minecraft 26.3 clientbound packet payloads. All integers are network endian."
  alias Valimc.Protocol.{Data, Wire}
  import Bitwise
  def packet(name, payload, state \\ :play), do: {Data.id(state, :clientbound, name), payload}
  def frame({id, payload}, threshold), do: Wire.frame(id, payload, threshold)

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
      Wire.varint(Data.registry_id("minecraft:dimension_type", "minecraft:overworld")),
      Wire.string("minecraft:overworld"),
      <<0::64, 1, 0, 0, 1, 0, 0>>,
      Wire.varint(63),
      <<0, 0>>
    ])
  end

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

  def abilities, do: packet("player_abilities", <<0x0D, 0.05::float-32, 0.1::float-32>>)
  def health, do: packet("set_health", [<<20.0::float-32>>, Wire.varint(20), <<5.0::float-32>>])
  def center({x, z}), do: packet("set_chunk_cache_center", [Wire.varint(x), Wire.varint(z)])
  def unload({x, z}), do: packet("forget_level_chunk", <<z::signed-32, x::signed-32>>)
  def chat(text), do: packet("system_chat", [Wire.text_component(text), <<0>>])

  def block(position, state),
    do: packet("block_update", [Wire.position(position), Wire.varint(state)])

  def ack(sequence), do: packet("block_changed_ack", Wire.varint(sequence))

  def player_info(player) do
    packet("player_info_update", [
      <<0x1D, 1>>,
      player.uuid,
      Wire.string(player.name),
      <<0, 1, 1, 0>>
    ])
  end

  def remove_info({_, uuid, _, _, _, _, _}), do: packet("player_info_remove", [<<1>>, uuid])
  def remove_info(player), do: packet("player_info_remove", [<<1>>, player.uuid])

  def remove_entity({id, _, _, _, _, _, _}),
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
       round(player.z * 4096), angle(player.yaw), angle(player.pitch)}

  def move_entity(player, {_, _, x, y, z, _, _}) do
    dx = round(player.x * 4096) - x
    dy = round(player.y * 4096) - y
    dz = round(player.z * 4096) - z

    if Enum.all?([dx, dy, dz], &(&1 >= -32768 and &1 <= 32767)) do
      packet("move_entity_pos_rot", [
        Wire.varint(player.entity_id),
        <<1, dx::signed-16, dy::signed-16, dz::signed-16, angle(player.yaw), angle(player.pitch)>>
      ])
    else
      # Respawn tracking for large creative-mode teleports avoids guessing new PositionPath encodings.
      [remove_entity(player), add_entity(player)]
    end
  end

  defp angle(value), do: round(value * 256 / 360) &&& 255
end
