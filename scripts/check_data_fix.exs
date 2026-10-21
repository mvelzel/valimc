# VMC-028d: ValiMC upgrades every older chunk exactly as vanilla's fixer does
# (DataFixOracle: the 26.2 world older_world.exs made, and a case for each fix),
# the upgraded region chunks hold the blocks and biomes of the 26.3 chunks they
# were made from, and the 26.2 world imports as the 26.3 world does.
[upgrade_path, content_path, older, out] = System.argv()
Code.require_file("nbt_canon.exs", __DIR__)
alias Valimc.Anvil.{Chunk, Import, RegionFile}
alias Valimc.NBT
alias Valimc.World.DataFix

Valimc.Protocol.Data.load!()
Valimc.World.Blocks.init!()
Valimc.World.Light.init!()

defmodule Diff do
  # The first path where two tags differ, with both values.
  def first(same, same, _path), do: nil

  def first({:compound, a}, {:compound, b}, path) do
    keys = Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b)))
    Enum.find_value(keys, &first(a[&1], b[&1], path ++ [&1]))
  end

  def first({:list, {_, a}} = x, {:list, {_, b}} = y, path) when length(a) == length(b) do
    if canon(x) == canon(y),
      do: nil,
      else:
        Enum.find_value(Enum.with_index(Enum.zip(elements(x), elements(y))), fn {{p, q}, i} ->
          first(p, q, path ++ [i])
        end)
  end

  def first(a, b, path) do
    if canon(a) == canon(b),
      do: nil,
      else: {Enum.join(Enum.map(path, &to_string/1), "/"), short(a), short(b)}
  end

  def canon(nil), do: nil
  def canon(tag), do: IO.iodata_to_binary(NbtCanon.canon(tag))

  defp elements({:list, {type, values}}) do
    Enum.map(values, fn
      %{"" => tag} = wrapped when map_size(wrapped) == 1 and type == :compound -> tag
      value -> {type, value}
    end)
  end

  defp short(tag), do: tag |> inspect(limit: 8, printable_limit: 80) |> String.slice(0, 300)
end

facts = upgrade_path |> File.read!() |> JSON.decode!()
read = &(&1 |> Base.decode64!() |> NBT.read() |> elem(1))

{failures, upgraded} =
  Enum.reduce(facts["cases"], {[], %{}}, fn entry, {failures, upgraded} ->
    kind = if entry["kind"] == "chunk", do: :chunk, else: :entities
    want = read.(entry["expected"])
    {:ok, got} = DataFix.upgrade(kind, read.(entry["input"]))

    failures =
      case Diff.first(got, want, []) do
        nil -> failures
        diff -> [{entry["name"], entry["version"], diff} | failures]
      end

    {failures, Map.put(upgraded, entry["name"], got)}
  end)

for {name, version, {path, ours, vanilla}} <- Enum.take(Enum.reverse(failures), 10) do
  IO.puts("#{name} (#{version}) differs at #{path}:\n  ValiMC:  #{ours}\n  vanilla: #{vanilla}")
end

unless failures == [],
  do: raise("#{length(failures)} of #{length(facts["cases"])} upgrades differ from vanilla's")

# The 26.3 chunks the 26.2 world was made from: same sections after the upgrade.
content = content_path |> File.read!() |> JSON.decode!()
regions = Path.join(content["world"], "dimensions/minecraft/overworld/region")

compared =
  for path <- Path.wildcard(Path.join(regions, "r.*.mca")),
      {:ok, chunks} = RegionFile.chunks(path),
      {{x, z}, {:ok, bytes}} <- chunks,
      {:ok, original} = NBT.read(bytes),
      {{:ok, %{sections: want}}, _} <- [Chunk.column(original)],
      reduce: 0 do
    count ->
      {{:ok, %{sections: got}}, _} = Chunk.column(Map.fetch!(upgraded, "region #{x} #{z}"))
      if got != want, do: raise("chunk #{x}, #{z}: its sections differ after the upgrade")
      count + 1
  end

File.rm_rf!(out)
{:ok, new} = Import.run(content["world"], Path.join(out, "from-26.3"))
{:ok, old} = Import.run(older, Path.join(out, "from-26.2"))

for field <- [:regions, :chunks, :contents, :skipped, :error_count, :spawn] do
  unless Map.fetch!(old, field) == Map.fetch!(new, field),
    do:
      raise(
        "the 26.2 world imports #{field} #{inspect(Map.fetch!(old, field))}, the 26.3 world #{inspect(Map.fetch!(new, field))}"
      )
end

if old.error_count != 0, do: raise("import errors: #{inspect(old.errors)}")

IO.puts(
  "PASS: #{length(facts["cases"])} chunks upgraded as vanilla upgrades them; " <>
    "#{compared} full chunks keep their sections; the 26.2 world imports #{old.chunks} chunks " <>
    "with #{inspect(old.contents)} as the 26.3 world does"
)
