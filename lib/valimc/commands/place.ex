defmodule Valimc.Commands.Place do
  @moduledoc """
  `/place feature|jigsaw|structure|template` (VMC-053), vanilla's
  `PlaceCommand` on the live world.

  The world generator plans the placement (`Native.worldgen_place_plan`): the
  chunks vanilla checks are loaded and every chunk it uses. Their region owners
  give their column images, the generator places into proto chunks made from
  them with a random seeded here (vanilla uses the level's random), and the
  blocks and block entities that changed are written back through the region
  owners, fenced at the revision the images were read at. Entities a structure
  would add are left out until mobs exist.
  """
  require Logger
  import Bitwise, only: [<<<: 2]
  alias Valimc.Command.{Error, Feedback, Source, Text}
  alias Valimc.Native

  @templates Path.expand("../../../priv/worldgen/structure_templates.json", __DIR__)
  @external_resource @templates
  @template_ids @templates |> File.read!() |> JSON.decode!() |> Map.keys() |> Enum.sort()
  @pools Path.expand("../../../priv/worldgen/template_pools.json", __DIR__)
  @external_resource @pools
  @pool_ids @pools |> File.read!() |> JSON.decode!() |> Map.keys() |> MapSet.new()
  @structures Path.expand("../../../priv/worldgen/structures.json", __DIR__)
  @external_resource @structures
  @structure_ids @structures |> File.read!() |> JSON.decode!() |> Map.keys() |> MapSet.new()

  @doc "Template ids, for the `place template` suggestions."
  def template_ids, do: @template_ids

  # ---- feature ----

  def feature(%{"feature" => id} = arguments, source) do
    pos = position(source, arguments["pos"])
    place!(source, {"feature", [id], 0, 1.0, false}, pos, "commands.place.feature.failed")
    {x, y, z} = pos
    Feedback.success(source, Text.translatable("commands.place.feature.success", [id, x, y, z]))
    {1, source.state}
  end

  # ---- jigsaw ----

  def jigsaw(%{"pool" => pool, "target" => target, "max_depth" => depth} = arguments, source) do
    unless pool in @pool_ids, do: Error.fail!("commands.place.jigsaw.invalid", [pool])
    pos = position(source, arguments["position"])

    place!(
      source,
      {"jigsaw", [pool, target], depth, 1.0, false},
      pos,
      "commands.place.jigsaw.failed"
    )

    {x, y, z} = pos
    Feedback.success(source, Text.translatable("commands.place.jigsaw.success", [x, y, z]))
    {1, source.state}
  end

  # ---- structure ----

  def structure(%{"structure" => id} = arguments, source) do
    unless id in @structure_ids, do: Error.fail!("commands.place.structure.invalid", [id])
    pos = position(source, arguments["pos"])
    place!(source, {"structure", [id], 0, 1.0, false}, pos, "commands.place.structure.failed")
    {x, y, z} = pos
    Feedback.success(source, Text.translatable("commands.place.structure.success", [id, x, y, z]))
    {1, source.state}
  end

  # ---- template ----

  def template(%{"template" => id} = arguments, source) do
    pos = position(source, arguments["pos"])
    rotation = Map.get(arguments, "rotation", "none")
    mirror = Map.get(arguments, "mirror", "none")
    integrity = Map.get(arguments, "integrity", 1.0)
    seed = Map.get(arguments, "seed", 0)
    strict = Map.get(arguments, :strict, false)
    # `StructureBlockEntity.createRandom`: seed 0 is the current time.
    random = if seed == 0, do: System.system_time(:millisecond), else: seed
    spec = {"template", [id, rotation, mirror], 0, integrity * 1.0, strict}

    place!(
      source,
      spec,
      pos,
      "commands.place.template.failed",
      random,
      "commands.place.template.invalid",
      id
    )

    {x, y, z} = pos

    Feedback.success(
      source,
      Text.translatable("commands.place.template.success", [id, x, y, z])
    )

    {1, source.state}
  end

  def template_strict(arguments, source), do: template(Map.put(arguments, :strict, true), source)

  # ---- placement ----

  defp position(source, nil) do
    {x, y, z} = source.position
    {floor(x), floor(y), floor(z)}
  end

  defp position(source, coordinates) do
    {x, y, z} = Source.block_pos(source, coordinates)

    unless Valimc.World.Chunk.valid_y?(y) and abs(x) < 30_000_000 and abs(z) < 30_000_000,
      do: Error.fail!("argument.pos.outofworld")

    {x, y, z}
  end

  defp place!(source, spec, pos, failed, random \\ nil, invalid \\ nil, id \\ nil) do
    {state, biome_source} = generator!(elem(spec, 0))

    case Native.worldgen_place_plan(state, biome_source, spec, pos) do
      {:ok, {"invalid", _, _}} ->
        Error.fail!(invalid, [id])

      {:ok, {"failed", _, _}} ->
        Error.fail!(failed)

      # The area holds the chunks vanilla checks; any of them not loaded
      # refuses the placement.
      {:ok, {"chunks", _checked, area}} ->
        chunks = chunks(area)
        {images, revisions} = images!(chunks)
        input = for {cx, cz} = c <- chunks, do: {cx, cz, Map.fetch!(images, c)}
        seed = random || :rand.uniform(1 <<< 62)

        case Native.worldgen_place(state, biome_source, spec, pos, input, base(), seed) do
          {:ok, nil} ->
            Error.fail!(failed)

          {:ok, {blocks, entities, mobs}} ->
            write!(blocks, entities, revisions)
            if mobs > 0, do: Logger.info("/place left out #{mobs} entities (no mobs yet)")
            source

          {:error, reason} ->
            Error.refuse!("Placing failed (#{reason})")
        end

      {:error, reason} ->
        Error.refuse!("Placing failed (#{reason})")
    end
  end

  defp generator!(kind) do
    case Valimc.World.Generator.spec(Valimc.config(:world_path)) do
      {:ok, %{kind: :noise} = spec} ->
        {:ok, state} = Valimc.World.Generator.worldgen(spec.seed, spec.noise_settings, spec.facts)
        {state, spec.biome_source}

      # Flat worlds (ValiMC's profile and flat presets): plains features and
      # templates; their heights are not noise terrain, which structures need.
      _flat when kind == "structure" ->
        Error.refuse!("Placing structures in flat worlds is not supported yet")

      # A jigsaw needs the structure registry, which fixed biome sources lack;
      # it reads the overworld's only for template pools and level bounds.
      _flat when kind == "jigsaw" ->
        {:ok, state} = Valimc.World.Generator.worldgen(0)
        {state, "minecraft:overworld"}

      _flat ->
        {:ok, state} = Valimc.World.Generator.worldgen(0)
        {state, "fixed:minecraft:plains"}
    end
  end

  defp chunks({{x0, z0}, {x1, z1}}), do: for(z <- z0..z1, x <- x0..x1, do: {x, z})

  # Column images by chunk, read per region with the revision they were read at.
  defp images!(chunks) do
    chunks
    |> Enum.group_by(&Valimc.World.region_key/1)
    |> Enum.reduce({%{}, %{}}, fn {key, group}, {images, revisions} ->
      with {:ok, owner} <- Valimc.World.owner(key),
           {:ok, %{images: read, revision: revision}} <-
             Valimc.World.Region.column_images(owner, group) do
        {Map.merge(images, read), Map.put(revisions, key, {owner, revision})}
      else
        _ -> Error.fail!("argument.pos.unloaded")
      end
    end)
  end

  defp base do
    for y <- Valimc.World.Chunk.min_y()..Valimc.World.Chunk.max_y(),
        do: Valimc.World.Chunk.base(y)
  end

  # Blocks per region at the revision their images were read at (a change in
  # between refuses rather than overwriting it), then the block entities. The
  # blocks of placed block entities may be types ValiMC does not model: their
  # records follow, as generation writes them.
  defp write!(blocks, entities, revisions) do
    edits = Map.new(blocks)
    entity_positions = MapSet.new(entities, & &1.position)
    region_of = fn {{x, _, z}, _} -> Valimc.World.region_key(Valimc.World.chunk_key(x, z)) end

    entries =
      case Valimc.Worldgen.FullChunk.block_entities(entities, %{}) do
        {:ok, entries} ->
          entries

        {:error, reason} ->
          Logger.warning("/place block entities not converted: #{inspect(reason)}")
          %{}
      end

    for {key, group} <- Enum.group_by(edits, region_of) do
      {owner, revision} = Map.fetch!(revisions, key)

      Enum.reduce(Enum.chunk_every(group, 4096), revision, fn batch, revision ->
        case Valimc.World.Region.set_blocks(owner, revision, Map.new(batch), entity_positions) do
          {:ok, revision} -> revision
          {:error, reason} -> Error.refuse!("Placing could not change the world (#{reason})")
        end
      end)
    end

    for {key, group} <- Enum.group_by(entries, region_of) do
      {owner, _} = Map.fetch!(revisions, key)

      case Valimc.World.Region.put_block_entities(owner, Map.new(group)) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("/place block entities not written: #{inspect(reason)}")
      end
    end

    :ok
  end
end
