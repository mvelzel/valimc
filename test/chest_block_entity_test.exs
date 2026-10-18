defmodule Valimc.Protocol.ChestBlockEntityTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{ChestBlockEntity, Data, Wire}
  @facts JSON.decode!(File.read!("priv/protocol/chest_states.json"))
  @single hd(@facts["single_states"])
  @double Enum.find(@facts["states"], &(&1["part"] != "single"))["state"]

  test "entries are deterministically chunk-local and contain no stored inventory" do
    edits = %{
      {-1, 64, -1} => @single,
      {-16, 65, -16} => @single,
      {0, 64, -1} => @single,
      {-2, 64, -2} => @double,
      {-3, 64, -3} => Data.block("stone")
    }

    bytes = ChestBlockEntity.chunk_entries({-1, -1}, edits) |> IO.iodata_to_binary()

    assert bytes ==
             IO.iodata_to_binary([
               Wire.varint(2),
               ChestBlockEntity.chunk_entry({-16, 65, -16}),
               ChestBlockEntity.chunk_entry({-1, 64, -1})
             ])

    assert IO.iodata_to_binary(ChestBlockEntity.chunk_entries({2, 2}, edits)) == <<0>>
  end

  test "invalid height/border and excess chunk entries cannot produce unbounded packets" do
    for position <- [{0, -65, 0}, {0, 320, 0}, {30_000_000, 64, 0}, {0, 64, -30_000_000}],
        do: assert_raise(FunctionClauseError, fn -> ChestBlockEntity.chunk_entry(position) end)

    edits =
      Map.new(0..1024, fn i -> {{rem(i, 16), 64 + div(i, 256), rem(div(i, 16), 16)}, @single} end)

    assert_raise ArgumentError, fn -> ChestBlockEntity.chunk_entries({0, 0}, edits) end
  end
end
