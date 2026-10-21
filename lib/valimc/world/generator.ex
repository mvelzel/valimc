defmodule Valimc.World.Generator do
  @moduledoc """
  A world's terrain generator (VMC-024d), recorded in its `world.json`: flat
  terrain for worlds without a generator entry (and imports), or vanilla's
  overworld terrain for a seed (`"generator": {"type": "vanilla", "seed": …}`).

  New worlds take the configured generator (`:generator`, `VALIMC_GENERATOR`,
  flat by default) and seed (`:seed`, `VALIMC_SEED`, random otherwise). A new
  vanilla world's spawn is vanilla's spawn search over its generated chunks
  (`Valimc.World.SpawnSearch`, VMC-027d).

  Regions of a vanilla world generate the chunks their log has no column image
  for when they load (`columns/2`), and persist them before serving them, so a
  chunk is generated once. New vanilla worlds are decorated (VMC-025d,
  `"features": true`): their regions take full chunks from their proto owner
  (`Valimc.Worldgen.Proto`) instead. Worlds generated before keep terrain
  only, so no chunk of theirs is decorated after it was sent.
  """
  alias Valimc.{Native, Worldgen}
  alias Valimc.Protocol.Data
  alias Valimc.World.Spawn

  @settings "minecraft:overworld"
  @biome_source "minecraft:overworld"
  # A batch is one native call of about 0.1 s; a region runs up to four at once.
  @batch 16
  @batches 4

  @doc """
  Create the configured world's metadata when it has none and remember its
  generator; call at start, before `Spawn.load!/0`.
  """
  def init! do
    base = Valimc.config(:world_path)

    with base when is_binary(base) <- base,
         false <- File.exists?(Spawn.path(base)),
         :vanilla <- Valimc.config(:generator) do
      seed = Valimc.config(:seed) || random_seed()
      :ok = create(base, seed)
    end

    :persistent_term.put({__MODULE__, :world}, of(base))
  end

  @doc "The configured world's generator (`init!/0`)."
  def current, do: :persistent_term.get({__MODULE__, :world}, :flat)

  @doc """
  What the client learns about a generator in its spawn information: the hashed
  seed (`BiomeManager.obfuscateSeed`: the first eight bytes of the SHA-256 of
  the seed, both little-endian; 0 for flat terrain) and whether the world is
  flat.
  """
  def client_info(:flat), do: {0, true}

  def client_info({:vanilla, seed}) do
    <<hashed::little-signed-64, _::binary>> = :crypto.hash(:sha256, <<seed::little-signed-64>>)
    {hashed, false}
  end

  @doc """
  Write `world.json` for a new vanilla world at `base` with `seed` and vanilla's
  world spawn (VMC-027d). Decorated unless `features: false` (terrain only, as
  worlds generated before VMC-025d); a decorated world's spawn search reads the
  full chunks its regions' first transactions make.
  """
  def create(base, seed, opts \\ []) when is_integer(seed) do
    features = Keyword.get(opts, :features, true)
    columns = if features, do: first_full_columns(seed), else: &columns/2
    {x, y, z} = Valimc.World.SpawnSearch.world_spawn({:vanilla, seed}, columns)
    File.mkdir_p!(base)
    generator = %{"type" => "vanilla", "seed" => seed}

    File.write(
      Spawn.path(base),
      JSON.encode!(%{
        "spawn" => [x, y, z],
        "yaw" => 0.0,
        "generator" => if(features, do: Map.put(generator, "features", true), else: generator)
      })
    )
  end

  # Full chunk images as region `key`'s transaction makes them when it is the
  # first one finalized: the 10 × 10 around it decorated Z outer, X inner over
  # terrain, memoized per region for one search. A player whose view starts
  # other regions first may race it.
  defp first_full_columns(seed) do
    {:ok, state} = worldgen(seed)
    proto = Valimc.Worldgen.Proto

    fn {:vanilla, ^seed}, chunks ->
      Map.new(chunks, fn chunk ->
        key = Valimc.World.region_key(chunk)

        images =
          case Process.get({__MODULE__, :first_full, seed, key}) do
            nil ->
              {:ok, terrain} =
                Native.worldgen_proto_terrain(state, @biome_source, proto.around(key, 2))

              images = Map.new(terrain, fn {x, z, image} -> {{x, z}, image} end)

              {:ok, {touched, _}} =
                Native.worldgen_proto_decorate(state, Map.values(images), proto.around(key, 1))

              images =
                Map.merge(images, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))

              own = Enum.map(proto.chunks_of(key), &images[&1])
              {:ok, full} = Native.worldgen_proto_full(state, own, protocol_biomes())
              images = Map.new(full, &{{&1.x, &1.z}, &1.image})
              Process.put({__MODULE__, :first_full, seed, key}, images)
              images

            images ->
              images
          end

        {chunk, Map.fetch!(images, chunk)}
      end)
    end
  end

  @doc "Whether the world at `base` decorates its generated chunks (VMC-025d)."
  def decorated?(nil), do: false

  def decorated?(base) do
    with {:ok, text} <- File.read(Spawn.path(base)),
         {:ok, %{"generator" => %{"type" => "vanilla", "features" => true}}} <- JSON.decode(text),
         do: true,
         else: (_ -> false)
  end

  @doc "The generator of the world at `base`: `:flat` or `{:vanilla, seed}`."
  def of(nil), do: :flat

  def of(base) do
    with {:ok, text} <- File.read(Spawn.path(base)),
         {:ok, %{"generator" => %{"type" => "vanilla", "seed" => seed}}} when is_integer(seed) <-
           JSON.decode(text) do
      {:vanilla, seed}
    else
      _ -> :flat
    end
  end

  @doc """
  Column images (`chunk => image`) of generated `chunks` of a vanilla world, in
  batches of #{@batch} generated at once on the seed's pool of states (VMC-071).
  """
  def columns({:vanilla, seed}, chunks) do
    chunks
    |> Enum.chunk_every(@batch)
    |> Task.async_stream(&generate(seed, &1),
      max_concurrency: @batches,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, generated}, acc ->
      Enum.reduce(generated, acc, fn {cx, cz, image, _heights}, acc ->
        Map.put(acc, {cx, cz}, image)
      end)
    end)
  end

  @doc "The spawn target's origin column `{x, z}` of `seed`, or nil (VMC-027d)."
  def spawn_origin(seed) do
    {:ok, state} = worldgen(seed)
    {:ok, origin} = Native.worldgen_spawn_origin(state)
    origin
  end

  defp generate(seed, chunks) do
    {:ok, state} = worldgen(seed)
    {:ok, generated} = Native.worldgen_columns(state, @biome_source, protocol_biomes(), chunks)
    generated
  end

  @doc """
  The worldgen state of `seed`, one per VM: noises and compiled functions are
  built once. The native state keeps a pool of per-call states (VMC-025d1), so
  concurrent generations of the seed run in parallel and any of them gives the
  same chunks.
  """
  def worldgen(seed) do
    case :persistent_term.get({__MODULE__, seed}, nil) do
      nil ->
        :global.trans({{__MODULE__, seed}, self()}, fn ->
          case :persistent_term.get({__MODULE__, seed}, nil) do
            nil ->
              {:ok, state} = Worldgen.new(seed, @settings)
              :persistent_term.put({__MODULE__, seed}, state)
              {:ok, state}

            state ->
              {:ok, state}
          end
        end)

      state ->
        {:ok, state}
    end
  end

  @doc "Protocol biome ids in the native registry's biome order."
  def protocol_biomes do
    case :persistent_term.get({__MODULE__, :biomes}, nil) do
      nil ->
        ids =
          Enum.map(Worldgen.biome_names(), &Data.registry_id("minecraft:worldgen/biome", &1))

        :persistent_term.put({__MODULE__, :biomes}, ids)
        ids

      ids ->
        ids
    end
  end

  defp random_seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end
end
