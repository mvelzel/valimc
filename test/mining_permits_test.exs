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

  test "renewal retains the original blocks and cannot revive expired, mutated or released tokens" do
    blocks = %{{0, 63, 0} => 1}
    {:ok, permits, token} = MiningPermits.reserve(%MiningPermits{}, blocks, 0)
    {:ok, renewed, ^blocks} = MiningPermits.renew(permits, token, 9999)
    assert map_size(renewed.entries) == 1
    assert {:ok, ^blocks} = MiningPermits.lookup(renewed, token, 19_998)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(renewed, token, 19_999)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(permits, token, 10_000)

    unrelated = MiningPermits.invalidate(renewed, %{{1, 63, 0} => 1})
    assert {:ok, _, ^blocks} = MiningPermits.renew(unrelated, token, 10_001)
    mutated = MiningPermits.invalidate(renewed, blocks)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(mutated, token, 10_001)
    released = MiningPermits.remove(renewed, token)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(released, token, 10_001)
    assert MiningPermits.remove(released, token) == released
  end
end
