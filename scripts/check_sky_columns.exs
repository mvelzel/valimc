alias Valimc.World.Blocks
[trace_path] = System.argv()
Valimc.Registry.BlockFacts.install!()
rows = :json.decode(File.read!(trace_path))

for row <- rows do
  {x, z} = {row["x"], row["z"]}
  chunk = Valimc.World.chunk_key(x, z)
  {:ok, blocks} = Blocks.new(Valimc.World.region_key(chunk))
  offset = (Integer.mod(z, 16) * 16 + Integer.mod(x, 16)) * 4

  Enum.each(row["steps"], fn [y, block, expected] ->
    :ok = Blocks.put(blocks, %{{x, y, z} => block})
    {heights, _biomes} = Blocks.column_facts(blocks, chunk)
    <<_::binary-size(offset), _motion::16, sky::16, _::binary>> = heights

    unless sky - 64 == max(-64, expected),
      do:
        raise(
          "Native sky-source height differs: #{inspect({{x, y, z}, block, sky - 64, expected})}"
        )
  end)
end

IO.puts(
  "PASS: #{Enum.sum(Enum.map(rows, &length(&1["steps"])))} native sky-source heights of published columns. Empty source columns clamp to build minimum; no lateral lighting."
)
