defmodule Valimc.Commands.PostEffects do
  @moduledoc """
  `/posteffect` (VMC-053i): each player's ordered list of post-effect ids, sent
  whole with `post_effects` on every change. The list lives on the online
  player and is cleared on respawn, as in vanilla; it is not yet saved with the
  player across reconnects.
  """
  alias Valimc.Command.{Error, Feedback, Source, Text}
  alias Valimc.Commands.Remote
  alias Valimc.Protocol.{Packets, Wire}

  def packet(ids),
    do: Packets.packet("post_effects", [Wire.varint(length(ids)), Enum.map(ids, &Wire.string/1)])

  @doc "Changes the connection's own list; returns `{changed, state}`."
  def apply(state, operation) do
    current = Map.get(state.player, :post_effects, [])

    next =
      case operation do
        {:add, id} -> if id in current, do: current, else: current ++ [id]
        {:remove, id} -> List.delete(current, id)
        :clear -> []
      end

    if next == current do
      {false, state}
    else
      player = Map.put(state.player, :post_effects, next)
      Valimc.Players.update(self(), player)
      Valimc.Net.Codec.send_packets(state, [packet(next)])
      {true, %{state | player: player}}
    end
  end

  @doc "`/posteffect add|remove <targets> <posteffect>`, `clear <targets>`, `list <target>`."
  def posteffect(%{literals: [mode]} = arguments, source) do
    case {mode, arguments} do
      {"add", %{"targets" => selector, "posteffect" => id}} ->
        change(source, selector, {:add, id}, "add", id)

      {"remove", %{"targets" => selector, "posteffect" => id}} ->
        change(source, selector, {:remove, id}, "remove", id)

      {"clear", %{"targets" => selector}} ->
        change(source, selector, :clear, "clear", nil)

      {"list", %{"target" => selector}} ->
        list(selector, source)
    end
  end

  defp change(source, selector, operation, key, id) do
    targets = Source.required_players(source, selector)

    changed =
      for {target, true} <- Remote.run_all!(targets, fn _ -> {:post_effect, operation} end),
          do: target

    args = if id, do: [id], else: []

    case changed do
      [] ->
        Error.fail!("commands.posteffect.#{key}.failed")

      [one] ->
        Feedback.success(
          source,
          Text.translatable(
            "commands.posteffect.#{key}.success.single",
            args ++ [Source.display_name(one)]
          )
        )

      many ->
        Feedback.success(
          source,
          Text.translatable("commands.posteffect.#{key}.success.multiple", args ++ [length(many)])
        )
    end

    length(changed)
  end

  defp list(selector, source) do
    target = Source.single_player(source, selector)
    ids = Map.get(target, :post_effects, [])
    name = Source.display_name(target)

    message =
      if ids == [],
        do: Text.translatable("commands.posteffect.list.empty", [name]),
        else:
          Text.translatable("commands.posteffect.list.success", [
            name,
            length(ids),
            Enum.join(ids, ", ")
          ])

    Feedback.success(source, message, false)
    length(ids)
  end
end
