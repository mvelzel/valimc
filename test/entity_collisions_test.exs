defmodule Valimc.EntityCollisionsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.EntityCollisions
  @box {0.0, 64.0, 0.0, 0.6, 65.8, 0.6}

  defp entity(id, changes \\ %{}) do
    Map.merge(
      %{id: id, box: @box, spectator: false, collidable: true, same_vehicle: false},
      changes
    )
  end

  test "incomplete, duplicated and excessive observations cannot authorize empty space" do
    for candidates <- [
          nil,
          [Map.delete(entity(2), :collidable)],
          [entity(2, %{same_vehicle: nil})],
          [entity(-1)],
          [entity(2, %{box: nil})],
          Enum.map(1..257, &entity/1)
        ] do
      assert {:error, :invalid_entity_observations} =
               EntityCollisions.collect(@box, 1, candidates)
    end

    assert {:error, :duplicate_entity_observation} =
             EntityCollisions.collect(@box, 1, [entity(2), entity(2)])

    for {box, subject} <- [{nil, 1}, {@box, -1}, {{0, 0, 0, 65, 1, 1}, 1}] do
      assert {:error, :invalid_entity_query} = EntityCollisions.collect(box, subject, [])
    end
  end
end
