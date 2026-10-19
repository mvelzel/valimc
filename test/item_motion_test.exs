defmodule Valimc.Physics.ItemMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ItemMotion

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

  test "native gravity addition clears horizontal negative zero left by wall restitution" do
    assert {:ok, %{velocity: {x, _, z}}} = ItemMotion.prepare({-0.0, 0.0, -0.0}, %ItemMotion{})
    assert <<x::float-64, z::float-64>> == <<0.0::float-64, 0.0::float-64>>

    assert {:ok, %{velocity: {x, _, z}}} =
             ItemMotion.prepare({-0.0, 0.0, -0.0}, %ItemMotion{no_gravity: true})

    assert <<x::float-64, z::float-64>> == <<-0.0::float-64, -0.0::float-64>>
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
