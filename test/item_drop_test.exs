defmodule Valimc.Physics.ItemDropTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ItemDrop
  @pose %{x: 10.5, y: 80.0, z: 10.5, yaw: 0.0, pitch: 0.0}

  test "directed drops start below the actual eye and move forward with native pickup delay" do
    assert {:ok, launch} = ItemDrop.launch(@pose, 1.62, :directed, [0, 0, 0, 0])
    assert launch.position == {10.5, 81.31999999284744, 10.5}
    assert launch.velocity == {0.0, 0.10000000149011612, 0.30000001192092896}
    assert launch.pickup_delay == 40
    assert {:ok, swimming} = ItemDrop.launch(@pose, 0.4, :directed, [0, 0, 0, 0])
    assert elem(swimming.position, 1) == 80.09999999403954
    assert swimming.velocity == launch.velocity
    assert {:ok, right} = ItemDrop.launch(%{@pose | yaw: 90}, 1.62, :directed, [0, 0, 0, 0])
    assert_in_delta elem(right.velocity, 0), -0.3, 1.0e-6
    assert_in_delta elem(right.velocity, 2), 0.0, 1.0e-6
  end

  test "scattered launches use a bounded horizontal radius and fixed upward speed" do
    for radius <- [0.0, 0.5, 0.9999999403953552], angle <- [0.0, 0.25, 0.75] do
      assert {:ok, launch} = ItemDrop.launch(@pose, 1.27, :scattered, [radius, angle, 0, 0])
      {x, y, z} = launch.velocity
      assert x * x + z * z <= 0.25
      assert y == 0.20000000298023224
      assert launch.position == {10.5, 80.96999996900558, 10.5}
    end
  end

  test "invalid random vectors, pose and output bounds refuse without generating entropy" do
    for draws <- [[], [0, 0, 0], [0, 0, 0, 0, 0], [-0.1, 0, 0, 0], [1.0, 0, 0, 0], [nil, 0, 0, 0]] do
      assert ItemDrop.launch(@pose, 1.62, :directed, draws) == {:error, :invalid_item_launch}
    end

    for {pose, eye, kind} <- [
          {Map.delete(@pose, :yaw), 1.62, :directed},
          {%{@pose | x: 30_000_000}, 1.62, :directed},
          {%{@pose | y: 1_000_000}, 1.62, :directed},
          {@pose, -1, :directed},
          {@pose, 9, :directed},
          {@pose, 1.62, :unknown}
        ] do
      assert ItemDrop.launch(pose, eye, kind, [0, 0, 0, 0]) == {:error, :invalid_item_launch}
    end
  end
end
