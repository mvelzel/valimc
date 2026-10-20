# VMC-070: `Valimc.Session.ChunkView` tracks the chunks vanilla's
# `ChunkTrackingView` tracks, and a view change enters and leaves the same chunks
# (ChunkViewOracle facts).
alias Valimc.Session.ChunkView

[facts_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

pairs = fn flat -> flat |> Enum.chunk_every(2) |> Enum.map(fn [x, z] -> {x, z} end) end
view = fn
  nil -> nil
  %{"x" => x, "z" => z, "distance" => distance} -> {{x, z}, distance}
end

for %{"chunks" => chunks} = facts <- facts["views"] do
  expected = pairs.(chunks)
  actual = ChunkView.chunks(view.(facts))

  if length(actual) != length(expected) or MapSet.new(actual) != MapSet.new(expected),
    do: raise("view #{inspect(view.(facts))}: #{length(actual)} chunks, vanilla #{length(expected)}")
end

for %{"from" => from, "to" => to, "entering" => entering, "leaving" => leaving} <-
      facts["differences"] do
  {actual_entering, actual_leaving} = ChunkView.difference(view.(from), view.(to))

  if MapSet.new(actual_entering) != MapSet.new(pairs.(entering)) or
       MapSet.new(actual_leaving) != MapSet.new(pairs.(leaving)) or
       length(actual_entering) != div(length(entering), 2) or
       length(actual_leaving) != div(length(leaving), 2),
     do: raise("change #{inspect(view.(from))} -> #{inspect(view.(to))} differs from vanilla")
end

counts = Enum.map_join(facts["views"], ", ", &"#{&1["distance"]}: #{div(length(&1["chunks"]), 2)}")

IO.puts(
  "PASS: #{length(facts["views"])} views and #{length(facts["differences"])} view changes equal vanilla's " <>
    "(chunks per distance #{counts})"
)
