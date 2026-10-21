import Bitwise
alias Valimc.Registry.BlockFacts
alias Valimc.World.Chunk
[trace_path] = System.argv()

# One above the column's top state whose mask has `bit`, else the bottom.
height = fn edits, bit ->
  Enum.find_value(Chunk.max_y()..Chunk.min_y()//-1, Chunk.min_y(), fn y ->
    mask = BlockFacts.heightmap(Map.get_lazy(edits, y, fn -> Chunk.base(y) end))
    if (mask &&& 1 <<< bit) != 0, do: y + 1
  end)
end

for row <- :json.decode(File.read!(trace_path)) do
  Enum.reduce(row["steps"], %{}, fn [y, id, expected], edits ->
    edits = Map.put(edits, y, id)
    actual = Enum.map(0..5, &height.(edits, &1))

    unless actual == expected,
      do:
        raise(
          "Native heightmap differs: #{inspect({row["x"], row["z"], y, id, expected, actual})}"
        )

    edits
  end)
end

IO.puts("PASS: 3360 native heightmap edits / 20160 column height observations across six types.")
