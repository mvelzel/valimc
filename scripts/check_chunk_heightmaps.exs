alias Valimc.World.Chunk
[trace_path, output] = System.argv()
Chunk.load!()
columns = :json.decode(File.read!(trace_path))

{_, _, rows} =
  Enum.reduce(0..104, {%{}, Map.new(0..255, &{&1, [128, 128]}), []}, fn step,
                                                                        {edits, expected, rows} ->
    {edits, expected} =
      Enum.reduce(columns, {edits, expected}, fn row, {edits, expected} ->
        [y, block, heights] = Enum.at(row["steps"], step)
        position = {row["x"], y, row["z"]}

        edits =
          if block == Chunk.base(y),
            do: Map.delete(edits, position),
            else: Map.put(edits, position, block)

        expected =
          Map.put(expected, row["x"] + row["z"] * 16, [
            Enum.at(heights, 1) + 64,
            Enum.at(heights, 4) + 64
          ])

        {edits, expected}
      end)

    if step in [0, 1, 2, 3, 4, 8, 16, 32, 64, 96, 104] do
      {_id, body} = Chunk.encode({0, 0}, edits)

      row = %{
        wire: Base.encode16(IO.iodata_to_binary(body), case: :lower),
        expected: Enum.map(0..255, &Map.fetch!(expected, &1))
      }

      {edits, expected, [row | rows]}
    else
      {edits, expected, rows}
    end
  end)

File.write!(output, :json.encode(Enum.reverse(rows)))

IO.puts(
  "PASS: #{length(rows)} encoded chunk fixtures retain independent native surface/motion expectations; Mojang decode follows."
)
