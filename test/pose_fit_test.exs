defmodule Valimc.PoseFitTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockScan, BorderSnapshot, CollisionContext, PlayerPose, PoseFit}
  alias Valimc.World.View
  @position {0.5, 64.0, 0.5}

  defp observations(states \\ %{}, entities \\ []) do
    {:ok, plan} = BlockScan.plan({0.19, 63.99, 0.19, 0.81, 65.81, 0.81})

    %{
      blocks: View.of(Map.new(plan, fn {p, _} -> {p, Map.get(states, p, 0)} end)),
      entities: entities,
      border: %BorderSnapshot{},
      subject: 1
    }
  end

  defp select(observations, intent \\ %PlayerPose{}, current \\ :standing),
    do: PoseFit.select(current, intent, @position, CollisionContext.empty(), observations)

  test "border and malformed/missing observations remain explicit rather than becoming air" do
    {:ok, border} = BorderSnapshot.new(0, 0, 0)

    assert {:ok, %{pose: :crouching, fits: %{swimming: false}}} =
             select(%{observations() | border: border}, %PlayerPose{}, :crouching)

    obs = observations()
    assert {:error, {:missing_block, _}} = select(%{obs | blocks: View.of(%{})})
    assert {:error, :invalid_entity_observations} = select(%{obs | entities: nil})
    assert {:error, :invalid_pose_fit_observations} = select(%{obs | border: nil})
    assert {:error, :invalid_pose_observations} = select(obs, %PlayerPose{shift: :unknown})
    assert {:error, :invalid_pose_fit_observations} = select(Map.put(obs, :extra, true))
  end
end
