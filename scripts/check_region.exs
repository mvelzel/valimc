# VMC-021a: ValiMC reads every slot of every region file as vanilla's RegionFile
# does (RegionOracle): the same chunks (by canonical digest), the same read
# errors and the same missing or dropped slots, for deflate and LZ4 worlds,
# external chunks and damaged files.
Code.require_file("nbt_canon.exs", __DIR__)
alias Valimc.Storage.Anvil.RegionFile
alias Valimc.Data.NBT

[facts_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

totals =
  Enum.reduce(facts["files"], %{chunks: 0, errors: 0, files: 0}, fn row, totals ->
    path = row["path"]
    {:ok, region} = RegionFile.coords(path)
    bytes = File.read!(path)
    where = {Path.dirname(path), region}

    ours =
      for {index, _, _, _} = slot <- RegionFile.slots(bytes),
          verdict =
            (case RegionFile.chunk(bytes, slot, where) do
               :absent ->
                 nil

               {:error, _} ->
                 "error"

               {:ok, nbt} ->
                 case NBT.read(nbt) do
                   {:ok, tag} -> NbtCanon.digest(tag)
                   {:error, _} -> "error"
                 end
             end),
          verdict != nil,
          into: %{},
          do: {Integer.to_string(index), verdict}

    unless ours == row["slots"] do
      differing =
        for key <- Enum.uniq(Map.keys(ours) ++ Map.keys(row["slots"])),
            ours[key] != row["slots"][key],
            do:
              {key, ours[key] && String.slice(ours[key], 0, 8),
               row["slots"][key] && String.slice(row["slots"][key], 0, 8)}

      raise "#{path}: slots differ from vanilla (index, ValiMC, vanilla): #{inspect(Enum.take(differing, 10))}"
    end

    errors = Enum.count(ours, fn {_, v} -> v == "error" end)

    %{
      totals
      | chunks: totals.chunks + map_size(ours) - errors,
        errors: totals.errors + errors,
        files: totals.files + 1
    }
  end)

IO.puts(
  "PASS: #{totals.files} region files read slot for slot as vanilla does: " <>
    "#{totals.chunks} chunks, #{totals.errors} read errors (deflate, LZ4, external and damaged files)"
)
