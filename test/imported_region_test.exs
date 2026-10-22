defmodule Valimc.ImportedRegionTest do
  @moduledoc "Imported column images persist in the region log; edits on top survive restarts (VMC-021c)."
  use ExUnit.Case, async: true
  alias Valimc.Protocol.Data
  alias Valimc.Registry.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World.{Blocks, Region, RegionStorage}

  @plains Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
  @desert Data.registry_id("minecraft:worldgen/biome", "minecraft:desert")

  setup do
    nonce = System.unique_integer([:positive])
    key = {78_000 + rem(nonce, 3_333) * 3, 1840}
    base = Path.join(System.tmp_dir!(), "valimc-imported-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.config(:region_size)
    %{key: key, base: base, chunk: {rx * size + 2, rz * size + 3}}
  end

  # An imported chunk: air below y 0 is a cave (flat terrain has stone there),
  # sandstone from y 0 to 15, desert biomes in that section.
  defp image(key, chunk) do
    air = {[0], <<>>, 0, [@plains], <<>>, 0}
    sandstone = {[BlockRegistry.default_state("sandstone")], <<>>, 0, [@desert], <<>>, 0}
    specs = List.duplicate(air, 4) ++ [sandstone] ++ List.duplicate(air, 19)
    {:ok, blocks} = Blocks.new(key)
    :ok = Valimc.Native.put_column(blocks.ref, elem(chunk, 0), elem(chunk, 1), specs)
    {:ok, image} = Blocks.column_image(blocks, chunk)
    image
  end

  defp block(owner, position) do
    {:ok, %{blocks: %{^position => state}}} = Region.observe_blocks(owner, [position])
    state
  end

  defp restart(key) do
    {:ok, {pid, _}} = Valimc.TestWorld.owner(key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, owner} = Valimc.TestWorld.owner(key)
    owner
  end

  test "an imported column loads from its checkpoint and edits equal to flat terrain persist",
       ctx do
    {cx, cz} = ctx.chunk
    columns = %{ctx.chunk => image(ctx.key, ctx.chunk)}
    assert RegionStorage.import(ctx.base, :overworld, ctx.key, %{columns: columns}) == :ok
    assert RegionStorage.import(ctx.base, :overworld, ctx.key, %{}) == {:error, :region_exists}

    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    cave = {cx * 16 + 5, 10 - 30, cz * 16 + 5}
    top = {cx * 16 + 5, 63, cz * 16 + 5}
    beside = {(cx + 1) * 16 + 5, 10 - 30, cz * 16 + 5}
    assert block(owner, cave) == 0
    assert block(owner, {cx * 16, 3, cz * 16}) == BlockRegistry.default_state("sandstone")
    assert block(owner, top) == 0
    assert block(owner, beside) == BlockRegistry.default_state("stone")

    # Stone is what flat terrain has at that height; in the imported chunk it is an edit.
    stone = BlockRegistry.default_state("stone")
    {:ok, observed} = Region.observe_blocks(owner, [cave])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{cave => stone})

    owner = restart(ctx.key)
    assert block(owner, cave) == stone
    assert block(owner, top) == 0
    assert block(owner, {cx * 16, 3, cz * 16}) == BlockRegistry.default_state("sandstone")
  end
end
