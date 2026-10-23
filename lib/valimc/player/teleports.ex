defmodule Valimc.Player.Teleports do
  @moduledoc """
  Command teleports in the owning connection (VMC-053b). The client gets an
  absolute position; vanilla's relative flags end at the same pose. Motion stops,
  flight continues and dead players stay where they are.
  """
  alias Valimc.Player.Motion

  # Another dimension's pose travels there (VMC-026b): vanilla's cross-level
  # `teleportTo` arrives at rest and starts no portal cooldown.
  def apply(%{life_stage: :alive} = state, %{dimension: dimension} = pose)
      when dimension != state.player.dimension do
    state = Valimc.Player.Sleep.stop(state, true)

    Valimc.Player.Travel.request(state, %{
      dimension: dimension,
      x: pose.x * 1.0,
      y: pose.y * 1.0,
      z: pose.z * 1.0,
      yaw: pose.yaw * 1.0,
      pitch: pose.pitch * 1.0,
      velocity: {0.0, 0.0, 0.0},
      portal: false
    })
  end

  def apply(%{life_stage: :alive} = state, pose) do
    # A teleported sleeper gets up first (`ServerPlayer.teleportTo`, VMC-040a).
    state = Valimc.Player.Sleep.stop(state, true)
    pose = Map.delete(pose, :dimension)

    player =
      Map.merge(state.player, %{
        x: pose.x * 1.0,
        y: pose.y * 1.0,
        z: pose.z * 1.0,
        yaw: pose.yaw * 1.0,
        pitch: pose.pitch * 1.0
      })

    state = Valimc.Player.Movement.relocate(state, player)

    player = %{
      state.player
      | motion: Motion.flight(state.player.motion, player.abilities.flying)
    }

    Valimc.Player.PlayerList.update(state.connection, player)
    %{state | player: player}
  end

  def apply(state, _pose), do: state
end
