defmodule Valimc.Commands.Text do
  @moduledoc """
  Text and presentation commands (VMC-053i): `tellraw` and `title`, with text
  resolved per recipient (`Valimc.Commands.ComponentResolver`).
  """
  alias Valimc.Commands.{ComponentResolver, Feedback, Targets}
  alias Valimc.Text
  alias Valimc.Protocol.{Packets, Wire}

  defp deliver(%{pid: pid}, packets),
    do: for(packet <- packets, do: Valimc.Player.PlayerList.deliver(pid, {:packet, packet}))

  defp component_packet(name, component),
    do: Packets.packet(name, Wire.text_component(Text.encode(component)))

  @doc "`/tellraw <targets> <message>`: system chat, no feedback."
  def tellraw(%{"targets" => selector, "message" => message}, source) do
    targets = Targets.required_players(source, selector)

    for target <- targets,
        do:
          deliver(target, [
            Packets.chat(
              Text.encode(ComponentResolver.resolve(message, recipient(source, target)))
            )
          ])

    length(targets)
  end

  # The recipient is the default score holder; ValiMC has no scores yet.
  defp recipient(source, _target), do: source

  @doc "`/title <targets> clear|reset|title|subtitle|actionbar|times`."
  def title(%{"targets" => selector, literals: [form]} = arguments, source) do
    targets = Targets.required_players(source, selector)

    {key, packet_for} =
      case String.to_existing_atom(form) do
        :clear ->
          {"commands.title.cleared", fn _ -> Packets.packet("clear_titles", <<0>>) end}

        :reset ->
          {"commands.title.reset", fn _ -> Packets.packet("clear_titles", <<1>>) end}

        :times ->
          {"commands.title.times",
           fn _ ->
             Packets.packet(
               "set_titles_animation",
               <<arguments["fadeIn"]::signed-32, arguments["stay"]::signed-32,
                 arguments["fadeOut"]::signed-32>>
             )
           end}

        form ->
          name =
            %{
              title: "set_title_text",
              subtitle: "set_subtitle_text",
              actionbar: "set_action_bar_text"
            }[form]

          {"commands.title.show.#{form}",
           fn target ->
             component_packet(
               name,
               ComponentResolver.resolve(arguments["title"], recipient(source, target))
             )
           end}
      end

    for target <- targets, do: deliver(target, [packet_for.(target)])

    Feedback.targets(source, targets, key)
    length(targets)
  end
end
