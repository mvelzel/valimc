defmodule Valimc.PlacementRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World

  alias Valimc.World.{
    MiningTransfers,
    PlacementTransfers,
    Region
  }

  @chest hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-placement-region-#{nonce}")
    key = {20_000 + rem(nonce, 3_333) * 3, 700}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 64, rz * span}
    other = {rx * span + 1, 64, rz * span}
    {:ok, {pid, epoch} = owner} = World.item_owner(key)
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, reservation} = Region.reserve_placement(owner, observed.revision, observed.blocks)

    transfer =
      Map.merge(reservation, %{source: <<nonce::128>>, sequence: 1, edits: %{position => 1}})

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    %{
      base: base,
      key: key,
      pid: pid,
      epoch: epoch,
      owner: owner,
      position: position,
      other: other,
      transfer: transfer
    }
  end

  defp reserve(owner, positions) do
    {:ok, observed} = Region.observe_blocks(owner, positions)
    Region.reserve_placement(owner, observed.revision, observed.blocks)
  end

  defp writing(pid, _budget \\ nil),
    do:
      Valimc.TestWait.until(fn ->
        Valimc.TestRegion.in_flight(Valimc.TestConn.state(pid).resource)
      end)

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :containers)

  defp receipt(ctx, owner, request, outcome) do
    assert {:ok, {key, receipt}} = Region.item_transfer_receipt(owner, request.source)
    assert key == ctx.key
    assert {:ok, ^outcome} = PlacementTransfers.receipt_result(key, request, receipt)
    receipt
  end

  test "a chest's block, empty contents and receipt publish together and remove together after restart",
       ctx do
    {x, y, z} = ctx.position
    position = {x + 4, y, z + 4}
    {:ok, reservation} = reserve(ctx.owner, [position])
    ctx = %{ctx | position: position, transfer: Map.merge(ctx.transfer, reservation)}
    request = %{ctx.transfer | edits: %{ctx.position => @chest}}
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_placement_transfer(ctx.owner, request) end)

    try do
      pending = writing(ctx.pid)
      assert pending.containers.entries[ctx.position].rows == 3
      # Adopted in owner memory; the published block waits for durability.
      assert Valimc.TestRegion.published_block(ctx.owner, ctx.position) == 0
      assert Task.yield(task, 10) == nil
      :sys.resume(writer)
      assert {:ok, :applied} = Task.await(task, 60_000)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end

    {:ok, containers} = Valimc.World.Containers.decode(disk(ctx), ctx.key)
    assert containers.entries[ctx.position].slots == Tuple.duplicate(nil, 27)
    assert containers.sequence == 1 and containers.receipts == %{}
    assert Valimc.TestBlocks.get(ctx.position) == @chest
    receipt(ctx, ctx.owner, request, :applied)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_placement_transfer(owner, request)
    assert :sys.get_state(elem(owner, 0)).resource.containers == containers
    {:ok, reserved} = Region.reserve_mining(owner, [ctx.position])
    removal = Map.merge(reserved, %{source: request.source, sequence: 2, records: []})
    assert {:ok, :applied} = Region.apply_mining_transfer(owner, removal)
    assert Valimc.TestBlocks.get(ctx.position) == Valimc.Registry.BlockFacts.fluid_remains(@chest)
    {:ok, removed} = Valimc.World.Containers.decode(disk(ctx), ctx.key)
    assert removed.entries == %{} and removed.sequence == 2 and removed.receipts == %{}
    assert {:ok, :already_applied} = Region.apply_mining_transfer(owner, removal)
  end

  test "unrelated edits preserve permits; target ABA, release and changed context reject durably",
       ctx do
    assert :ok = Valimc.TestBlocks.set(ctx.other, 1)
    assert {:ok, :applied} = Region.apply_placement_transfer(ctx.owner, ctx.transfer)
    {:ok, reserved} = reserve(ctx.owner, [ctx.other])

    request =
      Map.merge(ctx.transfer, reserved) |> Map.merge(%{sequence: 2, edits: %{ctx.other => 10}})

    assert :ok = Valimc.TestBlocks.set(ctx.other, 10)
    assert :ok = Valimc.TestBlocks.set(ctx.other, 1)
    assert {:ok, :rejected} = Region.apply_placement_transfer(ctx.owner, request)
    assert {:ok, :already_rejected} = Region.apply_placement_transfer(ctx.owner, request)
    assert Valimc.TestBlocks.get(ctx.other) == 1
    receipt(ctx, ctx.owner, request, :rejected)
    {:ok, released} = reserve(ctx.owner, [ctx.other])
    assert :ok = Region.release_placement(ctx.owner, released.permit)
    request = Map.merge(request, released) |> Map.put(:sequence, 3)
    assert {:ok, :rejected} = Region.apply_placement_transfer(ctx.owner, request)
    {:ok, observed} = Region.observe_blocks(ctx.owner, [ctx.other])

    assert {:error, :placement_context_changed} =
             Region.reserve_placement(ctx.owner, observed.revision, %{ctx.other => 0})

    assert :ok = Valimc.TestBlocks.set(ctx.position, 10)

    assert {:error, :stale_revision} =
             Region.reserve_placement(ctx.owner, observed.revision, observed.blocks)
  end

  test "mining permits, receipt hashes and malformed requests cannot authorize placement", ctx do
    {:ok, mining} = Region.reserve_mining(ctx.owner, [ctx.position])
    request = Map.merge(ctx.transfer, mining)
    assert {:ok, :rejected} = Region.apply_placement_transfer(ctx.owner, request)
    actual = receipt(ctx, ctx.owner, request, :rejected)

    assert {:error, :transfer_conflict} =
             MiningTransfers.receipt_result(
               ctx.key,
               request |> Map.delete(:edits) |> Map.put(:records, []),
               actual
             )

    assert {:error, :transfer_conflict} = Region.apply_placement_transfer(ctx.owner, ctx.transfer)

    assert {:error, :invalid_placement_request} =
             Region.apply_placement_transfer(ctx.owner, %{ctx.transfer | sequence: 0})

    assert {:error, :invalid_placement_reservation} = Region.reserve_placement(ctx.owner, 0, %{})

    assert {:error, :stale_owner} =
             Region.release_placement({ctx.pid, make_ref()}, ctx.transfer.permit)

    assert Valimc.TestBlocks.get(ctx.position) == 0
  end
end
