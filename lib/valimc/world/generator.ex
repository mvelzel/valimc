defmodule Valimc.World.Generator do
  @moduledoc """
  A world's terrain generator (VMC-024d), recorded once in its `world.json`
  and read once (`Valimc.World.Spec`): ValiMC's flat profile, imports, or
  vanilla's overworld terrain for a seed (`"generator": {"type": "vanilla",
  "seed": …}`).

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
  for when a view or a reader wants them, nearest first (`columns/2`,
  `Valimc.World.RegionGeneration`, VMC-075), and persist them before serving
  them, so a chunk is generated once. New vanilla worlds are decorated
  (VMC-025d, `"features": true`): their regions take full chunks from their
  proto owner (`Valimc.Worldgen.Proto`) instead. Worlds generated before keep
  terrain only, so no chunk of theirs is decorated after it was sent.

  The Nether and the End (VMC-026b) generate as vanilla's presets keep them in
  every world type: noise terrain of the world's seed (ValiMC's flat profile
  has none: the configured seed, else 0) with the dimension's noise settings
  and biome source and the world's data packs (`spec/2`), decorated unless the
  world is a noise world generated before decoration.
  """
  alias Valimc.{Native, Worldgen}
  alias Valimc.Protocol.Data
  alias Valimc.World.{GenSettings, Settings, Spec}

  @settings "minecraft:overworld"
  @biome_source "minecraft:overworld"
  # A batch is one native call of about 0.1 s; a region runs up to four at once.
  @batch 16
  @batches 4

  @doc """
  Create the configured world's metadata when it has none, then load its spec
  (`Spec.load!/0`, fatal when it does not read); call at start.
  """
  def init! do
    base = Valimc.config(:world_path)

    with base when is_binary(base) <- base,
         false <- File.exists?(Spec.path(base)),
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

    Spec.load!()
  end

  @doc "The configured world's overworld spawn information (`Spec.client_info/2`)."
  def client_info, do: Spec.client_info(Spec.current(), :overworld)

  @doc """
  Write `world.json` for a new vanilla world at `base` with `seed`, and its
  `settings.json` with vanilla's world spawn (VMC-027d). Decorated unless `features: false` (terrain only, as
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

      generator = %{"type" => "vanilla", "seed" => seed, "settings" => settings}
      generator = if features, do: Map.put(generator, "features", true), else: generator
      spawn = %{dimension: :overworld, position: {x, y, z}, yaw: 0.0, pitch: 0.0}

      with :ok <- Settings.write(base, %{spawn: spawn}), do: Spec.write(base, generator)
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
  The Nether's or the End's generator as the world's `recorded` settings name
  it (VMC-028a's `dimensions.<id>.generator`), else its dimension type's
  defaults: `{:ok, noise_settings, biome_source}` with a multi-noise preset, the
  End's or a fixed biome as the native worldgen names it.
  """
  def dimension_generator(recorded, dimension) do
    id = Valimc.Dimension.name(dimension)
    %{noise_settings: settings, biome_source: source} = Valimc.Dimension.facts(dimension)

    case recorded && get_in(recorded, ["dimensions", id, "generator"]) do
      nil ->
        {:ok, settings, source}

      %{"type" => "minecraft:noise", "settings" => settings, "biome_source" => biome_source}
      when is_binary(settings) ->
        case biome_source do
          %{"type" => "minecraft:multi_noise", "preset" => preset}
          when preset in ["minecraft:overworld", "minecraft:nether"] ->
            {:ok, settings, preset}

          %{"type" => "minecraft:the_end"} ->
            {:ok, settings, "minecraft:the_end"}

          %{"type" => "minecraft:fixed", "biome" => biome} ->
            if biome in Worldgen.biome_names(),
              do: {:ok, settings, "fixed:" <> biome},
              else: {:error, {:unknown_biome, biome}}

          other ->
            {:error, {:unsupported_biome_source, id, other}}
        end

      other ->
        {:error, {:unsupported_generator, id, other}}
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
               facts: facts,
               structures: Map.get(settings, "generate_structures", true)
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
                   facts: facts,
                   structures: Map.get(settings, "generate_structures", true)
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
              structures = Map.get(spec, :structures, false)

              {:ok, terrain} =
                Native.worldgen_proto_terrain(state, source, proto.around(key, 2), structures)

              images = Map.new(terrain, fn {x, z, image} -> {{x, z}, image} end)

              {:ok, {touched, _}} =
                Native.worldgen_proto_decorate(
                  state,
                  source,
                  Map.values(images),
                  proto.around(key, 1),
                  structures
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
