defmodule Valimc.StructureFlagsTest do
  @moduledoc """
  Structure start flags between finalize transactions (VMC-025f6): a mineshaft
  spider corridor that two regions' transactions decorate gets one cave spider
  spawner, as vanilla's saved start gives it, also when the owners restart in
  between.

  Seed 20261020's mineshaft starting at chunk (8, -8) has a spider corridor at
  x 151..153, y -44..-42, z -117..-108: its chunk (9, -8) is decorated with
  region (1, -2), its chunk (9, -7) with region (1, -1). Vanilla places the
  spawner in the first chunk with a free spot; without the flag the second
  transaction placed another (`worldgen_live_structures` covers the rest).
  """
  use ExUnit.Case, async: false
  alias Valimc.{Native, TestScope}
  alias Valimc.World.{Generator, Spawn}
  alias Valimc.Worldgen.Proto

  @seed 20_261_020
  @source "minecraft:overworld"
  @first {1, -2}
  @second {1, -1}
  @moduletag timeout: 300_000

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-flags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    File.write!(
      Spawn.path(base),
      JSON.encode!(%{
        "spawn" => [0, 100, 0],
        "yaw" => 0.0,
        "generator" => %{"type" => "vanilla", "seed" => @seed, "features" => true}
      })
    )

    keys = Enum.uniq(TestScope.neighborhood(@first, 3) ++ TestScope.neighborhood(@second, 3))
    TestScope.isolate(keys, world_path: base)

    on_exit(fn ->
      stop(keys)
      File.rm_rf(base)
    end)

    {:ok, worldgen} = Generator.worldgen(@seed)
    %{keys: keys, worldgen: worldgen}
  end

  defp stop(keys) do
    for key <- keys,
        {pid, _} <- Registry.lookup(Valimc.ProtoRegistry, key),
        do: TestScope.kill(pid)
  end

  defp corridor_spawners(full) do
    for %{block_entities: entities} <- full,
        %{position: {x, y, z}, kind: "minecraft:mob_spawner"} <- entities,
        x in 151..153 and y in -44..-42 and z in -117..-108,
        do: {x, y, z}
  end

  test "two transactions' NIF calls place the corridor's spawner once", ctx do
    area = Enum.uniq(Proto.around(@first, 2) ++ Proto.around(@second, 2))

    images =
      area
      |> Enum.chunk_every(8)
      |> Task.async_stream(&Native.worldgen_proto_terrain(ctx.worldgen, @source, &1, true),
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, {:ok, list}} -> list end)
      |> Map.new(fn {x, z, image} -> {{x, z}, image} end)

    # Each call decodes the images the last one encoded, as owners pass them.
    images =
      Enum.reduce(
        [Proto.around(@first, 1), Proto.around(@second, 1) -- Proto.around(@first, 1)],
        images,
        fn order, acc ->
          {:ok, {touched, 0}} =
            Native.worldgen_proto_decorate(ctx.worldgen, @source, Map.values(acc), order, true)

          Map.merge(acc, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))
        end
      )

    own = Enum.map(Proto.chunks_of(@second), &images[&1])
    {:ok, full} = Native.worldgen_proto_full(ctx.worldgen, own, Generator.protocol_biomes())
    assert [{_, _, z}] = corridor_spawners(full)
    # The first transaction placed it, in chunk (9, -8).
    assert z < -112
  end

  test "proto owners keep the flag across a restart", ctx do
    {:ok, _} = Proto.full_chunks(@first)
    stop(ctx.keys)
    {:ok, full} = Proto.full_chunks(@second)
    assert [{_, _, z}] = corridor_spawners(full)
    assert z < -112
  end
end
