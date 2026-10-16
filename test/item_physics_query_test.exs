defmodule Valimc.ItemPhysicsQueryTest do
  use ExUnit.Case, async: false
  alias Valimc.{ItemMotionState, ItemPhysicsQuery, World}

  setup do
    key = {-403, -403}
    assert {:ok, owner} = World.owner(key)
    on_exit(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(owner, 0)) end)
    %{n: -51_584, owner: owner, key: key}
  end

  test "one cohort resolves valid travel while an embedded neighbor refuses", %{n: n, key: key} do
    :ok = World.set_block({n + 5, 64, n + 5}, 1)

    inputs = [
      %{id: 1, revision: 1, position: {n + 5.5, 64.25, n + 5.5}, motion: %ItemMotionState{}},
      %{id: 2, revision: 7, position: {n + 20.5, 65.5, n + 20.5}, motion: %ItemMotionState{}}
    ]

    assert {:ok, task} = ItemPhysicsQuery.start(inputs)
    assert {:ok, result} = Task.await(task, 1500)
    assert result.refused == [{1, :item_inside_block}]
    assert [step] = result.steps
    assert step.id == 2 and step.revision == 7
    assert step.position == {n + 20.5, 65.46, n + 20.5}
    assert step.motion.age == 1 and elem(step.motion.velocity, 1) < 0
    assert Map.has_key?(result.fences, key)
  end

  test "duplicate IDs, invalid inputs and unbounded cohorts refuse before worker admission", %{
    n: n
  } do
    input = %{id: 1, revision: 1, position: {n + 8.5, 64, n + 8.5}, motion: %ItemMotionState{}}

    for inputs <- [
          [],
          [nil],
          [input, input],
          List.duplicate(input, 33),
          [%{input | revision: 0}],
          [Map.put(input, :refresh, nil)]
        ] do
      assert {:error, :invalid_item_physics_batch} = ItemPhysicsQuery.start(inputs)
    end

    assert {:error, :invalid_item_travel} = ItemPhysicsQuery.start([Map.delete(input, :motion)])
    assert {:error, :invalid_item_physics_batch} = ItemPhysicsQuery.start(nil)
    assert {:ok, task} = ItemPhysicsQuery.start(for id <- 1..32, do: %{input | id: id})
    assert {:ok, %{steps: steps, refused: []}} = Task.await(task, 1500)
    assert length(steps) == 32 and Enum.all?(steps, & &1.motion.on_ground)
  end
end
