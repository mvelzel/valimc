defmodule Valimc.Player.Pistons do
  @moduledoc """
  Moving blocks near a hosted player (VMC-048b), as its group hands a tick's
  pushes to the session: vanilla's server moves its player as it moves any
  entity a moving block meets (`PistonMovingBlockEntity.moveCollidedEntities`
  and `moveStuckEntities`, the piston mover's `Entity.move`), while the
  client moves its own player alike from the block event. The server keeps
  the moved position as the start of the client's next move, so the move
  packets that follow compare with where both put the player; nothing is
  sent. The server does not simulate a player's motion (`canSimulateMovement`),
  so a slime block flings only the client's. A spectator passes through.
  """
  alias Valimc.Data.PlayerPose
  alias Valimc.Physics.Kernel
  alias Valimc.Player.PlayerList

  @doc "The session after `pushes` (a tick's moving-block ticks, as `Kernel.pistons/4` takes them)."
  def push(
        %{phase: :play, life_stage: :alive, teleport_pending: false, player: player} = state,
        pushes
      ) do
    feet = {player.x, player.y, player.z}

    with false <- player.game_mode.current == :spectator,
         {:ok, %{box: {x0, y0, _, x1, y1, _}}} <-
           PlayerPose.geometry(Map.get(player, :pose, :standing), feet) do
      motion = player.motion

      body =
        {feet, {(x1 - x0) / 2, y1 - y0}, motion.velocity, {motion.on_ground, 0.6, false, false},
         {0.0, false, true, 0.08, 0.98}}

      case Kernel.pistons(
             Valimc.World.View.new(player.dimension),
             pushes,
             [body],
             Valimc.World.Clock.border_snapshot(player.dimension)
           ) do
        {:ok, [{{x, y, z}, _velocity, on_ground, true}]} ->
          player = %{player | x: x, y: y, z: z, motion: %{motion | on_ground: on_ground}}
          PlayerList.update(state.connection, player)
          %{state | player: player}

        _ ->
          state
      end
    else
      _ -> state
    end
  end

  def push(state, _pushes), do: state
end
