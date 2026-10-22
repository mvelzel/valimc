defmodule Valimc.Commands.Locate do
  @moduledoc """
  `/locate structure` (VMC-053o): vanilla's `findNearestMapStructure` in the
  world generator (`Native.worldgen_structure_locate`, up to 100 grid rings),
  with `LocateCommand`'s messages. Structure ids and tags are generated facts.
  """
  require Logger
  alias Valimc.Text.Error
  alias Valimc.Commands.Feedback
  alias Valimc.Text

  @doc "`/locate structure <structure>` and `/locate biome <biome>`."
  def locate(%{literals: ["structure"]} = arguments, source), do: structure(arguments, source)
  def locate(%{literals: ["biome"]} = arguments, source), do: biome(arguments, source)

  # `/locate structure <structure>`: a structure id or `#tag`.
  defp structure(%{"structure" => target}, source) do
    {printable, members} =
      case target do
        {:key, id} -> {id, if(MapSet.member?(Valimc.Commands.Facts.structures(), id), do: [id])}
        {:tag_key, id} -> {"#" <> id, Valimc.Commands.Facts.structure_tags()[id]}
      end

    unless members, do: Error.fail!("commands.locate.structure.invalid", [printable])

    # A world created without structures finds none (`generate-structures`).
    world = Valimc.World.Spec.current()

    unless Valimc.World.Spec.structures?(world),
      do: Error.fail!("commands.locate.structure.not_found", [printable])

    # The executing dimension's own generation (VMC-028: presets, a single
    # biome, data packs; VMC-077a: the source's dimension).
    spec =
      case Valimc.World.Spec.generation(world, source.dimension) do
        {:ok, %{kind: :noise} = spec} -> spec
        _ -> Error.refuse!("This flat preview world has no structures")
      end

    {x, y, z} = source.position
    pos = {floor(x), floor(y), floor(z)}
    started = System.monotonic_time(:millisecond)

    # A generation job (VMC-077b pool), never the command's own dirty call.
    search = fn ->
      {:ok, state} =
        Valimc.Worldgen.Generator.worldgen(spec.seed, spec.noise_settings, spec.facts)

      Valimc.Native.worldgen_structure_locate(state, spec.biome_source, members, pos, 100)
    end

    found =
      case Valimc.Worldgen.Pool.run(search, 50_000) do
        {:ok, {:ok, found}} -> found
        {:error, reason} -> Error.refuse!("Locating structures failed (#{inspect(reason)})")
      end

    elapsed = System.monotonic_time(:millisecond) - started

    case found do
      nil ->
        Error.fail!("commands.locate.structure.not_found", [printable])

      {fx, fy, fz, id} ->
        name = if match?({:tag_key, _}, target), do: "#{printable} (#{id})", else: printable
        show(source, pos, {fx, fy, fz}, "commands.locate.structure.success", false, name, elapsed)
    end
  end

  @doc "`LocateCommand.showLocateResult`: the message, the log line and the distance."
  def show(source, {sx, sy, sz}, {fx, fy, fz}, key, include_y, name, elapsed_ms) do
    distance =
      if include_y,
        do: mth_sqrt((sx - fx) ** 2 + (sy - fy) ** 2 + (sz - fz) ** 2) |> floor(),
        else:
          mth_sqrt(int32(int32((fx - sx) * (fx - sx)) + int32((fz - sz) * (fz - sz)))) |> floor()

    shown_y = if include_y, do: Integer.to_string(fy), else: "~"

    coordinates =
      Text.translatable("chat.square_brackets", [
        Text.translatable("chat.coordinates", [fx, shown_y, fz])
      ])
      |> Text.style([
        {"color", "green"},
        {"click_event", Text.suggest_command("/tp @s #{fx} #{shown_y} #{fz}")},
        {"hover_event",
         {:compound,
          %{
            "action" => {:string, "show_text"},
            "value" => Text.translatable("chat.coordinates.tooltip")
          }}}
      ])

    Feedback.success(source, Text.translatable(key, [name, coordinates, distance]), false)
    Logger.info("Locating element #{name} took #{elapsed_ms} ms")
    distance
  end

  # `Mth.sqrt(float)`: the argument and the root are both floats.
  defp mth_sqrt(value), do: float32(:math.sqrt(float32(value)))

  defp int32(value) do
    <<wrapped::signed-32>> = <<value::32>>
    wrapped
  end

  defp float32(value) do
    <<rounded::float-32>> = <<value * 1.0::float-32>>
    rounded
  end

  # `/locate biome <biome>` in a flat world, whose only biome is plains.
  defp biome(%{"biome" => biome}, source) do
    unless Valimc.World.Spec.generation(Valimc.World.Spec.current(), source.dimension) == nil,
      do:
        Error.throw!(%Error{
          message: Text.literal("Locating biomes in generated worlds is not supported yet")
        })

    {printable, found} =
      case biome do
        {:resource, id} -> {id, id == "minecraft:plains"}
        {:tag, id, members} -> {"#" <> id, plains_id() in members}
      end

    unless found, do: Error.fail!("commands.locate.biome.not_found", [printable])
    {x, y, z} = source.position
    min_y = Valimc.Data.Grid.min_y()

    {bx, by, bz} =
      {floor(x), floor(y) |> max(min_y + 1) |> min(Valimc.Data.Grid.max_y() + 1), floor(z)}

    name = if match?({:tag, _, _}, biome), do: "#{printable} (minecraft:plains)", else: printable

    coordinates =
      Text.translatable("chat.square_brackets", [
        Text.translatable("chat.coordinates", [bx, Integer.to_string(by), bz])
      ])
      |> Text.style([
        {"color", "green"},
        {"click_event", Text.suggest_command("/tp @s #{bx} #{by} #{bz}")},
        {"hover_event",
         {:compound,
          %{
            "action" => {:string, "show_text"},
            "value" => Text.translatable("chat.coordinates.tooltip")
          }}}
      ])

    Feedback.success(
      source,
      Text.translatable("commands.locate.biome.success", [name, coordinates, 0]),
      false
    )

    0
  end

  defp plains_id,
    do: Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
end
