defmodule Valimc.Physics.CollisionResponseTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.CollisionResponse

  test "nonfinite candidate retains the entire prior velocity and its bounce notification" do
    for {velocity, dy} <- [{{0.2, 0.0, -0.3}, 0.0}, {{0.2, 1.0e-300, -0.3}, 60_000_000.0}] do
      assert {:ok, %{velocity: ^velocity, bounced: true}} =
               CollisionResponse.step(velocity, dy, %CollisionResponse{
                 x_collision: true,
                 vertical_collision: true,
                 entity_bounciness: 1.0
               })
    end
  end

  test "invalid facts fail within the numeric boundary" do
    for {velocity, dy, facts} <- [
          {{0.0, 0.0, 0.0}, 0.0, %CollisionResponse{below: true}},
          {{0.0, -1.0, 0.0}, 0.0, %CollisionResponse{entity_bounciness: 1.01}},
          {{60_000_001.0, 0.0, 0.0}, 0.0, %CollisionResponse{}},
          {{0.0, 0.0, 0.0}, :unknown, %CollisionResponse{}}
        ] do
      assert {:error, :invalid_collision_response} = CollisionResponse.step(velocity, dy, facts)
    end
  end
end
