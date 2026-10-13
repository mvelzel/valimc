defmodule Valimc.EntityPacketsTest do
  use ExUnit.Case, async: true

  alias Valimc.Protocol.{
    Data,
    EntityPackets,
    EntityTypes,
    ItemStack,
    PackedVelocity,
    Packets,
    Wire
  }

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

  test "metadata uses pinned accessor types and preserves exact accepted stack bytes" do
    stack = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"probe" => {:string, "entity"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    bytes =
      EntityPackets.metadata(300, item_stack: stack, no_gravity: true, shared_flags: 64)
      |> payload()

    {300, <<0, 0, 64, 5, 8, 1, 8, 7, rest::binary>>} = Wire.take_varint(bytes)
    assert {:ok, ^stack, <<255>>} = ItemStack.take(rest)

    assert EntityTypes.field(:item_stack) == %{
             "index" => 8,
             "serializer" => EntityTypes.serializer("item_stack")
           }

    assert payload(EntityPackets.metadata(300, item_stack: nil)) ==
             Wire.varint(300) <> <<8, 7, 0, 255>>

    assert payload(EntityPackets.metadata(300, [])) == Wire.varint(300) <> <<255>>

    large = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"probe" => {:string, String.duplicate("a", 5000)}}}
        }
    }

    packet = EntityPackets.metadata(300, item_stack: large)
    assert {:ok, _, body, <<>>} = Wire.next_frame(Packets.frame(packet, 256), 2_097_152, 256)
    assert body == payload(packet)
  end

  test "motion, pickup and bounded removal carry only the specified entity references" do
    vector = {-5.0, 0.1, 2.0}
    {300, rest} = EntityPackets.motion(300, vector) |> payload() |> Wire.take_varint()
    assert rest == PackedVelocity.encode(vector)

    assert payload(EntityPackets.pickup(300, 301, 7)) ==
             Wire.varint(300) <> Wire.varint(301) <> <<7>>

    assert payload(EntityPackets.remove([300, 301])) ==
             <<2>> <> Wire.varint(300) <> Wire.varint(301)

    assert payload(EntityPackets.remove([])) == <<0>>
    {4096, _} = EntityPackets.remove(Enum.to_list(1..4096)) |> payload() |> Wire.take_varint()
    assert_raise ArgumentError, fn -> EntityPackets.remove(Enum.to_list(1..4097)) end
  end

  test "invalid helper inputs cannot encode malformed or oversized entity state" do
    for id <- [-1, 0, 2_147_483_648, :item] do
      assert_raise ArgumentError, fn -> EntityPackets.motion(id, {0, 0, 0}) end
    end

    for override <- [
          %{uuid: <<0>>},
          %{x: 30_000_000},
          %{y: 1_000_001},
          %{yaw: :nan},
          %{velocity: []}
        ] do
      assert_raise ArgumentError, fn ->
        EntityPackets.spawn_item(Map.merge(entity(), override))
      end
    end

    for changes <- [
          [health: 20],
          [shared_flags: -1],
          [shared_flags: 256],
          [no_gravity: 1],
          [item_stack: %{}],
          [item_stack: %{ItemStack.new("stone") | count: 65}],
          [no_gravity: true, no_gravity: false],
          [:bad],
          List.duplicate({:shared_flags, 0}, 4)
        ] do
      assert_raise ArgumentError, fn -> EntityPackets.metadata(300, changes) end
    end

    for count <- [-1, 0, 100, :count] do
      assert_raise ArgumentError, fn -> EntityPackets.pickup(300, 301, count) end
    end

    assert_raise ArgumentError, fn -> EntityPackets.remove([300, -1]) end
    assert_raise ArgumentError, fn -> apply(EntityPackets, :remove, [[300 | :bad_tail]]) end

    assert_raise ArgumentError, fn ->
      apply(EntityPackets, :metadata, [300, [{:no_gravity, true} | :bad_tail]])
    end

    assert_raise ArgumentError, fn -> apply(EntityPackets, :remove, [%{}]) end
    assert_raise ArgumentError, fn -> EntityPackets.spawn_item(%{}) end
  end
end
