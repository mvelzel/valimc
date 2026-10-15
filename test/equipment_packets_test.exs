defmodule Valimc.EquipmentPacketsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.EntityPackets

  test "equipment batches cannot be empty, duplicate, oversized or use unknown slots/entities" do
    for changes <- [
          [],
          [{0, nil}, {0, nil}],
          [{8, nil}],
          [{-1, nil}],
          Enum.map(0..8, &{&1, nil}),
          [{:main, nil}]
        ] do
      assert_raise ArgumentError, fn -> EntityPackets.equipment(1, changes) end
    end

    for id <- [0, -1, 2_147_483_648],
        do: assert_raise(ArgumentError, fn -> EntityPackets.equipment(id, [{0, nil}]) end)
  end
end
