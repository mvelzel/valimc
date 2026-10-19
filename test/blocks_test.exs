defmodule Valimc.World.BlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.World.{Blocks, Chunk}

  @key {0, 0}

  defp bytes({id, payload}), do: IO.iodata_to_binary([Wire.varint(id), payload])

  defp rust_packet(blocks, chunk), do: bytes(Blocks.packet(blocks, chunk))

  defp random_edits(seed, count, states) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

    Map.new(1..count, fn _ ->
      {{:rand.uniform(16) - 1, :rand.uniform(384) - 65, :rand.uniform(16) - 1},
       Enum.random(states)}
    end)
  end

  test "chunk packets are byte-identical to the Elixir reference across palette widths" do
    count = Data.block_state_count()
    few = [0, 1, 9, 10, 14, 15, 88, 661]

    cases = [
      {1, 40, few},
      # >16 distinct states in a section: wider indexed palettes.
      {2, 3_000, Enum.take_random(0..(count - 1), 100)},
      # >256 distinct states in a section: the direct (global) encoding.
      {3, 6_000, Enum.to_list(0..(count - 1))},
      # Water/lava levels and every air variant affect the vanilla section counts.
      {4, 500, [0, 18_649, 18_650] ++ Enum.to_list(86..117) ++ few}
    ]

    for {seed, n, states} <- cases do
      edits = random_edits(seed, n, states)
      {:ok, blocks} = Blocks.new(@key, edits)
      assert rust_packet(blocks, {0, 0}) == bytes(Chunk.encode({0, 0}, edits)), "seed #{seed}"

      assert Blocks.image(blocks) ==
               Map.reject(edits, fn {{_, y, _}, b} -> b == Chunk.base(y) end)
    end
  end

  test "untouched chunks use the cached flat packet; edited ones reverting to flat match it" do
    {:ok, blocks} = Blocks.new(@key)
    assert Blocks.encode(blocks, {3, 5}) == :flat
    :ok = Blocks.put(blocks, %{{50, 70, 80} => 1})
    :ok = Blocks.put(blocks, %{{50, 70, 80} => 0})
    assert %{sections: _} = Blocks.encode(blocks, {3, 5})
    assert rust_packet(blocks, {3, 5}) == bytes(Chunk.encode({3, 5}, %{}))
  end

  test "chests in a chunk become block entities without exporting its edits" do
    chest = Enum.min(Valimc.ChestAccess.single_states())
    edits = %{{1, 64, 1} => chest, {2, 64, 1} => 1, {20, 64, 1} => chest}
    {:ok, blocks} = Blocks.new(@key, edits)
    assert Blocks.chunk_entities(blocks, {0, 0}) == %{{1, 64, 1} => chest}
    assert rust_packet(blocks, {0, 0}) == bytes(Chunk.encode({0, 0}, edits))
  end

  test "reads, atomic batches and reverting to flat terrain" do
    {:ok, blocks} = Blocks.new(@key)
    stone = Data.block("stone")
    assert Blocks.get(blocks, {1, 63, 1}) == Data.block("grass_block")

    assert Blocks.put(blocks, %{{1, 70, 1} => stone, {1, 70, 2} => 99_999}) ==
             {:error, :invalid_state}

    assert Blocks.get(blocks, {1, 70, 1}) == 0
    assert Blocks.put(blocks, %{{1, 70, 1} => stone, {1, 63, 1} => 0}) == :ok

    assert Blocks.get_many(blocks, [{1, 70, 1}, {1, 63, 1}]) == %{
             {1, 70, 1} => stone,
             {1, 63, 1} => 0
           }

    assert Blocks.image(blocks, %{{1, 63, 1} => Data.block("grass_block")}) == %{
             {1, 70, 1} => stone
           }

    assert Blocks.heap_bytes(blocks) > 0

    :ok = Blocks.put(blocks, %{{1, 70, 1} => 0, {1, 63, 1} => Data.block("grass_block")})
    :ok = Blocks.compact(blocks)
    assert Blocks.image(blocks) == %{}
    assert Blocks.heap_bytes(blocks) == 0
  end

  test "outside the region or world height reads the flat profile and rejects writes" do
    {:ok, blocks} = Blocks.new(@key)
    size = Valimc.config(:region_size) * 16
    assert Blocks.get(blocks, {size, 63, 0}) == Data.block("grass_block")
    assert Blocks.get(blocks, {0, 400, 0}) == 0
    assert Blocks.put(blocks, %{{size, 70, 0} => 1}) == {:error, :out_of_region}
    assert Blocks.put(blocks, %{{0, 320, 0} => 1}) == {:error, :invalid_y}
  end
end
