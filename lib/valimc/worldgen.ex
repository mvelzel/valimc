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
  alias Valimc.Physics.FluidBlocks
  alias Valimc.Protocol.Data
  alias Valimc.Registry.Blocks

  @facts ~w(noises density_functions noise_settings biome_parameters material_rules
            material_conditions biomes carvers features placed_features block_state_providers
            feature_order)
  @rule_states ~w(result_state ore_block raw_ore_block filler_block)
  @terracotta ~w(terracotta orange_terracotta yellow_terracotta brown_terracotta red_terracotta
                 white_terracotta light_gray_terracotta)

  @doc "The native worldgen registry, parsed from the facts on first use."
  def registry do
    case :persistent_term.get({__MODULE__, :registry}, nil) do
      nil ->
        facts =
          Map.new(@facts, fn name ->
            json =
              Application.app_dir(:valimc, "priv/worldgen/#{name}.json")
              |> File.read!()
              |> JSON.decode!()

            {name, json}
          end)

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
          |> Map.put("blocks", blocks())
          |> Map.put(
            "support",
            read_json!(Application.app_dir(:valimc, "priv/worldgen/survival.json"))
          )
          |> Map.put(
            "block_registry",
            read_json!(Application.app_dir(:valimc, "priv/registry/blocks.json"))
          )
          |> Map.put("block_facts", block_facts())
          |> Map.put(
            "shapes",
            read_json!(Application.app_dir(:valimc, "priv/worldgen/shapes.json"))
          )
          |> Map.put(
            "templates",
            read_json!(Application.app_dir(:valimc, "priv/worldgen/templates.json"))
          )
          |> Map.put(
            "processor_lists",
            read_json!(Application.app_dir(:valimc, "priv/worldgen/processor_lists.json"))
          )
          |> Map.put(
            "structures",
            read_json!(Application.app_dir(:valimc, "priv/worldgen/structures.json"))
          )
          |> Map.put(
            "structure_sets",
            read_json!(Application.app_dir(:valimc, "priv/worldgen/structure_sets.json"))
          )

        {:ok, registry} = Native.worldgen_registry(facts)
        :persistent_term.put({__MODULE__, :registry}, registry)
        registry

      registry ->
        registry
    end
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()

  # Per state, what decoration reads (VMC-025): the worldgen flags, the
  # fluid (vanilla's fluid registry ids: empty, flowing water, water, flowing
  # lava, lava), its amount with the falling flag at bit 4, the heightmap
  # predicates, and the block and fluid tags.
  defp block_facts do
    flags = read_json!(Application.app_dir(:valimc, "priv/worldgen/blocks.json"))
    states = 0..(Blocks.state_count() - 1)

    fluids =
      Enum.map(states, fn id ->
        {:ok, fluid} = FluidBlocks.fetch(id)

        fluid_id =
          case {fluid.kind, fluid.source} do
            {:empty, _} -> 0
            {:water, false} -> 1
            {:water, true} -> 2
            {:lava, false} -> 3
            {:lava, true} -> 4
          end

        {fluid_id, fluid.amount + if(fluid.falling, do: 16, else: 0)}
      end)

    tags = Data.tags()

    %{
      "flags" => flags["flags"],
      "fluid" => Enum.map(fluids, &elem(&1, 0)),
      "fluid_level" => Enum.map(fluids, &elem(&1, 1)),
      "heightmaps" =>
        Enum.map(states, fn id ->
          {:ok, mask} = Valimc.Physics.HeightmapBlocks.mask(id)
          mask
        end),
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

  @doc "Worldgen state for `seed` and a noise settings entry."
  def new(seed, settings \\ "minecraft:overworld"),
    do: Native.worldgen_new(registry(), seed, settings)

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
  defp blocks do
    air = MapSet.new(~w(air cave_air void_air), &Blocks.id/1)
    water = Blocks.id("water")
    uncarvable = MapSet.new(Data.tags()["minecraft:block"]["minecraft:uncarvable"])
    grass = MapSet.new(~w(grass_block mycelium), &Blocks.id/1)
    dirt = Blocks.id("dirt")

    flags =
      for id <- 0..(Blocks.state_count() - 1) do
        block = Blocks.block_id(id)
        {:ok, fluid} = FluidBlocks.fetch(id)

        Enum.sum([
          if(block in air, do: 1, else: 0),
          if(fluid.kind != :empty, do: 2, else: 0),
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
