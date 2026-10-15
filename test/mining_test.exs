defmodule Valimc.MiningTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.Mining
  alias Valimc.Protocol.Data

  test "native hardness and harvest requirements distinguish stone, dirt, air and bedrock" do
    assert Mining.hardness(Data.block("stone")) == 1.5
    assert Mining.requires_tool?(Data.block("stone"))
    refute Mining.requires_tool?(Data.block("dirt"))
    assert {:ok, +0.0} = Mining.rate(Data.block("bedrock"), 32, true)
    assert {:ok, :infinity} = Mining.rate(Data.block("air"), 1, true)
    assert {:ok, :nan} = Mining.rate(Data.block("air"), 0, true)
    assert {:ok, %{complete: true, crack: 2_147_483_647}} = Mining.advance(:infinity, 0)
    assert {:ok, %{complete: false, crack: 0}} = Mining.advance(:nan, 100)
  end

  test "progress uses native float multiplication by elapsed+1 and distinct stop/completion thresholds" do
    {:ok, rate} = Mining.rate(Data.block("stone"), 1, true)
    assert {:ok, %{complete: false, stoppable: false}} = Mining.advance(rate, 30)
    assert {:ok, %{complete: false, stoppable: true}} = Mining.advance(rate, 31)
    assert {:ok, %{complete: false}} = Mining.advance(rate, 43)
    assert {:ok, %{complete: true}} = Mining.advance(rate, 44)
    assert {:ok, %{complete: false}} = Mining.advance(rate, 2_147_483_647)

    for args <- [{-1, 1, true}, {Data.block_state_count(), 1, true}, {1, -1, true}, {1, 1, nil}],
        do: assert(apply(Mining, :rate, Tuple.to_list(args)) == {:error, :invalid_mining_input})

    assert {:error, :invalid_mining_input} = Mining.advance(rate, -1)
  end
end
