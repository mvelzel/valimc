# World NBT codec cost (VMC-020) on the golden vanilla chunks.
#
#   python3 scripts/java_tool.py WorldNbtOracle generate <dir> <dir>/world-nbt.json
#   MIX_ENV=prod mix run --no-start bench/world_nbt.exs <dir>/world-nbt.json [results.json]
#
# Per region chunk (zlib, as vanilla stores them): inflate, decode (native and
# the Elixir reference), encode and deflate times, with p50/p95 over 20 passes
# after 3 warmups, and the whole-set throughput. Each phase runs in a fresh
# process holding only that phase's inputs, one at a time, like one importer.
alias Valimc.NBT

[facts_path | rest] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

chunks =
  for row <- facts["files"], row["kind"] == "region" do
    raw = Base.decode16!(row["raw"], case: :lower)
    {:ok, inflated} = NBT.decompress(raw, :zlib, 64 * 1024 * 1024)
    {:ok, tag} = NBT.read(inflated)
    %{raw: raw, inflated: inflated, tag: tag, encoded: IO.iodata_to_binary(NBT.write(tag))}
  end

time = fn fun ->
  {micros, _} = :timer.tc(fun)
  micros
end

# Each phase gets only its own inputs, so its heap holds what an importer's would.
phases = %{
  inflate: {:raw, &NBT.decompress(&1, :zlib, 64 * 1024 * 1024)},
  decode: {:inflated, &NBT.read/1},
  decode_reference: {:inflated, &NBT.read_reference/1},
  encode: {:tag, &IO.iodata_to_binary(NBT.write(&1))},
  deflate: {:encoded, &NBT.compress(&1, :zlib)}
}

results =
  for {name, {input, phase}} <- phases, into: %{} do
    inputs = Enum.map(chunks, &Map.fetch!(&1, input))

    Task.async(fn ->
      chunks = inputs
      for _ <- 1..3, chunk <- chunks, do: phase.(chunk)

      samples =
        for _ <- 1..20, chunk <- chunks do
          time.(fn -> phase.(chunk) end)
        end
        |> Enum.sort()

      total = Enum.sum(samples) / 20
      pick = fn q -> Enum.at(samples, min(length(samples) - 1, floor(q * length(samples)))) end

      {name,
       %{
         p50_us: pick.(0.5),
         p95_us: pick.(0.95),
         max_us: List.last(samples),
         chunks_per_second: round(length(chunks) / (total / 1_000_000))
       }}
    end)
    |> Task.await(:infinity)
  end

sizes = Enum.map(chunks, &byte_size(&1.inflated)) |> Enum.sort()

summary = %{
  chunks: length(chunks),
  inflated_bytes_p50: Enum.at(sizes, div(length(sizes), 2)),
  inflated_bytes_max: List.last(sizes),
  otp: System.otp_release(),
  schedulers: System.schedulers_online(),
  phases: results
}

IO.puts(JSON.encode!(summary))
with [out] <- rest, do: File.write!(out, JSON.encode!(summary))
