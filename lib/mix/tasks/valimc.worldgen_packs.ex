defmodule Mix.Tasks.Valimc.WorldgenPacks do
  @shortdoc "Extract the worldgen facts of a world's data packs"
  @moduledoc """
      mix valimc.worldgen_packs WORLD

  Runs the fact oracles that give `priv/worldgen` with the world's data packs
  (`WORLD/datapacks`, folders and zips, after vanilla's in name order) into
  `WORLD/worldgen/DIGEST/` (`Valimc.World.Datapacks`, VMC-028c), and checks that
  ValiMC can generate them. Needs the research toolchain (Java 25 and the pinned
  jar, `scripts/java_tool.py`); run it whenever the packs change, with the
  server stopped.
  """
  use Mix.Task
  alias Valimc.World.Datapacks

  @worldgen ~w(noises density_functions noise_settings biome_parameters material_rules
               material_conditions biomes carvers features placed_features block_state_providers
               feature_order dimensions)

  @impl true
  def run([world]) do
    Mix.Task.run("app.config")
    Valimc.Protocol.Data.load!()
    world = Path.expand(world)

    case Datapacks.digest(world) do
      nil ->
        Mix.shell().info("#{world} has no data packs: it generates from vanilla's facts")

      digest ->
        dir = Path.join([world, "worldgen", digest])

        if match?({:ok, ^dir}, Datapacks.facts(world)) do
          Mix.shell().info("Facts for these packs exist: #{dir}")
        else
          extract(world, digest, dir)
        end
    end
  end

  def run(_), do: Mix.raise("usage: mix valimc.worldgen_packs WORLD")

  defp extract(world, digest, dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    unpacked =
      Path.join(
        System.tmp_dir!(),
        "valimc-packs-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(unpacked)

    try do
      packs = Datapacks.unpack(world, unpacked)
      out = &Path.join(dir, "#{&1}.json")

      oracle!(
        "WorldgenFactsOracle",
        Enum.map(@worldgen, out) ++ ["--tags", out.("tags")],
        packs
      )

      oracle!(
        "StructureTemplateOracle",
        [out.("block_transforms"), out.("processor_lists")],
        packs
      )

      oracle!(
        "StructureOracle",
        [
          "facts"
          | Enum.map(~w(structures structure_sets template_pools structure_templates), out)
        ],
        packs
      )

      oracle!("WorldSettingsOracle", ["facts", out.("world_presets")], packs)

      case Valimc.Worldgen.registry(dir) do
        {:ok, _} ->
          File.write!(
            Path.join(dir, "packs.json"),
            JSON.encode!(%{
              digest: digest,
              packs: Enum.map(Datapacks.packs(world), &Path.basename/1),
              version: Datapacks.facts_version(),
              server_sha1: Valimc.Version.server_sha1()
            })
          )

          case Datapacks.facts(world) do
            {:ok, ^dir} -> Mix.shell().info("Worldgen facts for #{length(packs)} packs: #{dir}")
            {:error, reason} -> refuse(dir, reason)
          end

        {:error, reason} ->
          refuse(dir, reason)
      end
    after
      File.rm_rf(unpacked)
    end
  end

  defp oracle!(name, args, packs) do
    {output, status} =
      System.cmd("python3", ["scripts/java_tool.py", name | args] ++ ["--packs" | packs],
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.shell().error(output)
      Mix.raise("#{name} failed with these packs")
    end
  end

  defp refuse(dir, reason) do
    File.rm_rf!(dir)
    Mix.raise("ValiMC cannot generate these packs' worldgen: #{inspect(reason)}")
  end
end
