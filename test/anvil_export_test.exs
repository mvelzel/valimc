defmodule Valimc.AnvilExportTest do
  @moduledoc "Region files and chunks written for vanilla (VMC-021e3), read back by the importer's readers."
  use ExUnit.Case, async: true
  alias Valimc.Anvil.{Chunk, RegionFile, RegionWriter}
  alias Valimc.NBT
  alias Valimc.Protocol.Data
  alias Valimc.Registry.Blocks, as: BlockRegistry
  alias Valimc.World.Blocks

  setup do
    dir = Path.join(System.tmp_dir!(), "valimc-export-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "region files hold every chunk where the reader finds it, large ones externally", ctx do
    small = :crypto.strong_rand_bytes(100)
    # Incompressible and over 255 sectors: vanilla moves it to `c.X.Z.mcc`.
    large = :crypto.strong_rand_bytes(1_100_000)
    medium = :binary.copy(<<7>>, 50_000)
    chunks = %{{-32, -1} => small, {-1, -32} => large, {-17, -5} => medium}
    assert RegionWriter.write(ctx.dir, {-1, -1}, chunks, 1_700_000_000) == :ok
    path = Path.join(ctx.dir, "r.-1.-1.mca")
    assert File.exists?(Path.join(ctx.dir, "c.-1.-32.mcc"))
    refute File.exists?(path <> ".tmp")

    {:ok, read} = RegionFile.chunks(path, 4_000_000)
    assert Map.new(read) == Map.new(chunks, fn {chunk, bytes} -> {chunk, {:ok, bytes}} end)
    assert byte_size(File.read!(path)) |> rem(4096) == 0

    for {_, _, _, timestamp} <- RegionFile.slots(File.read!(path)),
        do: assert(timestamp == 1_700_000_000)
  end

  test "a chunk's NBT imports back to the same blocks, biomes and block entities" do
    key = {0, 0}
    {:ok, blocks} = Blocks.new(key)
    stairs = BlockRegistry.state("oak_stairs", %{"facing" => "east", "half" => "top"})

    edits =
      Map.new(0..299, fn i ->
        {{rem(i, 16), -64 + div(i, 7), rem(div(i, 16), 16)},
         Enum.at([stairs, Data.block("glass"), Data.block("chest"), 0], rem(i, 4))}
      end)

    :ok = Blocks.put(blocks, edits)
    {:ok, states, biomes} = Blocks.dump_column(blocks, {0, 0})
    entity = {:compound, %{"id" => {:string, "minecraft:sign"}, "x" => {:int, 0}}}
    extras = %{"structures" => {:compound, %{"starts" => {:compound, %{}}}}}
    tag = Chunk.to_nbt({0, 0}, states, biomes, [entity], extras)

    {:compound, root} = tag

    assert root["Status"] == {:string, "minecraft:full"} and
             root["structures"] == extras["structures"]

    assert root["block_entities"] == NBT.list([entity])

    # Written and read as a world file, the chunk converts back to the same column.
    {:ok, read} = tag |> NBT.write() |> IO.iodata_to_binary() |> NBT.read()
    {{:ok, %{chunk: {0, 0}, sections: specs}}, _} = Chunk.column(read)
    {:ok, other} = Blocks.new(key)
    :ok = Blocks.put_column(other, {0, 0}, specs)
    assert Blocks.dump_column(other, {0, 0}) == {:ok, states, biomes}
  end

  test "native vanilla packing equals the Elixir reference" do
    sections =
      [
        :binary.copy(<<0, 9>>, 4096),
        for(i <- 0..4095, into: <<>>, do: <<rem(i * 7, 3)::16>>),
        for(i <- 0..4095, into: <<>>, do: <<rem(i * 31, 300)::16>>),
        for(i <- 0..4095, into: <<>>, do: <<:rand.uniform(35_000)::16>>),
        for(i <- 0..63, into: <<>>, do: <<rem(i, 5)::16>>)
      ]

    for values <- sections, minimum <- [0, 4] do
      {palette, data} = Chunk.pack_reference(values, minimum)
      assert Valimc.Native.pack_paletted(values, minimum) == {:ok, {palette, data}}
    end

    assert Valimc.Native.pack_paletted(<<1>>, 4) == {:error, :invalid_layers}
  end
end
