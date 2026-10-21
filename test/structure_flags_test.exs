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
  @moduletag :slow
  alias Valimc.{Native, TestScope}
  alias Valimc.World.Generator
  alias Valimc.Worldgen.Proto

  @seed 20_261_020
  @source "minecraft:overworld"
  @first {1, -2}
  @second {1, -1}
  @moduletag timeout: 300_000

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-flags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    :ok =
      Valimc.World.Spec.write(base, %{"type" => "vanilla", "seed" => @seed, "features" => true})

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

  test "proto owners keep the flag across a restart", ctx do
    {:ok, _} = Proto.full_chunks(@first)
    stop(ctx.keys)
    {:ok, full} = Proto.full_chunks(@second)
    assert [{_, _, z}] = corridor_spawners(full)
    assert z < -112
  end
end
