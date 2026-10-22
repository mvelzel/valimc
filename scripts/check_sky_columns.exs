alias Valimc.World.Blocks
[trace_path] = System.argv()
Valimc.Data.BlockFacts.install!()
rows = :json.decode(File.read!(trace_path))

for row <- rows do
  {x, z} = {row["x"], row["z"]}
  chunk = Valimc.World.chunk_key(x, z)
  {:ok, blocks} = Blocks.new(Valimc.World.region_key(chunk))

  Enum.each(row["steps"], fn [y, block, expected] ->
    :ok = Blocks.put(blocks, %{{x, y, z} => block})
    [snapshot] = Blocks.snapshots(blocks, [{chunk, nil}], 0)
    {:ok, {_motion, sky}} = Valimc.Native.snapshot_column(snapshot, x, z)

    unless sky == max(-64, expected),
      do: raise("Native sky-source height differs: #{inspect({{x, y, z}, block, sky, expected})}")
  end)
end

IO.puts(
  "PASS: #{Enum.sum(Enum.map(rows, &length(&1["steps"])))} native sky-source heights of published columns. Empty source columns clamp to build minimum; no lateral lighting."
)
