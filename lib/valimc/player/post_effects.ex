defmodule Valimc.Player.PostEffects do
  @moduledoc """
  A player's ordered list of post-effect ids (VMC-053i, `/posteffect`), sent
  whole with `post_effects` on every change. The list lives on the online
  player and is cleared on respawn, as in vanilla; it is not yet saved with the
  player across reconnects.
  """
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
      Valimc.Players.update(state.connection, player)
      Valimc.Net.Codec.send_packets(state, [packet(next)])
      {true, %{state | player: player}}
    end
  end
end
