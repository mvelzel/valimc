alias Valimc.Protocol.{Data, Wire}
alias Valimc.World.BlockBatch
[output] = System.argv()

cases =
  for {sx, sy, sz} <- [{0, 4, 0}, {-1, -4, -1}, {1_874_998, 19, -1_874_999}],
      state <- [0, 1, 127, 128, Data.block_state_count() - 1, :mixed] do
    edits =
      for x <- 0..15,
          y <- 0..15,
          z <- 0..15,
          into: %{},
          do:
            {{sx * 16 + x, sy * 16 + y, sz * 16 + z},
             if(state == :mixed,
               do: rem(x * 37 + y * 211 + z * 13, Data.block_state_count()),
               else: state
             )}

    {:ok, batch} = BlockBatch.prepare(edits, nil)
    [{_, frame}] = batch.frames
    {:ok, id, body, <<>>} = Wire.next_frame(frame, 2_097_152, nil)
    if id != Data.id(:play, :clientbound, "section_blocks_update"), do: raise("Wrong packet id")
    ordered = Enum.sort_by(edits, fn {{x, y, z}, _} -> {x, z, y} end)

    %{
      payload: Base.encode16(body, case: :lower),
      edits: Enum.map(ordered, fn {{x, y, z}, block} -> [x, y, z, block] end)
    }
  end

File.write!(output, JSON.encode!(cases))

IO.puts(
  "Prepared #{length(cases)} section packets / #{length(cases) * 4096} block updates for native verification."
)
