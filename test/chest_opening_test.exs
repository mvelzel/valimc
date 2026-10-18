defmodule Valimc.ChestOpeningTest do
  use ExUnit.Case, async: true
  alias Valimc.ChestOpening
  alias Valimc.Protocol.Data
  @block hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  test "provider checks combine current identity, entity presence and native lid obstructions" do
    air = Data.block("air")
    assert ChestOpening.provider?(@block, true, air, false)
    refute ChestOpening.provider?(@block, false, air, false)
    refute ChestOpening.provider?(@block, true, air, true)
    refute ChestOpening.provider?(air, true, air, false)
    refute ChestOpening.provider?(@block, true, Data.block("stone"), false)

    for above <- [-1, Data.block_state_count(), :unknown] do
      assert ChestOpening.obstructed?(above, false)
      refute ChestOpening.provider?(@block, true, above, false)
    end
  end
end
