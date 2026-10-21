defmodule Valimc.World.Generator do
  @moduledoc """
  A world's terrain generator (VMC-024d), recorded in its `world.json`: flat
  terrain for worlds without a generator entry (and imports), or vanilla's
  overworld terrain for a seed (`"generator": {"type": "vanilla", "seed": …}`).

  New worlds take the configured generator (`:generator`, `VALIMC_GENERATOR`,
  flat by default) and seed (`:seed`, `VALIMC_SEED`, random otherwise). A new
  vanilla world's spawn is vanilla's spawn search over its generated chunks
  (`Valimc.World.SpawnSearch`, VMC-027d). Its `world.json` also keeps vanilla's
  generation settings (`settings`, `Valimc.World.GenSettings`, VMC-028a) from
  `server.properties`' equivalents: the level type (`:level_type`,
  `VALIMC_LEVEL_TYPE`), generator settings (`:generator_settings`,
  `VALIMC_GENERATOR_SETTINGS`) and `:generate_structures`
  (`VALIMC_GENERATE_STRUCTURES`). An imported world records the settings of its
  `world_gen_settings.dat` (`"type": "imported"`) and keeps flat terrain outside
  its imported chunks.

  Regions of a vanilla world generate the chunks their log has no column image
  for when they load (`columns/2`), and persist them before serving them, so a
  chunk is generated once. New vanilla worlds are decorated (VMC-025d,
  `"features": true`): their regions take full chunks from their proto owner
  (`Valimc.Worldgen.Proto`) instead. Worlds generated before keep terrain
  only, so no chunk of theirs is decorated after it was sent.
  """
  alias Valimc.{Native, Worldgen}
  alias Valimc.Protocol.Data
  alias Valimc.World.{GenSettings, Spawn}

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

      case create(base, seed,
             level_type: Valimc.config(:level_type),
             generator_settings: Valimc.config(:generator_settings),
             structures: Valimc.config(:generate_structures)
           ) do
        :ok -> :ok
        {:error, reason} -> raise "Cannot create the world: #{inspect(reason)}"
      end
    end

    generator = of(base)
    # The packs' facts once: region loads and proto owners read them per region.
    :persistent_term.put({__MODULE__, :facts}, {base, Valimc.World.Datapacks.facts(base)})

    with {:vanilla, _} <- generator,
         {:error, reason} <- spec(base),
         do: raise("Cannot generate the world at #{base}: #{inspect(reason)}")

    :persistent_term.put({__MODULE__, :world}, generator)
    :persistent_term.put({__MODULE__, :settings}, recorded(base))
  end

  @doc "The configured world's generator (`init!/0`)."
  def current, do: :persistent_term.get({__MODULE__, :world}, :flat)

  @doc """
  The configured world's recorded generation settings (`init!/0`): a vanilla
  world's or an imported one's, nil for ValiMC's flat profile.
  """
  def current_settings, do: :persistent_term.get({__MODULE__, :settings}, nil)

  @doc """
  What the client learns about the configured world in its spawn information
  (`client_info/2`).
  """
  def client_info, do: client_info(current(), current_settings())

  @doc """
  What the client learns about a generator in its spawn information: the hashed
  seed (`BiomeManager.obfuscateSeed`: the first eight bytes of the SHA-256 of
  the seed, both little-endian) and whether the overworld is flat. ValiMC's flat
  profile has no seed (0); an imported world has its settings' seed.
  """
  def client_info(generator, settings \\ nil)

  def client_info(:flat, nil), do: {0, true}

  def client_info({:vanilla, seed}, nil), do: {hashed(seed), false}

  def client_info(_generator, %{"seed" => seed} = settings),
    do: {hashed(seed), GenSettings.overworld(settings)["type"] == "minecraft:flat"}

  defp hashed(seed) do
    <<hashed::little-signed-64, _::binary>> = :crypto.hash(:sha256, <<seed::little-signed-64>>)
    hashed
  end

  @doc """
  Write `world.json` for a new vanilla world at `base` with `seed` and vanilla's
  world spawn (VMC-027d). Decorated unless `features: false` (terrain only, as
  worlds generated before VMC-025d); a decorated world's spawn search reads the
  full chunks its regions' first transactions make.
  """
  def create(base, seed, opts \\ []) when is_integer(seed) do
    with {:ok, facts} <- Valimc.World.Datapacks.facts(base),
         settings =
           GenSettings.create(
             Keyword.get(opts, :level_type),
             Keyword.get(opts, :generator_settings),
             seed,
             Keyword.get(opts, :structures, true),
             GenSettings.presets(facts)
           ),
         {:ok, spec} <- spec_of(settings, facts) do
      # Flat worlds are not decorated (their features and lakes are off).
      features = Keyword.get(opts, :features, true) and spec.kind == :noise
      columns = if features, do: first_full_columns(spec), else: &columns/2

      {x, y, z} =
        Valimc.World.SpawnSearch.world_spawn(spec, columns,
          origin: spawn_chunk(spec),
          height: spawn_height(spec)
        )

      File.mkdir_p!(base)
      generator = %{"type" => "vanilla", "seed" => seed, "settings" => settings}
      write_metadata(base, {x, y, z}, generator, features)
    end
  end

  # `ChunkGenerator.getOrigin`: a noise generator's spawn target, else chunk
  # (0, 0); `getSpawnHeight`: 64 for noise, the bottom plus the flat layers.
  defp spawn_chunk(%{kind: :noise} = spec) do
    case spawn_origin(spec.seed, spec.noise_settings, spec.facts) do
      {x, z} -> {Bitwise.bsr(x, 4), Bitwise.bsr(z, 4)}
      nil -> {0, 0}
    end
  end

  defp spawn_chunk(_), do: {0, 0}

  defp spawn_height(%{kind: :noise}), do: 64
  defp spawn_height(%{kind: :flat, height: height}), do: -64 + min(height, 384)

  @noise_settings ~w(minecraft:overworld minecraft:large_biomes minecraft:amplified)

  @doc """
  What generation needs for the world at `base` (VMC-028b): `:flat` for
  ValiMC's flat profile and imports, else `{:ok, spec}` (`spec_of/1`) or why
  ValiMC cannot generate it.
  """
  def spec(base) do
    case of(base) do
      :flat ->
        :flat

      {:vanilla, seed} ->
        with {:ok, facts} <- facts(base),
             do: spec_of(recorded(base) || GenSettings.legacy({:vanilla, seed}), facts)
    end
  end

  # The configured world's pack facts as `init!/0` found them; any other
  # world's (tests, tools) read now.
  defp facts(base) do
    case :persistent_term.get({__MODULE__, :facts}, nil) do
      {^base, facts} -> facts
      _ -> Valimc.World.Datapacks.facts(base)
    end
  end

  @doc """
  The overworld generation of `settings`: a noise generator over the overworld,
  large biomes or amplified noise settings and the overworld preset's or a
  fixed biome (`%{kind: :noise, seed, noise_settings, biome_source}`, the biome
  source as the native worldgen names it: `minecraft:overworld` or
  `fixed:BIOME`), or a flat one without features or lakes (`%{kind: :flat,
  seed, layers, height, biome}`: the states from the bottom up and the
  biome's protocol id). Anything else is `{:error, reason}`.
  """
  def spec_of(%{"seed" => seed} = settings, facts \\ nil) do
    case GenSettings.overworld(settings) do
      %{"type" => "minecraft:noise", "settings" => noise, "biome_source" => source}
      when noise in @noise_settings ->
        case source do
          %{"type" => "minecraft:multi_noise", "preset" => "minecraft:overworld"} ->
            {:ok,
             %{
               kind: :noise,
               seed: seed,
               noise_settings: noise,
               biome_source: "minecraft:overworld",
               facts: facts
             }}

          %{"type" => "minecraft:fixed", "biome" => biome} ->
            if biome in Worldgen.biome_names(),
              do:
                {:ok,
                 %{
                   kind: :noise,
                   seed: seed,
                   noise_settings: noise,
                   biome_source: "fixed:" <> biome,
                   facts: facts
                 }},
              else: {:error, {:unknown_biome, biome}}

          other ->
            {:error, {:unsupported_biome_source, other}}
        end

      %{"type" => "minecraft:flat", "settings" => %{"features" => false, "lakes" => false} = flat} ->
        flat_spec(seed, flat)

      %{"type" => "minecraft:flat"} ->
        {:error, {:unsupported_generator, :flat_features_or_lakes}}

      other ->
        {:error, {:unsupported_generator, other}}
    end
  end

  defp flat_spec(seed, %{"layers" => layers, "biome" => biome}) do
    states =
      for %{"block" => "minecraft:" <> name, "height" => height} <- layers,
          _ <- 1..height//1,
          do: Valimc.Registry.Blocks.default_state(name)

    air = Valimc.Registry.Blocks.default_state("air")
    column = states |> Enum.take(384) |> then(&(&1 ++ List.duplicate(air, 384 - length(&1))))

    {:ok,
     %{
       kind: :flat,
       seed: seed,
       layers: for(state <- column, into: <<>>, do: <<state::16>>),
       height: length(states),
       biome: Data.registry_id("minecraft:worldgen/biome", biome)
     }}
  end

  defp write_metadata(base, {x, y, z}, generator, features) do
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
  defp first_full_columns(%{kind: :noise} = spec) do
    {:ok, state} = worldgen(spec.seed, spec.noise_settings, spec.facts)
    source = spec.biome_source
    proto = Valimc.Worldgen.Proto

    fn ^spec, chunks ->
      Map.new(chunks, fn chunk ->
        key = Valimc.World.region_key(chunk)

        images =
          case Process.get({__MODULE__, :first_full, spec, key}) do
            nil ->
              {:ok, terrain} =
                Native.worldgen_proto_terrain(state, source, proto.around(key, 2))

              images = Map.new(terrain, fn {x, z, image} -> {{x, z}, image} end)

              {:ok, {touched, _}} =
                Native.worldgen_proto_decorate(
                  state,
                  source,
                  Map.values(images),
                  proto.around(key, 1)
                )

              images =
                Map.merge(images, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))

              own = Enum.map(proto.chunks_of(key), &images[&1])
              {:ok, full} = Native.worldgen_proto_full(state, own, protocol_biomes())
              images = Map.new(full, &{{&1.x, &1.z}, &1.image})
              Process.put({__MODULE__, :first_full, spec, key}, images)
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

  @doc """
  The generation settings `world.json` records for the world at `base`: its
  own, those of an older vanilla world (the normal preset), or nil (ValiMC's
  flat profile; an import whose settings ValiMC could not read).
  """
  def recorded(nil), do: nil

  def recorded(base) do
    with {:ok, text} <- File.read(Spawn.path(base)),
         {:ok, %{"generator" => %{"type" => type} = generator}} <- JSON.decode(text) do
      case {type, generator} do
        {_, %{"settings" => %{} = settings}} ->
          settings

        {"vanilla", %{"seed" => seed}} when is_integer(seed) ->
          GenSettings.legacy({:vanilla, seed})

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Record an imported world's generation settings in its `world.json`: those of
  `world_gen_settings.dat` (`root`, nil without one), or why ValiMC cannot read
  them. Imported worlds keep flat terrain outside their imported chunks.
  """
  def record_import(base, root) do
    generator =
      case root && GenSettings.from_nbt(root) do
        nil ->
          nil

        {:ok, %{"seed" => seed} = settings} ->
          %{"type" => "imported", "seed" => seed, "settings" => settings}

        {:error, reason} ->
          %{"type" => "imported", "unreadable" => inspect(reason)}
      end

    with {:ok, text} <- File.read(Spawn.path(base)),
         {:ok, meta} <- JSON.decode(text) do
      meta = if generator, do: Map.put(meta, "generator", generator), else: meta
      File.write(Spawn.path(base), JSON.encode!(meta))
    end
  end

  @doc """
  The settings to export for the world at `base`: recorded ones, else those
  of ValiMC's flat profile.
  """
  def settings(base), do: recorded(base) || GenSettings.legacy(:flat)

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
  Column images (`chunk => image`) of generated `chunks` of a vanilla world
  (a `spec_of/1` spec, or `{:vanilla, seed}` for the normal preset): noise
  terrain in batches of #{@batch} generated at once on the seed's pool of
  states (VMC-071), or a flat world's layers.
  """
  def columns({:vanilla, seed}, chunks),
    do:
      columns(
        %{
          kind: :noise,
          seed: seed,
          noise_settings: @settings,
          biome_source: @biome_source,
          facts: nil
        },
        chunks
      )

  def columns(%{kind: :flat, layers: layers, biome: biome}, chunks) do
    {:ok, image} = Native.column_layers_image(layers, biome)
    Map.new(chunks, &{&1, image})
  end

  def columns(%{kind: :noise} = spec, chunks) do
    chunks
    |> Enum.chunk_every(@batch)
    |> Task.async_stream(&generate(spec, &1),
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
  def spawn_origin(seed, noise_settings \\ @settings, facts \\ nil) do
    {:ok, state} = worldgen(seed, noise_settings, facts)
    {:ok, origin} = Native.worldgen_spawn_origin(state)
    origin
  end

  defp generate(spec, chunks) do
    {:ok, state} = worldgen(spec.seed, spec.noise_settings, spec.facts)

    {:ok, generated} =
      Native.worldgen_columns(state, spec.biome_source, protocol_biomes(), chunks)

    generated
  end

  @doc """
  The worldgen state of `seed` and noise settings, one per VM: noises and
  compiled functions are built once. The native state keeps a pool of per-call
  states (VMC-025d1), so concurrent generations of the seed run in parallel and
  any of them gives the same chunks.
  """
  def worldgen(seed, noise_settings \\ @settings, facts \\ nil) do
    key =
      if noise_settings == @settings and facts == nil,
        do: {__MODULE__, seed},
        else: {__MODULE__, seed, noise_settings, facts}

    case :persistent_term.get(key, nil) do
      nil ->
        :global.trans({key, self()}, fn ->
          case :persistent_term.get(key, nil) do
            nil ->
              with {:ok, state} <- Worldgen.new(seed, noise_settings, facts) do
                :persistent_term.put(key, state)
                {:ok, state}
              end

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
