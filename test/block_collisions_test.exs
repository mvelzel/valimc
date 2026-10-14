defmodule Valimc.BlockCollisionsTest do
  use ExUnit.Case, async: true

  alias Valimc.Physics.{
    BlockCollisions,
    BlockEntityContext,
    BlockScan,
    BlockShapes,
    Box,
    CollisionContext,
    Shape,
    VoxelOps
  }

  defp region({x, _, z}), do: Valimc.World.region_key(Valimc.World.chunk_key(x, z))

  defp observations(box, overrides \\ %{}, default \\ 0) do
    {:ok, plan} = BlockScan.plan(box)

    plan
    |> Enum.map(fn {pos, _} -> {pos, Map.get(overrides, pos, default)} end)
    |> Enum.group_by(fn {pos, _} -> region(pos) end)
    |> Enum.flat_map(fn {key, blocks} ->
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(pid, :stop) end)
      owner = {pid, make_ref()}

      Enum.map(Enum.chunk_every(blocks, 128), fn batch ->
        %{owner: owner, region: key, revision: 7, blocks: Map.new(batch)}
      end)
    end)
  end

  @box {0.2, 0.2, 0.2, 1.8, 1.8, 1.8}

  test "ordered colliders preserve all owner fences and tolerate consistent repeated batches" do
    obs = observations(@box, %{{0, 0, 0} => 1, {1, 0, 0} => 1, {0, 1, 1} => 1})
    assert {:ok, result} = BlockCollisions.collect(@box, obs ++ [hd(obs)])
    assert Enum.map(result.colliders, & &1.position) == [{0, 0, 0}, {1, 0, 0}, {0, 1, 1}]

    for c <- result.colliders do
      assert c.state == 1
      assert c.shape.boxes == [Box.move({0, 0, 0, 1, 1, 1}, c.position)]
      refute c.shape.full_block
    end

    assert result.fences == Map.new(obs, &{&1.region, Map.take(&1, [:owner, :revision])})
  end

  test "strict shared full-block overlap retains tiny and zero extents inside a block" do
    for width <- [0.0, 1.0e-8, 1.0e-7] do
      box = {0.5, 0.2, 0.2, 0.5 + width, 0.8, 0.8}

      assert {:ok, %{colliders: [%{position: {0, 0, 0}}]}} =
               BlockCollisions.collect(box, observations(box, %{{0, 0, 0} => 1}))

      assert Shape.empty?(VoxelOps.world_box(box))
    end

    touching = {1.0, 0.2, 0.2, 1.5, 0.8, 0.8}

    assert {:ok, %{colliders: []}} =
             BlockCollisions.collect(touching, observations(touching, %{{0, 0, 0} => 1}))
  end

  test "voxel overlap excludes holes inside a compound shape's bounds" do
    box = {0.4, 0.6, 0.8, 0.6, 0.9, 0.95}

    assert {:ok, %{colliders: []}} =
             BlockCollisions.collect(box, observations(box, %{{0, 0, 0} => 5474}))

    lower = {0.4, 0.4, 0.8, 0.6, 0.6, 0.95}

    assert {:ok, %{colliders: [%{state: 5474}]}} =
             BlockCollisions.collect(lower, observations(lower, %{{0, 0, 0} => 5474}))
  end

  test "missing observations never silently become air, including ineligible candidates" do
    obs = observations(@box)
    [first | rest] = obs
    pos = first.blocks |> Map.keys() |> hd()

    assert {:error, {:missing_block, ^pos}} =
             BlockCollisions.collect(@box, [
               %{first | blocks: Map.delete(first.blocks, pos)} | rest
             ])

    assert {:error, {:unknown_block_state, ^pos}} =
             BlockCollisions.collect(@box, [
               %{first | blocks: Map.put(first.blocks, pos, 35_723)} | rest
             ])

    assert {:error, :invalid_block_position} =
             BlockCollisions.collect(@box, [%{first | blocks: %{{0, :bad, 0} => 0}}])

    assert {:error, {:foreign_block, {100_000, 0, 100_000}}} =
             BlockCollisions.collect(@box, [%{first | blocks: %{{100_000, 0, 100_000} => 0}}])
  end

  test "conflicting blocks, owner revisions, incarnations and owner-region reuse reject" do
    obs = observations(@box)
    first = hd(obs)
    pos = first.blocks |> Map.keys() |> hd()

    assert {:error, {:conflicting_block, ^pos}} =
             BlockCollisions.collect(@box, obs ++ [%{first | blocks: %{pos => 1}}])

    for changed <- [%{first | revision: 8}, %{first | owner: {elem(first.owner, 0), make_ref()}}] do
      assert {:error, {:conflicting_fence, _}} = BlockCollisions.collect(@box, obs ++ [changed])
    end

    assert {:error, :owner_region_conflict} =
             BlockCollisions.collect(@box, [first, %{first | region: {999, 999}, blocks: %{}}])
  end

  test "block entities distinguish missing, invalid and confirmed absent observations" do
    box = {0.2, 0.2, 0.2, 0.8, 0.8, 0.8}

    for {id, name} <- [{16849, "minecraft:shulker_box"}, {3801, "minecraft:moving_piston"}] do
      obs = observations(box, %{{0, 0, 0} => id})
      assert {:error, {:context_required, {0, 0, 0}, ^name}} = BlockCollisions.collect(box, obs)

      assert {:ok, %{colliders: colliders}} =
               BlockCollisions.collect(box, obs, CollisionContext.empty(), %{
                 {0, 0, 0} => BlockEntityContext.absent()
               })

      assert length(colliders) == if(id == 16849, do: 1, else: 0)

      assert {:error, :invalid_block_entity_context} =
               BlockCollisions.collect(box, obs, CollisionContext.empty(), %{{0, 0, 0} => :absent})
    end

    # A shulker on a scan edge is ineligible: no block-entity read is needed.
    assert {:ok, %{colliders: []}} =
             BlockCollisions.collect(box, observations(box, %{{-1, -1, 0} => 16849}))

    assert {:error, :invalid_context} = BlockCollisions.collect(box, [], :empty)

    assert {:error, :invalid_block_entity_context} =
             BlockCollisions.collect(box, observations(box), CollisionContext.empty(), %{
               {99, 0, 0} => BlockEntityContext.absent()
             })
  end

  test "candidate, batch and collider limits fail without partial results" do
    large = {0.2, 0.2, 0.2, 5.8, 5.8, 5.8}
    assert {:error, :collider_limit} = BlockCollisions.collect(large, observations(large, %{}, 1))
    assert {:error, :block_scan_limit} = BlockCollisions.collect({0, 0, 0, 10, 10, 10}, [])
    obs = observations(@box)

    assert {:error, :invalid_observations} =
             BlockCollisions.collect(@box, List.duplicate(hd(obs), 17))

    assert {:error, :invalid_observations} = BlockCollisions.collect(@box, [hd(obs) | :bad])
    blocks = Map.new(0..128, &{{&1, 0, 0}, 0})

    assert {:error, :invalid_observations} =
             BlockCollisions.collect(@box, [%{hd(obs) | blocks: blocks}])
  end

  test "native shared-full identity is lost by move and retained by optimized creation" do
    {:ok, stone} = BlockShapes.fetch(1)
    assert stone.full_block
    refute Shape.move(stone, {0, 0, 0}).full_block
    assert VoxelOps.box({0, 0, 0, 1, 1, 1}).full_block

    assert VoxelOps.union(
             VoxelOps.box({0, 0, 0, 0.5, 1, 1}),
             VoxelOps.box({0.5, 0, 0, 1, 1, 1})
           ).full_block

    assert_raise ArgumentError, fn ->
      VoxelOps.intersects?(%{VoxelOps.box({0, 0, 0, 0.5, 1, 1}) | full_block: true}, stone)
    end
  end
end
