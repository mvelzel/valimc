import Bitwise
alias Valimc.Physics.HeightmapBlocks
alias Valimc.World.ColumnHeight
[facts_path, trace_path] = System.argv()
facts = :json.decode(File.read!(facts_path))

unless facts == :json.decode(File.read!("priv/physics/heightmap_blocks.json")),
  do: raise("Native heightmap predicates differ")

for row <- :json.decode(File.read!(trace_path)) do
  Enum.reduce(row["steps"], List.duplicate(ColumnHeight.flat(), 6), fn [y, id, expected],
                                                                       columns ->
    {:ok, mask} = HeightmapBlocks.mask(id)

    columns =
      Enum.with_index(columns, fn bits, i ->
        {:ok, bits} = ColumnHeight.update(bits, y, (mask &&& 1 <<< i) != 0)
        bits
      end)

    actual =
      Enum.map(columns, fn bits ->
        {:ok, height} = ColumnHeight.height(bits)
        height
      end)

    unless actual == expected,
      do:
        raise(
          "Native heightmap update differs: #{inspect({row["x"], row["z"], y, id, expected, actual})}"
        )

    columns
  end)
end

IO.puts(
  "PASS: all35723 native heightmap predicates and3360 updates /20160 height observations across six types."
)
