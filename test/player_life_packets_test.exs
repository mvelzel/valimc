defmodule Valimc.PlayerLifePacketsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{ClientCommand, Data, Packets, Wire}
  defp payload({_, body}), do: IO.iodata_to_binary(body)

  test "fire sources and equipped armor attributes use the pinned registries" do
    for source <- [:in_fire, :on_fire, :lava, :hot_floor] do
      {128, body} = Packets.damage_event(128, source) |> payload() |> Wire.take_varint()
      {id, <<0, 0, 0>>} = Wire.take_varint(body)

      assert id ==
               Data.registry_id("minecraft:damage_type", "minecraft:" <> Atom.to_string(source))
    end

    {128, <<3, 1, 20.0::float-64, 0, 2, 8.0::float-64, 0, 10, 0.4::float-64, 0>>} =
      Packets.armor_attributes(%{entity_id: 128}, %{armor: 20, toughness: 8.0, burning_time: 0.4})
      |> payload()
      |> Wire.take_varint()
  end

  test "fall events have no attacker/source position, and death uses a fixed-width entity ID" do
    packet = Packets.damage_event(128)
    assert elem(packet, 0) == Data.id(:play, :clientbound, "damage_event")
    {128, rest} = Wire.take_varint(payload(packet))
    {type, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert type == Data.registry_id("minecraft:damage_type", "minecraft:fall")
    {128, rest} = Wire.take_varint(payload(Packets.damage_event(128, :stalagmite)))
    {type, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert type == Data.registry_id("minecraft:damage_type", "minecraft:stalagmite")
    assert_raise ArgumentError, fn -> apply(Packets, :damage_event, [128, :bad]) end
    {128, rest} = Wire.take_varint(payload(Packets.damage_event(128, :freeze)))
    {type, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert type == Data.registry_id("minecraft:damage_type", "minecraft:freeze")
    assert payload(Packets.death_animation(128)) == <<128::signed-32, 3>>

    for id <- [0, -1, 2_147_483_648, :bad] do
      assert_raise ArgumentError, fn -> Packets.damage_event(id) end
      assert_raise ArgumentError, fn -> Packets.death_animation(id) end
      assert_raise ArgumentError, fn -> Packets.death(id, "fell") end
    end

    assert {_, _} = Packets.death(1, String.duplicate("a", 1024))

    for message <- [nil, <<255>>, String.duplicate("a", 1025)] do
      assert_raise ArgumentError, fn -> Packets.death(1, message) end
    end

    for location <- [:bad, {0, 1_000_001, 0}, {30_000_000, 64, 0}, {0.5, 64, 0}] do
      assert_raise ArgumentError, fn -> Packets.respawn(%{}, location) end
    end
  end

  test "client lifecycle enums reject invalid, incomplete, oversized and trailing requests" do
    assert {:ok, :respawn} = ClientCommand.decode(<<0>>)
    assert {:ok, :stats} = ClientCommand.decode(<<1>>)
    assert {:ok, :gamerules} = ClientCommand.decode(<<2>>)
    assert {:ok, :respawn} = ClientCommand.decode(<<128, 0>>)

    for bytes <- [
          <<>>,
          <<128>>,
          <<3>>,
          <<0, 0>>,
          Wire.varint(-1),
          <<128, 128, 128, 128, 16>>,
          <<128, 128, 128, 128, 128, 0>>,
          nil
        ] do
      assert {:error, :invalid_client_command} = ClientCommand.decode(bytes)
    end
  end
end
