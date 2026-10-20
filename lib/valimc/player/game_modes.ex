defmodule Valimc.Player.GameModes do
  @moduledoc """
  Live game-mode changes in the owning connection (VMC-053), as vanilla's
  `ServerPlayer.setGameMode`: abilities follow the mode, the client gets the
  `change_game_mode` event and abilities, and peers that track the player get the
  game-mode player-info update. Unchanged modes report `:unchanged`.
  """
  alias Valimc.{GameMode, Players, PlayerAbilities, PlayerMotion}
  alias Valimc.Protocol.{Packets, Wire}
  import Valimc.Net.Codec, only: [send_packets: 2]

  def set(state, mode) do
    if state.player.game_mode.current == mode do
      {:unchanged, state}
    else
      {:ok, game_mode} = GameMode.change(state.player.game_mode, mode)
      abilities = PlayerAbilities.for_mode(mode, state.player.abilities)

      player = %{
        state.player
        | game_mode: game_mode,
          abilities: abilities,
          motion: PlayerMotion.flight(state.player.motion, abilities.flying)
      }

      state = %{
        state
        | player: player,
          inventory: %{state.inventory | infinite_materials: abilities.infinite_materials}
      }

      Players.update(self(), player)

      send_packets(state, [
        Packets.packet("game_event", <<3, GameMode.id(mode) * 1.0::float-32>>),
        Packets.abilities(abilities),
        Packets.interaction_attributes(player),
        info(player)
      ])

      Players.broadcast({:player_packet, self(), player.entity_id, info(player)}, self())
      {:changed, state}
    end
  end

  @doc "The `player_info_update` packet with only `UPDATE_GAME_MODE`."
  def info(player) do
    Packets.packet("player_info_update", [
      <<0x04, 1>>,
      player.uuid,
      Wire.varint(GameMode.id(player.game_mode.current))
    ])
  end
end
