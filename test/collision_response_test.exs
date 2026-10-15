defmodule Valimc.Physics.CollisionResponseTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{AirMotion, CollisionResponse}

  test "wall/floor stops retain free axes and repeated landing ticks settle" do
    assert {:ok, %{velocity: {x, stopped_y, 3.0}, bounced: false}} =
             CollisionResponse.step({2.0, -1.0, 3.0}, 0.0, %CollisionResponse{
               x_collision: true,
               vertical_collision: true,
               below: true
             })

    assert x == 0.0
    assert stopped_y == 0.0

    final =
      Enum.reduce(1..2000, {0.2, -0.1, -0.3}, fn _, velocity ->
        {:ok, %{velocity: resolved, bounced: false}} =
          CollisionResponse.step(velocity, 0.0, %CollisionResponse{
            vertical_collision: true,
            below: true
          })

        {:ok, next} = AirMotion.step(resolved, %AirMotion{on_ground: true})
        next
      end)

    assert {x, y, z} = final
    assert abs(x) < 1.0e-100 and abs(z) < 1.0e-100
    assert y > -0.079 and y < -0.078
  end

  test "slime bounces fast falls while careful movement and slow contact suppress it" do
    floor = %CollisionResponse{vertical_collision: true, below: true, block_bounciness: 1.0}

    assert {:ok, %{velocity: {_, y, _}, bounced: true}} =
             CollisionResponse.step({0.2, -2.0, -0.3}, -1.0, floor)

    assert y > 2.0 and y < 2.04

    for {velocity, f} <- [
          {{0.2, -2.0, -0.3}, %{floor | suppress_bounce: true}},
          {{0.2, -2.0, -0.3}, %{floor | block_suppresses_bounce: true}},
          {{0.2, -0.08, -0.3}, floor}
        ] do
      assert {:ok, %{velocity: {0.2, y, -0.3}, bounced: false}} =
               CollisionResponse.step(velocity, 0.0, f)

      assert y == 0.0
    end
  end

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
