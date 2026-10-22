defmodule Valimc.World.Spec do
  @moduledoc """
  What a world generates, read once (VMC-077a). A world's `world.json` holds
  its generator; it is written once, crash-safely, when the world is created
  or imported (`write/2`) and never changed afterwards. The configured world's
  spec is loaded at application start (`load!/0`) and a failure to read it
  stops the start; nothing reads the file again, so a read error can never
  turn a generated world into flat terrain. Other worlds (tools, tests'
  private worlds) are read when asked (`fetch/1`).

  Generators: ValiMC's flat profile (`"flat"`, also a world without a
  `world.json`), vanilla generation of a seed (`"vanilla"`: its recorded
  settings, the normal preset without them, and `"features"` for decorated
  worlds) and imported worlds (`"imported"`: flat terrain outside the imported
  chunks, the recorded settings for the other dimensions). The settings that
  change at runtime (spawn, default game mode, admin switches) live in
  `Valimc.World.Settings`; a `world.json` that still holds a spawn is from
  before VMC-077a and is refused (worlds are not migrated, VMC-077 D4).

  Per dimension a spec knows its generation (nil when it does not generate,
  else `{:ok, generation}` as `Generator.spec_of/2` describes it, or
  `{:error, reason}`) and whether its chunks are decorated. The Nether and the
  End generate in every world type with the world's seed, decorated unless the
  overworld is noise terrain generated before decoration (VMC-026b).
  """
  alias Valimc.Worldgen.{Datapacks, GenSettings, Generator}

  @key {__MODULE__, :current}

  defstruct base: nil, generator: :flat, seed: 0, settings: nil, dimensions: %{}

  @doc "The world metadata file of a world directory."
  def path(base), do: Path.join(base, "world.json")

  @doc "Write a new world's `generator` entry (creation and import only)."
  def write(base, generator) when is_map(generator),
    do: Valimc.Storage.DurableFile.write(path(base), JSON.encode!(%{"generator" => generator}))

  @doc "Load the configured world's spec at start; raises when it cannot be read."
  def load! do
    base = Valimc.config(:world_path)

    case load(base) do
      {:ok, spec} -> :persistent_term.put(@key, spec)
      {:error, reason} -> raise "Cannot load the world at #{base}: #{inspect(reason)}"
    end
  end

  @doc """
  The configured world's spec (`load!/0`); tools that run without the
  application get ValiMC's flat profile without a world directory.
  """
  def current, do: :persistent_term.get(@key, nil) || build(nil, nil, {:ok, nil})

  @doc "The spec of the world at `base`: the loaded one, else read now (tools, tests)."
  def fetch(base) do
    case :persistent_term.get(@key, nil) do
      %__MODULE__{base: ^base} = spec ->
        spec

      _ ->
        case load(base) do
          {:ok, spec} -> spec
          {:error, reason} -> exit({:world_unavailable, base, reason})
        end
    end
  end

  @doc "Read the world at `base`: `{:ok, spec}` or `{:error, reason}`."
  def load(nil), do: {:ok, build(nil, nil, {:ok, nil})}

  def load(base) do
    with {:ok, generator} <- read(base),
         {:ok, spec} <- {:ok, build(base, generator, Datapacks.facts(base))} do
      case {spec.generator, spec.dimensions.overworld.generation} do
        {:vanilla, {:error, reason}} -> {:error, reason}
        _ -> {:ok, spec}
      end
    end
  end

  defp read(base) do
    case File.read(path(base)) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, %{"spawn" => _}} ->
            {:error,
             {:world_format_too_old,
              "#{path(base)} keeps the spawn; worlds from before VMC-077a are not migrated"}}

          {:ok, %{"generator" => generator}} when is_map(generator) ->
            {:ok, generator}

          _ ->
            {:error, {:invalid_world_metadata, path(base)}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:world_metadata_unreadable, path(base), reason}}
    end
  end

  defp build(base, generator, facts) do
    {kind, seed, settings, features} = kind(generator)
    overworld = overworld(kind, settings, facts)

    others =
      Map.new([:the_nether, :the_end], fn dimension ->
        decorated =
          case overworld do
            {:ok, %{kind: :noise}} -> features
            _ -> true
          end

        {dimension, %{generation: other(settings, seed, dimension, facts), decorated: decorated}}
      end)

    %__MODULE__{
      base: base,
      generator: kind,
      seed: seed,
      settings: settings,
      dimensions:
        Map.put(others, :overworld, %{
          generation: overworld,
          decorated: overworld != nil and features
        })
    }
  end

  # `{kind, seed, recorded settings, decorated}` of the `generator` entry.
  defp kind(%{"type" => "vanilla", "seed" => seed} = generator) when is_integer(seed) do
    settings = generator["settings"] || GenSettings.legacy({:vanilla, seed})
    {:vanilla, seed, settings, generator["features"] == true}
  end

  defp kind(%{"type" => "imported", "settings" => %{"seed" => seed} = settings})
       when is_integer(seed),
       do: {:imported, seed, settings, false}

  defp kind(%{"type" => "imported"}), do: {:imported, flat_seed(), nil, false}
  defp kind(nil), do: {:flat, flat_seed(), nil, false}
  defp kind(%{"type" => "flat"}), do: {:flat, flat_seed(), nil, false}
  defp kind(other), do: {{:unsupported, other}, flat_seed(), nil, false}

  # ValiMC's flat profile has no seed: the Nether and the End take the configured one.
  defp flat_seed, do: Valimc.config(:seed) || 0

  defp overworld(:vanilla, settings, facts),
    do: with({:ok, facts} <- facts, do: Generator.spec_of(settings, facts))

  defp overworld({:unsupported, other}, _settings, _facts),
    do: {:error, {:unsupported_world, other}}

  defp overworld(_kind, _settings, _facts), do: nil

  defp other(settings, seed, dimension, facts) do
    with {:ok, facts} <- facts,
         {:ok, noise, source} <- Generator.dimension_generator(settings, dimension) do
      {:ok,
       %{
         kind: :noise,
         seed: seed,
         noise_settings: noise,
         biome_source: source,
         facts: facts,
         structures: settings != nil and Map.get(settings, "generate_structures", true)
       }}
    end
  end

  @doc """
  How `dimension` generates its absent chunks: nil when it does not (a flat or
  imported overworld), `{:ok, generation}` or `{:error, reason}`.
  """
  def generation(%__MODULE__{dimensions: dimensions}, dimension),
    do: dimensions[dimension].generation

  @doc "Whether `dimension` decorates its generated chunks (VMC-025d)."
  def decorated?(%__MODULE__{dimensions: dimensions}, dimension),
    do: dimensions[dimension].decorated

  @doc "Whether the world generates structures (`generate-structures`)."
  def structures?(%__MODULE__{settings: settings}),
    do: settings == nil or Map.get(settings, "generate_structures", true)

  @doc """
  The settings to export: the recorded ones, else those of ValiMC's flat profile.
  """
  def settings(%__MODULE__{settings: settings}), do: settings || GenSettings.legacy(:flat)

  @doc """
  What the client learns about `dimension` in its spawn information: the hashed
  seed (`BiomeManager.obfuscateSeed`: the first eight bytes of the SHA-256 of
  the seed, both little-endian) and whether it is flat. ValiMC's flat profile
  has no seed (0) in the overworld; the Nether and the End have the world's.
  """
  def client_info(%__MODULE__{settings: nil}, :overworld), do: {0, true}

  def client_info(%__MODULE__{settings: settings}, :overworld),
    do: {hashed(settings["seed"]), GenSettings.overworld(settings)["type"] == "minecraft:flat"}

  def client_info(%__MODULE__{seed: seed}, _dimension), do: {hashed(seed), false}

  defp hashed(seed) do
    <<hashed::little-signed-64, _::binary>> = :crypto.hash(:sha256, <<seed::little-signed-64>>)
    hashed
  end
end
