defmodule Valimc.PlayerBurningTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerBurning

  test "ignition extends duration, clears freezing even without extending, and saturates" do
    assert {:ok, %{ticks: 300, clear_freeze: true}} = PlayerBurning.ignite_seconds(-20, 15, 1)
    assert {:ok, %{ticks: 300, clear_freeze: true}} = PlayerBurning.ignite_ticks(300, 20, 1)
    assert {:ok, %{ticks: 2_147_483_647}} = PlayerBurning.ignite_ticks(-20, 2_147_483_647, 1024)
    assert {:ok, -20} = PlayerBurning.clear(-20)
  end

  test "creative assignment caps a new duration without reinterpreting an unextended old one" do
    assert {:ok, 1} = PlayerBurning.assign(300, true)
    assert {:ok, %{ticks: 300}} = PlayerBurning.ignite_ticks(300, 20, 1, true)
    assert {:ok, %{ticks: 1}} = PlayerBurning.ignite_ticks(300, 400, 1, true)
    assert {:ok, %{ticks: 1, damage: 1.0}} = PlayerBurning.tick(300, false, false, true)
  end

  test "burn callbacks precede decrement, skip lava and immunity, and retire the visible flag" do
    assert {:ok, %{ticks: 19, damage: 1.0, on_fire: true}} = PlayerBurning.tick(20, false, false)
    assert {:ok, %{ticks: 20, damage: +0.0}} = PlayerBurning.tick(21, false, false)
    assert {:ok, %{ticks: 299, damage: +0.0}} = PlayerBurning.tick(300, false, true)
    assert {:ok, %{ticks: 0, damage: +0.0, on_fire: false}} = PlayerBurning.tick(20, true, false)
    assert {:ok, %{ticks: 0, on_fire: false}} = PlayerBurning.tick(1, false, false)
    assert {:ok, %{ticks: -20}} = PlayerBurning.tick(-20, false, false)
  end

  test "lava immunity preserves counters and freeze state while zero burning-time still requests damage" do
    assert {:ok, %{ticks: -20, damage: +0.0, clear_freeze: false}} =
             PlayerBurning.lava(-20, true, 1)

    assert {:ok, %{ticks: 0, damage: 4.0, clear_freeze: true}} = PlayerBurning.lava(-20, false, 0)
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
