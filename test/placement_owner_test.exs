defmodule Valimc.PlacementOwnerTest do
  use ExUnit.Case, async: false
  alias Valimc.{PlayerPlacementQuery, World}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    previous = Valimc.config(:world_path)
    path = Path.join(System.tmp_dir!(), "valimc-place-owner-#{nonce}")
    Application.put_env(:valimc, :world_path, path)
    key = {60_000 + rem(nonce, 10_000), 1700}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span + 40, 64, rz * span + 40}
    {:ok, owner} = World.owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(path)
    end)

    %{key: key, position: position, owner: owner, span: span, path: path}
  end

  defp plan(c, item \\ "stone", request \\ nil) do
    request = request || %{position: c.position, face: 1, cursor: {0.5, 0.5, 0.5}}
    {:ok, task} = PlayerPlacementQuery.start(ItemStack.new(item).item_id, request)
    Task.await(task, 1000)
  end

  test "prepared native replacement is inert until a fresh fenced owner commit", c do
    assert :ok = World.set_block(c.position, 89)
    assert {:ok, prepared} = plan(c, "oak_slab")
    assert prepared.candidate == %{position: c.position, state: 15_179, replace_clicked: true}
    assert World.get_block(c.position) == 89

    assert {:ok, revision} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    assert revision == prepared.revision + 1
    assert World.get_block(c.position) == 15_179

    assert {:error, :stale_revision} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    assert {:ok, merged} = plan(c, "oak_slab")
    assert merged.candidate.state == 15_182
    assert {:ok, _} = Region.place_block(c.owner, merged.revision, merged.batch, merged.deadline)
    assert World.get_block(c.position) == 15_182
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
    writer = :sys.get_state(pid).resource.store
    :sys.suspend(writer)

    task =
      Task.async(fn ->
        Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)
      end)

    try do
      wait_writing(pid)
      assert World.get_block(c.position) == 0
      assert :sys.get_state(pid).resource.containers.entries == %{}
      assert {:error, :mining_storage_busy} = World.set_block(c.position, 1)
      assert Task.yield(task, 10) == nil
      :sys.resume(writer)
      assert {:ok, revision} = Task.await(task)
      assert revision == prepared.revision + 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end

    chest = World.get_block(c.position)
    old = :sys.get_state(pid).resource.containers
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
      assert World.get_block(c.position) == chest
      assert :sys.get_state(pid).resource.containers == old
      assert Task.yield(removal, 10) == nil
      :sys.resume(writer)
      assert :ok = Task.await(removal)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(removal, :brutal_kill)
    end

    assert World.get_block(c.position) == 0

    {:ok, containers} =
      Valimc.World.Containers.decode(
        File.read!(Valimc.World.Store.container_path(c.path, c.key)),
        c.key
      )

    assert containers.entries == %{} and containers.sequence == 2 and containers.receipts == %{}
    assert :sys.get_state(pid).resource.containers == containers
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

  test "creative metadata-file failure recovers the committed chest before a new owner publishes",
       c do
    request = %{position: c.position, face: 1, cursor: {0.5, 0.5, 0.5}, yaw: 0.0}
    {:ok, prepared} = plan(c, "chest", request)
    path = Valimc.World.Store.container_path(c.path, c.key)
    File.mkdir_p!(path)
    {pid, _} = c.owner
    monitor = Process.monitor(pid)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :mining_commit_uncertain} =
               Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

      assert_receive {:DOWN, ^monitor, :process, _, _}, 1000
    end)

    assert File.regular?(Valimc.World.Store.mining_path(c.path, c.key))
    File.rmdir!(path)
    {:ok, {replacement, _}} = World.owner(c.key)
    assert World.get_block(c.position) == prepared.candidate.state
    containers = :sys.get_state(replacement).resource.containers
    assert containers.entries[c.position].slots == Tuple.duplicate(nil, 27)
    assert containers.sequence == 1 and containers.receipts == %{}
    assert not File.exists?(Valimc.World.Store.mining_path(c.path, c.key))
  end

  defp wait_writing(pid, tries \\ 200)
  defp wait_writing(_, 0), do: flunk("joint chest write did not start")

  defp wait_writing(pid, tries) do
    if match?(
         %{kind: :container_blocks, phase: :writing},
         :sys.get_state(pid).resource.item_pending
       ) do
      :ok
    else
      Process.sleep(1)
      wait_writing(pid, tries - 1)
    end
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
      task =
        Task.async(fn ->
          Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)
        end)

      Process.sleep(275)
      :sys.resume(pid)
      assert {:error, :invalid_or_expired_placement} = Task.await(task, 1000)
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
