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

    %{key: key, position: position, owner: owner, span: span}
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
