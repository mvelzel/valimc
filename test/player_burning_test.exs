defmodule Valimc.PlayerBurningTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerBurning

  test "creative assignment caps a new duration without reinterpreting an unextended old one" do
    assert {:ok, 1} = PlayerBurning.assign(300, true)
    assert {:ok, %{ticks: 300}} = PlayerBurning.ignite_ticks(300, 20, 1, true)
    assert {:ok, %{ticks: 1}} = PlayerBurning.ignite_ticks(300, 400, 1, true)
    assert {:ok, %{ticks: 1, damage: 1.0}} = PlayerBurning.tick(300, false, false, true)
  end

  test "malformed counters, durations, factors and flags refuse" do
    for ticks <- [-2_147_483_649, 2_147_483_648, nil, 1.0] do
      refute PlayerBurning.valid?(ticks)
      assert {:error, :invalid_burning} = PlayerBurning.tick(ticks, false, false)
    end

    assert {:error, :invalid_burning} = PlayerBurning.ignite_ticks(0, -1, 1)
    assert {:error, :invalid_burning} = PlayerBurning.ignite_ticks(0, 20, 1025)
    assert {:error, :invalid_burning} = PlayerBurning.ignite_seconds(0, -0.1, 1)
    assert {:error, :invalid_burning} = PlayerBurning.tick(0, nil, false)
  end
end
