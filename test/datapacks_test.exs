defmodule Valimc.DatapacksTest do
  @moduledoc """
  A world's data packs (VMC-028c): their digest, the facts cached under it and
  the refusals. Vanilla parity of a pack's worldgen is stage
  `worldgen_datapack`.
  """
  use ExUnit.Case, async: true
  alias Valimc.World.{Datapacks, Generator}

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-packs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  defp pack!(base, name, files) do
    for {path, text} <- files do
      file = Path.join([base, "datapacks", name, path])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, text)
    end
  end

  defp facts!(base, biomes) do
    dir = Path.join([base, "worldgen", Datapacks.digest(base)])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "biomes.json"), JSON.encode!(Map.new(biomes, &{&1, %{}})))
    File.write!(Path.join(dir, "packs.json"), JSON.encode!(%{digest: Datapacks.digest(base)}))
    dir
  end

  test "a world without packs generates from vanilla's facts", %{base: base} do
    assert Datapacks.packs(base) == []
    assert Datapacks.digest(base) == nil
    assert Datapacks.facts(base) == {:ok, nil}
    File.mkdir_p!(Path.join(base, "datapacks"))
    assert Datapacks.facts(base) == {:ok, nil}
  end

  test "the digest follows every pack's name and bytes", %{base: base} do
    pack!(base, "b", %{"pack.mcmeta" => "{}", "data/x/worldgen/biome/a.json" => "{}"})
    pack!(base, "a", %{"pack.mcmeta" => "{}"})
    File.write!(Path.join([base, "datapacks", "notes.txt"]), "not a pack")
    assert Enum.map(Datapacks.packs(base), &Path.basename/1) == ["a", "b"]

    digest = Datapacks.digest(base)
    assert digest =~ ~r/^[0-9a-f]{64}$/
    assert Datapacks.digest(base) == digest

    pack!(base, "b", %{"data/x/worldgen/biome/a.json" => "{ }"})
    refute Datapacks.digest(base) == digest

    # A zip of the same files is the same pack.
    pack!(base, "b", %{"data/x/worldgen/biome/a.json" => "{}"})
    folder = Path.join([base, "datapacks", "b"])

    {:ok, _} =
      :zip.create(
        String.to_charlist(Path.join([base, "datapacks", "b.zip"])),
        [~c"data/x/worldgen/biome/a.json", ~c"pack.mcmeta"],
        cwd: String.to_charlist(folder)
      )

    File.rm_rf!(folder)
    assert Enum.map(Datapacks.packs(base), &Path.basename/1) == ["a", "b.zip"]
    refute Datapacks.digest(base) == digest

    unpacked = Path.join(base, "unpacked")
    [a, b] = Datapacks.unpack(base, unpacked)
    assert a == Path.join([base, "datapacks", "a"])
    assert File.read!(Path.join(b, "data/x/worldgen/biome/a.json")) == "{}"
  end

  test "packs without facts, or facts that change the biomes, are refused", %{base: base} do
    pack!(base, "sample", %{"pack.mcmeta" => "{}"})
    assert {:error, {:datapack_facts_missing, hint}} = Datapacks.facts(base)
    assert hint =~ "mix valimc.worldgen_packs"
    assert {:error, {:datapack_facts_missing, _}} = Generator.create(base, 1)
    refute File.exists?(Path.join(base, "world.json"))

    dir = facts!(base, Valimc.Worldgen.biome_names())
    assert Datapacks.facts(base) == {:ok, dir}

    facts!(base, ["minecraft:plains", "sample:new"])
    assert Datapacks.facts(base) == {:error, {:unsupported_datapack, :biomes_added_or_removed}}

    # Facts of other packs (a stale digest) are not these packs' facts.
    facts!(base, Valimc.Worldgen.biome_names())
    pack!(base, "sample", %{"pack.mcmeta" => "{ }"})
    assert {:error, {:datapack_facts_missing, _}} = Datapacks.facts(base)
  end
end
