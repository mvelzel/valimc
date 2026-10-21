defmodule Valimc.World.GenSettings do
  @moduledoc """
  A world's generation settings as vanilla 26.3 stores them (VMC-028a):
  `WorldGenSettings` in `data/minecraft/world_gen_settings.dat`, its `data`
  holding `seed`, `generate_structures`, `bonus_chest` and `dimensions`
  (dimension id to its `type` and `generator`). ValiMC keeps the codec's JSON
  form in `world.json` (`generator.settings`), so import and export convert
  between NBT and JSON instead of interpreting.

  New settings follow a dedicated server's `server.properties`: `level-type`
  names a world preset (`priv/worldgen/world_presets.json`, the data pack's
  `worldgen/world_preset` registry), falling back to `minecraft:normal`; only for
  `minecraft:flat` do `generator-settings` replace the overworld's generator,
  parsed as `FlatLevelGeneratorSettings` (and ignored when they do not parse).
  The structures flag is `generate-structures`; there is no bonus chest.

  Generators ValiMC can convert: noise (settings named, not inline) over a
  multi-noise preset, fixed, checkerboard or End biome source; flat; debug.
  Anything else (a data pack's inline settings or parameter lists) is refused
  with its reason.
  """
  alias Valimc.Registry.Blocks

  @path Path.expand("../../../priv/worldgen/world_presets.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  unless Valimc.Version.stamped?(@facts), do: raise("Wrong world preset facts")
  @presets @facts["presets"]

  @sets_path Path.expand("../../../priv/worldgen/structure_sets.json", __DIR__)
  @external_resource @sets_path
  @structure_sets @sets_path |> File.read!() |> :json.decode() |> Map.keys() |> MapSet.new()

  @normal "minecraft:normal"
  @flat "minecraft:flat"
  # `DimensionType.Y_SIZE`: a flat world's layers stay within it.
  @max_height 4064
  @booleans ~w(generate_structures bonus_chest lakes features)
  @generators ~w(minecraft:noise minecraft:flat minecraft:debug)

  @doc "The world presets, by id."
  def presets, do: @presets

  @doc """
  Settings for a new world: `level_type` (a preset id), `generator_settings`
  (`server.properties` JSON, used by the flat preset), `seed` and whether
  structures generate.
  """
  def create(level_type, generator_settings, seed, structures)
      when is_integer(seed) and is_boolean(structures) do
    preset = Map.get(@presets, level_type || @normal, @presets[@normal])

    dimensions =
      case {Map.has_key?(@presets, level_type) and level_type == @flat, flat(generator_settings)} do
        {true, {:ok, settings}} ->
          put_in(preset["dimensions"]["minecraft:overworld"]["generator"], %{
            "type" => @flat,
            "settings" => settings
          })["dimensions"]

        _ ->
          preset["dimensions"]
      end

    %{
      "seed" => seed,
      "generate_structures" => structures,
      "bonus_chest" => false,
      "dimensions" => dimensions
    }
  end

  @doc "The overworld's generator."
  def overworld(%{"dimensions" => %{"minecraft:overworld" => %{"generator" => generator}}}),
    do: generator

  @doc """
  `FlatLevelGeneratorSettings` from `server.properties` JSON, normalised as its
  codec writes them back: layers (an unknown block is air), lakes and features
  (false unless given), the biome (plains unless a known one is given), and
  structure overrides when they name known structure sets (a lenient field:
  anything else drops it). `:error` when they do not parse.
  """
  def flat(nil), do: :error
  def flat(""), do: :error

  def flat(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = json} -> flat(json)
      _ -> :error
    end
  end

  def flat(%{"layers" => layers} = json) when is_list(layers) do
    with {:ok, layers} <- layers(layers),
         true <- Enum.sum(Enum.map(layers, & &1["height"])) <= @max_height,
         {:ok, lakes} <- boolean(json, "lakes"),
         {:ok, features} <- boolean(json, "features") do
      settings = %{
        "layers" => layers,
        "lakes" => lakes,
        "features" => features,
        "biome" => biome(json["biome"])
      }

      {:ok,
       case overrides(json["structure_overrides"]) do
         nil -> settings
         overrides -> Map.put(settings, "structure_overrides", overrides)
       end}
    else
      _ -> :error
    end
  end

  def flat(_), do: :error

  defp layers(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"height" => height} = layer, {:ok, acc}
      when is_integer(height) and height >= 0 and height <= @max_height ->
        block =
          case layer["block"] do
            "minecraft:" <> name = id when is_binary(name) ->
              if Blocks.id(name), do: id, else: "minecraft:air"

            name when is_binary(name) ->
              if Blocks.id(name), do: "minecraft:" <> name, else: "minecraft:air"

            _ ->
              "minecraft:air"
          end

        {:cont, {:ok, [%{"block" => block, "height" => height} | acc]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, layers} -> {:ok, Enum.reverse(layers)}
      error -> error
    end
  end

  defp boolean(json, key) do
    case Map.get(json, key, false) do
      value when is_boolean(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp biome(name) when is_binary(name) do
    id = if String.contains?(name, ":"), do: name, else: "minecraft:" <> name
    if id in Valimc.Worldgen.biome_names(), do: id, else: "minecraft:plains"
  end

  defp biome(_), do: "minecraft:plains"

  defp overrides(list) when is_list(list) and list != [] do
    ids = Enum.map(list, &qualify/1)
    if Enum.all?(ids, &MapSet.member?(@structure_sets, &1)), do: ids
  end

  defp overrides(id) when is_binary(id) do
    if not String.starts_with?(id, "#") and MapSet.member?(@structure_sets, qualify(id)),
      do: qualify(id)
  end

  defp overrides(_), do: nil

  defp qualify(id) when is_binary(id),
    do: if(String.contains?(id, ":"), do: id, else: "minecraft:" <> id)

  defp qualify(_), do: nil

  @doc """
  The settings of a world created before VMC-028a, from its `world.json`
  generator: a vanilla world used the normal preset (structures on), a world
  without a generator ValiMC's flat profile (bedrock, 123 stone, 3 dirt, grass
  over plains, no structures, seed 0).
  """
  def legacy({:vanilla, seed}), do: create(@normal, nil, seed, true)

  def legacy(:flat) do
    {:ok, settings} =
      flat(%{
        "layers" => [
          %{"block" => "minecraft:bedrock", "height" => 1},
          %{"block" => "minecraft:stone", "height" => 123},
          %{"block" => "minecraft:dirt", "height" => 3},
          %{"block" => "minecraft:grass_block", "height" => 1}
        ],
        "biome" => "minecraft:plains"
      })

    flat = create(@normal, nil, 0, false)

    put_in(flat["dimensions"]["minecraft:overworld"]["generator"], %{
      "type" => @flat,
      "settings" => settings
    })
  end

  ## Files

  @doc "`world_gen_settings.dat`'s root for `settings`: `data` and the data version."
  def to_nbt(settings) do
    with :ok <- supported(settings),
         {:ok, data} <- tag(settings, nil) do
      {:ok,
       {:compound, %{"data" => data, "DataVersion" => {:int, Valimc.Version.data_version()}}}}
    end
  end

  @doc "Settings from `world_gen_settings.dat`'s root, or `{:error, reason}`."
  def from_nbt({:compound, %{"data" => {:compound, _} = data} = root}) do
    with {:ok, _} <- Valimc.World.Schema.check(:data, {:compound, root}),
         {:ok, settings} <- json(data),
         :ok <- supported(settings),
         do: {:ok, settings}
  end

  def from_nbt(_), do: {:error, :invalid_world_gen_settings}

  # The codec's NBT types: `seed` is a long, flags are bytes, numbers ints.
  defp tag(value, "seed") when is_integer(value), do: {:ok, {:long, value}}
  defp tag(value, _) when is_boolean(value), do: {:ok, {:byte, if(value, do: 1, else: 0)}}
  defp tag(value, _) when is_integer(value), do: {:ok, {:int, value}}
  defp tag(value, _) when is_binary(value), do: {:ok, {:string, value}}

  defp tag(value, _) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, inner}, {:ok, acc} ->
      case tag(inner, key) do
        {:ok, tag} -> {:cont, {:ok, Map.put(acc, key, tag)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, {:compound, fields}}
      error -> error
    end
  end

  defp tag([], _), do: {:ok, {:list, {:end, []}}}

  defp tag(list, key) when is_list(list) do
    with {:ok, tags} <- tags(list, key) do
      case Enum.uniq(Enum.map(tags, &elem(&1, 0))) do
        [:compound] -> {:ok, {:list, {:compound, Enum.map(tags, &elem(&1, 1))}}}
        [:string] -> {:ok, {:list, {:string, Enum.map(tags, &elem(&1, 1))}}}
        _ -> {:error, {:unsupported_world_gen_settings, key}}
      end
    end
  end

  defp tag(_, key), do: {:error, {:unsupported_world_gen_settings, key}}

  defp tags(list, key) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case tag(value, key) do
        {:ok, tag} -> {:cont, {:ok, [tag | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.reverse(tags)}
      error -> error
    end
  end

  defp json({:compound, fields}) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, tag}, {:ok, acc} ->
      case value(tag, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp value({:byte, flag}, key) when key in @booleans and flag in [0, 1], do: {:ok, flag == 1}
  defp value({:long, value}, "seed"), do: {:ok, value}
  defp value({:int, value}, _), do: {:ok, value}
  defp value({:string, value}, _), do: {:ok, value}
  defp value({:compound, _} = tag, _), do: json(tag)
  defp value({:list, {:end, []}}, _), do: {:ok, []}
  defp value({:list, {:string, values}}, _), do: {:ok, values}

  defp value({:list, {:compound, values}}, key) do
    Enum.reduce_while(values, {:ok, []}, fn fields, {:ok, acc} ->
      case json({:compound, fields}) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      _ -> {:error, {:unsupported_world_gen_settings, key}}
    end
  end

  defp value(_, key), do: {:error, {:unsupported_world_gen_settings, key}}

  # The shapes ValiMC converts: every dimension a known generator type, noise
  # settings named, biome sources of known types without inline parameters.
  defp supported(%{"seed" => seed, "dimensions" => dimensions} = settings)
       when is_integer(seed) and is_map(dimensions) do
    with true <- is_boolean(settings["generate_structures"]),
         true <- is_boolean(settings["bonus_chest"]),
         nil <- Enum.find_value(dimensions, &unsupported_dimension/1) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_world_gen_settings}
    end
  end

  defp supported(_), do: {:error, :invalid_world_gen_settings}

  defp unsupported_dimension({id, %{"type" => type, "generator" => generator}})
       when is_binary(type) do
    case generator do
      %{"type" => "minecraft:noise", "settings" => settings, "biome_source" => source}
      when is_binary(settings) ->
        case source do
          %{"type" => "minecraft:multi_noise", "preset" => preset} when is_binary(preset) -> nil
          %{"type" => "minecraft:fixed", "biome" => biome} when is_binary(biome) -> nil
          %{"type" => "minecraft:checkerboard"} -> nil
          %{"type" => "minecraft:the_end"} -> nil
          %{"type" => type} -> {:error, {:unsupported_biome_source, id, type}}
          _ -> {:error, {:unsupported_biome_source, id, nil}}
        end

      %{"type" => "minecraft:noise"} ->
        {:error, {:inline_noise_settings, id}}

      %{"type" => type} when type in @generators ->
        nil

      %{"type" => type} ->
        {:error, {:unsupported_generator, id, type}}

      _ ->
        {:error, {:unsupported_generator, id, nil}}
    end
  end

  defp unsupported_dimension({id, _}), do: {:error, {:invalid_dimension, id}}
end
