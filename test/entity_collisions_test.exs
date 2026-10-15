defmodule Valimc.EntityCollisionsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{EntityCollisions, Shape}
  @box {0.0, 64.0, 0.0, 0.6, 65.8, 0.6}

  defp entity(id, changes \\ %{}) do
    Map.merge(
      %{id: id, box: @box, spectator: false, collidable: true, same_vehicle: false},
      changes
    )
  end

  test "self, spectators, non-solid entities and shared vehicles do not block a player" do
    candidates = [
      entity(1),
      entity(2, %{spectator: true}),
      entity(3, %{collidable: false}),
      entity(4, %{same_vehicle: true}),
      entity(5),
      entity(6)
    ]

    assert {:ok, result} = EntityCollisions.collect(@box, 1, candidates)
    assert Enum.map(result.colliders, & &1.id) == [5, 6]
    assert {:ok, anonymous} = EntityCollisions.collect(@box, nil, candidates)
    assert Enum.map(anonymous.colliders, & &1.id) == [1, 4, 5, 6]
  end

  test "lookup margin includes nearby contact without requiring final shape intersection" do
    near = entity(2, %{box: {0.60000005, 64.0, 0.0, 1.0, 65.0, 0.6}})
    far = entity(3, %{box: {0.6000002, 64.0, 0.0, 1.0, 65.0, 0.6}})
    assert {:ok, %{colliders: [%{id: 2}]}} = EntityCollisions.collect(@box, 1, [near, far])
  end

  test "average query size and individual shape emptiness are different native rules" do
    assert {:ok, %{query_box: nil, colliders: []}} =
             EntityCollisions.collect({0, 0, 0, 1.0e-8, 1.0e-8, 1.0e-8}, nil, [])

    thin = entity(2, %{box: {0.3, 64.0, 0.3, 0.3, 65.0, 0.3}})
    assert {:ok, %{colliders: [collider]}} = EntityCollisions.collect(@box, 1, [thin])
    assert Shape.empty?(collider.shape)
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
