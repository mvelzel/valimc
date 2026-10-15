defmodule Valimc.FoodPropertiesTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.{FoodProperties, ItemStack, ItemTypes, Wire}

  defp props, do: %{nutrition: 5, saturation: 6.0, can_always_eat: false}

  test "food patches keep effective default identity through both stack formats and the journal" do
    plain = ItemStack.new("bread", 3)
    patched = %{plain | components: %{"minecraft:food" => props()}}
    assert ItemStack.same_item?(plain, patched)

    for mode <- [:trusted, :untrusted] do
      bytes = patched |> ItemStack.encode(mode) |> IO.iodata_to_binary()
      assert {:ok, ^patched} = ItemStack.decode(bytes, mode)
    end

    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    snapshot = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => patched}})
    assert {:ok, bytes} = PlayerSnapshot.encode(<<9::128>>, snapshot)
    assert {:ok, saved} = PlayerSnapshot.decode(bytes, <<9::128>>)
    assert saved.inventory.slots[36] == patched
    changed = %{patched | components: %{"minecraft:food" => %{props() | nutrition: 6}}}
    refute ItemStack.same_item?(plain, changed)
    removed = %{plain | removed: MapSet.new(["minecraft:food"])}
    refute ItemStack.same_item?(plain, removed)
    stone = ItemStack.new("stone")
    assert ItemStack.same_item?(stone, %{stone | removed: MapSet.new(["minecraft:food"])})
  end

  test "invalid nutrition, nonfinite/negative saturation, booleans and truncated food cannot enter inventory" do
    invalid = [
      Wire.varint(-1) <> <<0.0::float-32, 0>>,
      <<0, -1.0::float-32, 0>>,
      <<0, 0x7FC00000::32, 0>>,
      <<0, 0x7F800000::32, 0>>,
      <<0, 0.0::float-32, 2>>,
      <<0>>,
      <<>>
    ]

    for payload <- invalid, mode <- [:trusted, :untrusted] do
      length = if mode == :untrusted, do: Wire.varint(byte_size(payload)), else: <<>>

      bytes =
        IO.iodata_to_binary([
          Wire.varint(1),
          Wire.varint(ItemTypes.id("stone")),
          <<1, 0>>,
          Wire.varint(ItemTypes.component_id("food")),
          length,
          payload
        ])

      assert {:error, _} = ItemStack.decode(bytes, mode)
    end

    for invalid <- [
          %{props() | nutrition: -1},
          %{props() | nutrition: 2_147_483_648},
          %{props() | saturation: -1.0},
          %{props() | can_always_eat: 1},
          Map.put(props(), :extra, 1)
        ],
        do: refute(FoodProperties.valid?(invalid))
  end

  test "maximum food values remain bounded and signed zero keeps its native record identity" do
    value = %{props() | nutrition: 2_147_483_647, saturation: 3.4028234663852886e38}
    assert FoodProperties.valid?(value)

    {^value, <<9>>} =
      FoodProperties.take(IO.iodata_to_binary([FoodProperties.encode(value), <<9>>]))

    positive = %{
      ItemStack.new("stone")
      | components: %{"minecraft:food" => %{props() | saturation: 0.0}}
    }

    negative = %{positive | components: %{"minecraft:food" => %{props() | saturation: -0.0}}}
    refute ItemStack.same_item?(positive, negative)
  end
end
