defmodule Valimc.World.Datapacks do
  @moduledoc """
  A world's data packs and the worldgen facts they give (VMC-028c).

  The packs are the folders and zips in `WORLD/datapacks`, applied after
  vanilla's in name order. Their worldgen comes from the same fact extraction
  that gives `priv/worldgen`, run with the packs (`mix valimc.worldgen_packs
  WORLD`, which needs the research toolchain), into `WORLD/worldgen/DIGEST/`:
  the digest covers the pinned server and every file of every pack, so the
  facts follow the packs exactly and stay cached until they change. The server
  never runs that extraction: a world whose packs have no facts, or whose facts
  ValiMC cannot generate, is refused with the reason.

  What a pack may not change: the biomes (clients know vanilla's registry only).
  """
  # 2: structure templates carry their palettes (VMC-025f).
  @facts_version 2

  @doc "The world's data packs (paths), in the order they apply."
  def packs(nil), do: []

  def packs(base) do
    dir = Path.join(base, "datapacks")

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            path = Path.join(dir, name),
            File.dir?(path) or String.ends_with?(name, ".zip"),
            do: path

      _ ->
        []
    end
  end

  @doc """
  The digest of the world's packs (nil without packs): the pinned server, this
  extraction's version, and each pack's name and files (paths and bytes).
  """
  def digest(base) do
    case packs(base) do
      [] ->
        nil

      packs ->
        hash =
          Enum.reduce(packs, :crypto.hash_init(:sha256), fn pack, acc ->
            acc = :crypto.hash_update(acc, ["pack\0", Path.basename(pack), "\0"])

            Enum.reduce(files(pack), acc, fn {path, bytes}, acc ->
              :crypto.hash_update(acc, [path, "\0", <<byte_size(bytes)::64>>, bytes])
            end)
          end)
          |> :crypto.hash_update(["#{@facts_version}\0", Valimc.Version.server_sha1()])
          |> :crypto.hash_final()

        Base.encode16(hash, case: :lower)
    end
  end

  # A pack's files, sorted by path: a folder's, or a zip's entries.
  defp files(pack) do
    if File.dir?(pack) do
      pack
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, pack), File.read!(&1)})
    else
      {:ok, entries} = :zip.unzip(String.to_charlist(pack), [:memory])
      entries |> Enum.map(fn {name, bytes} -> {to_string(name), bytes} end) |> Enum.sort()
    end
  end

  @doc """
  The facts directory for the world's packs: `{:ok, nil}` without packs,
  `{:ok, dir}` when the extraction ran for exactly these packs, else
  `{:error, reason}`.
  """
  def facts(base) do
    case digest(base) do
      nil ->
        {:ok, nil}

      digest ->
        dir = Path.join([base, "worldgen", digest])

        with {:ok, text} <- File.read(Path.join(dir, "packs.json")),
             {:ok, %{"digest" => ^digest}} <- JSON.decode(text),
             :ok <- same_biomes(dir) do
          {:ok, dir}
        else
          {:error, :enoent} ->
            {:error, {:datapack_facts_missing, "run mix valimc.worldgen_packs #{base}"}}

          {:error, _} = error ->
            error

          _ ->
            {:error, {:datapack_facts_invalid, dir}}
        end
    end
  end

  defp same_biomes(dir) do
    ours =
      dir
      |> Path.join("biomes.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.keys()
      |> Enum.sort()

    if ours == Valimc.Worldgen.biome_names(),
      do: :ok,
      else: {:error, {:unsupported_datapack, :biomes_added_or_removed}}
  end

  @doc """
  Unpack the world's packs as folders under `into` (zips unzipped), for the
  fact oracles; returns their paths in order.
  """
  def unpack(base, into) do
    for {pack, index} <- Enum.with_index(packs(base)) do
      if File.dir?(pack) do
        pack
      else
        target = Path.join(into, "#{index}-#{Path.basename(pack, ".zip")}")
        File.mkdir_p!(target)
        {:ok, _} = :zip.unzip(String.to_charlist(pack), cwd: String.to_charlist(target))
        target
      end
    end
  end

  @doc false
  def facts_version, do: @facts_version
end
