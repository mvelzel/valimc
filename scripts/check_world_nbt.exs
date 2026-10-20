# VMC-020: ValiMC decodes every vanilla world NBT payload to vanilla's value
# (canonical digest, see WorldNbtOracle), agrees with vanilla's verdict on edge
# cases, and writes its re-encodings for `WorldNbtOracle verify`.
alias Valimc.NBT
alias Valimc.World.Schema

[facts_path, out_dir] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()
File.mkdir_p!(out_dir)

unless facts["data_version"] == Valimc.Version.data_version(),
  do: raise("Vanilla data version #{facts["data_version"]} is not the pinned one")

# Vanilla accepts unpaired surrogates in modified UTF-8; ValiMC refuses them.
divergent = %{"lone_surrogate" => {:error, :invalid_nbt_utf}}

defmodule Canon do
  @ids %{
    byte: 1,
    short: 2,
    int: 3,
    long: 4,
    float: 5,
    double: 6,
    byte_array: 7,
    string: 8,
    list: 9,
    compound: 10,
    int_array: 11,
    long_array: 12
  }
  @widths %{byte_array: 1, int_array: 4, long_array: 8}

  def digest(tag),
    do: :crypto.hash(:sha256, canon(tag)) |> Base.encode16(case: :lower)

  def canon({type, value}), do: [@ids[type], payload(type, value)]

  defp payload(:byte, v), do: <<v::signed-8>>
  defp payload(:short, v), do: <<v::signed-16>>
  defp payload(:int, v), do: <<v::signed-32>>
  defp payload(:long, v), do: <<v::signed-64>>
  defp payload(type, v) when type in [:float, :double], do: v
  defp payload(:string, v), do: [<<byte_size(v)::32>>, v]

  defp payload(type, v) when is_map_key(@widths, type),
    do: [<<div(byte_size(v), @widths[type])::32>>, v]

  defp payload(:list, {type, values}) do
    elements =
      Enum.map(values, fn
        # Vanilla unwraps `{"": tag}` elements of a compound list on load.
        %{"" => inner} = value when type == :compound and map_size(value) == 1 -> canon(inner)
        value -> canon({type, value})
      end)

    [<<length(values)::32>>, elements]
  end

  defp payload(:compound, fields) do
    entries =
      for {name, tag} <- Enum.sort(fields), do: [<<byte_size(name)::32>>, name, canon(tag)]

    [<<map_size(fields)::32>>, entries]
  end
end

kinds =
  facts["files"]
  |> Enum.with_index()
  |> Enum.reduce(%{}, fn {row, index}, kinds ->
    raw = Base.decode16!(row["raw"], case: :lower)
    compression = String.to_existing_atom(row["compression"])

    tag =
      case NBT.read_compressed(raw, compression) do
        {:ok, tag} -> tag
        error -> raise "#{row["path"]} #{inspect(row["chunk"])}: #{inspect(error)}"
      end

    {:ok, inflated} = NBT.decompress(raw, compression, NBT.disk_limits().bytes)

    unless NBT.read_reference(inflated) == {:ok, tag},
      do: raise("#{row["path"]} #{inspect(row["chunk"])}: native and Elixir readers differ")

    unless Canon.digest(tag) == row["digest"],
      do: raise("#{row["path"]} #{inspect(row["chunk"])} decodes to a different value")

    kind = Schema.kind(row["path"])
    version = row["data_version"]

    unless Schema.check(kind, tag) == {:ok, version},
      do: raise("#{row["path"]}: schema #{inspect(kind)} #{inspect(Schema.check(kind, tag))}")

    File.write!(Path.join(out_dir, "file-#{index}.bin"), NBT.write_compressed(tag, compression))
    Map.update(kinds, kind, 1, &(&1 + 1))
  end)

for {row, index} <- Enum.with_index(facts["cases"]) do
  raw = Base.decode16!(row["raw"], case: :lower)
  framing = row["framing"]

  result =
    if framing == "disk",
      do: NBT.read(raw),
      else: NBT.decode(raw, %{NBT.network_limits() | depth: 512, bytes: 1_048_576})

  case {divergent[row["name"]], result, row["accept"]} do
    {nil, {:ok, tag}, true} ->
      unless Canon.digest(tag) == row["digest"], do: raise("#{row["name"]} decodes differently")

      bytes =
        if framing == "disk",
          do: NBT.write(tag),
          else: NBT.encode(tag, %{NBT.disk_limits() | duplicates: :refuse})

      File.write!(Path.join(out_dir, "case-#{index}.bin"), bytes)

    {nil, {:error, _}, false} ->
      :ok

    {expected, result, _} when expected != nil and expected == result ->
      :ok

    other ->
      raise "#{row["name"]}: ValiMC and vanilla disagree: #{inspect(other)}"
  end
end

IO.puts(
  "PASS: #{length(facts["files"])} vanilla world NBT payloads #{inspect(kinds)} decode to vanilla's values (native and Elixir readers agree) " <>
    "with their data version; #{length(facts["cases"])} edge cases match vanilla's verdict (#{map_size(divergent)} documented divergence)"
)
