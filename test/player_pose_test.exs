defmodule Valimc.PlayerPoseTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.PlayerPose, as: Pose

  test "unavailable swimming fit cannot authorize a new pose" do
    assert Pose.select(:standing, %Pose{shift: true}, %{}) == {:error, {:missing_fit, :swimming}}

    assert Pose.select(:dying, %Pose{sleeping: true, spectator: true}, %{swimming: false}) ==
             {:ok, :dying, [:swimming]}
  end

  test "spectators and passengers still require the initial swimming gate" do
    for intent <- [%Pose{spectator: true, shift: true}, %Pose{passenger: true, shift: true}] do
      assert Pose.select(:standing, intent, %{swimming: true}) == {:ok, :crouching, [:swimming]}
    end
  end

  test "standing intent may keep crouching or fall back to swimming" do
    fits = %{swimming: true, standing: false, crouching: true}

    assert Pose.select(:crouching, %Pose{}, fits) ==
             {:ok, :crouching, [:swimming, :standing, :crouching]}

    assert Pose.select(:standing, %Pose{}, %{fits | crouching: false}) ==
             {:ok, :swimming, [:swimming, :standing, :crouching]}

    assert Pose.select(:standing, %Pose{}, Map.delete(fits, :crouching)) ==
             {:error, {:missing_fit, :crouching}}
  end

  test "flight suppresses Shift desire and higher-priority poses override it" do
    assert Pose.select(:standing, %Pose{shift: true, flying: true}, %{
             swimming: true,
             standing: true
           }) ==
             {:ok, :standing, [:swimming, :standing]}

    assert Pose.select(:standing, %Pose{sleeping: true, swimming: true, shift: true}, %{
             swimming: true,
             sleeping: true
           }) ==
             {:ok, :sleeping, [:swimming, :sleeping]}
  end

  test "native float dimensions and eye heights stay distinct from rounded display values" do
    {:ok, standing} = Pose.geometry(:standing, {0, 0, 0})

    assert standing.box ==
             {-0.30000001192092896, +0.0, -0.30000001192092896, 0.30000001192092896,
              1.7999999523162842, 0.30000001192092896}

    assert standing.eye == {+0.0, 1.6200000047683716, +0.0}
    {:ok, crouching} = Pose.geometry(:crouching, {0, 64, 0})
    assert elem(crouching.box, 4) == 65.5
    assert elem(crouching.eye, 1) == 65.26999998092651
  end

  test "invalid or excessive observations fail explicitly" do
    for fits <- [nil, %{swimming: :unknown}, %{unknown: true}, Map.new(1..19, &{&1, true})],
        do: assert(Pose.select(:standing, %Pose{}, fits) == {:error, :invalid_pose_observations})

    assert Pose.select(:unknown, %Pose{}, %{}) == {:error, :invalid_pose_observations}
    assert Pose.select(:standing, %Pose{shift: 1}, %{}) == {:error, :invalid_pose_observations}

    assert Pose.select(:standing, Map.put(%Pose{}, :extra, true), %{}) ==
             {:error, :invalid_pose_observations}

    malformed = %Pose{} |> Map.delete(:shift) |> Map.put(:unknown, true)
    assert Pose.select(:standing, malformed, %{}) == {:error, :invalid_pose_observations}
    assert Pose.dimensions(:unknown) == {:error, :unknown_pose}
    assert Pose.geometry(:standing, {30_000_000, 64, 0}) == {:error, :invalid_pose_position}
    assert Pose.geometry(:standing, {0, 1_000_001, 0}) == {:error, :invalid_pose_position}
  end
end
