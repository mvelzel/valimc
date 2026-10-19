defmodule Valimc.PlayerPoseTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.PlayerPose, as: Pose

  test "unavailable swimming fit cannot authorize a new pose" do
    assert Pose.select(:standing, %Pose{shift: true}, %{}) == {:error, {:missing_fit, :swimming}}

    assert Pose.select(:dying, %Pose{sleeping: true, spectator: true}, %{swimming: false}) ==
             {:ok, :dying, [:swimming]}
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
