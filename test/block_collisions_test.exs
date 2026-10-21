defmodule Valimc.BlockCollisionsTest do
  use ExUnit.Case, async: true

  alias Valimc.Physics.{
    BlockCollisions,
    BlockScan,
    Box,
    CollisionContext
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

  test "a validated sample reuses states and fences but resolves each dynamic context afresh" do
    obs = observations(@box, %{{0, 0, 0} => 30519})
    {:ok, frame} = BlockCollisions.prepare(obs)
    empty = CollisionContext.empty()
    falling = CollisionContext.entity(0.2) |> CollisionContext.with_entity(3.0, false, false)
    assert {:ok, %{colliders: []}} = BlockCollisions.collect_frame(@box, frame, empty)

    assert {:ok, %{colliders: [collider], fences: fences}} =
             BlockCollisions.collect_frame(@box, frame, falling)

    assert collider.shape.boxes == [{0.0, 0.0, 0.0, 1.0, 0.8999999761581421, 1.0}]
    assert fences == Map.new(obs, &{&1.region, Map.take(&1, [:owner, :revision])})
    assert {:ok, %{colliders: []}} = BlockCollisions.collect_frame(@box, frame, empty)

    assert BlockCollisions.collect_frame(@box, frame, falling) ==
             BlockCollisions.collect(@box, obs, falling)

    assert {:error, {:missing_block, _}} =
             BlockCollisions.collect_frame(Box.move(@box, {4, 0, 0}), frame, empty)

    assert {:error, :invalid_context} = BlockCollisions.collect_frame(@box, frame, :bad)
    assert {:error, :invalid_block_frame} = BlockCollisions.collect_frame(@box, nil, empty)
  end
end
