defmodule Valimc.Commands.Effects do
  @moduledoc """
  Sound, particle and dialog commands (VMC-053i): `particle`, `playsound`,
  `stopsound` and `dialog`, sending vanilla's packets to the players concerned.
  """
  alias Valimc.Command.{Error, Feedback, Source, Text}
  alias Valimc.Protocol.{Packets, Wire}

  @sources ~w(master music record weather block hostile neutral player ambient voice ui)

  defp send(source, %{pid: pid}, packet) do
    if pid == self(),
      do: Valimc.Net.Codec.send_packets(source.state, [packet]),
      else: Valimc.Connection.deliver(pid, {:packet, packet})
  end

  defp tracked(source, sent, key, id_arg) do
    case sent do
      [] ->
        :ok

      [one] ->
        Feedback.success(
          source,
          Text.translatable(key <> ".single", [id_arg, Source.display_name(one)])
        )

      many ->
        Feedback.success(source, Text.translatable(key <> ".multiple", [id_arg, length(many)]))
    end
  end

  # ---- particle ----

  @doc "`/particle <name> [<pos> [<delta> <speed> <count> [force|normal [<viewers>]]]]`."
  def particle(%{"name" => {id, bytes}} = arguments, source) do
    {x, y, z} =
      if arguments["pos"], do: Source.position(source, arguments["pos"]), else: source.position

    {dx, dy, dz} =
      if arguments["delta"],
        do: Source.position(%{source | position: {0.0, 0.0, 0.0}}, arguments["delta"]),
        else: {0.0, 0.0, 0.0}

    speed = Map.get(arguments, "speed", 0.0)
    count = Map.get(arguments, "count", 0)
    force = arguments[:mode] == :force

    viewers =
      case arguments do
        %{"viewers" => selector} -> Source.required_players(source, selector)
        _ -> [source.player | Enum.reject(Valimc.Players.all(), &(&1.pid == self()))]
      end

    packet =
      Packets.packet("level_particles", [
        bytes,
        <<if(force, do: 1, else: 0), 0>>,
        <<x * 1.0::float-64, y * 1.0::float-64, z * 1.0::float-64>>,
        <<dx * 1.0::float-32, dy * 1.0::float-32, dz * 1.0::float-32>>,
        <<speed * 1.0::float-32, speed * 1.0::float-32, speed * 1.0::float-32>>,
        Wire.varint(count),
        Wire.varint(0)
      ])

    range = if force, do: 512, else: 32

    sent =
      for viewer <- viewers, within?(viewer, {x, y, z}, range) do
        send(source, viewer, packet)
        viewer
      end

    if sent == [], do: Error.fail!("commands.particle.failed")
    Feedback.success(source, Text.translatable("commands.particle.success", [id]))
    {length(sent), source.state}
  end

  def particle_force(arguments, source), do: particle(Map.put(arguments, :mode, :force), source)

  # Distance from the centre of the viewer's block, strictly below the range.
  defp within?(player, {x, y, z}, range) do
    cx = floor(player.x) + 0.5
    cy = floor(player.y) + 0.5
    cz = floor(player.z) + 0.5
    (cx - x) ** 2 + (cy - y) ** 2 + (cz - z) ** 2 < range * range
  end

  # ---- sounds ----

  @doc "`/playsound <sound> [<source> [<targets> [<pos> [<volume> [<pitch> [<minVolume>]]]]]]`."
  def playsound(%{"sound" => id} = arguments, source) do
    category = Map.get(arguments, :source, "master")

    targets =
      case arguments do
        %{"targets" => selector} -> Source.required_players(source, selector)
        _ -> [source.player]
      end

    {x, y, z} =
      if arguments["pos"], do: Source.position(source, arguments["pos"]), else: source.position

    volume = Map.get(arguments, "volume", 1.0)
    pitch = Map.get(arguments, "pitch", 1.0)
    min_volume = Map.get(arguments, "minVolume", 0.0)
    range = if volume > 1, do: 16 * volume, else: 16
    seed = :rand.uniform(0x3FFFFFFFFFFFFFFF)

    sent =
      Enum.flat_map(targets, fn target ->
        {dx, dy, dz} = {x - target.x, y - target.y, z - target.z}
        distance = :math.sqrt(dx * dx + dy * dy + dz * dz)

        cond do
          distance * distance <= range * range ->
            send(source, target, sound_packet(id, category, {x, y, z}, volume, pitch, seed))
            [target]

          min_volume <= 0 ->
            []

          true ->
            at =
              {target.x + dx / distance * 2, target.y + dy / distance * 2,
               target.z + dz / distance * 2}

            send(source, target, sound_packet(id, category, at, min_volume, pitch, seed))
            [target]
        end
      end)

    if sent == [], do: Error.fail!("commands.playsound.failed")
    tracked(source, sent, "commands.playsound.success", id)
    {length(sent), source.state}
  end

  for category <- @sources do
    def unquote(:"playsound_#{category}")(arguments, source),
      do: playsound(Map.put(arguments, :source, unquote(category)), source)

    def unquote(:"stopsound_#{category}")(arguments, source),
      do: stopsound(Map.put(arguments, :source, unquote(category)), source)
  end

  defp sound_packet(id, category, {x, y, z}, volume, pitch, seed) do
    Packets.packet("sound", [
      Wire.varint(0),
      Wire.string(id),
      <<0>>,
      Wire.varint(Enum.find_index(@sources, &(&1 == category))),
      <<trunc(x * 8)::signed-32, trunc(y * 8)::signed-32, trunc(z * 8)::signed-32>>,
      <<volume * 1.0::float-32, pitch * 1.0::float-32, seed::signed-64>>
    ])
  end

  @doc "`/stopsound <targets> [* <sound> | <source> [<sound>]]`."
  def stopsound(%{"targets" => selector} = arguments, source) do
    targets = Source.required_players(source, selector)
    category = arguments[:source]
    sound = arguments["sound"]

    flags = if(category, do: 1, else: 0) + if(sound, do: 2, else: 0)

    packet =
      Packets.packet("stop_sound", [
        <<flags>>,
        if(category, do: Wire.varint(Enum.find_index(@sources, &(&1 == category))), else: []),
        if(sound, do: Wire.string(sound), else: [])
      ])

    for target <- targets, do: send(source, target, packet)

    message =
      case {category, sound} do
        {nil, nil} ->
          Text.translatable("commands.stopsound.success.sourceless.any")

        {nil, sound} ->
          Text.translatable("commands.stopsound.success.sourceless.sound", [sound])

        {category, nil} ->
          Text.translatable("commands.stopsound.success.source.any", [category])

        {category, sound} ->
          Text.translatable("commands.stopsound.success.source.sound", [sound, category])
      end

    Feedback.success(source, message)
    {length(targets), source.state}
  end

  # ---- dialog ----

  @doc "`/dialog show <targets> <dialog>` and `/dialog clear <targets>`."
  def dialog_show(%{"targets" => selector, "dialog" => {_id, network_id}}, source) do
    targets = Source.required_players(source, selector)

    for target <- targets,
        do: send(source, target, Packets.packet("show_dialog", Wire.varint(network_id + 1)))

    dialog_feedback(source, targets, "commands.dialog.show")
  end

  def dialog_clear(%{"targets" => selector}, source) do
    targets = Source.required_players(source, selector)
    for target <- targets, do: send(source, target, Packets.packet("clear_dialog", <<>>))
    dialog_feedback(source, targets, "commands.dialog.clear")
  end

  defp dialog_feedback(source, targets, key) do
    message =
      case targets do
        [one] -> Text.translatable(key <> ".single", [Source.display_name(one)])
        _ -> Text.translatable(key <> ".multiple", [length(targets)])
      end

    Feedback.success(source, message)
    {length(targets), source.state}
  end
end
