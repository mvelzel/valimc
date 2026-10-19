defmodule Valimc.MovementValidationTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{MovementValidation, VoxelOps}

  test "existing overlap is retained, new overlap rejects and unbounded/malformed facts fail" do
    old = {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}
    existing = VoxelOps.world_box({0.1, 0, -0.2, 0.2, 1, 0.2})
    new = VoxelOps.world_box({0.75, 0, -0.2, 1.0, 2, 0.2})
    assert MovementValidation.new_collision?(old, [existing]) == {:ok, false}
    assert MovementValidation.new_collision?(old, [existing, new]) == {:ok, true}

    assert MovementValidation.new_collision?(old, List.duplicate(new, 129)) ==
             {:error, :invalid_movement_observation}

    assert MovementValidation.new_collision?(old, [:unknown]) ==
             {:error, :invalid_movement_observation}

    assert MovementValidation.new_collision?(nil, []) == {:error, :invalid_movement_observation}

    assert MovementValidation.collision_rejected?(nil, false, false, false) ==
             {:error, :invalid_movement_observation}
  end
end
