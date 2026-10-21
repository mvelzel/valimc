defmodule Valimc.Commands.Locate do
  @moduledoc """
  `/locate structure` (VMC-053o): vanilla's `findNearestMapStructure` in the
  world generator (`Native.worldgen_structure_locate`, up to 100 grid rings),
  with `LocateCommand`'s messages. Structure ids and tags are generated facts.
  ValiMC does not place structure pieces yet (VMC-025f), so the position is
  where vanilla's structure starts.
  """
  require Logger
  alias Valimc.Command.{Error, Feedback, Text}

  @path Path.expand("../../../priv/commands/facts.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @structures MapSet.new(@facts["structures"])
  @tags @facts["structure_tags"]

  @doc "`/locate structure <structure>`: a structure id or `#tag`."
  def structure(%{"structure" => target}, source) do
    {printable, members} =
      case target do
        {:key, id} -> {id, if(id in @structures, do: [id])}
        {:tag_key, id} -> {"#" <> id, @tags[id]}
      end

    unless members, do: Error.fail!("commands.locate.structure.invalid", [printable])

    seed =
      case Valimc.World.Generator.current() do
        {:vanilla, seed} -> seed
        _ -> Error.refuse!("This flat preview world has no structures")
      end

    {x, y, z} = source.position
    pos = {floor(x), floor(y), floor(z)}
    {:ok, state} = Valimc.World.Generator.worldgen(seed)
    started = System.monotonic_time(:millisecond)

    found =
      case Valimc.Native.worldgen_structure_locate(
             state,
             "minecraft:overworld",
             members,
             pos,
             100
           ) do
        {:ok, found} -> found
        {:error, reason} -> Error.refuse!("Locating structures failed (#{reason})")
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
    {distance, source.state}
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
end
