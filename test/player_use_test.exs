defmodule Valimc.PlayerUseTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerUse
  alias Valimc.Protocol.{ItemStack, UseItem, Wire}

  test "use requests reject malformed hands, sequences, nonfinite angles and trailing bytes" do
    body = <<0, 0, 0::float-32, 90::float-32>>
    assert {:ok, %{hand: :main, sequence: 0, yaw: 0.0, pitch: 90.0}} = UseItem.decode(body)

    for bytes <- [
          <<>>,
          binary_part(body, 0, 9),
          body <> <<0>>,
          <<2, 0, 0::64>>,
          <<0, 0, 0x7F800000::32, 0::32>>,
          IO.iodata_to_binary([<<0>>, Wire.varint(2_147_483_648), <<0::64>>])
        ] do
      assert {:error, :invalid_use_item} = UseItem.decode(bytes)
    end
  end

  test "native type-only use refresh accepts changed count/components but cancels a different item" do
    stack = ItemStack.new("bread", 2)
    use = PlayerUse.new(stack, :off, %{consumable: %{"ticks" => 2}})
    latest = %{stack | count: 1, removed: MapSet.new(["minecraft:food"])}
    assert {:using, next} = PlayerUse.tick(use, latest)
    assert {:finish, %{remaining: 0}} = PlayerUse.tick(next, latest)
    assert {:cancel, nil} = PlayerUse.tick(use, ItemStack.new("dirt"))
    assert {:cancel, nil} = PlayerUse.tick(use, nil)
    assert PlayerUse.start_flags(128, :main) == 129
    assert PlayerUse.start_flags(128, :off) == 131
    assert PlayerUse.stop_flags(131) == 130
    assert PlayerUse.start_flags(130, :main) == 129
  end
end
