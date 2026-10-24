defmodule Valimc.Player.Displacement do
  @moduledoc "An opening lid's external move of the hosted player, predicted alike by the client."
  alias Valimc.Data.{Box, PlayerPose}
  alias Valimc.Physics.Kernel
  alias Valimc.Player.PlayerList
  alias Valimc.World.{Clock, EntityColliders, View}

  def push(
        %{phase: :play, life_stage: :alive, teleport_pending: false, player: player} = state,
        area,
        delta
      ) do
    feet = {player.x, player.y, player.z}

    with false <- player.game_mode.current == :spectator,
         {:ok, %{box: {x0, y0, _, x1, y1, _} = box}} <-
           PlayerPose.geometry(Map.get(player, :pose, :standing), feet),
         true <- Box.intersects?(box, area),
         view = View.new(player.dimension),
         {:ok, boxes} <- EntityColliders.collect(view, query(box), player.entity_id),
         motion = player.motion,
         body =
           {feet, {(x1 - x0) / 2, y1 - y0}, motion.velocity, {motion.on_ground, 0.6, true, false},
            {0.0, false, true, 0.08, 0.98}},
         {:ok, {{x, y, z}, velocity, on_ground}} <-
           Kernel.displace(
             view,
             body,
             delta,
             boxes,
             Clock.border_snapshot(player.dimension),
             false
           ) do
      player = %{
        player
        | x: x,
          y: y,
          z: z,
          motion: %{motion | velocity: velocity, on_ground: on_ground}
      }

      PlayerList.update(state.connection, player)
      %{state | player: player}
    else
      _ -> state
    end
  end

  def push(state, _area, _delta), do: state

  defp query({a, b, c, d, e, f}), do: {a - 2.0, b - 2.0, c - 2.0, d + 2.0, e + 2.0, f + 2.0}
end
