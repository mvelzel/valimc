defmodule Valimc.Worldgen do
  @moduledoc """
  Vanilla world generation (VMC-023, VMC-024). The generated facts in
  `priv/worldgen` (noise parameters, density functions, noise settings, biome
  parameter presets, material rules and conditions, biomes; from
  `WorldgenFactsOracle`) parse once per VM into a native registry, with block
  states turned into global state ids; `new/2` gives one seed's noises and
  compiled functions for a noise settings entry (`valimc_core::worldgen`).
  """
  alias Valimc.Native
  alias Valimc.Protocol.Data
  alias Valimc.Registry.{BlockFacts, Blocks}

  @facts ~w(noises density_functions noise_settings biome_parameters material_rules
            material_conditions biomes carvers features placed_features block_state_providers
            feature_order dimensions)
  @rule_states ~w(result_state ore_block raw_ore_block filler_block)
  @terracotta ~w(terracotta orange_terracotta yellow_terracotta brown_terracotta red_terracotta
                 white_terracotta light_gray_terracotta)

  # Facts a data pack can change (VMC-028c): a world with packs reads them from
  # its facts directory (`Valimc.World.Datapacks`), the rest from `priv`.
  @pack_facts @facts ++
                ~w(processor_lists structures structure_sets template_pools structure_templates)

  @doc """
  The native worldgen registry of vanilla's facts (`priv/worldgen`), parsed on
  first use; raises if they do not parse.
  """
  def registry do
    {:ok, registry} = registry(nil)
    registry
  end

  @doc """
  The native registry of a facts directory (`nil`: vanilla's): the facts a data
  pack can change come from `dir` (with its block and fluid tags,
  `tags.json`), the others from `priv`. Parsed once per directory and VM;
  `{:error, reason}` when ValiMC cannot generate them.
  """
  def registry(dir) do
    key = {__MODULE__, :registry, dir}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, registry} <- parse(dir) do
          :persistent_term.put(key, registry)
          {:ok, registry}
        end

      registry ->
        {:ok, registry}
    end
  end

  defp fact(dir, name) do
    path =
      if dir && name in @pack_facts,
        do: Path.join(dir, "#{name}.json"),
        else: Application.app_dir(:valimc, "priv/worldgen/#{name}.json")

    read_json!(path)
  end

  defp parse(dir) do
    facts = Map.new(@facts, &{&1, fact(dir, &1)})

    tags =
      case dir && File.read(Path.join(dir, "tags.json")) do
        {:ok, text} -> JSON.decode!(text)
        _ -> Data.tags()
      end

    facts =
      facts
      |> Map.update!("noise_settings", fn settings ->
        Map.new(settings, fn {id, entry} ->
          {id,
           entry
           |> Map.update!("default_block", &state_id/1)
           |> Map.update!("default_fluid", &state_id/1)}
        end)
      end)
      |> Map.update!("material_rules", &Map.new(&1, fn {id, rule} -> {id, states(rule)} end))
      |> Map.put("blocks", blocks(tags))
      |> Map.put("support", fact(nil, "survival"))
      |> Map.put(
        "block_registry",
        read_json!(Application.app_dir(:valimc, "priv/registry/blocks.json"))
      )
      |> Map.put("block_facts", block_facts(tags))
      |> Map.put("shapes", fact(nil, "shapes"))
      |> Map.merge(
        Map.new(
          ~w(block_transforms processor_lists structures structure_sets template_pools
             structure_templates),
          &{&1, fact(dir, &1)}
        )
      )

    BlockFacts.install!()
    Native.worldgen_registry(facts)
  rescue
    error in [File.Error, JSON.DecodeError, KeyError, MatchError, ArgumentError] ->
      {:error, Exception.message(error)}

    # Facts the native registry cannot generate raise with the reason.
    error in ErlangError ->
      {:error, error.original}
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()

  # What decoration reads besides the installed per-state facts
  # (`BlockFacts.install!/0`): each block's block entity type and the block and
  # fluid tags.
  defp block_facts(tags) do
    %{
      "block_entity_types" => BlockFacts.block_entity_types(),
      "block_tags" => tags["minecraft:block"],
      "fluid_tags" => tags["minecraft:fluid"]
    }
  end

  @doc "Biome names in the native registry's order (registry ids index this list)."
  def biome_names do
    Application.app_dir(:valimc, "priv/worldgen/biomes.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  The generation context of `seed` and a noise settings entry (VMC-077n), over
  vanilla's facts or a facts directory's (`registry/1`): compiled now, on a
  dirty scheduler, and shared by every generation call of the seed.
  """
  def new(seed, settings \\ "minecraft:overworld", dir \\ nil) do
    with {:ok, registry} <- registry(dir),
         do: Native.worldgen_new(registry, seed, settings)
  end

  # Block states inside material rules become state ids.
  defp states(%{} = json) do
    Map.new(json, fn
      {key, value} when key in @rule_states -> {key, state_id(value)}
      {key, value} -> {key, states(value)}
    end)
  end

  defp states(list) when is_list(list), do: Enum.map(list, &states/1)
  defp states(other), do: other

  # A block state as vanilla's codec encodes it: a name, or a name with
  # properties.
  defp state_id("minecraft:" <> name), do: Blocks.default_state(name)

  defp state_id(%{"Name" => "minecraft:" <> name} = state),
    do: Blocks.state(name, Map.get(state, "Properties", %{}))

  # Per state: bit 0 air, 1 contains a fluid, 2 water, 3 uncarvable (block
  # tag), 4 grass block or mycelium, 5 dirt.
  defp blocks(tags) do
    water = Blocks.id("water")
    uncarvable = MapSet.new(tags["minecraft:block"]["minecraft:uncarvable"])
    grass = MapSet.new(~w(grass_block mycelium), &Blocks.id/1)
    dirt = Blocks.id("dirt")

    flags =
      for id <- 0..(Blocks.state_count() - 1) do
        block = Blocks.block_id(id)

        Enum.sum([
          if(BlockFacts.air?(id), do: 1, else: 0),
          if(BlockFacts.fluid(id).kind != :empty, do: 2, else: 0),
          if(block == water, do: 4, else: 0),
          if(block in uncarvable, do: 8, else: 0),
          if(block in grass, do: 16, else: 0),
          if(block == dirt, do: 32, else: 0)
        ])
      end

    %{
      "air" => Blocks.default_state("air"),
      "water" => Blocks.default_state("water"),
      "lava" => Blocks.default_state("lava"),
      "terracotta" => Enum.map(@terracotta, &Blocks.default_state/1),
      "snow_block" => Blocks.default_state("snow_block"),
      "packed_ice" => Blocks.default_state("packed_ice"),
      "flags" => flags
    }
  end
end
