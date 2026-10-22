defmodule Valimc.BlockRegistryTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks

  test "every state decodes to properties that encode back to it" do
    for state <- 0..(Blocks.state_count() - 1) do
      name = Blocks.name(Blocks.block_id(state))
      assert Blocks.state(name, Map.new(Blocks.properties(state))) == state
    end
  end
end
