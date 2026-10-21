defmodule Valimc.ColumnRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Protocol.Data
  alias Valimc.World
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {980, nonce}
    base = Path.join(System.tmp_dir!(), "valimc-columns-#{nonce}")
    TestScope.isolate(key, world_path: base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, owner} = World.owner(key)
    %{owner: owner, key: key, x: 980 * 128, z: nonce * 128}
  end

  test "block and column observations share one revision through batch and direct mutations",
       ctx do
    {x, z} = column = {ctx.x, ctx.z}

    assert {:ok, %{revision: 0, columns: %{^column => initial}}} =
             Region.observe_columns(ctx.owner, [column])

    assert initial == %{world_surface: 64, motion_blocking: 64, sky_source: 64}

    assert {:ok, 1} =
             Region.set_blocks(ctx.owner, 0, %{{x, 90, z} => 1, {x, 91, z} => Data.block("glass")})

    assert {:error, :stale_revision} = Region.observe_columns(ctx.owner, [column], 0)

    assert {:ok, %{revision: 1, columns: %{^column => heights}}} =
             Region.observe_columns(ctx.owner, [column], 1)

    assert heights == %{world_surface: 92, motion_blocking: 92, sky_source: 91}
    assert :ok = Valimc.TestBlocks.remove({x, 90, z})

    assert {:ok, %{revision: 2, columns: %{^column => heights}}} =
             Region.observe_columns(ctx.owner, [column], 2)

    assert heights == %{world_surface: 92, motion_blocking: 92, sky_source: 64}

    assert {:ok, %{revision: 2, blocks: %{{^x, 90, ^z} => 0}}} =
             Region.observe_blocks(ctx.owner, [{x, 90, z}], 2)

    assert {:error, :invalid_block_batch} =
             Valimc.TestBlocks.set({x, 90, z}, Data.block_state_count())

    assert {:ok, %{revision: 2}} = Region.observe_columns(ctx.owner, [], 2)
  end

  test "replacement rebuilds columns from the committed edits and fences the old incarnation",
       ctx do
    {pid, epoch} = ctx.owner
    column = {ctx.x, ctx.z}
    assert :ok = Valimc.TestBlocks.set({ctx.x, 319, ctx.z}, 1)
    assert :ok = Region.flush(pid)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert {:ok, {next, next_epoch} = owner} = World.owner(ctx.key)
    assert next != pid and next_epoch != epoch
    assert {:error, :stale_owner} = Region.observe_columns({next, epoch}, [column])

    assert {:ok, %{revision: 0, columns: %{^column => heights}}} =
             Region.observe_columns(owner, [column])

    assert heights == %{world_surface: 320, motion_blocking: 320, sky_source: 320}
    assert :ok = Valimc.TestBlocks.remove({ctx.x, 319, ctx.z})

    assert {:ok, %{columns: %{^column => %{sky_source: 64}}}} =
             Region.observe_columns(owner, [column])
  end

  test "column reads reject unbounded, malformed and foreign queries", ctx do
    for bad <- [
          Enum.map(0..128, &{ctx.x + rem(&1, 128), ctx.z}),
          [{ctx.x * 1.0, ctx.z}],
          [{30_000_000, 0}],
          :all
        ] do
      assert {:error, :invalid_column_query} = Region.observe_columns(ctx.owner, bad)
    end

    assert {:error, :wrong_region} = Region.observe_columns(ctx.owner, [{ctx.x + 128, ctx.z}])
    assert {:error, :invalid_column_query} = Region.observe_columns(ctx.owner, [], -1)
  end
end
