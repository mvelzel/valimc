defmodule Valimc.BlockRegistryTest do
  use ExUnit.Case, async: true
  alias Valimc.Registry.Blocks

  test "every state decodes to properties that encode back to it" do
    for state <- 0..(Blocks.state_count() - 1) do
      name = Blocks.name(Blocks.block_id(state))
      assert Blocks.state(name, Map.new(Blocks.properties(state))) == state
    end
  end

  test "chest states follow the generated property order" do
    assert Blocks.class(Blocks.default_state("chest")) == "ChestBlock"

    assert Blocks.properties(Blocks.default_state("chest")) ==
             [{"facing", "north"}, {"type", "single"}, {"waterlogged", "false"}]

    east = Blocks.state("chest", %{"facing" => "east", "waterlogged" => "true"})
    assert east in Blocks.states("chest")

    assert Blocks.properties(east) == [
             {"facing", "east"},
             {"type", "single"},
             {"waterlogged", "true"}
           ]

    assert_raise ArgumentError, fn -> Blocks.state("chest", %{"facing" => "up"}) end
  end
end
