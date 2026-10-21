defmodule Valimc.Protocol.ChestBlockEntityTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ChestBlockEntity
  @facts JSON.decode!(File.read!("priv/protocol/chest_states.json"))
  @single hd(@facts["single_states"])

  test "invalid height/border and excess chunk entries cannot produce unbounded packets" do
    for position <- [{0, -65, 0}, {0, 320, 0}, {30_000_000, 64, 0}, {0, 64, -30_000_000}],
        do: assert_raise(FunctionClauseError, fn -> ChestBlockEntity.chunk_entry(position) end)

    edits =
      Map.new(0..1024, fn i -> {{rem(i, 16), 64 + div(i, 256), rem(div(i, 16), 16)}, @single} end)

    preserved =
      for i <- 0..98_304, do: {{rem(i, 16), -64 + div(i, 256), rem(div(i, 16), 16)}, 7, nil}

    assert_raise ArgumentError, fn -> ChestBlockEntity.chunk_entries({0, 0}, edits, preserved) end
  end
end
