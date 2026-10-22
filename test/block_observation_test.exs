defmodule Valimc.BlockObservationTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "valimc-block-observation-#{System.unique_integer([:positive])}"
      )

    key = {-310, -310}
    TestScope.isolate(TestScope.neighborhood(key), world_path: path)
    {:ok, owner} = World.owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf!(path)
    end)

    %{key: key, owner: owner, pos: {-39680, 64, -39680}}
  end

  test "one immutable batch carries matching owner identity, revision and terrain", c do
    {x, _y, z} = c.pos
    floor = {x, 63, z}
    assert {:ok, first} = Region.observe_blocks(c.owner, [c.pos, floor, c.pos])
    assert first.owner == c.owner and first.region == c.key and first.revision == 0
    assert first.blocks == %{c.pos => 0, floor => Valimc.Protocol.Data.block("grass_block")}
    assert :ok = Valimc.TestBlocks.set(c.pos, 1)
    assert {:error, :stale_revision} = Region.observe_blocks(c.owner, [c.pos], first.revision)
    assert {:ok, next} = Region.observe_blocks(c.owner, [c.pos], first.revision + 1)
    assert next.blocks == %{c.pos => 1} and first.blocks[c.pos] == 0
    assert {:ok, %{blocks: %{}, revision: 1}} = Region.observe_blocks(c.owner, [], 1)
  end

  test "strict request limits reject before contacting even a suspended owner", c do
    {pid, _} = c.owner
    :sys.suspend(pid)

    try do
      for {positions, revision} <- [
            {List.duplicate(c.pos, 129), :any},
            {[c.pos | :bad], :any},
            {[{1.0, 64, 1}], :any},
            {[{0, -1_000_001, 0}], :any},
            {[{0, 1_000_001, 0}], :any},
            {[{30_000_000, 64, 0}], :any},
            {[{0, 64, -30_000_000}], :any},
            {[:invalid], :any},
            {[c.pos], -1},
            {[c.pos], "0"}
          ] do
        assert {:error, :invalid_block_query} =
                 Region.observe_blocks(c.owner, positions, revision)
      end

      {:messages, messages} = Process.info(pid, :messages)
      refute Enum.any?(messages, &match?({:"$gen_call", _, {:observe_blocks, _, _, _}}, &1))
    after
      :sys.resume(pid)
    end

    assert {:ok, %{blocks: blocks}} = Region.observe_blocks(c.owner, List.duplicate(c.pos, 128))
    assert blocks == %{c.pos => 0}
  end

  test "negative boundaries, stale incarnations and foreign region requests are explicit", c do
    {pid, epoch} = c.owner
    {x, y, z} = c.pos
    assert {:error, {:retry, :stale_owner}} = Region.observe_blocks({pid, make_ref()}, [c.pos])
    assert {:error, :wrong_region} = Region.observe_blocks({pid, epoch}, [{x - 1, y, z}])

    assert {:ok, _} =
             Region.observe_blocks(c.owner, [{x + 127, -64, z + 127}, {x + 127, 319, z + 127}])

    assert {:error, :wrong_region} = Region.observe_blocks(c.owner, [{x + 128, y, z}])
  end

  test "concurrent reads pair the committed block state with its revision", c do
    writer =
      Task.async(fn ->
        for i <- 1..100, do: :ok = Valimc.TestBlocks.set(c.pos, rem(i, 2))
      end)

    reads =
      1..200
      |> Task.async_stream(fn _ -> Region.observe_blocks(c.owner, [c.pos]) end,
        timeout: 60_000,
        max_concurrency: 8
      )
      |> Enum.to_list()

    Task.await(writer, 60_000)

    for {:ok, {:ok, snapshot}} <- reads do
      assert snapshot.blocks[c.pos] == rem(snapshot.revision, 2)
    end

    assert Enum.all?(reads, &match?({:ok, {:ok, _}}, &1))
    assert {:ok, %{revision: 100}} = Region.observe_blocks(c.owner, [c.pos])
  end

  test "timed-out and dead owners never yield empty terrain", c do
    {pid, _} = c.owner
    # This owner's queries time out at the play budget (VMC-073).
    Valimc.TestScope.isolate(pid, owner_call_scale: 1)
    :sys.suspend(pid)

    try do
      assert {:error, {:retry, :block_query_timeout}} = Region.observe_blocks(c.owner, [c.pos])
    after
      :sys.resume(pid)
    end

    assert {:ok, %{blocks: blocks}} = Region.observe_blocks(c.owner, [c.pos])
    assert blocks == %{c.pos => 0}
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert {:error, {:retry, :region_unavailable}} = Region.observe_blocks(c.owner, [c.pos])
  end

  test "replacement preserves flushed terrain and changes the incarnation even at revision zero",
       c do
    {pid, epoch} = c.owner
    assert :ok = Valimc.TestBlocks.set(c.pos, 1)
    assert :ok = Region.flush(pid)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert {:ok, {replacement, new_epoch} = fresh} = World.owner(c.key)
    refute replacement == pid or new_epoch == epoch
    assert {:error, {:retry, :stale_owner}} = Region.observe_blocks({replacement, epoch}, [c.pos])
    assert {:ok, snapshot} = Region.observe_blocks(fresh, [c.pos], 0)
    assert snapshot.owner == fresh and snapshot.blocks == %{c.pos => 1}
  end

  test "a paused region cannot block another region or change item publication", c do
    {pid, _} = c.owner
    key = {-309, -310}
    # Another group: the regionizer would make the neighbour this one's.
    TestScope.isolate(key, regionizer: false)
    {:ok, {other, _} = neighbour} = World.owner(key)

    on_exit(fn ->
      if Process.alive?(other),
        do: TestScope.kill(other)
    end)

    :sys.suspend(pid)

    try do
      assert {:ok, first} = Region.observe_blocks(neighbour, [{-39552, 64, -39680}])
      assert first.blocks == %{{-39552, 64, -39680} => 0}

      assert {:ok, _} =
               Region.create_item(
                 neighbour,
                 Valimc.Protocol.ItemStack.new("stone"),
                 {-39551.5, 64.0, -39679.5}
               )

      items = World.item_snapshot(key)
      assert map_size(items) == 1

      assert {:ok, ^first} =
               Region.observe_blocks(neighbour, [{-39552, 64, -39680}], first.revision)

      assert World.item_snapshot(key) == items
    after
      :sys.resume(pid)
    end
  end
end
