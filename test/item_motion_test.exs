defmodule Valimc.Physics.ItemMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ItemMotion

  test "gravity precedes movement and drag follows supplied collision velocity" do
    assert {:ok, %{request: {0.3, y, -0.2} = requested}} =
             ItemMotion.prepare({0.3, 0.1, -0.2}, %ItemMotion{})

    assert y == 0.060000000000000005

    assert {:ok, {0.2940000057220459, 0.058800001144409184, -0.1960000038146973}} =
             ItemMotion.finish(requested, false, 0.6)

    assert {:ok, {0.17640001773834227, +0.0, -0.11760001182556153}} =
             ItemMotion.finish({0.3, +0.0, -0.2}, true, 0.6)
  end

  test "fluid depth and rise use strict native float boundaries, including no-gravity items" do
    for kind <- [:water, :lava] do
      assert {:ok, %{velocity: {1.0, -0.04, +0.0}}} =
               ItemMotion.prepare({1, 0, 0}, %ItemMotion{fluid: kind, depth: 0.10000000149011612})

      assert {:ok, %{velocity: {horizontal, rise, +0.0}}} =
               ItemMotion.prepare({1, 0, 0}, %ItemMotion{
                 fluid: kind,
                 depth: 0.10000000894069672,
                 no_gravity: true
               })

      assert horizontal == if(kind == :water, do: 0.9900000095367432, else: 0.949999988079071)
      assert rise == 0.0005000000237487257
      boundary = 0.05999999865889549

      assert {:ok, %{velocity: {_, ^boundary, _}}} =
               ItemMotion.prepare({0, boundary, 0}, %ItemMotion{fluid: kind, depth: 0.5})
    end

    assert {:ok, %{velocity: {1.0, +0.0, +0.0}}} =
             ItemMotion.prepare({1, 0, 0}, %ItemMotion{no_gravity: true})
  end

  test "resting items skip movement until supplied refresh; horizontal motion wakes them" do
    assert {:ok, %{request: nil, velocity: {+0.0, -0.04, +0.0}}} =
             ItemMotion.prepare({0, 0, 0}, %ItemMotion{on_ground: true})

    assert {:ok, %{request: {+0.0, -0.04, +0.0}}} =
             ItemMotion.prepare({0, 0, 0}, %ItemMotion{on_ground: true, refresh: true})

    assert {:ok, %{request: {0.004, -0.04, +0.0}}} =
             ItemMotion.prepare({0.004, 0, 0}, %ItemMotion{on_ground: true})

    assert {:ok, %{request: {+0.0, -0.04, +0.0}}} =
             ItemMotion.prepare({0, 0, 0}, %ItemMotion{})
  end

  test "ground friction and bounce use post-collision support, without bouncing upward velocity" do
    assert {:ok, {_, 0.49000000953674316, _}} = ItemMotion.finish({0, -1, 0}, true, 0.6)
    assert {:ok, {_, 0.9800000190734863, _}} = ItemMotion.finish({0, 1, 0}, true, 0.6)
    {:ok, {stone, _, _}} = ItemMotion.finish({1, 0, 0}, true, 0.6)
    {:ok, {ice, _, _}} = ItemMotion.finish({1, 0, 0}, true, 0.98)
    assert ice > stone
  end

  test "missing or unbounded observations refuse before physics" do
    for facts <- [
          %{},
          %ItemMotion{fluid: :unknown},
          %ItemMotion{depth: -1},
          %ItemMotion{depth: 65},
          %ItemMotion{on_ground: nil},
          %ItemMotion{no_gravity: nil},
          %ItemMotion{refresh: nil}
        ] do
      assert ItemMotion.prepare({0, 0, 0}, facts) == {:error, :invalid_item_motion}
    end

    assert ItemMotion.prepare({0, -64, 0}, %ItemMotion{}) == {:error, :item_motion_limit}
    assert ItemMotion.prepare({65, 0, 0}, %ItemMotion{}) == {:error, :invalid_item_motion}
    assert ItemMotion.finish({0, 0, 0}, false, -1) == {:error, :invalid_item_motion}
    assert ItemMotion.finish({0, 0, 65}, false, 0.6) == {:error, :invalid_item_motion}
  end
end
