defmodule Valimc.SilverfishTest do
  @moduledoc """
  Infested blocks (VMC-043b6): a harvest lets out a silverfish unless the
  tool has Silk Touch.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Breaking
  alias Valimc.Data.Blocks
  alias Valimc.Protocol.ItemStack

  test "an infested block's harvest lets out a silverfish, not with Silk Touch" do
    state = Blocks.default_state("infested_stone")
    assert Breaking.plan(state, {0, 64, 0}, nil, true, %{}).infestation

    pick = %{
      ItemStack.new("diamond_pickaxe")
      | components: %{"minecraft:enchantments" => %{"minecraft:silk_touch" => 1}}
    }

    refute Breaking.plan(state, {0, 64, 0}, pick, true, %{}).infestation
    refute Breaking.plan(Blocks.default_state("stone"), {0, 64, 0}, nil, true, %{}).infestation
  end
end
