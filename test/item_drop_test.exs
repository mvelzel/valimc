defmodule Valimc.Physics.ItemDropTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ItemDrop
  @pose %{x: 10.5, y: 80.0, z: 10.5, yaw: 0.0, pitch: 0.0}

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
