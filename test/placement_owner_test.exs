defmodule Valimc.PlacementOwnerTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{PlayerPlacementQuery, World}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "valimc-place-owner-#{nonce}")
    key = {60_000 + rem(nonce, 3_333) * 3, 1700}
    TestScope.isolate(TestScope.neighborhood(key), world_path: path)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span + 40, 64, rz * span + 40}
    {:ok, owner} = World.owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf!(path)
    end)

    %{key: key, position: position, owner: owner, span: span, path: path}
  end

  defp plan(c, item \\ "stone", request \\ nil) do
    request = request || %{position: c.position, face: 1, cursor: {0.5, 0.5, 0.5}}
    {:ok, task} = PlayerPlacementQuery.start(ItemStack.new(item).item_id, request)
    Task.await(task, 60_000)
  end

  test "owner block commits refuse unsupported block entities and keep supported ones", c do
    {pid, _} = c.owner

    # Default states the 26.3 client sent for a copper chest and a barrel.
    for state <- [32_926, 24_100] do
      revision = Valimc.TestConn.state(pid).resource.revision

      assert {:error, :unsupported_block_entity} =
               Region.set_blocks(c.owner, revision, %{c.position => state})

      assert World.get_block(c.position) == 0
    end

    {:ok, furnace} = Valimc.Physics.CookingBlocks.placement(:furnace, 90.0)
    revision = Valimc.TestConn.state(pid).resource.revision
    assert {:ok, _} = Region.set_blocks(c.owner, revision, %{c.position => furnace})
    assert World.get_block(c.position) == furnace
  end

  test "a plan stays valid across edits in other sections of the region", c do
    assert {:ok, prepared} = plan(c)
    {x, y, z} = c.position
    # Same region, other sections: one chunk over, and one section up.
    assert :ok = World.set_block({x + 16, y, z}, 1)
    assert :ok = World.set_block({x, y + 16, z}, 1)

    assert {:ok, _} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    assert World.get_block(c.position) == prepared.candidate.state
  end

  test "target ABA cannot authorize an old placement plan", c do
    assert {:ok, prepared} = plan(c)
    assert :ok = World.set_block(c.position, 1)
    assert :ok = World.set_block(c.position, 0)

    assert {:error, :stale_revision} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    assert World.get_block(c.position) == 0
  end

  test "creative chest block and metadata wait for one joint writer on creation and removal", c do
    request = %{position: c.position, face: 1, cursor: {0.5, 0.5, 0.5}, yaw: 180.0}
    assert {:ok, prepared} = plan(c, "chest", request)
    {pid, _} = c.owner
    writer = Valimc.TestConn.state(pid).resource.store
    :sys.suspend(writer)

    task =
      Task.async(fn ->
        Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)
      end)

    try do
      wait_writing(pid)
      # Adopted in owner memory; readers see the chest only once durable.
      assert Valimc.TestRegion.published_block(c.owner, c.position) == 0
      assert Task.yield(task, 10) == nil
      :sys.resume(writer)
      assert {:ok, _} = Task.await(task, 60_000)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end

    chest = World.get_block(c.position)
    old = Valimc.TestConn.state(pid).resource.containers
    assert old.entries[c.position].slots == Tuple.duplicate(nil, 27)
    :sys.suspend(writer)
    {:ok, current} = Region.observe_blocks(c.owner, [c.position])

    removal =
      Task.async(fn ->
        Region.destroy_block(
          c.owner,
          current.revision,
          c.position,
          System.monotonic_time(:millisecond) + 250
        )
      end)

    try do
      wait_writing(pid)
      assert Valimc.TestRegion.published_block(c.owner, c.position) == chest

      assert Valimc.World.Containers.decode(
               Valimc.TestDisk.read(c.path, c.key, :containers),
               c.key
             ) ==
               {:ok, old}

      assert Task.yield(removal, 10) == nil
      :sys.resume(writer)
      assert :ok = Task.await(removal, 60_000)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(removal, :brutal_kill)
    end

    assert World.get_block(c.position) == 0

    {:ok, containers} =
      Valimc.World.Containers.decode(
        Valimc.TestDisk.read(c.path, c.key, :containers),
        c.key
      )

    assert containers.entries == %{} and containers.sequence == 2 and containers.receipts == %{}
    assert Valimc.TestConn.state(pid).resource.containers == containers
    assert World.item_snapshot(c.key) == %{}
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, {replacement, _}} = World.owner(c.key)
    assert :sys.get_state(replacement).resource.containers == containers
    assert World.get_block(c.position) == 0
  end

  test "chest preparation refuses adjacent ordinary states and region-edge neighbors", c do
    {x, y, z} = c.position
    chest = Valimc.Protocol.Data.item_block(ItemStack.new("chest").item_id)
    :ok = World.set_block({x + 1, y, z}, chest)
    request = %{position: c.position, face: 1, cursor: {0.5, 0.5, 0.5}, yaw: 0.0}
    assert {:error, :adjacent_chest} = plan(c, "chest", request)
    {rx, _} = c.key
    request = %{request | position: {rx * c.span, y, z}}
    assert {:error, :cross_owner_chest} = plan(c, "chest", request)
  end

  defp wait_writing(pid, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      Enum.any?(Valimc.TestConn.state(pid).resource.item_writes, &(&1.kind == :blocks))
    end)

    :ok
  end

  test "corrections share owner message order with later world publications", c do
    World.subscribe(MapSet.new([c.key]), MapSet.new())
    assert :ok = Region.correct_blocks(c.owner, [c.position], self())
    assert :ok = World.set_block(c.position, 1)
    assert_receive {:event, {:block, position, 0}}
    assert position == c.position
    assert_receive {:event, {:block, ^position, 1}}

    assert {:error, :invalid_block_query} =
             Region.correct_blocks(c.owner, List.duplicate(c.position, 3), self())
  end

  test "queued expired commits cannot mutate a resumed owner", c do
    assert {:ok, prepared} = plan(c)
    {pid, _} = c.owner
    :sys.suspend(pid)

    try do
      # A short deadline that passes while the commit waits behind the suspended owner.
      deadline = System.monotonic_time(:millisecond) + 50

      task =
        Task.async(fn ->
          Region.place_block(c.owner, prepared.revision, prepared.batch, deadline)
        end)

      Process.sleep(60)
      :sys.resume(pid)
      assert {:error, :invalid_or_expired_placement} = Task.await(task, 60_000)
      assert World.get_block(c.position) == 0
    after
      :sys.resume(pid)
    end
  end

  test "a retired incarnation cannot reuse its revision after replacement", c do
    assert {:ok, prepared} = plan(c)
    {pid, epoch} = c.owner
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, {next, _}} = World.owner(c.key)

    assert {:error, :region_unavailable} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    assert {:error, :stale_owner} =
             Region.place_block(
               {next, epoch},
               prepared.revision,
               prepared.batch,
               prepared.deadline
             )

    assert World.get_block(c.position) == 0
  end

  test "stalled and absent sources fail without cold admission or blocking the caller", c do
    {pid, _} = c.owner
    # This owner's queries time out at the play budget (VMC-073).
    Valimc.TestScope.isolate(pid, owner_call_scale: 1)
    :sys.suspend(pid)

    try do
      assert {:error, :block_query_timeout} = plan(c)
    after
      :sys.resume(pid)
    end

    {rx, rz} = c.key
    foreign = {rx + 10, rz}

    request = %{
      position: {(rx + 10) * c.span + 40, 64, rz * c.span + 40},
      face: 1,
      cursor: {0.5, 0.5, 0.5}
    }

    assert {:error, :region_unavailable} = plan(c, "stone", request)
    assert Registry.lookup(Valimc.RegionRegistry, foreign) == []

    request = %{request | position: {(rx + 1) * c.span - 1, 64, rz * c.span + 40}, face: 5}
    assert {:error, :cross_owner_placement} = plan(c, "stone", request)
    assert Registry.lookup(Valimc.RegionRegistry, {rx + 1, rz}) == []
  end
end
