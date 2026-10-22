defmodule Valimc.PlacementRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World.{BlockBatch, Containers, Region}

  @chest hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-placement-region-#{nonce}")
    key = {20_000 + rem(nonce, 3_333) * 3, 700}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    position = {rx * span + 4, 64, rz * span + 4}
    {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(key)

    on_exit(fn ->
      for {live, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    %{base: base, key: key, pid: pid, owner: owner, position: position}
  end

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :containers)

  test "a chest's block and empty contents apply in one placement; its break clears both", ctx do
    {:ok, observed} = Region.observe_blocks(ctx.owner, [ctx.position])
    {:ok, batch} = BlockBatch.prepare(%{ctx.position => @chest})
    deadline = System.monotonic_time(:millisecond) + 200
    assert {:ok, _} = Region.place_block(ctx.owner, observed.revision, batch, deadline)
    assert Valimc.TestRegion.section(ctx.owner).containers.entries[ctx.position].rows == 3
    assert :ok = Region.flush(ctx.pid)
    {:ok, containers} = Containers.decode(disk(ctx), ctx.key)
    assert containers.entries[ctx.position].slots == Tuple.duplicate(nil, 27)
    assert Valimc.TestBlocks.get(ctx.position) == @chest

    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(ctx.key)
    assert Valimc.TestRegion.section(owner).containers == containers
    assert :ok = Region.mine_block(owner, ctx.position, @chest, [])
    assert Valimc.TestBlocks.get(ctx.position) == Valimc.Data.BlockFacts.fluid_remains(@chest)
    assert :ok = Region.flush(pid)

    assert disk(ctx) == nil or
             match?({:ok, %{entries: e}} when e == %{}, Containers.decode(disk(ctx), ctx.key))
  end
end
