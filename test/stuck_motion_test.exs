defmodule Valimc.Physics.StuckMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{StuckBlocks, StuckMotion}

  test "powder requires feet contact and malformed facts cannot reset falls" do
    assert StuckMotion.player_contact(:powder_snow, false, false, false) ==
             {:ok, %{multiplier: nil, reset_fall: false}}

    {:ok, contact} = StuckMotion.player_contact(:powder_snow, false, true, false)
    assert contact.reset_fall and elem(contact.multiplier, 1) == 1.5

    assert StuckMotion.player_contact(:cobweb, false, false, true) ==
             {:ok, %{multiplier: nil, reset_fall: false}}

    assert {:error, _} = StuckMotion.player_contact(:unknown, false, false, false)
    assert {:error, _} = StuckMotion.prepare({0, 0, 0}, {0, 0, 0}, {-1, 1, 1})
    assert StuckBlocks.fetch(1) == {:ok, :none}
    assert StuckBlocks.fetch(30519) == {:ok, :powder_snow}
    assert {:error, :unknown_block_state} = StuckBlocks.fetch(35723)
  end
end
