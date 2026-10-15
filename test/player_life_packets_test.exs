defmodule Valimc.PlayerLifePacketsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{ClientCommand, Data, Packets, Wire}
  defp payload({_, body}), do: IO.iodata_to_binary(body)

  test "fall events have no attacker/source position, and death uses a fixed-width entity ID" do
    packet = Packets.fall_damage(128)
    assert elem(packet, 0) == Data.id(:play, :clientbound, "damage_event")
    {128, rest} = Wire.take_varint(payload(packet))
    {type, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert type == Data.registry_id("minecraft:damage_type", "minecraft:fall")
    assert payload(Packets.death_animation(128)) == <<128::signed-32, 3>>

    for id <- [0, -1, 2_147_483_648, :bad] do
      assert_raise ArgumentError, fn -> Packets.fall_damage(id) end
      assert_raise ArgumentError, fn -> Packets.death_animation(id) end
      assert_raise ArgumentError, fn -> Packets.death(id, "fell") end
    end

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
