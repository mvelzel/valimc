defmodule Valimc.MiningRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-region-#{nonce}")
    key = {20_000 + rem(nonce, 3_333) * 3, 400}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 63, rz * span}
    {:ok, {pid, _epoch} = owner} = Valimc.TestWorld.item_owner(key)
    assert :ok = Valimc.TestBlocks.set(position, Data.block("stone"))
    assert :ok = Region.flush(pid)
    {x, _, z} = position

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: 63.5,
      z: z + 0.5,
      stack: ItemStack.new("cobblestone")
    }

    on_exit(fn ->
      for {live, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    %{key: key, pid: pid, owner: owner, position: position, record: record}
  end

  test "a break removes the block and adopts its drops in one call; a second finds it gone",
       ctx do
    stone = Data.block("stone")
    assert :ok = Region.mine_block(ctx.owner, ctx.position, stone, [ctx.record])
    assert Valimc.TestBlocks.get(ctx.position) == 0
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1

    assert {:error, :stale_block} =
             Region.mine_block(ctx.owner, ctx.position, stone, [ctx.record])

    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
  end

  test "a changed block, another section and an old owner refuse the break", ctx do
    assert :ok = Valimc.TestBlocks.set(ctx.position, Data.block("dirt"))

    assert {:error, :stale_block} =
             Region.mine_block(ctx.owner, ctx.position, Data.block("stone"), [])

    assert {:error, :wrong_region} = Region.mine_block(ctx.owner, {0, 63, 0}, 0, [])

    assert {:error, {:retry, :stale_owner}} =
             Region.mine_block({ctx.pid, make_ref()}, ctx.position, Data.block("dirt"), [])

    assert Valimc.TestBlocks.get(ctx.position) == Data.block("dirt")
    assert Valimc.TestWorld.item_snapshot(ctx.key) == %{}
  end
end
