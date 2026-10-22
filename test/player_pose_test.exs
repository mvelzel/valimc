defmodule Valimc.PlayerPoseTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.PlayerPose, as: Pose

  test "unknown poses and positions outside the world fail explicitly" do
    assert Pose.dimensions(:unknown) == {:error, :unknown_pose}
    assert Pose.geometry(:standing, {30_000_000, 64, 0}) == {:error, :invalid_pose_position}
    assert Pose.geometry(:standing, {0, 1_000_001, 0}) == {:error, :invalid_pose_position}
    assert Pose.from_id(Pose.id(:crouching)) == :crouching
  end
end
