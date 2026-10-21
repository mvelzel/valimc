alias Valimc.World.{Chunk, View}
[trace_path] = System.argv()
rows = :json.decode(File.read!(trace_path))

for row <- rows do
  {x, z} = {row["x"], row["z"]}

  Enum.reduce(row["steps"], %{}, fn [y, block, expected], edits ->
    position = {x, y, z}

    edits =
      if block == Chunk.base(y),
        do: Map.delete(edits, position),
        else: Map.put(edits, position, block)

    column = Map.new(Chunk.min_y()..320, &{{x, &1, z}, Chunk.block_at(edits, {x, &1, z})})
    {:ok, heights} = Valimc.PlayerRainQuery.heights(View.of(column), x, z)

    unless heights.sky_source == max(-64, expected),
      do:
        raise(
          "Native sky-source height differs: #{inspect({position, block, heights, expected})}"
        )

    edits
  end)
end

IO.puts(
  "PASS: #{Enum.sum(Enum.map(rows, &length(&1["steps"])))} native sky-source heights of edited columns. Empty source columns clamp to build minimum; no lateral lighting."
)
