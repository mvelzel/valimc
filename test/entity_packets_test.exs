defmodule Valimc.EntityPacketsTest do
  use ExUnit.Case, async: true

  alias Valimc.Protocol.{Data, EntityPackets, PackedVelocity, Packets, Wire}
  alias Valimc.Data.EntityTypes

  defp entity,
    do: %{
      entity_id: 300,
      uuid: <<0::128>>,
      x: -3.25,
      y: 64.2,
      z: 1.75,
      yaw: 1.40624999,
      pitch: -1.40624999,
      velocity: {-4.0, 2.5, -1.75}
    }

  defp payload({_, payload}), do: IO.iodata_to_binary(payload)

  test "spawn uses item type, float32 packed angles and the complete packed velocity" do
    e = entity()
    packet = EntityPackets.spawn_item(e)
    assert elem(packet, 0) == Data.id(:play, :clientbound, "add_entity")
    {300, <<uuid::binary-size(16), rest::binary>>} = Wire.take_varint(payload(packet))
    assert uuid == e.uuid
    {type, <<x::float-64, y::float-64, z::float-64, rest::binary>>} = Wire.take_varint(rest)
    assert type == EntityTypes.id("item") and {x, y, z} == {e.x, e.y, e.z}
    assert {:ok, velocity, <<255, 1, 1, 0>>} = PackedVelocity.take(rest)
    assert PackedVelocity.decode(PackedVelocity.encode(e.velocity)) == {:ok, velocity}

    for threshold <- [nil, 1, 256] do
      frame = Packets.frame(packet, threshold)
      assert {:ok, id, body, <<>>} = Wire.next_frame(frame, 2_097_152, threshold)
      assert id == elem(packet, 0) and body == payload(packet)
    end
  end
end
