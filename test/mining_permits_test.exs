defmodule Valimc.MiningPermitsTest do
  use ExUnit.Case, async: true
  alias Valimc.World.MiningPermits

  test "bounded permits expire, reject target ABA, and retain unrelated work" do
    blocks = %{{0, 63, 0} => 1}
    {:ok, first, token} = MiningPermits.reserve(%MiningPermits{}, blocks, 0)
    assert {:ok, ^blocks} = MiningPermits.lookup(first, token, 9999)
    assert {:error, :stale_mining_permit} = MiningPermits.lookup(first, token, 10_000)
    assert MiningPermits.invalidate(first, %{{1, 63, 0} => 1}) == first
    invalidated = MiningPermits.invalidate(first, %{{0, 63, 0} => 1})
    assert {:error, :stale_mining_permit} = MiningPermits.lookup(invalidated, token, 1)

    full =
      Enum.reduce(1..127, first, fn _, permits ->
        {:ok, next, _} = MiningPermits.reserve(permits, blocks, 0)
        next
      end)

    assert {:error, :mining_permit_limit} = MiningPermits.reserve(full, blocks, 1)
    assert {:ok, renewed, _} = MiningPermits.reserve(full, blocks, 10_000)
    assert map_size(renewed.entries) == 1
  end
end
