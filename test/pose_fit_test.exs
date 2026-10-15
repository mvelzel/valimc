defmodule Valimc.PoseFitTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockScan, BorderSnapshot, CollisionContext, PlayerPose, PoseFit}
  alias Valimc.World
  @position {0.5, 64.0, 0.5}

  defp observations(states \\ %{}, entities \\ []) do
    {:ok, plan} = BlockScan.plan({0.19, 63.99, 0.19, 0.81, 65.81, 0.81})
    groups = Enum.group_by(plan, fn {{x, _, z}, _} -> World.region_key(World.chunk_key(x, z)) end)

    blocks =
      for {key, positions} <- groups do
        pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        on_exit(fn -> Process.exit(pid, :kill) end)

        %{
          owner: {pid, make_ref()},
          region: key,
          revision: 5,
          blocks: Map.new(positions, fn {p, _} -> {p, Map.get(states, p, 0)} end)
        }
      end

    %{
      blocks: blocks,
      block_entities: %{},
      entities: entities,
      border: %BorderSnapshot{},
      subject: 1
    }
  end

  defp select(observations, intent \\ %PlayerPose{}, current \\ :standing),
    do: PoseFit.select(current, intent, @position, CollisionContext.empty(), observations)

  test "complete open observations select standing and retain exact owner fences" do
    observations = observations()
    assert {:ok, result} = select(observations)
    assert result.pose == :standing
    assert result.queries == [:swimming, :standing]
    assert result.fits == %{swimming: true, standing: true}

    assert result.fences ==
             Map.new(observations.blocks, &{&1.region, Map.take(&1, [:owner, :revision])})

    assert {:ok, result.geometry} == PlayerPose.geometry(:standing, @position)
  end

  test "crouch/crawl clearance and the initial swimming gate use native lazy order" do
    assert {:ok, crouch} = select(observations(%{{0, 65, 0} => 15178}))
    assert crouch.pose == :crouching
    assert crouch.queries == [:swimming, :standing, :crouching]
    assert crouch.fits == %{swimming: true, standing: false, crouching: true}
    assert {:ok, crawl} = select(observations(%{{0, 65, 0} => 1}))
    assert crawl.pose == :swimming
    assert crawl.fits == %{swimming: true, standing: false, crouching: false}

    # No entity lookup is required once blocks reject the swimming fit.
    assert {:ok, retained} =
             select(observations(%{{0, 64, 0} => 1}, nil), %PlayerPose{}, :crouching)

    assert retained.pose == :crouching and retained.queries == [:swimming]
  end

  test "solid head-space entities restrict the selected pose; non-solid entities do not" do
    entity = %{
      id: 2,
      box: {0.2, 65.6, 0.2, 0.8, 65.8, 0.8},
      spectator: false,
      collidable: true,
      same_vehicle: false
    }

    assert {:ok, %{pose: :crouching}} = select(observations(%{}, [entity]))
    assert {:ok, %{pose: :standing}} = select(observations(%{}, [%{entity | collidable: false}]))
  end

  test "border and malformed/missing observations remain explicit rather than becoming air" do
    {:ok, border} = BorderSnapshot.new(0, 0, 0)

    assert {:ok, %{pose: :crouching, fits: %{swimming: false}}} =
             select(%{observations() | border: border}, %PlayerPose{}, :crouching)

    obs = observations()
    assert {:error, {:missing_block, _}} = select(%{obs | blocks: []})
    assert {:error, :invalid_entity_observations} = select(%{obs | entities: nil})
    assert {:error, :invalid_pose_fit_observations} = select(%{obs | border: nil})
    assert {:error, :invalid_pose_observations} = select(obs, %PlayerPose{shift: :unknown})
    assert {:error, :invalid_pose_fit_observations} = select(Map.put(obs, :extra, true))
    [first | rest] = obs.blocks

    assert {:error, {:conflicting_fence, _}} =
             select(%{obs | blocks: [first, %{first | revision: 6} | rest]})
  end
end
