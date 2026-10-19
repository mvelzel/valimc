# Elixir edit map + reference encoder versus Rust paletted sections (VMC-062).
#   mix run bench/section_storage.exs
# Measures one chunk's packet bytes (sections + heightmaps + block entities, before
# compression) and the block memory of that chunk. Medians of `runs` samples.
alias Valimc.World.{Blocks, Chunk}
alias Valimc.Protocol.Wire

runs = 30
:rand.seed(:exsss, {62, 62, 62})

median = fn fun ->
  times = for _ <- 1..runs, do: elem(:timer.tc(fun), 0)
  Enum.at(Enum.sort(times), div(runs, 2))
end

# Terrain-like: every block of y -64..127 from 24 states with vertical bands and noise.
terrain =
  for x <- 0..15, z <- 0..15, y <- -64..127, into: %{} do
    band = div(y + 64, 12)
    {{x, y, z}, if(:rand.uniform(10) == 1, do: 1 + :rand.uniform(400), else: 1 + band)}
  end

scenarios = [
  {"flat (untouched)", %{}},
  {"one edit", %{{1, 64, 1} => 1}},
  {"4,096 random edits",
   Map.new(1..4096, fn _ ->
     {{:rand.uniform(16) - 1, :rand.uniform(384) - 65, :rand.uniform(16) - 1},
      :rand.uniform(2000)}
   end)},
  {"terrain-like (49,152 blocks)", terrain}
]

IO.puts(
  "| Scenario | Elixir encode µs | Rust encode µs | Elixir map bytes | Rust section bytes |"
)

IO.puts("|---|---:|---:|---:|---:|")

for {name, edits} <- scenarios do
  {:ok, blocks} = Blocks.new({0, 0}, edits)
  bytes = fn {id, payload} -> IO.iodata_to_binary([Wire.varint(id), payload]) end
  true = bytes.(Chunk.encode({0, 0}, edits)) == bytes.(Blocks.packet(blocks, {0, 0}))
  elixir = median.(fn -> bytes.(Chunk.encode({0, 0}, edits)) end)
  rust = median.(fn -> bytes.(Blocks.packet(blocks, {0, 0})) end)
  map_bytes = :erts_debug.flat_size(edits) * 8
  IO.puts("| #{name} | #{elixir} | #{rust} | #{map_bytes} | #{Blocks.heap_bytes(blocks)} |")
end

{:ok, blocks} = Blocks.new({0, 0})
batch = Enum.take(terrain, 4096) |> Map.new()
put = median.(fn -> :ok = Blocks.put(blocks, batch) end)
get = median.(fn -> Blocks.get_many(blocks, Map.keys(batch)) end)
IO.puts("\n4,096-block batch: put #{put} µs, get_many #{get} µs (one NIF call each)")
