# Elixir edit map + reference encoder versus Rust paletted sections (VMC-062).
#   mix run bench/section_storage.exs
# One chunk's packet bytes (sections, heightmaps, block entities; before
# compression) per scenario, plus that chunk's block memory.
alias Valimc.World.{Blocks, Chunk}
alias Valimc.Protocol.Wire

:rand.seed(:exsss, {62, 62, 62})
bytes = fn {id, payload} -> IO.iodata_to_binary([Wire.varint(id), payload]) end
random = fn -> {:rand.uniform(16) - 1, :rand.uniform(384) - 65, :rand.uniform(16) - 1} end

# Terrain-like: every block of y -64..127 from vertical bands with 10% noise.
terrain =
  for x <- 0..15, z <- 0..15, y <- -64..127, into: %{} do
    band = div(y + 64, 12)
    {{x, y, z}, if(:rand.uniform(10) == 1, do: 1 + :rand.uniform(400), else: 1 + band)}
  end

inputs =
  for {name, edits} <- [
        {"flat (untouched)", %{}},
        {"one edit", %{{1, 64, 1} => 1}},
        {"4,096 random edits", Map.new(1..4096, fn _ -> {random.(), :rand.uniform(2000)} end)},
        {"terrain-like (49,152 blocks)", terrain}
      ],
      into: %{} do
    {:ok, blocks} = Blocks.new({0, 0}, edits)
    true = bytes.(Chunk.encode({0, 0}, edits)) == bytes.(Blocks.packet(blocks, {0, 0}))

    IO.puts(
      "#{name}: Elixir map #{:erts_debug.flat_size(edits) * 8} B, " <>
        "Rust sections #{elem(Valimc.Native.heap_bytes(blocks.ref), 1)} B"
    )

    {name, {edits, blocks}}
  end

Benchee.run(
  %{
    "elixir edit map encode" => fn {edits, _} -> bytes.(Chunk.encode({0, 0}, edits)) end,
    "rust section encode" => fn {_, blocks} -> bytes.(Blocks.packet(blocks, {0, 0})) end
  },
  inputs: inputs,
  warmup: 1,
  time: 3,
  memory_time: 1
)

{:ok, blocks} = Blocks.new({0, 0})
batch = terrain |> Enum.take(4096) |> Map.new()

Benchee.run(
  %{
    "put 4,096 blocks" => fn -> :ok = Blocks.put(blocks, batch) end,
    "get_many 4,096 blocks" => fn -> Blocks.get_many(blocks, Map.keys(batch)) end
  },
  warmup: 1,
  time: 2
)
