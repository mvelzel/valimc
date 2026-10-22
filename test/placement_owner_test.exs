defmodule Valimc.PlacementOwnerTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.PlayerPlacementQuery
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
    {:ok, owner} = Valimc.TestWorld.owner(key)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
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
    # Default states the 26.3 client sent for a copper chest and a barrel.
    for state <- [32_926, 24_100] do
      revision = Valimc.TestRegion.section(c.owner).revision

      assert {:error, :unsupported_block_entity} =
               Region.set_blocks(c.owner, revision, %{c.position => state})

      assert Valimc.TestBlocks.get(c.position) == 0
    end

    {:ok, furnace} = Valimc.CookingBlocks.placement(:furnace, 90.0)
    revision = Valimc.TestRegion.section(c.owner).revision
    assert {:ok, _} = Region.set_blocks(c.owner, revision, %{c.position => furnace})
    assert Valimc.TestBlocks.get(c.position) == furnace
  end

  test "target ABA cannot authorize an old placement plan", c do
    assert {:ok, prepared} = plan(c)
    assert :ok = Valimc.TestBlocks.set(c.position, 1)
    assert :ok = Valimc.TestBlocks.set(c.position, 0)

    assert {:error, :stale_revision} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    assert Valimc.TestBlocks.get(c.position) == 0
  end

  test "creative chest block and metadata apply together on creation and removal", c do
    request = %{position: c.position, face: 1, cursor: {0.5, 0.5, 0.5}, yaw: 180.0}
    assert {:ok, prepared} = plan(c, "chest", request)
    {pid, _} = c.owner

    assert {:ok, _} =
             Region.place_block(c.owner, prepared.revision, prepared.batch, prepared.deadline)

    chest = Valimc.TestBlocks.get(c.position)
    assert Valimc.TestRegion.published_block(c.owner, c.position) == chest
    old = Valimc.TestRegion.section(c.owner).containers
    assert old.entries[c.position].slots == Tuple.duplicate(nil, 27)
    {:ok, current} = Region.observe_blocks(c.owner, [c.position])

    assert :ok =
             Region.destroy_block(
               c.owner,
               current.revision,
               c.position,
               System.monotonic_time(:millisecond) + 250
             )

    assert Valimc.TestBlocks.get(c.position) == 0
    assert :ok = Region.flush(pid)

    {:ok, containers} =
      Valimc.World.Containers.decode(
        Valimc.TestDisk.read(c.path, c.key, :containers),
        c.key
      )

    assert containers.entries == %{} and containers.sequence == 2 and containers.receipts == %{}
    assert Valimc.TestRegion.section(c.owner).containers == containers
    assert Valimc.TestWorld.item_snapshot(c.key) == %{}
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, replacement} = Valimc.TestWorld.owner(c.key)
    assert Valimc.TestRegion.section(replacement).containers == containers
    assert Valimc.TestBlocks.get(c.position) == 0
  end

  test "stalled and absent sources fail without cold admission or blocking the caller", c do
    {pid, _} = c.owner
    # This owner's queries time out at the play budget (VMC-073).
    Valimc.TestScope.isolate(pid, owner_call_scale: 1)
    :sys.suspend(pid)

    try do
      assert {:error, {:retry, :block_query_timeout}} = plan(c)
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

    assert {:error, {:retry, :region_unavailable}} = plan(c, "stone", request)
    assert Valimc.TestWorld.registered(foreign) == []

    request = %{request | position: {(rx + 1) * c.span - 1, 64, rz * c.span + 40}, face: 5}
    assert {:error, :cross_owner_placement} = plan(c, "stone", request)
    assert Valimc.TestWorld.registered({rx + 1, rz}) == []
  end
end
