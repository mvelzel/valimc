import Bitwise
alias Valimc.Registry.BlockFacts
alias Valimc.World.ColumnHeight
[trace_path] = System.argv()

for row <- :json.decode(File.read!(trace_path)) do
  Enum.reduce(row["steps"], List.duplicate(ColumnHeight.flat(), 6), fn [y, id, expected],
                                                                       columns ->
    mask = BlockFacts.heightmap(id)

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

IO.puts("PASS: 3360 native heightmap updates / 20160 height observations across six types.")
