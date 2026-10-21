alias Valimc.World.{Chunk, ColumnIndex}
[trace_path] = System.argv()

rows = :json.decode(File.read!(trace_path))

for row <- rows do
  {x, z} = column = {row["x"], row["z"]}

  Enum.reduce(row["steps"], {%{}, %{}}, fn [y, block, expected], {edits, index} ->
    position = {x, y, z}

    edits =
      if block == Chunk.base(y),
        do: Map.delete(edits, position),
        else: Map.put(edits, position, block)

    index = ColumnIndex.update(index, &Chunk.block_at(edits, &1), %{position => block})
    actual = ColumnIndex.heights(index, column).sky_source

    unless actual == max(-64, expected),
      do:
        raise("Native sky-source height differs: #{inspect({position, block, actual, expected})}")

    unless ColumnIndex.restore(edits, &Chunk.block_at(edits, &1)) == index,
      do: raise("Rebuilt sky/height columns differ from incremental observations")

    {edits, index}
  end)
end

IO.puts(
  "PASS: #{Enum.sum(Enum.map(rows, &length(&1["steps"])))} native sky-source height updates and complete sparse-index rebuilds. Empty source columns clamp to build minimum; no lateral lighting."
)
